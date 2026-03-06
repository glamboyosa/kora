defmodule KoraWeb.SessionLive.Show do
  use KoraWeb, :live_view
  alias Kora.Repo
  alias Kora.Sessions.Session
  alias Kora.Agents
  alias Kora.Messages.Message
  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kora.PubSub, "session:#{id}")
      send(self(), :load_models)
    end

    session = Repo.get!(Session, id)
    agents = Agents.list_agents(id)

    # We load messages for the selected agent. Default to root.
    selected_agent = Enum.find(agents, fn a -> a.name == "root" end) || List.first(agents)
    # Default: root expanded so the hierarchy is visible; children collapsible
    root_ids = agents |> Enum.filter(fn a -> a.parent_id == nil end) |> Enum.map(& &1.id) |> MapSet.new()

    messages =
      if selected_agent do
        Repo.all(
          from m in Message,
            where: m.agent_id == ^selected_agent.id,
            order_by: [asc: m.inserted_at]
        )
      else
        []
      end

    {:ok,
     assign(socket,
       session: session,
       agents: agents,
       agent_tree: build_agent_tree(agents),
       selected_agent: selected_agent,
       messages: messages,
       stream_token: "",
       spawn_modal: false,
       spawn_form: to_form(%{"goal" => "", "name" => ""}),
       chat_form: to_form(%{"content" => ""}),
       available_models: Kora.LLM.OpenRouter.fallback_models(),
       working_status: nil,
       expanded_messages: MapSet.new(),
       expanded_agents: root_ids
     )}
  end

  defp build_agent_tree(agents) do
    # Build nested list: [{agent, [children]}, ...]
    # 1. Map id -> agent
    # 2. Group by parent_id

    agents_by_parent = Enum.group_by(agents, & &1.parent_id)
    roots = agents_by_parent[nil] || []

    build_tree_recursive(roots, agents_by_parent)
  end

  defp build_tree_recursive(agents, lookup) do
    Enum.map(agents, fn agent ->
      children = lookup[agent.id] || []
      %{agent: agent, children: build_tree_recursive(children, lookup)}
    end)
  end

  @impl true
  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    agent = Enum.find(socket.assigns.agents, fn a -> a.id == agent_id end)

    if agent do
      messages =
        Repo.all(
          from m in Message, where: m.agent_id == ^agent.id, order_by: [asc: m.inserted_at]
        )

      {:noreply,
       assign(socket,
         selected_agent: agent,
         messages: messages,
         stream_token: "",
         chat_form: to_form(%{"content" => ""})
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_spawn_modal", _, socket) do
    {:noreply, assign(socket, spawn_modal: !socket.assigns.spawn_modal)}
  end

  def handle_event("toggle_message", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_messages
    new_expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end
    {:noreply, assign(socket, expanded_messages: new_expanded)}
  end

  def handle_event("toggle_agent_node", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_agents
    new_expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end
    {:noreply, assign(socket, expanded_agents: new_expanded)}
  end

  def handle_event("change_model", %{"model" => model}, socket) do
    agent = socket.assigns.selected_agent
    if agent && model != "" do
      case Agents.update_agent(agent, %{model: model}) do
        {:ok, updated} ->
          agents = Agents.list_agents(socket.assigns.session.id)
          agent_tree = build_agent_tree(agents)
          {:noreply,
           assign(socket,
             selected_agent: updated,
             agents: agents,
             agent_tree: agent_tree
           )}
        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update model")}
      end
    else
      {:noreply, socket}
    end
  end

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

  def handle_event("spawn_subagent", %{"goal" => goal, "name" => name}, socket) do
    # Manually spawn agent under selected agent
    parent = socket.assigns.selected_agent
    session = socket.assigns.session

    task_args = %{
      "name" => name,
      "goal" => goal,
      "context" => "Manually spawned via UI",
      # Inherit tools from parent? Or default?
      # Inherit
      "tools" => parent.tools
    }

    # We use Kora.Tools logic but called manually?
    # Kora.Tools.spawn_agent is private.
    # We should expose a context function for spawning.
    # But since we are in LiveView, we can just use create_agent + start_agent like in Tools.

    # Actually, let's call Kora.Tools.execute("spawn_agent", ...) via Task?
    # No, execute expects to return a result string. We just want to fire and forget here (or wait for confirmation).

    # Let's replicate logic cleanly.

    attrs = %{
      session_id: session.id,
      parent_id: parent.id,
      name: name,
      # Inherit model
      model: parent.model,
      goal: goal,
      context: "Manually spawned via UI",
      tools: parent.tools,
      # Will be started below
      status: :waiting,
      system_prompt: """
      You are a specialized subagent running inside Kora.
      Parent: #{parent.name}
      Goal: #{goal}
      """
    }

    case Kora.Agents.create_agent(attrs) do
      {:ok, agent} ->
        Kora.Agents.update_agent(agent, %{status: :running})
        Kora.AgentSupervisor.start_agent(id: agent.id)

        {:noreply,
         assign(socket, spawn_modal: false) |> put_flash(:info, "Spawned agent #{name}")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn: #{inspect(cs.errors)}")}
    end
  end

  def handle_event("send_message", %{"content" => content}, socket) do
    agent = socket.assigns.selected_agent

    if agent do
      Kora.Agent.add_message(agent.id, content)
      # Optimistic update? Or wait for PubSub update?
      # Wait for PubSub.
      {:noreply, assign(socket, chat_form: to_form(%{"content" => ""}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_agent", _, socket) do
    agent = socket.assigns.selected_agent

    if agent do
      Kora.Agent.retry(agent.id)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    agent = Enum.find(socket.assigns.agents, fn a -> a.id == agent_id end)

    if agent do
      messages =
        Repo.all(
          from m in Message, where: m.agent_id == ^agent.id, order_by: [asc: m.inserted_at]
        )

      {:noreply,
       assign(socket,
         selected_agent: agent,
         messages: messages,
         stream_token: "",
         chat_form: to_form(%{"content" => ""})
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:agent_token, %{agent_id: agent_id, chunk: chunk}}, socket) do
    if socket.assigns.selected_agent && socket.assigns.selected_agent.id == agent_id do
      {:noreply,
       assign(socket,
         stream_token: socket.assigns.stream_token <> chunk,
         working_status: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_working, %{agent_id: agent_id, message: message}}, socket) do
    if socket.assigns.selected_agent && socket.assigns.selected_agent.id == agent_id do
      {:noreply, assign(socket, working_status: message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_failed, %{agent_id: agent_id, error: error}}, socket) do
    # Refresh so UI shows :failed status and error; any agent in session may have failed
    agents = Agents.list_agents(socket.assigns.session.id)
    agent_tree = build_agent_tree(agents)

    socket =
      socket
      |> assign(agents: agents, agent_tree: agent_tree, working_status: nil)
      |> then(fn s ->
        if s.assigns.selected_agent && s.assigns.selected_agent.id == agent_id do
          assign(s, selected_agent: Agents.get_agent!(agent_id))
        else
          s
        end
      end)
      |> put_flash(:error, "Agent failed: #{error}")

    {:noreply, socket}
  end

  def handle_info({:agent_done, %{agent_id: agent_id, result: _result}}, socket) do
    # Refresh messages to get the final one from DB
    if socket.assigns.selected_agent && socket.assigns.selected_agent.id == agent_id do
      messages =
        Repo.all(
          from m in Message, where: m.agent_id == ^agent_id, order_by: [asc: m.inserted_at]
        )

      # We need to refresh the agent itself to update status to :done
      updated_agent = Agents.get_agent!(agent_id)

      # Also refresh the agent tree to show status update
      agents = Agents.list_agents(socket.assigns.session.id)

      {:noreply,
       assign(socket,
         messages: messages,
         stream_token: "",
         working_status: nil,
         selected_agent: updated_agent,
         agents: agents,
         agent_tree: build_agent_tree(agents),
         chat_form: to_form(%{"content" => ""})
       )}
    else
      # Still refresh agent list/tree for status updates
      agents = Agents.list_agents(socket.assigns.session.id)

      {:noreply,
       assign(socket,
         agents: agents,
         agent_tree: build_agent_tree(agents),
         working_status: nil,
         chat_form: to_form(%{"content" => ""})
       )}
    end
  end

  def handle_info(:load_models, socket) do
    models = Kora.LLM.OpenRouter.list_models()
    socket =
      socket
      |> assign(available_models: models)
      |> push_event("store_models", %{models: Enum.map(models, &Tuple.to_list/1)})
    {:noreply, socket}
  end

  def handle_info({:agent_spawned, _payload}, socket) do
    # Refresh agent list
    agents = Agents.list_agents(socket.assigns.session.id)

    {:noreply,
     assign(socket,
       agents: agents,
       agent_tree: build_agent_tree(agents),
       chat_form: to_form(%{"content" => ""})
     )}
  end

  # Catch-all for other events we don't handle yet
  def handle_info(_, socket), do: {:noreply, socket}

  attr :nodes, :list, required: true
  attr :selected_id, :string, default: nil
  attr :depth, :integer, default: 0
  attr :expanded_agents, :any, default: MapSet.new()

  def agent_tree(assigns) do
    ~H"""
    <div class="space-y-1">
      <%= for node <- @nodes do %>
        <% has_children = node.children != [] %>
        <% expanded = MapSet.member?(@expanded_agents, node.agent.id) %>
        <div class="flex flex-col">
          <div class="flex items-center">
            <div :if={@depth > 0} style={"width: #{@depth * 12}px"} class="h-px bg-muted shrink-0">
            </div>
            <%= if has_children do %>
              <button
                type="button"
                id={"toggle-agent-#{node.agent.id}"}
                phx-hook="PreserveScrollOnToggle"
                data-scroll-container="#messages-container"
                phx-click="toggle_agent_node"
                phx-value-id={node.agent.id}
                class="p-1 rounded hover:bg-accent text-muted-foreground shrink-0"
                title={if expanded, do: "Collapse", else: "Expand"}
              >
                <.icon name={if expanded, do: "hero-chevron-down", else: "hero-chevron-right"} class="w-3 h-3" />
              </button>
            <% else %>
              <div style="width: 20px" class="shrink-0"></div>
            <% end %>
            <button
              phx-click="select_agent"
              phx-value-id={node.agent.id}
              class={"flex-1 text-left px-2 py-1.5 rounded-md text-sm transition-colors flex items-center gap-2 min-w-0 #{if @selected_id == node.agent.id, do: "bg-primary text-primary-foreground", else: "hover:bg-accent"}"}
            >
              <div class="truncate flex-1 font-medium">{node.agent.name}</div>
              <div class="text-[10px] opacity-70 border border-current rounded px-1">
                {node.agent.status}
              </div>
            </button>
          </div>
          <%= if has_children && expanded do %>
            <.agent_tree nodes={node.children} selected_id={@selected_id} depth={@depth + 1} expanded_agents={@expanded_agents} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
