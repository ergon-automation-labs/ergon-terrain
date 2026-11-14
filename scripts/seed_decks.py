#!/usr/bin/env python3
"""Seed decks from priv/seeds/*.json through the bot's own subjects. Idempotent.

A deck that exists is reused; a card whose front is already on the deck is left alone,
except that a missing hook is filled in. Nothing is ever removed.

Usage: seed_decks.py --server nats://localhost:4223 [--file priv/seeds/tip_decks.json] [--dry-run]
       seed_decks.py --server ... --deck Noticed --front "..." --back "..." [--hook "..."]

The second form is how the system teaches on its own: an agent that notices a detail is
fuzzy files one card, and the tip of the day brings it round.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path


NOTICED = "Cards the system added on its own, because a detail looked fuzzy or kept coming up."


def ask(server: str, subject: str, payload: dict) -> dict:
    out = subprocess.run(
        ["nats", "request", "--server", server, "--no-context", "--raw", "--timeout", "5s",
         subject, json.dumps(payload)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"{subject}: no answer from {server}: {out.stderr.strip()}")
    body = json.loads(out.stdout)
    if not body.get("ok"):
        raise RuntimeError(f"{subject} refused: {body.get('error')} ({body.get('code')})")
    return body.get("data", {})


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--server", required=True)
    p.add_argument("--file", default=str(Path(__file__).resolve().parents[1] / "priv/seeds/tip_decks.json"))
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--deck")
    p.add_argument("--front")
    p.add_argument("--back")
    p.add_argument("--hook")
    a = p.parse_args()

    if a.deck or a.front or a.back:
        if not (a.deck and a.front and a.back):
            sys.exit("one card needs --deck, --front and --back")
        card = {"front": a.front, "back": a.back}
        if a.hook:
            card["hook"] = a.hook
        seed = {"decks": [{"name": a.deck, "description": NOTICED if a.deck == "Noticed" else None, "cards": [card]}]}
    else:
        seed = json.loads(Path(a.file).read_text())
    tracks = {t["name"]: t["id"] for t in ask(a.server, "terrain.tracks.list", {})["tracks"]}
    made = {"decks": 0, "cards": 0, "hooks": 0, "kept": 0}

    for deck in seed["decks"]:
        name = deck["name"]
        if name not in tracks:
            if a.dry_run:
                print(f"+ deck {name} ({len(deck['cards'])} cards)")
                made["decks"] += 1
                made["cards"] += len(deck["cards"])
                continue
            track = ask(a.server, "terrain.tracks.create", {"name": name, "description": deck.get("description")})["track"]
            tracks[name] = track["id"]
            made["decks"] += 1

        existing = {c["front"]: c for c in ask(a.server, "terrain.cards.list", {"track_id": tracks[name]})["cards"]}
        for card in deck["cards"]:
            have = existing.get(card["front"])
            if have is None:
                if not a.dry_run:
                    ask(a.server, "terrain.cards.create", {"track_id": tracks[name], **card})
                print(f"+ {name}: {card['front'][:60]}")
                made["cards"] += 1
            elif card.get("hook") and not have.get("hook"):
                if not a.dry_run:
                    ask(a.server, "terrain.cards.update", {"card_id": have["id"], "hook": card["hook"]})
                print(f"~ {name}: hook for {card['front'][:50]}")
                made["hooks"] += 1
            else:
                made["kept"] += 1

    verb = "would create" if a.dry_run else "created"
    print(f"{verb}: {made['decks']} decks, {made['cards']} cards, {made['hooks']} hooks · unchanged: {made['kept']}")


if __name__ == "__main__":
    main()
