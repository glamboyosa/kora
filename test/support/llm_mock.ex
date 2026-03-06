defmodule Kora.LLM.Mock do
  require Logger

  def stream(_model, messages, _tools) do
    parent = self()

    # Simple Mock:
    # 1. First turn: Call file_write
    # 2. Second turn (with tool result): Finish

    Task.start(fn ->
      last_msg = List.last(messages)

      if last_msg.role == "tool" do
        # Second turn: Finish
        # Stream content
        msg = %{"choices" => [%{"delta" => %{"content" => "File written."}}]}
        send(parent, {:llm_event, msg})
        send(parent, :llm_done)
      else
        # First turn: Call tool
        tool_call_delta = %{
          "index" => 0,
          "id" => "call_mock_123",
          "type" => "function",
          "function" => %{
            "name" => "file_write",
            "arguments" => "{\"path\": \"/tmp/test_kora_mock.txt\", \"content\": \"Hello Kora!\"}"
          }
        }

        msg = %{"choices" => [%{"delta" => %{"tool_calls" => [tool_call_delta]}}]}
        send(parent, {:llm_event, msg})
        send(parent, :llm_done)
      end
    end)

    :ok
  end
end
