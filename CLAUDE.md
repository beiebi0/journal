# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Footprint** is an AI-powered personal travel journal. It ingests 10+ years of travel media (images, videos) from Google Photos, enriches it with AI (vision tagging, semantic search, LLM captions), and produces structured trip timelines, year-in-review summaries, and vlog/reel content.

Primary goal: working MVP usable as a portfolio demo for Forward Deployed Engineer (FDE) interviews.

## Planned Tech Stack

- **Pipeline**: Python
- **Storage**: PostgreSQL + pgvector (semantic search)
- **Vision tagging**: Google Vision API or CLIP
- **LLM / narrative generation**: Claude API
- **Embeddings**: for semantic search over photos/trips
- **Video assembly**: FFmpeg
- **Early UI**: Streamlit → Next.js for eventual product
- **Auth / API clients**: `google-auth`, `requests`, `Pillow` / `exifread`

## Data Sources

- **Google Photos** (primary) — images + videos; Google Takeout exports companion `.json` per photo with GPS + timestamps (preferred over the API for EXIF data, since the API doesn't expose EXIF directly)
- **Apple Photos** — manual export with "Location Information" enabled
- **Flights** — Gmail, TripIt, or manual CSV
- **Hotels** — manual records

Key decision: parse both EXIF from image files *and* the Takeout companion `.json` for location/time metadata.

## Architecture (Planned)

```
Google Photos (Takeout or API)
        ↓
  Batch Downloader + EXIF/JSON Parser
        ↓
  PostgreSQL DB  ←→  pgvector (embeddings)
        ↓
  AI Enrichment Layer
    ├── Vision model (tagging, scene detection)
    ├── Embedding model (semantic search)
    └── Claude API (captions, narratives, year-in-review)
        ↓
  Streamlit UI (personal) → Next.js (product)
```

Pipeline stages are parallelizable: batch download and batch tagging can run concurrently.

## Phased Roadmap

- **Week 1**: Data pipeline — Google Photos ingestion, EXIF parsing, DB schema, join with flights/hotels
- **Week 2**: AI enrichment — vision tagging, embeddings, semantic search, LLM captions
- **Week 3**: Personal UI — Streamlit timeline, search, trip detail, year-in-review
- **Week 4**: Polish + personal stories + refinement
- **Week 5**: Buffer + demo prep

Start with one trip end-to-end before scaling to the full library.

## Git Workflow

```
main (stable/demo-ready) → dev → feature/...
```

- Feature branches: `feature/google-photos-ingestion`, `feature/ai-enrichment`, etc.
- Required repo docs: `PRD.md`, `DESIGN.md`, `ROADMAP.md`, `CHANGELOG.md`

## Commands

Commands will be added here as the project is built out. Expected entries:

```bash
# Install dependencies (once pyproject.toml / requirements.txt exists)
pip install -r requirements.txt

# Run pipeline (placeholder)
python -m footprint.pipeline

# Run tests
pytest

# Run Streamlit UI
streamlit run app/main.py
```
