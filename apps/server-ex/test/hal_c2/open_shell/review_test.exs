defmodule HalC2.OpenShell.ReviewTest do
  # Review sandboxes (#1412) against the fake gateway, whose sandbox is a directory
  # here (`HalC2.Test.FakeSandbox`). The app env's `:home` names the MC.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.{Broker, Review}
  alias HalC2.Test.{FakeOpenShell, FakeSandbox}

  @moduletag :tmp_dir
  @thread "Review-Thread-1"

  setup %{tmp_dir: dir} = context do
    FakeOpenShell.put_env(
      home: Path.join(dir, "mc"),
      openshell_broker: [host: "127.0.0.1", bind: "127.0.0.1", ips: ["127.0.0.1"]]
    )

    key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "sk-test-key")

    on_exit(fn ->
      if key, do: System.put_env("OPENAI_API_KEY", key), else: System.delete_env("OPENAI_API_KEY")
    end)

    root = FakeSandbox.root()

    gateway =
      FakeOpenShell.start(
        OpenShell.pki_dir(),
        [notify: self(), exec: FakeSandbox.exec(root, self(), Map.get(context, :sandbox, []))] ++
          Map.get(context, :gateway, [])
      )

    File.write!(
      OpenShell.state_path(),
      JSON.encode!(%{"endpoint" => gateway.endpoint, "driver" => "podman"})
    )

    for child <- Map.get(context, :before, []), do: child.(gateway)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Settings)
    start_supervised!(Review)
    # Its first reconcile is done before the test puts sandboxes of its own.
    :sys.get_state(Review)

    %{gateway: gateway, root: root, repo: repo!(dir)}
  end

  test "a review's sandbox holds a checkout at its head made from a bundle, and its key only in a provider",
       %{gateway: g, root: root, repo: repo} do
    assert {:ok, %{sandbox: name}} = Review.open(spec(repo))
    assert name == "review-review-thread-1"

    checkout = Path.join(root, "review")
    assert git!(checkout, ["rev-parse", "HEAD"]) == repo.head
    assert File.read!(Path.join(checkout, "change.txt")) == "change\n"
    # A repository of its own: no remote, no hooks, and the bundle gone.
    assert git!(checkout, ["remote"]) == ""
    assert git!(checkout, ["config", "core.hooksPath"]) == "/dev/null"
    refute File.exists?(Path.join(root, "review.bundle"))

    # The key is the provider's; the sandbox's own environment has no credential.
    assert %{^name => %{credentials: %{"OPENAI_API_KEY" => "sk-test-key"}}} =
             FakeOpenShell.providers(g)

    assert_received {:openshell_request, "CreateSandbox", %{spec: spec}}
    assert spec.providers == [name]
    refute Enum.any?(Map.values(spec.environment), &(&1 =~ "sk-test"))

    assert %{workdir: "/sandbox/review", commit: commit, mcp: %{url: url, report: true}} =
             Review.binding(@thread)

    assert commit == repo.head
    assert url =~ ~r"^http://127.0.0.1:\d+/report$"
    assert Review.refusal(@thread, "codex") == nil
  end

  test "a checkout not at the head asked for leaves no sandbox, provider or binding", %{
    gateway: g,
    repo: repo
  } do
    assert {:error, message} = Review.open(%{spec(repo) | head: repo.base})
    assert message =~ "is not at #{repo.base}"
    assert_gone(g)
  end

  @tag gateway: [widen: &__MODULE__.widen/1]
  test "a gateway that widens the review's policy gets no review", %{gateway: g, repo: repo} do
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "wider than asked: the gateway adds network rules"
    assert_gone(g)
  end

  test "a review without the model's API key opens no sandbox", %{gateway: g, repo: repo} do
    System.delete_env("OPENAI_API_KEY")
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "needs OPENAI_API_KEY"
    refute_received {:openshell_request, "CreateSandbox", _}
    assert_gone(g)
  end

  test "an agent that cannot run in a sandbox is refused, never run here" do
    assert Review.refusal(@thread, "cursor") =~ "cursor cannot run in yet"
    assert Review.refusal(@thread, "codex") =~ "Run the review again."
  end

  test "the broker takes only its token, a bounded body and its one tool", %{repo: repo} do
    {:ok, _} = Review.open(spec(repo))
    %{mcp: mcp} = Review.binding(@thread)

    list = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "gh_pr_merge"}
    }

    assert {401, _} = FakeSandbox.post(%{mcp | authorization: "Bearer nope"}, list)
    assert {401, _} = FakeSandbox.post(%{mcp | authorization: nil}, list)

    assert {413, _} =
             FakeSandbox.post(mcp, String.duplicate("x", OpenShell.Policy.broker_body() + 1))

    assert {200, body} = FakeSandbox.post(mcp, list)
    assert %{"error" => %{"code" => -32602}} = JSON.decode!(body)

    # Once the sandbox is closed, its token is too.
    :ok = Review.close(@thread, "stopped")
    assert {401, _} = FakeSandbox.post(mcp, list)
  end

  test "a review past its time loses its sandbox", %{repo: repo} do
    # A second, the shortest lease there is.
    {:ok, %{sandbox: name}} = Review.open(%{spec(repo) | minutes: 1 / 60})
    assert_receive {:openshell_request, "DeleteSandbox", %{name: ^name}}, 5_000
    assert Review.ended(@thread) == "time"
    assert Review.binding(@thread) == nil
    assert Review.refusal(@thread, "codex") =~ "past its time limit"
  end

  test "a review past its token budget loses its sandbox, and a count reported again is not added twice",
       %{repo: repo} do
    {:ok, %{sandbox: name}} = Review.open(%{spec(repo) | tokens: 100})
    Review.spent(@thread, "m1", 60)
    Review.spent(@thread, "m1", 70)
    :sys.get_state(Review)
    assert Review.binding(@thread)

    Review.spent(@thread, "m2", 31)
    assert_receive {:openshell_request, "DeleteSandbox", %{name: ^name}}, 5_000
    assert Review.ended(@thread) == "tokens"
  end

  @tag sandbox: [hold: "tar"]
  test "a stop while the sandbox is made leaves none behind", %{gateway: g, repo: repo} do
    task = Task.async(fn -> Review.open(spec(repo)) end)
    assert_receive {:sandbox_held, handler}, 5_000
    :ok = Review.close(@thread, "stopped")
    send(handler, :release)

    assert {:error, "The review was stopped while its sandbox was made."} =
             Task.await(task, 10_000)

    assert_gone(g)
  end

  test "a lease is reaped once it has ended, with or without the MC", %{gateway: g} do
    now = System.os_time(:second)
    FakeOpenShell.put_sandbox(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_sandbox(g, "review-new", owned(Review.labels("new", now + 600)))
    FakeOpenShell.put_sandbox(g, "other", owned(%{"halc2.github.io/role" => "workspace"}))

    # What the reaper's timer runs, the MC up or not.
    assert {:ok, "Deleted review sandboxes past their time: review-old"} =
             OpenShell.Command.command(["reap"])

    assert {:ok, "No review sandbox is past its time."} = OpenShell.Command.command(["reap"])
    assert Map.keys(FakeOpenShell.sandboxes(g)) |> Enum.sort() == ["other", "review-new"]
  end

  @tag before: [&__MODULE__.left_behind/1]
  test "an MC starting deletes the review sandboxes it holds no binding for", %{gateway: g} do
    assert_receive {:openshell_request, "DeleteSandbox", %{name: "review-left"}}, 5_000
    assert_receive {:openshell_request, "DeleteProvider", %{name: "review-left"}}, 5_000
    refute Map.has_key?(FakeOpenShell.sandboxes(g), "review-left")
  end

  test "a sandboxed program past its output limit is cancelled", %{repo: repo} do
    {:ok, _} = Review.open(spec(repo))
    test = self()

    sandbox =
      Review.binding(@thread)
      |> Review.subprocess()
      |> Map.merge(%{output_limit: 10, on_limit: fn -> send(test, :limited) end})

    {:ok, sub} =
      HalC2.Subprocess.start(["sh", "-c", "printf '%s\\n' 0123456789abcdef"], sandbox: sandbox)

    assert_receive :limited, 5_000
    assert HalC2.Subprocess.Sandboxed.exited(sub.proc, 5_000) == {:ok, 137}
  end

  # --- fixtures -------------------------------------------------------------------------

  def widen(policy) do
    rule = %OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule{name: "everywhere"}
    %{policy | network_policies: Map.put(policy.network_policies, "everywhere", rule)}
  end

  def left_behind(gateway) do
    FakeOpenShell.put_sandbox(
      gateway,
      "review-left",
      owned(Review.labels("left", System.os_time(:second) + 600))
    )
  end

  defp assert_gone(g) do
    assert FakeOpenShell.sandboxes(g) == %{}
    assert FakeOpenShell.providers(g) == %{}
    assert Review.binding(@thread) == nil
    assert :ets.lookup(Broker, {:thread, @thread}) == []
  end

  defp owned(labels), do: Map.put(labels, OpenShell.owner_label(), OpenShell.owner())

  defp spec(repo) do
    %{
      thread_id: @thread,
      driver: "codex",
      instance: "codex",
      clone: repo.dir,
      head_ref: "refs/hal-c2/code-review/1/head",
      base_ref: "refs/hal-c2/code-review/1/base",
      head: repo.head,
      merge_base: repo.base,
      review: "acme/api#1",
      tool: "code_review_report",
      minutes: 10,
      tokens: nil
    }
  end

  defp repo!(dir) do
    repo = Path.join(dir, "clone")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "# api\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "Start"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "change.txt"), "change\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "Change"])
    head = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["update-ref", "refs/hal-c2/code-review/1/head", head])
    git!(repo, ["update-ref", "refs/hal-c2/code-review/1/base", base])
    %{dir: repo, head: head, base: base}
  end

  defp git!(dir, args) do
    config = ~w(-c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false)
    {out, code} = System.cmd("git", config ++ args, cd: dir, stderr_to_stdout: true)
    assert code in [0, 1], out
    String.trim(out)
  end
end
