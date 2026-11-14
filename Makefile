SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)

.PHONY: test-handlers test-stores test-nats test-integration test-full setup help deps test dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs push-and-publish

help:
	@echo "Terrain Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail terrain_bot log with grc (brew install grc; make -C .. install-grc)"
	@echo "  make seed-decks      - Seed decks from priv/seeds/tip_decks.json [NATS_PORT=4222 DRY_RUN=1]"
	@echo "  make learn-card      - File one card the system wants her to learn: FRONT= BACK= [HOOK= DECK=Noticed]"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

_compile-impl:
	@LOG_FILE="/tmp/compile-terrain-$$(date +%s).log"; \
	echo "Compiling terrain and logging to $$LOG_FILE..."; \
	set -o pipefail; \
	$(MIX) compile 2>&1 | tee "$$LOG_FILE"; \
	rc=$$?; \
	echo "✓ Compilation log: $$LOG_FILE"; \
	exit $$rc

deps:
	$(MIX) deps.get

test:
	$(MIX) test

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/terrain_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/terrain_bot/"
	@echo ""

publish-release: release
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then echo "Failed to resolve version from mix.exs"; exit 1; fi; \
	TARBALL=terrain_bot-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel terrain_bot/; \
	echo "✓ Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Terrain Bot Elixir release v$$VERSION." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	echo ""

	@$(MAKE) publish-deploy-event TARGET=mini
push-and-publish:
	@git push && $(MAKE) publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# Seed decks (priv/seeds/tip_decks.json) through terrain's own subjects. Idempotent: existing
# decks and cards are kept, missing hooks filled in. Defaults to the dev broker; production
# needs NATS_PORT=4222 said out loud. DRY_RUN=1 lists what would be created.
SEED_NATS_PORT ?= $(or $(NATS_PORT),4223)
.PHONY: seed-decks
seed-decks:
	@python3 scripts/seed_decks.py --server nats://localhost:$(SEED_NATS_PORT) $(if $(FILE),--file $(FILE),) $(if $(DRY_RUN),--dry-run,)

# One card, filed by the system itself (an agent noticing a fuzzy detail). DECK defaults to Noticed.
.PHONY: learn-card
learn-card:
	@test -n "$(FRONT)" -a -n "$(BACK)" || { echo 'Usage: make learn-card FRONT="..." BACK="..." [HOOK="..."] [DECK=Noticed] [NATS_PORT=4222]'; exit 1; }
	@python3 scripts/seed_decks.py --server nats://localhost:$(SEED_NATS_PORT) --deck "$(or $(DECK),Noticed)" --front "$(FRONT)" --back "$(BACK)" $(if $(HOOK),--hook "$(HOOK)",) $(if $(DRY_RUN),--dry-run,)


# Shared targets (push, credo, pre-push-cleanup, bump-version, git-push).
# Defined once in bot_army_infra so they cannot drift per repo.
BOT_ARMY_COMMON_MK := $(abspath $(CURDIR)/../bot_army_infra/make/common.mk)
ifeq ($(wildcard $(BOT_ARMY_COMMON_MK)),)
$(warning bot_army_infra not found at $(BOT_ARMY_COMMON_MK) - shared targets unavailable)
else
include $(BOT_ARMY_COMMON_MK)
endif
