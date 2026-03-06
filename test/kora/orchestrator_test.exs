defmodule Kora.OrchestratorTest do
  use Kora.DataCase

  alias Kora.Orchestrator
  alias Kora.Agents
  alias Kora.Sessions.Session

  describe "sessions" do
    test "start_session/2 creates session and root agent" do
      goal = "Test goal"
      assert {:ok, session_id} = Orchestrator.start_session(goal)

      session = Repo.get!(Session, session_id)
      assert session.goal == goal
      assert session.status == "active"

      # Check root agent
      agents = Agents.list_agents(session_id)
      assert length(agents) == 1
      root = List.first(agents)
      assert root.name == "root"
      assert root.status == :running
      assert root.goal == goal
    end
  end
end
