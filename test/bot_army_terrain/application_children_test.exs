defmodule BotArmyTerrain.ApplicationChildrenTest do
  @moduledoc """
  Every process the bot needs at runtime is in the supervision tree.

  The Consumer was not. It had a subject list, a registry registration, and handlers for
  `bot.army.terrain.command.ingest`, `.import_cards` and `.generate_cards` — and no line in
  `application.ex` started it, so on the host those three publishes went to a subject with
  no subscriber and disappeared. A publish to nobody is not an error: it is silence, which
  is why it survived. This test is the regression guard for the *class* of defect: the
  broker-facing children are named in one function, and the consumer is one of them.
  """
  use ExUnit.Case
  @moduletag :core

  alias BotArmyTerrain.Application

  test "the command consumer is supervised in a release" do
    modules = Application.nats_children(:prod) |> Enum.map(&elem(&1, 0))

    assert BotArmyTerrain.NATS.Consumer in modules,
           "the Consumer subscribes to bot.army.terrain.command.*; without it those commands are dropped"
  end

  test "the reads and events are supervised beside it" do
    modules = Application.nats_children(:prod) |> Enum.map(&elem(&1, 0))

    assert BotArmyTerrain.NATS.RequestHandler in modules
    assert BotArmyTerrain.NATS.EventHandler in modules
  end

  test "tests boot no broker children" do
    assert Application.nats_children(:test) == []
  end
end
