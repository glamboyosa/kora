defmodule Kora.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, {:array, :map}, default: []
    field :tool_call_id, :string
    field :tool_name, :string

    belongs_to :agent, Kora.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:agent_id, :role, :content, :tool_calls, :tool_call_id, :tool_name])
    |> validate_required([:agent_id, :role])
  end
end
