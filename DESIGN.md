# DESIGN.md — Footprint

System architecture, data schema, and key engineering decisions — including the reasoning behind each choice.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Storage Layer](#storage-layer)
3. [Data Schema](#data-schema)
4. [AI Enrichment Pipeline](#ai-enrichment-pipeline)
5. [Search](#search)
6. [API Layer](#api-layer)
7. [Multi-tenancy & Shared Trips](#multi-tenancy--shared-trips)
8. [Engineering Principles](#engineering-principles)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                      Data Sources                        │
│   Google Takeout (MVP)  │  Google Photos API (Phase 2)  │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│                   Ingestion Pipeline                      │
│  Takeout Parser → EXIF Extractor → Normalizer → DB Write │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│                  Enrichment Pipeline                      │
│  CLIP (tags + embeddings) → Claude (captions)            │
│  Nominatim (geocoding)    → Human review (UI)            │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│                     Storage                              │
│     PostgreSQL + pgvector    │    S3 (media files)       │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│                      API Layer                           │
│              FastAPI (Phase 2)                           │
└────────────────┬────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────────────────┐
│                         UI                               │
│       Streamlit (MVP)    │    Next.js + Deck.gl (Phase 2)│
└─────────────────────────────────────────────────────────┘
```

### Pipeline design principles

**Stateless workers**
Each pipeline stage reads from the DB, writes to the DB, and holds no local state between runs. This means any stage can be restarted, retried, or moved to a different machine without data loss. If a worker crashes mid-run, the next run picks up exactly where it left off — nothing is lost, nothing is duplicated.

**Queue-backed via DB**
The `enrichment_status` column on `media` acts as a lightweight job queue (`pending → processing → done/failed`). This is intentionally simple for MVP — no Redis, no Celery. But because it follows the same producer/consumer pattern, swapping in a real queue later requires changing only the runner, not the worker logic.

**Idempotent inserts**
Every insert uses `ON CONFLICT DO UPDATE` or `ON CONFLICT DO NOTHING`. Re-running any pipeline stage on the same data produces the same result. This matters because Takeout exports can be re-downloaded, and AI enrichment may be re-run with updated models or prompts. Idempotency means these are safe operations, not dangerous ones.

**Restartable**
Rows stuck in `processing` for > 10 minutes are reset to `pending` on pipeline startup. This handles the case where the process is killed mid-run — the next startup automatically recovers without manual intervention.

---

## Storage Layer

### Media files

Media files (photos, videos) are stored in an object store behind an abstract interface. The pipeline never references a storage backend directly — it always goes through the interface.

```python
class StorageBackend(Protocol):
    async def upload(self, key: str, data: bytes) -> str: ...
    async def download(self, key: str) -> bytes: ...
    async def get_signed_url(self, key: str, expires_in: int) -> str: ...
    async def delete(self, key: str) -> None: ...

class LocalStorage(StorageBackend): ...   # MVP
class S3Storage(StorageBackend): ...      # Phase 2
```

**Why abstract the storage backend?**
The MVP runs locally with 200 photos from one trip. Phase 2 needs to handle 28,000+ photos in the cloud. Without abstraction, migrating from local to S3 would require touching every part of the codebase that reads or writes files. With the `StorageBackend` protocol, swapping backends is a one-line config change. It also makes testing easier — tests use `LocalStorage` without needing AWS credentials.

**Why S3 over GCS?**
S3 is the industry default for object storage. Almost every company uses AWS or treats S3 as the reference architecture. Demonstrating S3 knowledge in interviews is more transferable than GCS, which is Google-specific. The `StorageBackend` abstraction means this choice can be revisited without code changes if needed.

**Key naming convention:**
```
{user_id}/{year}/{month}/{google_photos_id}.{ext}
e.g. 1/2023/12/AB1234.jpg
```

This structure makes it easy to list all media for a user, filter by year/month, and enforce access control at the bucket prefix level in S3.

### Database

PostgreSQL 15+ with the `pgvector` extension.

**Why PostgreSQL over a dedicated vector DB (e.g. Pinecone, Weaviate)?**
A dedicated vector DB would require running and maintaining a second database, syncing data between systems, and handling consistency. PostgreSQL with `pgvector` keeps everything in one place — structured metadata, relationships, and vectors — with full ACID guarantees and a single query language. For a library of 28,000 photos, pgvector's HNSW index is fast enough. The added operational complexity of a second DB is not justified at this scale.

---

## Data Schema

### Design principles

**Soft-delete everywhere**
`deleted BOOLEAN DEFAULT FALSE` and `deleted_at TIMESTAMPTZ` on all user-facing tables. Queries always filter `WHERE deleted = FALSE`.

*Why:* Users can accidentally delete a photo or tag. Without soft-delete, that data is gone permanently. With it, recovery is a single SQL update. In a shared trip, one user could delete something that belongs to another — soft-delete gives the owner a window to restore it. This is standard practice at big tech companies and becomes a compliance requirement when the product scales to paying users.

**Audit trail**
`created_at` and `updated_at` on all tables, maintained by database triggers (not application code).

*Why triggers instead of application code:* Application code can be bypassed — a direct DB query, a migration script, or a bug could update a row without setting `updated_at`. Triggers are enforced at the database level and cannot be skipped. This is important for debugging data issues in production.

**Multi-tenancy from day one**
`owner_id` foreign key on all user-owned tables, even in Phase 1 with a single user.

*Why add it now instead of later?* Adding `owner_id` to a table with millions of rows later requires a migration that locks the table, backfills values, and updates every existing query. Adding it from the start when the table is empty costs nothing. It also forces every query to be written with ownership in mind — a habit that prevents data leakage bugs when Phase 2 multi-user support is added.

**AI vs human data separated**
AI-generated content (tags, captions) lives in dedicated tables with `source`, `model`, and `verified` columns. User content (personal notes) lives on `media.note`. These are never mixed.

*Why:* AI outputs are probabilistic and can be wrong — they need to be reviewable, correctable, and re-generated as models improve. User-written content is authoritative and should never be overwritten by AI. Keeping them separate makes it clear which is which, and allows re-running AI enrichment without touching user data.

---

### users

```sql
CREATE TABLE users (
    id           BIGSERIAL PRIMARY KEY,
    email        TEXT UNIQUE NOT NULL,
    display_name TEXT,
    avatar_url   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted      BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);
```

---

### trips

A trip is the top-level organizing unit. Trips can be personal or shared between users.

```sql
CREATE TABLE trips (
    id          BIGSERIAL PRIMARY KEY,
    owner_id    BIGINT NOT NULL REFERENCES users (id),
    name        TEXT   NOT NULL,
    start_date  DATE   NOT NULL,
    end_date    DATE   NOT NULL,
    countries   TEXT[] NOT NULL DEFAULT '{}',
    cities      TEXT[] NOT NULL DEFAULT '{}',
    inferred    BOOLEAN NOT NULL DEFAULT TRUE,
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted     BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT trips_dates_valid CHECK (end_date >= start_date)
);
```

**Why `inferred BOOLEAN`?**
Trips can be detected automatically (date-range clustering from flight records and photo timestamps) or created manually. The flag distinguishes them so the UI can show confidence indicators and the pipeline knows which trips are safe to re-infer vs which the user has explicitly defined.

**Why `countries[]` and `cities[]` as arrays instead of a junction table?**
For display and filtering, querying `WHERE 'Japan' = ANY(countries)` is fast with a GIN index and avoids a join. For Phase 1 scale (hundreds of trips), this is the right tradeoff. If multi-user filtering across millions of trips becomes a hot path, normalize into a junction table at that point — it is a straightforward migration.

#### Shared trips

```sql
CREATE TABLE trip_members (
    trip_id    BIGINT NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    user_id    BIGINT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role       TEXT NOT NULL DEFAULT 'viewer'
               CHECK (role IN ('viewer', 'contributor', 'admin')),
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (trip_id, user_id)
);
```

**Why roles?**
A shared trip between partners needs granular control. A `viewer` can see the trip but not add media. A `contributor` can add their own photos to a shared timeline. An `admin` can manage members and edit trip details. Without roles, sharing is all-or-nothing — which breaks the use case where you want to share a trip view with family without letting them modify it.

**How shared trip timelines work:**
The trip timeline query joins `media` where `trip_id` matches AND the requesting user is either the `owner_id` or a member in `trip_members`. Media items retain their `owner_id` — contributors own their own photos. The timeline merges all contributors' media sorted by `captured_at`, giving a unified chronological view of the trip regardless of who took each photo.

---

### locations

Deduplicated geocoded places. Many media rows reference one location row.

```sql
CREATE TABLE locations (
    id            BIGSERIAL PRIMARY KEY,
    country       TEXT,
    country_code  CHAR(2),
    city          TEXT,
    neighborhood  TEXT,
    place_name    TEXT,
    lat           DOUBLE PRECISION NOT NULL,
    lng           DOUBLE PRECISION NOT NULL,
    raw_geocode   JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted       BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMPTZ
);
```

**Why deduplicate locations?**
A 200-photo trip to Korea will have many photos taken within meters of each other — same temple, same restaurant, same street corner. Without deduplication, you would call Nominatim 200 times and store 200 nearly-identical location rows. With deduplication (bounding-box check before geocoding), you call Nominatim once per unique place and store one row. This respects Nominatim's 1 req/sec rate limit and keeps the `locations` table clean for map rendering.

**Why store `raw_geocode` as JSONB?**
Nominatim returns more data than the schema captures (postal codes, districts, administrative boundaries, etc.). Storing the raw response means that data is never lost — if a new field becomes useful later, it can be extracted from `raw_geocode` without re-geocoding.

---

### media

One row per photo or video.

```sql
CREATE TABLE media (
    id                BIGSERIAL PRIMARY KEY,
    owner_id          BIGINT NOT NULL REFERENCES users (id),
    trip_id           BIGINT REFERENCES trips     (id) ON DELETE SET NULL,
    location_id       BIGINT REFERENCES locations (id) ON DELETE SET NULL,

    google_photos_id  TEXT UNIQUE,
    filename          TEXT NOT NULL,
    storage_key       TEXT NOT NULL,
    file_size_bytes   BIGINT,
    media_type        media_type NOT NULL,

    captured_at       TIMESTAMPTZ,
    imported_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    lat               DOUBLE PRECISION,
    lng               DOUBLE PRECISION,
    altitude_m        DOUBLE PRECISION,

    camera_make       TEXT,
    camera_model      TEXT,
    width_px          INTEGER,
    height_px         INTEGER,
    duration_secs     DOUBLE PRECISION,

    note              TEXT,
    note_updated_at   TIMESTAMPTZ,

    enrichment_status enrichment_status NOT NULL DEFAULT 'pending',

    deleted           BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at        TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Why `storage_key` instead of a full URL?**
Storing a full S3 URL locks the schema to a specific bucket and region. If the bucket is renamed, migrated, or moved to a different region, every row needs updating. A `storage_key` is a stable relative path — the full URL is constructed at query time by the `StorageBackend`. This also makes local development seamless: the same key resolves to a local file path in development and an S3 URL in production.

**Why `ON DELETE SET NULL` for `trip_id` and `location_id`?**
If a trip is soft-deleted, its media should not be deleted with it — the photos still exist and belong to the user. `SET NULL` preserves the media row while detaching it from the deleted trip. The user can re-assign it or it appears in an "unorganized" view.

**Why `captured_at` from Takeout `photoTakenTime` and not EXIF `DateTimeOriginal`?**
Takeout's `photoTakenTime` is a UTC Unix timestamp — timezone-aware and reliable. EXIF `DateTimeOriginal` is a local time string with no timezone information (`"2023:12:15 08:32:10"`). If the camera clock was set to the wrong timezone (common when traveling internationally), the EXIF timestamp is wrong. The Takeout timestamp is Google's canonical record of when the photo was taken and is always preferred.

**Why store `lat/lng` on `media` AND have a separate `locations` table?**
Raw GPS coordinates on `media` are the ground truth from the photo itself. The `locations` table is a derived, geocoded view of those coordinates. Keeping both means: (1) the original GPS is never lost even if geocoding fails, (2) the pipeline can re-geocode without losing raw data, and (3) map rendering can use raw coordinates for clustering while display uses the human-readable place name from `locations`.

**Why `NULL` for GPS instead of `0.0, 0.0`?**
In Takeout JSON, `0.0, 0.0` means "no GPS data" — not coordinates in the Gulf of Guinea. Storing `NULL` makes this distinction unambiguous in SQL. `WHERE lat IS NOT NULL` correctly finds photos with GPS; `WHERE lat = 0` would incorrectly find both no-GPS photos and any photo accidentally taken at the origin.

**Why `note` on `media` instead of a separate `media_notes` table?**
Personal notes are one-to-one with media — one photo, one diary entry. A separate table would add a join to every media query for no benefit at this cardinality. If notes ever become versioned or collaborative, they can be extracted into a table at that point.

#### Trip assignment — two-level strategy

1. **Date-range (automatic):** pipeline sets `trip_id` when `captured_at` falls within `trips.start_date..end_date`. Covers ~95% of cases.
2. **Explicit overrides:** `trip_media_overrides` handles edge cases.

```sql
CREATE TABLE trip_media_overrides (
    trip_id   BIGINT NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    media_id  BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    action    TEXT NOT NULL DEFAULT 'include'
              CHECK (action IN ('include', 'exclude')),
    added_by  BIGINT REFERENCES users (id),
    added_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (trip_id, media_id)
);
```

**Why a separate overrides table instead of a flag on `media`?**
A flag like `force_trip_id` on `media` only allows one override per photo. The overrides table allows the same photo to be explicitly included in one trip and excluded from another — which matters for shared trips where different users may have different views of where a photo belongs. It also keeps the override logic queryable and auditable.

---

### flights

One row per leg. JFK → LHR → NRT = two rows.

```sql
CREATE TABLE flights (
    id                   BIGSERIAL PRIMARY KEY,
    owner_id             BIGINT NOT NULL REFERENCES users (id),
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
    deleted              BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (owner_id, flight_number, scheduled_departure)
);
```

**Why store both scheduled and actual times?**
Scheduled times come from booking confirmations. Actual times may differ due to delays. For year-in-review stats (total time in the air, longest flight), actual times are more accurate. For trip reconstruction (when did you arrive?), actual arrival matters. Storing both preserves the full picture without data loss.

**Why `raw_source_data JSONB`?**
Flight data comes from multiple sources (Gmail parsing, TripIt API, manual CSV). Each source returns different fields. Storing the raw payload preserves everything even if the schema doesn't capture it yet — useful for debugging parsing bugs and for extracting new fields later without re-fetching.

---

### hotels

```sql
CREATE TABLE hotels (
    id           BIGSERIAL PRIMARY KEY,
    owner_id     BIGINT NOT NULL REFERENCES users (id),
    trip_id      BIGINT REFERENCES trips (id) ON DELETE SET NULL,
    name         TEXT NOT NULL,
    city         TEXT,
    country      TEXT,
    country_code CHAR(2),
    lat          DOUBLE PRECISION,
    lng          DOUBLE PRECISION,
    check_in     DATE NOT NULL,
    check_out    DATE NOT NULL,
    booking_ref  TEXT,
    source       booking_source NOT NULL DEFAULT 'manual',
    raw_source_data JSONB,
    deleted      BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT hotels_dates_valid CHECK (check_out > check_in)
);
```

**Why `DATE` instead of `TIMESTAMPTZ` for check_in/check_out?**
Hotel bookings are always calendar dates, not times. A guest checks in on December 15 — the exact time is irrelevant to the journal. Using `DATE` avoids timezone ambiguity: `TIMESTAMPTZ` for a hotel check-in would require knowing the hotel's local timezone, which is not always available from booking data.

---

### tags

AI-generated and manually added tags per media item.

```sql
CREATE TYPE tag_source AS ENUM ('ai', 'manual');

CREATE TABLE tags (
    id           BIGSERIAL PRIMARY KEY,
    media_id     BIGINT NOT NULL REFERENCES media (id) ON DELETE CASCADE,
    tag          TEXT NOT NULL,
    confidence   REAL CHECK (confidence BETWEEN 0 AND 1),
    model        TEXT,
    source       tag_source NOT NULL DEFAULT 'ai',
    verified     BOOLEAN,
    verified_at  TIMESTAMPTZ,
    verified_by  BIGINT REFERENCES users (id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (media_id, tag, model)
);
```

**Why `verified BOOLEAN` with three states (NULL/TRUE/FALSE)?**
Two states (verified/unverified) lose information. `NULL` means "not yet reviewed" — the user has not seen this tag. `TRUE` means confirmed. `FALSE` means explicitly rejected. This distinction matters: an unreviewed tag should appear in a review queue; a rejected tag should be hidden permanently; a confirmed tag should be weighted higher in search. Without the three-state distinction, you cannot tell the difference between "never seen" and "deliberately rejected."

**Why `UNIQUE (media_id, tag, model)`?**
The pipeline can be re-run with an updated CLIP model. The constraint ensures the same (media, tag, model) combination is never duplicated — re-running uses `ON CONFLICT DO UPDATE` to refresh the confidence score. Different models can produce the same tag for the same photo and coexist as separate rows.

**Tag states:**

| source | verified | Meaning |
|--------|----------|---------|
| `ai` | `NULL` | AI suggested, not yet reviewed |
| `ai` | `TRUE` | AI suggested, human confirmed |
| `ai` | `FALSE` | AI suggested, human rejected |
| `manual` | `TRUE` | Human added directly |

**Why is this human-in-the-loop pattern important?**
AI tagging is probabilistic — CLIP may tag a temple photo as "museum" or miss "cherry blossom" entirely. A travel journal's value comes from accuracy. The review queue lets the user correct errors over time. Verified tags become a higher-quality signal than raw AI output for search and year-in-review stats. This is the standard pattern for ML systems in production: model output + human review + feedback loop.

---

### embeddings

```sql
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

CREATE INDEX idx_embeddings_hnsw_clip
    ON embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    WHERE model = 'clip-vit-b32';
```

**Why one row per (media_id, model) instead of one row per media?**
Embedding models improve over time. Storing by model means you can re-embed with a newer model and keep the old vectors for comparison — without a schema migration. It also allows running multiple models side by side (CLIP for image search, a text embedding model for caption search) with separate HNSW indexes.

**Why HNSW over IVFFlat?**
HNSW (Hierarchical Navigable Small World) requires no training step, supports incremental inserts, and delivers better recall. IVFFlat requires a training run on the full dataset before it can be used — impractical for an ongoing ingestion pipeline where new photos are added continuously.

**Why a partial index per model?**
A single HNSW index over all embeddings would mix vectors from different models. Distance comparisons between vectors from different models are meaningless — CLIP vectors and OpenAI embedding vectors live in completely different spaces. Partial indexes (`WHERE model = 'clip-vit-b32'`) ensure the ANN search only compares vectors from the same model.

---

### captions

AI-generated captions. Personal diary notes live on `media.note` instead.

```sql
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
```

**Why `prompt_version`?**
Caption quality depends heavily on the prompt. As the prompt is refined, you want to re-generate captions without losing the old ones — both for A/B comparison and as a safety net if the new prompt produces worse results. Bumping `prompt_version` creates a new row; the old caption is preserved and still queryable.

**Why `tokens_used`?**
Claude API costs money. Tracking tokens per caption enables cost monitoring, budget enforcement, and optimization (e.g., identifying that resizing images to 1568px before encoding saves 30% of tokens). Without this, API costs are a black box.

**AI caption vs personal note — why separate:**

| | AI Caption | Personal Note (`media.note`) |
|---|---|---|
| Source | Claude API | User |
| Content | What is in the photo | Your memory or story |
| Example | "People eating at a night market stall" | "First tteokbokki with Jenny — found this by accident" |
| Editable | No (versioned by prompt_version) | Yes, any time |
| Overwritable by pipeline | Yes (on prompt_version bump) | Never |

---

## AI Enrichment Pipeline

### Tools (free, local-first)

| Task | Tool | Reason |
|---|---|---|
| Tagging | CLIP ViT-B/32 (`open-clip-torch`) | Open source, runs on CPU, no API cost, dual-use for embeddings |
| Embeddings | CLIP ViT-B/32 (same model) | Same inference pass as tagging — no extra compute |
| Captions | Claude API (`claude-sonnet-4-6`) | Best-in-class vision + language model; free credits to start |
| Geocoding | Nominatim via `geopy` | Free, no API key required, sufficient for personal use |

**Why CLIP over Google Vision API or Rekognition?**
Google Vision API and AWS Rekognition cost money per image. For 28,000 photos, that becomes significant. CLIP runs entirely locally with no per-call cost. It is also dual-purpose — the same model produces both tags (zero-shot classification) and embeddings (vector search) in one inference pass, making it twice as efficient.

**Why Claude for captions instead of an open-source vision model?**
Open-source vision models (LLaVA, Moondream) require significant GPU memory to run at acceptable speed. Claude produces higher-quality, more natural captions without local GPU requirements. The free API credits are sufficient for a single trip, and the cost per image is low enough that it remains affordable as the library grows.

### Enrichment status state machine

```
pending → processing → done
                    ↘ failed
```

- `pending`: inserted, not yet processed
- `processing`: worker claimed the row (set before any API calls)
- `done`: all enrichment steps completed successfully
- `failed`: unrecoverable error — logged, skipped, does not block the pipeline

**Why set `processing` before API calls?**
If the process crashes after an API call but before writing the result, the row would stay in `processing`. Without the pre-claim step, a restart would re-process the row and make a duplicate API call (wasting money and potentially creating duplicate DB rows). With it, a restart finds the row in `processing`, applies the 10-minute timeout, resets it to `pending`, and retries cleanly.

### Human-in-the-loop

The UI exposes a tag review queue per trip:
- Approve / reject AI tags
- Add manual tags the AI missed
- Edit or add personal notes per photo

Verified tags (`verified = TRUE`) take precedence in search ranking and year-in-review stats.

---

## Search

### Vector search (primary)

Semantic search using CLIP embeddings. The query string is encoded with CLIP into a 512-d vector, then nearest neighbors are retrieved via pgvector HNSW index.

```sql
SELECT m.id, m.filename, 1 - (e.embedding <=> $1::vector) AS similarity
FROM   embeddings e
JOIN   media m ON m.id = e.media_id
WHERE  e.model = 'clip-vit-b32'
  AND  m.deleted = FALSE
ORDER  BY e.embedding <=> $1::vector
LIMIT  20;
```

**Why vector search as primary?**
Keyword search requires users to remember exact tags or words that appear in captions. Vector search understands meaning — "rainy covered market" finds the right photos even if none are tagged "rain" or "market." For a travel journal spanning 10+ years and 28,000 photos, the ability to search by feeling and memory rather than exact keywords is the killer feature that justifies the architecture.

### Full-text search (secondary)

PostgreSQL `tsvector` on captions, notes, and tags. No extra infrastructure — built into Postgres.

```sql
ALTER TABLE media ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(note, ''))
    ) STORED;
```

**Why full-text in addition to vector?**
Vector search is powerful but imprecise for exact lookups. Searching for "Seoul" should return all photos tagged or captioned with "Seoul" — not photos that semantically resemble Seoul. Full-text is faster and more accurate for known keywords. The two approaches complement each other: vector search for fuzzy memory-based queries, full-text for precise lookups.

**Combined search strategy:**
1. Run vector search → top 50 candidates
2. Re-rank by full-text relevance if the query contains recognized keywords
3. Apply filters: trip, year, country, verified tags

---

## API Layer

### Phase 1 (MVP)

Streamlit accesses the DB directly via SQLAlchemy async sessions. No API layer.

**Why skip the API layer for MVP?**
The MVP is a personal tool for one user running locally. Adding a FastAPI layer at this stage would double the code to write without adding value — there are no other clients, no auth requirements, no rate limiting concerns. The goal is to get to a working product fast. The schema is designed so the API layer can be added cleanly later.

### Phase 2 (Next.js + multi-user)

FastAPI sits between all clients and the DB.

```
Next.js / Mobile / Third-party
            ↓
          FastAPI
            ↓
       PostgreSQL + S3
```

**Why FastAPI?**
FastAPI generates OpenAPI docs automatically (useful for portfolio and future third-party integrations), has first-class async support (matches the async SQLAlchemy setup already in place), and is the standard choice for Python API layers in AI/ML products. It also handles JWT auth, rate limiting, and request validation with minimal boilerplate.

**Key endpoints (planned):**
```
GET  /trips                      list user's trips
GET  /trips/{id}/media           paginated media for a trip
GET  /trips/{id}/timeline        day-by-day timeline view
GET  /media/{id}                 single media item + enrichment
POST /media/{id}/note            add/edit personal note
POST /media/{id}/tags            add manual tag
PUT  /media/{id}/tags/{tag_id}   verify/reject AI tag
GET  /search?q=...               vector + full-text search
GET  /year-review/{year}         year-in-review stats
GET  /globe/heatmap              lat/lng density data for globe view
```

---

## Multi-tenancy & Shared Trips

### Data ownership
Every user-owned row has `owner_id` referencing `users`. At the API layer, every query is scoped to the requesting user's `owner_id`. Users cannot access other users' data unless explicitly granted through `trip_members`.

**Why enforce ownership at the DB query level, not just the API level?**
API-level enforcement can be bypassed by bugs — a missing auth check, a misconfigured middleware, or a direct DB query during debugging. Query-level `WHERE owner_id = $user_id` is a second line of defense. For a product handling personal photos, defense in depth on data access is non-negotiable.

### Shared trips
- `trip_members` table defines who has access to a trip and at what role
- `contributor` role can add their own media to a shared trip
- The trip timeline merges all contributors' media sorted by `captured_at`
- Each media item retains its `owner_id` — contributors own their own photos
- The trip owner controls who can contribute vs view

**Why contributors retain ownership of their own photos?**
In a shared trip between partners, each person's photos are personal. If the shared trip is deleted or the partnership ends, each person should be able to take their photos with them. Retaining `owner_id` on each media item ensures this is always possible — the data is never ambiguously co-owned.

### Globe view
- Each user sees only their own footprint heatmap by default
- Optionally merge with a partner's heatmap to show shared destinations
- Built in Next.js with Deck.gl `GlobeView` + `HeatmapLayer`
- Click behavior on hotspot: TODO — open trip timeline or photo grid for that location

---

## Engineering Principles

### Extensibility
- Schema changes via Alembic migrations — `schema.sql` is the initial state only
- New enrichment models: add a row to `embeddings` or `tags` with a new `model` value — no schema change
- New storage backends: implement `StorageBackend` protocol — no pipeline changes
- New AI providers: swap at the `enrichment/` module level — DB schema is provider-agnostic
- New data sources (Apple Photos, TripIt): add a new `ingest/` module — pipeline runner is source-agnostic

### Scalability path

| Dimension | Now (MVP) | Later (Phase 2) |
|---|---|---|
| Media storage | Local filesystem | S3 |
| Job queue | DB `enrichment_status` column | Celery + Redis / SQS |
| Enrichment concurrency | Sequential | Parallel workers, configurable |
| Users | Single user | Multi-tenant via FastAPI + JWT |
| UI | Streamlit | Next.js + Deck.gl globe |
| CLIP inference | CPU, local | GPU server or managed embedding API |
| Data source | Google Takeout | Google Photos API + Apple Photos + TripIt |

Each transition in this table is independent — they can be adopted one at a time, in any order, without affecting the others. That is the value of the abstractions built into the initial design.
