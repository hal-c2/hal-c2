defmodule T3.Plugins.Bundled do
  @moduledoc """
  The provider adapters that ship with the node: Codex, Claude, and the ACP agents
  (the built-in ones and those added from the ACP registry). They are plugins like
  any other (`T3.Plugins`), except that they are on until the user turns them off,
  and a plugin file with the same id replaces one (how a bundled provider is
  updated without a new node version).

  The list is the `:bundled_plugins` application setting, so a node can start
  with none.
  """

  @doc "The bundled plugin modules."
  def modules,
    do:
      Application.get_env(:t3, :bundled_plugins, [
        __MODULE__.Codex,
        __MODULE__.Claude,
        __MODULE__.Acp
      ])

  @doc false
  def manifest(id, name, driver, capabilities) do
    %{
      id: id,
      name: name,
      version: T3.Upgrade.version(),
      api_version: T3.Plugins.api_version(),
      settings: [],
      provider: %{driver: driver, name: name, capabilities: capabilities}
    }
  end
end

defmodule T3.Plugins.Bundled.Codex do
  @moduledoc "Codex (`codex app-server`) as a bundled provider plugin."
  @behaviour T3.Plugins.ProviderAdapter
  alias T3.Codex.ThreadRuntime

  @impl true
  def manifest,
    do:
      T3.Plugins.Bundled.manifest(
        "codex",
        "Codex",
        "codex",
        ~w(interrupt active_steering fork rollback approvals plan_updates model_switching interaction_mode text_generation usage_limits)a
      )

  @impl true
  defdelegate start_turn(thread_id, turn), to: ThreadRuntime
  @impl true
  defdelegate interrupt(thread_id, run_id), to: ThreadRuntime
  @impl true
  defdelegate steer(thread_id, run_id, text), to: ThreadRuntime
  @impl true
  defdelegate respond(thread_id, request_id, response), to: ThreadRuntime
  @impl true
  defdelegate rollback(thread_id, plan), to: ThreadRuntime

  @impl true
  def providers(_settings),
    do:
      for(
        entry <- [T3.Codex.Provider.entry()],
        entry != nil,
        do: T3.ProviderUsageLimits.put(entry)
      )
end

defmodule T3.Plugins.Bundled.Claude do
  @moduledoc "Claude (the Claude Agent SDK) as a bundled provider plugin."
  @behaviour T3.Plugins.ProviderAdapter
  alias T3.Claude.ThreadRuntime

  @impl true
  def manifest,
    do:
      T3.Plugins.Bundled.manifest(
        "claude",
        "Claude",
        "claudeAgent",
        ~w(interrupt active_steering fork rollback approvals plan_updates model_switching interaction_mode text_generation usage_limits)a
      )

  @impl true
  defdelegate start_turn(thread_id, turn), to: ThreadRuntime
  @impl true
  defdelegate interrupt(thread_id, run_id), to: ThreadRuntime
  @impl true
  defdelegate steer(thread_id, run_id, text), to: ThreadRuntime
  @impl true
  defdelegate respond(thread_id, request_id, response), to: ThreadRuntime
  @impl true
  defdelegate rollback(thread_id, plan), to: ThreadRuntime

  @impl true
  def providers(_settings),
    do:
      for(
        entry <- [T3.Claude.Provider.entry()],
        entry != nil,
        do: T3.ProviderUsageLimits.put(entry)
      )
end

defmodule T3.Plugins.Bundled.Acp do
  @moduledoc """
  Every ACP agent (`T3.Acp`): the built-in ones and those added from the ACP
  registry, which need no plugin of their own.
  """
  @behaviour T3.Plugins.ProviderAdapter
  alias T3.Acp.ThreadRuntime

  @impl true
  def manifest,
    do:
      T3.Plugins.Bundled.manifest(
        "acp",
        "ACP agents",
        "acp",
        ~w(interrupt rollback approvals plan_updates model_switching interaction_mode native_sessions sign_in)a
      )

  @impl true
  defdelegate start_turn(thread_id, turn), to: ThreadRuntime
  @impl true
  defdelegate interrupt(thread_id, run_id), to: ThreadRuntime
  @impl true
  defdelegate steer(thread_id, run_id, text), to: ThreadRuntime
  @impl true
  defdelegate respond(thread_id, request_id, response), to: ThreadRuntime
  @impl true
  defdelegate rollback(thread_id, plan), to: ThreadRuntime

  @impl true
  def providers(_settings), do: T3.Acp.entries()
end
