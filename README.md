# Footprint

An AI-powered personal travel journal that transforms 10+ years of travel media into structured, searchable, and shareable memories.

## What It Does

- **Ingests** photos and videos from Google Photos (via Takeout or API), enriched with GPS, timestamps, flights, and hotel stays
- **Enriches** media with AI: auto-tagging, semantic search, and LLM-generated captions and narratives
- **Summarizes** travel history into year-in-review reports — countries, cities, distance, highlights, and patterns
- **Generates** content for YouTube vlogs and Instagram Reels from trip media

## Tech Stack

| Layer | Tools |
|---|---|
| Pipeline | Python |
| Storage | PostgreSQL + pgvector |
| Vision | Google Vision API / CLIP |
| LLM | Claude API |
| Video | FFmpeg |
| UI (personal) | Streamlit |
| UI (product) | Next.js |

## Architecture

```
Google Photos (Takeout / API)
        ↓
  Batch Downloader + EXIF/JSON Parser
        ↓
  PostgreSQL  ←→  pgvector (embeddings)
        ↓
  AI Enrichment (vision tagging · embeddings · Claude narratives)
        ↓
  Streamlit UI (personal) → Next.js (product)
```

## Roadmap

| Phase | Focus |
|---|---|
| Week 1 | Data pipeline — ingestion, EXIF parsing, DB schema, flights/hotels |
| Week 2 | AI enrichment — tagging, embeddings, semantic search, captions |
| Week 3 | Personal UI — timeline, search, trip detail, year-in-review |
| Week 4 | Polish + personal stories |
| Week 5 | Demo prep |

## Docs

- [`PRD.md`](PRD.md) — product requirements and user stories
- [`DESIGN.md`](DESIGN.md) — data schema, system architecture, API design
- [`ROADMAP.md`](ROADMAP.md) — phased milestones
- [`CHANGELOG.md`](CHANGELOG.md) — what shipped in each phase
