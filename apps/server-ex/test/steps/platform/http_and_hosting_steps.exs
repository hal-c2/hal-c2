defmodule HalC2.Steps.Platform.HttpAndHosting do
  @moduledoc "Steps for features/node/platform/http-and-hosting.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)
  @patch "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"

  # A project whose origin is on `remote`, with `gh` answered by `rules` (fake_gh.py).
  defp pull_request_project(context, remote, rules) do
    home = context.node.home
    World.put_app_env(:gh_command, @fake_gh)
    System.put_env("FAKE_GH_RULES", Path.join(home, "gh-rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(home, "gh.log"))

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_GH_RULES")
      System.delete_env("FAKE_GH_LOG")
    end)

    File.write!(Path.join(home, "gh-rules.json"), JSON.encode!(rules))
    context = World.create_project(context, "widgets")
    root = World.project(context, "widgets").root
    {_, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: root)
    context
  end

  defp ask_diff(context) do
    ref = %{
      "projectId" => World.project(context, "widgets").id,
      "repository" => "acme/widgets",
      "number" => 5
    }

    response =
      Node.request(context.node, :post, "/api/pull-requests/diff",
        bearer: context.access,
        json: ref
      )

    Map.put(context, :response, response)
  end

  step "a browser on another origin sends a preflight request", context do
    response =
      Node.request(context.node, :options, "/api/auth/websocket-ticket",
        headers: [
          {"origin", "https://elsewhere.example"},
          {"access-control-request-method", "POST"},
          {"access-control-request-headers", "authorization"}
        ]
      )

    Map.put(context, :response, response)
  end

  step "the node answers it with no content and allows the request", context do
    assert {204, headers, body} = context.response
    assert body in ["", nil]
    headers = Map.new(headers)
    assert headers["access-control-allow-origin"] == "*"
    assert headers["access-control-allow-methods"] =~ "POST"
    assert headers["access-control-allow-headers"] =~ "authorization"
    context
  end

  step "anyone asks the node's well-known environment route", context do
    Map.put(
      context,
      :response,
      Node.request(context.node, :get, "/.well-known/hal-c2/environment")
    )
  end

  step "it answers with the environment descriptor and node name", context do
    assert {200, _, descriptor} = context.response
    assert descriptor["environmentId"] == context.node.environment
    assert is_binary(descriptor["label"])
    assert descriptor["node"] == Atom.to_string(node())
    context
  end

  step "the list of cluster members", context do
    assert {200, _, %{"cluster" => cluster}} = context.response
    assert [%{"environmentId" => id, "label" => _}] = cluster
    assert id == context.node.environment
    context
  end

  step "a browser opens the node's root address", context do
    Map.put(context, :response, Node.request(context.node, :get, "/"))
  end

  step "it shows how to paste a pairing link into Add environment", context do
    assert {200, headers, html} = context.response
    assert Map.new(headers)["content-type"] =~ "text/html"
    assert html =~ "pairing link"
    assert html =~ "Add environment"
    context
  end

  step "says links work once and expire after five minutes", context do
    {200, _, html} = context.response
    assert html =~ "Pairing links work once and expire after 5 minutes."
    context
  end

  step "a client requests a route the node does not have", context do
    Map.put(context, :response, Node.request(context.node, :get, "/api/no-such-route"))
  end

  step "a thread's agent with its MCP bearer", context do
    Node.ensure(HalC2.Mcp)
    context = context |> World.create_project("Work") |> World.create_thread("Agent work")

    %{authorization: authorization} =
      HalC2.Mcp.server(World.thread_id(context, "Agent work"), "codex")

    Map.put(context, :mcp, authorization)
  end

  step "the agent posts an MCP request", context do
    request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"}

    response =
      Node.request(context.node, :post, "/mcp",
        headers: [{"authorization", context.mcp}],
        json: request
      )

    Map.put(context, :response, response)
  end

  step "the node answers it on the same request", context do
    assert {200, _, %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"tools" => tools}}} =
             context.response

    assert tools != []
    # Another bearer is not an agent's.
    assert {401, _, _} =
             Node.request(context.node, :post, "/mcp",
               bearer: "not-an-agent",
               json: %{"jsonrpc" => "2.0", "id" => 8, "method" => "tools/list"}
             )

    context
  end

  step "an agent opens the MCP route for streaming", context do
    Map.put(context, :response, Node.request(context.node, :get, "/mcp"))
  end

  step "the node answers that the method is not allowed", context do
    assert {405, _, _} = context.response
    context
  end

  step "ending an MCP session always succeeds", context do
    assert {200, _, _} = Node.request(context.node, :delete, "/mcp")
    context
  end

  step "a client with orchestration:read", context do
    assert {200, %{"access_token" => access, "scope" => scope}} =
             Node.exchange(context.node, HalC2.Auth.create_pairing_token(context.node.store))

    assert "orchestration:read" in String.split(scope)
    Map.put(context, :access, access)
  end

  step "it asks for a pull request's diff over HTTP", context do
    context
    |> pull_request_project("https://github.com/acme/widgets.git", [
      %{"args" => ["pr diff 5", "--repo github.com/acme/widgets"], "stdout" => @patch}
    ])
    |> ask_diff()
  end

  step "the project's node answers with the diff", context do
    assert {200, _, %{"patch" => @patch, "truncated" => false}} = context.response
    context
  end

  step ~r/^it asks for a pull request diff and (?<problem>the pull request provider is unavailable|fetching the diff fails)$/,
       %{args: [problem]} = context do
    case problem do
      "the pull request provider is unavailable" ->
        pull_request_project(context, "https://gitlab.com/acme/widgets.git", [])

      "fetching the diff fails" ->
        pull_request_project(context, "https://github.com/acme/widgets.git", [
          %{"args" => ["pr diff 5"], "exit" => 1, "stderr" => "HTTP 500: server error"}
        ])
    end
    |> ask_diff()
  end
end
