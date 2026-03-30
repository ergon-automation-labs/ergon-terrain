# Lesson Import Guide

## Directory Structure

Organize lessons by track in `/app/lessons/`:

```
/app/lessons/
├── elixir_bootcamp/
│   ├── npcs.yaml
│   ├── pattern_matching.yaml
│   ├── guard_clauses.yaml
│   └── list_operations.yaml
├── greek_basics/
│   ├── npcs.yaml
│   ├── alphabet.yaml
│   └── common_letters.yaml
└── ...
```

Each track directory name becomes the track name (underscores replaced with spaces).

## Path Mapping In Deployed Environments

When imports are triggered from a surface running in a container, paths often use
`/app/lessons/...`. Terrain bot can remap that prefix using:

- `TERRAIN_LESSONS_ROOT=/absolute/host/path/to/terrain_gameshow`

Example:

- requested path: `/app/lessons/elixir_bootcamp`
- resolved path: `${TERRAIN_LESSONS_ROOT}/elixir_bootcamp`

## NPC Definitions (npcs.yaml)

Define NPCs at the track level in `npcs.yaml`:

```yaml
npc_players:
  - name: "Alice"
    personality: "competitive"
  - name: "Bob"
    personality: "mentor"
  - name: "Carol"
    personality: "skeptic"
```

### Available Personalities

- **`competitive`** - Tries to beat the player, congratulates/taunts based on answer
- **`mentor`** - Encouraging, educational tone, guides learning
- **`skeptic`** - Questions answers, asks "why?", seeks deeper understanding
- **`enthusiast`** - Excited, energetic reactions to both right and wrong answers
- **`comedian`** - Makes jokes, uses humor in responses
- **`neutral`** - Factual, no emotional reactions, just states facts
- **`expert`** - Technical depth, explains the underlying principles
- **`cheerleader`** - Supportive, celebrates effort and progress

## Lesson YAML Format

Each `.yaml` or `.yml` file in a track directory becomes one lesson:

```yaml
# Required fields
title: "Pattern Matching Basics"
difficulty: "beginner"  # beginner, intermediate, advanced
content: |
  Detailed explanation of the concept.
  Can be multiple paragraphs.
  Markdown formatting is supported.

# Quiz
quiz_question: "What is the match operator in Elixir?"
quiz_options:
  - "="          # Index 0
  - ":="         # Index 1
  - "=="         # Index 2
  - "match()"    # Index 3
quiz_correct_index: 0  # Correct answer is at index 0

# Host dialogue (gameshow banter)
host_intro: |
  "Alright, this one trips up developers from other languages..."

host_correct: |
  "Exactly! The = operator is the match operator in Elixir.
  It doesn't assign—it unifies both sides of the expression.
  That's what makes pattern matching so powerful!"

host_wrong: |
  "Not quite! While := and == exist in Elixir,
  = is the one that does the real magic.
  Remember: it's unification, not assignment."

# Optional fields
external_link: "https://hexdocs.pm/elixir/pattern-matching"
```

## Import from TUI

In the TUI, press `i` to open the import dialog:

1. Enter a directory path (defaults to `/app/lessons`)
2. The importer will:
   - Scan for subdirectories (tracks)
   - Read `npcs.yaml` from each track
   - Import all `.yaml`/`.yml` files as lessons
   - Queue embeddings for content

## Example: Complete Track

```
/app/lessons/elixir_bootcamp/
├── npcs.yaml
│   content:
│     npc_players:
│       - name: "Alice"
│         personality: "competitive"
│       - name: "Bob"
│         personality: "mentor"
│
├── 01_pattern_matching.yaml
├── 02_guard_clauses.yaml
├── 03_list_operations.yaml
└── 04_recursion.yaml
```

When imported:
- Track created: "Elixir Bootcamp"
- 4 lessons created (one per file)
- NPCs available: Alice (competitive), Bob (mentor)
- All lessons can reference these NPCs for banter
