defmodule HalC2.Test.FakeOpenShell.Validator do
  @moduledoc """
  OpenShell 0.1.7's checks of a sandbox policy, ported so the fake gateway refuses
  what the real one does. `violations/1` gives `[]` for a policy 0.1.7 takes and a
  reason per check it fails otherwise.

  The sources, in OpenShell v0.1.7:

    * The gateway's create path (`crates/openshell-server/src/grpc/sandbox.rs:680-694`)
      refuses `_provider_` keys (`grpc/validation.rs:1056-1069`), then validates the
      policy (`crates/openshell-policy/src/lib.rs:1413-1685`), which runs the shared
      endpoint checks of `crates/openshell-policy/src/l7_validate.rs:71-90` (TLS,
      enforcement and access modes) and `:243-327` (L7 field combinations), and the
      MCP version checks of `lib.rs:1739-1789`.
    * The sandbox's supervisor refuses a policy it loads that fails its own L7 checks
      (`crates/openshell-supervisor-network/src/l7/mod.rs:1236-1700`), of which the
      MCP rule checks (`:891-982`, `:1029-1075`, `:1680-1700`) are ported here, as a
      sandbox that cannot load its policy never runs.

  Only what a HAL-C2 policy could get wrong is ported: TCP host selectors, GraphQL,
  SQL and middleware are left out.
  """

  alias HalC2.OpenShell.Proto.Openshell.Sandbox.V1, as: Sb

  # `openshell-policy-schema/src/lib.rs:31-40`
  @mcp_versions ~w(2025-03-26 2025-06-18 2025-11-25 2026-07-28)
  @l7 ~w(rest websocket graphql sql json-rpc mcp)

  def violations(%Sb.SandboxPolicy{} = policy) do
    reserved(policy) ++
      process(policy.process) ++
      landlock(policy.landlock) ++
      filesystem(policy.filesystem) ++
      Enum.flat_map(Enum.sort(policy.network_policies), fn {key, rule} ->
        name = if rule.name in [nil, ""], do: key, else: rule.name

        rule.endpoints
        |> Enum.with_index()
        |> Enum.flat_map(fn {ep, i} ->
          Enum.map(endpoint(ep), &"#{name}.endpoints[#{i}]: #{&1}")
        end)
      end)
  end

  defp reserved(policy) do
    for key <- Map.keys(policy.network_policies),
        String.starts_with?(key, "_provider_"),
        do: "network_policies key '#{key}' uses reserved '_provider_' prefix"
  end

  # lib.rs:1419-1434, 840-847
  defp process(nil), do: []

  defp process(%Sb.ProcessPolicy{} = p) do
    for {field, value} <- [run_as_user: p.run_as_user, run_as_group: p.run_as_group],
        value not in [nil, ""] and not identity?(value),
        do: "#{field} must be 'sandbox' or a numeric UID/GID, got '#{value}'"
  end

  defp identity?("sandbox"), do: true

  defp identity?(value) do
    case Integer.parse(value) do
      {n, ""} -> n >= 1 and n <= 4_294_967_294
      _ -> false
    end
  end

  # lib.rs:1439-1446; openshell-core/src/policy.rs:99-106
  defp landlock(%Sb.LandlockPolicy{compatibility: c})
       when c not in ["", "best_effort", "hard_requirement"],
       do: ["invalid landlock.compatibility '#{c}'"]

  defp landlock(_), do: []

  # lib.rs:1358-1411
  defp filesystem(nil), do: []

  defp filesystem(%Sb.FilesystemPolicy{read_only: ro, read_write: rw}) do
    paths = ro ++ rw

    if(length(paths) > 256, do: ["too many filesystem paths"], else: []) ++
      Enum.flat_map(paths, fn path ->
        cond do
          byte_size(path) > 4096 -> ["path too long: #{path}"]
          not String.starts_with?(path, "/") -> ["path must be absolute: #{path}"]
          ".." in Path.split(path) -> ["path contains '..': #{path}"]
          true -> []
        end
      end) ++
      for(
        path <- rw,
        String.trim_trailing(path, "/") == "",
        do: "read-write path is overly broad: #{path}"
      )
  end

  defp endpoint(%Sb.NetworkEndpoint{} = ep) do
    protocol = ep.protocol || ""
    mcp? = String.downcase(protocol) == "mcp"
    tcp? = String.downcase(protocol) == "tcp"
    access = access(ep.access)
    rules = ep.rules || []
    allow_all = mcp? and ep.mcp != nil and ep.mcp.allow_all_known_mcp_methods == true

    ports = if ep.ports == [], do: Enum.reject([ep.port], &(&1 == 0)), else: ep.ports

    host_errors =
      cond do
        String.trim(ep.host) == "" and (tcp? or ep.allowed_ips == []) ->
          ["endpoint host must not be empty"]

        ep.host in ["*", "**"] ->
          ["invalid host wildcard '#{ep.host}'"]

        String.starts_with?(ep.host, ["*.", "**."]) and length(String.split(ep.host, ".")) <= 2 ->
          ["TLD wildcard '#{ep.host}' is not allowed"]

        true ->
          []
      end

    port_errors =
      if(ports == [], do: ["endpoint '#{ep.host}' must declare at least one port"], else: []) ++
        for(p <- ports, p < 1 or p > 65_535, do: "invalid port #{p}")

    host_errors ++
      port_errors ++
      modes(ep) ++
      semantics(protocol, access, rules, ep.deny_rules || [], allow_all) ++
      if(ep.path not in [nil, ""] and not String.starts_with?(ep.path, "/") and ep.path != "**",
        do: ["path must start with '/' or be '**'"],
        else: []
      ) ++
      mcp_options(mcp?, ep) ++
      if(mcp?, do: mcp_rules(rules, allow_all, ep.mcp), else: [])
  end

  # l7_validate.rs:71-90. A TLS mode is unset (0.1.7 terminates TLS itself) or skip;
  # `terminate` and `passthrough` are refused.
  defp modes(ep) do
    tls =
      if ep.tls in [:NETWORK_TLS_MODE_UNSPECIFIED, :NETWORK_TLS_MODE_SKIP, 0, 1],
        do: [],
        else: [
          "unknown tls value #{inspect(ep.tls)}; omit the field to keep automatic TLS termination"
        ]

    enforcement =
      if is_atom(ep.enforcement),
        do: [],
        else: ["unknown enforcement enum value #{ep.enforcement}"]

    access = if is_atom(ep.access), do: [], else: ["unknown access enum value #{ep.access}"]
    tls ++ enforcement ++ access
  end

  defp access(:NETWORK_ACCESS_PRESET_READ_ONLY), do: "read-only"
  defp access(:NETWORK_ACCESS_PRESET_READ_WRITE), do: "read-write"
  defp access(:NETWORK_ACCESS_PRESET_FULL), do: "full"
  defp access(_), do: ""

  # l7_validate.rs:243-327, with rules_would_deny_all as lib.rs:1555-1566 computes it.
  defp semantics(protocol, access, rules, deny_rules, allow_all) do
    l7 = String.downcase(protocol)
    known? = l7 in @l7
    mcp? = l7 == "mcp"
    jsonrpc? = l7 == "json-rpc"
    rules? = rules != []
    deny_all? = rules? and Enum.all?(rules, &empty_allow?(&1.allow))

    [
      {protocol != "" and not known? and l7 != "tcp", "unknown protocol '#{protocol}'"},
      {l7 == "tcp" and (access != "" or rules? or deny_rules != []),
       "protocol tcp does not support access, rules, or deny_rules"},
      {rules? and access != "", "rules and access are mutually exclusive"},
      {(mcp? or jsonrpc?) and access != "",
       "protocol #{protocol} does not support access presets"},
      {jsonrpc? and not rules? and access == "",
       "protocol #{protocol} requires explicit rules with allow.method"},
      {known? and not mcp? and not jsonrpc? and not rules? and access == "",
       "protocol requires rules or access to define allowed traffic"},
      {mcp? and not rules? and access == "" and not allow_all,
       "protocol mcp requires rules when mcp.allow_all_known_mcp_methods is false"},
      {deny_all? and not (mcp? and allow_all),
       "rules would deny all traffic (no allow clause found)"},
      {deny_rules != [] and not known?, "deny_rules require protocol"},
      {deny_rules != [] and not mcp? and not rules? and access == "",
       "deny_rules require rules or access to define the base allow set"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp empty_allow?(nil), do: true

  defp empty_allow?(%Sb.L7Allow{} = a),
    do:
      Enum.all?(
        [a.method, a.path, a.command, a.operation_type, a.operation_name],
        &(&1 in [nil, ""])
      ) and
        a.fields == [] and map_size(a.params) == 0

  # lib.rs:1739-1789
  defp mcp_options(true, %{mcp: %Sb.McpOptions{versions: versions}}) do
    repeated = Enum.uniq(versions -- Enum.uniq(versions))

    Enum.map(repeated, &"repeats protocol version '#{&1}'") ++
      for v <- versions, v not in @mcp_versions, do: "unsupported protocol version '#{v}'"
  end

  defp mcp_options(false, %{mcp: %Sb.McpOptions{}, protocol: p}),
    do: ["uses protocol '#{p}' and cannot configure mcp options"]

  defp mcp_options(_, _), do: []

  # supervisor-network l7/mod.rs:891-982, 1029-1075 and 1680-1700.
  defp mcp_rules(rules, allow_all, mcp) do
    strict = mcp == nil or mcp.strict_tool_names != false
    tool_selectors? = Enum.any?(rules, &tool_selector?(&1.allow))

    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{allow: allow}, i} ->
      allow = allow || %Sb.L7Allow{}
      method = allow.method || ""
      loc = "rules[#{i}].allow"

      [
        {method == "" and not allow_all,
         "#{loc}.method: required when mcp.allow_all_known_mcp_methods is false"},
        {glob?(method) and not String.starts_with?(method, "tools/"),
         "#{loc}.method: MCP method globs are only valid for the tools/ method family"},
        {tool_selector?(allow) and method not in ["", "tools/call"],
         "#{loc}.method: must be tools/call when an MCP rule uses params.name"},
        {Enum.any?(Map.keys(allow.params), &(&1 != "name")),
         "#{loc}.params: MCP tool argument matching is not supported yet"},
        {not strict and tool_selector?(allow) and glob?(matcher(allow.params["name"])),
         "#{loc}.params.name: wildcard tool-name matchers require mcp.strict_tool_names"},
        {tool_selectors? and not tool_selector?(allow) and
           (calls_tools?(method) or (method == "" and allow_all)),
         "#{loc}: method matcher allows every tool call and conflicts with MCP tool allow rules"},
        {allow.path not in [nil, ""] or map_size(allow.query) > 0,
         "#{loc}: mcp L7 rules must use method/tool, not path/query"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    end)
  end

  defp tool_selector?(%Sb.L7Allow{params: %{"name" => m}}) when m != nil, do: true
  defp tool_selector?(_), do: false

  defp matcher(%Sb.L7QueryMatcher{glob: g, any: any}), do: Enum.join([g | any], ",")

  defp glob?(value), do: String.contains?(value, ["*", "?", "["])

  defp calls_tools?(method),
    do:
      method in ["tools/call", "*"] or
        (glob?(method) and Regex.match?(glob(method), "tools/call"))

  defp glob(pattern) do
    body =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("\\A" <> body <> "\\z")
  end
end
