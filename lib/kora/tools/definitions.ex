defmodule Kora.Tools.Definitions do
  def for_tools(tool_names) do
    Enum.map(tool_names, &definition/1)
  end

  defp definition("web_search") do
    %{
      type: "function",
      function: %{
        name: "web_search",
        description: "Search the web using Exa AI and return structured results.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "The search query"},
            num_results: %{
              type: "integer",
              description: "Number of results to return (default: 5)"
            },
            use_autoprompt: %{
              type: "boolean",
              description: "Use Exa autoprompt to improve query (default: true)"
            }
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
            method: %{
              type: "string",
              enum: ["GET", "POST", "PUT", "DELETE"],
              description: "Default: GET"
            },
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
            name: %{
              type: "string",
              description:
                "A short unique identifier for this subagent, e.g. researcher, summarizer"
            },
            goal: %{
              type: "string",
              description:
                "The single, specific goal for this subagent. Be explicit about expected output format."
            },
            model: %{
              type: "string",
              description: "OpenRouter model string. Omit to use the session default."
            },
            tools: %{
              type: "array",
              items: %{type: "string"},
              description: "Tools this subagent may use. Omit to inherit parent tools."
            },
            context: %{
              type: "string",
              description:
                "Any context the subagent needs: where to write output, what format to use, relevant background."
            }
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
        description:
          "Call a named agent that is already running in this session and wait for its result.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "The name of the agent to call"},
            message: %{
              type: "string",
              description: "The message or question to send to the agent"
            }
          },
          required: ["name", "message"]
        }
      }
    }
  end
end
