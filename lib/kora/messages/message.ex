defmodule Kora.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :role, :string
    field :content, :string
    # JSON list of tool calls
    field :tool_calls, {:array, :map}, default: []

    belongs_to :agent, Kora.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:agent_id, :role, :content, :tool_calls])
    |> validate_required([:agent_id, :role])
  end
end
