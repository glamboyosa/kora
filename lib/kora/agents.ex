defmodule Kora.Agents do
  @moduledoc """
  The Agents context.
  """
  import Ecto.Query, warn: false
  alias Kora.Repo
  alias Kora.Agents.Agent
  alias Kora.Messages.Message

  def list_agents(session_id) do
    Repo.all(from a in Agent, where: a.session_id == ^session_id, order_by: [asc: a.inserted_at])
  end

  def get_agent!(id), do: Repo.get!(Agent, id)

  def get_agent(id), do: Repo.get(Agent, id)

  def create_agent(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
  end

  def change_agent(%Agent{} = agent, attrs \\ %{}) do
    Agent.changeset(agent, attrs)
  end

  def get_agent_by_name(session_id, name) do
    Repo.get_by(Agent, session_id: session_id, name: name)
  end

  def add_user_message(agent_id, content) do
    Repo.transaction(fn ->
      # 1. Insert message
      Repo.insert!(%Message{
        agent_id: agent_id,
        role: "user",
        content: content
      })

      # 2. Update agent status to running if done/failed
      agent = Repo.get!(Agent, agent_id)
      # We always want to ensure it's running if we add a message to continue chat
      if agent.status in [:done, :failed] do
        update_agent(agent, %{status: :running, error: nil})
      else
        {:ok, agent}
      end
    end)
  end
end
