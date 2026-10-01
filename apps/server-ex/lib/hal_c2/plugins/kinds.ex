defmodule HalC2.Plugins.Kind do
  @moduledoc """
  The callbacks every kind of plugin has (`use HalC2.Plugins.Kind` in a kind's
  behaviour):

    * `manifest/0`: `%{id, name, version, api_version, settings}`, where `settings`
      lists `%{key, label}` fields and a field with `secret: true` is kept in the
      MC's secret store rather than the settings document.
    * `validate_settings/1` (optional): `:ok`, or `{:error, message}` shown to the
      user when they save settings the plugin cannot use.
    * `start_link/1` (optional): the plugin's process, started with its settings
      under the plugin's own supervisor while the plugin is enabled.
  """

  defmacro __using__(_opts) do
    quote do
      @callback manifest() :: map
      @callback validate_settings(settings :: map) :: :ok | {:error, String.t()}
      @callback start_link(settings :: map) :: GenServer.on_start()
      @optional_callbacks validate_settings: 1, start_link: 1
    end
  end
end

defmodule HalC2.Plugins.ProviderAdapter do
  @capabilities ~w(interrupt active_steering fork rollback approvals plan_updates model_switching interaction_mode text_generation native_sessions usage_limits sign_in)a
  @moduledoc """
  An agent provider. The orchestration runs every turn through the adapter behind
  the thread's provider instance (`HalC2.Plugins.provider/1`); Codex, Claude and the
  ACP agents are bundled adapters (`HalC2.Plugins.Bundled`), and a plugin file with
  the same id replaces the bundled one.

  An adapter writes its turn into the thread's log with `HalC2.Orchestration.TurnWriter`
  (`started/1` when the turn runs, `finish/3` when it ends). `start_turn/2` returns
  once the turn is under way; a process it starts for the thread belongs under
  `HalC2.Plugins.sessions(driver)`, the plugin's own sessions supervisor. The process
  that calls `started/1` drives the turn: if it crashes before `finish/3`, the MC
  ends the turn as failed.

  The manifest's `provider:` map declares the rest (atom keys, all optional):

    * `driver`: the driver instances name (default: the plugin id).
    * `name`, `icon`, `accent_color`, `documentation_url`: how clients show it.
    * `capabilities`: what it can do, from `#{inspect(@capabilities)}`;
      anything left out is not offered (see `provider/3`, `session_capabilities/2`).
    * `runtime_modes`: the access modes it supports (default: all).
    * `models`: `[%{slug, name}]`.
    * `instance_settings`: `[%{key, label, secret}]` an instance of it needs.

  `providers/1` (optional) answers the `ServerProvider` snapshots itself; without
  it they are built from the manifest.

  A plugin that declares `native_sessions` has its session carried when a thread
  moves to another machine (`HalC2.PortableSessions`) if it also says where a session
  lives and how a copy is placed:

    * `session_files(native_id, cwd)`: the files of the session it keeps as
      `native_id` for work in `cwd`, as `[{name, path}]` with the main file first,
      each named relative to where `place_session/3` puts it.
    * `place_session(files, from, to)`: places a copy of `[{name, data}]` for the
      project at `to` (the session recorded `from`), never replacing a file already
      there, and answers `{:ok, native_id}`. The thread's next run there gets
      `fork: %{thread: native_id, carried: true, fallback: context}` and branches a
      new session from the copy; when it cannot open it, it starts a new one with
      `HalC2.Orchestration.Handoff.prompt(fallback, turn.text)`.

  Without them, or when either fails, the thread moves and its next run there gets
  a summary of the conversation.

  An adapter that declares `active_steering` implements `steer/3`: it hands
  `%{text, attachments}` (attachments shaped like a turn's) to the turn running as
  `run_id`, or answers `{:error, reason}` when the provider does not take it.
  """
  use HalC2.Plugins.Kind

  @runtime_modes ~w(approval-required auto-accept-edits auto full-access)

  @callback start_turn(thread_id :: String.t(), turn :: map) :: :ok
  @callback interrupt(thread_id :: String.t(), run_id :: String.t() | nil) ::
              :ok | {:error, String.t()}
  @callback steer(
              thread_id :: String.t(),
              run_id :: String.t(),
              message :: %{text: String.t(), attachments: [map]}
            ) ::
              :ok | {:error, String.t()}
  @callback respond(thread_id :: String.t(), request_id :: String.t(), response :: map) ::
              :ok | {:error, String.t()}
  @callback rollback(thread_id :: String.t(), plan :: map) :: {:ok, map} | {:error, String.t()}
  @callback providers(settings :: map) :: [map]
  @callback session_files(native_id :: String.t(), cwd :: String.t()) :: [{String.t(), Path.t()}]
  @callback place_session(files :: [{String.t(), binary}], from :: String.t(), to :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}
  @optional_callbacks interrupt: 2,
                      steer: 3,
                      respond: 3,
                      rollback: 2,
                      providers: 1,
                      session_files: 2,
                      place_session: 3

  @doc "The capabilities a plugin can declare."
  def capabilities, do: @capabilities

  @doc "The capabilities `module`'s manifest declares."
  def declared(provider), do: MapSet.new(provider[:capabilities] || [])

  @doc """
  The `ServerProvider` snapshot of instance `instance_id` of a plugin that declares
  `provider` (its manifest's `provider:` map).
  """
  def provider(provider, instance_id, driver) do
    can = declared(provider)

    %{
      "instanceId" => instance_id,
      "driver" => driver,
      "displayName" => provider[:name],
      "accentColor" => provider[:accent_color],
      "iconUrl" => provider[:icon],
      "showInteractionModeToggle" => :interaction_mode in can,
      "supportedRuntimeModes" => provider[:runtime_modes] || @runtime_modes,
      "requiresNewThreadForModelChange" => :model_switching not in can,
      "supportsConversationRollback" => :rollback in can,
      "supportsTextGeneration" => :text_generation in can,
      "setup" => %{
        "canAuthenticate" => :sign_in in can,
        "canInstall" => false,
        "documentationUrl" => provider[:documentation_url]
      },
      "enabled" => true,
      "installed" => true,
      "version" => nil,
      "status" => "ready",
      "availability" => "available",
      "auth" => %{"status" => "unknown"},
      "checkedAt" => HalC2.Orchestration.Entities.now(),
      "models" =>
        for(
          {model, index} <- Enum.with_index(provider[:models] || []),
          do: %{
            "slug" => to_string(model[:slug]),
            "name" => to_string(model[:name] || model[:slug]),
            "isCustom" => false,
            "isDefault" => index == 0,
            "capabilities" => nil
          }
        ),
      "slashCommands" => [],
      "skills" => []
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
    |> then(fn entry ->
      if :native_sessions in can,
        do:
          Map.put(entry, "nativeSessions", %{
            "canList" => true,
            "canLoad" => true,
            "canResume" => true,
            "canDelete" => false
          }),
        else: entry
    end)
  end

  @doc """
  A provider session's capabilities (`HalC2.Orchestration.Entities`) narrowed to what
  a plugin declares, so the core offers only what works.
  """
  def session_capabilities(base, provider) do
    can = declared(provider)
    approvals = :approvals in can
    plans = :plan_updates in can

    base
    |> put_in(["turns", "supportsInterrupt"], :interrupt in can)
    |> put_in(["turns", "supportsActiveSteering"], :active_steering in can)
    |> put_in(["turns", "supportsSteeringByInterruptRestart"], :active_steering not in can)
    |> put_in(["threads", "canForkThread"], :fork in can)
    |> put_in(["threads", "canForkFromTurn"], :fork in can)
    |> put_in(["threads", "canRollbackThread"], :rollback in can)
    |> put_in(["checkpointing", "providerCanRollbackConversation"], :rollback in can)
    |> put_in(["sessions", "supportsModelSwitchInSession"], :model_switching in can)
    |> put_in(["approvals", "supportsCommandApproval"], approvals)
    |> put_in(["approvals", "supportsFileChangeApproval"], approvals)
    |> put_in(["planning", "emitsPlanUpdated"], plans)
    |> put_in(["planning", "emitsTodoList"], plans)
  end
end

defmodule HalC2.Plugins.McpToolPack do
  @moduledoc """
  Tools offered to agents next to HAL-C2's own in the `hal-c2` MCP server (`HalC2.Mcp`),
  in projects that allow it. Tools are MCP tool definitions (`name`, `description`,
  `inputSchema`); a call answers JSON or an error the agent reads.
  """
  use HalC2.Plugins.Kind
  @callback tools(settings :: map) :: [map]
  @callback call_tool(name :: String.t(), arguments :: map, settings :: map) ::
              {:ok, term} | {:error, String.t()}
end

defmodule HalC2.Plugins.GitHost do
  @moduledoc """
  A git host the MC's pull request listing reads (`HalC2.PullRequests.list/1`) for
  projects whose remote is on it. A pull request is the listing's entry shape
  (`number`, `title`, `url`, `state`, `headBranch`, `baseBranch`, `updatedAt`, ...).
  """
  use HalC2.Plugins.Kind
  @callback host?(host :: String.t(), settings :: map) :: boolean
  @callback list_pull_requests(repository :: String.t(), settings :: map) ::
              {:ok, [map]} | {:error, String.t()}
end

defmodule HalC2.Plugins.NotificationChannel do
  @moduledoc """
  Delivers the MC's notifications (`HalC2.Plugins.notify/1`): a turn that finished
  while no client had its thread in the foreground arrives as
  `%{"type" => "turn.finished", "threadId", "title", "status"}`.
  """
  use HalC2.Plugins.Kind
  @callback notify(notification :: map, settings :: map) :: :ok | {:error, String.t()}
end

defmodule HalC2.Plugins.TextGeneration do
  @moduledoc """
  Writes titles, commit messages and pull request text (`HalC2.TextGeneration`) when
  the user picks the plugin's id as their text generation model. It answers a JSON
  object matching `schema`.
  """
  use HalC2.Plugins.Kind

  @callback generate(prompt :: String.t(), schema :: map, settings :: map) ::
              {:ok, map} | {:error, String.t()}
end
