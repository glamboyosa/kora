# Kora — Agent Reference

This file defines the agent contract for Kora. Read it in full before implementing any agent-related module. It covers what an agent is, how it runs, how it communicates, how it spawns subagents, and what invariants must always hold.

---

## What an Agent Is

An agent is a supervised `GenServer`. It is the atomic unit of work in Kora. It owns its identity, its system prompt, its model assignment, its permitted tools, and its full message history. It runs an LLM loop until it produces a final response or fails.

Every agent — whether spawned by the user, a workflow definition, or another agent dynamically — is the same struct and the same process type. There is no distinction between a "root agent" and a "subagent" at the process level. The difference is only in `parent_id` (nil for root agents) and the system prompt injected at startup.

---

## Agent State

```elixir
defmodule Kora.Agent.State do
  @type status :: :waiting | :running | :done | :failed

  @type t :: %__MODULE__{
    id: String.t(),
    session_id: String.t(),
    parent_id: String.t() | nil,
    name: String.t(),
    model: String.t(),
    system_prompt: String.t(),
    goal: String.t(),
    context: String.t() | nil,
    tools: [String.t()],
    messages: [map()],
    status: status(),
    result: String.t() | nil,
    error: String.t() | nil,
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil
  }
end
```

Every field in this struct must be persisted to the `agents` table before the agent begins its loop and updated on every status transition.

---

## Agent Lifecycle

```
:waiting   -> agent is registered but blocked on dependencies
:running   -> agent is actively in the LLM loop
:done      -> agent produced a final result
:failed    -> agent exhausted retries or encountered an unrecoverable error
```

Transitions:

- `:waiting -> :running` — Orchestrator calls `Agent.start/1` when dependencies resolve
- `:running -> :done` — LLM returns a final text response (no tool calls)
- `:running -> :running` — LLM returns tool calls; agent processes them and loops
- `:running -> :failed` — unrecoverable error or max retries exceeded

Every transition is written to SQLite before the next operation. If the process crashes between a transition write and the next LLM call, restart picks up from the last persisted status.

---

## The LLM Loop

This is the core of `Kora.Agent`. Implement it as a recursive private function called from `handle_continue/2` after initialization.

```
defp run_loop(state) do
  1. Build messages list: system_prompt + state.messages
  2. Call Kora.LLM.OpenRouter.stream/3 with model, messages, tool_definitions(state.tools)
  3. Receive streaming chunks via handle_info, accumulate into a response
  4. When stream closes:
     a. If response has no tool_calls -> finalize(state, response.content)
     b. If response has tool_calls -> execute_tools(state, response.tool_calls)
```

```
defp execute_tools(state, tool_calls) do
  1. For each tool_call, dispatch to Kora.Tools.execute/2 as an async Task
  2. Await all tasks (respect per-tool timeout from config, default 30s)
  3. Append each tool result to state.messages as role: "tool"
  4. Persist all new messages to SQLite
  5. Broadcast tool_call and tool_result events via EventBus
  6. Loop back to run_loop/1
```

```
defp finalize(state, content) do
  1. Append final assistant message to state.messages
  2. Persist final message to SQLite
  3. Update agent status to :done, set result = content, completed_at = now()
  4. Persist updated agent to SQLite
  5. Broadcast agent_done event via EventBus
  6. Notify parent: if state.parent_id != nil, send result to parent agent process
  7. Notify Orchestrator: Orchestrator.agent_completed(state.session_id, state.id, content)
```

---

## Message Format

Messages are stored as a list of maps and passed directly to OpenRouter. Follow the OpenAI message format.

```elixir
# User or system turn
%{role: "user", content: "Find recent papers on BEAM concurrency"}

# Assistant turn (no tool calls)
%{role: "assistant", content: "Here is what I found..."}

# Assistant turn with tool calls
%{
  role: "assistant",
  content: nil,
  tool_calls: [
    %{
      id: "call_abc123",
      type: "function",
      function: %{
        name: "web_search",
        arguments: ~s({"query": "BEAM concurrency 2025"})
      }
    }
  ]
}

# Tool result (must follow the assistant turn that requested it)
%{
  role: "tool",
  tool_call_id: "call_abc123",
  content: "Result: ..."
}
```

The messages list in agent state is the source of truth. It is built up over the entire loop and passed in full to each LLM call. Never truncate or summarize it automatically — that is a future concern.

---

## Tool Definitions

When calling the LLM, pass tool definitions for every tool in `state.tools`. Definitions follow the OpenAI function calling format.

```elixir
defmodule Kora.Tools.Definitions do
  def for_tools(tool_names) do
    Enum.map(tool_names, &definition/1)
  end

  defp definition("web_search") do
    %{
      type: "function",
      function: %{
        name: "web_search",
        description: "Search the web and return structured results.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "The search query"}
          },
          required: ["query"]
        }
      }
    }
  end

  defp definition("file_read") do
    %{
      type: "function",
      function: %{
        name: "file_read",
        description: "Read the contents of a file from the local filesystem.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Absolute or home-relative file path"}
          },
          required: ["path"]
        }
      }
    }
  end

  defp definition("file_write") do
    %{
      type: "function",
      function: %{
        name: "file_write",
        description: "Write content to a file. Creates the file if it does not exist.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Absolute or home-relative file path"},
            content: %{type: "string", description: "Content to write"}
          },
          required: ["path", "content"]
        }
      }
    }
  end

  defp definition("shell_exec") do
    %{
      type: "function",
      function: %{
        name: "shell_exec",
        description: "Run a shell command and return stdout and stderr. Use sparingly.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "The shell command to run"},
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds, default 10000"}
          },
          required: ["command"]
        }
      }
    }
  end

  defp definition("http_request") do
    %{
      type: "function",
      function: %{
        name: "http_request",
        description: "Make an HTTP request and return the response body.",
        parameters: %{
          type: "object",
          properties: %{
            url: %{type: "string"},
            method: %{type: "string", enum: ["GET", "POST", "PUT", "DELETE"], description: "Default: GET"},
            headers: %{type: "object", description: "Optional headers map"},
            body: %{type: "string", description: "Optional request body"}
          },
          required: ["url"]
        }
      }
    }
  end

  defp definition("spawn_agent") do
    %{
      type: "function",
      function: %{
        name: "spawn_agent",
        description: """
        Spawn a new specialized subagent to handle a specific subtask.
        The subagent runs to completion and its final output is returned to you as the tool result.
        Use this when the task has clearly separable subtasks, especially ones that can run in parallel,
        or when a subtask benefits from a different model or specialized instruction set.
        Do not spawn subagents for trivial tasks you can complete in 1-2 tool calls yourself.
        """,
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "A short unique identifier for this subagent, e.g. researcher, summarizer"},
            goal: %{type: "string", description: "The single, specific goal for this subagent. Be explicit about expected output format."},
            model: %{type: "string", description: "OpenRouter model string. Omit to use the session default."},
            tools: %{
              type: "array",
              items: %{type: "string"},
              description: "Tools this subagent may use. Omit to inherit parent tools."
            },
            context: %{type: "string", description: "Any context the subagent needs: where to write output, what format to use, relevant background."}
          },
          required: ["name", "goal"]
        }
      }
    }
  end

  defp definition("agent_call") do
    %{
      type: "function",
      function: %{
        name: "agent_call",
        description: "Call a named agent that is already running in this session and wait for its result.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "The name of the agent to call"},
            message: %{type: "string", description: "The message or question to send to the agent"}
          },
          required: ["name", "message"]
        }
      }
    }
  end
end
```

---

## spawn_agent Implementation Contract

When `Kora.Tools.execute/2` receives a `spawn_agent` call, it must:

1. Validate required fields (`name`, `goal`). Return an error tool result if invalid.
2. Resolve the model: use the provided model or fall back to session default from config.
3. Resolve tools: use the provided list or inherit from the parent agent.
4. Build the subagent state with `parent_id` set to the calling agent's id.
5. Inject the subagent system prompt (see System Prompts section below).
6. Call `Kora.AgentSupervisor.start_agent/1` which calls `DynamicSupervisor.start_child/2`.
7. Wait for the subagent to complete by monitoring its process and awaiting the `{:agent_done, id, result}` message.
8. Return the subagent's result as the tool result string.
9. If the subagent fails, return an error tool result describing the failure.

The calling agent's process blocks during step 7. This is intentional — the agent is waiting for its delegate. Other agents in the session are unaffected.

If the caller needs multiple subagents to run in parallel, it should emit multiple `spawn_agent` tool calls in a single LLM response. Kora detects multiple tool calls and dispatches them concurrently via `Task.async_stream/3` before awaiting all results.

---

## System Prompts

### Root Agent

Injected when `parent_id` is nil.

```
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
```

### Subagent

Injected when `parent_id` is not nil.

```
You are a specialized subagent running inside Kora.
A parent agent has assigned you a specific, scoped task. Complete it and nothing else.

Your goal: {{goal}}
Your context: {{context}}

Rules:
- Work on your assigned goal directly. Do not expand scope.
- Only spawn further subagents if the task is genuinely parallelizable
  and you cannot complete it efficiently alone. Prefer doing the work yourself.
- Write your final output to the location specified in your context,
  or return it as your final message if no location is given.
- Do not ask clarifying questions. Make reasonable assumptions and proceed.
- End your final message with a clear statement of what you produced and where.
```

---

## EventBus Events

Every significant agent event is broadcast via `Phoenix.PubSub` so the LiveView UI can update in real time without polling. All events are broadcast to the topic `"session:#{session_id}"`.

```elixir
# Agent status changed
{:agent_status, %{agent_id: id, name: name, status: status}}

# Token chunk received from LLM stream
{:agent_token, %{agent_id: id, chunk: chunk}}

# Tool call initiated
{:tool_call, %{agent_id: id, tool: tool_name, input: input, call_id: call_id}}

# Tool result received
{:tool_result, %{agent_id: id, tool: tool_name, output: output, call_id: call_id, duration_ms: ms}}

# Agent completed
{:agent_done, %{agent_id: id, name: name, result: result}}

# Agent failed
{:agent_failed, %{agent_id: id, name: name, error: error}}

# Subagent spawned
{:agent_spawned, %{parent_id: parent_id, child_id: child_id, name: name}}
```

Broadcast these from inside the Agent GenServer at the exact moment each event occurs, not batched afterward.

---

## Persistence Rules

These are invariants. Do not relax them.

- Write the full agent row to SQLite before calling the LLM for the first time.
- Write every new message (user, assistant, tool, tool result) to the `messages` table immediately after it is appended to state.
- Write every tool call to `tool_results` when dispatched (with output null) and update it when the result arrives.
- Write to `cost_ledger` after every LLM response that returns usage metadata.
- Update agent `status`, `result`, `error`, `completed_at` on every status transition before broadcasting the event.

The rule is: SQLite is always ahead of or equal to in-memory state. Never the reverse.

---

## Error Handling

### Retryable errors

- HTTP 429 from OpenRouter — wait for `RateLimiter.wait/2`, then retry the same LLM call
- HTTP 5xx from OpenRouter — exponential backoff, max 3 retries
- Tool timeout — return a tool result with `{:error, :timeout}`, let the LLM decide how to proceed

### Non-retryable errors

- HTTP 401/403 — bad API key; fail the agent immediately with a clear error message
- Invalid tool call payload — return an error tool result, let the LLM correct itself
- Max loop iterations exceeded (default: 50 LLM calls per agent) — fail the agent

### Crash recovery

If the Agent GenServer crashes, the supervisor restarts it. On `init/1`, the agent should check its persisted status in SQLite:

- If status is `:done` or `:failed` — do not restart the loop, just hold state
- If status is `:running` — rebuild messages from the `messages` table and resume the loop from the last message
- If status is `:waiting` — wait for the Orchestrator to call `start/1` again

---

## Invariants

These must always be true. If any of them are violated, it is a bug.

1. No two agents in the same session share the same `name`.
2. An agent's `messages` list in SQLite is always a superset of what was last sent to the LLM.
3. A `:done` or `:failed` agent never re-enters the LLM loop.
4. A `spawn_agent` call always produces a process registered under `AgentSupervisor`.
5. Every broadcast event has a corresponding SQLite write that happened before it.
6. An agent's `parent_id` always refers to an agent that exists in the same session.
7. Tool execution never blocks the agent process directly — always via `Task`.
