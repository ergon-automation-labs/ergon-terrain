# Bot Army Terrain

**Standalone git repo.** Clone this repository (or add it as a submodule) and run `make setup`; push to `main` triggers the pre-push hook (build + publish release) and Jenkins deploys.

Terrain is the **content pipeline** for the learning stack: it ingests markdown and CSV decks, chunks and embeds content (pgvector), and organizes material into **tracks**. The Dungeon Quiz Show and other surfaces use Terrain for track listing and overworld; the Learning Bot owns cards and FSRS scheduling.

- **North star:** [docs/north_star_docs/TERRAIN_NORTH_STAR.md](../docs/north_star_docs/TERRAIN_NORTH_STAR.md) (in parent monorepo or copy into this repo’s `docs/`)
- **Umbrella (NATS, data models):** [docs/north_star_docs/LEARNING_STACK_NORTH_STAR.md](../docs/north_star_docs/LEARNING_STACK_NORTH_STAR.md)

## What Terrain does

- **Tracks** — Create and list learning tracks (e.g. "Elixir Bootcamp", "Greek Bootcamp"). Tables live in the `terrain` Postgres schema.
- **Content chunks** — Ingest CSV (front, back, track, tags) or markdown; store chunks with optional pgvector embeddings. Re-import is idempotent (match by `content_hash`); existing stats in Learning Bot are never overwritten.
- **NATS** — Subscribes to `bot.army.terrain.command.ingest`. Payload: `source_type` (e.g. `csv`), `path_or_blob_ref` (file path).

## Setup

This repo is self-contained. After cloning:

```bash
cd bot_army_terrain   # or your clone path
make setup            # deps.get + git hooks + test DB
cp .env.example .env  # then edit .env for DB/NATS
```

- **Requirements:** Elixir 1.14+, Postgres with [pgvector](https://github.com/pgvector/pgvector).
- Create DB and run migrations if not using `make setup-db`:

  ```bash
  createdb ergon_terrain_dev
  mix ecto.migrate
  ```

- Optional: set `BOT_ARMY_TERRAIN_DB_*` or `DATABASE_*` in `.env` for URL/auth.

## Usage

- **Cards (what a review surface reads):** `bot.army.terrain.command.import_cards` takes
  `{"path": "/path/to/deck.csv"}` and creates the track *and* its cards immediately — no
  model involved. The columns are `front,back,card_type,track`; a quoted field may contain
  commas but not newlines (`CsvParser` is line-based). Cards are what
  `terrain.cards.due` / `terrain.review.submit` work on; `command.ingest` only makes chunks.

- **The starter deck.** `priv/decks/money_making.csv` ships inside the release, so a host
  that has the release has the deck:

  ```bash
  # on the host, against the broker that host's terrain is on
  nats pub bot.army.terrain.command.import_cards \
    "{\"path\": \"$(ls -d /opt/ergon/releases/terrain_bot/releases/*/lib/bot_army_terrain-*/priv/decks/money_making.csv | tail -1)\"}"
  ```

  Import is additive per row and cheap to repeat; it does not touch review state that
  already exists. The deck lives in the release rather than in `/etc` or `/opt/ergon/decks`
  because it is *content*, and content that is only on one host's disk is content that a
  redeploy silently deletes.

- **CLI ingest (CSV):**

  ```elixir
  BotArmyTerrain.Ingestion.IngestionWorker.ingest_csv("/path/to/elixir_bootcamp_deck.csv")
  ```

- **NATS:** Publish to `bot.army.terrain.command.ingest` with JSON body, e.g.:

  ```json
  { "payload": { "source_type": "csv", "path_or_blob_ref": "/path/to/deck.csv" } }
  ```

- **List tracks (for Dungeon/overworld):**

  ```elixir
  BotArmyTerrain.TrackStore.list_tracks()
  BotArmyTerrain.TrackStore.list_tracks(status: "active")
  ```

## Project layout

- `lib/bot_army_terrain/` — Application, Repo, TrackStore, ChunkStore
- `lib/bot_army_terrain/schemas/` — Track, ContentChunk (Ecto schemas, prefix `terrain`)
- `lib/bot_army_terrain/ingestion/` — CsvParser, IngestionWorker
- `lib/bot_army_terrain/nats/` — Consumer (commands), RequestHandler (reads and writes)

## Release

```bash
mix release terrain_bot
```

Run with NATS and Postgres available; the consumer will reconnect if NATS is temporarily down.
