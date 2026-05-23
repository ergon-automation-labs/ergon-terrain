defmodule BotArmyTerrain.GraphRepo do
  @moduledoc "Ecto repo for Apache AGE graph queries (terrain bot)."
  use Ecto.Repo,
    otp_app: :bot_army_terrain,
    adapter: Ecto.Adapters.Postgres

  require Logger

  def init(_, opts) do
    opts =
      Keyword.put(opts, :after_connect, fn conn ->
        try do
          Postgrex.query!(conn, "LOAD 'age'", [])
          Postgrex.query!(conn, "SET search_path = ag_catalog, \"$user\", public", [])
        rescue
          e ->
            Logger.warning(
              "[BotArmyTerrain.GraphRepo] AGE extension unavailable or error during init: #{inspect(e)}"
            )
        end
      end)

    {:ok, opts}
  end
end
