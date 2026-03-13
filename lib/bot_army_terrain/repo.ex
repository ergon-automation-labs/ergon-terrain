defmodule BotArmyTerrain.Repo do
  @moduledoc """
  Ecto Repository for Terrain.

  Tables live in the `terrain` Postgres schema (prefix on all tables).
  Uses pgvector for content_chunks.embedding_vector.
  """

  use Ecto.Repo,
    otp_app: :bot_army_terrain,
    adapter: Ecto.Adapters.Postgres
end
