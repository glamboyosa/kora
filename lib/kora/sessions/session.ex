defmodule Kora.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :workflow_id, :binary_id
    # active, completed, failed
    field :status, :string, default: "active"
    field :goal, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    has_many :agents, Kora.Agents.Agent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:workflow_id, :status, :goal, :started_at, :completed_at])
    |> validate_required([:status, :goal])
  end
end
