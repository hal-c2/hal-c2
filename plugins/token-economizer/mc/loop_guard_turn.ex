# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/turn.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: the guard is a map kept by the plugin's process,
# not a file between hook processes; `fold/6` returns the judge job to start instead of
# starting it, and a verdict comes back through `verdict/3` instead of a result file; the
# sampled (in-line) judge and the redirect writer are not ported, since the plugin runs
# only the background judge, which writes the redirect with its verdict; nothing holds a
# decision for a later call, since the MC hears every call as it ends; `mix features`,
# `mix prop` and `mix proof` are test runs too; and nothing is decided while the turn's
# checks pass after its last edit.

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
      the agent stopped on its own, the guard did not stop it, no verification after
      its last edit failed, and no command after that edit may have hidden a check
      (`resolved_proxy/2`).
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
  # A package manager's own options before its check say which package's it runs (`pnpm
  # --filter web test`, `npm --prefix web test`, `yarn workspace web test`).
  @verify ~r/\A(?:^|[\s;&|(])(?:(?:~?\/)?(?:[\w.\-]+\/)*python\d?(?:\.\d+)?\s+)?(?:~?\/)?(?:[\w.\-]+\/)*(?:pytest|py\.test|tox|nox|python\d?(?:\.\d+)?\s+-m\s+(?:pytest|unittest)|manage\.py\s+test|runtests(?:\.py)?|jest|vitest|mocha|ava|playwright\s+test|(?:npm|pnpm|yarn|bun|vp)(?:\s+(?:(?:--(?:filter|prefix|dir|workspace|cwd)|-[FCw])(?:=\S+|\s+(?!-)\S+)|-r|--recursive|--workspaces|-ws|--if-present|-s|--silent|workspace\s+\S+))*\s+(?:run\s+)?test|go\s+test|cargo\s+(?:test|nextest)|(?:mvn|mvnw|\.\/mvnw)\s+(?:\S+\s+)*test|(?:gradle|gradlew|\.\/gradlew)\s+(?:\S+\s+)*test|make\s+(?:test|check)|ctest|rspec|phpunit|dotnet\s+test|swift\s+test|mix\s+(?:test|features|prop|proof)|deno\s+test|node\s+--test|bazel\s+test|(?:\.\/)?bin\/test)(?![\w.\-\/])/i

  # A command line's exit status is its last command's, so it may not be the test run's:
  # `npm test 2>&1 | tail -n 8` exits with `tail`'s status, `npm test || true` with 0.
  # For such a run the runner's own summary decides (`runner_verdict/1`). Without one, a
  # run whose status was replaced (a pipe, `||`, a report of the status) is read by its
  # output's markers; a run followed by other commands keeps the status the agent
  # reported, since their output is in the result too.
  @quoted ~r/'[^']*'|"(?:\\.|[^"\\])*"/
  @sep ~r/(&&|\|\||\|&|(?<!>)\||;|\n)/
  # A package manager's check behind an option `@verify` does not know (`npm --dry-run
  # test`), which may change what runs or whether anything does: a check, not read.
  @opaque_run ~r/\A(?:^|[\s;&|(])(?:~?\/)?(?:[\w.\-]+\/)*(?:npm|pnpm|yarn|bun|vp)\s+(?:\S+\s+)*(?:run\s+)?test(?![\w.\-\/])/i
  # A runner asked for its help, version or test list, not to run the tests.
  @not_a_run ~r/\s(?:-h|--help|--version|--collect-only|--co|--list\S*)(?!\S)/
  # What may precede the command itself: `FOO=1 timeout 60 npm test`, and a launcher that
  # runs it in the project's environment, `uv run pytest`, `npx jest`, `bundle exec rspec`,
  # `dotenv -e .env.local -- npx vitest run`, `mise exec -- mix test`. A negation or a
  # keyword (`! pytest`, `if pytest; then`) leaves a run a run, whose status
  # `ShellEdits.plain?/1` then calls unknown.
  @prefix ~r/^\s*(?:(?:\w+=\S*|!|if|elif|while|until|then|else|do|time|nice|nohup|command|env|timeout(?:\s+(?:-\S+|[A-Z]+|\d\S*))+|(?:(?:uv|poetry|pipenv|pdm|hatch|rye)\s+run|npx|bunx|(?:npm|pnpm|yarn)\s+(?:exec|dlx)|bundle\s+exec|xvfb-run)(?:\s+-\S+)*|(?:dotenv|mise\s+(?:exec|x))(?:\s+(?!--(?:\s|$))\S+)*\s+--)\s+)*/
  # What only reports on the run before it: `echo "exit=$?"`, `true`, `exit 0`.
  @pipefail_on ~r/^set\s(?:.*\s)?-[a-zA-Z]*o\s+pipefail\b/
  @pipefail_off ~r/^set\s(?:.*\s)?\+[a-zA-Z]*o\s+pipefail\b/
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
      # Whether an edit was tried after the last check ran: one that failed to apply too,
      # and one later in the check's own command (`pytest && sed -i ...`).
      unchecked: false,
      # The last call that ran a command that may hide a check (`ShellEdits.hides_check?/2`):
      # 0 for none.
      unread: 0,
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
      # Whether one did not: the agent cannot take one now, so none is sent again.
      refused: false,
      # The redirects that reached the agent.
      redirects: 0,
      # The thread's last place when the last redirect reached the agent
      # (`redirected/3`): a call that started there or before is the old segment's. Nil
      # when no redirect named one.
      since: nil
    }
  end

  # ---- commands and their exit status --------------------------------------------------

  # `cmd` as its commands and the separators between them (`[cmd, sep, cmd, ...]`), with
  # quoted text masked, and whether `pipefail` is on as each command runs. A command
  # recorded as `bash -lc '<script>'` (Codex) is split by its script, and a heredoc's
  # lines are the input of the command that reads them, not commands of their own.
  defp pieces(cmd) do
    {cmd, _} = cmd |> ShellEdits.script() |> ShellEdits.split_heredocs()
    masked = Regex.replace(~r/[(){}]/, Regex.replace(@quoted, cmd, "Q"), " ")
    pieces = masked |> then(&Regex.split(@sep, &1, include_captures: true)) |> drop_trailing()
    {pieces, pipefail(pieces)}
  end

  # `set -o pipefail` (or `-eo`, `-euo`) turns it on for the commands after it, and
  # `set +o pipefail` off again.
  defp pipefail(pieces) do
    pieces
    |> Enum.take_every(2)
    |> Enum.map_reduce(false, fn stage, on ->
      stage = String.trim(stage)

      cond do
        Regex.match?(@pipefail_on, stage) -> {on, true}
        Regex.match?(@pipefail_off, stage) -> {on, false}
        true -> {on, on}
      end
    end)
    |> elem(0)
  end

  # Each separator, `{before, sep, after, pipefail}`: the commands either side of it and
  # whether `pipefail` was on as they ran.
  defp after_each(pieces, pipefail) do
    stages = Enum.take_every(pieces, 2)
    seps = pieces |> Enum.drop(1) |> Enum.take_every(2)
    Enum.zip([stages, seps, Enum.drop(stages, 1), pipefail])
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
  `python repro.py 2>&1 | tail -20` exits with `tail`'s status. Nor when the command is
  not plain (`ShellEdits.plain?/1`): `! pytest` succeeds when the tests fail. A heredoc's
  lines are the input of the command that reads them, not commands of their own.
  """
  def exit_status_covers(cmd) when is_binary(cmd) do
    if String.trim(cmd) == "" or not ShellEdits.plain?(cmd) do
      false
    else
      {pieces, pipefail} = pieces(cmd)

      pieces
      |> after_each(pipefail)
      |> Enum.all?(fn {stage, sep, _, pipefail} ->
        sep == "&&" or (pipefail and sep in ["|", "|&"]) or quiet?(stage)
      end)
    end
  end

  def exit_status_covers(_), do: false

  @doc """
  What `cmd`'s exit status says of the test runs in it: nil when it runs none; "own"
  when it is theirs (a run is last, or followed only by `&&`, or piped under
  `pipefail`); "hidden" when a pipe, `||` or a mere report of the status replaced it;
  "mixed" when other commands ran after, their output in the result too; "unknown" when
  the command is not plain (`ShellEdits.plain?/1`: `! pytest`, `(pytest)`, `(set -o
  pipefail); pytest | tail`), whose status this does not scope, or runs a package
  manager's check behind an option this does not know (`npm --dry-run test`).
  """
  def status_of_tests(cmd) when is_binary(cmd) do
    {pieces, pipefail} = pieces(cmd)
    stages = pieces |> Enum.with_index() |> Enum.filter(fn {_, i} -> rem(i, 2) == 0 end)

    status =
      Enum.reduce(stages, nil, fn {stage, i}, found ->
        if run?(stage) do
          rest = pieces |> after_each(pipefail) |> Enum.drop(div(i, 2))
          status = after_run(rest)
          if found == nil or @rank[status] > @rank[found], do: status, else: found
        else
          found
        end
      end)

    cond do
      Enum.any?(stages, fn {stage, _} -> opaque_run?(stage) end) -> "unknown"
      status != nil and not ShellEdits.plain?(cmd) -> "unknown"
      true -> status
    end
  end

  def status_of_tests(_), do: nil

  defp opaque_run?(stage) do
    stage = Regex.replace(@prefix, stage, "")
    Regex.match?(@opaque_run, stage) and not Regex.match?(@verify, stage)
  end

  defp run?(stage),
    do:
      Regex.match?(@verify, Regex.replace(@prefix, stage, "")) and
        not Regex.match?(@not_a_run, stage)

  # Whether `cmd` writes one of `edits` after its last test run (`pytest && sed -i ... a.py`),
  # which that run then did not check. Quotes are masked to their own length, so a command's
  # place in the mask is its place in the script.
  defp writes_after_run?(cmd, edits) do
    {script, _} = cmd |> ShellEdits.script() |> ShellEdits.split_heredocs()
    masked = Regex.replace(@quoted, script, &String.duplicate("Q", byte_size(&1)))
    masked = Regex.replace(~r/[(){}]/, masked, " ")
    cuts = for [{at, len} | _] <- Regex.scan(@sep, masked, return: :index), do: {at, at + len}
    starts = [0 | Enum.map(cuts, &elem(&1, 1))]
    ends = Enum.map(cuts, &elem(&1, 0)) ++ [byte_size(masked)]

    case Enum.zip(starts, ends)
         |> Enum.filter(fn {from, to} -> run?(binary_part(masked, from, to - from)) end)
         |> List.last() do
      nil ->
        false

      {_, to} ->
        tail = binary_part(script, to, byte_size(script) - to)
        Enum.any?(ShellEdits.targets(tail), &(&1 in edits))
    end
  end

  # Whether `cmd`, one `&&` chain that exited 0, ran its last check after every command in
  # it that may hide one (`bash scripts/check.sh && pytest -q`): each of those exited 0,
  # and the check after them is the last word. A hiding command after the check (`pytest
  # -q && bash scripts/check.sh`) may have changed the tree, or run a check of its own that
  # failed unread, so its pass is not taken, deliberately: a redirect there is the cost of
  # not reading the script. A comment or an escape could hide where the chain ends, so
  # neither is read as one. Every command before the check must also have run apart from
  # it (`apart?/3`), or it may have changed the check in the chain's own shell.
  defp checked_last?(cmd, "own", 0, written) do
    {script, _} = cmd |> ShellEdits.script() |> ShellEdits.split_heredocs()
    script = String.trim_trailing(script)
    unquoted = Regex.replace(@quoted, script, &String.duplicate("Q", byte_size(&1)))
    masked = Regex.replace(~r/[(){}]/, unquoted, " ")
    cuts = for [{at, len} | _] <- Regex.scan(@sep, masked, return: :index), do: {at, at + len}
    starts = [0 | Enum.map(cuts, &elem(&1, 1))]
    ends = Enum.map(cuts, &elem(&1, 0)) ++ [byte_size(masked)]

    last_run =
      Enum.zip(starts, ends)
      |> Enum.filter(fn {from, to} -> run?(binary_part(masked, from, to - from)) end)
      |> List.last()

    chain? =
      not String.contains?(masked, ["#", "\\"]) and
        Enum.all?(cuts, fn {from, to} -> binary_part(masked, from, to - from) == "&&" end)

    case last_run do
      {from, _} when chain? ->
        before = Enum.take_while(Enum.zip(starts, ends), fn {at, _} -> at < from end)

        ShellEdits.plain?(cmd) and
          Enum.all?(before, fn {at, to} ->
            apart?(binary_part(unquoted, at, to - at), binary_part(script, at, to - at), written)
          end) and
          not ShellEdits.hides_check?(
            binary_part(script, from, byte_size(script) - from),
            written
          )

      _ ->
        false
    end
  end

  defp checked_last?(_, _, _, _), do: false

  # Whether one command of a chain ran apart from the check after it, so all it could do
  # to the check is exit nonzero, which the chain's `&&` would have shown: a simple command
  # (no group or subshell bracket, no `[[`) whose name is a program, or one of the
  # builtins below that cannot change what a later command runs, or a `source`/`.` of a
  # plain path the turn did not write (`. venv/bin/activate`). Anything else (a keyword,
  # `eval`, a function definition, `alias`, `export PATH=...`, a bare assignment) may
  # change the check in the chain's own shell, so the chain is not read. `masked` is the
  # segment with its quotes masked, so a bracket in a quoted word is no bracket.
  @apart_builtins ~w(cd pushd popd echo printf true false : test [ pwd)
  # Bash's builtins and keywords: a name among them is not a program run apart.
  @shell_builtins ~w(
    . : [ alias bg bind break builtin caller cd command compgen complete compopt continue
    declare dirs disown echo enable eval exec exit export false fc fg getopts hash help
    history jobs kill let local logout mapfile popd printf pushd pwd read readarray readonly
    return set shift shopt source suspend test times trap type typeset ulimit umask unalias
    unset wait ! [[ ]] case coproc do done elif else esac fi for function if in select then
    time until while { }
  )

  defp apart?(masked, segment, written) do
    words =
      segment
      |> String.split()
      |> Enum.drop_while(&Regex.match?(~r/^\w+=\S*$/, &1))

    not String.contains?(masked, ["(", ")", "{", "}", "[["]) and
      case words do
        [dot, file] when dot in ["source", "."] ->
          Regex.match?(~r{^[\w./-]+$}, file) and Path.basename(file) not in written

        [name | _] ->
          name in @apart_builtins or
            (name not in @shell_builtins and Regex.match?(~r{^[\w./@+-]+$}, name))

        [] ->
          false
      end
  end

  defp after_run(rest) do
    Enum.reduce_while(rest, "own", fn
      {_, sep, then, pipefail}, status ->
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
      # An edit that failed ("String to replace not found") changed nothing to verify, but
      # a turn that tries edits after its checks passed is not done with them.
      canon in ["edit", "create"] and exit_code not in [nil, 0] ->
        %{g | unchecked: true}

      canon in ["edit", "create"] ->
        %{g | last_edit: g.cum_turns, edits: g.edits + 1, unchecked: true}

      true ->
        cmd = if canon == "bash", do: args["command"]
        status = status_of_tests(cmd)
        # A check whose status this does not scope verifies nothing, and may have failed.
        verifies = status not in [nil, "unknown"]

        written = Map.keys(g.whole.edit_counts)

        g =
          if canon == "bash" and
               (status == "unknown" or ShellEdits.hides_check?(cmd, written)) and
               not checked_last?(cmd, status, exit_code, written),
             do: %{g | unread: g.cum_turns},
             else: g

        g =
          cond do
            shell_edits == [] ->
              g

            # `sed -i 's/x/y/' missing.py` failed and, as a failed edit tool's does, changed
            # nothing to verify. A failed run after a write is the run's failure.
            exit_code not in [nil, 0] and not verifies ->
              %{g | unchecked: true}

            # `sed -i ... && pytest`: the edit comes first, so the run verifies it.
            true ->
              %{
                g
                | last_edit: g.cum_turns - if(verifies, do: 1, else: 0),
                  edits: g.edits + 1,
                  unchecked: true
              }
          end

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
              last_verify_failed: failed,
              # The proxy takes every write in a command that runs checks as checked, as
              # upstream's does; whether the run passed on the last edit keeps the order.
              unchecked: shell_edits != [] and writes_after_run?(cmd, shell_edits)
          }
        else
          g
        end
    end
  end

  @doc """
  Whether this turn ended green, the stand-in for the grader the envelope cannot have:
  green unless a verification after the last edit failed, or a command after it may have
  hidden a check (`ShellEdits.hides_check?/2`: a nested shell's script, inline code, a
  capped or garbled command, a heredoc not placed), one that may have failed unheard.
  """
  def resolved_proxy(g, stopped_normally \\ true) do
    stopped_normally and not g.aborted and g.cum_turns != 0 and
      not (g.last_verify_failed and g.last_verify > g.last_edit) and
      not (g.unread > 0 and g.unread >= g.last_edit)
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
  defp ask_judge(g, digest, now, budget) do
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
            # Past the budget a stuck verdict is offered as a stop, which needs no redirect.
            job = %{
              "id" => id,
              "digest" => live_digest(g, digest),
              "segment" => g.segment,
              "redirect" => redirect_left?(g, budget)
            }

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
  `%{"id", "digest", "segment", "redirect"}` (`redirect`: whether a stuck verdict could
  still be answered with a redirect, so one is worth writing), whose verdict goes back
  through `verdict/3`.

  `opts`: `envelope` (nil before the project has one), `thr`, `judge` (whether a judge
  is wired), `nudge_budget` (1), `now` (seconds, for a judge job gone stale) and
  `started`, the call's place in the thread, given as it started. A call heard after a
  redirect reached the agent that did not start after it (`since`), or whose place is
  not known then, may have been under way before the agent was sent it: it counts for
  the turn, but not for the segment after the redirect, and decides nothing.
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
      if status in ["hidden", "mixed", "unknown"] do
        case runner_verdict(result) do
          nil -> if status in ["hidden", "unknown"], do: nil, else: exit_code
          verdict -> if verdict, do: 1, else: 0
        end
      else
        exit_code
      end

    failed = if exit_code == nil, do: nil, else: exit_code != 0
    early = g.since != nil and not (is_integer(opts[:started]) and opts[:started] > g.since)
    st = if early, do: g.st, else: State.update(g.st, name, args, result, failed)
    whole = State.update(g.whole, name, args, result, failed)

    # `State` counts the Python runners its thresholds were tuned on; the turn's other
    # test runs (`npx vitest`, `go test`) are verifications too, in what the redirect and
    # the judge are told. No rule the guard decides by reads this count.
    {st, whole} =
      cond do
        status == nil or Regex.match?(State.test_run_re(), cmd) -> {st, whole}
        early -> {st, %{whole | test_runs: whole.test_runs + 1}}
        true -> {%{st | test_runs: st.test_runs + 1}, %{whole | test_runs: whole.test_runs + 1}}
      end

    g = %{
      g
      | st: if(early, do: st, else: State.fold_shell_edits(st, shell_edits)),
        whole: State.fold_shell_edits(whole, shell_edits),
        cum_turns: g.cum_turns + 1
    }

    g = track(g, name, args, result, exit_code, shell_edits)

    # While a redirect is on its way the calls are the ones the agent made before it, so
    # nothing is decided on them, nor on one heard after it that may have started before
    # it. While the turn's checks pass after its last edit, it is not stuck however it got
    # there: the errors and repeated edits it counts are the work those checks just
    # verified (a passing run after six failing ones at the backstop).
    if g.aborted or g.redirecting or early or verified?(g),
      do: {g, nil, nil},
      else: decide(g, envelope, thr, budget, opts)
  end

  # Whether a stuck call is answered with a redirect rather than a stop offer: one is
  # left in the budget, and none was refused.
  defp redirect_left?(g, budget), do: g.nudges_done < budget and not g.refused

  # Whether the turn's last check passed and nothing since may have undone it: an edit, or
  # a command that may have hidden a check (a capped one, a nested shell's) that failed.
  defp verified?(g) do
    g.verifications > 0 and not g.last_verify_failed and not g.unchecked and
      not (g.unread > 0 and g.unread >= g.last_verify)
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
      action = if redirect_left?(g, budget), do: :nudge, else: :abort
      {g, decision} = stop(g, action, reason, envelope)
      {g, decision, nil}
    else
      {g, {abort, reason}, job} = assess(g, envelope, thr, opts)

      cond do
        abort ->
          {g, decision} =
            stop(g, if(redirect_left?(g, budget), do: :nudge, else: :abort), reason, envelope)

          {g, decision, job}

        thr["nudge_on_ambiguous"] && reason == "judge-ambiguous-spared" &&
            redirect_left?(g, budget) ->
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
        budget = Keyword.get(opts, :nudge_budget, 1)
        {g, verdict, job} = ask_judge(g, digest, opts[:now] || 0, budget)

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
  are not part of. `since` is the thread's last place when it did (`Host.steer/4`'s
  receipt): a call heard later that started there or before, still under way when the
  agent was sent it, stays out of the new segment (`fold/6`). A verdict on the old
  segment is about the old one. One that did not (the provider cannot take a message
  while it works) leaves the segment as it was, and the next stuck call is offered a
  stop, whatever redirects the budget has left.
  """
  def redirected(g, landed, since \\ nil)

  def redirected(g, true, since) do
    %{
      g
      | redirecting: false,
        since: since,
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

  def redirected(g, false, _since), do: %{g | redirecting: false, refused: true}

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
