defmodule BotArmyTerrain.Repo.Migrations.AddHookToCards do
  @moduledoc """
  A card can carry a hook: the vivid line that makes the answer stick.

  Front and back are the question and the answer. The hook is the image, story or wordplay
  told after the answer is revealed, and the tip of the day draws it. It is optional and
  nullable, so every existing card is unchanged.
  """
  use Ecto.Migration

  def change do
    alter table(:cards, prefix: "terrain") do
      add(:hook, :text)
    end
  end
end
