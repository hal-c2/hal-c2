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
      service_user_home: Path.join(dir, "user"),
      service_platform: {:unix, :linux},
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

    FakeOpenShell.install!(gateway)

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

  @tag gateway: [widen: &__MODULE__.writable_usr/1]
  test "a gateway that lets the review write its programs gets no review", %{
    gateway: g,
    repo: repo
  } do
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "wider than asked: the gateway changes the paths it may read or write"
    assert_gone(g)
  end

  @tag gateway: [widen: &__MODULE__.as_root/1]
  test "a gateway that runs the review as another user gets no review", %{gateway: g, repo: repo} do
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "wider than asked: the gateway changes the user it runs as"
    assert_gone(g)
  end

  test "a review's disk is a tmpfs of its size on each path it writes", %{repo: repo} do
    assert {:ok, _} = Review.open(spec(repo))
    assert_received {:openshell_request, "CreateSandbox", %{spec: spec}}

    assert %{"podman" => %{"mounts" => mounts}} =
             Google.Protobuf.to_map(spec.template.driver_config)

    assert Enum.map(mounts, &{&1["type"], &1["target"], &1["size_bytes"]}) ==
             for({path, bytes} <- HalC2.OpenShell.Policy.writable(), do: {"tmpfs", path, bytes})

    assert spec.policy.filesystem.read_write ==
             Enum.map(HalC2.OpenShell.Policy.writable(), &elem(&1, 0))
  end

  @tag sandbox: [disk: :unbounded]
  test "a sandbox whose driver left its disk unbounded gets no review", %{gateway: g, repo: repo} do
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "disk is not bounded"
    assert_gone(g)
  end

  test "a gateway on a driver that cannot bound a review's disk opens no sandbox", %{
    gateway: g,
    repo: repo
  } do
    for state <- [%{"endpoint" => g.endpoint}, %{"endpoint" => g.endpoint, "driver" => "vm"}] do
      File.write!(OpenShell.state_path(), JSON.encode!(state))
      assert {:error, message} = Review.open(spec(repo))
      assert message =~ "Podman or Docker driver"
    end

    refute_received {:openshell_request, "CreateSandbox", _}
    assert_gone(g)
  end

  test "a home without its reaper opens no review sandbox", %{gateway: g, repo: repo} do
    for path <- OpenShell.Service.reaper_paths(:systemd), do: File.rm!(path)

    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "need this HAL-C2 home's reaper"
    refute_received {:openshell_request, "CreateSandbox", _}
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

  test "a stop before the sandbox is made leaves none made", %{gateway: g, repo: repo} do
    :ok = Review.close(@thread, "stopped")

    assert {:error, "The review was stopped before its sandbox was made."} =
             Review.open(spec(repo))

    refute_received {:openshell_request, "CreateProvider", _}
    assert_gone(g)
  end

  test "a gateway holding another environment's sandboxes gets no review", %{
    gateway: g,
    repo: repo
  } do
    FakeOpenShell.put_sandbox(g, "theirs", %{OpenShell.owner_label() => "env-b"})

    assert {:error, "This MC's OpenShell gateway holds another HAL-C2 environment's" <> _} =
             Review.open(spec(repo))

    assert Map.keys(FakeOpenShell.sandboxes(g)) == ["theirs"]
    assert FakeOpenShell.providers(g) == %{}
    assert Review.binding(@thread) == nil
  end

  @tag sandbox: [hold: "tar"]
  test "a checkout that does not reach its sandbox within the review's time leaves nothing",
       %{gateway: g, repo: repo} do
    assert {:error, "The review's checkout did not reach its sandbox in time."} =
             Review.open(%{spec(repo) | minutes: 1 / 60})

    assert_gone(g)
  end

  test "an agent whose sandbox is no longer this MC's does not start", %{gateway: g, repo: repo} do
    {:ok, %{sandbox: name}} = Review.open(spec(repo))
    FakeOpenShell.put_sandbox(g, name, %{})
    sandbox = Review.binding(@thread) |> Review.subprocess()

    assert {:error, "The review's sandbox is not one this MC made, so nothing was run in it."} =
             HalC2.Subprocess.start(["true"], sandbox: sandbox)
  end

  # An agent's connection traps exits and stops on any it hears: the gateway calls
  # that start a sandboxed program must leave it nothing linked to end.
  test "a program started by a process that traps exits hears no exit but its own",
       %{repo: repo} do
    {:ok, _} = Review.open(spec(repo))
    Process.flag(:trap_exit, true)
    sandbox = Review.binding(@thread) |> Review.subprocess()

    {:ok, sub} = HalC2.Subprocess.start(["codex", "app-server"], sandbox: sandbox)
    :ok = HalC2.Subprocess.write_line(sub, ~s({"id":1,"method":"initialize"}))
    assert_receive {:subprocess_lines, _, [line]}, 5_000
    assert %{"id" => 1, "result" => _} = JSON.decode!(line)
    refute_received {:EXIT, _, _}
  end

  @tag gateway: [delete: {:accepted, :never}]
  test "a deletion the gateway only accepts holds up no other review", %{repo: repo} do
    {:ok, %{sandbox: name}} = Review.open(spec(repo))
    :ok = Review.close(@thread, "stopped")
    assert_receive {:openshell_request, "DeleteSandbox", %{name: ^name}}, 5_000

    # The deletion still waits on the gateway; the review process answers meanwhile.
    assert Review.binding(@thread) == nil
    assert Review.ended(@thread) == "stopped"
    assert :ok = Review.close("Another-Thread", "stopped")
  end

  test "a lease is reaped once it has ended, with or without the MC", %{gateway: g} do
    now = System.os_time(:second)
    FakeOpenShell.put_sandbox(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_sandbox(g, "review-new", owned(Review.labels("new", now + 600)))
    FakeOpenShell.put_sandbox(g, "other", owned(%{"halc2.github.io/role" => "workspace"}))
    # Another home's, past its time, with this MC's environment id (a copied home).
    FakeOpenShell.put_sandbox(g, "review-home", owned(other_home(Review.labels("h", now - 1))))
    FakeOpenShell.put_provider(g, "review-home", owned(other_home(Review.labels("h", now - 1))))
    # A provider whose sandbox never came, the MC gone between the two.
    FakeOpenShell.put_provider(g, "review-orphan", owned(Review.labels("orphan", now - 1)))
    FakeOpenShell.put_provider(g, "review-new", owned(Review.labels("new", now + 600)))

    # A reaper written for another home's directory reaps nothing here.
    assert {:error, "[reaper-wrong-home] " <> _} =
             OpenShell.Command.command(["reap", "--root", Path.join(OpenShell.root(), "other")])

    assert Map.has_key?(FakeOpenShell.sandboxes(g), "review-old")

    # What the reaper's timer runs, the MC up or not.
    assert {:ok, "Deleted review sandboxes past their time: review-old"} =
             OpenShell.Command.command(["reap", "--root", OpenShell.root()])

    assert {:ok, "No review sandbox is past its time."} = OpenShell.Command.command(["reap"])

    assert Map.keys(FakeOpenShell.sandboxes(g)) |> Enum.sort() == [
             "other",
             "review-home",
             "review-new"
           ]

    assert Map.keys(FakeOpenShell.providers(g)) |> Enum.sort() == ["review-home", "review-new"]
  end

  # The reaper's timer tries again a minute later; until then it says what is left.
  @tag gateway: [delete_provider: :accepted]
  test "a reaper that cannot confirm a lease's deletion says what is left and fails", %{
    gateway: g
  } do
    now = System.os_time(:second)
    FakeOpenShell.put_sandbox(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_provider(g, "review-old", owned(Review.labels("old", now - 1)))

    assert {:error, "Reaping review sandboxes left some behind: review-old: " <> why} =
             OpenShell.Command.command(["reap"])

    assert why =~ "delete_pending"
    refute why =~ "Deleted:"
    assert Map.has_key?(FakeOpenShell.providers(g), "review-old")
  end

  # A gateway that lists one kind and not the other still has the other reaped.
  test "a reaper that cannot list sandboxes still deletes every provider past its lease",
       %{gateway: g} do
    now = System.os_time(:second)
    FakeOpenShell.put_sandbox(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_provider(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_provider(g, "review-orphan", owned(Review.labels("orphan", now - 1)))
    FakeOpenShell.put_provider(g, "review-new", owned(Review.labels("new", now + 600)))
    FakeOpenShell.failing(g, ["ListSandboxes"])

    assert {:error, "Reaping review sandboxes left some behind: sandboxes not listed: " <> _} =
             OpenShell.Command.command(["reap"])

    assert Map.keys(FakeOpenShell.providers(g)) == ["review-new"]
    assert Map.has_key?(FakeOpenShell.sandboxes(g), "review-old")

    FakeOpenShell.failing(g, [])
    assert {:ok, _} = OpenShell.Command.command(["reap"])
    refute Map.has_key?(FakeOpenShell.sandboxes(g), "review-old")
  end

  test "a reaper that cannot list providers still deletes every sandbox past its lease",
       %{gateway: g} do
    now = System.os_time(:second)
    FakeOpenShell.put_sandbox(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.put_provider(g, "review-old", owned(Review.labels("old", now - 1)))
    FakeOpenShell.failing(g, ["ListProviders"])

    assert {:error, message} = OpenShell.Command.command(["reap"])
    assert message =~ "providers not listed"
    assert message =~ "Deleted: review-old."
    assert FakeOpenShell.sandboxes(g) == %{}
    assert FakeOpenShell.providers(g) == %{}
  end

  test "a fresh gateway gets HAL-C2's key-only profile, and the review's provider is of it",
       %{gateway: g, repo: repo} do
    assert {:ok, %{sandbox: name}} = Review.open(spec(repo))

    assert %{"hal-c2-codex" => profile} = FakeOpenShell.profiles(g)
    assert profile.endpoints == [] and profile.binaries == [] and profile.files == []

    assert [%{env_vars: ["OPENAI_API_KEY"], auth_style: "bearer", header_name: "authorization"}] =
             profile.credentials

    assert FakeOpenShell.providers(g)[name].type == "hal-c2-codex"
  end

  @tag gateway: [
         profiles: [
           %HalC2.OpenShell.Proto.Openshell.V1.ProviderProfile{
             id: "hal-c2-codex",
             credentials: [
               %HalC2.OpenShell.Proto.Openshell.V1.ProviderProfileCredential{
                 name: "api_key",
                 env_vars: ["OPENAI_API_KEY"],
                 required: true
               }
             ],
             endpoints: [
               %HalC2.OpenShell.Proto.Openshell.Sandbox.V1.NetworkEndpoint{
                 host: "elsewhere.example",
                 port: 443
               }
             ]
           }
         ]
       ]
  test "a review is not given a profile by its id that sends its key elsewhere", %{
    gateway: g,
    repo: repo
  } do
    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "hal-c2-codex is not the one HAL-C2 makes"
    refute_received {:openshell_request, "CreateProvider", _}
    refute_received {:openshell_request, "CreateSandbox", _}
    assert FakeOpenShell.providers(g) == %{}
    assert Review.binding(@thread) == nil
  end

  test "a review whose provider name is taken deletes nothing it did not make", %{
    gateway: g,
    repo: repo
  } do
    name = Review.name(@thread)
    theirs = %{OpenShell.owner_label() => "another-mc"}
    FakeOpenShell.put_provider(g, name, theirs)

    assert {:error, message} = Review.open(spec(repo))
    assert message =~ "already exists"
    refute_received {:openshell_request, "DeleteProvider", _}
    refute_received {:openshell_request, "DeleteSandbox", _}
    assert FakeOpenShell.providers(g)[name].labels == theirs
    assert Review.binding(@thread) == nil
  end

  @tag before: [&__MODULE__.left_behind/1]
  test "an MC starting deletes the review sandboxes it holds no binding for", %{gateway: g} do
    assert_receive {:openshell_request, "DeleteSandbox", %{name: "review-left"}}, 5_000
    assert_receive {:openshell_request, "DeleteProvider", %{name: "review-left"}}, 5_000
    refute Map.has_key?(FakeOpenShell.sandboxes(g), "review-left")
    refute Map.has_key?(FakeOpenShell.providers(g), "review-left")
    assert Map.has_key?(FakeOpenShell.sandboxes(g), "review-home")
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

  def writable_usr(policy),
    do: %{
      policy
      | filesystem: %{policy.filesystem | read_write: ["/usr" | policy.filesystem.read_write]}
    }

  def as_root(policy),
    do: %{policy | process: %{policy.process | run_as_user: "root"}}

  def widen(policy) do
    rule = %OpenShell.Proto.Openshell.Sandbox.V1.NetworkPolicyRule{name: "everywhere"}
    %{policy | network_policies: Map.put(policy.network_policies, "everywhere", rule)}
  end

  def left_behind(gateway) do
    labels = Review.labels("left", System.os_time(:second) + 600)
    FakeOpenShell.put_sandbox(gateway, "review-left", owned(labels))
    FakeOpenShell.put_provider(gateway, "review-left", owned(labels))
    # Another home's, on a gateway the two share: not this MC's to reconcile.
    FakeOpenShell.put_sandbox(gateway, "review-home", owned(other_home(labels)))
  end

  defp assert_gone(g) do
    assert FakeOpenShell.sandboxes(g) == %{}
    assert FakeOpenShell.providers(g) == %{}
    assert Review.binding(@thread) == nil
    assert :ets.lookup(Broker, {:thread, @thread}) == []
  end

  defp owned(labels), do: Map.put(labels, OpenShell.owner_label(), OpenShell.owner())
  defp other_home(labels), do: Map.put(labels, Review.home_label(), "0123456789ab")

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
