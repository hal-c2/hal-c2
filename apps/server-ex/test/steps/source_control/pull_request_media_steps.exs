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
      type = if conn.request_path =~ "video", do: "video/mp4", else: "image/png"

      if auth == ["Bearer " <> token],
        do: conn |> put_resp_content_type(type, nil) |> send_resp(200, bytes),
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

  @video "https://github.com/user-attachments/assets/9a8b7c6d-video"

  step ~r/^the description of pull request (?<number>\d+) (?<where>.+) holds an image and a video uploaded to GitHub$/,
       %{args: [number, where]} = context do
    assert String.to_integer(number) == context.pr_number
    token = "gho_media#{System.unique_integer([:positive])}"
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

    # The thread's own checkout is another repository; the media belong to
    # this pull request's, which is where the fetch must be made from.
    context =
      if where =~ "other than",
        do: World.github_project(context, "acme/threads"),
        else: context

    context
    |> Shared.reshape_pr(%{
      "body" => "Adds the tax table.\n\n![The table](#{@image})\n\n![The run](#{@video})"
    })
    |> World.cli_rules([%{"args" => ["auth token"], "stdout" => token <> "\n"}])
    |> Map.put(:github, %{token: token, bytes: bytes})
  end

  # Reading it is the description, then each image through a URL the MC signs.
  step "the user reads the description", context do
    detail = Shared.pr_detail!(context)
    cwd = World.project(context, context.pr_repository).root

    urls =
      ~r/!\[[^\]]*\]\(([^)]+)\)/
      |> Regex.scan(detail["body"])
      |> Enum.map(fn [_, url] -> url end)

    assert urls != []

    {responses, assets, context} =
      Enum.reduce(urls, {[], [], context}, fn url, {responses, assets, context} ->
        {asset, context} =
          World.call(context, "assets.createUrl", %{
            "resource" => %{"_tag" => "github-media", "cwd" => cwd, "url" => url}
          })

        assert {:ok, %{"relativeUrl" => relative}} = asset
        {[Mc.request(context.mc, :get, relative) | responses], [asset | assets], context}
      end)

    responses = Enum.reverse(responses)

    Map.merge(context, %{
      detail: detail,
      asset: List.first(Enum.reverse(assets)),
      response: List.first(responses),
      responses: responses
    })
  end

  step "the image and the video are shown, fetched in the pull request's own repository",
       context do
    %{token: token, bytes: bytes} = context.github
    assert [{200, image_headers, ^bytes}, {200, video_headers, ^bytes}] = context.responses
    assert {"content-type", "image/png"} in image_headers
    assert {"content-type", "video/mp4"} in video_headers
    assert_received {:github_request, "/user-attachments/assets/0f3c1d2e-screenshot", auth}
    assert auth == ["Bearer " <> token]
    assert_received {:github_request, "/user-attachments/assets/9a8b7c6d-video", video_auth}
    assert video_auth == ["Bearer " <> token]

    # The credential was read in the pull request's own checkout, not another's.
    asks = World.cli_calls(context, "auth token")
    assert asks != []

    assert Enum.all?(
             asks,
             &(&1["cwd"] == World.project(context, context.pr_repository).root)
           )

    context
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

    sent =
      [context.detail, context.asset, headers, body] ++
        Enum.flat_map(context[:responses] || [], fn {_s, h, b} -> [h, b] end)

    for sent <- sent,
        do: refute(inspect(sent, limit: :infinity, printable_limit: :infinity) =~ token)

    context
  end
end
