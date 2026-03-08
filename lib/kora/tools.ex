defmodule Kora.Tools do
  require Logger

  def execute(tool_name, args) do
    Logger.info("Executing tool: #{tool_name} with args: #{inspect(args)}")

    case tool_name do
      "web_search" ->
        web_search(args)

      "file_read" ->
        file_read(args)

      "file_write" ->
        file_write(args)

      "shell_exec" ->
        shell_exec(args)

      "http_request" ->
        http_request(args)

      "spawn_agent" ->
        # spawn_agent logic is handled by the caller or specialized handler.
        # But if called here, it means we are executing it.
        # However, spawn_agent requires Agent context (parent_id, session_id).
        # We might need to pass context to execute/2.
        {:error, "spawn_agent requires context"}

      "agent_call" ->
        {:error, "agent_call requires context"}

      _ ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end

  # We overload execute to accept context if needed (session_id for workspace-relative paths).
  def execute(tool_name, args, context) do
    case tool_name do
      "spawn_agent" -> spawn_agent(args, context)
      "agent_call" -> agent_call(args, context)
      "file_read" -> file_read(args, context)
      "file_write" -> file_write(args, context)
      _ -> execute(tool_name, args)
    end
  end

  defp workspace_root do
    Application.get_env(:kora, :workspace_root) || File.cwd!()
  end

  defp session_workspace_dir(session_id) when is_binary(session_id) do
    Path.join([workspace_root(), "workspace", session_id])
  end

  defp session_workspace_dir(_), do: nil

  # Cross-platform: ~/Documents, ~/Downloads etc. work on macOS, Linux, and Windows.
  defp user_home_path(path) when is_binary(path) do
    home = System.user_home() || Path.expand("~")
    rest = path |> String.trim_leading("~") |> String.trim_leading("/") |> String.trim_leading("\\")
    if rest == "", do: home, else: Path.join(home, rest)
  end

  @doc """
  Deletes the session workspace directory (all files written by tools in this session).
  Call when the root agent completes so created files are cleaned up.
  """
  def cleanup_session_workspace(session_id) when is_binary(session_id) do
    dir = session_workspace_dir(session_id)
    if File.exists?(dir) do
      File.rm_rf(dir)
      Logger.info("Cleaned up session workspace: #{dir}")
    end
    :ok
  end

  def cleanup_session_workspace(_), do: :ok

  # Real web search uses Exa (https://exa.ai). Set EXA_API_KEY in .env for live results; otherwise mock data is returned.
  defp web_search(args) do
    query = args["query"]
    num_results = Map.get(args, "num_results", 5)
    use_autoprompt = Map.get(args, "use_autoprompt", true)

    api_key = Application.get_env(:kora, :exa_api_key)

    if is_nil(api_key) || api_key == "" do
      # Fallback to mock if no key provided, but warn
      Logger.warning("No EXA_API_KEY found. Using mock search. Add EXA_API_KEY to .env for real web search (see https://exa.ai).")
      {:ok, "Search results for: #{query}\n[Mock Result - Set EXA_API_KEY to get real results]"}
    else
      url = "https://api.exa.ai/search"

      body = %{
        query: query,
        numResults: num_results,
        useAutoprompt: use_autoprompt,
        # Fetch text content
        contents: %{text: true}
      }

      headers = [
        {"x-api-key", api_key},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
        {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
          formatted = format_exa_results(results)
          {:ok, formatted}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Exa API Error #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Exa Request Failed: #{inspect(reason)}"}
      end
    end
  end

  defp format_exa_results(results) do
    results
    |> Enum.map(fn r ->
      """
      Title: #{r["title"]}
      URL: #{r["url"]}
      Summary: #{String.slice(r["text"] || "", 0, 300)}...
      """
    end)
    |> Enum.join("\n---\n")
  end

  defp file_read(args, context \\ nil) do
    path = args["path"]
    pattern = args["pattern"]
    base = if context && context[:session_id], do: session_workspace_dir(context[:session_id]), else: nil
    # Paths starting with ~ → user home (Documents, Downloads, etc.) on any OS.
    full_path =
      cond do
        String.starts_with?(path, "~") -> user_home_path(path)
        base -> Path.join(base, path)
        true -> Path.expand(path)
      end

    case File.read(full_path) do
      {:ok, content} ->
        if pattern != nil && pattern != "" do
          lines = String.split(content, "\n", trim: false)
          matched =
            lines
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> String.contains?(line, pattern) end)
          n = length(matched)
          matching =
            matched
            |> Enum.map(fn {line, num} -> "  #{num}: #{line}" end)
            |> Enum.join("\n")
          if n == 0 do
            {:ok, "(no lines matching \"#{pattern}\" in #{path})"}
          else
            {:ok, "Matches for \"#{pattern}\" in #{path} (#{n} line(s)):\n#{matching}"}
          end
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{path}. Resolved to: #{full_path}. (Files are read from the session workspace; ensure the file was written in this session.)"}

      {:error, reason} ->
        {:error, "Failed to read file #{full_path}: #{inspect(reason)}"}
    end
  end

  defp file_write(args, context \\ nil) do
    path = args["path"]
    content = args["content"]
    base = if context && context[:session_id], do: session_workspace_dir(context[:session_id]), else: nil
    full_path =
      cond do
        String.starts_with?(path, "~") -> user_home_path(path)
        base -> Path.join(base, path)
        true -> Path.expand(path)
      end
    File.mkdir_p!(Path.dirname(full_path))

    case File.write(full_path, content) do
      :ok -> {:ok, "File written successfully to #{full_path}"}
      {:error, reason} -> {:error, "Failed to write file: #{inspect(reason)}"}
    end
  end

  defp shell_exec(%{"command" => command} = args) do
    timeout = Map.get(args, "timeout_ms", 10000)

    # Security Warning: This allows arbitrary command execution.
    # Be extremely careful.

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, "Exit Code: #{exit_code}\nOutput:\n#{output}"}

      nil ->
        {:error, "Command timed out after #{timeout}ms"}

      {:exit, reason} ->
        {:error, "Command exited with reason: #{inspect(reason)}"}
    end
  end

  defp http_request(%{"url" => url} = args) do
    method = Map.get(args, "method", "GET") |> String.to_atom()
    headers = Map.get(args, "headers", %{})
    body = Map.get(args, "body", "")

    opts = [
      method: method,
      url: url,
      headers: headers,
      body: body,
      receive_timeout: 30_000
    ]

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, "Status: #{status}\nBody:\n#{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp spawn_agent(args, context) do
    parent_id = context[:agent_id]
    session_id = context[:session_id]

    name = args["name"]
    goal = args["goal"]

    # Create agent record with status: :running so that when the Agent process starts,
    # handle_continue(:check_status) sees :running and calls run_loop immediately.
    # (If we used :waiting, the process would never start the loop and would sit idle until timeout.)
    attrs = %{
      session_id: session_id,
      parent_id: parent_id,
      name: name,
      model: args["model"] || context[:default_model],
      goal: goal,
      context: args["context"],
      tools: args["tools"] || context[:parent_tools] || [],
      status: :running,
      system_prompt: """
      You are a specialized subagent running inside Kora.
      A parent agent has assigned you a specific, scoped task. Complete it and nothing else.

      Your goal: #{goal}
      Your context: #{args["context"] || "No additional context provided."}

      Rules:
      - Work on your assigned goal directly. Do not expand scope.
      - Only spawn further subagents if the task is genuinely parallelizable
        and you cannot complete it efficiently alone. Prefer doing the work yourself.
      - Write your final output to the location specified in your context,
        or return it as your final message if no location is given.
      - Do not ask clarifying questions. Make reasonable assumptions and proceed.
      - End your final message with a clear statement of what you produced and where.
      """
    }

    case Kora.Agents.create_agent(attrs) do
      {:ok, agent} ->
        timeout_ms = Application.get_env(:kora, :subagent_timeout_ms, 300_000)
        timeout_s = div(timeout_ms, 1000)

        Logger.info("Spawning subagent name=#{name} id=#{agent.id} (timeout #{timeout_s}s)")

        # Subscribe to completion event
        Phoenix.PubSub.subscribe(Kora.PubSub, "session:#{session_id}")

        # Start the process
        case Kora.AgentSupervisor.start_agent(id: agent.id) do
          {:ok, _pid} ->
            Logger.info("Waiting for subagent name=#{name} id=#{agent.id} (timeout #{timeout_s}s)")

            # Notify UI so user sees "Waiting for subagent: apple_researcher" etc.
            Phoenix.PubSub.broadcast(
              Kora.PubSub,
              "session:#{session_id}",
              {:agent_working, %{agent_id: parent_id, message: "Waiting for subagent: #{name}"}}
            )

            result =
              receive do
                {:agent_done, %{agent_id: id, result: res}} when id == agent.id ->
                  Phoenix.PubSub.unsubscribe(Kora.PubSub, "session:#{session_id}")
                  Logger.info("Subagent name=#{name} id=#{agent.id} completed")
                  {:ok, res}

                {:agent_failed, %{agent_id: id, error: err}} when id == agent.id ->
                  Phoenix.PubSub.unsubscribe(Kora.PubSub, "session:#{session_id}")
                  Logger.error("Subagent name=#{name} id=#{agent.id} failed: #{inspect(err)}")
                  {:error, err}
              after
                timeout_ms ->
                  Phoenix.PubSub.unsubscribe(Kora.PubSub, "session:#{session_id}")
                  msg = "Subagent #{name} timed out after #{timeout_s}s"
                  Logger.error("Subagent name=#{name} id=#{agent.id} timed out after #{timeout_s}s")
                  {:error, msg}
              end

            result

          {:error, reason} ->
            Logger.error("Failed to start subagent name=#{name}: #{inspect(reason)}")
            {:error, "Failed to start agent process: #{inspect(reason)}"}
        end

      {:error, changeset} ->
        {:error, "Failed to create agent record: #{inspect(changeset.errors)}"}
    end
  end

  defp agent_call(_args, _context) do
    # Placeholder
    {:error, "agent_call not implemented"}
  end
end
