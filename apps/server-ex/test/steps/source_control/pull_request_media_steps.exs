defmodule HalC2.Steps.SourceControl.PullRequestMedia do
  @moduledoc """
  Steps for the images of `features/source-control/pull-request-review.feature`. A
  pull request's description points at media on GitHub, which a private repository
  serves only to a signed-in request: the client asks the MC for a URL of its own
  (`assets.createUrl`, `github-media`) and reads the image there, so the credential
  stays on the MC (`HalC2.Attachments.GitHubMedia`). GitHub is a local server here.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.SourceControl.Shared
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @image "https://github.com/user-attachments/assets/0f3c1d2e-screenshot"

  # Serves `bytes` as a PNG to requests carrying `token`, 404 otherwise, as GitHub
  # answers for a private repository; tells the test what each request carried.
  defmodule PrivateGitHub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test, token: token, bytes: bytes}) do
      auth = get_req_header(conn, "authorization")
      send(test, {:github_request, conn.request_path, auth})

      if auth == ["Bearer " <> token],
        do: conn |> put_resp_content_type("image/png", nil) |> send_resp(200, bytes),
        else: send_resp(conn, 404, "Not Found")
    end
  end

  step "the description of pull request {int} holds an image uploaded to GitHub",
       %{args: [number]} = context do
    assert number == context.pr_number
    token = "gho_private#{System.unique_integer([:positive])}"
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(1_016)

    {:ok, pid} =
      Bandit.start_link(
        plug: {PrivateGitHub, %{test: self(), token: token, bytes: bytes}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    World.put_app_env(:github_media_origin, "http://127.0.0.1:#{port}")
    :persistent_term.erase({HalC2.Attachments.GitHubMedia, :token})

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({HalC2.Attachments.GitHubMedia, :token})
    end)

    context
    |> Shared.reshape_pr(%{"body" => "Adds the tax table.\n\n![The table](#{@image})"})
    |> World.cli_rules([%{"args" => ["auth token"], "stdout" => token <> "\n"}])
    |> Map.put(:github, %{token: token, bytes: bytes})
  end

  # Reading it is the description, then each image through a URL the MC signs.
  step "the user reads the description", context do
    detail = Shared.pr_detail!(context)
    assert [_, image] = Regex.run(~r/!\[[^\]]*\]\(([^)]+)\)/, detail["body"])

    {asset, context} =
      World.call(context, "assets.createUrl", %{
        "resource" => %{
          "_tag" => "github-media",
          "cwd" => World.project(context, context.pr_repository).root,
          "url" => image
        }
      })

    assert {:ok, %{"relativeUrl" => url}} = asset

    Map.merge(context, %{
      detail: detail,
      asset: asset,
      response: Mc.request(context.mc, :get, url)
    })
  end

  step "the MC fetches the image with its GitHub credentials", context do
    %{token: token, bytes: bytes} = context.github
    assert_received {:github_request, "/user-attachments/assets/0f3c1d2e-screenshot", auth}
    assert auth == ["Bearer " <> token]
    assert [_ | _] = World.cli_calls(context, "auth token")
    assert {200, headers, ^bytes} = context.response
    assert {"content-type", "image/png"} in headers
    context
  end

  step "the client never receives the GitHub token", context do
    %{token: token} = context.github
    {_status, headers, body} = context.response

    for sent <- [context.detail, context.asset, headers, body],
        do: refute(inspect(sent, limit: :infinity, printable_limit: :infinity) =~ token)

    context
  end
end
