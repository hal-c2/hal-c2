defmodule T3.Plugins.Kind do
  @moduledoc """
  The callbacks every kind of plugin has (`use T3.Plugins.Kind` in a kind's
  behaviour):

    * `manifest/0`: `%{id, name, version, api_version, settings}`, where `settings`
      lists `%{key, label}` fields and a field with `secret: true` is kept in the
      node's secret store rather than the settings document.
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

defmodule T3.Plugins.ProviderAdapter do
  @moduledoc "A provider runtime. Discovered and listed; turns do not route to one yet."
  use T3.Plugins.Kind
end

defmodule T3.Plugins.McpToolPack do
  @moduledoc """
  Tools offered to agents next to T3's own in the `t3-code` MCP server (`T3.Mcp`),
  in projects that allow it. Tools are MCP tool definitions (`name`, `description`,
  `inputSchema`); a call answers JSON or an error the agent reads.
  """
  use T3.Plugins.Kind
  @callback tools(settings :: map) :: [map]
  @callback call_tool(name :: String.t(), arguments :: map, settings :: map) ::
              {:ok, term} | {:error, String.t()}
end

defmodule T3.Plugins.GitHost do
  @moduledoc """
  A git host the node's pull request listing reads (`T3.PullRequests.list/1`) for
  projects whose remote is on it. A pull request is the listing's entry shape
  (`number`, `title`, `url`, `state`, `headBranch`, `baseBranch`, `updatedAt`, ...).
  """
  use T3.Plugins.Kind
  @callback host?(host :: String.t(), settings :: map) :: boolean
  @callback list_pull_requests(repository :: String.t(), settings :: map) ::
              {:ok, [map]} | {:error, String.t()}
end

defmodule T3.Plugins.NotificationChannel do
  @moduledoc "Delivers the node's notifications. Not called by the node yet."
  use T3.Plugins.Kind
  @callback notify(notification :: map, settings :: map) :: :ok | {:error, String.t()}
end

defmodule T3.Plugins.TextGeneration do
  @moduledoc """
  Writes titles, commit messages and pull request text (`T3.TextGeneration`) when
  the user picks the plugin's id as their text generation model. It answers a JSON
  object matching `schema`.
  """
  use T3.Plugins.Kind

  @callback generate(prompt :: String.t(), schema :: map, settings :: map) ::
              {:ok, map} | {:error, String.t()}
end
