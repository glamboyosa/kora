defmodule Kora.ToolResults.ToolResult do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_results" do
    field :tool_name, :string
    # JSON
    field :input, :map
    field :output, :string
    field :error, :string
    field :duration_ms, :integer

    belongs_to :agent, Kora.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tool_result, attrs) do
    tool_result
    |> cast(attrs, [:agent_id, :tool_name, :input, :output, :error, :duration_ms])
    |> validate_required([:agent_id, :tool_name])
  end
end
