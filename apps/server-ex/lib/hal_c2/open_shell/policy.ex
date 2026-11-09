defmodule HalC2.OpenShell.Policy do
  @moduledoc """
  The policy a review sandbox runs under (#1412), and the check of what the gateway
  composed from it before an agent starts.

  A review sandbox reaches two places and nothing else: its model's API, with the
  credential OpenShell injects for the sandbox's provider, and the MC's report broker
  (`HalC2.OpenShell.Broker`), as MCP with one tool. Both are enforced, named by exact
  host, port and binary, and Landlock is a hard requirement, so a kernel without it
  fails the sandbox rather than running it open.

  `check/2` reads the policy the gateway says the sandbox runs (`GetSandboxConfig`),
  which a gateway-wide policy may have added to, and refuses anything wider than
  `review/1` asked for.
  """

  alias HalC2.OpenShell.Proto.Openshell.Sandbox.V1, as: Sb

  @mcp_version "2025-06-18"
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
  The policy for a review: `model` is `%{host, port, binaries, provider}` (the API the
  agent calls, the agent's executables, the OpenShell provider holding its key) and
  `broker` is `%{host, port, path, ips}` (where the report broker listens, as the
  sandbox reaches it).
  """
  def review(%{model: model, broker: broker}) do
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
              tls: :NETWORK_TLS_MODE_TERMINATE,
              enforcement: :NETWORK_ENFORCEMENT_MODE_ENFORCE,
              access: :NETWORK_ACCESS_PRESET_READ_WRITE,
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
              mcp: %Sb.McpOptions{strict_tool_names: true, versions: [@mcp_version]}
            }
          ]
        }
      }
    }
  end

  @doc """
  `:ok` when the composed `policy` is no wider than `wanted` (`review/1`'s): the same
  rules, each endpoint and binary exactly as asked, Landlock required, nothing in
  audit mode, no TLS skipped, no credential let through uninspected and no
  middleware. Otherwise `{:error, why}`.
  """
  def check(%Sb.SandboxPolicy{} = policy, %Sb.SandboxPolicy{} = wanted) do
    cond do
      policy.landlock == nil or policy.landlock.compatibility != "hard_requirement" ->
        {:error, "Landlock is not a hard requirement"}

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

  defp same_rule?(policy, wanted, name) do
    got = policy.network_policies[name]
    want = wanted.network_policies[name]

    paths = fn rule -> rule.binaries |> Enum.map(& &1.path) |> Enum.sort() end

    paths.(got) == paths.(want) and Enum.all?(got.binaries, &exact?(&1.path)) and
      length(got.endpoints) == length(want.endpoints) and
      Enum.all?(Enum.zip(got.endpoints, want.endpoints), fn {g, w} -> same_endpoint?(g, w) end)
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
