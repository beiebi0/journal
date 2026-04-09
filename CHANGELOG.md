# CHANGELOG

Work log for the Footprint project. Most recent entries at the top.

---

## [Unreleased] — Week 1: Data Pipeline

### In Progress
- Reviewing PRD and DESIGN.md before writing code

### Planned
- Step 1: Config + DB layer (`config.py`, `db/connection.py`, `db/models.py`)
- Step 2: Takeout JSON parser (`metadata/takeout_json.py`)
- Step 3: EXIF extractor (`metadata/exif.py`)
- Step 4: Takeout ingester + normalizer (`ingest/takeout.py`, `metadata/normalizer.py`)
- Step 5: Geocoder (`enrichment/geocoder.py`)
- Step 6: CLIP tagging + embeddings (`enrichment/vision.py`, `enrichment/embeddings.py`)
- Step 7: Claude captions (`enrichment/captions.py`)
- Step 8: Pipeline runner (`pipeline/runner.py`)

---

## 2026-04-09

### Added
- `DESIGN.md` — full system architecture and data schema with reasoning behind every design decision
  - Storage abstraction (`StorageBackend` protocol — local filesystem now, S3 later)
  - Multi-tenancy schema (`users` table, `owner_id` on all user-owned tables)
  - Shared trips (`trip_members` with viewer / contributor / admin roles)
  - Human-in-the-loop tag review (`tags.verified`, `tags.source`)
  - AI captions vs personal notes separated by design
  - Soft-delete everywhere (`deleted`, `deleted_at` on all user-facing tables)
  - Vector search (pgvector HNSW) + full-text search (PostgreSQL `tsvector`)
  - FastAPI layer planned for Phase 2
  - Scalability path table (local → cloud, sequential → parallel, single-user → multi-tenant)

### Updated
- `PRD.md` — added TODOs:
  - Globe view click behavior (open trip timeline or photo grid)
  - Activity tracking from Garmin (GPX/FIT) and Strava (API) — hiking, running, cycling

---

## 2026-04-08

### Added
- `README.md` — project overview, tech stack, architecture diagram, roadmap
- `CLAUDE.md` — guidance for Claude Code sessions on this repo
- `PRD.md` — product requirements, user stories, success metrics, out of scope
- `schema.sql` — initial PostgreSQL schema with pgvector (media, trips, locations, flights, hotels, tags, embeddings, captions)
- `pyproject.toml` — Python project config (hatchling, dependencies, ruff, mypy, pytest)
- `.env.example` — all environment variables with descriptions
- `.gitignore`
- `scripts/init_db.py` — one-shot DB schema initializer
- `src/footprint/` — Python package skeleton (db, ingest, metadata, enrichment, pipeline, ui modules)
- `tests/` — test directory

### Decisions made
- **Data source**: Google Takeout for MVP (Google Photos API deliberately omits GPS)
- **Enrichment stack**: CLIP (local, free) for tagging + embeddings; Claude API for captions; Nominatim for geocoding
- **Storage**: local filesystem for MVP, S3 for Phase 2 — abstracted behind `StorageBackend` protocol
- **UI**: Streamlit for MVP, Next.js + Deck.gl for Phase 2 (including spinnable globe with heatmap)
- **Pipeline**: stateless, queue-backed, idempotent — designed to scale from laptop to server
- **S3 over GCS**: better interview transferability; abstraction makes it swappable

### Research completed (via subagents)
- Google Photos API: confirmed GPS is deliberately omitted; `baseUrl` expires in 60 min; rate limit 10k req/day
- Google Takeout JSON: `photoTakenTime` (not `creationTime`) for timestamps; `geoData` preferred over `geoDataExif`; `title` field for filename matching; `0.0, 0.0` means no GPS
- PostgreSQL schema: full table design with pgvector HNSW indexes, soft-delete, audit triggers
- Python project structure: `src` layout, `pyproject.toml` + `requirements.txt`, `pydantic-settings` for config
