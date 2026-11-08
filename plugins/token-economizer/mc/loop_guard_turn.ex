# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/turn.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: the guard is a map kept by the plugin's process,
# not a file between hook processes; `fold/6` returns the judge job to start instead of
# starting it, and a verdict comes back through `verdict/3` instead of a result file; the
# sampled (in-line) judge and the redirect writer are not ported, since the plugin runs
# only the background judge, which writes the redirect with its verdict; and nothing
# holds a decision for a later call, since the MC hears every call as it ends.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.Turn do
  @moduledoc """
  The loop guard for one turn, one tool call at a time.

  Per call it folds the result into a `State`, checks the cumulative backstop, and asks
  the rules (gate, then the background judge, then the envelope fallback) whether the
  turn is stuck. The first stuck verdict is answered with a redirect, a later one with a
  stop verdict (which the plugin delivers as a notice, never as a stop). Once a redirect
  reaches the agent the segment's state starts afresh: the agent's fair window to recover.

    * The unit is a turn, one message to the agent's end: a person already splits work
      into short turns, and a whole thread folded as one would look stuck merely by being
      long.
    * There is no grader, so the project's envelope learns from turns that ended green:
      the agent stopped on its own, the guard did not stop it, and no verification after
      its last edit failed (`resolved_proxy/2`).
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.{Rules, ShellEdits, State}

  @judge_base_gap 5
  @judge_max_gap 20
  # A verdict that never came back (its job died) stops blocking the next one after this
  # many seconds.
  @judge_stale_s 300

  # What counts as running the project's own checks, across ecosystems. Broader than
  # `State.test_run_re/0` (the Python vocabulary the thresholds were tuned on); used only
  # for the ended-green proxy, never to change what `State` counts. A runner is often
  # named by path (`python tests/runtests.py`, `.venv/bin/pytest`).
  @verify ~r/\A(?:^|[\s;&|(])(?:(?:~?\/)?(?:[\w.\-]+\/)*python\d?(?:\.\d+)?\s+)?(?:~?\/)?(?:[\w.\-]+\/)*(?:pytest|py\.test|tox|nox|python\d?(?:\.\d+)?\s+-m\s+(?:pytest|unittest)|manage\.py\s+test|runtests(?:\.py)?|jest|vitest|mocha|ava|playwright\s+test|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test|go\s+test|cargo\s+(?:test|nextest)|(?:mvn|mvnw|\.\/mvnw)\s+(?:\S+\s+)*test|(?:gradle|gradlew|\.\/gradlew)\s+(?:\S+\s+)*test|make\s+(?:test|check)|ctest|rspec|phpunit|dotnet\s+test|swift\s+test|mix\s+test|deno\s+test|node\s+--test|bazel\s+test|(?:\.\/)?bin\/test)(?![\w.\-\/])/i

  # A command line's exit status is its last command's, so it may not be the test run's:
  # `npm test 2>&1 | tail -n 8` exits with `tail`'s status, `npm test || true` with 0.
  # For such a run the runner's own summary decides (`runner_verdict/1`). Without one, a
  # run whose status was replaced (a pipe, `||`, a report of the status) is read by its
  # output's markers; a run followed by other commands keeps the status the agent
  # reported, since their output is in the result too.
  @quoted ~r/'[^']*'|"(?:\\.|[^"\\])*"/
  @sep ~r/(&&|\|\||\|&|(?<!>)\||;|\n)/
  # A runner asked for its help, version or test list, not to run the tests.
  @not_a_run ~r/\s(?:-h|--help|--version|--collect-only|--co|--list\S*)(?!\S)/
  # What may precede the command itself: `FOO=1 timeout 60 npm test`, and a launcher that
  # runs it in the project's environment, `uv run pytest`, `npx jest`, `bundle exec rspec`,
  # `dotenv -e .env.local -- npx vitest run`, `mise exec -- mix test`.
  @prefix ~r/^\s*(?:(?:\w+=\S*|time|nice|nohup|command|env|timeout(?:\s+(?:-\S+|[A-Z]+|\d\S*))+|(?:(?:uv|poetry|pipenv|pdm|hatch|rye)\s+run|npx|bunx|(?:npm|pnpm|yarn)\s+(?:exec|dlx)|bundle\s+exec|xvfb-run)(?:\s+-\S+)*|(?:dotenv|mise\s+(?:exec|x))(?:\s+(?!--(?:\s|$))\S+)*\s+--)\s+)*/
  # What only reports on the run before it: `echo "exit=$?"`, `true`, `exit 0`.
  @report ~r/^\s*(?:echo|printf|true|:|exit)(?:\s|$)/
  @rank %{"own" => 0, "hidden" => 1, "mixed" => 2}

  # Commands whose own failure does not matter to the loop guard: they read, move about,
  # set up or report. A later command may take over the exit status from one of them
  # without hiding a failure of the work.
  @quiet_heads ~w(cat head tail less more wc sort uniq cut tr nl column ls tree pwd stat file du which type whereis grep egrep fgrep rg ag jq find echo printf true : cd pushd popd export source . set sed git)
  @git_reads ~w(show diff log status grep ls-files blame rev-parse branch)

  # A test runner's summary of its run, which holds whatever the exit status says.
  @run_failed Regex.compile!(
                Enum.join(
                  [
                    # pytest
                    "\\b[1-9]\\d* (?:failed|errors?)\\b.*\\bin \\d+(?:\\.\\d+)?s\\b",
                    # unittest, Django
                    "^FAILED \\((?:failures|errors)=",
                    # sympy's bin/test
                    "^tests finished:.*\\b[1-9]\\d* (?:failed|exceptions?)\\b",
                    # TAP (`node --test`)
                    "^# fail [1-9]",
                    # jest
                    "^Tests:.*\\b[1-9]\\d* failed\\b",
                    # vitest
                    "^\\s*Tests\\s+[1-9]\\d* failed\\b",
                    # mocha
                    "^\\s*[1-9]\\d* failing\\b",
                    # Playwright
                    "^\\s*[1-9]\\d* failed\\s*$",
                    # go
                    "^(?:--- FAIL: |FAIL\\t|FAIL$)",
                    # cargo
                    "^test result: FAILED",
                    # rspec
                    "\\b\\d+ examples?, [1-9]\\d* failures?\\b",
                    # JUnit (Maven, Gradle)
                    "Tests run: \\d+, Failures: (?:[1-9]|0, Errors: [1-9])",
                    "BUILD FAIL(?:URE|ED)"
                  ],
                  "|"
                ),
                "m"
              )
  @run_passed Regex.compile!(
                Enum.join(
                  [
                    "\\b\\d+ passed\\b.*\\bin \\d+(?:\\.\\d+)?s\\b",
                    "^OK(?: \\(.*\\))?\\s*$",
                    "^tests finished: \\d+ passed",
                    "^# fail 0\\b",
                    "^Tests:\\s+\\d+ passed",
                    "^\\s*Tests\\s+\\d+ passed",
                    "^\\s*\\d+ passing\\b",
                    # Playwright
                    "^\\s*\\d+ passed \\(\\d+(?:\\.\\d+)?(?:ms|s|m|h)\\)",
                    "^ok\\s+\\S+\\s+(?:\\d+(?:\\.\\d+)?s|\\(cached\\))",
                    "^test result: ok\\.",
                    "\\b\\d+ examples?, 0 failures\\b",
                    "BUILD SUCCESS"
                  ],
                  "|"
                ),
                "m"
              )

  @not_green "Tests are still NOT green."

  def judge_base_gap, do: @judge_base_gap
  def judge_stale_s, do: @judge_stale_s

  @doc "A fresh guard for the turn `turn_key`."
  def new(turn_key \\ "") do
    %{
      turn_key: turn_key,
      # This segment, reset after a nudge.
      st: State.new(),
      # The whole turn, never reset.
      whole: State.new(),
      cum_turns: 0,
      segment: 0,
      nudges_done: 0,
      aborted: false,
      abort_delivered: false,
      events: [],
      judge_last: -999,
      judge_gap: @judge_base_gap,
      judge_calls: 0,
      judge_tokens: 0,
      last_edit: 0,
      last_verify: 0,
      last_verify_failed: false,
      edits: 0,
      verifications: 0,
      # %{"id", "since", "segment"} of the judge job out, or nil.
      judge_pending: nil,
      # The verdict of the pending job, once it came back: {:ok, verdict | nil}.
      judge_arrived: nil,
      # A redirect the judge wrote with its verdict.
      nudge_ready: nil,
      # A redirect sent, until it is known whether it reached the agent (`redirected/2`).
      redirecting: false,
      # The redirects that reached the agent.
      redirects: 0
    }
  end

  # ---- commands and their exit status --------------------------------------------------

  # `cmd` as its commands and the separators between them (`[cmd, sep, cmd, ...]`), with
  # quoted text masked, and whether it sets `pipefail`. A command recorded as
  # `bash -lc '<script>'` (Codex) is split by its script.
  defp pieces(cmd) do
    cmd = ShellEdits.script(cmd)
    masked = Regex.replace(~r/[(){}]/, Regex.replace(@quoted, cmd, "Q"), " ")
    pieces = Regex.split(@sep, masked, include_captures: true)
    {drop_trailing(pieces), String.contains?(cmd, "pipefail")}
  end

  # A trailing `;` or newline.
  defp drop_trailing(pieces) do
    if length(pieces) > 1 and String.trim(List.last(pieces)) == "",
      do: pieces |> Enum.drop(-2) |> drop_trailing(),
      else: pieces
  end

  defp basename(path), do: path |> String.split("/") |> List.last()

  defp quiet?(stage) do
    case @prefix |> Regex.replace(String.trim(stage) <> " ", "") |> String.split() do
      [] ->
        true

      [head | rest] ->
        case basename(head) do
          "git" -> match?([sub | _] when sub in @git_reads, rest)
          # `sed -i` edits.
          "sed" -> not Enum.any?(rest, &Regex.match?(~r/^(?:-[a-zA-Z]*i|--in-place)/, &1))
          "find" -> not Enum.any?(rest, &(&1 in ~w(-delete -exec -execdir -ok)))
          head -> head in @quiet_heads
        end
    end
  end

  @doc """
  Whether `cmd`'s exit status says whether the work it ran failed: yes for one command,
  an `&&` chain or a pipe under `pipefail`, and when every command whose status a later
  one replaces only reads, moves about, sets up or reports (`grep -rn Error src | head`,
  `cd web; npx vitest run`). Not when one that does work could have failed unseen:
  `python repro.py 2>&1 | tail -20` exits with `tail`'s status. A heredoc's lines are the
  input of the command that reads them, not commands of their own.
  """
  def exit_status_covers(cmd) when is_binary(cmd) do
    if String.trim(cmd) == "" do
      false
    else
      {shell, _} = ShellEdits.split_heredocs(cmd)
      {pieces, pipefail} = pieces(shell)

      pieces
      |> Enum.drop(-1)
      |> Enum.chunk_every(2)
      |> Enum.all?(fn [stage, sep] ->
        sep == "&&" or (pipefail and sep in ["|", "|&"]) or quiet?(stage)
      end)
    end
  end

  def exit_status_covers(_), do: false

  @doc """
  What `cmd`'s exit status says of the test runs in it: nil when it runs none; "own"
  when it is theirs (a run is last, or followed only by `&&`, or piped under
  `pipefail`); "hidden" when a pipe, `||` or a mere report of the status replaced it;
  "mixed" when other commands ran after, their output in the result too.
  """
  def status_of_tests(cmd) when is_binary(cmd) do
    {pieces, pipefail} = pieces(cmd)
    stages = pieces |> Enum.with_index() |> Enum.filter(fn {_, i} -> rem(i, 2) == 0 end)

    Enum.reduce(stages, nil, fn {stage, i}, found ->
      if Regex.match?(@verify, Regex.replace(@prefix, stage, "")) and
           not Regex.match?(@not_a_run, stage) do
        status = after_run(pieces |> Enum.drop(i + 1) |> Enum.chunk_every(2), pipefail)
        if found == nil or @rank[status] > @rank[found], do: status, else: found
      else
        found
      end
    end)
  end

  def status_of_tests(_), do: nil

  defp after_run(rest, pipefail) do
    Enum.reduce_while(rest, "own", fn
      [sep | then], status ->
        then = List.first(then) || ""

        cond do
          sep == "&&" or (pipefail and sep in ["|", "|&"]) -> {:cont, status}
          sep in ["|", "|&", "||"] -> {:halt, "hidden"}
          not Regex.match?(@report, then) -> {:halt, "mixed"}
          true -> {:cont, "hidden"}
        end
    end)
  end

  @doc """
  True when a test runner's summary in `text` says its run failed, false when one says
  it passed (and none failed), nil when `text` holds no summary.
  """
  def runner_verdict(text) when is_binary(text) and text != "" do
    cond do
      Regex.match?(@run_failed, text) -> true
      Regex.match?(@run_passed, text) -> false
      true -> nil
    end
  end

  def runner_verdict(_), do: nil

  # ---- the ended-green proxy ----------------------------------------------------------

  defp track(g, name, args, result, exit_code, shell_edits) do
    canon = State.canon_tool(name)

    cond do
      # An edit that failed ("String to replace not found") changed nothing to verify.
      canon in ["edit", "create"] and exit_code not in [nil, 0] ->
        g

      canon in ["edit", "create"] ->
        %{g | last_edit: g.cum_turns, edits: g.edits + 1}

      true ->
        cmd = if canon == "bash", do: args["command"]
        verifies = status_of_tests(cmd) != nil

        g =
          if shell_edits != [],
            # `sed -i ... && pytest`: the edit comes first, so the run verifies it.
            do: %{g | last_edit: g.cum_turns - if(verifies, do: 1, else: 0), edits: g.edits + 1},
            else: g

        if verifies do
          failed =
            if exit_code != nil,
              do: exit_code != 0,
              # No status, or one another command gave (a pipe).
              else: Regex.match?(State.error_re(), result || "")

          %{
            g
            | last_verify: g.cum_turns,
              verifications: g.verifications + 1,
              last_verify_failed: failed
          }
        else
          g
        end
    end
  end

  @doc """
  Whether this turn ended green, the stand-in for the grader the envelope cannot have:
  green unless a verification after the last edit failed.
  """
  def resolved_proxy(g, stopped_normally \\ true) do
    stopped_normally and not g.aborted and g.cum_turns != 0 and
      not (g.last_verify_failed and g.last_verify > g.last_edit)
  end

  # ---- what the judge is told -----------------------------------------------------------

  @doc """
  How the turn's last verification went. The digest says "#{@not_green}" whenever it has
  an envelope; here the guard knows, so the judge, and the redirect it writes, is told.
  """
  def verification_state(%{verifications: 0}),
    do: "No test or verification run has been seen in this turn."

  def verification_state(g) do
    state = if g.last_verify_failed, do: "failed", else: "passed"
    since = if g.last_edit > g.last_verify, do: " There have been edits since.", else: ""
    "The last verification run #{state}.#{since}"
  end

  def live_digest(g, digest), do: String.replace(digest || "", @not_green, verification_state(g))

  # ---- the background judge ---------------------------------------------------------------

  defp backoff(g, %{"stuck" => false}),
    do: %{g | judge_gap: min(@judge_max_gap, g.judge_gap + @judge_base_gap)}

  defp backoff(g, _), do: %{g | judge_gap: @judge_base_gap}

  @doc """
  A verdict came back for job `job_id`: kept for the next call if it is the job this
  guard is waiting on, else dropped (a verdict on an old segment is about the old one).
  What the job spent is counted either way.
  """
  def verdict(g, job_id, verdict) do
    g = %{g | judge_tokens: g.judge_tokens + tokens(verdict)}

    case g.judge_pending do
      %{"id" => ^job_id} -> %{g | judge_arrived: {:ok, verdict}}
      _ -> g
    end
  end

  defp tokens(%{"_tokens" => n}) when is_number(n), do: n
  defp tokens(_), do: 0

  # The judge in the background: a verdict is taken whenever one has come back, a new job
  # starts under the rate limit, and while one is out the judge answers nothing, which
  # the rules read as throttled, the same as a call the rate limit skipped.
  defp ask_judge(g, digest, now) do
    case g.judge_arrived do
      {:ok, v} ->
        g = %{g | judge_pending: nil, judge_arrived: nil}
        g = if is_map(v), do: %{g | nudge_ready: ready(v["_nudge"])}, else: g
        {backoff(g, v), if(is_map(v) and v != %{}, do: v), nil}

      nil ->
        pending = g.judge_pending

        cond do
          pending != nil and now - pending["since"] < @judge_stale_s ->
            {g, nil, nil}

          # A pending job past `@judge_stale_s` never answered: it stops blocking.
          g.st.turns - g.judge_last < g.judge_gap ->
            {%{g | judge_pending: nil}, nil, nil}

          true ->
            calls = g.judge_calls + 1
            id = "#{g.turn_key}:#{g.segment}:#{calls}"
            job = %{"id" => id, "digest" => live_digest(g, digest), "segment" => g.segment}

            {%{
               g
               | judge_last: g.st.turns,
                 judge_calls: calls,
                 judge_pending: %{"id" => id, "since" => now, "segment" => g.segment}
             }, nil, job}
        end
    end
  end

  defp ready(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp ready(_), do: nil

  # ---- one completed tool call ------------------------------------------------------------

  @doc """
  Folds one completed call: `{guard, decision, job}`, where `decision` is nil,
  `{:nudge, reason}` or `{:abort, reason}`, and `job` is nil or a judge job to start,
  `%{"id", "digest", "segment"}`, whose verdict goes back through `verdict/3`.

  `opts`: `envelope` (nil before the project has one), `thr`, `judge` (whether a judge
  is wired), `nudge_budget` (1) and `now` (seconds, for a judge job gone stale).
  """
  def fold(g, name, args, result, exit_code, opts \\ []) do
    envelope = opts[:envelope]
    thr = opts[:thr] || Rules.defaults()
    budget = Keyword.get(opts, :nudge_budget, 1)
    args = if is_map(args), do: args, else: %{}
    result = if is_binary(result), do: result, else: ""
    cmd = if State.canon_tool(name) == "bash", do: args["command"]

    shell_edits =
      case ShellEdits.targets(cmd) do
        [] ->
          []

        # A file put back with `git checkout --` or `git restore` is an edit only when
        # this turn edited it: putting back what a dev server keeps regenerating is not
        # churn.
        edits ->
          reverted = ShellEdits.revert_targets(cmd)
          Enum.filter(edits, &(&1 not in reverted or Map.get(g.whole.edit_counts, &1, 0) > 0))
      end

    status = status_of_tests(cmd)

    exit_code =
      if status in ["hidden", "mixed"] do
        case runner_verdict(result) do
          nil -> if status == "hidden", do: nil, else: exit_code
          verdict -> if verdict, do: 1, else: 0
        end
      else
        exit_code
      end

    failed = if exit_code == nil, do: nil, else: exit_code != 0
    st = State.update(g.st, name, args, result, failed)
    whole = State.update(g.whole, name, args, result, failed)

    # `State` counts the Python runners its thresholds were tuned on; the turn's other
    # test runs (`npx vitest`, `go test`) are verifications too, in what the redirect and
    # the judge are told. No rule the guard decides by reads this count.
    {st, whole} =
      if status != nil and not Regex.match?(State.test_run_re(), cmd),
        do: {%{st | test_runs: st.test_runs + 1}, %{whole | test_runs: whole.test_runs + 1}},
        else: {st, whole}

    g = %{
      g
      | st: State.fold_shell_edits(st, shell_edits),
        whole: State.fold_shell_edits(whole, shell_edits),
        cum_turns: g.cum_turns + 1
    }

    g = track(g, name, args, result, exit_code, shell_edits)

    # While a redirect is on its way the calls are the ones the agent made before it, so
    # nothing is decided on them.
    if g.aborted or g.redirecting,
      do: {g, nil, nil},
      else: decide(g, envelope, thr, budget, opts)
  end

  defp decide(g, envelope, thr, budget, opts) do
    backstop =
      case {thr["backstop_turns"], envelope} do
        {nil, nil} -> nil
        {nil, env} -> env * thr["backstop_mult"]
        {turns, _} -> turns
      end

    if backstop != nil and g.cum_turns >= backstop and Rules.stuck?(g.st, thr) do
      # The ladder is nudge, then stop. A project's envelope is a few calls, so its
      # backstop falls inside the stuck rule's floor: the moment a turn first counts as
      # stuck the backstop has tripped too, and would pre-empt every nudge. An unspent
      # nudge goes first; after it, a fresh segment must be stuck again before the
      # backstop stops it.
      reason = "cum-backstop:#{g.cum_turns}>=#{Rules.fixed(backstop, 0)}t"
      action = if g.nudges_done < budget, do: :nudge, else: :abort
      {g, decision} = stop(g, action, reason, envelope)
      {g, decision, nil}
    else
      {g, {abort, reason}, job} = assess(g, envelope, thr, opts)

      cond do
        abort ->
          {g, decision} =
            stop(g, if(g.nudges_done < budget, do: :nudge, else: :abort), reason, envelope)

          {g, decision, job}

        thr["nudge_on_ambiguous"] && reason == "judge-ambiguous-spared" && g.nudges_done < budget ->
          {g, decision} = stop(g, :nudge, "ambiguous-past-envelope", envelope)
          {g, decision, job}

        true ->
          {g, nil, job}
      end
    end
  end

  # `Rules.assess_abort/4` with the background judge, which changes the guard.
  defp assess(g, envelope, thr, opts) do
    cond do
      abort = Rules.backstop(g.st, envelope, thr) ->
        {g, abort, nil}

      !opts[:judge] ->
        {g, Rules.assess_abort(g.st, envelope, nil, thr), nil}

      not Rules.judge_gate_open?(g.st, envelope, thr) ->
        {g, {false, "gate-closed"}, nil}

      true ->
        digest = State.recent_digest(g.st, 24, envelope)
        {g, verdict, job} = ask_judge(g, digest, opts[:now] || 0)

        # A judge that could not answer (no textGeneration, the model down) is no judge:
        # read as unsure, it would let the aggressive level redirect a healthy turn.
        if is_map(verdict) and verdict["_failed"] == true,
          do: {g, Rules.assess_abort(g.st, envelope, nil, thr), job},
          else: {g, Rules.read_verdict(verdict, thr), job}
    end
  end

  defp stop(g, action, reason, envelope) do
    event = %{
      "segment" => g.segment,
      "action" => Atom.to_string(action),
      "turn_in_segment" => g.st.turns,
      "cum_turns" => g.cum_turns,
      "envelope" => envelope,
      "reason" => reason,
      "snapshot" => State.snapshot(g.st)
    }

    g = %{g | events: Enum.take(g.events ++ [event], -20)}
    g = if action == :abort, do: %{g | aborted: true}, else: g
    {g, {action, reason}}
  end

  @doc """
  The redirect: the one the judge wrote with its verdict, else the count template
  (`Rules.nudge_text/1`), which mirrors only the agent's own actions. `{text, guard}`.
  """
  def nudge_body(%{nudge_ready: text} = g) when is_binary(text),
    do: {text, %{g | nudge_ready: nil}}

  def nudge_body(g), do: {Rules.nudge_text(g.st), g}

  @doc """
  A redirect was sent: it spends the budget, and the guard decides nothing until
  `redirected/2` says whether it reached the agent.
  """
  def redirect(g), do: %{g | nudges_done: g.nudges_done + 1, redirecting: true}

  @doc """
  Whether the redirect sent reached the agent. One that did starts the segment after it
  with a fresh state: the agent's fair window to recover, which the calls made before it
  are not part of. A verdict on the old segment is about the old one. One that did not
  (the provider cannot take a message while it works) leaves the segment as it was, and
  the next stuck call is offered a stop.
  """
  def redirected(g, true) do
    %{
      g
      | redirecting: false,
        redirects: g.redirects + 1,
        segment: g.segment + 1,
        st: State.new(),
        judge_last: -999,
        judge_gap: @judge_base_gap,
        judge_pending: nil,
        judge_arrived: nil,
        nudge_ready: nil
    }
  end

  def redirected(g, false), do: %{g | redirecting: false}

  @doc "A redirect sent and taken at once, as watching decides."
  def after_nudge(g), do: g |> redirect() |> redirected(true)

  def summary(g, stopped_normally \\ true) do
    %{
      "turnKey" => g.turn_key,
      "toolCalls" => g.cum_turns,
      "nudges" => g.nudges_done,
      "aborted" => g.aborted,
      "resolvedProxy" => resolved_proxy(g, stopped_normally),
      "edits" => g.edits,
      "verifications" => g.verifications,
      "judgeTokens" => g.judge_tokens
    }
  end
end
