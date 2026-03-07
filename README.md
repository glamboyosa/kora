# Kora

**Local-first multi-agent runtime on the BEAM.** Each agent is an OTP process; the LLM can spawn subagents via a DynamicSupervisor. SQLite-backed, streams to the browser.

---

**Status: WIP.** Packaging is in progress: you can run from source or with Docker today. A .dmg (desktop app) and Burrito-built binary are planned—the desktop app uses a sidecar pattern (Tauri launches the Elixir server as a background process.

## Install (macOS / Linux)

When release assets are available, you can install with:

```bash
curl -sL https://raw.githubusercontent.com/glamboyosa/kora/main/install.sh | bash
```

Then open Kora.app (macOS) or run `./kora` (Linux).

## Run the web app

**From source (dev):**

```bash
cp .env.example .env   # set OPENROUTER_API_KEY
mix setup
mix phx.server
```

Then open [http://localhost:4000](http://localhost:4000).

**With Docker:**

```bash
export OPENROUTER_API_KEY=your_key
docker compose up --build
```

Then open [http://localhost:4000](http://localhost:4000). Optional: set `EXA_API_KEY` for real web search. For production, set `SECRET_KEY_BASE` (e.g. `mix phx.gen.secret`).

## What it does

- **Sessions & agents:** Create a session with a goal; a root agent runs and can call tools (file read/write, web search, etc.).
- **Subagents:** The LLM can call `spawn_agent` to create child agents (e.g. “research X”, “write Y”); each is a supervised OTP process.
- **Persistence:** Sessions, agents, and messages live in SQLite; you can restart and resume.
- **UI:** Phoenix LiveView dashboard: agent tree, streaming replies, model switcher (OpenRouter), expand/collapse.

## Requirements

- Elixir 1.15+, Erlang/OTP 26+
- [OpenRouter](https://openrouter.ai) API key (for LLM). Optional: Exa API key for web search.
