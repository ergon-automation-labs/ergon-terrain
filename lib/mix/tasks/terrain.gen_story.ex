defmodule Mix.Tasks.Terrain.GenStory do
  @moduledoc """
  Build a playable chapter from a plan and the cards it tests.

  Usage:
    mix terrain.gen_story --plan priv/story/plans/chapter_02.json \\
      --cards /tmp/the_system.json --out priv/story/chapter_02.json

  Options:
    --plan   Chapter plan (prose + which card each scene tests)
    --cards  The deck's cards, as returned by `terrain.cards.list`
             (either the reply's `data` object or its `cards` list)
    --out    Where to write the chapter

  This is offline on purpose: no model and no request path. It compiles a reviewed plan into
  data, validates the graph, and writes the same JSON the Story plays.
  """

  use Mix.Task

  alias BotArmyTerrain.StoryBuilder

  @shortdoc "Compile a story chapter plan into playable JSON"

  @impl Mix.Task
  def run(args) do
    case parse(args) do
      {:ok, plan_path, cards_path, out_path} ->
        plan = plan_path |> File.read!() |> Jason.decode!()
        cards = cards_path |> File.read!() |> Jason.decode!() |> cards()

        case StoryBuilder.build(plan, cards) do
          {:ok, chapter} ->
            File.write!(out_path, Jason.encode!(chapter, pretty: true) <> "\n")
            Mix.shell().info("Wrote #{out_path} (#{map_size(chapter["scenes"])} scenes)")

          {:error, reasons} ->
            Mix.raise("The plan cannot make a chapter:\n  " <> Enum.join(reasons, "\n  "))
        end

      :help ->
        Mix.shell().info(@moduledoc)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp parse(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [plan: :string, cards: :string, out: :string, help: :boolean]
      )

    cond do
      opts[:help] -> :help
      invalid != [] -> {:error, "unknown options: #{inspect(invalid)}"}
      !opts[:plan] -> {:error, "--plan is required"}
      !opts[:cards] -> {:error, "--cards is required"}
      !opts[:out] -> {:error, "--out is required"}
      true -> {:ok, opts[:plan], opts[:cards], opts[:out]}
    end
  end

  defp cards(%{"data" => %{"cards" => cards}}) when is_list(cards), do: cards
  defp cards(%{"cards" => cards}) when is_list(cards), do: cards
  defp cards(cards) when is_list(cards), do: cards
  defp cards(_other), do: []
end
