defmodule Mix.Tasks.Terrain.Ads.Lint do
  @shortdoc "Check story interstitials against the canon and placement rules"

  @moduledoc """
  Run the same checks the selector uses before a creative is allowed near her:

      mix terrain.ads.lint

  A trailer must have a next chapter, match its lesson exactly, and leak none of its answers.
  A recap must restate the lesson of the chapter it follows. A sponsor's lesson must be at
  least two chapters old. Every file must carry the fields the panel renders.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    case BotArmyTerrain.Ads.lint() do
      {:ok, count} ->
        Mix.shell().info("Checked #{count} creative(s): no issues.")

      {:error, errors} ->
        Enum.each(errors, &Mix.shell().error("  " <> &1))
        Mix.raise("#{length(errors)} problem(s) in the interstitial catalogue")
    end
  end
end
