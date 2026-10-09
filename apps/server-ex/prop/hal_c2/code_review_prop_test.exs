defmodule HalC2.CodeReviewPropTest do
  @moduledoc """
  A state machine model of the code-review plugin's MC process
  (`plugins/code-review/mc`), loaded and enabled through `HalC2.Plugins` as a user
  installs it, against a fake GitHub (`test/support/fake_gh.py`), fake remotes served
  over a fake `GIT_SSH_COMMAND`, and the fake Codex, whose review turns stay open.

  Three pull requests (`acme/api#1`, `acme/api#2`, `acme/web#1`) each have two head
  commits to push between. The commands open and close them, push, break a head so its
  checkout fails, hold checkouts at the fetch and posts at GitHub, refuse posts, look
  for pull requests, start, retry, report, dismiss, discard and publish reviews, end
  turns, answer a superseded post late, change settings, turn the plugin off and on,
  and crash it. After every step:

  - one review runs per pull request: each run has a thread of its own once it starts
    and none before, and a retry replaces a run rather than adding one;
  - every post is the one the model expects, on the commit its run reviewed, and a late
    answer to a superseded post leaves the newer run alone;
  - a report with nothing to post goes back to the agent as an error, and one posted
    automatically is answered once GitHub has, with how the post went;
  - turning the plugin off or restarting it calls off the checkouts and posts in flight,
    and the look for pull requests, and leaves no checkout no review points at;
  - the `reviews` snapshot, and the topic clients follow, match the model;
  - the plugin process is only replaced when the step restarts it.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @id "code-review"
  @server HalC2Plugins.CodeReview
  @package Path.expand("../../../../plugins/code-review", __DIR__)
  @support Path.expand("../../test/support", __DIR__)
  @prompt "Review \#{{pr.number}} {{pr.title}} in {{repository}}. answer from gate"
  @keys ["acme/api#1", "acme/api#2", "acme/web#1"]
  @prs %{"acme/api#1" => {"api", 1}, "acme/api#2" => {"api", 2}, "acme/web#1" => {"web", 1}}
  # Distinct, so the listing (newest first) comes in the order of `@keys`.
  @updated %{
    "acme/api#1" => "2026-09-03T00:00:00Z",
    "acme/api#2" => "2026-09-02T00:00:00Z",
    "acme/web#1" => "2026-09-01T00:00:00Z"
  }
  @order ~w(running queued publishing waiting failed kept ready published)a
  @events %{
    "approve" => "APPROVE",
    "request-changes" => "REQUEST_CHANGES",
    "comment" => "COMMENT"
  }
  @statuses Map.new(@order, &{Atom.to_string(&1), &1})

  setup_all do
    fx = Path.expand("../../tmp/prop/code-review-fixtures-#{System.pid()}", __DIR__)
    File.rm_rf!(fx)
    File.mkdir_p!(Path.join(fx, "holds"))
    shas = remotes(fx)

    ssh = Path.join(fx, "fake-ssh")

    # Serves `git@github.com:acme/<repo>.git` from `remotes/`; while `fetch.hold`
    # exists a fetch waits, its git's pid in `holds/<pid of this script>`, until the
    # hold goes or the test lets that git go with `holds/go-<git pid>` (a fetch may
    # connect more than once).
    File.write!(ssh, """
    #!/bin/sh
    for last; do :; done
    if [ -e '#{fx}/fetch.hold' ]; then
      marker='#{fx}/holds/'$$
      echo $PPID > "$marker.tmp" && mv "$marker.tmp" "$marker"
      while [ -e '#{fx}/fetch.hold' ] && [ ! -e '#{fx}/holds/go-'$PPID ] && [ -d '#{fx}' ]; do sleep 0.05; done
      rm -f "$marker"
    fi
    cd '#{fx}/remotes' && exec sh -c "$last"
    """)

    File.chmod!(ssh, 0o755)
    bin = Path.join(fx, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(@support, "fake_gh.py"), Path.join(bin, "gh"))

    vars = ~w(PATH FAKE_GH_RULES FAKE_GH_LOG GIT_SSH_COMMAND HAL_C2_FAKE_REMOTES FAKE_CODEX_GATE)
    previous_vars = Map.new(vars, &{&1, System.get_env(&1)})
    apps = ~w(gh_command codex_command settings_check_ms home)a
    previous_apps = Map.new(apps, &{&1, Application.fetch_env(:hal_c2, &1)})

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("FAKE_GH_RULES", Path.join(fx, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(fx, "calls.jsonl"))
    System.put_env("GIT_SSH_COMMAND", ssh)
    System.put_env("HAL_C2_FAKE_REMOTES", Path.join(fx, "remotes"))
    Application.put_env(:hal_c2, :gh_command, "gh")

    Application.put_env(:hal_c2, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

    Application.put_env(:hal_c2, :settings_check_ms, nil)
    :persistent_term.put({__MODULE__, :fx}, %{dir: fx, shas: shas})

    on_exit(fn ->
      for {var, value} <- previous_vars,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))

      for {key, value} <- previous_apps do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end

      File.rm_rf!(fx)
    end)

    :ok
  end

  property "code review runs one review per head, posts it once and leaves nothing behind when turned off",
    numtests: HalC2.Prop.numtests(30),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        begin_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        end_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------------

  # `reviews`: key → %{status, run (the run its thread is, nil before the first), seen
  # (the head the last look saw, 1 or 2), reviewed, changed, verdict, comments (one
  # dismissed flag each), publish_error, seq (order queued)}. `runs`: key → whether
  # each run so far got its thread and checkout, kept when a review is discarded.
  # `posts`: every post that reached GitHub, `{key, reviewed, comments, event}`.
  # `held_runs`/`held_pubs`: checkouts held at the fetch and posts held at GitHub.
  # Every pull request starts open, so the first look finds them all ready.
  def initial_state do
    look(%{
      enabled: true,
      settings: %{publishing: "draft", concurrency: 2, activation: "selective", new_pushes: false},
      prs: Map.new(@keys, &{&1, %{open: true, head: 1, broken: false}}),
      reviews: %{},
      runs: %{},
      posts: [],
      gate: :open,
      refusing: false,
      hold: false,
      held_runs: [],
      held_pubs: [],
      crashes: 0,
      seq: 0
    })
  end

  def command(m) do
    key = oneof(@keys)

    launched =
      for {key, runs} <- m.runs, {true, k} <- Enum.with_index(runs, 1), do: {key, k}

    superseded =
      for {key, runs} <- m.runs, k <- 1..(length(runs) - 1)//1, do: {key, k}

    # Mostly the run a review is on now, sometimes one it moved past.
    current =
      for {key, %{run: k}} when k != nil <- m.reviews, Enum.at(m.runs[key], k - 1), do: {key, k}

    run =
      if current == [],
        do: elements(launched),
        else: frequency([{4, elements(current)}, {1, elements(launched)}])

    # Mostly a review there is something to do with.
    waiting = for {key, %{status: :waiting}} <- m.reviews, do: key
    published = if waiting == [], do: key, else: frequency([{3, elements(waiting)}, {1, key}])
    commented = for {key, %{comments: [_ | _]}} <- m.reviews, do: key
    commented = if commented == [], do: key, else: frequency([{3, elements(commented)}, {1, key}])

    on =
      [
        {3, {:call, __MODULE__, :refresh, []}},
        {1, {:call, __MODULE__, :poll, []}},
        {5, {:call, __MODULE__, :start, [key]}},
        {2, {:call, __MODULE__, :retry, [key]}},
        {2, {:call, __MODULE__, :dismiss, [commented, oneof([1, 2]), boolean()]}},
        {2, {:call, __MODULE__, :discard, [key]}},
        {if(waiting == [], do: 2, else: 10), {:call, __MODULE__, :publish, [published]}},
        {1, {:call, __MODULE__, :disable, [oneof([:plain, :polling])]}}
      ] ++
        if(m.crashes < 2, do: [{1, {:call, __MODULE__, :crash, []}}], else: []) ++
        if(launched != [],
          do: [
            {6,
             {:call, __MODULE__, :report,
              [run, oneof([:findings, :findings, :approve, :nothing])]}},
            {1,
             {:call, __MODULE__, :turn_finished, [run, oneof(~w(completed failed interrupted))]}}
          ],
          else: []
        ) ++
        if(superseded != [],
          do: [{1, {:call, __MODULE__, :late_published, [elements(superseded)]}}],
          else: []
        )

    off = [{4, {:call, __MODULE__, :enable, []}}]

    always = [
      {3, {:call, __MODULE__, :push, [key]}},
      {2, {:call, __MODULE__, :toggle_open, [key]}},
      {1, {:call, __MODULE__, :break, [key]}},
      {2, {:call, __MODULE__, :gate, [oneof([:open, :closed])]}},
      {1, {:call, __MODULE__, :refuse, [boolean()]}},
      {2, {:call, __MODULE__, :hold, [boolean()]}},
      {2,
       {:call, __MODULE__, :save,
        [
          oneof([
            {"publishing", oneof(~w(local draft automatic))},
            {"concurrency", oneof([1, 2])},
            {"activation", oneof(~w(automatic selective))},
            {"reviewNewPushes", boolean()}
          ])
        ]}}
    ]

    frequency(if(m.enabled, do: on, else: off) ++ always)
  end

  @plugin_commands ~w(refresh poll start retry dismiss discard publish disable report turn_finished late_published)a

  def precondition(m, {:call, _, :enable, _}), do: not m.enabled
  def precondition(m, {:call, _, :crash, _}), do: m.enabled and m.crashes < 2

  def precondition(m, {:call, _, cmd, [{key, k} | _]}) when cmd in [:report, :turn_finished],
    do: m.enabled and Enum.at(m.runs[key] || [], k - 1) == true

  def precondition(m, {:call, _, :late_published, [{key, k}]}),
    do: m.enabled and k < length(m.runs[key] || [])

  def precondition(m, {:call, _, cmd, _}) when cmd in @plugin_commands, do: m.enabled
  def precondition(m, {:call, _, :push, [key]}), do: not m.prs[key].broken
  def precondition(_m, _call), do: true

  def next_state(m, _result, call), do: m |> step(call) |> elem(0)

  def postcondition(m, call, observed) do
    {m, reply} = step(m, call)

    expected = %{
      reply: reply,
      view: view(m),
      threads: for({key, runs} <- m.runs, runs != [], into: %{}, do: {key, runs}),
      checkouts: checkouts(m),
      orphans: [],
      posts: Enum.sort(m.posts),
      problems: []
    }

    observed = %{observed | posts: Enum.sort(observed.posts)}

    if observed != expected do
      for {field, value} <- expected, observed[field] != value do
        IO.puts(
          "#{inspect(call)}: #{field} expected #{inspect(value, limit: :infinity)}, " <>
            "got #{inspect(observed[field], limit: :infinity)}"
        )
      end
    end

    observed == expected
  end

  # `{model after call, the reply it expects}`; a reply is :ok, :error, :held (a post
  # GitHub holds) or nil (a step with no reply to check).
  defp step(m, {:call, _, :refresh, []}), do: {look(m), :ok}
  defp step(m, {:call, _, :poll, []}), do: {look(m), nil}

  defp step(m, {:call, _, :start, [key]}) do
    case m.reviews[key] do
      nil ->
        if m.prs[key].open,
          do: {m |> put_review(key, fresh(m, key)) |> queue(key) |> pump(), :ok},
          else: {m, :error}

      %{status: s} when s in [:queued, :running] ->
        {m, :ok}

      _ ->
        {m |> queue(key) |> pump(), :ok}
    end
  end

  defp step(m, {:call, _, :retry, [key]}) do
    case m.reviews[key] do
      nil -> {m, :error}
      %{status: s} when s in [:queued, :running] -> {m, :ok}
      _ -> {m |> queue(key) |> pump(), :ok}
    end
  end

  defp step(m, {:call, _, :dismiss, [key, i, flag]}) do
    case m.reviews[key] do
      %{comments: comments} = r when length(comments) >= i ->
        {put_review(m, key, %{r | comments: List.replace_at(comments, i - 1, flag)}), :ok}

      _ ->
        {m, :error}
    end
  end

  defp step(m, {:call, _, :discard, [key]}) do
    case m.reviews[key] do
      nil -> {m, :error}
      %{status: s} when s in [:running, :publishing] -> {m, :error}
      _ -> {pump(%{m | reviews: Map.delete(m.reviews, key)}), :ok}
    end
  end

  defp step(m, {:call, _, :publish, [key]}) do
    case m.reviews[key] do
      %{status: :waiting} = r ->
        m |> put_review(key, %{r | status: :publishing, publish_error: false}) |> post(key)

      _ ->
        {m, :error}
    end
  end

  defp step(m, {:call, _, :report, [{key, k}, kind]}) do
    case m.reviews[key] do
      %{run: ^k, status: s} = r when s not in [:queued, :ready, :published, :publishing] ->
        if kind == :nothing do
          {m, :error}
        else
          {verdict, comments} =
            if kind == :findings, do: {"request-changes", [false, false]}, else: {"approve", []}

          status =
            %{"local" => :kept, "draft" => :waiting, "automatic" => :publishing}[
              m.settings.publishing
            ]

          r = %{r | status: status, verdict: verdict, comments: comments, publish_error: false}
          m = put_review(m, key, r)

          # The agent is told how an automatic post went once GitHub has answered.
          if status == :publishing do
            {m, posted} = post(m, key)
            {pump(m), %{ok: :posted, error: :refused, held: :held}[posted]}
          else
            {pump(m), :ok}
          end
        end

      _ ->
        {m, nil}
    end
  end

  defp step(m, {:call, _, :turn_finished, [{key, k}, _status]}) do
    case m.reviews[key] do
      %{run: ^k, status: :running} = r ->
        {m |> put_review(key, %{r | status: :failed}) |> pump(), nil}

      _ ->
        {m, nil}
    end
  end

  defp step(m, {:call, _, :late_published, _}), do: {m, :ok}

  defp step(m, {:call, _, :disable, _}),
    do: {%{m | enabled: false, held_runs: [], held_pubs: []}, :ok}

  defp step(m, {:call, _, :enable, []}), do: {restart(%{m | enabled: true, crashes: 0}), :ok}
  defp step(m, {:call, _, :crash, []}), do: {restart(%{m | crashes: m.crashes + 1}), nil}

  defp step(m, {:call, _, :save, [{field, value}]}) do
    name =
      %{
        "publishing" => :publishing,
        "concurrency" => :concurrency,
        "activation" => :activation,
        "reviewNewPushes" => :new_pushes
      }[field]

    m = %{m | settings: Map.put(m.settings, name, value)}
    if m.enabled, do: {restart(%{m | crashes: 0}), :ok}, else: {m, :ok}
  end

  defp step(m, {:call, _, :push, [key]}),
    do: {update_pr(m, key, &%{&1 | head: 3 - &1.head}), :ok}

  defp step(m, {:call, _, :toggle_open, [key]}),
    do: {update_pr(m, key, &%{&1 | open: not &1.open}), :ok}

  defp step(m, {:call, _, :break, [key]}),
    do: {update_pr(m, key, &%{&1 | broken: not &1.broken}), :ok}

  defp step(m, {:call, _, :gate, [:closed]}), do: {%{m | gate: :closed}, :ok}

  defp step(m, {:call, _, :gate, [:open]}) do
    held = m.held_pubs
    m = %{m | gate: :open, held_pubs: []}
    {Enum.reduce(held, m, fn {key, run, refused}, m -> complete(m, key, run, refused) end), :ok}
  end

  defp step(m, {:call, _, :refuse, [refusing]}), do: {%{m | refusing: refusing}, :ok}
  defp step(m, {:call, _, :hold, [true]}), do: {%{m | hold: true}, :ok}

  defp step(m, {:call, _, :hold, [false]}) do
    held = m.held_runs
    m = %{m | hold: false, held_runs: []}
    {Enum.reduce(held, m, fn {key, k}, m -> resolve(m, key, k) end), :ok}
  end

  defp put_review(m, key, review), do: %{m | reviews: Map.put(m.reviews, key, review)}
  defp update_pr(m, key, fun), do: %{m | prs: Map.update!(m.prs, key, fun)}

  defp fresh(m, key) do
    %{
      status: :ready,
      run: nil,
      seen: m.prs[key].head,
      reviewed: nil,
      changed: false,
      verdict: nil,
      comments: [],
      publish_error: false,
      seq: nil
    }
  end

  defp queue(m, key) do
    review = %{
      m.reviews[key]
      | status: :queued,
        seq: m.seq + 1,
        verdict: nil,
        comments: [],
        publish_error: false,
        changed: false
    }

    %{put_review(m, key, review) | seq: m.seq + 1}
  end

  # What a look at the open pull requests does, in the listing's order.
  defp look(m) do
    automatic = m.settings.activation == "automatic"
    reviews = Map.reject(m.reviews, fn {key, r} -> r.status == :ready and not m.prs[key].open end)

    m =
      Enum.reduce(@keys, %{m | reviews: reviews}, fn key, m ->
        pr = m.prs[key]
        known = m.reviews[key]

        cond do
          not pr.open ->
            m

          known && known.status in [:queued, :running] ->
            put_review(m, key, %{known | seen: pr.head})

          known == nil or known.reviewed == nil ->
            m = put_review(m, key, %{(known || fresh(m, key)) | seen: pr.head})
            if automatic, do: queue(m, key), else: m

          known.reviewed == pr.head ->
            put_review(m, key, %{known | seen: pr.head, changed: false})

          automatic and m.settings.new_pushes ->
            m |> put_review(key, %{known | seen: pr.head}) |> queue(key)

          true ->
            put_review(m, key, %{known | seen: pr.head, changed: true})
        end
      end)

    pump(m)
  end

  # Starts queued reviews, oldest first, while fewer than `concurrency` run; each
  # start is a new run, held at the fetch while the hold is on.
  defp pump(m) do
    running = Enum.count(m.reviews, fn {_, r} -> r.status == :running end)

    taken =
      m.reviews
      |> Enum.filter(fn {_, r} -> r.status == :queued end)
      |> Enum.sort_by(fn {_, r} -> r.seq end)
      |> Enum.take(max(m.settings.concurrency - running, 0))
      |> Enum.map(&elem(&1, 0))

    m =
      Enum.reduce(taken, m, fn key, m ->
        runs = (m.runs[key] || []) ++ [false]
        m = %{m | runs: Map.put(m.runs, key, runs)}
        put_review(m, key, %{m.reviews[key] | status: :running, run: length(runs)})
      end)

    started = Enum.map(taken, &{&1, m.reviews[&1].run})

    if m.hold,
      do: %{m | held_runs: m.held_runs ++ started},
      else: Enum.reduce(started, m, fn {key, k}, m -> resolve(m, key, k) end)
  end

  # Run `k` of `key` gets past the fetch: a broken head fails it, any other is checked
  # out as it is now and gets the run's thread.
  defp resolve(m, key, k) do
    case m.reviews[key] do
      %{status: :running, run: ^k} = r ->
        if m.prs[key].broken do
          m |> put_review(key, %{r | status: :failed}) |> pump()
        else
          m = put_review(m, key, %{r | reviewed: m.prs[key].head})
          %{m | runs: Map.update!(m.runs, key, &List.replace_at(&1, k - 1, true))}
        end

      _ ->
        m
    end
  end

  # Posts the review of `key` as it is now; GitHub answers at once unless the gate holds it.
  defp post(m, key) do
    r = m.reviews[key]
    kept = Enum.count(r.comments, &(not &1))
    m = %{m | posts: m.posts ++ [{key, r.reviewed, kept, @events[r.verdict]}]}

    if m.gate == :closed,
      do: {%{m | held_pubs: m.held_pubs ++ [{key, r.run, m.refusing}]}, :held},
      else: {complete(m, key, r.run, m.refusing), if(m.refusing, do: :error, else: :ok)}
  end

  # GitHub's answer to the post of run `run` lands only on that run, still being posted.
  defp complete(m, key, run, refused) do
    case m.reviews[key] do
      %{status: :publishing, run: ^run} = r ->
        r =
          if refused,
            do: %{r | status: :waiting, publish_error: true},
            else: %{r | status: :published, publish_error: false}

        put_review(m, key, r)

      _ ->
        m
    end
  end

  # The plugin starts again from what it saved: a run it was starting failed, a post
  # it was making waits, and it looks at once.
  defp restart(m) do
    reviews =
      Map.new(m.reviews, fn {key, r} ->
        case r.status do
          :running -> {key, %{r | status: :failed}}
          :publishing -> {key, %{r | status: :waiting}}
          _ -> {key, r}
        end
      end)

    look(%{m | reviews: reviews, held_runs: [], held_pubs: []})
  end

  defp view(%{enabled: false}), do: :off

  defp view(m) do
    m.reviews
    |> Enum.sort_by(fn {key, r} ->
      {repo, number} = @prs[key]
      {Enum.find_index(@order, &(&1 == r.status)), repo, -number}
    end)
    |> Enum.map(fn {key, r} ->
      run = if r.status in [:queued, :ready], do: nil, else: r.run
      {key, r.status, run, r.seen, r.reviewed, r.changed, r.verdict, r.comments, r.publish_error}
    end)
  end

  # A review's checkout stays from its run's start until its next run starts or it is
  # discarded.
  defp checkouts(m) do
    Enum.count(m.reviews, fn {key, r} -> r.run != nil and Enum.at(m.runs[key], r.run - 1) end)
  end

  # --- commands ---------------------------------------------------------------------------

  def refresh, do: observe(call("refresh", %{}))

  def poll do
    send(@server, :poll)
    observe(nil)
  end

  def start(key) do
    {repo, number} = @prs[key]
    observe(call("start", %{"repository" => "acme/#{repo}", "number" => number}))
  end

  def retry(key), do: observe(call("retry", %{"key" => key}))

  def dismiss(key, i, flag),
    do: observe(call("dismiss", %{"key" => key, "commentId" => "c#{i}", "dismissed" => flag}))

  def discard(key), do: observe(call("discard", %{"key" => key}))

  # Asked of the plugin directly, as `call("publish")` waits for GitHub's answer.
  def publish(key) do
    ref = make_ref()
    send(@server, {:"$gen_call", {self(), ref}, {:publish, key}})
    drain()

    receive do
      {^ref, reply} -> observe(reply(reply))
    after
      0 -> observe(:held)
    end
  end

  def report({key, k}, kind) do
    arguments =
      case kind do
        :findings ->
          %{
            "verdict" => "request-changes",
            "summary" => "Two things.",
            "comments" => [
              %{"path" => "src/limits.ts", "line" => 1, "body" => "One."},
              %{"path" => "src/limits.ts", "line" => 2, "body" => "Two."}
            ]
          }

        :approve ->
          %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}

        :nothing ->
          %{"verdict" => "comment", "summary" => " ", "comments" => []}
      end

    # Asked from a process of its own, as a report posted automatically is answered
    # only once GitHub has answered.
    me = self()
    ref = make_ref()
    tid = tid(key, k)
    # A post already in flight (the user's, or an earlier report's) is not this
    # report's: the review takes no report then, and the answer comes at once.
    posting = posting?(key, tid)

    spawn(fn ->
      send(me, {ref, HalC2.Plugins.call_tool("code_review_report", arguments, tid)})
    end)

    observe(await_report(ref, key, tid, posting, System.monotonic_time(:millisecond) + 15_000))
  end

  # The report's answer, or `:held` once its post is the plugin's and GitHub holds it.
  defp await_report(ref, key, tid, posting, deadline) do
    receive do
      {^ref, answer} -> told(answer)
    after
      0 ->
        cond do
          not posting and posting?(key, tid) ->
            drain()

            if posting?(key, tid) do
              :held
            else
              receive do
                {^ref, answer} -> told(answer)
              after
                15_000 -> problem("the report of #{key} was never answered")
              end
            end

          System.monotonic_time(:millisecond) > deadline ->
            problem("the report of #{key} was never answered")

          true ->
            Process.sleep(5)
            await_report(ref, key, tid, posting, deadline)
        end
    end
  end

  defp posting?(key, tid) do
    case get_state(Process.whereis(@server)) do
      {:ok, %{reviews: %{^key => %{"status" => "publishing", "threadId" => ^tid}}}} -> true
      _ -> false
    end
  end

  defp told({:ok, %{"next" => next}}) do
    cond do
      next =~ "is posted" -> :posted
      next =~ "failed" -> :refused
      true -> :ok
    end
  end

  defp told({:error, _, _}), do: :error
  defp told(nil), do: nil

  def turn_finished({key, k}, status) do
    event = %{"type" => "turn.finished", "threadId" => tid(key, k), "status" => status}
    # Compiled when the plugin starts, so unknown to the compiler here.
    apply(@server, :handle_event, [event, %{}])
    observe(nil)
  end

  def late_published({key, k}),
    do: observe(reply(GenServer.call(@server, {:published, key, tid(key, k), nil})))

  def disable(:plain),
    do: observe(killing(fn -> plugins("disable", %{"id" => @id}) end), :restarted)

  # Turned off while the look for pull requests waits on GitHub: the look ends with it.
  def disable(:polling) do
    hold = fx_path("list.hold")
    pids = fx_path("list.pids")
    File.write!(hold, "")
    File.write!(pids, "")
    send(@server, :poll)
    wait_for_file(pids)
    {:monitors, [{:process, poller} | _]} = Process.info(Process.whereis(@server), :monitors)
    ref = Process.monitor(poller)
    reply = killing(fn -> plugins("disable", %{"id" => @id}) end)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      2_000 ->
        problem("the look for pull requests outlived code-review being turned off")
        File.rm(hold)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          10_000 -> problem("the look for pull requests never ended")
        end
    end

    File.rm(hold)
    observe(reply, :restarted)
  end

  def enable do
    observe(plugins("enable", %{"id" => @id, "acceptPermissions" => permissions()}), :restarted)
  end

  def crash do
    pid = Process.whereis(@server)
    {:parent, sup} = Process.info(pid, :parent)

    killing(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
      await_restart(sup, pid, 1_000)
    end)

    observe(nil, :restarted)
  end

  def save({field, value}) do
    restarts = if Process.whereis(@server), do: :restarted, else: :same

    killing(fn -> plugins("saveSettings", %{"id" => @id, "settings" => %{field => value}}) end)
    |> observe(restarts)
  end

  def push(key) do
    world = Process.get(:cr_world)
    pr = world.prs[key]
    {repo, number} = @prs[key]
    head = 3 - pr.head

    git!(fx_dir(), [
      "--git-dir",
      bare(repo),
      "update-ref",
      "refs/pull/#{number}/head",
      sha(key, head)
    ])

    put_world(put_in(world.prs[key].head, head))
    observe(:ok)
  end

  def toggle_open(key) do
    world = Process.get(:cr_world)
    put_world(update_in(world.prs[key].open, &(not &1)))
    observe(:ok)
  end

  def break(key) do
    world = Process.get(:cr_world)
    pr = world.prs[key]
    {repo, number} = @prs[key]
    ref = "refs/pull/#{number}/head"

    if pr.broken,
      do: git!(fx_dir(), ["--git-dir", bare(repo), "update-ref", ref, sha(key, pr.head)]),
      else: git!(fx_dir(), ["--git-dir", bare(repo), "update-ref", "-d", ref])

    put_world(put_in(world.prs[key].broken, not pr.broken))
    observe(:ok)
  end

  def gate(:closed) do
    File.write!(fx_path("gate.closed"), "")
    observe(:ok)
  end

  def gate(:open) do
    File.rm(fx_path("gate.closed"))
    observe(:ok)
  end

  def refuse(refusing) do
    put_world(%{Process.get(:cr_world) | refusing: refusing})
    observe(:ok)
  end

  def hold(true) do
    File.write!(fx_path("fetch.hold"), "")
    observe(:ok)
  end

  def hold(false) do
    File.rm(fx_path("fetch.hold"))
    observe(:ok)
  end

  defp call(method, input) do
    reply(HalC2.Plugins.handle("call", %{"id" => @id, "method" => method, "input" => input}))
  end

  defp plugins(method, input), do: reply(HalC2.Plugins.handle(method, input))

  defp reply({:ok, _}), do: :ok
  defp reply(:ok), do: :ok
  defp reply({:error, _}), do: :error

  defp tid(key, k), do: Enum.at(Process.get(:cr_tids)[key] || [], k - 1)

  # --- observing --------------------------------------------------------------------------

  # Waits for the plugin to settle, then reads what the model checks. `restarts` says
  # whether the step replaces the plugin process (`:restarted`) or keeps it (`:same`).
  defp observe(reply, restarts \\ :same) do
    drain()
    :sys.get_state(HalC2.Plugins)
    take_messages()
    pid = Process.whereis(@server)
    before = Process.get(:cr_pid)

    case restarts do
      :same when pid != before ->
        problem("code-review's process changed: #{inspect(before)} → #{inspect(pid)}")

      :restarted when pid != nil and pid == before ->
        problem("code-review was not restarted")

      _ ->
        :ok
    end

    Process.put(:cr_pid, pid)

    view =
      if pid do
        snapshot = GenServer.call(@server, :snapshot)
        if snapshot["problem"], do: problem("code-review reports: #{snapshot["problem"]}")
        published = snapshot |> JSON.encode!() |> JSON.decode!()

        if Process.get(:cr_topic) != published,
          do: problem("the reviews topic is behind: #{inspect(Process.get(:cr_topic))}")

        Enum.map(snapshot["reviews"], &review_view/1)
      else
        :off
      end

    %{
      reply: reply,
      view: view,
      threads: threads(),
      checkouts: length(checkout_dirs()),
      orphans: orphans(),
      posts: posts(),
      problems: Process.put(:cr_problems, []) |> Enum.reverse()
    }
  end

  defp review_view(r) do
    key = r["key"]

    {key, @statuses[r["status"]], run(key, r["threadId"]), head(r["headSha"]),
     head(r["reviewedSha"]), r["changed"] == true, r["verdict"],
     Enum.map(r["comments"] || [], &(&1["dismissed"] == true)), r["publishError"] != nil}
  end

  # The run a thread id is: its place among the thread ids seen for the review.
  defp run(_key, nil), do: nil

  defp run(key, tid) do
    tids = Process.get(:cr_tids)
    seen = tids[key] || []

    case Enum.find_index(seen, &(&1 == tid)) do
      nil ->
        Process.put(:cr_tids, Map.put(tids, key, seen ++ [tid]))
        length(seen) + 1

      i ->
        i + 1
    end
  end

  defp head(nil), do: nil
  defp head(sha), do: Map.get(fx().heads, sha, {:unknown, sha})

  # Whether each run seen has its thread.
  defp threads do
    for {key, tids} <- Process.get(:cr_tids), into: %{} do
      {key, Enum.map(tids, &thread?/1)}
    end
  end

  defp thread?(tid) do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(tid))
    HalC2.StreamState.get(state, "thread")[tid] != nil
  end

  defp checkout_dirs,
    do: Path.wildcard(Path.join([data_dir(), "checkouts", "*", "pr-*", "*"]))

  # Checkouts on disk that no saved review points at.
  defp orphans do
    saved =
      case File.read(Path.join(data_dir(), "reviews.json")) do
        {:ok, text} ->
          for {_, r} <- JSON.decode!(text)["reviews"],
              r["checkout"],
              do: Path.expand(r["checkout"])

        _ ->
          []
      end

    Enum.reject(checkout_dirs(), &(Path.expand(&1) in saved))
  end

  defp data_dir, do: Path.join([HalC2.Paths.data_dir(), "plugin-data", @id])

  # Every review posted to the fake GitHub: `{key, head, comments, event}`.
  defp posts do
    fx_path("calls.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.flat_map(fn call ->
      args = Enum.join(call["args"] || [], " ")

      case Regex.run(~r{--method POST .*repos/acme/(\w+)/pulls/(\d+)/reviews}, args) do
        [_, repo, number] ->
          body = JSON.decode!(call["stdin"])

          [
            {"acme/#{repo}##{number}", head(body["commit_id"]), length(body["comments"] || []),
             body["event"]}
          ]

        nil ->
          []
      end
    end)
  end

  defp take_messages do
    receive do
      {:hal_c2_plugin_topic, _, @id, "reviews", value} ->
        Process.put(:cr_topic, value)
        take_messages()

      _ ->
        take_messages()
    after
      0 -> :ok
    end
  end

  defp problem(text), do: Process.put(:cr_problems, [text | Process.get(:cr_problems, [])])

  # --- settling -------------------------------------------------------------------------

  # Returns once the plugin has nothing in flight but runs held at the fetch and posts
  # held at GitHub, and has heard from everything that ended.
  defp drain, do: drain(System.monotonic_time(:millisecond) + 15_000, false)

  defp drain(deadline, settled_once) do
    with pid when is_pid(pid) <- Process.whereis(@server),
         {:ok, state} <- get_state(pid) do
      kids = kids(pid)

      cond do
        System.monotonic_time(:millisecond) > deadline ->
          problem("code-review never settled: #{length(kids)} processes, #{parked()} held")

        state.polling != nil ->
          await_poller(pid, deadline)
          drain(deadline, false)

        length(kids) == parked() ->
          # Once more, for what the processes that just ended told it.
          if settled_once, do: :ok, else: drain(deadline, true)

        true ->
          await_any(kids)
          drain(deadline, false)
      end
    else
      _ -> :ok
    end
  end

  defp get_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _ -> :gone
  end

  defp kids(pid) do
    {:parent, parent} = Process.info(pid, :parent)
    {:links, links} = Process.info(pid, :links)
    Enum.filter(links, &(is_pid(&1) and &1 != parent))
  end

  defp await_poller(pid, deadline) do
    case Process.info(pid, :monitors) do
      {:monitors, [{:process, poller} | _]} ->
        ref = Process.monitor(poller)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            Process.demonitor(ref, [:flush])
        end

      _ ->
        :ok
    end
  end

  defp await_any(kids) do
    refs = Enum.map(kids, &Process.monitor/1)

    receive do
      {:DOWN, ref, :process, _, _} when is_reference(ref) -> :ok
    after
      20 -> :ok
    end

    for ref <- refs, do: Process.demonitor(ref, [:flush])
  end

  # Runs held at the fetch and posts held at GitHub.
  defp parked do
    if(File.exists?(fx_path("fetch.hold")), do: length(markers()), else: 0) +
      if File.exists?(fx_path("gate.closed")), do: length(gated()), else: 0
  end

  # The git pid of each fetch the hold keeps waiting.
  defp markers do
    holds = fx_path("holds")

    for name <- File.ls!(holds),
        name =~ ~r/^\d+$/,
        {:ok, text} <- [File.read(Path.join(holds, name))],
        git = String.trim(text),
        not File.exists?(Path.join(holds, "go-" <> git)),
        do: git
  end

  # The fake gh processes GitHub holds a post in.
  defp gated do
    case File.read(fx_path("gate.pids")) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.uniq()
        |> Enum.filter(&fake_gh?/1)

      _ ->
        []
    end
  end

  defp fake_gh?(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, state | _] <-
           stat |> String.split(") ", parts: 2) |> List.last() |> String.split(" "),
         true <- state != "Z",
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline") do
      String.contains?(cmdline, fx_dir())
    else
      _ -> false
    end
  end

  # Runs `fun`, which stops the plugin, and checks that the checkouts and posts it had
  # in flight were called off: each held fetch is let go and must finish on its own, and
  # each held post's gh must be gone.
  defp killing(fun) do
    markers = if File.exists?(fx_path("fetch.hold")), do: markers(), else: []
    pythons = if File.exists?(fx_path("gate.closed")), do: gated(), else: []
    result = fun.()

    for git <- markers do
      File.write!(fx_path("holds/go-" <> git), "")
      if not gone?(git), do: problem("the fetch in git #{git} never finished")
    end

    for py <- pythons,
        not gone?(py),
        do: problem("the post in gh #{py} outlived code-review stopping")

    result
  end

  defp gone?(pid) do
    match?(
      {_, 0},
      System.cmd("timeout", ["5", "tail", "--pid=#{pid}", "-s", "0.05", "-f", "/dev/null"])
    )
  end

  defp wait_for_file(path) do
    {_, 0} =
      System.cmd("timeout", ["5", "sh", "-c", "until [ -s '#{path}' ]; do sleep 0.05; done"])
  end

  defp await_restart(_sup, _old, 0), do: problem("code-review was not restarted after a crash")

  defp await_restart(sup, old, tries) do
    case Supervisor.which_children(sup) do
      [{_, pid, _, _}] when is_pid(pid) and pid != old ->
        :ok

      _ ->
        :sys.get_state(sup)
        await_restart(sup, old, tries - 1)
    end
  end

  # --- one case ----------------------------------------------------------------------------

  defp begin_case do
    home = HalC2.Prop.scratch_home("code-review")
    fx = fx_dir()
    File.write!(fx_path("calls.jsonl"), "")

    for name <- ~w(gate.closed fetch.hold list.hold gate.pids list.pids),
        do: File.rm(fx_path(name))

    File.rm_rf!(fx_path("holds"))
    File.mkdir_p!(fx_path("holds"))
    codex_gate = Path.join(home, "codex-gate")
    File.mkdir_p!(codex_gate)
    System.put_env("FAKE_CODEX_GATE", codex_gate)

    for key <- @keys do
      {repo, number} = @prs[key]
      git!(fx, ["--git-dir", bare(repo), "update-ref", "refs/pull/#{number}/head", sha(key, 1)])
    end

    roots =
      for repo <- ~w(api web) do
        root = Path.join([home, "roots", repo])
        File.mkdir_p!(Path.dirname(root))
        git!(home, ["clone", "-q", bare(repo), root])
        git!(root, ["remote", "set-url", "origin", "git@github.com:acme/#{repo}.git"])
        {repo, root}
      end

    Process.put(:cr_tids, %{})
    Process.put(:cr_problems, [])

    put_world(%{
      prs: Map.new(@keys, &{&1, %{open: true, head: 1, broken: false}}),
      refusing: false
    })

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Settings,
      HalC2.Streams,
      HalC2.Shell,
      HalC2.Orchestration.TurnWatch,
      {Registry, keys: :unique, name: HalC2.Codex.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Claude.Registry},
        id: :claude_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Acp.Registry},
        id: :acp_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: HalC2.Pi.Registry}, id: :pi_registry),
      {DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one},
      HalC2.Mcp,
      {Registry, keys: :unique, name: HalC2.Vcs.Registry},
      {DynamicSupervisor, name: HalC2.Vcs.Supervisor, strategy: :one_for_one},
      HalC2.PullRequests.Refreshes,
      HalC2.Plugins
    ])

    :sys.get_state(HalC2.Plugins)

    for {repo, root} <- roots do
      {:ok, _} =
        HalC2.Projects.mutate(%{
          "type" => "project.create",
          "projectId" => repo,
          "title" => repo,
          "workspaceRoot" => root
        })

      HalC2.Streams.flush_shell(repo)
    end

    :sys.get_state(HalC2.Shell)
    File.mkdir_p!(Path.join(HalC2.Paths.data_dir(), "plugins"))
    File.cp_r!(@package, Path.join([HalC2.Paths.data_dir(), "plugins", @id]))
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})

    {:ok, _} =
      HalC2.Plugins.handle("enable", %{"id" => @id, "acceptPermissions" => permissions()})

    {:ok, _} =
      HalC2.Plugins.handle("saveSettings", %{
        "id" => @id,
        "settings" => %{
          "provider" => "codex",
          "model" => "fake/one",
          "prompt" => @prompt,
          "pollMinutes" => 60,
          "command" => "",
          "repositories" => ["acme/api", "acme/web"],
          "activation" => "selective",
          "publishing" => "draft",
          "concurrency" => 2,
          "reviewNewPushes" => false,
          "readReviewMd" => false
        }
      })

    {:ok, last} = HalC2.Plugins.subscribe_topic(self(), @id, "reviews")
    Process.put(:cr_topic, last)
    HalC2.PullRequests.invalidate(%{})
    drain()
    :sys.get_state(HalC2.Plugins)
    take_messages()
    Process.put(:cr_pid, Process.whereis(@server))
  end

  defp end_case do
    for name <- ~w(gate.closed fetch.hold list.hold), do: File.rm(fx_path(name))
    HalC2.Prop.stop_services()
    # The fake Codex turns still open end, and their processes with them.
    File.write(Path.join(System.get_env("FAKE_CODEX_GATE"), "answer"), "")
    take_messages()
  end

  defp permissions do
    {:ok, %{"plugins" => plugins}} = HalC2.Plugins.handle("list", %{})
    Enum.find(plugins, &(&1["id"] == @id))["permissions"] |> Enum.map(& &1["id"])
  end

  # --- the fake GitHub -------------------------------------------------------------------

  defp put_world(world) do
    Process.put(:cr_world, world)
    fx = fx_dir()

    gate =
      "echo $PPID >> '#{fx}/gate.pids'; while [ -e '#{fx}/gate.closed' ] && [ -d '#{fx}' ]; do sleep 0.05; done"

    hold =
      "echo $PPID >> '#{fx}/list.pids'; while [ -e '#{fx}/list.hold' ] && [ -d '#{fx}' ]; do sleep 0.05; done"

    lists =
      for repo <- ~w(api web) do
        %{
          "args" => ["pr list", "--repo github.com/acme/#{repo}"],
          "run" => hold,
          "stdout" => listing(world, repo)
        }
      end

    refusal = %{
      "args" => ["--method POST", "pulls/"],
      "run" => gate,
      "exit" => 1,
      "stderr" => "gh: Unprocessable Entity\nCan not approve your own pull request (HTTP 422)\n",
      "stdout" => %{
        "message" => "Unprocessable Entity",
        "errors" => ["Can not approve your own pull request"]
      }
    }

    rules =
      [%{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}}] ++
        lists ++
        [permissions_rule()] ++
        if(world.refusing, do: [refusal], else: []) ++
        [%{"args" => ["--method POST", "pulls/"], "run" => gate, "stdout" => "{}"}]

    path = fx_path("rules.json")
    File.write!(path <> ".tmp", JSON.encode!(rules))
    File.rename!(path <> ".tmp", path)
  end

  defp listing(world, repo) do
    for key <- @keys,
        {^repo, number} <- [@prs[key]],
        world.prs[key].open do
      %{
        "number" => number,
        "title" => "Pull request #{number}",
        "url" => "https://github.com/acme/#{repo}/pull/#{number}",
        "author" => %{"login" => "octocat"},
        "headRefName" => "feature/#{number}",
        "baseRefName" => "main",
        "state" => "OPEN",
        "isDraft" => false,
        "createdAt" => "2026-09-01T00:00:00Z",
        "updatedAt" => @updated[key],
        "reviewRequests" => [],
        "latestReviews" => [],
        "labels" => [],
        "statusCheckRollup" => [],
        "headRefOid" => sha(key, world.prs[key].head),
        "additions" => 5,
        "deletions" => 0
      }
    end
  end

  defp permissions_rule do
    %{
      "args" => ["api graphql"],
      "stdin" => ["viewerCanUpdate viewerDidAuthor }"],
      "stdout" => %{
        "data" => %{
          "repository" => %{
            "mergeCommitAllowed" => true,
            "squashMergeAllowed" => true,
            "rebaseMergeAllowed" => true,
            "viewerPermission" => "WRITE",
            "pullRequest" => %{"viewerCanUpdate" => true, "viewerDidAuthor" => false}
          }
        }
      }
    }
  end

  # The fake remotes: `acme/api` and `acme/web`, each pull request with two head
  # commits off `main` that change `src/limits.ts`. Returns `{key, i}` → sha.
  defp remotes(fx) do
    for repo <- ~w(api web), reduce: %{} do
      shas ->
        bare = Path.join([fx, "remotes", "acme", "#{repo}.git"])
        File.mkdir_p!(Path.dirname(bare))
        git!(fx, ["init", "-q", "--bare", "-b", "main", bare])
        seed = Path.join(fx, "seed-#{repo}")
        git!(fx, ["init", "-q", "-b", "main", seed])
        File.write!(Path.join(seed, "README.md"), "# #{repo}\n")
        git!(seed, ["add", "README.md"])
        git!(seed, ["commit", "-q", "-m", "Start"])
        git!(seed, ["push", "-q", bare, "main:main"])

        for {key, {^repo, number}} <- @prs, i <- 1..2, reduce: shas do
          shas ->
            git!(seed, ["checkout", "-q", "--detach", "main"])
            File.mkdir_p!(Path.join(seed, "src"))

            File.write!(
              Path.join(seed, "src/limits.ts"),
              "export const limit = #{number}#{i};\nexport const name = \"#{repo} #{i}\";\n"
            )

            git!(seed, ["add", "src/limits.ts"])
            git!(seed, ["commit", "-q", "-m", "#{key} at #{i}"])
            sha = git!(seed, ["rev-parse", "HEAD"])
            git!(seed, ["push", "-q", bare, "HEAD:refs/fixtures/#{number}/#{i}"])
            Map.put(shas, {key, i}, sha)
        end
    end
  end

  defp git!(dir, args) do
    config = ~w(-c user.name=Prop -c user.email=prop@example.com -c commit.gpgsign=false)

    case System.cmd("git", config ++ args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> raise "git #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end

  defp fx do
    case Process.get(:cr_fx) do
      nil ->
        %{dir: dir, shas: shas} = :persistent_term.get({__MODULE__, :fx})
        fx = %{dir: dir, shas: shas, heads: Map.new(shas, fn {{_key, i}, sha} -> {sha, i} end)}
        Process.put(:cr_fx, fx)
        fx

      fx ->
        fx
    end
  end

  defp fx_dir, do: fx().dir
  defp fx_path(name), do: Path.join(fx_dir(), name)
  defp sha(key, i), do: fx().shas[{key, i}]
  defp bare(repo), do: Path.join([fx_dir(), "remotes", "acme", "#{repo}.git"])
end
