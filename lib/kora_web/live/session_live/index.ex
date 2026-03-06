defmodule KoraWeb.SessionLive.Index do
  use KoraWeb, :live_view
  alias Kora.Repo
  alias Kora.Sessions.Session
  alias Kora.Orchestrator
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load_models)
    end

    sessions = Repo.all(from s in Session, order_by: [desc: s.inserted_at])
    default_model = Application.get_env(:kora, :default_model) || "google/gemini-3.1-pro-preview"

    {:ok,
     assign(socket,
       sessions: sessions,
       available_models: Kora.LLM.OpenRouter.fallback_models(),
       form: to_form(%{"goal" => "", "model" => default_model})
     )}
  end

  @impl true
  def handle_info(:load_models, socket) do
    models = Kora.LLM.OpenRouter.list_models()
    socket =
      socket
      |> assign(available_models: models)
      |> push_event("store_models", %{models: Enum.map(models, &Tuple.to_list/1)})
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_cached_models", %{"models" => raw}, socket) when is_list(raw) do
    models =
      Enum.reduce(raw, [], fn
        [name, id], acc when is_binary(name) and is_binary(id) -> [{name, id} | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()
    if models != [] do
      {:noreply, assign(socket, available_models: models)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_session", %{"goal" => goal, "model" => model}, socket) do
    model = if model in [nil, ""], do: nil, else: model
    case Orchestrator.start_session(goal, model) do
      {:ok, session_id} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start session: #{inspect(reason)}")}
    end
  end
end
