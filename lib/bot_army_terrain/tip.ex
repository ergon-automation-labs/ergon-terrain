defmodule BotArmyTerrain.Tip do
  @moduledoc """
  The tip of the day: one card, from one deck, for one morning.

  The deck rotates by day, so each deck gets its morning in turn. Inside the deck, a card
  already reviewed since `since` stays the tip (so the card does not change under her after
  she answers it); otherwise the most overdue card; otherwise one picked by the day.

  The bot owns the words the card is told in (`voice/1`): the announcer line, the prompt to
  answer before flipping, and the line each press earns. A surface draws them and maps nothing.
  Text may carry three marks the surface renders: `**weight**`, `*motion*`, `!!impact!!`.
  """

  @type pick :: %{track: map, card: map, answered: boolean} | nil

  @announce [
    "**Attention, Crawler.** The System has prepared *one* piece of knowledge for you. It is free. Nothing down here is free. !!Take it anyway.!!",
    "Morning, monkey. I, the **magnificent**, have picked a fact small enough even for you. *You're welcome.*",
    "!!Battle stations.!! One contact on the plot, Captain. Range *closing*. **Weapons free.**",
    "**Achievement pending:** answer one card before coffee. Reward: *undisclosed*. Probably smugness.",
    "The fleet is in orbit and the tactical display is *quiet*. **Perfect time** for one drill.",
    "!!Loot box detected.!! Rarity: **Common**. Contents: one fact. Opening it is *your move*.",
    "Look, I'd explain everything, but your brain has a *load limit*. So — **one** thing. Today.",
    "**Wake up, Crawler.** The floor *collapses* eventually. Learn something on the way down."
  ]

  @flip [
    "Say your answer — out loud or in your head — **then** flip.",
    "Commit to a guess. *Any* guess. **Then** flip.",
    "Fire first, check the sensors after. **Answer, then flip.**"
  ]

  @knew [
    "!!New Achievement:!! **Didn't Even Blink.** Reward: this card goes *further away*. That is the prize.",
    "!!Direct hit.!! Target destroyed. It won't be back for **days**.",
    "Huh. Not bad, for a monkey. **Logged.**",
    "**Confirmed kill.** The tactical officer *nods once*. That's a lot, from her."
  ]

  @not_yet [
    "**Good.** That is exactly the one worth meeting again. It comes back *tomorrow* — no charge.",
    "Missed shot — but the sensors **recorded the target**. Next pass, it's *yours*.",
    "The System notes your effort. The System is *impressed you tried*. **Back tomorrow.**",
    "That's how memory works: you **reach**, it *slips*, and the reach is what builds it.",
    "Wow. A filthy monkey, *staring at a card*, **not knowing**. I'll put it in the museum. !!Back tomorrow.!!",
    "The System has updated your profile: *\"Confident. Wrong.\"* **Tomorrow** we fix one of those.",
    "I would explain it again, but I explained it *on the back of the card*. **Read the back, monkey.**",
    "Crawler, the audience *is laughing*. It's fine. They laugh at everyone. !!Next pass is yours.!!"
  ]

  @later "Card stowed. *The ship will still be here.*"

  @doc """
  Choose the tip. `decks` is a list of `{track, cards}` in the order tracks are listed.
  `now` decides what is due; `since` is the start of her day.
  """
  @spec choose([{map, [map]}], Date.t(), DateTime.t(), DateTime.t()) :: pick
  def choose(decks, %Date{} = date, %DateTime{} = since, %DateTime{} = now) do
    decks = Enum.reject(decks, fn {_track, cards} -> cards == [] end)

    case decks do
      [] ->
        nil

      _ ->
        {track, cards} = Enum.at(decks, rem(day(date), length(decks)))
        {card, answered} = pick_card(cards, date, since, now)
        %{track: track, card: card, answered: answered}
    end
  end

  defp pick_card(cards, date, since, now) do
    answered =
      cards
      |> Enum.filter(&after?(Map.get(&1, :last_reviewed_at), since))
      |> Enum.max_by(&Map.get(&1, :last_reviewed_at), DateTime, fn -> nil end)

    due =
      cards
      |> Enum.filter(fn c ->
        Map.get(c, :state) != "suspended" and not after?(Map.get(c, :next_review_at), now)
      end)
      |> Enum.min_by(&Map.get(&1, :next_review_at), DateTime, fn -> nil end)

    cond do
      answered -> {answered, true}
      due -> {due, false}
      true -> {Enum.at(cards, rem(day(date), length(cards))), false}
    end
  end

  defp after?(nil, _), do: false
  defp after?(%DateTime{} = t, ref), do: DateTime.compare(t, ref) == :gt

  defp day(date), do: Date.to_gregorian_days(date)

  @doc "The words the card is told in, chosen by the day so a reload does not change them."
  @spec voice(Date.t()) :: map
  def voice(%Date{} = date) do
    d = day(date)

    %{
      "announce" => pick(@announce, d),
      "flip" => pick(@flip, d),
      "knew" => pick(@knew, d),
      "not_yet" => pick(@not_yet, d),
      "later" => @later
    }
  end

  defp pick(list, d), do: Enum.at(list, rem(d, length(list)))
end
