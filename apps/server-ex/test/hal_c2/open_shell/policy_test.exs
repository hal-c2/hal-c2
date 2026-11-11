defmodule HalC2.OpenShell.PolicyTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell.Policy
  alias HalC2.OpenShell.Proto.Openshell.Sandbox.V1, as: Sb
  alias HalC2.Test.FakeOpenShell.Validator

  @review %{
    model: %{
      host: "api.anthropic.com",
      port: 443,
      requests: [{"POST", "/v1/messages"}, {"GET", "/v1/models"}],
      binaries: ["/usr/local/bin/claude"],
      provider: "hal-c2-review-1"
    },
    broker: %{host: "host.openshell.internal", port: 4100, path: "/mcp", ips: ["172.17.0.1"]},
    tool: "code_review_report"
  }

  defp report(policy), do: hd(policy.network_policies["report"].endpoints)
  defp model(policy), do: hd(policy.network_policies["model"].endpoints)

  test "OpenShell 0.1.7 takes a review's policy" do
    policy = Policy.review(@review)

    assert Validator.violations(policy) == []
    # It survives the wire unchanged, as the gateway decodes it.
    assert Validator.violations(Sb.SandboxPolicy.decode(Sb.SandboxPolicy.encode(policy))) == []
    assert Policy.check(policy, policy) == :ok
  end

  # 0.1.7's supervisor adds these once the sandbox is up; a review never asks for them,
  # so a gateway that adds less leaves it narrower.
  test "the supervisor's own paths pass the read-back, and only as it adds them" do
    wanted = Policy.review(@review)
    refute "/proc" in wanted.filesystem.read_only
    refute "/dev/null" in wanted.filesystem.read_write

    add = fn policy, read, write ->
      update_in(
        policy.filesystem,
        &%{&1 | read_only: &1.read_only ++ read, read_write: &1.read_write ++ write}
      )
    end

    assert Policy.check(add.(wanted, ~w(/var/log /proc /dev/urandom), ~w(/dev/null)), wanted) ==
             :ok

    for {read, write} <- [{~w(/home), []}, {[], ~w(/proc)}, {[], ~w(/var/log)}] do
      assert Policy.check(add.(wanted, read, write), wanted) ==
               {:error, "the gateway changes the paths it may read or write"}
    end
  end

  # A gateway may keep a rule's endpoints, ports and addresses in its own order; what
  # they let through is what decides.
  test "a policy kept in another order is the one asked for, and one wider is not" do
    review = put_in(@review.broker.ips, ["172.17.0.1", "169.254.1.2"])
    wanted = Policy.review(review)

    reorder = fn policy, fun ->
      update_in(policy.network_policies["report"].endpoints, fn endpoints ->
        endpoints |> Enum.map(fun) |> Enum.reverse()
      end)
    end

    kept = reorder.(wanted, &%{&1 | allowed_ips: Enum.reverse(&1.allowed_ips)})
    assert Policy.check(kept, wanted) == :ok

    wider = reorder.(wanted, &%{&1 | allowed_ips: ["10.0.0.9" | &1.allowed_ips]})
    assert Policy.check(wider, wanted) == {:error, "network rule report is not the one asked for"}
  end

  # 0.1.7 adds one per provider attached, with nothing in it.
  test "the empty rule the gateway adds for a provider is no widening, and one with an endpoint is" do
    wanted = Policy.review(@review)
    add = &put_in(wanted.network_policies["_provider_review-1"], &1)

    assert Policy.check(add.(%Sb.NetworkPolicyRule{name: "_provider_review-1"}), wanted) == :ok

    open = %Sb.NetworkPolicyRule{name: "_provider_review-1", endpoints: [model(wanted)]}
    assert Policy.check(add.(open), wanted) == {:error, "the gateway adds network rules"}

    binary = %Sb.NetworkPolicyRule{
      name: "_provider_review-1",
      binaries: [%Sb.NetworkBinary{path: "/bin/sh"}]
    }

    assert Policy.check(add.(binary), wanted) == {:error, "the gateway adds network rules"}

    other = %Sb.NetworkPolicyRule{name: "extra"}

    assert Policy.check(put_in(wanted.network_policies["extra"], other), wanted) ==
             {:error, "the gateway adds network rules"}
  end

  test "the model's TLS is left to OpenShell to terminate, never skipped" do
    assert model(Policy.review(@review)).tls == :NETWORK_TLS_MODE_UNSPECIFIED
  end

  # The key is the user's: with it the rest of the API reads their files, and every
  # program the agent starts reaches the endpoint as the agent does.
  test "the model endpoint lets through its model's requests and nothing else" do
    endpoint = model(Policy.review(@review))

    assert endpoint.access == :NETWORK_ACCESS_PRESET_UNSPECIFIED
    assert Enum.map(endpoint.rules, &{&1.allow.method, &1.allow.path}) == @review.model.requests

    for widen <- [
          &%{&1 | rules: [], access: :NETWORK_ACCESS_PRESET_READ_WRITE},
          &%{
            &1
            | rules: [
                %Sb.L7Rule{allow: %Sb.L7Allow{method: "GET", path: "/v1/files/**"}} | &1.rules
              ]
          }
        ] do
      wider = put_model(Policy.review(@review), widen)
      assert Validator.violations(wider) == []

      assert Policy.check(wider, Policy.review(@review)) ==
               {:error, "network rule model is not the one asked for"}
    end
  end

  # A gateway-wide policy can set any endpoint field, and many widen what gets through:
  # each is compared, all but the markers the gateway derives itself.
  test "an endpoint the gateway changes in any field is not the one asked for" do
    wanted = Policy.review(@review)

    for change <- [
          request_body_credential_rewrite: true,
          websocket_credential_rewrite: true,
          credential_signing: "sigv4",
          signing_service: "bedrock",
          allow_encoded_slash: true,
          persisted_queries: "allow_registered",
          graphql_max_body_bytes: 1_048_576,
          advisor_proposed: true
        ] do
      wider = put_model(wanted, &struct!(&1, [change]))

      assert Policy.check(wider, wanted) ==
               {:error, "network rule model is not the one asked for"},
             "#{inspect(change)} passed"
    end

    marked = put_model(wanted, &%{&1 | provider_credentialed: true, token_grant_owner: "grant"})
    assert Policy.check(marked, wanted) == :ok
  end

  test "a model request that is a glob is refused" do
    for request <- [{"GET", "/v1/files/**"}, {"*", "/v1/messages"}, {"POST", "/v1/*"}] do
      review = put_in(@review.model.requests, [request])
      assert_raise ArgumentError, fn -> Policy.review(review) end
    end
  end

  test "the report endpoint lets through the MCP handshake and a call of the one tool" do
    rules = report(Policy.review(@review)).rules

    assert Enum.map(rules, & &1.allow.method) ==
             ~w(initialize notifications/initialized ping tools/list tools/call)

    assert [%{allow: %{params: %{"name" => %Sb.L7QueryMatcher{glob: "code_review_report"}}}}] =
             Enum.filter(rules, &(&1.allow.method == "tools/call"))

    # Only `tools/call` names a tool, and nothing lets every method through.
    assert Enum.all?(rules, &(map_size(&1.allow.params) == 0 or &1.allow.method == "tools/call"))
    refute report(Policy.review(@review)).mcp.allow_all_known_mcp_methods
  end

  test "a tool name that is a glob is refused" do
    assert_raise ArgumentError, fn -> Policy.review(%{@review | tool: "code_review_*"}) end
  end

  describe "the ported validator refuses what 0.1.7 does" do
    test "a TLS mode of terminate or passthrough" do
      for tls <- [:NETWORK_TLS_MODE_TERMINATE, :NETWORK_TLS_MODE_PASSTHROUGH] do
        policy = put_model(Policy.review(@review), &%{&1 | tls: tls})
        assert [violation] = Validator.violations(policy)
        assert violation =~ "unknown tls value"
      end
    end

    test "an MCP endpoint with no rules" do
      policy = put_report(Policy.review(@review), &%{&1 | rules: []})

      assert Validator.violations(policy) == [
               "report.endpoints[0]: protocol mcp requires rules when mcp.allow_all_known_mcp_methods is false"
             ]
    end

    test "an MCP rule that lets every tool through beside a tool rule" do
      wide = %Sb.L7Rule{allow: %Sb.L7Allow{method: "tools/*"}}
      policy = put_report(Policy.review(@review), &%{&1 | rules: [wide | &1.rules]})
      assert [violation] = Validator.violations(policy)
      assert violation =~ "allows every tool call"
    end

    test "an access preset on an MCP endpoint, and an MCP revision it does not know" do
      policy =
        put_report(Policy.review(@review), fn ep ->
          %{
            ep
            | access: :NETWORK_ACCESS_PRESET_FULL,
              mcp: %{ep.mcp | versions: ["2024-11-05"]}
          }
        end)

      violations = Validator.violations(policy)
      assert Enum.any?(violations, &(&1 =~ "rules and access are mutually exclusive"))
      assert Enum.any?(violations, &(&1 =~ "does not support access presets"))
      assert Enum.any?(violations, &(&1 =~ "unsupported protocol version '2024-11-05'"))
    end

    test "a rule key the gateway keeps for providers, and a read-write root" do
      policy = Policy.review(@review)
      rule = policy.network_policies["model"]

      policy = %{
        policy
        | network_policies: Map.put(policy.network_policies, "_provider_x", rule),
          filesystem: %{policy.filesystem | read_write: ["/"]}
      }

      violations = Validator.violations(policy)
      assert Enum.any?(violations, &(&1 =~ "reserved '_provider_' prefix"))
      assert Enum.any?(violations, &(&1 =~ "read-write path is overly broad: /"))
    end
  end

  defp put_model(policy, fun), do: put_endpoint(policy, "model", fun)
  defp put_report(policy, fun), do: put_endpoint(policy, "report", fun)

  defp put_endpoint(policy, name, fun) do
    update_in(policy.network_policies[name], fn rule ->
      %{rule | endpoints: Enum.map(rule.endpoints, fun)}
    end)
  end
end
