defmodule HalC2.OpenShellReviewPropTest do
  @moduledoc """
  `HalC2.OpenShell.Review` (#1412) against a model of a review sandbox's lease, over
  any sequence of reviews opened, stopped, past their budget or their time, sandboxes
  left on the gateway from before, reconciles and restarts of the review process,
  reaps, and a gateway that for a while only accepts provider deletions. The gateway
  is the TLS fake, each sandbox a directory of its own. The promises:

    * a review opens once: a thread stopped before its sandbox was made gets none;
    * a review has a binding and a broker token exactly while it is open, and its
      sandbox and provider are on the gateway meanwhile;
    * a review ends once, keeping the first reason it ended for, and its sandbox and
      provider are deleted;
    * spending is counted per key, its latest value, and only past the budget does
      the review end;
    * a reconcile deletes what was left from before and nothing that is open;
    * a restart keeps no binding, and deletes every review sandbox there was;
    * a provider whose deletion the gateway only accepted is not taken as gone: it is
      asked for again by the next reconcile, restart or reap, a reap reports it as
      left behind, and it goes once the gateway deletes again;
    * another HAL-C2 home's review sandboxes, with this MC's environment id on the
      same gateway (a copied home), are never deleted.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.OpenShell
  alias HalC2.OpenShell.{Broker, Client, Review}
  alias HalC2.Test.{FakeOpenShell, FakeSandbox}

  @moduletag timeout: :infinity

  # Long enough for anything here to arrive; reaching it fails the case.
  @wait 10_000
  @budget 100
  @threads ~w(T1 T2 T3)

  property "a review sandbox is open exactly while its review is, and ends once",
    numtests: HalC2.Prop.numtests(25),
    max_size: 15 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("openshell-review")
        level = Logger.level()
        Logger.configure(level: :none)
        key = System.get_env("OPENAI_API_KEY")
        System.put_env("OPENAI_API_KEY", "sk-prop-key")

        Application.put_env(:hal_c2, :openshell_broker,
          host: "127.0.0.1",
          bind: "127.0.0.1",
          ips: ["127.0.0.1"]
        )

        Application.put_env(:hal_c2, :service_user_home, Path.join(home, "user"))
        Application.put_env(:hal_c2, :service_platform, {:unix, :linux})

        roots = Path.join(home, "sandboxes")
        sink = spawn(fn -> discard() end)

        gateway =
          FakeOpenShell.start(OpenShell.pki_dir(),
            notify: self(),
            exec: fn command, io, start ->
              root = Path.join(roots, start.sandbox)
              File.mkdir_p!(root)
              FakeSandbox.exec(root, sink).(command, io, start)
            end
          )

        FakeOpenShell.install!(gateway)

        Process.put(:review_prop, %{
          gateway: gateway,
          repo: repo!(home),
          roots: roots,
          left: [],
          others: [],
          deleted: []
        })

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Settings,
          Review
        ])

        settle()

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            HalC2.Prop.stop_services()
            Supervisor.stop(gateway.server)
            Process.exit(sink, :kill)
            Application.delete_env(:hal_c2, :openshell_broker)
            Application.delete_env(:hal_c2, :service_user_home)
            Application.delete_env(:hal_c2, :service_platform)

            if key,
              do: System.put_env("OPENAI_API_KEY", key),
              else: System.delete_env("OPENAI_API_KEY")

            Logger.configure(level: level)
            File.rm_rf!(home)
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # threads: by id, `:open` with its `spent` counts, or `{:ended, reason}`; one not
  # there is fresh. left: sandboxes put on the gateway since the last reconcile, each
  # with its provider. others: another home's sandboxes put there, which stay.
  # stalled: the gateway only accepts provider deletions; pending: the providers it
  # accepted deleting and kept.
  def initial_state, do: %{threads: %{}, left: 0, others: 0, stalled: false, pending: []}

  def command(state) do
    open = for {t, %{spent: _}} <- state.threads, do: t

    frequency(
      [
        {4, {:call, __MODULE__, :open, [oneof(@threads)]}},
        {3, {:call, __MODULE__, :close, [oneof(@threads), oneof(["stopped", "discarded"])]}},
        {1, {:call, __MODULE__, :left_behind, []}},
        {1, {:call, __MODULE__, :other_home_left, []}},
        {1, {:call, __MODULE__, :reconcile, []}},
        {1, {:call, __MODULE__, :restart, []}},
        {2, {:call, __MODULE__, :stall, [boolean()]}}
      ] ++
        if(open == [], do: [{2, {:call, __MODULE__, :reap, []}}], else: []) ++
        if(open == [],
          do: [],
          else: [
            {4, {:call, __MODULE__, :spent, [oneof(open), oneof(["m1", "m2"]), range(0, 70)]}},
            {1, {:call, __MODULE__, :deadline, [oneof(open)]}}
          ]
        )
    )
  end

  # A provider the gateway kept takes its name: a review of that thread cannot open
  # until it goes (`CreateProvider` refuses it).
  def precondition(state, {:call, _, :open, [t]}),
    do: not open?(state, t) and Review.name(t) not in state.pending

  # A reap here deletes everything past a far deadline, open reviews' sandboxes too.
  def precondition(state, {:call, _, :reap, []}),
    do: not Enum.any?(Map.keys(state.threads), &open?(state, &1))

  def precondition(state, {:call, _, op, [t | _]}) when op in [:spent, :deadline],
    do: open?(state, t)

  def precondition(state, {:call, _, :left_behind, []}), do: state.left < 2
  def precondition(state, {:call, _, :other_home_left, []}), do: state.others < 2
  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: model(state, call)

  defp model(state, {:call, _, :open, [t]}) do
    if Map.has_key?(state.threads, t),
      do: state,
      else: put_in(state.threads[t], %{spent: %{}})
  end

  defp model(state, {:call, _, :close, [t, reason]}), do: ended(state, t, reason)
  defp model(state, {:call, _, :deadline, [t]}), do: ended(state, t, "time")

  defp model(state, {:call, _, :spent, [t, key, n]}) do
    counts = Map.put(state.threads[t].spent, key, n)

    if Enum.sum(Map.values(counts)) > @budget,
      do: ended(state, t, "tokens"),
      else: put_in(state.threads[t].spent, counts)
  end

  defp model(state, {:call, _, :left_behind, []}), do: %{state | left: state.left + 1}
  defp model(state, {:call, _, :other_home_left, []}), do: %{state | others: state.others + 1}
  defp model(state, {:call, _, :stall, [on]}), do: %{state | stalled: on}

  # Both ask for every provider no open review holds to go, the pending ones too.
  defp model(state, {:call, _, op, []}) when op in [:reconcile, :reap],
    do: kept(%{state | left: 0}, left_names(state) ++ state.pending)

  # The review process's tables go with it: no binding, and no ending, is kept.
  defp model(state, {:call, _, :restart, []}) do
    open = for {t, %{spent: _}} <- state.threads, do: Review.name(t)

    kept(
      %{initial_state() | others: state.others, stalled: state.stalled, pending: state.pending},
      open ++ left_names(state) ++ state.pending
    )
  end

  # The first reason a thread ends for is the one kept; one that was open had its
  # provider deleted.
  defp ended(state, t, reason) do
    case state.threads[t] do
      {:ended, _} -> state
      nil -> put_in(state.threads[t], {:ended, reason})
      %{spent: _} -> kept(put_in(state.threads[t], {:ended, reason}), [Review.name(t)])
    end
  end

  # Providers `names` are asked to go: a stalled gateway keeps them, one that deletes
  # again does not.
  defp kept(%{stalled: true} = state, names),
    do: %{state | pending: Enum.sort(Enum.uniq(state.pending ++ names))}

  defp kept(state, names), do: %{state | pending: state.pending -- names}

  defp left_names(state), do: for(n <- 0..(state.left - 1)//1, do: "review-left-#{n}")

  defp open?(state, t), do: match?(%{spent: _}, state.threads[t])

  def postcondition(state, call, observed) do
    after_ = model(state, call)
    open = for {t, %{spent: _}} <- after_.threads, do: t
    names = Enum.sort(for t <- open, do: Review.name(t))
    ends = for {t, {:ended, reason}} <- after_.threads, into: %{}, do: {t, reason}

    result_ok(state, call, observed.result) and observed.missing == [] and
      observed.bound == Enum.sort(open) and observed.tokens == Enum.sort(open) and
      observed.ended == ends and
      observed.sandboxes == Enum.sort(names ++ observed.left ++ observed.others) and
      observed.providers == Enum.sort(Enum.uniq(names ++ observed.left ++ after_.pending))
  end

  defp result_ok(state, {:call, _, :open, [t]}, result) do
    case state.threads[t] do
      nil -> match?({:ok, %{sandbox: _}}, result)
      {:ended, _} -> result == {:error, "The review was stopped before its sandbox was made."}
    end
  end

  # A reap deletes what was left and every provider kept; one the gateway only
  # accepted deleting is reported as left behind, never as gone.
  defp result_ok(state, {:call, _, :reap, []}, result) do
    left = left_names(state)

    case {state.stalled, Enum.sort(Enum.uniq(state.pending ++ left)), result} do
      {true, [_ | _] = kept, {:error, {:not_deleted, [], failed}}} ->
        Enum.sort(failed) == for(name <- kept, do: {name, {:delete_pending, name}})

      {true, [_ | _], _} ->
        false

      {_, _, {:ok, deleted}} ->
        Enum.sort(deleted) == left

      _ ->
        false
    end
  end

  defp result_ok(_state, _call, result), do: result == :ok

  # --- commands -------------------------------------------------------------------

  def open(t), do: observe(fn -> Review.open(spec(t)) end, [])

  def close(t, reason), do: ending(t, fn -> Review.close(t, reason) end)

  def spent(t, key, n) do
    ending(t, fn ->
      :ok = Review.spent(t, key, n)
      settle()
    end)
  end

  # What the review's timer sends once its lease is up.
  def deadline(t) do
    ending(t, fn ->
      send(Review, {:deadline, t})
      settle()
    end)
  end

  def left_behind do
    %{gateway: g, left: left} = ctx = Process.get(:review_prop)
    name = "review-left-#{length(left)}"

    labels =
      Review.labels("left", System.os_time(:second) + 600)
      |> Map.put(OpenShell.owner_label(), OpenShell.owner())

    FakeOpenShell.put_sandbox(g, name, labels)
    FakeOpenShell.put_provider(g, name, labels)

    Process.put(:review_prop, %{ctx | left: [name | left]})
    observe(fn -> :ok end, [])
  end

  # Another home's review sandbox, past its time, under this MC's environment id.
  def other_home_left do
    %{gateway: g, others: others} = ctx = Process.get(:review_prop)
    name = "review-home-#{length(others)}"

    labels =
      Review.labels("home", System.os_time(:second) - 1)
      |> Map.put(Review.home_label(), "0123456789ab")
      |> Map.put(OpenShell.owner_label(), OpenShell.owner())

    FakeOpenShell.put_sandbox(g, name, labels)
    Process.put(:review_prop, %{ctx | others: [name | others]})
    observe(fn -> :ok end, [])
  end

  def stall(on) do
    FakeOpenShell.provider_deletions(
      Process.get(:review_prop).gateway,
      if(on, do: :accepted, else: :completed)
    )

    observe(fn -> :ok end, [])
  end

  # A reconcile asks for every provider no open review holds to go.
  def reconcile do
    bound = for t <- @threads, b = Review.binding(t), do: b.sandbox
    forget_left()

    observe(
      fn ->
        Review.reconcile()
        settle()
      end,
      providers() -- bound
    )
  end

  def restart do
    forget_left()

    observe(
      fn ->
        HalC2.Prop.restart_service(Review)
        settle()
      end,
      providers()
    )
  end

  # What `hal-c2-service openshell reap` runs, a day on, with every review closed.
  def reap do
    forget_left()
    deleting = providers()

    observe(
      fn ->
        {:ok, conn} = Client.connect()

        try do
          Review.reap(conn, System.os_time(:second) + 86_400)
        after
          Client.disconnect(conn)
        end
      end,
      deleting
    )
  end

  # Every provider on the gateway is this home's: other homes leave only sandboxes.
  defp providers, do: Map.keys(FakeOpenShell.providers(Process.get(:review_prop).gateway))

  # A thread open before `fun` and not after has its sandbox deleted.
  defp ending(t, fun) do
    before = Review.binding(t)

    observe(fn ->
      result = fun.()
      {result, if(before && !Review.binding(t), do: [before.sandbox], else: [])}
    end)
  end

  defp observe(fun, deleting), do: observe(fn -> {fun.(), deleting} end)

  # What `fun` returned, the deletions it started (awaited), and what the review
  # process and the gateway hold after.
  defp observe(fun) do
    {result, deleting} = fun.()
    %{gateway: g, left: left, others: others} = Process.get(:review_prop)

    %{
      result: result,
      missing: Enum.reject(deleting, &deleted?/1),
      bound: Enum.sort(for t <- @threads, Review.binding(t), do: t),
      tokens: Enum.sort(for t <- @threads, :ets.lookup(Broker, {:thread, t}) != [], do: t),
      ended: for(t <- @threads, reason = Review.ended(t), into: %{}, do: {t, reason}),
      left: left,
      others: others,
      sandboxes: Enum.sort(Map.keys(FakeOpenShell.sandboxes(g))),
      providers: Enum.sort(Map.keys(FakeOpenShell.providers(g)))
    }
  end

  defp forget_left do
    ctx = Process.get(:review_prop)
    Process.put(:review_prop, %{ctx | left: []})
    ctx.left
  end

  # A deletion's provider goes after its sandbox, so once it is asked for the sandbox
  # is gone.
  defp deleted?(name) do
    ctx = Process.get(:review_prop)

    if name in ctx.deleted do
      Process.put(:review_prop, %{ctx | deleted: List.delete(ctx.deleted, name)})
      true
    else
      receive do
        {:openshell_request, "DeleteProvider", %{name: ^name}} -> gone(name)
      after
        @wait -> false
      end
    end
  end

  # Waits for what the review process was sent, and drops the gateway's other news
  # but deletions, which a later step may wait on.
  defp settle do
    :sys.get_state(Review)
    flush()
  end

  defp flush do
    receive do
      {:openshell_request, "DeleteProvider", %{name: name}} ->
        gone(name)
        ctx = Process.get(:review_prop)
        Process.put(:review_prop, %{ctx | deleted: [name | ctx.deleted]})
        flush()

      {:openshell_request, _, _} ->
        flush()
    after
      0 -> :ok
    end
  end

  # The fake keeps a sandbox's directory; a deleted sandbox's files go with it.
  defp gone(name) do
    File.rm_rf!(Path.join(Process.get(:review_prop).roots, name))
    true
  end

  defp discard do
    receive do
      _ -> discard()
    end
  end

  defp spec(t) do
    repo = Process.get(:review_prop).repo

    %{
      thread_id: t,
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
      tokens: @budget
    }
  end

  defp repo!(home) do
    repo = Path.join(home, "clone")
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
    {out, 0} = System.cmd("git", config ++ args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end
end
