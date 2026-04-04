defmodule BotArmyTerrain.Schemas.GameState do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "terrain"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_states" do
    field :track_id, :binary_id
    field :game_json, :string
    field :dojo_json, :string
    field :status, :string, default: "pending"
    field :generated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(game_state, attrs) do
    game_state
    |> cast(attrs, [:track_id, :game_json, :dojo_json, :status, :generated_at, :tenant_id, :user_id])
    |> validate_required([:track_id, :status])
    |> unique_constraint(:track_id)
  end
end
