# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/state.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: the state is a map; `completed_calls` and
# `state_from_trajectory` are not ported (the MC hears calls already paired), nor is
# `edit_order`, which nothing reads.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.State do
  @moduledoc """
  What the loop guard reads off a turn: a per-call fold of its failure-loop signals.

  The state is updated once per completed tool call (`update/5`) and keeps only counts
  and a short, leakage-safe action log: edits per file, error outputs, verification
  runs, and how often a failure repeats one seen before (`stagnation/1`, the signal
  that separates a loop from a hard but productive grind).
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.ShellEdits

  # An output that ran code to verify behaviour (the test step of the edit-test loop).
  @test_run ~r/(runtests(\.py)?|\bpytest\b|py\.test|manage\.py\s+test|python\s+-m\s+unittest|\btox\b|\bnox\b|\btrial\b|python\d?\s+-c\b)/i
  # Other ecosystems' failing-test summaries, which name no error: TAP (`node --test`)
  # `# fail 2` and `not ok 3`, mocha's and rspec's counts, JUnit's, and Go's
  # `--- FAIL: T` and `FAIL<tab>pkg` (not unittest's `FAIL: test_x`, which would change
  # the line a Python failure is known by, and so which failures count as repeats).
  @error ~r/(Traceback \(most recent call last\)|\b\w*Error\b|\bFAILED\b|\bassert\b|Exception|errors during collection|^# fail [1-9]|^not ok \d|\b[1-9]\d* (?:failing|failures?)\b|Failures: [1-9]|^(?-i:--- FAIL: |FAIL\t|FAIL$))/im
  @edit_tools ~w(edit str_replace create)
  # Tools whose output is the content of files, not the outcome of running anything: a
  # test file full of `assert` read back is not a failure, nor is reading it twice a
  # repeated one.
  @content_tools ~w(view grep glob)
  # Agents' tool names, normalised to the names the fold keys on. Unknown names pass
  # through unchanged.
  @canon %{
    "bash" => "bash",
    "shell" => "bash",
    "read" => "view",
    "view" => "view",
    "grep" => "grep",
    "glob" => "glob",
    "edit" => "edit",
    "multiedit" => "edit",
    "str_replace" => "edit",
    "apply_patch" => "edit",
    "write" => "create",
    "create" => "create"
  }
  @recent 40
  # A shell word's value: quoted (`'...'`, `$'...'`, `"..."`) or bare, in parts.
  @value ~S{(?:\$'(?:\\.|[^'\\])*'|'[^']*'|"(?:\\.|[^"\\])*"|[^\s;&|()'"])}
  # A quoted string, which a newline in it shows to be text (a commit message's body, a
  # file's lines), not a word.
  @quoted ~S{\$'(?:\\.|[^'\\])*'|'[^']*'|"(?:\\.|[^"\\])*"}
  # `NAME=value`, set before a command, by `export` or `env`, or passed to one (`make
  # TOKEN=...`): any of them may be a secret. A flag's (`--maxfail=1`) is not one.
  @assignment Regex.compile!("(^|[\\s;&|(`])([A-Za-z_]\\w*)=#{@value}*")
  # A here-string's text, `<<< '...'`.
  @here_string Regex.compile!("<<<\\s*#{@value}+")
  # Code run from the command line, which may write files no edit counter sees, or hold
  # anything: `python -c`, `node -e`, `ruby -e`, `perl -ne`, `php -r`, `deno eval`.
  @inline_code ~r/(?:^|[\s;&|(\/])(?:python\d?(?:\.\d+)?\s+(?:-\S+\s+)*-c|(?:node|bun)\s+(?:-\S+\s+)*(?:-e|-p|--eval|--print)|(?:ruby|osascript|Rscript)\s+(?:-\S+\s+)*-e|perl\s+(?:-\S+\s+)*-[a-zA-Z]*[eE]|php\s+(?:-\S+\s+)*-r|deno\s+eval)(?=[\s'"]|$)/

  def test_run_re, do: @test_run
  def error_re, do: @error

  @doc "A fresh state."
  def new do
    %{
      turns: 0,
      edit_counts: %{},
      error_outputs: 0,
      test_runs: 0,
      fail_sigs: %{},
      repeated_fail_sigs: 0,
      recent: []
    }
  end

  @doc "The fold's name for a tool: `Bash` and `shell` are `bash`, `Read` is `view`, ..."
  def canon_tool(name) when is_binary(name) and name != "",
    do: Map.get(@canon, String.downcase(name), name)

  def canon_tool(_), do: "?"

  @doc "The last part of a path."
  def basename(nil), do: ""
  def basename(""), do: ""
  def basename(path), do: path |> String.trim_trailing("/") |> String.split("/") |> List.last()

  def edit_churn(%{edit_counts: counts}) when counts == %{}, do: 0
  def edit_churn(%{edit_counts: counts}), do: counts |> Map.values() |> Enum.max()

  def distinct_edit_files(%{edit_counts: counts}), do: map_size(counts)

  @doc """
  The share of failing outputs that repeat an earlier identical failure: the agent
  edited, but the same failure came back. 0 when nothing failed.
  """
  def stagnation(%{fail_sigs: sigs, repeated_fail_sigs: repeated}) do
    case sigs |> Map.values() |> Enum.sum() do
      0 -> 0.0
      total -> repeated / total
    end
  end

  @doc """
  A normalised signature of a failing output: numbers, addresses and paths dropped, so
  two runs that fail the same way hash alike. A hash, never the content.
  """
  def failure_sig(text) when is_binary(text) and text != "" do
    case text |> String.split(~r/\r\n|\n|\r/) |> Enum.find(&Regex.match?(@error, &1)) do
      nil ->
        nil

      line ->
        norm = line |> String.replace(~r/0x[0-9a-f]+|\d+|\/\S+/, "") |> String.trim()
        :crypto.hash(:md5, norm) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    end
  end

  def failure_sig(_), do: nil

  @doc """
  Folds one completed tool call into the state. `failed` is what the agent reported
  of the call (true for a non-zero exit or a tool error, false for success, nil when it
  did not say) and decides whether its output can be a failing one: a call known to
  have succeeded is not, a content tool only when the tool itself failed, and otherwise
  the output's own markers decide.
  """
  def update(state, tool_name, args, result, failed \\ nil) do
    turns = state.turns + 1
    args = if is_map(args), do: args, else: %{}
    tool = canon_tool(tool_name)
    state = %{state | turns: turns}

    {state, action} =
      if tool in @edit_tools do
        case basename(args["path"] || args["filePath"] || args["file_path"]) do
          "" ->
            {state, tool}

          b ->
            {%{state | edit_counts: Map.update(state.edit_counts, b, 1, &(&1 + 1))}, "edit #{b}"}
        end
      else
        {state, tool}
      end

    cmd = if tool == "bash", do: args["command"] || "", else: ""

    {state, action} =
      cond do
        is_binary(cmd) and cmd != "" ->
          short =
            cmd |> shown() |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 90)

          state =
            if Regex.match?(@test_run, cmd),
              do: %{state | test_runs: state.test_runs + 1},
              else: state

          {state, "$ #{short}"}

        tool in ["grep", "glob"] ->
          {state, "#{tool} #{String.slice(text(args["pattern"]), 0, 40)}"}

        tool == "view" ->
          {state, "view #{basename(args["path"] || args["file_path"])}"}

        true ->
          {state, action}
      end

    can_fail = if tool in @content_tools, do: failed == true, else: failed != false

    {state, fail} =
      if is_binary(result) and result != "" and can_fail and Regex.match?(@error, result) do
        state = %{state | error_outputs: state.error_outputs + 1}

        case failure_sig(result) do
          nil ->
            {state, nil}

          sig ->
            repeated =
              if Map.has_key?(state.fail_sigs, sig),
                do: state.repeated_fail_sigs + 1,
                else: state.repeated_fail_sigs

            {%{
               state
               | repeated_fail_sigs: repeated,
                 fail_sigs: Map.update(state.fail_sigs, sig, 1, &(&1 + 1))
             }, sig}
        end
      else
        {state, nil}
      end

    # A rolling, leakage-safe action log: tool, command, search or error signature only,
    # never file contents, edit bodies or what a view showed.
    tag = if fail, do: "  [err##{fail}]", else: ""
    line = "#{String.pad_leading(Integer.to_string(turns), 3)}: #{action}#{tag}"
    %{state | recent: Enum.take(state.recent ++ [line], -@recent)}
  end

  @doc """
  A compact, leakage-safe digest of the agent's recent process (its last `n` actions)
  for the judge. `envelope`, how long this project's turns that ended well usually run,
  is given as context, so the judge can tell an abnormally long turn.
  """
  def recent_digest(state, n \\ 24, envelope \\ nil) do
    head =
      "turns=#{state.turns} edit_churn=#{edit_churn(state)} " <>
        "distinct_edit_files=#{distinct_edit_files(state)} " <>
        "error_outputs=#{state.error_outputs} test_runs=#{state.test_runs} " <>
        "repeated_identical_failures=#{state.repeated_fail_sigs} " <>
        "stagnation=#{fixed(stagnation(state), 2)}"

    head =
      if envelope && envelope != 0 do
        ratio = state.turns / envelope

        head <>
          "\nrepo_context: tasks here usually RESOLVE within ~#{fixed(envelope, 0)} " <>
          "turns; this trajectory is at #{state.turns} turns = #{fixed(ratio, 1)}x that " <>
          "typical length. Tests are still NOT green. A trajectory far past " <>
          "the typical resolved length with recurring failures is likely a " <>
          "dead-end loop, even if it touches many files."
      else
        head
      end

    head <> "\nRecent actions (oldest->newest):\n" <> Enum.join(Enum.take(state.recent, -n), "\n")
  end

  @doc "The signals, as an ended-green turn's record keeps them."
  def snapshot(state) do
    %{
      "turns" => state.turns,
      "edit_churn" => edit_churn(state),
      "distinct_edit_files" => distinct_edit_files(state),
      "error_outputs" => state.error_outputs,
      "test_runs" => state.test_runs,
      "stagnation" => Float.round(stagnation(state) * 1.0, 3),
      "repeated_fail_sigs" => state.repeated_fail_sigs
    }
  end

  @doc "Counts `names` as edits, and says so in the action log."
  def fold_shell_edits(state, []), do: state

  def fold_shell_edits(state, names) do
    counts = Enum.reduce(names, state.edit_counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))

    recent =
      case state.recent do
        [] ->
          []

        recent ->
          shown =
            Enum.join(Enum.take(names, 4), ", ") <> if(length(names) > 4, do: ", ...", else: "")

          List.update_at(recent, -1, &"#{&1}  [edits #{shown}]")
      end

    %{state | edit_counts: counts, recent: recent}
  end

  # What the action log keeps of a command: never a heredoc's body, a here-string's text,
  # a quoted string over several lines or the value a variable is set to (`API_TOKEN=...
  # pytest`), and of a command that writes a file, source or not, runs code given inline
  # (`node -e '...'`) or code this cannot read (`sh -c '...'`, `... | python3`, quotes
  # that do not balance), only the programs it runs, for any of its words may be what it
  # writes (`printf '...' > a.py`, `echo SECRET=1 > Main.qml`, `sed -i 's/x/y/' a.py`).
  # `fold_shell_edits/2` names the source files it wrote.
  defp shown(cmd) do
    script = ShellEdits.script(cmd)

    if ShellEdits.writes?(script) or Regex.match?(@inline_code, script) or
         ShellEdits.opaque?(script) do
      Enum.join(ShellEdits.programs(script), "; ") <> " …"
    else
      {shell, _} = ShellEdits.split_heredocs(script)

      shell =
        Regex.replace(~r/#{@quoted}/, shell, fn q ->
          if String.contains?(q, "\n"), do: String.last(q) <> "…" <> String.last(q), else: q
        end)

      shell = Regex.replace(@here_string, shell, "<<< …")
      Regex.replace(@assignment, shell, "\\1\\2=…")
    end
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  defp fixed(x, digits), do: :erlang.float_to_binary(x * 1.0, decimals: digits)
end
