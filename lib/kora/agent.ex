defmodule Kora.Agent do
  use GenServer, restart: :transient
  require Logger
  alias Kora.Repo
  alias Kora.Agents
  alias Kora.Messages.Message
  alias Kora.ToolResults.ToolResult

  @llm_adapter Application.compile_env(:kora, :llm_adapter, Kora.LLM.OpenRouter)

  # --- State Struct ---
  defmodule State do
    defstruct [
      :id,
      :session_id,
      :parent_id,
      :name,
      :model,
      :system_prompt,
      :goal,
      :context,
      :tools,
      # List of map
      :messages,
      :status,
      :result,
      :error,
      # Accumulator for streaming response
      :current_response,
      # List of pending tool call tasks
      :pending_tool_calls
    ]
  end

  # --- Client API ---

  def start_link(opts) do
    id = Keyword.get(opts, :id)
    # Registered by id so we can look up and send casts (add_message, retry) without holding a pid.
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  def via_tuple(id), do: {:via, Registry, {Kora.AgentRegistry, id}}

  def add_message(agent_id, content) do
    # 1. Write to DB via Context
    {:ok, _agent} = Agents.add_user_message(agent_id, content)

    # 2. Notify process if alive
    case Registry.lookup(Kora.AgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:new_user_message, content})

      [] ->
        # Process not running (e.g. app restarted). Start it so it loads state from DB and processes the new message.
        Kora.AgentSupervisor.start_agent(id: agent_id)
    end
  end

  def retry(agent_id) do
    {:ok, _agent} =
      Agents.update_agent(Agents.get_agent!(agent_id), %{status: :running, error: nil})

    case Registry.lookup(Kora.AgentRegistry, agent_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :retry)

      [] ->
        Kora.AgentSupervisor.start_agent(id: agent_id)
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id)
    # Load agent from DB
    case Agents.get_agent(id) do
      nil ->
        {:stop, :not_found}

      agent ->
        # Load messages
        messages = Repo.all(Ecto.assoc(agent, :messages))
        # Convert messages to map format for LLM
        messages_map = Enum.map(messages, &message_to_map/1)

        state = %State{
          id: agent.id,
          session_id: agent.session_id,
          parent_id: agent.parent_id,
          name: agent.name,
          model: agent.model,
          system_prompt: agent.system_prompt,
          goal: agent.goal,
          context: agent.context,
          tools: agent.tools,
          messages: messages_map,
          status: agent.status,
          result: agent.result,
          error: agent.error,
          current_response: nil,
          pending_tool_calls: []
        }

        {:ok, state, {:continue, :check_status}}
    end
  end

  @impl true
  def handle_continue(:check_status, state) do
    case state.status do
      :waiting ->
        # Wait for start signal (from Orchestrator)
        {:noreply, state}

      :running ->
        # Resume loop
        run_loop(state)

      :done ->
        {:noreply, state}

      :failed ->
        {:noreply, state}
    end
  end

  # --- Message Handlers ---

  @impl true
  def handle_cast({:new_user_message, content}, state) do
    # Add to state messages
    msg_map = %{role: "user", content: content}
    new_messages = state.messages ++ [msg_map]
    new_state = %{state | messages: new_messages, status: :running}

    # Trigger loop
    run_loop(new_state)
  end

  @impl true
  def handle_cast(:retry, state) do
    # Just run loop again
    run_loop(%{state | status: :running})
  end

  @impl true
  def handle_info({:llm_event, event}, state) do
    # Handle streaming chunk
    # Event is parsed JSON from SSE
    # %{"choices" => [%{"delta" => delta, ...}]}

    delta = get_in(event, ["choices", Access.at(0), "delta"]) || %{}
    content_chunk = delta["content"]
    tool_calls_chunk = delta["tool_calls"]

    new_response = update_response(state.current_response, content_chunk, tool_calls_chunk)

    # Broadcast token/update if needed
    if content_chunk do
      Phoenix.PubSub.broadcast(
        Kora.PubSub,
        "session:#{state.session_id}",
        {:agent_token, %{agent_id: state.id, chunk: content_chunk}}
      )
    end

    {:noreply, %{state | current_response: new_response}}
  end

  @impl true
  def handle_info(:llm_done, state) do
    # LLM stream finished.
    response = state.current_response

    # Check if we have tool calls or content
    if response.tool_calls != [] do
      # Execute tools
      execute_tools(state, response.tool_calls)
    else
      # Finalize
      finalize(state, response.content)
    end
  end

  @impl true
  def handle_info({:llm_error, error}, state) do
    Logger.error("Agent #{state.id} LLM error: #{inspect(error)}")
    fail_agent(state, "LLM error: #{inspect(error)}")
  end

  @impl true
  def handle_info({:tool_result, tool_call_id, result}, state) do
    # We track pending tool call IDs in state; when all are received we re-enter the loop.
    output =
      case result do
        {:ok, val} ->
          val

        {:error, reason} ->
          Logger.warning("Agent id=#{state.id} tool_call_id=#{tool_call_id} error: #{inspect(reason)}")
          "Error: #{inspect(reason)}"
      end

    tool_name =
      case Repo.get_by(ToolResult, agent_id: state.id, call_id: tool_call_id) do
        nil -> "unknown"
        row -> row.tool_name
      end

    tool_msg_map = %{
      role: "tool",
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      content: output
    }

    persist_message(state.id, tool_msg_map)

    new_messages = state.messages ++ [tool_msg_map]
    new_state = %{state | messages: new_messages}

    pending = List.delete(state.pending_tool_calls, tool_call_id)

    if pending == [] do
      # All tools done, loop again
      run_loop(%{new_state | pending_tool_calls: []})
    else
      {:noreply, %{new_state | pending_tool_calls: pending}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task down. Assuming handled by handle_info tool_result logic if we use Task.async
    # But we need to match ref.
    # For now, we assume Tasks send a message before exit or we use Task.async and handle the reply.
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp run_loop(state) do
    # Re-fetch agent so mid-session model changes (from UI switcher) take effect on this turn
    agent = Agents.get_agent!(state.id)
    state = %{state | model: agent.model}

    Logger.info("Agent id=#{state.id} name=#{state.name} run_loop (model=#{state.model})")

    # Notify UI so user sees "Thinking..." while waiting for first token
    Phoenix.PubSub.broadcast(
      Kora.PubSub,
      "session:#{state.session_id}",
      {:agent_working, %{agent_id: state.id, message: "Thinking..."}}
    )

    # 1. Build messages
    messages = build_messages(state)

    # 2. Call LLM
    tools = Kora.Tools.Definitions.for_tools(state.tools)

    # Init accumulator
    state = %{state | current_response: %{content: "", tool_calls: []}}

    # Stream
    @llm_adapter.stream(state.model, messages, tools)

    {:noreply, state}
  end

  defp execute_tools(state, tool_calls) do
    tool_names = Enum.map(tool_calls, fn tc -> tc["function"]["name"] end)
    Logger.info("Agent id=#{state.id} executing #{length(tool_calls)} tool(s): #{inspect(tool_names)}")

    # Notify UI so user sees progress (e.g. "Calling 3 tool(s): spawn_agent, spawn_agent, spawn_agent")
    message = "Calling #{length(tool_calls)} tool(s): #{Enum.join(tool_names, ", ")}"
    Phoenix.PubSub.broadcast(
      Kora.PubSub,
      "session:#{state.session_id}",
      {:agent_working, %{agent_id: state.id, message: message}}
    )

    # 1. Persist assistant message with tool_calls
    assistant_msg = %{
      role: "assistant",
      content: state.current_response.content,
      tool_calls: tool_calls
    }

    persist_message(state.id, assistant_msg)

    new_messages = state.messages ++ [assistant_msg]
    state = %{state | messages: new_messages, current_response: nil}

    # 2. Dispatch tools
    # We map tool calls to tasks

    pending_ids = Enum.map(tool_calls, fn tc -> tc["id"] end)

    Enum.each(tool_calls, fn tool_call ->
      tool_name = tool_call["function"]["name"]
      args_json = tool_call["function"]["arguments"]
      call_id = tool_call["id"]

      # Handle error?
      args = Jason.decode!(args_json)

      # Persist tool execution start?
      # Spec: "Write every tool call to tool_results when dispatched"

      persist_tool_start(state.id, tool_name, args, call_id)

      # Spawn Task
      parent = self()

      Task.Supervisor.start_child(Kora.ToolSupervisor, fn ->
        start_time = System.monotonic_time(:millisecond)

        # Context for tool
        context = %{
          session_id: state.session_id,
          agent_id: state.id,
          # Fallback
          default_model: state.model,
          parent_tools: state.tools
        }

        result = Kora.Tools.execute(tool_name, args, context)

        duration = System.monotonic_time(:millisecond) - start_time

        # Persist result
        persist_tool_end(state.id, call_id, result, duration)

        send(parent, {:tool_result, call_id, result})
      end)
    end)

    {:noreply, %{state | pending_tool_calls: pending_ids}}
  end

  defp finalize(state, content) do
    Logger.info("Agent id=#{state.id} name=#{state.name} finalizing (content length=#{content |> to_string() |> String.length()})")

    # When the model returns empty content (common after tool use with some providers), synthesize from recent tool results so the user sees a real summary.
    display_content =
      cond do
        content != nil && content != "" ->
          content

        synthesis_from_messages(state) != nil ->
          synthesis_from_messages(state)

        true ->
          Logger.warning("Agent #{state.id} finalized with empty content and no tool results to synthesize")
          "Summary: No final text from the model. You can click Continue to run another turn."
      end

    # Root agent: clean up session workspace (delete files written during the session)
    if state.parent_id == nil do
      Kora.Tools.cleanup_session_workspace(state.session_id)
    end

    # 1. Append final message
    msg = %{role: "assistant", content: display_content}
    persist_message(state.id, msg)

    # 2. Update status
    {:ok, _} =
      Agents.update_agent(Agents.get_agent!(state.id), %{
        status: :done,
        result: display_content,
        completed_at: DateTime.utc_now()
      })

    # 3. Broadcast
    Phoenix.PubSub.broadcast(
      Kora.PubSub,
      "session:#{state.session_id}",
      {:agent_done, %{agent_id: state.id, result: display_content}}
    )

    # 4. Notify parent?
    # Handled by parent monitoring or waiting for tool result (spawn_agent).

    {:noreply, %{state | status: :done, result: display_content}}
  end

  # Build a short summary from recent tool results when the model returned empty content.
  defp synthesis_from_messages(state) do
    tool_results =
      state.messages
      |> Enum.filter(fn m -> m[:role] == "tool" && m[:content] && m[:content] != "" end)
      |> Enum.take(-5)
      |> Enum.map(fn m ->
        content = m[:content] || ""
        if String.length(content) > 300 do
          String.slice(content, 0, 300) <> "..."
        else
          content
        end
      end)

    if tool_results == [] do
      nil
    else
      lines = Enum.with_index(tool_results, 1) |> Enum.map(fn {c, i} -> "#{i}. #{String.replace(c, "\n", " ")}" end)
      "**Summary (synthesized from tool results):**\n\n" <> Enum.join(lines, "\n\n")
    end
  end

  defp fail_agent(state, reason) do
    Logger.error("Agent id=#{state.id} name=#{state.name} failed: #{inspect(reason)}")

    Agents.update_agent(Agents.get_agent!(state.id), %{
      status: :failed,
      error: reason,
      completed_at: DateTime.utc_now()
    })

    Phoenix.PubSub.broadcast(
      Kora.PubSub,
      "session:#{state.session_id}",
      {:agent_failed, %{agent_id: state.id, error: reason}}
    )

    {:noreply, %{state | status: :failed, error: reason}}
  end

  # --- Helpers ---

  defp build_messages(state) do
    # System prompt + stored messages
    # We must ensure the Goal is included if not already in messages.
    # The Spec says: "Agent receives its goal... Agent builds messages list: system_prompt + context + prior history"
    # But currently `messages` table stores history.
    # Goal is just metadata? No, Goal should be the FIRST user message.

    # We should verify if messages list is empty. If so, add goal as User message.
    # But if we persist messages, we should have persisted the goal message at creation?
    # Orchestrator didn't persist it.

    initial_user_msg =
      if state.messages == [] && state.goal do
        [%{role: "user", content: "Goal: #{state.goal}\nContext: #{state.context || ""}"}]
      else
        []
      end

    [%{role: "system", content: state.system_prompt}] ++ initial_user_msg ++ state.messages
  end

  defp message_to_map(msg) do
    # Convert Schema struct to Map for LLM
    m = %{role: msg.role, content: msg.content}

    if msg.tool_calls != [] && msg.tool_calls != nil do
      Map.put(m, :tool_calls, msg.tool_calls)
    else
      m
    end
  end

  defp persist_message(agent_id, msg_map) do
    Repo.insert!(%Message{
      agent_id: agent_id,
      role: msg_map.role,
      content: msg_map[:content],
      tool_calls: msg_map[:tool_calls] || [],
      tool_call_id: msg_map[:tool_call_id],
      tool_name: msg_map[:tool_name]
    })
  end

  defp persist_tool_start(agent_id, tool_name, args, call_id) do
    ToolResult.changeset(%ToolResult{}, %{
      agent_id: agent_id,
      call_id: call_id,
      tool_name: tool_name,
      input: args
    })
    |> Repo.insert!()
  end

  defp persist_tool_end(agent_id, call_id, result, duration) do
    {output, error} =
      case result do
        {:ok, val} -> {val, nil}
        {:error, e} -> {nil, inspect(e)}
      end

    case Repo.get_by(ToolResult, agent_id: agent_id, call_id: call_id) do
      nil ->
        # Start was not persisted (e.g. before call_id existed); insert full row.
        Repo.insert!(%ToolResult{
          agent_id: agent_id,
          call_id: call_id,
          tool_name: "unknown",
          input: %{},
          output: output,
          error: error,
          duration_ms: duration
        })

      row ->
        row
        |> Ecto.Changeset.change(%{output: output, error: error, duration_ms: duration})
        |> Repo.update!()
    end
  end

  defp update_response(current, content_chunk, tool_calls_chunk) do
    # Accumulate content
    new_content = (current.content || "") <> (content_chunk || "")

    # Accumulate tool calls
    # This is complex because tool_calls stream as partial JSON.
    # We need to merge list of tool calls by index.

    new_tool_calls = merge_tool_calls(current.tool_calls, tool_calls_chunk)

    %{current | content: new_content, tool_calls: new_tool_calls}
  end

  defp merge_tool_calls(current, nil), do: current

  defp merge_tool_calls(current, chunks) do
    # chunks is list of deltas: [%{index: 0, function: ...}]
    Enum.reduce(chunks, current, fn chunk, acc ->
      index = chunk["index"]

      if index < length(acc) do
        List.update_at(acc, index, fn existing ->
          deep_merge(existing, chunk)
        end)
      else
        if index == length(acc) do
          acc ++ [chunk]
        else
          # Pad with nil or ignore out of order (should not happen in sequence)
          acc
        end
      end
    end)
  end

  defp deep_merge(target, nil), do: target

  defp deep_merge(target, source) do
    Map.merge(target, source, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        if is_binary(v1) and is_binary(v2), do: v1 <> v2, else: v2
      end
    end)
  end
end
