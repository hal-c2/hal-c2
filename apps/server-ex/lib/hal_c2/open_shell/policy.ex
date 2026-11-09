defmodule HalC2.OpenShell.Policy do
  @moduledoc """
  The policy a review sandbox runs under (#1412), and the check of what the gateway
  composed from it before an agent starts.

  A review sandbox reaches two places and nothing else: its model's endpoints on its
  API, with the credential OpenShell injects for the sandbox's provider, and the MC's
  report broker
  (`HalC2.OpenShell.Broker`), as MCP with one tool. Both are enforced, named by exact
  host, port and binary, and Landlock is a hard requirement, so a kernel without it
  fails the sandbox rather than running it open.

  OpenShell 0.1.7 refuses a policy its validator does not take, and the fake gateway
  of the tests runs a port of that validator (`HalC2.Test.FakeOpenShell.Validator`):
  a policy change that 0.1.7 would refuse fails there too.

  `check/2` reads the policy the gateway says the sandbox runs (`GetSandboxConfig`),
  which a gateway-wide policy may have added to, and refuses anything wider than
  `review/1` asked for.
  """

  alias HalC2.OpenShell.Proto.Openshell.Sandbox.V1, as: Sb

  @mcp_version "2025-06-18"
  # The MCP methods an agent's client calls before and around its one tool call. An
  # MCP endpoint lets through only the methods its rules name.
  @mcp_methods ~w(initialize notifications/initialized ping tools/list)
  # The largest JSON-RPC body the broker takes: a report with many comments fits.
  @broker_body 262_144
  @home "/sandbox/home"
  # The only paths a review writes, each a tmpfs of this many bytes, so a review
  # cannot fill this machine's disk. A tmpfs is charged to the sandbox's memory.
  @writable [{"/sandbox", 2_147_483_648}, {"/tmp", 536_870_912}]

  @doc "Where a review's agent keeps its files, a fresh directory of the sandbox."
  def home, do: @home

  @doc "The paths a review writes, `{path, bytes}`: its whole disk."
  def writable, do: @writable

  @doc "The MCP revision the broker speaks, the one the policy lets through."
  def mcp_version, do: @mcp_version

  @doc "The largest request body the broker and the policy accept."
  def broker_body, do: @broker_body

  @doc """
  The policy for a review: `model` is `%{host, port, requests, binaries, provider}`
  (the API the agent calls, the `{method, path}` of each request it makes there, the
  agent's executables, the OpenShell provider holding its key),
  `broker` is `%{host, port, path, ips}` (where the report broker listens, as the
  sandbox reaches it) and `tool` the one tool the broker takes a call of.
  """
  def review(%{model: model, broker: broker, tool: tool}) do
    # A tool name is matched as a glob, so one with a glob's characters would let more
    # through than the one tool.
    unless tool =~ ~r/\A[A-Za-z0-9_.-]+\z/, do: raise(ArgumentError, "not a tool name: #{tool}")

    binaries = Enum.map(model.binaries, &%Sb.NetworkBinary{path: &1})

    %Sb.SandboxPolicy{
      version: 1,
      filesystem: %Sb.FilesystemPolicy{
        include_workdir: true,
        read_only: ~w(/usr /lib /lib64 /bin /sbin /etc /opt),
        read_write: Enum.map(@writable, &elem(&1, 0))
      },
      landlock: %Sb.LandlockPolicy{compatibility: "hard_requirement"},
      process: %Sb.ProcessPolicy{run_as_user: "sandbox", run_as_group: "sandbox"},
      network_policies: %{
        "model" => %Sb.NetworkPolicyRule{
          name: "model",
          binaries: binaries,
          endpoints: [
            %Sb.NetworkEndpoint{
              host: model.host,
              port: model.port,
              protocol: "rest",
              # Unset: 0.1.7 terminates TLS by itself and takes no other mode but skip.
              enforcement: :NETWORK_ENFORCEMENT_MODE_ENFORCE,
              # Only these: the key opens the rest of the user's account on the API too,
              # and every program the agent starts reaches this endpoint as it does.
              rules: model_rules(model.requests),
              credential_binding: %Sb.NetworkCredentialBinding{provider: model.provider}
            }
          ]
        },
        "report" => %Sb.NetworkPolicyRule{
          name: "report",
          binaries: binaries,
          endpoints: [
            %Sb.NetworkEndpoint{
              host: broker.host,
              port: broker.port,
              path: broker.path,
              protocol: "mcp",
              enforcement: :NETWORK_ENFORCEMENT_MODE_ENFORCE,
              allowed_ips: broker.ips,
              json_rpc_max_body_bytes: @broker_body,
              rules: report_rules(tool),
              mcp: %Sb.McpOptions{strict_tool_names: true, versions: [@mcp_version]}
            }
          ]
        }
      }
    }
  end

  # Each path exactly, any query: a glob in one would let more through than it names.
  defp model_rules(requests) do
    for {method, path} <- requests do
      unless method =~ ~r/\A[A-Z]+\z/ and path =~ ~r/\A(\/[A-Za-z0-9_.-]+)+\z/,
        do: raise(ArgumentError, "not one request: #{method} #{path}")

      %Sb.L7Rule{allow: %Sb.L7Allow{method: method, path: path}}
    end
  end

  # The handshake and listing, then `tools/call` of `tool` alone.
  defp report_rules(tool) do
    Enum.map(@mcp_methods, &%Sb.L7Rule{allow: %Sb.L7Allow{method: &1}}) ++
      [
        %Sb.L7Rule{
          allow: %Sb.L7Allow{
            method: "tools/call",
            params: %{"name" => %Sb.L7QueryMatcher{glob: tool}}
          }
        }
      ]
  end

  @doc """
  `:ok` when the composed `policy` is no wider than `wanted` (`review/1`'s): the same
  paths readable and writable and the same user, as a gateway-wide policy replaces
  them too; the same rules, each endpoint and binary exactly as asked, Landlock
  required, nothing in audit mode, no TLS skipped, no credential let through
  uninspected and no middleware. Otherwise `{:error, why}`.
  """
  def check(%Sb.SandboxPolicy{} = policy, %Sb.SandboxPolicy{} = wanted) do
    cond do
      policy.landlock == nil or policy.landlock.compatibility != "hard_requirement" ->
        {:error, "Landlock is not a hard requirement"}

      filesystem(policy.filesystem) != filesystem(wanted.filesystem) ->
        {:error, "the gateway changes the paths it may read or write"}

      policy.process != wanted.process ->
        {:error, "the gateway changes the user it runs as"}

      map_size(policy.network_middlewares || %{}) > 0 ->
        {:error, "the gateway adds network middleware"}

      Map.keys(policy.network_policies) |> Enum.sort() !=
          Map.keys(wanted.network_policies) |> Enum.sort() ->
        {:error, "the gateway adds network rules"}

      rule = Enum.find(Map.keys(wanted.network_policies), &(not same_rule?(policy, wanted, &1))) ->
        {:error, "network rule #{rule} is not the one asked for"}

      true ->
        :ok
    end
  end

  def check(_policy, _wanted), do: {:error, "the gateway reports no policy"}

  # In any order, as a gateway may keep them.
  defp filesystem(%Sb.FilesystemPolicy{} = fs),
    do: %{fs | read_only: Enum.sort(fs.read_only), read_write: Enum.sort(fs.read_write)}

  defp filesystem(other), do: other

  defp same_rule?(policy, wanted, name) do
    got = policy.network_policies[name]
    want = wanted.network_policies[name]

    paths = fn rule -> rule.binaries |> Enum.map(& &1.path) |> Enum.sort() end

    paths.(got) == paths.(want) and Enum.all?(got.binaries, &exact?(&1.path)) and
      length(got.endpoints) == length(want.endpoints) and
      Enum.all?(Enum.zip(endpoints(got), endpoints(want)), fn {g, w} -> same_endpoint?(g, w) end)
  end

  # Endpoints, their ports and their addresses in any order, as a gateway may keep
  # them. A rule's L7 rules keep theirs.
  defp endpoints(rule) do
    rule.endpoints
    |> Enum.map(&%{&1 | ports: Enum.sort(&1.ports), allowed_ips: Enum.sort(&1.allowed_ips)})
    |> Enum.sort_by(&{&1.host, &1.port, &1.ports, &1.path})
  end

  # The fields that decide what an endpoint lets through, compared whole.
  @endpoint_fields ~w(host port ports protocol tls enforcement access rules allowed_ips path
                      json_rpc_max_body_bytes mcp credential_binding allow_uninspected_credentials
                      deny_rules)a

  defp same_endpoint?(got, want) do
    got.enforcement == :NETWORK_ENFORCEMENT_MODE_ENFORCE and
      got.tls != :NETWORK_TLS_MODE_SKIP and got.allow_uninspected_credentials != true and
      exact?(got.host) and Enum.all?(got.allowed_ips, &exact?/1) and
      Map.take(got, @endpoint_fields) == Map.take(want, @endpoint_fields)
  end

  defp exact?(value), do: is_binary(value) and value != "" and not String.contains?(value, "*")
end
