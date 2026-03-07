defmodule Kora.Orchestrator do
  use GenServer
  alias Kora.Repo
  alias Kora.Sessions.Session
  alias Kora.Agents

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def start_session(goal, model \\ nil) do
    # 1. Create Session
    session_changeset =
      Session.changeset(%Session{}, %{
        status: "active",
        goal: goal,
        started_at: DateTime.utc_now()
      })

    case Repo.insert(session_changeset) do
      {:ok, session} ->
        # 2. Create Root Agent
        root_agent_attrs = %{
          session_id: session.id,
          name: "root",
          model:
            model || Application.get_env(:kora, :default_model) || "google/gemini-3-flash-preview",
          # Start immediately
          status: :running,
          goal: goal,
          system_prompt: root_system_prompt(),
          # Default tools
          tools: default_tools(),
          started_at: DateTime.utc_now()
        }

        case Agents.create_agent(root_agent_attrs) do
          {:ok, agent} ->
            # 3. Start Agent Process
            case Kora.AgentSupervisor.start_agent(id: agent.id) do
              {:ok, _pid} -> {:ok, session.id}
              {:error, reason} -> {:error, "Failed to start root agent: #{inspect(reason)}"}
            end

          {:error, cs} ->
            {:error, "Failed to create root agent: #{inspect(cs.errors)}"}
        end

      {:error, cs} ->
        {:error, "Failed to create session: #{inspect(cs.errors)}"}
    end
  end

  defp default_tools do
    base_tools = ["file_read", "file_write", "spawn_agent"]

    if Application.get_env(:kora, :exa_api_key) do
      ["web_search" | base_tools]
    else
      base_tools
    end
  end

  defp root_system_prompt do
    """
    You are Kora's root orchestration agent. You receive a goal and are responsible
    for completing it — either directly or by delegating subtasks to subagents.

    Available tools: {{tool_list}}

    When to spawn subagents:
    - The goal has clearly separable subtasks that benefit from parallelism
    - A subtask requires a different model or a focused instruction set
    - The subtask is long-running and should not block your main reasoning loop

    When NOT to spawn subagents:
    - You can complete the task in 1-3 tool calls yourself
    - The subtask is trivial — spawning adds latency without benefit
    - You are already handling a scoped subtask from a parent agent

    Task decomposition rules:
    - Give each subagent ONE specific goal with an explicit output format
    - Tell each subagent where to write its output (file path) or that it should return its result directly
    - Never spawn subagents that will duplicate each other's work
    - After subagents complete, you synthesize their results — do not delegate synthesis

    Think step by step before your first tool call. Decide whether to decompose.
    Then act.
    """
    |> String.replace("{{tool_list}}", Enum.join(default_tools(), ", "))
  end
end
