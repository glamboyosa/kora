defmodule Kora.CostLedger.CostEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cost_ledger" do
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :decimal

    belongs_to :agent, Kora.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cost_entry, attrs) do
    cost_entry
    |> cast(attrs, [:agent_id, :model, :prompt_tokens, :completion_tokens, :cost_usd])
    |> validate_required([:agent_id, :model, :prompt_tokens, :completion_tokens])
  end
end
