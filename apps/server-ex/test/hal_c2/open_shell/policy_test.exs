defmodule HalC2.OpenShell.PolicyTest do
  use ExUnit.Case, async: true

  alias HalC2.OpenShell.Policy
  alias HalC2.OpenShell.Proto.Openshell.Sandbox.V1, as: Sb
  alias HalC2.Test.FakeOpenShell.Validator

  @review %{
    model: %{
      host: "api.anthropic.com",
      port: 443,
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

  test "the model's TLS is left to OpenShell to terminate, never skipped" do
    assert model(Policy.review(@review)).tls == :NETWORK_TLS_MODE_UNSPECIFIED
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
