defmodule HalC2Plugins.CliProxyApi.Instances do
  @moduledoc """
  The provider instances the plugin keeps in Settings → Providers, "Claude via
  CLIProxyAPI" (`claude`) and "Codex via CLIProxyAPI" (`codex`), and when it puts
  them, as plain functions.

  The plugin owns only what routes an agent through the proxy: Claude's
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and an empty `ANTHROPIC_API_KEY`, and
  a Claude home of its own; Codex's `-c` overrides naming the proxy as its model
  provider and the variable that carries the key. Everything else is the user's: a
  rename, a colour, switching it off and variables of their own are kept whenever
  the plugin puts the instance again.

  It never fights the user. An instance is put when the plugin first adds it, and
  again only when what it owns changes (the port, the key, the address); an edit the
  user makes to the plugin's own fields stands until then. An instance the user
  deletes is `dismissed` in the plugin's ledger and not added again until the user
  adds it back from the page. One missing as the plugin starts was taken out while
  it was off (`HalC2.Plugins` does that), so it is added back.

  The ledger is `%{name => %{"state" => "created" | "dismissed", "digest" => hex}}`:
  the digest of what the plugin last put, never the key itself.
  """

  @names ["claude", "codex"]
  @labels %{"claude" => "Claude via CLIProxyAPI", "codex" => "Codex via CLIProxyAPI"}
  @key_variable "CLIPROXYAPI_API_KEY"

  def names, do: @names
  def label(name), do: @labels[name]

  @doc """
  The instance `name` routes through the proxy at `base` (`http://127.0.0.1:8317`)
  with the client key `key`; Claude's home is `claude_home`.
  """
  def desired("claude", base, key, claude_home) do
    %{
      "driver" => "claudeAgent",
      "displayName" => @labels["claude"],
      "enabled" => true,
      "environment" => [
        variable("ANTHROPIC_BASE_URL", base, false),
        variable("ANTHROPIC_AUTH_TOKEN", key, true),
        variable("ANTHROPIC_API_KEY", "", false)
      ],
      "config" => %{"homePath" => claude_home}
    }
  end

  def desired("codex", base, key, _claude_home) do
    %{
      "driver" => "codex",
      "displayName" => @labels["codex"],
      "enabled" => true,
      "environment" => [variable(@key_variable, key, true)],
      "config" => %{"launchArgs" => codex_args(base)}
    }
  end

  @doc """
  Codex's own provider table, given on its command line: `codex app-server -c …`
  reads each `-c key=value` as TOML, and a value that is not TOML as a string.
  """
  def codex_args(base) do
    Enum.map_join(
      [
        "model_provider=cliproxyapi",
        "model_providers.cliproxyapi.name=CLIProxyAPI",
        "model_providers.cliproxyapi.base_url=#{String.trim_trailing(base, "/")}/v1",
        "model_providers.cliproxyapi.env_key=#{@key_variable}",
        "model_providers.cliproxyapi.wire_api=responses"
      ],
      " ",
      &"-c #{&1}"
    )
  end

  @doc "The digest of what the plugin owns in `instance`."
  def digest(instance) do
    owned = Map.take(instance, ["driver", "environment", "config"])
    :crypto.hash(:sha256, :erlang.term_to_binary(owned)) |> Base.encode16(case: :lower)
  end

  @doc """
  What to do about instance `name`:

    * `{:put, instance}`: put `instance` (`desired` laid over the user's `current`),
    * `:dismiss`: the user deleted it, record that and leave it deleted,
    * `:keep`: nothing.

  `phase` is `:start` as the plugin starts and `:running` after.
  """
  def decide(entry, current, desired, phase) do
    digest = digest(desired)

    case {entry, current} do
      {%{"state" => "dismissed"}, _} -> :keep
      {nil, nil} -> {:put, desired}
      {nil, current} -> {:put, merge(current, desired)}
      {%{"state" => "created"}, nil} when phase == :start -> {:put, desired}
      {%{"state" => "created"}, nil} -> :dismiss
      {%{"digest" => ^digest}, _current} -> :keep
      {_entry, current} -> {:put, merge(current, desired)}
    end
  end

  @doc """
  `desired` over what the user made of `current`: the user's name, colour, on or off
  and variables of their own stay, the plugin's variables and config keys are its
  own. A sensitive variable the user set comes back redacted, and the MC keeps its
  sealed value when it is written back so.
  """
  def merge(current, desired) do
    ours = MapSet.new(desired["environment"], & &1["name"])
    theirs = Enum.reject(current["environment"] || [], &MapSet.member?(ours, &1["name"]))

    current
    |> Map.merge(Map.take(desired, ["driver"]))
    |> Map.put("environment", desired["environment"] ++ theirs)
    |> Map.put("config", Map.merge(current["config"] || %{}, desired["config"]))
  end

  defp variable(name, value, sensitive),
    do: %{"name" => name, "value" => value, "sensitive" => sensitive}
end
