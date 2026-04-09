# Product Requirements Document — Footprint

## Overview

Footprint is an AI-powered personal travel journal that ingests 10+ years of travel media from Google Photos, enriches it with structured data and AI, and produces searchable timelines, year-in-review summaries, and shareable content.

**Phase 1 target**: personal tool for one user  
**Phase 2 target**: multi-user product others can connect to their own Google Photos

---

## Problem Statement

Travel memories are scattered across Google Photos, email confirmations, and mental notes. There's no single place that:
- Connects photos to where you were, how you got there, and where you stayed
- Surfaces patterns and highlights across years of travel
- Lets you search memories semantically ("that beach in Thailand, 2022")
- Helps turn raw media into polished content

---

## Users

### Phase 1
- Solo user with 10+ years of travel media in Google Photos, building a personal tool and portfolio demo

### Phase 2
- Travelers who want an AI-powered journal from their own Google Photos library

---

## User Stories

### Data Ingestion
- As a user, I can connect my Google Photos account so my travel media is automatically imported
- As a user, I can import a Google Takeout export so I get full GPS and metadata without manual effort
- As a user, I can upload a CSV of my flights so they are joined to my photo timeline
- As a user, I can manually add hotel stays so my full trip context is captured

### Trip Timeline
- As a user, I can view a timeline of a trip with photos, videos, and a map of locations visited
- As a user, I can see each day of a trip broken down by location, media, and activities
- As a user, I can read AI-generated captions for photos that describe what's happening

### Search
- As a user, I can search my entire photo library semantically (e.g. "sunset over water") and get relevant results
- As a user, I can filter trips by country, year, or travel companion

### Year-in-Review
- As a user, I can generate a year-in-review report that includes:
  - Countries and cities visited
  - Total distance traveled and flights taken
  - Nights away from home
  - Highlights and "firsts"
  - Patterns in my travel style
  - An LLM-generated narrative summary

### Globe View (Next.js — Phase 2)
- As a user, I can see a spinnable 3D globe with a heatmap showing every location I've visited
- TODO: define click behavior on a hotspot (open trip timeline? photo grid for that location?)

### Content Generation
- As a user, I can generate a vlog-style video from a trip's media using FFmpeg
- As a user, I can export short-form clips suitable for Instagram Reels

---

## Success Metrics

| Metric | Target |
|---|---|
| Single trip ingested end-to-end | Week 1 |
| Semantic search returns relevant results | Week 2 |
| Year-in-review generated for 2024 | Week 3 |
| Full personal library ingested | Week 4 |
| Demo-ready for FDE interviews | Week 5 |

---

## Out of Scope (Phase 1)

- Social sharing or public profiles
- Mobile app
- Real-time sync with Google Photos
- Multi-user accounts
- Monetization
