-- =============================================================================
-- Footprint — PostgreSQL Database Schema
-- Requires: PostgreSQL 15+ with pgvector extension
-- Run: psql -d footprint -f schema.sql
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgvector;

-- =============================================================================
-- ENUM TYPES
-- =============================================================================

CREATE TYPE media_type AS ENUM ('photo', 'video');

CREATE TYPE booking_source AS ENUM ('gmail', 'tripit', 'manual', 'csv');

-- Pipeline enrichment state — allows restarts without reprocessing done rows
CREATE TYPE enrichment_status AS ENUM ('pending', 'processing', 'done', 'failed');


-- =============================================================================
-- TRIPS
-- =============================================================================

CREATE TABLE trips (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT    NOT NULL,
    start_date  DATE    NOT NULL,
    end_date    DATE    NOT NULL,
    countries   TEXT[]  NOT NULL DEFAULT '{}',
    cities      TEXT[]  NOT NULL DEFAULT '{}',
    inferred    BOOLEAN NOT NULL DEFAULT TRUE,   -- TRUE = auto-detected from flights/gaps
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT trips_dates_valid CHECK (end_date >= start_date)
);

CREATE INDEX idx_trips_date_range ON trips (start_date, end_date);
CREATE INDEX idx_trips_countries  ON trips USING GIN (countries);
CREATE INDEX idx_trips_cities     ON trips USING GIN (cities);


-- =============================================================================
-- LOCATIONS
-- =============================================================================
-- Deduplicated geocoded places. Many media rows share one location row.
-- Cluster nearby coords before reverse-geocoding to avoid redundant API calls.

CREATE TABLE locations (
    id            BIGSERIAL PRIMARY KEY,
    country       TEXT,
    country_code  CHAR(2),        -- ISO 3166-1 alpha-2, e.g. 'JP'
    city          TEXT,
    neighborhood  TEXT,
    place_name    TEXT,           -- Most specific, e.g. "Senso-ji Temple"
    lat           DOUBLE PRECISION NOT NULL,
    lng           DOUBLE PRECISION NOT NULL,
    raw_geocode   JSONB,          -- Cached Nominatim response
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_locations_lat_lng ON locations (lat, lng);
CREATE INDEX idx_locations_country ON locations (country);
CREATE INDEX idx_locations_city    ON locations (city);


-- =============================================================================
-- MEDIA
-- =============================================================================
-- One row per photo or video. EXIF and Takeout sidecar JSON are merged here.
-- trip_id and location_id are null until pipeline stages assign them.
--
-- GPS notes:
--   - lat/lng come from Takeout geoData (preferred) or embedded EXIF
--   - 0.0, 0.0 means no GPS data — filter with: WHERE lat != 0 OR lng != 0
--   - google_photos_id is the dedup key for re-imports

CREATE TABLE media (
    id                BIGSERIAL PRIMARY KEY,
    trip_id           BIGINT REFERENCES trips     (id) ON DELETE SET NULL,
    location_id       BIGINT REFERENCES locations (id) ON DELETE SET NULL,

    google_photos_id  TEXT UNIQUE,
    filename          TEXT NOT NULL,
    file_path         TEXT NOT NULL,
    file_size_bytes   BIGINT,
    media_type        media_type NOT NULL,

    -- Use photoTakenTime from Takeout, not creationTime (which is upload date)
    captured_at       TIMESTAMPTZ,
    imported_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    lat               DOUBLE PRECISION,
    lng               DOUBLE PRECISION,
    altitude_m        DOUBLE PRECISION,

    camera_make       TEXT,
    camera_model      TEXT,
    width_px          INTEGER,
    height_px         INTEGER,
    duration_secs     DOUBLE PRECISION,  -- NULL for photos

    enrichment_status enrichment_status NOT NULL DEFAULT 'pending',
    deleted           BOOLEAN NOT NULL DEFAULT FALSE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_media_trip_id        ON media (trip_id);
CREATE INDEX idx_media_captured_at    ON media (captured_at);
CREATE INDEX idx_media_lat_lng        ON media (lat, lng);
CREATE INDEX idx_media_location_id    ON media (location_id);
CREATE INDEX idx_media_media_type     ON media (media_type);
-- Shrinks as pipeline progresses — keeps enrichment queue scans fast
CREATE INDEX idx_media_enrichment_pending
    ON media (enrichment_status)
    WHERE enrichment_status = 'pending';


-- =============================================================================
-- TRIP ↔ MEDIA OVERRIDES
-- =============================================================================
-- Date-range assignment covers ~95% of cases (media.trip_id set by pipeline).
-- This table handles edge cases: airport photos taken the morning after landing,
-- pre-trip shots, etc.

CREATE TABLE trip_media_overrides (
    trip_id   BIGINT NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    media_id  BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    action    TEXT NOT NULL DEFAULT 'include'
              CHECK (action IN ('include', 'exclude')),
    added_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (trip_id, media_id)
);


-- =============================================================================
-- FLIGHTS
-- =============================================================================
-- One row per leg. JFK→LHR→NRT = two rows.

CREATE TABLE flights (
    id                   BIGSERIAL PRIMARY KEY,
    trip_id              BIGINT REFERENCES trips (id) ON DELETE SET NULL,

    origin_iata          CHAR(3) NOT NULL,
    destination_iata     CHAR(3) NOT NULL,
    origin_city          TEXT,
    destination_city     TEXT,

    airline              TEXT,
    airline_iata         CHAR(2),
    flight_number        TEXT,

    scheduled_departure  TIMESTAMPTZ,
    actual_departure     TIMESTAMPTZ,
    scheduled_arrival    TIMESTAMPTZ,
    actual_arrival       TIMESTAMPTZ,

    source               booking_source NOT NULL DEFAULT 'manual',
    raw_source_data      JSONB,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (flight_number, scheduled_departure)
);

CREATE INDEX idx_flights_trip_id   ON flights (trip_id);
CREATE INDEX idx_flights_departure ON flights (scheduled_departure);
CREATE INDEX idx_flights_origin    ON flights (origin_iata);
CREATE INDEX idx_flights_dest      ON flights (destination_iata);


-- =============================================================================
-- HOTELS
-- =============================================================================

CREATE TABLE hotels (
    id           BIGSERIAL PRIMARY KEY,
    trip_id      BIGINT REFERENCES trips (id) ON DELETE SET NULL,

    name         TEXT NOT NULL,
    city         TEXT,
    country      TEXT,
    country_code CHAR(2),
    lat          DOUBLE PRECISION,
    lng          DOUBLE PRECISION,

    check_in     DATE NOT NULL,
    check_out    DATE NOT NULL,

    booking_ref     TEXT,
    source          booking_source NOT NULL DEFAULT 'manual',
    raw_source_data JSONB,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT hotels_dates_valid CHECK (check_out > check_in)
);

CREATE INDEX idx_hotels_trip_id  ON hotels (trip_id);
CREATE INDEX idx_hotels_check_in ON hotels (check_in);
CREATE INDEX idx_hotels_country  ON hotels (country);


-- =============================================================================
-- TAGS
-- =============================================================================
-- AI-generated tags per media item.
-- INSERT ... ON CONFLICT DO UPDATE safely refreshes scores on pipeline re-run.

CREATE TABLE tags (
    id          BIGSERIAL PRIMARY KEY,
    media_id    BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    tag         TEXT NOT NULL,
    confidence  REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    model       TEXT NOT NULL,  -- e.g. 'google-vision-v1', 'clip-vit-b32'
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (media_id, tag, model)
);

CREATE INDEX idx_tags_media_id ON tags (media_id);
CREATE INDEX idx_tags_tag      ON tags (tag);


-- =============================================================================
-- EMBEDDINGS
-- =============================================================================
-- One vector per (media_id, model) — supports multiple models side by side.
-- vector(512) = CLIP ViT-B/32. Change dimension for other models.
--
-- Semantic search query:
--   SELECT m.id, m.filename, 1 - (e.embedding <=> $1::vector) AS similarity
--   FROM embeddings e JOIN media m ON m.id = e.media_id
--   WHERE e.model = 'clip-vit-b32'
--   ORDER BY e.embedding <=> $1::vector
--   LIMIT 20;

CREATE TABLE embeddings (
    id          BIGSERIAL PRIMARY KEY,
    media_id    BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    embedding   vector(512) NOT NULL,
    model       TEXT    NOT NULL,
    dimensions  INTEGER NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (media_id, model),
    CONSTRAINT embeddings_dims_match CHECK (dimensions = vector_dims(embedding))
);

CREATE INDEX idx_embeddings_media_id ON embeddings (media_id);
-- HNSW ANN index — partial per model to keep cross-model distances separate
CREATE INDEX idx_embeddings_hnsw_clip
    ON embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE model = 'clip-vit-b32';


-- =============================================================================
-- CAPTIONS
-- =============================================================================
-- Bump prompt_version to iterate on prompts without losing old captions.

CREATE TABLE captions (
    id             BIGSERIAL PRIMARY KEY,
    media_id       BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    caption_text   TEXT NOT NULL,
    model          TEXT NOT NULL,
    prompt_version TEXT NOT NULL DEFAULT 'v1',
    tokens_used    INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (media_id, model, prompt_version)
);

CREATE INDEX idx_captions_media_id ON captions (media_id);


-- =============================================================================
-- UPDATED_AT TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_updated_at
    BEFORE UPDATE ON trips
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_media_updated_at
    BEFORE UPDATE ON media
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- VIEWS
-- =============================================================================

CREATE VIEW media_full AS
SELECT
    m.id, m.google_photos_id, m.filename, m.file_path,
    m.media_type, m.captured_at,
    m.lat, m.lng, m.altitude_m,
    m.camera_make, m.camera_model,
    m.width_px, m.height_px, m.duration_secs, m.file_size_bytes,
    m.enrichment_status,
    t.id         AS trip_id,
    t.name       AS trip_name,
    t.start_date AS trip_start,
    t.end_date   AS trip_end,
    l.id           AS location_id,
    l.country, l.country_code, l.city, l.neighborhood, l.place_name
FROM  media     m
LEFT JOIN trips     t ON t.id = m.trip_id
LEFT JOIN locations l ON l.id = m.location_id
WHERE m.deleted = FALSE;

CREATE VIEW year_stats AS
SELECT
    EXTRACT(YEAR FROM m.captured_at)::INTEGER           AS year,
    COUNT(*)                                             AS media_count,
    COUNT(*) FILTER (WHERE m.media_type = 'photo')      AS photo_count,
    COUNT(*) FILTER (WHERE m.media_type = 'video')      AS video_count,
    array_agg(DISTINCT l.country)
        FILTER (WHERE l.country IS NOT NULL)             AS countries,
    array_agg(DISTINCT l.city)
        FILTER (WHERE l.city IS NOT NULL)                AS cities,
    COUNT(DISTINCT l.country)                            AS country_count,
    COUNT(DISTINCT l.city)                               AS city_count
FROM  media     m
LEFT JOIN locations l ON l.id = m.location_id
WHERE m.deleted = FALSE
  AND m.captured_at IS NOT NULL
GROUP BY 1
ORDER BY 1;
