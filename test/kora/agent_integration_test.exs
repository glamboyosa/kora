defmodule Kora.AgentIntegrationTest do
  use Kora.DataCase
  alias Kora.Orchestrator
  alias Kora.Agents
  alias Kora.Messages.Message

  test "full agent loop: start -> tool call -> result -> done" do
    # 1. Start session
    {:ok, session_id} = Orchestrator.start_session("Write a file")

    # 2. Get root agent
    [root] = Agents.list_agents(session_id)
    assert root.status == :running

    # Wait for completion (Agent subscribes to PubSub, but test process can too)
    Phoenix.PubSub.subscribe(Kora.PubSub, "session:#{session_id}")

    # Agent process is running asynchronously.
    # It should:
    # 1. Call LLM (Mock) -> get file_write tool call
    # 2. Execute file_write -> writes /tmp/test_kora_mock.txt
    # 3. Call LLM (Mock) with result -> get "File written."
    # 4. Finish -> :done

    # Wait for completion
    assert_receive {:agent_done, %{agent_id: agent_id, result: result}}, 5000
    assert agent_id == root.id
    # Wait, the failure was: left: "", right: "File written."
    # This means result is empty string?
    # Why?
    # In Mock, I send: %{"choices" => [%{"delta" => %{"content" => "File written."}}]}
    # Agent: update_response -> accumulates content.
    # Then finalize -> result = content.

    # Maybe the delta structure in Mock is slightly off or Agent logic is wrong?
    # Mock: %{"choices" => [%{"delta" => %{"content" => "File written."}}]}
    # Agent: get_in(event, ["choices", Access.at(0), "delta"])
    # "content" key lookup.

    # Wait, the test failure said:
    # left: ""
    # right: "File written."
    # So the result received was empty string.

    # This implies `content_chunk` was nil or empty in `update_response`.
    # Let's check Agent `handle_info({:llm_event, event}, state)`.
    # `content_chunk = delta["content"]`

    # If Mock sends JSON keys as strings, Jason decodes them as strings.
    # My Mock uses map literal `%{...}`. 
    # If I pass map directly to `llm_event`, keys are atoms unless I used strings explicitly.
    # In Mock: `"choices"` => ...
    # Wait. `send(parent, {:llm_event, %{"choices" => ...}})`
    # This is a Map with string keys.
    # Agent uses `get_in(event, ["choices", ...])`. String keys.
    # So that matches.

    # Why is content empty?
    # Maybe `state.current_response` was reset?
    # `run_loop` inits accumulator.
    # Stream called.
    # Events arrive.
    # `llm_done` arrives.

    # Maybe race condition? `llm_done` arrives before `llm_event`?
    # Task.start sends them sequentially.
    # BEAM message ordering guarantees order between same pair of processes.
    # So `llm_event` arrives first.

    # Let's inspect `state` in Agent if possible or add logging.
    # I'll rely on debugging the test failure.

    # Wait! In Mock:
    # send(parent, {:llm_event, %{"choices" => [%{"delta" => %{"content" => "File written."}}]} })
    # In Agent:
    # content_chunk = delta["content"]
    # new_response = update_response(..., content_chunk, ...)
    # current_response updated.

    # Ah! `update_response` logic:
    # new_content = (current.content || "") <> (content_chunk || "")

    # If `content_chunk` is nil (e.g. tool call event), it stays same.
    # If `content_chunk` is "File written.", it appends.

    # In Mock:
    # 1st turn: send tool call. Content is nil.
    # 2nd turn: send content. Tool calls nil.

    # Wait, `Agent.handle_info(:llm_done)`:
    # if response.tool_calls != [], execute tools.
    # else finalize.

    # 1st turn: tool_calls not empty. Execute tools.
    # This resets current_response to nil in `execute_tools`.
    # state = %{state | messages: ..., current_response: nil}

    # Then `run_loop` is called.
    # `run_loop` sets `current_response: %{content: "", tool_calls: []}`.
    # Then calls stream.

    # 2nd turn:
    # Mock sends content "File written.".
    # Agent updates response. content becomes "File written.".
    # Mock sends `llm_done`.
    # Agent checks tool_calls. Empty.
    # Finalize with content "File written.".

    # So why did test receive empty string?
    # Did the Mock send content correctly?
    # `send(parent, {:llm_event, %{"choices" => [%{"delta" => %{"content" => "File written."}}]}})`
    # It looks correct.

    # Maybe `Access.at(0)` fails if list is empty? No, Mock sends list with 1 item.

    # I suspect maybe `Jason.decode` isn't happening in Mock because I send raw map, but Agent expects map (since OpenRouter adapter parses it).
    # Yes, `Kora.Agent` expects `event` to be a Map (parsed JSON).
    # Mock sends a Map.

    # Let's add Logger.info to Agent to trace.
    # Or maybe the assertion failed because `result` was *actually* empty?
    # Maybe `handle_info` logic for `content_chunk` isn't working?

    assert agent_id == root.id
    # Verify messages
    # messages = Repo.all(from m in Message, where: m.agent_id == ^root.id, order_by: [asc: m.inserted_at])
    # IO.inspect(Enum.map(messages, &{&1.role, &1.content, &1.tool_calls}), label: "Messages")

    assert result == "File written."
  end
end
