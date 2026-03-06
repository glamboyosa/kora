defmodule Kora.LLM.OpenRouter do
  @moduledoc """
  Adapter for OpenRouter API. Uses [OpenRouter Models API](https://openrouter.ai/docs/guides/overview/models)
  for listing models (GET /api/v1/models).
  """
  require Logger

  @base_url "https://openrouter.ai/api/v1"

  # Preferred model id patterns for dropdown, in display order (Gemini biased as best).
  @preferred_patterns [
    "google/gemini-3.1",
    "google/gemini-3",
    "openai/gpt-5.4",
    "openai/gpt-5.3",
    "anthropic/claude-opus-4",
    "anthropic/claude-sonnet-4",
    "moonshot/kimi-2.5",
    "openrouter/free"
  ]

  @doc """
  Fetches models from OpenRouter API and returns a curated list for the dropdown:
  Gemini 3.1/3, OpenAI 5.4/5.3, Claude Opus/Sonnet 4.6, Kimi 2.5, and free models.
  Returns `[{display_name, model_id}, ...]`. On API failure returns a static fallback list.
  """
  def list_models do
    api_key = Application.get_env(:kora, :openrouter_api_key)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "http://localhost:4000"}
    ]

    case Req.get(@base_url <> "/models", headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        build_curated_list(data)

      _ ->
        fallback_models()
    end
  rescue
    e ->
      Logger.warning("OpenRouter list_models failed: #{inspect(e)}")
      fallback_models()
  end

  defp build_curated_list(data) do
    selected =
      @preferred_patterns
      |> Enum.flat_map(fn pattern ->
        data
        |> Enum.filter(fn m -> String.starts_with?(m["id"], pattern) end)
        |> Enum.take(1)
        |> Enum.map(fn m -> {m["id"], m["name"] || m["id"]} end)
      end)
      |> Enum.uniq_by(fn {id, _} -> id end)

    # Ensure free is included even if not in API response
    free = {"openrouter/free", "Free (OpenRouter)"}
    selected = if Enum.any?(selected, fn {id, _} -> id == "openrouter/free" end), do: selected, else: selected ++ [free]

    Enum.map(selected, fn {id, name} -> {name, id} end)
  end

  def fallback_models do
    [
      {"Gemini 3.1 Pro", "google/gemini-3.1-pro-preview"},
      {"Gemini 3 Flash", "google/gemini-3-flash-preview"},
      {"GPT 5.4 Pro", "openai/gpt-5.4-pro"},
      {"GPT 5.4", "openai/gpt-5.4"},
      {"Claude Opus 4", "anthropic/claude-opus-4"},
      {"Claude Sonnet 4", "anthropic/claude-sonnet-4"},
      {"Kimi 2.5", "moonshot/kimi-2.5"},
      {"Free (OpenRouter)", "openrouter/free"}
    ]
  end

  def stream(model, messages, tools \\ []) do
    api_key = Application.get_env(:kora, :openrouter_api_key)
    parent = self()

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"HTTP-Referer", "http://localhost:4000"},
      {"X-Title", "Kora"}
    ]

    body = %{
      model: model,
      messages: messages,
      stream: true
    }

    body = if tools != [], do: Map.put(body, :tools, tools), else: body

    Task.start(fn ->
      try do
        Req.post!(@base_url <> "/chat/completions",
          json: body,
          headers: headers,
          into: fn {:data, data}, {req, resp} ->
            {events, _rest} = extract_events(data)

            Enum.each(events, fn event ->
              if event != :done do
                send(parent, {:llm_event, event})
              end
            end)

            {:cont, {req, resp}}
          end,
          receive_timeout: 60_000
        )

        send(parent, :llm_done)
      rescue
        e ->
          Logger.error("OpenRouter stream error: #{inspect(e)}")
          send(parent, {:llm_error, e})
      end
    end)

    :ok
  end

  defp extract_events(buffer) do
    # Simple split by newlines for SSE
    # Note: This simple implementation might split a JSON object if it spans chunks,
    # but OpenRouter usually sends one "data: ..." line per chunk.
    # A robust implementation would need a persistent buffer across chunks.

    parts = String.split(buffer, "\n")

    events =
      parts
      |> Enum.map(&parse_sse/1)
      |> Enum.reject(&is_nil/1)

    {events, ""}
  end

  defp parse_sse(part) do
    case String.split(part, "data: ", parts: 2) do
      [_, json_data] ->
        json_data = String.trim(json_data)

        if json_data == "[DONE]" do
          :done
        else
          case Jason.decode(json_data) do
            {:ok, decoded} -> decoded
            _ -> nil
          end
        end

      _ ->
        nil
    end
  end
end
