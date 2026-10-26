defmodule BotArmyTerrain.Repo.Migrations.SoftDeleteCards do
  @moduledoc """
  A removed card can be put back.

  Her word, 2026-10-26: *"give her the undo for building/maintaining her own decks"*. Removal
  was the one press on the management page with no way back — the row was gone and the review
  history with it — so the shelf could only be maintained by someone willing to be wrong
  permanently. This makes the removal reversible without inventing a history table:

    * `deleted_at` (null = on the deck) is the whole record of the removal.
    * **Every read filters it**, so a removed card is invisible to the due list, the deck list,
      the counts, and `cards.similar` — from outside, removal still looks like removal.

  The unique index has to move with it. `idx_cards_front_hash` on `(track_id, md5(front))`
  would otherwise refuse a *new* card with the same front as a card that was removed, so a
  removal would quietly poison the deck's vocabulary — the card would be gone and the words
  unusable. The index becomes partial over the rows that are actually on the deck, which is
  also the only set a "duplicate front" refusal was ever about.
  """
  use Ecto.Migration

  def up do
    alter table(:cards, prefix: "terrain") do
      add(:deleted_at, :utc_datetime_usec)
    end

    drop_if_exists(
      index(:cards, [:track_id, "md5(front)"],
        prefix: "terrain",
        name: :idx_cards_front_hash
      )
    )

    create(
      unique_index(:cards, [:track_id, "md5(front)"],
        prefix: "terrain",
        name: :idx_cards_front_hash,
        where: "deleted_at IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:cards, [:track_id, "md5(front)"],
        prefix: "terrain",
        name: :idx_cards_front_hash
      )
    )

    create(
      unique_index(:cards, [:track_id, "md5(front)"],
        prefix: "terrain",
        name: :idx_cards_front_hash
      )
    )

    alter table(:cards, prefix: "terrain") do
      remove(:deleted_at)
    end
  end
end
