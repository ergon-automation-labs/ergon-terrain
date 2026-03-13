# Terrain Architecture Planning — Phase 1

**Status:** Phase 1 Architecture Definition
**Last Updated:** 2026-03-13
**Owner:** Bot Army Core Team

---

## Executive Summary

Terrain is a knowledge worker learning platform built around context-aware spaced repetition. Phase 1 delivers a single-user MVP that ingests markdown/CSV content, generates flashcards, and manages review scheduling. It's designed for clean extraction into a multi-tenant product in Phase 2+.

**Core principle:** Content you ingest is embedded, chunked, and connected to your active context through NATS and the LLM Proxy.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Terrain Phase 1 MVP                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Ingestion   │    │   Card Gen   │    │  Reviews     │  │
│  ├──────────────┤    ├──────────────┤    ├──────────────┤  │
│  │ CSV, MD      │ -> │ LLM Proxy    │ -> │ SRS Engine   │  │
│  │ File Watcher │    │ Embeddings   │    │ Scheduling   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                    │                    │          │
│         └────────────────────┴────────────────────┘          │
│                        │                                     │
│                   ┌────▼─────┐                               │
│                   │ NATS      │ ◄──────────────────────      │
│                   │ Publisher │  bot.army.terrain.*          │
│                   └──────────┘                               │
│                        │                                     │
│         ┌──────────────┴──────────────┐                      │
│         ▼                             ▼                      │
│    ┌────────────┐             ┌────────────────┐             │
│    │ PostgreSQL │             │ Phoenix LiveView│             │
│    │ pgvector   │             │ (Manual Review) │             │
│    │ (chunk+vec)│             └────────────────┘             │
│    └────────────┘                                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Phase 1 Scope

### What's In Scope (MVP)

- ✅ Ingest CSV and markdown content
- ✅ Chunk content into 200-500 token pieces
- ✅ Embed chunks via LLM Proxy
- ✅ Store vectors with pgvector
- ✅ Generate flashcards from chunks via LLM
- ✅ Implement SM-2 spaced repetition scheduling
- ✅ Manual review via LiveView card flip UI
- ✅ Track management (create, list, pause)
- ✅ Basic progress tracking

### What's Out of Scope (Phase 2+)

- ❌ Idle detection and ambient encounters
- ❌ Context matching (requires Context Broker)
- ❌ Dungeon mode and gamification
- ❌ Notion/Obsidian advanced parsing
- ❌ Multi-user support and auth
- ❌ Export functionality
- ❌ Smart Mirror / phone delivery

---

## Database Schema (PostgreSQL)

### tracks

```sql
CREATE TABLE terrain.tracks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  name VARCHAR(255) NOT NULL,
  description TEXT,
  color VARCHAR(7),           -- hex color for UI
  icon VARCHAR(100),
  status VARCHAR(50) DEFAULT 'active', -- active|paused|archived
  card_count INTEGER DEFAULT 0,
  chunk_count INTEGER DEFAULT 0,
  xp INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_tracks_user_id ON terrain.tracks(user_id);
CREATE INDEX idx_tracks_status ON terrain.tracks(status);
```

### content_chunks

```sql
CREATE TABLE terrain.content_chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  track_id UUID NOT NULL REFERENCES terrain.tracks(id) ON DELETE CASCADE,
  source_type VARCHAR(50) NOT NULL,   -- csv|markdown|notion|obsidian
  source_path VARCHAR(500),
  content TEXT NOT NULL,
  content_hash VARCHAR(64),           -- sha256 for dedup
  metadata JSONB DEFAULT '{}',        -- heading, tags, frontmatter
  embedding_vector vector(1536),      -- text-embedding-3-small dimension
  embedding_model VARCHAR(100),       -- model name for tracking
  embedded_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_chunks_track_id ON terrain.content_chunks(track_id);
CREATE INDEX idx_chunks_content_hash ON terrain.content_chunks(content_hash);
CREATE INDEX idx_chunks_embedded_at ON terrain.content_chunks(embedded_at);
CREATE INDEX idx_chunks_vector ON terrain.content_chunks USING ivfflat (embedding_vector vector_cosine_ops);
```

### cards

```sql
CREATE TABLE terrain.cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  track_id UUID NOT NULL REFERENCES terrain.tracks(id) ON DELETE CASCADE,
  chunk_id UUID REFERENCES terrain.content_chunks(id) ON DELETE SET NULL,
  front TEXT NOT NULL,
  back TEXT NOT NULL,
  card_type VARCHAR(50) DEFAULT 'basic',  -- basic|cloze|definition
  generation_model VARCHAR(100),          -- which model generated it

  -- SRS Fields (SM-2)
  ease_factor FLOAT DEFAULT 2.5,
  interval_days INTEGER DEFAULT 1,
  repetitions INTEGER DEFAULT 0,
  next_review_at TIMESTAMP DEFAULT NOW(),
  last_reviewed_at TIMESTAMP,
  state VARCHAR(50) DEFAULT 'new',        -- new|learning|review|suspended

  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_cards_track_id ON terrain.cards(track_id);
CREATE INDEX idx_cards_next_review_at ON terrain.cards(next_review_at);
CREATE INDEX idx_cards_state ON terrain.cards(state);
CREATE UNIQUE INDEX idx_cards_front_hash ON terrain.cards(track_id, md5(front));
```

### review_sessions

```sql
CREATE TABLE terrain.review_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  track_id UUID REFERENCES terrain.tracks(id) ON DELETE SET NULL,
  trigger VARCHAR(50),                   -- idle|manual|scheduled
  cards_shown INTEGER DEFAULT 0,
  cards_correct INTEGER DEFAULT 0,
  xp_earned INTEGER DEFAULT 0,
  duration_seconds INTEGER,
  started_at TIMESTAMP DEFAULT NOW(),
  ended_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_sessions_user_id ON terrain.review_sessions(user_id);
CREATE INDEX idx_sessions_track_id ON terrain.review_sessions(track_id);
CREATE INDEX idx_sessions_started_at ON terrain.review_sessions(started_at);
```

### review_results

```sql
CREATE TABLE terrain.review_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
  session_id UUID NOT NULL REFERENCES terrain.review_sessions(id) ON DELETE CASCADE,
  card_id UUID NOT NULL REFERENCES terrain.cards(id) ON DELETE CASCADE,
  quality INTEGER NOT NULL,              -- 0-5 (SM-2 score)
  response_ms INTEGER,
  reviewed_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_results_session_id ON terrain.review_results(session_id);
CREATE INDEX idx_results_card_id ON terrain.review_results(card_id);
CREATE INDEX idx_results_user_id ON terrain.review_results(user_id);
```

---

## Module Structure

```
lib/bot_army_terrain/
├── application.ex              # OTP supervision tree
├── repo.ex                     # Ecto repo (terrain schema)
│
├── ingestion/
│   ├── csv_parser.ex           # Parse CSV format (front, back, track, tags)
│   ├── markdown_parser.ex      # Parse markdown into sections
│   ├── ingestion_worker.ex     # Orchestrator: parse → chunk → embed → store
│   └── chunk_builder.ex        # Implements 200-500 token chunking
│
├── embeddings/
│   ├── embedding_client.ex     # Publish llm.request.embed to LLM Proxy
│   └── chunk_store.ex          # pgvector storage and similarity queries
│
├── cards/
│   ├── card_generator.ex       # LLM Proxy: chunk → flashcard candidates
│   ├── card_store.ex           # CRUD and query operations
│   └── srs_engine.ex           # Pure SM-2 implementation (no side effects)
│
├── tracks/
│   ├── track_store.ex          # Create, list, update, pause tracks
│   └── track_schema.ex         # Ecto schema
│
├── progress/
│   └── progress_tracker.ex     # Record review results, update SRS
│
├── nats/
│   └── consumer.ex             # Subscribe to bot.army.terrain.command.ingest
│
└── schemas/
    ├── track.ex                # Ecto schema: tracks
    ├── content_chunk.ex        # Ecto schema: content_chunks
    ├── card.ex                 # Ecto schema: cards
    ├── review_session.ex       # Ecto schema: review_sessions
    └── review_result.ex        # Ecto schema: review_results
```

---

## NATS Subject Taxonomy (Phase 1)

### Commands (TUI → Terrain)

| Subject | Payload | Response |
|---------|---------|----------|
| `bot.army.terrain.command.ingest` | `{source_type: "csv", path: "/path/to/deck.csv"}` | `bot.army.terrain.event.ingest_complete` |
| `bot.army.terrain.command.review` | `{track_id?: uuid}` (manual review trigger) | Streams cards via LiveView |

### Events (Terrain → System)

| Subject | Trigger | Payload |
|---------|---------|---------|
| `bot.army.terrain.event.chunk_ingested` | Each chunk stored | `{chunk_id, source_path, track_id, token_count}` |
| `bot.army.terrain.event.cards_generated` | Cards created from chunk | `{chunk_id, cards: [{id, front, back}]}` |
| `bot.army.terrain.event.ingest_complete` | All chunks/cards done | `{track_id, chunk_count, card_count, duration_ms}` |
| `bot.army.terrain.event.review_result` | User submits quality score | `{card_id, quality: 0-5, response_ms, interval_days}` |

---

## Key Implementation Details

### Chunking Strategy

- **Target chunk size:** 200-500 tokens
- **Overlap:** 50-token overlap between adjacent chunks to preserve context
- **Heading preservation:** Include heading context in metadata, not in chunk body
- **Deduplication:** Use SHA256 hash of normalized content for idempotent re-import

### Embedding Flow

```
IngestionWorker.ingest_file(path)
  → ChunkBuilder.chunk_content(text, metadata)
  → Enum.each(chunks, fn chunk ->
      EmbeddingClient.embed(chunk.text)
      → Gnat.request(:gnat, "llm.request.embed", {...})
      → ChunkStore.save_with_vector(chunk, vector)
    end)
```

### SM-2 Algorithm (SrsEngine)

Pure functions — no side effects, fully testable:

```elixir
def update(card, quality) when quality in 0..5 do
  case quality do
    q when q < 3 ->
      # Failed: reset to learning
      {ease_factor, 1, 0, add_days(1)}

    3 ->
      # Hard: normal progression
      new_ease = card.ease_factor - 0.14
      {new_ease, card.interval + 1, card.reps + 1, add_days(card.interval + 1)}

    4 ->
      # Good: standard progression
      new_ease = card.ease_factor
      {new_ease, card.interval * new_ease, card.reps + 1, add_days(card.interval * new_ease)}

    5 ->
      # Easy: accelerated progression
      new_ease = card.ease_factor + 0.1
      {new_ease, card.interval * new_ease * 1.3, card.reps + 1, add_days(card.interval * new_ease * 1.3)}
  end
end
```

### Re-import Idempotency

**Problem:** User updates CSV deck, re-runs import. Must not lose SRS state.

**Solution:** Match cards by `(track_id, sha256(front))`:

```elixir
def upsert_card(track_id, front, back, tags) do
  case CardStore.get_by_front_hash(track_id, front) do
    {:ok, existing_card} ->
      # Card exists: preserve SRS fields, optionally update back/tags
      CardStore.update(existing_card, %{back: back, tags: tags})

    {:error, :not_found} ->
      # New card: insert with default SRS state
      CardStore.create(%{track_id, front, back, tags, state: "new"})
  end
end
```

---

## LiveView UI (Phase 1 MVP)

### Card Review Screen

- **Card Flip:** Hidden back, click to reveal
- **Quality Input:** Buttons for 0-5 grade (or 1-4 for SM-2)
- **Auto-Submit:** Saves result, updates SRS, loads next card
- **Progress:** Shows "X of Y" cards in session

### Track List Screen

- **Track Cards:** Name, card count, last review date, status badge
- **Actions:** Create new, pause, archive, view details
- **Stats:** Total XP, cards due, days since last review

---

## Critical Dependencies

| Dependency | Purpose | Phase 1 Impact |
|-----------|---------|----------------|
| `bot_army_runtime` | NATS connection, Telemetry | Required |
| `bot_army_core` | NATS envelope decoding | Required |
| LLM Proxy (NATS) | Embeddings, card generation | Required |
| pgvector extension | Vector storage | Required (Postgres config) |
| Phoenix LiveView | Manual review UI | Required |
| Ecto | Database ORM | Required |

---

## Testing Strategy

### Unit Tests (No DB)

- **SrsEngine:** All SM-2 boundaries, quality 0-5, interval calculations
- **ChunkBuilder:** Tokenization, overlap logic, heading preservation
- **CsvParser:** Format validation, escape handling
- **MarkdownParser:** Heading extraction, section splitting

### Integration Tests (With Mocks)

- **IngestionWorker:** CSV → chunks → embed → store flow
- **EmbeddingClient:** Gnat.request mock, timeout handling
- **CardGenerator:** Chunk → card generation mock
- **ProgressTracker:** Review result → SRS update → next_review_at calculation

### Manual Testing (E2E)

1. Drop a CSV into ingest directory
2. Verify chunks appear in database with vectors
3. Generate 3-5 cards from first chunk
4. Review a card with quality=4
5. Verify next_review_at is calculated correctly per SM-2

---

## Deployment Checklist

- [ ] PostgreSQL with pgvector extension installed
- [ ] `terrain` schema created
- [ ] All migrations run
- [ ] NATS server running (via bot_army_runtime)
- [ ] LLM Proxy running and accessible
- [ ] Terrain bot starts: `mix phx.server`
- [ ] LiveView accessible at `http://localhost:4000/review`
- [ ] Sample CSV imports successfully

---

## Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Embedding model changes | Vector incompatibility | Lock embedding model in config; document re-embed process |
| Chunk size inconsistency | Inconsistent learning | Unit tests on ChunkBuilder; fixed token limit |
| SM-2 calculation bugs | Wrong scheduling | 100% test coverage on SrsEngine; hardcoded min/max intervals |
| NATS timeout during embed | Chunks stuck pending | Retry with exponential backoff; mark chunks `embedding_pending` |
| Duplicate chunks | Unnecessary re-embedding | SHA256 hash unique constraint + upsert logic |
| Postgres unavailable | Data loss | All in-progress data cached in ETS; commit on reconnect |

---

## Success Criteria (Phase 1 Complete)

✅ Drop a CSV with 10 rows (front, back, track) → get 10 cards
✅ Cards embed within 30 seconds
✅ Review card with quality=4 → next_review_at is 4+ days away
✅ Review card with quality=2 → next_review_at is 1 day away
✅ Re-import same CSV → existing card SRS state preserved
✅ Can create new track and assign cards to it
✅ All unit tests pass, 80%+ coverage
✅ LiveView card flip works, quality submission works

---

## Next Steps (After Phase 1)

1. **Context Integration** — Subscribe to `context.state.current`, match chunks by vector similarity
2. **Idle Detection** — Subscribe to idle signal, schedule encounters
3. **Notion/Obsidian parsing** — Extend ingestion pipeline
4. **Gamification** — XP system, overworld map
5. **Export** — Portable user data package for Phase 2 migration

---

## References

- **North Star:** `TERRAIN_NORTH_STAR.md` (authoritative for all phases)
- **NATS Contracts:** `LEARNING_STACK_NORTH_STAR.md` (full subject taxonomy)
- **SM-2 Algorithm:** https://supermemo.com/en/blog/application-of-a-spaced-repetition-algorithm-sm-2-in-learning-english-vocabulary
- **pgvector Docs:** https://github.com/pgvector/pgvector
- **Phoenix LiveView:** https://hexdocs.pm/phoenix_live_view

