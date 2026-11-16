defmodule BotArmyTerrain.AdsLintTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyTerrain.Ads

  setup do
    dir =
      Path.join(System.tmp_dir!(), "terrain_ads_lint_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    Application.put_env(:bot_army_terrain, :ads_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:bot_army_terrain, :ads_dir)
    end)

    {:ok, dir: dir}
  end

  test "the authored catalogue passes the lint" do
    assert {:ok, count} = Ads.lint()
    assert count >= 3
  end

  test "a body that leaks the next chapter's answer is refused", %{dir: dir} do
    creative = %{
      "id" => "bad-trailer",
      "kind" => "trailer",
      "slot" => "story_boundary",
      "air_after" => "ch1",
      "lesson" => "The door decides the row.",
      "title" => "Next: The Door Decides the Row",
      "body" => "One card. That is all you need.",
      "tagline" => %{"prompt" => "Where does a default decide for you?", "max_chars" => 120}
    }

    File.write!(Path.join(dir, "bad.json"), Jason.encode!(creative))

    assert {:error, errors} = Ads.lint()
    assert Enum.any?(errors, &(&1 =~ "leaks an answer"))
  end

  test "a trailer with no next chapter is refused", %{dir: dir} do
    creative = %{
      "id" => "last-trailer",
      "kind" => "trailer",
      "slot" => "story_boundary",
      "air_after" => "ch2",
      "lesson" => "The door decides the row.",
      "title" => "Next",
      "body" => "There is no next page.",
      "tagline" => %{"prompt" => "Who holds the pen?", "max_chars" => 100}
    }

    File.write!(Path.join(dir, "last.json"), Jason.encode!(creative))

    assert {:error, errors} = Ads.lint()
    assert Enum.any?(errors, &(&1 =~ "needs a next chapter"))
  end
end
