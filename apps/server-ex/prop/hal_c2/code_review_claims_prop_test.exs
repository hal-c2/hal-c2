defmodule HalC2.CodeReviewClaimsPropTest do
  @moduledoc """
  A state machine model of how the code-review plugin (`plugins/code-review/mc`) shares
  the reviewing of a pull request's commits with another of the user's machines.

  The plugin runs here as in `HalC2.CodeReviewPropTest` (loaded and enabled through
  `HalC2.Plugins`, against the fake GitHub, fake remotes and the fake Codex whose turns
  stay open), reviewing every new head of `acme/api#1` and `acme/api#2` on its own,
  one review at a time, and publishing when asked. The other machine, "laptop", is a
  bare `:peer` node with only a stand-in `HalC2.Plugins.Host`, whose `peer/3` answers
  the rows (queued, running, claimed, published, each maybe holding a claim of the
  other commit) the test gives it, or that its plugin is restarting, so the plugin sees
  a peer whose claims the test controls. The commands set and clear those rows,
  restart the laptop's plugin, cut the laptop off and connect it again, push, look,
  ask for reviews, hold checkouts at the fetch, report, stop a run at the agent's usage
  limit, publish and crash the plugin. A change of the laptop's rows while it is
  connected, and its plugin coming back, reach the plugin as a real peer's would, by
  `Host.peer/3` calling `claims_changed/0` here. After every step:

  - a run launches its thread only when the connected laptop neither claims the commit
    it checked out at the moment it claims it nor is restarting its plugin; one that
    does not is back to ready, left to the laptop, and its checkout is gone;
  - what this machine shares (`claims/1`) is the model's row for each review, a commit
    it reviewed held when the review is queued again for another head;
  - the `reviews` snapshot, `elsewhere` included, and the topic clients follow, match
    the model;
  - a publish is refused, and nothing posted, exactly when the connected laptop has
    published the reviewed commit or is restarting its plugin;
  - when the laptop leaves, or tells it no longer has a review this machine left to
    it, that review is looked at again at once; one it still has, or may have while
    its plugin restarts, shows where it is now;
  - paused at the usage limit, this machine shares no queued review, and the user's
    ask that ends the pause still leaves a commit the laptop claimed to the laptop.
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
  @keys ["acme/api#1", "acme/api#2"]
  @numbers %{"acme/api#1" => 1, "acme/api#2" => 2}
  # Distinct, so the listing (newest first) comes in the order of `@keys`.
  @updated %{"acme/api#1" => "2026-09-03T00:00:00Z", "acme/api#2" => "2026-09-02T00:00:00Z"}
  @order ~w(running queued publishing waiting failed kept ready published)a
  @statuses Map.new(@order, &{Atom.to_string(&1), &1})
  # The rows the laptop may hold for a pull request: queued or running there but not
  # yet started (soft), or started on a commit (hard).
  @rows [{"queued", false}, {"running", false}, {"running", true}, {"published", true}]
  @paused "code-review reports: Reviews are paused: the agent hit its usage limit, which resets at 2999-01-01T00:00:00Z. Queued reviews wait instead of failing one by one."

  setup_all do
    fx = Path.expand("../../tmp/prop/code-review-claims-fixtures-#{System.pid()}", __DIR__)
    File.rm_rf!(fx)
    File.mkdir_p!(Path.join(fx, "holds"))
    shas = remotes(fx)
    ssh = Path.join(fx, "fake-ssh")

    # Serves `git@github.com:acme/<repo>.git` from `remotes/`; while `fetch.hold`
    # exists a fetch waits, its git's pid in `holds/<pid of this script>`.
    File.write!(ssh, """
    #!/bin/sh
    for last; do :; done
    if [ -e '#{fx}/fetch.hold' ]; then
      marker='#{fx}/holds/'$$
      echo $PPID > "$marker.tmp" && mv "$marker.tmp" "$marker"
      while [ -e '#{fx}/fetch.hold' ] && [ -d '#{fx}' ]; do sleep 0.05; done
      rm -f "$marker"
    fi
    cd '#{fx}/remotes' && exec sh -c "$last"
    """)

    File.chmod!(ssh, 0o755)
    bin = Path.join(fx, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(@support, "fake_gh.py"), Path.join(bin, "gh"))

    vars =
      ~w(PATH FAKE_GH_RULES FAKE_GH_LOG GIT_SSH_COMMAND HAL_C2_FAKE_REMOTES FAKE_CODEX_GATE
         GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0)

    previous_vars = Map.new(vars, &{&1, System.get_env(&1)})
    apps = ~w(gh_command codex_command settings_check_ms home)a
    previous_apps = Map.new(apps, &{&1, Application.fetch_env(:hal_c2, &1)})

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("FAKE_GH_RULES", Path.join(fx, "rules.json"))
    System.put_env("FAKE_GH_LOG", Path.join(fx, "calls.jsonl"))
    System.put_env("GIT_SSH_COMMAND", ssh)
    System.put_env("HAL_C2_FAKE_REMOTES", Path.join(fx, "remotes"))
    # The plugin fetches GitHub over HTTPS, which the fake remote answers over SSH.
    System.put_env(%{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "url.git@github.com:.insteadOf",
      "GIT_CONFIG_VALUE_0" => "https://github.com/"
    })

    Application.put_env(:hal_c2, :gh_command, "gh")

    Application.put_env(:hal_c2, :codex_command, [
      "python3",
      "-u",
      Path.join(@support, "fake_codex.py")
    ])

    Application.put_env(:hal_c2, :settings_check_ms, nil)
    started_distribution = distribute()
    laptop = start_laptop()
    :persistent_term.put({__MODULE__, :fx}, %{dir: fx, shas: shas, laptop: laptop})

    on_exit(fn ->
      stop_laptop(laptop)
      if started_distribution, do: :net_kernel.stop()

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

  property "of two connected machines one reviews each commit, and it posts its review once",
    numtests: HalC2.Prop.numtests(60),
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

  # `prs`: key → its head (1 or 2). `reviews`: key → %{status, run (the run its thread
  # is, nil before the first), seen (the head the last look saw), reviewed, claimed,
  # elsewhere (the laptop's status where a look or a run left it to the laptop),
  # publish_error, seq (order queued), held (`{reviewed, status}` of the commit it
  # still claims since it was queued again for another head)}. `runs`: key → whether
  # each run so far launched its thread. `posts`: every post that reached GitHub,
  # `{key, reviewed}`. `laptop`: whether it is connected; `restarting`: whether its
  # plugin is restarting, so it cannot say what it has; `rows`: key → `{head, status,
  # claimed, held}` it shares, `held` the status of a claim of the other head or nil.
  # `held` (of the model): runs held at the fetch. `paused`: stopped at the agent's
  # usage limit, until the user asks for a review.
  #
  # The plugin reviews every new head of both pull requests on its own, one at a time,
  # and keeps reviews for the user to publish. Its first look finds both at head 1.
  def initial_state do
    look(%{
      prs: Map.new(@keys, &{&1, 1}),
      reviews: %{},
      runs: %{},
      posts: [],
      laptop: true,
      restarting: false,
      rows: %{},
      hold: false,
      held: [],
      paused: false,
      seq: 0,
      crashes: 0
    })
  end

  def command(m) do
    key = oneof(@keys)
    row = {oneof([1, 2]), elements(@rows), oneof([nil, nil, "published", "failed"])}

    launched = for {key, runs} <- m.runs, {true, k} <- Enum.with_index(runs, 1), do: {key, k}

    current =
      for {key, %{run: k}} when k != nil <- m.reviews, Enum.at(m.runs[key], k - 1), do: {key, k}

    running =
      for {key, %{run: k, status: :running}} <- m.reviews, {key, k} in current, do: {key, k}

    run =
      if current == [],
        do: elements(launched),
        else: frequency([{4, elements(current)}, {1, elements(launched)}])

    # Mostly a review that can be published.
    waiting = for {key, %{status: :waiting}} <- m.reviews, do: key
    published = if waiting == [], do: key, else: frequency([{3, elements(waiting)}, {1, key}])

    # The laptop claiming the commit a run here is about to claim, taking a head
    # this machine has yet to look at, publishing the commit this machine reviewed,
    # or holding any row at all.
    contested =
      for(
        {key, %{status: s}} <- m.reviews,
        s in [:queued, :running],
        do:
          {:call, __MODULE__, :peer_set,
           [
             key,
             oneof([
               {m.prs[key], {"running", true}, nil},
               {3 - m.prs[key], {"queued", false}, "running"}
             ])
           ]}
      ) ++
        for(
          {key, %{status: s, reviewed: r}} <- m.reviews,
          s not in [:queued, :running] and r != m.prs[key],
          do: {:call, __MODULE__, :peer_set, [key, {m.prs[key], elements(@rows), nil}]}
        ) ++
        for {key, %{reviewed: r}} when r != nil <- m.reviews,
            do:
              {:call, __MODULE__, :peer_set,
               [
                 key,
                 oneof([{r, {"published", true}, nil}, {3 - r, {"running", true}, "published"}])
               ]}

    # The laptop letting go of, or moving on from, a review this machine left to it.
    released =
      for {key, %{elsewhere: e, seen: seen}} when e != nil <- m.reviews,
          row <- [nil, {3 - seen, {"running", true}, nil}],
          do: {:call, __MODULE__, :peer_set, [key, row]}

    peer =
      [{3, {:call, __MODULE__, :peer_set, [key, oneof([nil, row])]}}] ++
        if(contested == [],
          do: [],
          else: [{if(waiting == [], do: 2, else: 4), elements(contested)}]
        ) ++
        if released == [], do: [], else: [{5, elements(released)}]

    # Mostly cut off once a look or a run left a review to the laptop.
    left? = released != []

    frequency(
      [
        {3, {:call, __MODULE__, :refresh, []}},
        {3, {:call, __MODULE__, :start, [key]}},
        {3, {:call, __MODULE__, :push, [key]}},
        {if(waiting == [], do: 2, else: 6), {:call, __MODULE__, :publish, [published]}},
        {2, {:call, __MODULE__, :hold, [boolean()]}},
        {if(m.restarting, do: 4, else: 1), {:call, __MODULE__, :restarting, [not m.restarting]}},
        if(m.laptop,
          do: {if(left?, do: 6, else: 1), {:call, __MODULE__, :disconnect, []}},
          else: {4, {:call, __MODULE__, :reconnect, []}}
        )
      ] ++
        peer ++
        if(launched != [], do: [{6, {:call, __MODULE__, :report, [run]}}], else: []) ++
        if(running != [],
          do: [{2, {:call, __MODULE__, :limited, [elements(running)]}}],
          else: []
        ) ++
        if(not m.hold and m.crashes < 2, do: [{1, {:call, __MODULE__, :crash, []}}], else: [])
    )
  end

  def precondition(m, {:call, _, cmd, [{key, k}]}) when cmd in [:report, :limited],
    do: Enum.at(m.runs[key] || [], k - 1) == true

  def precondition(m, {:call, _, :disconnect, []}), do: m.laptop
  def precondition(m, {:call, _, :reconnect, []}), do: not m.laptop
  def precondition(m, {:call, _, :crash, []}), do: not m.hold and m.crashes < 2
  def precondition(_m, _call), do: true

  def next_state(m, _result, call), do: m |> step(call) |> elem(0)

  def postcondition(m, call, observed) do
    {m, reply} = step(m, call)

    expected = %{
      reply: reply,
      view: view(m),
      claims: for({key, r} <- m.reviews, row = shared(m, r), into: %{}, do: {key, row}),
      threads: for({key, runs} <- m.runs, runs != [], into: %{}, do: {key, runs}),
      checkouts: checkouts(m),
      orphans: [],
      posts: m.posts,
      problems: if(m.paused, do: [@paused], else: [])
    }

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

  # `{model after call, the reply it expects}`; nil is a step with no reply to check.
  defp step(m, {:call, _, :refresh, []}), do: {look(m), :ok}

  # The user's ask ends a pause and runs whatever a look left to the laptop: only a
  # claim of the laptop's on the commit checked out keeps it from running.
  defp step(m, {:call, _, :start, [key]}) do
    m = %{m | paused: false}

    case m.reviews[key] do
      %{status: s} when s in [:queued, :running] -> {pump(m), :ok}
      _ -> {m |> queue(key) |> pump(), :ok}
    end
  end

  defp step(m, {:call, _, :push, [key]}),
    do: {%{m | prs: Map.update!(m.prs, key, &(3 - &1))}, :ok}

  defp step(m, {:call, _, :peer_set, [key, row]}) do
    rows =
      case row do
        nil -> Map.delete(m.rows, key)
        {head, {status, claimed}, held} -> Map.put(m.rows, key, {head, status, claimed, held})
      end

    m = %{m | rows: rows}
    {if(tells?(m), do: peer_claims(m), else: m), :ok}
  end

  # A plugin restarting answers that it cannot say; once back, it tells this machine.
  defp step(m, {:call, _, :restarting, [on]}) do
    m = %{m | restarting: on}
    {if(tells?(m), do: peer_claims(m), else: m), :ok}
  end

  # What a look had left to the laptop is looked at again once it is gone.
  defp step(m, {:call, _, :disconnect, []}) do
    m = %{m | laptop: false}

    if Enum.any?(m.reviews, fn {_, r} -> r.elsewhere end),
      do:
        {look(%{m | reviews: Map.new(m.reviews, fn {k, r} -> {k, %{r | elsewhere: nil}} end)}),
         :ok},
      else: {m, :ok}
  end

  defp step(m, {:call, _, :reconnect, []}), do: {%{m | laptop: true}, :ok}

  defp step(m, {:call, _, :hold, [true]}), do: {%{m | hold: true}, :ok}

  defp step(m, {:call, _, :hold, [false]}) do
    held = m.held
    m = %{m | hold: false, held: []}
    {Enum.reduce(held, m, fn {key, k}, m -> resolve(m, key, k) end), :ok}
  end

  defp step(m, {:call, _, :report, [{key, k}]}) do
    case m.reviews[key] do
      %{run: ^k, status: s} = r when s in [:running, :waiting, :failed] ->
        {m |> put_review(key, %{r | status: :waiting, publish_error: false}) |> pump(), :ok}

      _ ->
        {m, :error}
    end
  end

  # The run waits in the queue again, and nothing starts until the user asks.
  defp step(m, {:call, _, :limited, [{key, k}]}) do
    case m.reviews[key] do
      %{run: ^k, status: :running} -> {%{queue(m, key) | paused: true}, nil}
      _ -> {m, nil}
    end
  end

  defp step(m, {:call, _, :publish, [key]}) do
    case m.reviews[key] do
      %{status: :waiting, reviewed: reviewed} = r ->
        cond do
          {reviewed, "published"} in Enum.map(laptop_rows(m, key), &Tuple.delete_at(&1, 2)) ->
            {put_review(m, key, %{r | publish_error: true}), :refused}

          # The laptop cannot say whether it posted, so the post waits for it.
          m.laptop and m.restarting ->
            {put_review(m, key, %{r | publish_error: true}), :restarting}

          true ->
            m = put_review(m, key, %{r | status: :published, publish_error: false})
            {%{m | posts: m.posts ++ [{key, reviewed}]}, :ok}
        end

      _ ->
        {m, :error}
    end
  end

  # The plugin starts again from what it saved, a run it had in hand failed, and looks.
  defp step(m, {:call, _, :crash, []}) do
    reviews =
      Map.new(m.reviews, fn {key, r} ->
        {key,
         %{r | status: if(r.status == :running, do: :failed, else: r.status), elsewhere: nil}}
      end)

    {look(%{m | reviews: reviews, crashes: m.crashes + 1}), nil}
  end

  defp put_review(m, key, review), do: %{m | reviews: Map.put(m.reviews, key, review)}

  # Whether the laptop tells this machine its claims changed: it does when connected
  # and its plugin runs.
  defp tells?(m), do: m.laptop and not m.restarting

  # This machine read the laptop's claims again, told by the laptop or after a run
  # stepped back: each review this machine has not taken up at the head it saw shows
  # where the laptop has it now, and one the laptop let go of is looked at again at
  # once. A laptop restarting its plugin still has what it had.
  defp peer_claims(m) do
    changed =
      for {key, r} <- m.reviews,
          r.status not in [:queued, :running] and r.reviewed != r.seen,
          other <- [laptop_status(m, key, r.seen)],
          other != r.elsewhere,
          other != nil or not (m.laptop and m.restarting),
          into: %{},
          do: {key, %{r | elsewhere: other}}

    m = %{m | reviews: Map.merge(m.reviews, changed)}
    if Enum.any?(changed, fn {_, r} -> r.elsewhere == nil end), do: look(m), else: m
  end

  # The laptop's status of `key` at `head`, a claim over a queued one.
  defp laptop_status(m, key, head) do
    rows = for {^head, _, _} = row <- laptop_rows(m, key), do: row

    case Enum.sort_by(rows, &elem(&1, 2)) do
      [] -> nil
      rows -> rows |> List.last() |> elem(1)
    end
  end

  # The laptop's rows of `key` as this machine reads them, `{head, status, claimed}`,
  # a commit it holds behind a review queued again among them. One cut off, or
  # restarting its plugin, has none.
  defp laptop_rows(%{laptop: true, restarting: false, rows: rows}, key) do
    case rows[key] do
      nil -> []
      {head, status, claimed, nil} -> [{head, status, claimed}]
      {head, status, claimed, held} -> [{head, status, claimed}, {3 - head, held, true}]
    end
  end

  defp laptop_rows(_m, _key), do: []

  defp fresh(head) do
    %{
      status: :ready,
      run: nil,
      seen: head,
      reviewed: nil,
      claimed: false,
      elsewhere: nil,
      publish_error: false,
      seq: nil,
      held: nil
    }
  end

  # Queued for a head other than the one it reviewed, a review still holds that commit,
  # and what became of it.
  defp queue(m, key) do
    r = m.reviews[key]

    held =
      if r.claimed and r.reviewed != nil and r.reviewed != r.seen,
        do: {r.reviewed, Atom.to_string(r.status)},
        else: r.held

    review = %{
      r
      | status: :queued,
        held: held,
        seq: m.seq + 1,
        claimed: false,
        elsewhere: nil,
        publish_error: false
    }

    %{put_review(m, key, review) | seq: m.seq + 1}
  end

  # A look at both open pull requests, in the listing's order. Any row of the laptop's
  # at the head seen now leaves the review to it, unless this machine reviewed that head.
  defp look(m) do
    Enum.reduce(@keys, m, fn key, m ->
      head = m.prs[key]
      known = m.reviews[key]
      reviewed = known && known.reviewed

      other = laptop_status(m, key, head)

      seen = %{(known || fresh(head)) | seen: head, elsewhere: nil}

      cond do
        known && known.status in [:queued, :running] ->
          put_review(m, key, seen)

        other && reviewed != head ->
          put_review(m, key, %{seen | elsewhere: other})

        known && known.status == :failed && reviewed == nil && known.seen == head ->
          put_review(m, key, seen)

        reviewed == head ->
          put_review(m, key, seen)

        true ->
          m |> put_review(key, seen) |> queue(key)
      end
    end)
    |> pump()
  end

  # Starts the oldest queued review while none runs and the queue is not paused; held
  # at the fetch while the hold is on.
  defp pump(%{paused: true} = m), do: m

  defp pump(m) do
    running = Enum.any?(m.reviews, fn {_, r} -> r.status == :running end)

    queued =
      m.reviews
      |> Enum.filter(fn {_, r} -> r.status == :queued end)
      |> Enum.sort_by(fn {_, r} -> r.seq end)

    case {running, queued} do
      {false, [{key, r} | _]} ->
        runs = (m.runs[key] || []) ++ [false]

        m = %{
          put_review(m, key, %{r | status: :running, run: length(runs)})
          | runs: Map.put(m.runs, key, runs)
        }

        if m.hold,
          do: %{m | held: m.held ++ [{key, length(runs)}]},
          else: resolve(m, key, length(runs))

      _ ->
        m
    end
  end

  # Run `k` of `key` checks out the head there is now and claims it, unless the
  # connected laptop claimed that commit, or is restarting its plugin and cannot say:
  # then it steps back, the next queued starts, and it reads the laptop's claims again.
  defp resolve(m, key, k) do
    case m.reviews[key] do
      %{status: :running, run: ^k} = r ->
        head = m.prs[key]

        other =
          Enum.find_value(laptop_rows(m, key), fn
            {^head, status, true} -> status
            _ -> nil
          end) || if(m.laptop and m.restarting, do: "queued")

        case other do
          status when status != nil ->
            m
            |> put_review(key, %{r | status: :ready, claimed: false, elsewhere: status})
            |> pump()
            |> peer_claims()

          nil ->
            m = put_review(m, key, %{r | reviewed: head, claimed: true})
            %{m | runs: Map.update!(m.runs, key, &List.replace_at(&1, k - 1, true))}
        end

      _ ->
        m
    end
  end

  # What this machine shares of a review, `{head, status, claimed, held}`: the commit
  # it started on, or the head it is about to start or has queued (unless paused, when
  # what waits is left to others), with any commit it holds from before it was queued
  # again; with neither, the commit it holds.
  defp shared(m, r) do
    status = Atom.to_string(r.status)

    row =
      cond do
        r.claimed and r.reviewed != nil -> {r.reviewed, status, true}
        r.status == :running or (r.status == :queued and not m.paused) -> {r.seen, status, false}
        true -> nil
      end

    case {row, r.held} do
      {nil, nil} ->
        nil

      {nil, {sha, held}} ->
        {sha, held, true, nil}

      {{sha, status, claimed}, {other, held}} when other != sha ->
        {sha, status, claimed, {other, held, true}}

      {{sha, status, claimed}, _} ->
        {sha, status, claimed, nil}
    end
  end

  defp view(m) do
    m.reviews
    |> Enum.sort_by(fn {key, r} ->
      {Enum.find_index(@order, &(&1 == r.status)), -@numbers[key]}
    end)
    |> Enum.map(fn {key, r} ->
      run = if r.status in [:queued, :ready], do: nil, else: r.run
      {key, r.status, run, r.seen, r.reviewed, r.elsewhere, r.publish_error}
    end)
  end

  # A review's checkout stays from its run's launch until its next run starts.
  defp checkouts(m) do
    Enum.count(m.reviews, fn {key, r} -> r.run != nil and Enum.at(m.runs[key], r.run - 1) end)
  end

  # --- commands ---------------------------------------------------------------------------

  def refresh, do: observe(reply(call("refresh", %{})))

  def start(key),
    do: observe(reply(call("start", %{"repository" => "acme/api", "number" => @numbers[key]})))

  def push(key) do
    world = Process.get(:cr_world)
    head = 3 - world[key]

    git!(fx_dir(), [
      "--git-dir",
      bare(),
      "update-ref",
      "refs/pull/#{@numbers[key]}/head",
      sha(key, head)
    ])

    put_world(Map.put(world, key, head))
    observe(:ok)
  end

  def peer_set(key, row) do
    rows = :peer.call(laptop().pid, :persistent_term, :get, [:cr_peer_rows, %{}])

    rows =
      case row do
        nil ->
          Map.delete(rows, key)

        {head, {status, claimed}, held} ->
          row = %{"sha" => sha(key, head), "status" => status, "claimed" => claimed}

          held =
            held && %{"sha" => sha(key, 3 - head), "status" => held, "claimed" => true}

          Map.put(rows, key, if(held, do: Map.put(row, "held", held), else: row))
      end

    :ok = :peer.call(laptop().pid, :persistent_term, :put, [:cr_peer_rows, rows])
    tell()
    observe(:ok)
  end

  # The laptop's plugin restarting, so it answers that it cannot say what it has, and
  # back, when it tells this machine.
  def restarting(on) do
    :ok = :peer.call(laptop().pid, :persistent_term, :put, [:cr_peer_restarting, on])
    if not on, do: tell()
    observe(:ok)
  end

  # Told as a real peer's `Host.peers/4` tells it; one cut off, or whose plugin is
  # restarting, tells no one. The plugin has the message by the time the call returns.
  defp tell do
    %{pid: peer, node: node} = laptop()

    if node in Node.list() and
         not :peer.call(peer, :persistent_term, :get, [:cr_peer_restarting, false]) do
      case :peer.call(peer, :erpc, :call, [
             node(),
             HalC2.Plugins.Host,
             :peer,
             [@id, :claims_changed, []]
           ]) do
        {:ok, %{"result" => :ok}} -> :ok
        other -> problem("claims_changed answered #{inspect(other)}")
      end
    end
  end

  # Cut off: once the plugin heard, by what it publishes when it had left a review to
  # the laptop, and by the laptop's own nodedown here otherwise.
  def disconnect do
    node = laptop().node
    gone = to_string(node)
    {:ok, state} = get_state(Process.whereis(@server))
    left? = Enum.any?(state.reviews, fn {_, r} -> match?(%{"node" => ^gone}, r["elsewhere"]) end)
    true = Node.disconnect(node)

    receive do
      {:nodedown, ^node} -> :ok
    after
      10_000 -> problem("#{gone} never went down")
    end

    if left?,
      do:
        await_topic(
          &(not Enum.any?(&1["reviews"], fn r -> match?(%{"node" => ^gone}, r["elsewhere"]) end))
        )

    observe(:ok)
  end

  def reconnect do
    node = laptop().node
    true = Node.connect(node)

    receive do
      {:nodeup, ^node} -> :ok
    after
      10_000 -> problem("#{node} never came up")
    end

    :global.sync()
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

  def report({key, k}) do
    arguments = %{"verdict" => "approve", "summary" => "Looks right.", "comments" => []}

    case HalC2.Plugins.call_tool("code_review_report", arguments, tid(key, k)) do
      {:ok, _} -> observe(:ok)
      _ -> observe(:error)
    end
  end

  # The provider's usage limit ends run `k`'s turn; the limit resets long after any case.
  def limited({key, k}) do
    event = %{
      "type" => "turn.finished",
      "threadId" => tid(key, k),
      "status" => "failed",
      "errorClass" => "usage_limit",
      "error" => "Subscription quota exhausted.",
      "resetAt" => "2999-01-01T00:00:00Z"
    }

    apply(@server, :handle_event, [event, %{}])
    observe(nil)
  end

  def publish(key) do
    case call("publish", %{"key" => key}) do
      {:ok, _} ->
        observe(:ok)

      {:error, %{"message" => message}} ->
        observe(
          cond do
            message =~ "laptop already posted its review of this commit." -> :refused
            message =~ "laptop is restarting code review; try again." -> :restarting
            true -> :error
          end
        )
    end
  end

  def crash do
    pid = Process.whereis(@server)
    {:parent, sup} = Process.info(pid, :parent)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
    await_restart(sup, pid, 1_000)
    observe(nil, :restarted)
  end

  defp call(method, input),
    do: HalC2.Plugins.handle("call", %{"id" => @id, "method" => method, "input" => input})

  defp reply({:ok, _}), do: :ok
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

      :restarted when pid == before ->
        problem("code-review was not restarted")

      _ ->
        :ok
    end

    Process.put(:cr_pid, pid)
    snapshot = GenServer.call(@server, :snapshot)
    if snapshot["problem"], do: problem("code-review reports: #{snapshot["problem"]}")
    published = snapshot |> JSON.encode!() |> JSON.decode!()

    if Process.get(:cr_topic) != published,
      do: problem("the reviews topic is behind: #{inspect(Process.get(:cr_topic))}")

    # Compiled when the plugin starts, so unknown to the compiler here.
    claims =
      for {key, row} <- apply(@server, :claims, [@keys]),
          into: %{},
          do: {key, {head(row["sha"]), row["status"], row["claimed"], held(row["held"])}}

    %{
      reply: reply,
      view: Enum.map(snapshot["reviews"], &review_view/1),
      claims: claims,
      threads: threads(),
      checkouts: length(checkout_dirs()),
      orphans: orphans(),
      posts: posts(),
      problems: Process.put(:cr_problems, []) |> Enum.reverse()
    }
  end

  defp review_view(r) do
    key = r["key"]
    gone = to_string(laptop().node)

    elsewhere =
      case r["elsewhere"] do
        nil -> nil
        %{"machine" => "laptop", "node" => ^gone, "status" => status} -> status
        other -> {:unexpected, other}
      end

    {key, @statuses[r["status"]], run(key, r["threadId"]), head(r["headSha"]),
     head(r["reviewedSha"]), elsewhere, r["publishError"] != nil}
  end

  # The run a thread id is: its place among the thread ids seen for the review, in
  # every snapshot the plugin published, so a run that stepped back counts too.
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

  defp held(nil), do: nil
  defp held(row), do: {head(row["sha"]), row["status"], row["claimed"]}

  defp head(nil), do: nil
  defp head(sha), do: Map.get(fx().heads, sha, {:unknown, sha})

  # Whether each run seen launched its thread.
  defp threads do
    for {key, tids} <- Process.get(:cr_tids), into: %{}, do: {key, Enum.map(tids, &thread?/1)}
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

  # Every review posted to the fake GitHub: `{key, head}`.
  defp posts do
    fx_path("calls.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.flat_map(fn call ->
      args = Enum.join(call["args"] || [], " ")

      case Regex.run(~r{--method POST .*repos/acme/api/pulls/(\d+)/reviews}, args) do
        [_, number] -> [{"acme/api##{number}", head(JSON.decode!(call["stdin"])["commit_id"])}]
        nil -> []
      end
    end)
  end

  defp take_messages do
    receive do
      {:hal_c2_plugin_topic, _, @id, "reviews", value} ->
        topic(value)
        take_messages()

      _ ->
        take_messages()
    after
      0 -> :ok
    end
  end

  # Every snapshot published names the runs started by then.
  defp topic(value) do
    Process.put(:cr_topic, value)
    for r <- value["reviews"] || [], do: run(r["key"], r["threadId"])
  end

  # Takes what the plugin publishes until a snapshot satisfies `done?`.
  defp await_topic(done?) do
    receive do
      {:hal_c2_plugin_topic, _, @id, "reviews", value} ->
        topic(value)
        if not done?.(value), do: await_topic(done?)
    after
      10_000 -> problem("code-review never published what was awaited")
    end
  end

  defp problem(text), do: Process.put(:cr_problems, [text | Process.get(:cr_problems, [])])

  # --- settling -------------------------------------------------------------------------

  # Returns once the plugin has nothing in flight but runs held at the fetch, and has
  # heard from everything that ended.
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

  # Runs held at the fetch: the git pid of each fetch the hold keeps waiting.
  defp parked do
    if File.exists?(fx_path("fetch.hold")) do
      holds = fx_path("holds")
      Enum.count(File.ls!(holds), &(&1 =~ ~r/^\d+$/))
    else
      0
    end
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

  # --- the laptop -----------------------------------------------------------------------

  defp distribute do
    if :erlang.is_alive() do
      false
    else
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"hal_c2_prop_cr#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
      true
    end
  end

  # A bare node: no MC, only a `HalC2.Plugins.Host` whose `peer/3` answers the rows
  # in its `:cr_peer_rows`. Its control runs over standard io, so cutting the
  # distribution connection leaves it running. It stops with a process of its own,
  # as ExUnit's `setup_all` process ends before the tests run.
  defp start_laptop do
    driver = self()

    owner =
      spawn(fn ->
        {:ok, pid, node} =
          :peer.start(%{
            name: :"hal_c2_cr_laptop#{System.unique_integer([:positive])}",
            host: ~c"127.0.0.1",
            longnames: true,
            connection: :standard_io,
            args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
          })

        send(driver, {:laptop, self(), pid, node})
        receive do: (:stop -> :peer.stop(pid))
      end)

    receive do
      {:laptop, ^owner, pid, node} ->
        {:module, _} =
          :peer.call(pid, :code, :load_binary, [HalC2.Plugins.Host, ~c"laptop", host_stub()])

        %{owner: owner, pid: pid, node: node}
    after
      60_000 -> raise "the laptop never started"
    end
  end

  defp stop_laptop(%{owner: owner}) do
    ref = Process.monitor(owner)
    send(owner, :stop)
    receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
  end

  defp host_stub do
    source = """
    -module('Elixir.HalC2.Plugins.Host').
    -export([peer/3]).
    peer(<<"code-review">>, claims, [Keys]) ->
        Result = case persistent_term:get(cr_peer_restarting, false) of
            true -> restarting;
            false -> maps:with(Keys, persistent_term:get(cr_peer_rows, \#{}))
        end,
        {ok, \#{<<"machine">> => <<"laptop">>, <<"result">> => Result}};
    peer(_, _, _) ->
        none.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
          token, acc -> {:cont, [token | acc]}
        end,
        fn [] -> {:cont, []} end
      )
      |> Enum.map(fn form ->
        {:ok, parsed} = :erl_parse.parse_form(form)
        parsed
      end)

    {:ok, _, binary} = :compile.forms(forms, [:binary, :return_errors])
    binary
  end

  defp laptop, do: fx().laptop

  # --- one case ----------------------------------------------------------------------------

  defp begin_case do
    home = HalC2.Prop.scratch_home("code-review-claims")
    fx = fx_dir()
    File.write!(fx_path("calls.jsonl"), "")
    File.rm(fx_path("fetch.hold"))
    File.rm_rf!(fx_path("holds"))
    File.mkdir_p!(fx_path("holds"))
    codex_gate = Path.join(home, "codex-gate")
    File.mkdir_p!(codex_gate)
    System.put_env("FAKE_CODEX_GATE", codex_gate)

    for key <- @keys,
        do:
          git!(fx, [
            "--git-dir",
            bare(),
            "update-ref",
            "refs/pull/#{@numbers[key]}/head",
            sha(key, 1)
          ])

    root = Path.join([home, "roots", "api"])
    File.mkdir_p!(Path.dirname(root))
    git!(home, ["clone", "-q", bare(), root])
    git!(root, ["remote", "set-url", "origin", "git@github.com:acme/api.git"])

    # The laptop starts connected, with nothing of the pull requests in hand.
    %{pid: peer, node: node} = laptop()
    :ok = :peer.call(peer, :persistent_term, :put, [:cr_peer_rows, %{}])
    :ok = :peer.call(peer, :persistent_term, :put, [:cr_peer_restarting, false])
    :net_kernel.monitor_nodes(true)
    if node not in Node.list(), do: true = Node.connect(node)
    :global.sync()

    Process.put(:cr_tids, %{})
    Process.put(:cr_problems, [])
    put_world(Map.new(@keys, &{&1, 1}))

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

    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "api",
        "title" => "api",
        "workspaceRoot" => root
      })

    HalC2.Streams.flush_shell("api")
    :sys.get_state(HalC2.Shell)
    File.mkdir_p!(Path.join(HalC2.Paths.data_dir(), "plugins"))
    File.cp_r!(@package, Path.join([HalC2.Paths.data_dir(), "plugins", @id]))
    {:ok, _} = HalC2.Plugins.handle("rescan", %{})
    # Subscribed first, so every run the plugin starts is seen.
    {:ok, _} = HalC2.Plugins.subscribe_topic(self(), @id, "reviews")

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
          "repositories" => ["acme/api"],
          "activation" => "automatic",
          "publishing" => "draft",
          "concurrency" => 1,
          "reviewNewPushes" => true,
          "readReviewMd" => false
        }
      })

    HalC2.PullRequests.invalidate(%{})
    drain()
    :sys.get_state(HalC2.Plugins)
    take_messages()
    Process.put(:cr_pid, Process.whereis(@server))
  end

  defp end_case do
    File.rm(fx_path("fetch.hold"))
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

  # `world`: key → its head.
  defp put_world(world) do
    Process.put(:cr_world, world)

    details =
      for key <- @keys do
        pr =
          Map.merge(pr_entry(world, key), %{
            "body" => "",
            "changedFiles" => 1,
            "isCrossRepository" => false,
            "baseRef" => %{"compare" => %{"behindBy" => 0}},
            "labels" => %{"nodes" => []},
            "reviewRequests" => %{"nodes" => []},
            "commits" => %{"nodes" => []}
          })

        %{
          "args" => ["api graphql"],
          "stdin" => ["viewerCanUpdateBranch", ~s("name":"api"), ~s("number":#{@numbers[key]})],
          "stdout" => %{
            "data" => %{"repository" => %{"viewerPermission" => "WRITE", "pullRequest" => pr}}
          }
        }
      end

    permissions = %{
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

    rules =
      [
        %{"args" => ["api user"], "stdout" => %{"id" => 7, "login" => "monalisa"}},
        %{
          "args" => ["pr list", "--repo github.com/acme/api"],
          "stdout" => Enum.map(@keys, &pr_entry(world, &1))
        }
      ] ++
        details ++
        [permissions, %{"args" => ["--method POST", "pulls/"], "stdout" => "{}"}]

    path = fx_path("rules.json")
    File.write!(path <> ".tmp", JSON.encode!(rules))
    File.rename!(path <> ".tmp", path)
  end

  defp pr_entry(world, key) do
    number = @numbers[key]

    %{
      "number" => number,
      "title" => "Pull request #{number}",
      "url" => "https://github.com/acme/api/pull/#{number}",
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
      "headRefOid" => sha(key, world[key]),
      "additions" => 5,
      "deletions" => 0
    }
  end

  # The fake remote `acme/api`, each pull request with two head commits off `main`.
  # Returns `{key, i}` → sha.
  defp remotes(fx) do
    bare = Path.join([fx, "remotes", "acme", "api.git"])
    File.mkdir_p!(Path.dirname(bare))
    git!(fx, ["init", "-q", "--bare", "-b", "main", bare])
    seed = Path.join(fx, "seed-api")
    git!(fx, ["init", "-q", "-b", "main", seed])
    File.write!(Path.join(seed, "README.md"), "# api\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-q", "-m", "Start"])
    git!(seed, ["push", "-q", bare, "main:main"])

    for {key, number} <- @numbers, i <- 1..2, into: %{} do
      git!(seed, ["checkout", "-q", "--detach", "main"])
      File.mkdir_p!(Path.join(seed, "src"))
      File.write!(Path.join(seed, "src/limits.ts"), "export const limit = #{number}#{i};\n")
      git!(seed, ["add", "src/limits.ts"])
      git!(seed, ["commit", "-q", "-m", "#{key} at #{i}"])
      sha = git!(seed, ["rev-parse", "HEAD"])
      git!(seed, ["push", "-q", bare, "HEAD:refs/fixtures/#{number}/#{i}"])
      {{key, i}, sha}
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
        fx = :persistent_term.get({__MODULE__, :fx})
        fx = Map.put(fx, :heads, Map.new(fx.shas, fn {{_key, i}, sha} -> {sha, i} end))
        Process.put(:cr_fx, fx)
        fx

      fx ->
        fx
    end
  end

  defp fx_dir, do: fx().dir
  defp fx_path(name), do: Path.join(fx_dir(), name)
  defp sha(key, i), do: fx().shas[{key, i}]
  defp bare, do: Path.join([fx_dir(), "remotes", "acme", "api.git"])
end
