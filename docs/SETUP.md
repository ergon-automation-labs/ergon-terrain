# Getting Started with bot_army_terrain

Terrain is **its own git repository**. Clone it, run `make setup`, and push to `main` to trigger the pre-push hook (build + GitHub release); Jenkins deploys from the release.

This guide walks you through setting up Terrain Bot for local development.

## Prerequisites

- **Elixir 1.14+** — [elixir-lang.org](https://elixir-lang.org)
- **Erlang/OTP 25+** — Installed with Elixir
- **PostgreSQL with pgvector** — For terrain schema and embeddings
- **Git** — Version control
- **GitHub CLI** (`gh`) — For releasing to GitHub

## Quick Start

### 1. Install Dependencies and Hooks

```bash
make setup
```

This will:

- Initialize git if needed
- Run `mix deps.get`
- Install git hooks for pre-push validation (`core.hooksPath = git-hooks`)
- Create and migrate the test database

### 2. Set Up Environment Variables

Create a `.env` file from the template for local development and testing:

```bash
cp .env.example .env
```

Edit `.env` to match your local setup:

```bash
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USER=postgres
DATABASE_PASSWORD=postgres
DATABASE_NAME=ergon_terrain_dev
```

`.env` is gitignored and should never be committed.

### 3. Set Up Test Database

`make setup` runs `make setup-db`, which creates the test DB and runs migrations. If you need to reset:

```bash
make reset-db
```

### 4. Verify Setup

```bash
mix compile
mix test
```

Tests require Postgres (with pgvector extension). If you see database errors, ensure the DB exists and `make setup-db` or `make reset-db` has been run.

## Development Workflow

### Code Changes

```bash
# Format code
make format

# Linter
make credo

# Tests
make test
```

### Pushing to GitHub

When you push to `main`, the pre-push hook:

1. Runs `mix compile`, `mix credo`, `mix test`
2. Builds the OTP release (`terrain_bot`)
3. Creates a tarball and publishes a GitHub release
4. Allows the push to continue

Jenkins can then deploy from the new release.

### Manual Release

```bash
make release          # Build release locally
make publish-release  # Package and publish to GitHub
```

## Key Commands

```bash
make help             # Show all commands
make setup            # deps + git hooks + test DB
make setup-hooks      # Install git hooks only (core.hooksPath = git-hooks)
make setup-db         # Create and migrate test database
make reset-db         # Drop and recreate test database
make test             # Run tests
make credo            # Run linter
make check            # test + credo + dialyzer
make format           # Format code
make clean            # Remove build artifacts
```

## Release Configuration

Release name in `mix.exs`: `terrain_bot`. Deployed to `/opt/ergon/releases/terrain_bot/` via Jenkins.

## Configuration

- **Development:** `.env` (see `.env.example`).
- **Production:** Salt pillar and launchd environment (see `bot_army_infra`).

## Deployment

1. Push to `main` → pre-push builds release and publishes to GitHub.
2. Jenkins downloads the release and runs Salt (`bots.terrain_bot`).
3. Migrations run via `terrain_bot/bin/terrain_bot eval 'BotArmyTerrain.Release.migrate()'`.

## This repo

- **Standalone git repo:** Clone (or add as submodule), then `make setup` and `make setup-hooks` if hooks aren’t already active.
- **Remote:** Point `origin` at your Terrain repo (e.g. `ergon-automation-labs/ergon-terrain`). Update `GITHUB_REPO` in `Jenkinsfile` to match so Jenkins downloads releases from the right place.

## Related Documentation

- `README.md` — Terrain overview and NATS/ingestion
- North star docs (in parent monorepo or copied into this repo): `TERRAIN_NORTH_STAR.md`, `LEARNING_STACK_NORTH_STAR.md`
