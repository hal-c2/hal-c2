# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/shell_edits.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: Python's `shlex` (non-POSIX, with punctuation
# characters) is reimplemented here, quirks included, so commands split as upstream's do,
# but for a run of operators (`)>`), a word's quoted parts (`-e'a;b'`), escapes (`a\;b`,
# `"a\"b"`, `$'a\'b'`) and a `#` inside a word, read as the shell reads them;
# `fold_shell_edits` lives in State; a heredoc ends where the shell's
# does, its delimiter any word (`<<'EOF-CODE'`, `<<123`), and every heredoc a line opens
# is read; `dd`, `sponge`, `cp`, `mv`, `install`
# and `truncate` write files too, as does `gawk -i inplace`; an editor behind a wrapper
# (`sudo -u me`, `timeout 10`, `xargs`, `find -exec`), in a nested shell or `eval`, with
# its script attached (`-e's/a/b/'`) or after git's global options is read;
# `programs/1` and `writes?/1` are new; QML counts as source.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.ShellEdits do
  @moduledoc """
  Edits made through the shell, which an edit-tool counter does not see.

  An agent that edits through Bash (`sed -i`, `perl -pi`, a redirect, `tee`, `sponge` or
  `dd of=` into a source file, a `cp`, `mv` or `install` onto one, `truncate`, an inline
  Python script that writes the file back, `patch` or `git apply`, Codex's `apply_patch`
  fed a patch on stdin) would otherwise look like one that edited
  nothing, and a judge reading the digest would be told no file had been edited when four
  had. `targets/1` reads those writes off the command; `State.fold_shell_edits/2` counts
  them after the regular update, so the call still counts once.
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.State

  @shells ~w(sh bash zsh dash ksh)
  # Programs that run code: from stdin when given no script, or handed on the command line.
  @interpreter ~r/^(?:python\d?(?:\.\d+)?|node|bun|deno|ruby|perl|php|lua|osascript|Rscript|pwsh|fish)$/
  @awk ~w(awk gawk mawk nawk)
  # The flags an interpreter is read with: none hands it code. Any other may (`-e`, `-c`,
  # `-pe`, `--eval`, `--import=data:...`, `-M'X;...'`), wherever it is in the words.
  @reading_flag ~r/^(?:-[wvVhI]|-I\S+|--(?:version|help|check|no-warnings|enable-source-maps|trace-warnings|trace-uncaught|test(?:-[\w-]+)?(?:=\S*)?))$/
  # The flags an interpreter given no script runs without reading stdin (`node --test`).
  @no_stdin_flag ~r/^(?:-[vVh]|--(?:version|help|test(?:-[\w-]+)?(?:=\S*)?))$/
  # Python's own flags that hand it no code, and those that take the next word.
  @python_flag ~r/^-[bBdEhiIOqsSuvVx]+$/
  # Flags that hand an interpreter its code (`perl -le`, `node -p`, `ruby -e`); flags whose
  # value is attached (`ruby -Itest`, `perl -Mstrict`), which are none of them; and flags
  # whose value is the next word (`node -r ./setup.js`, `php -d x=1`), not the program.
  @eval_flag ~r/^-(?:-(?:eval|print|exec|command)(?:=.*)?|[A-Za-z]*[ceEp][A-Za-z]*)$/
  @attached_value ~r/^-[IrMmWXdx]/
  @separate_value ~w(-r --require --import --loader --experimental-loader --input-type -I -M -d -c)
  # A heredoc's delimiter, after its `<<`: `-` for `<<-`, then any word, quoted in whole
  # or part or not (`<<'EOF-CODE'`, `<<"E"OF`, `<<\EOF`, `<<123`).
  @heredoc_word ~r/\A(-?)[ \t]*((?:'[^'\n]*'|"(?:\\.|[^"\\\n])*"|\\.|[^\s'"<>|&;()\\])+)/u
  # What ends a word, so a `#` after it starts a comment.
  @boundary ~c" \t;&|()<>"
  @ops ["&&", "||", ";", ";;", "|", "|&", "&", "\n", "(", ")"]
  # Redirects that write their operand: any that may, `<>` opening it read-write too.
  @out [">", ">>", ">|", "&>", "&>>", "<>"]
  # The shell's words that open or close a group, a branch or a loop, before a command.
  @reserved ~w({ } ! if then else elif fi do done while until)
  # Programs that run another, given after their own words, and the programs this reads
  # writes off, which a wrapper is unwrapped to.
  @wrappers ~w(sudo doas command env time nohup timeout nice ionice stdbuf chronic flock xargs find)
  @writers ~w(sed perl awk gawk tee dd sponge truncate cp mv install patch git apply_patch eval) ++
             @shells
  # The operands `find -exec` and `xargs -I` put file names in place of.
  @fed ["{}", "+", ";", "\\"]
  # Input, heredoc tags, fd duplication.
  @skip_operand ["<", "<<", "<<<", "<&", ">&"]
  # Redirect and `tee` targets count only when they look like source, so `> out.log` or
  # `| tee /tmp/run.txt`, capturing output, is not mistaken for an edit.
  @source_file ~r/\.(?:py|pyi|pyx|pxd|js|jsx|mjs|cjs|ts|tsx|rs|go|java|kt|kts|scala|c|cc|cpp|cxx|h|hh|hpp|rb|php|cs|swift|m|mm|sh|bash|zsh|lua|jl|ex|exs|erl|hs|ml|clj|sql|toml|ya?ml|json|cfg|ini|conf|md|rst|html?|css|scss|vue|svelte|qml|xml|gradle|properties|in)$/i
  @python ~r/(?:^|[\s\/;&|(])python\d?(?:\.\d+)?\b/
  @py_open_lit ~r/open\(\s*(['"])([^'"\n]+)\1\s*,\s*(['"])([^'"]*)\3/
  @py_open_var ~r/open\(\s*([A-Za-z_]\w*)\s*,\s*(['"])([^'"]*)\2/
  @py_write_path_lit ~r/(?:pathlib\.)?Path\(\s*(['"])([^'"\n]+)\1\s*\)\.write_(?:text|bytes)\(/
  @py_write_path_var ~r/\b([A-Za-z_]\w*)\.write_(?:text|bytes)\(/
  # Codex's patch format, as `apply_patch <<'PATCH'` takes it on stdin.
  @patch_file ~r/^\*\*\* (?:Update|Add|Delete) File:\s*(.+?)\s*$/m

  @doc """
  Basenames of the files a shell command writes, in order, without repeats; of the script
  for one run as `bash -lc '<script>'`.
  """
  def targets(cmd) when is_binary(cmd) do
    for({kind, path} <- writes(cmd), kind == :edit or Regex.match?(@source_file, path), do: path)
    |> Enum.filter(&(String.starts_with?(&1, "(") or not_scratch(&1)))
    |> Enum.map(&if(String.starts_with?(&1, "("), do: &1, else: State.basename(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def targets(_), do: []

  @doc """
  Whether a shell command writes any file but a device (`> /dev/null`), source or not,
  scratch or not: what `targets/1` leaves out (`> out.log`, `> /tmp/a.py`, `> Makefile`)
  is still written, and the words that write it may be the file's contents.
  """
  def writes?(cmd) when is_binary(cmd),
    do: Enum.any?(writes(cmd), fn {_, path} -> not String.starts_with?(path, "/dev/") end)

  def writes?(_), do: false

  # Every path the command writes, as `{:edit, path}` for an editor's (`sed -i`, `patch`,
  # a Python script's) and `{:capture, path}` for a redirect's or `tee`'s, which may only
  # be capturing output.
  defp writes(cmd) do
    cmd = script(cmd)

    if String.trim(cmd) == "" do
      []
    else
      {shell, bodies} = split_heredocs(cmd)
      {cmds, redirects} = commands(shell)
      found = for path <- redirects, do: {:capture, path}

      found =
        Enum.reduce(bare(cmds), found, fn tokens, found ->
          found ++ written_by(head(tokens), tokens, bodies)
        end)

      if Regex.match?(@python, shell),
        do: found ++ for(p <- py_writes(Enum.join([shell | bodies], "\n")), do: {:edit, p}),
        else: found
    end
  end

  @doc """
  Basenames of the files a shell command puts back with `git checkout --` or `git
  restore`. `targets/1` counts them as written, which they are; the loop guard counts
  them as edits only for a file the turn edited.
  """
  def revert_targets(cmd) when is_binary(cmd) do
    cmd = script(cmd)

    if String.trim(cmd) == "" do
      []
    else
      {shell, _} = split_heredocs(cmd)
      {cmds, _} = commands(shell)

      for(tokens <- bare(cmds), p <- restored(tokens), not_scratch(p), do: State.basename(p))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  def revert_targets(_), do: []

  @doc """
  Whether a shell command's words may be code this does not read: quotes that do not
  balance, a nested shell's script or `eval`'s (`sh -c '...'`), a program reading its
  code from stdin (`... | python3`, `curl ... | sh`), awk's program, or an interpreter
  given any flag but those it is only read with, wherever in its words (`node
  --input-type commonjs -e '...'`, `python3 -X dev -c '...'`), behind a wrapper too
  (`timeout 10 ruby -e '...'`, `find -exec perl -pe '...'`). Python's are read up to the
  script or module it runs; the words after are that program's.
  """
  def opaque?(cmd) when is_binary(cmd) do
    {shell, _} = cmd |> script() |> split_heredocs()

    case tokens(shell) do
      :error ->
        true

      {:ok, _} ->
        {cmds, _} = commands(shell)
        Enum.any?(bare(cmds), &runs_code?/1)
    end
  end

  def opaque?(_), do: false

  @doc """
  Whether a shell command may run a check this does not hear, or hide one's exit status,
  so a turn must not be learned from it. Narrower than `opaque?/1`, which hides from the
  digest anything this does not read whole: a runner with any flags (`bun test
  --coverage`, `node --experimental-vm-modules node_modules/.bin/jest`) and a parameter
  expansion (`${VAR}`) hide nothing. It does when its text was cut (a plugin hears none
  of a command too long), a quote does not close, or a heredoc is not placed, so its
  lines may be any commands; or when it runs a script this does not read: a nested
  shell's (`bash -lc '...' || true`, `eval`), one a shell or interpreter reads from stdin
  (`python3 <<EOF`, `... | sh`), inline code (`node -e`, `perl -le`, `deno eval`), a file
  `written` this turn (basenames) it sources or runs with a shell (`source run.sh`), or
  a command substitution whose own command does (`$(...)`, backticks, `<(...)`, in a
  heredoc the shell expands too). A command run whole as `bash -lc '<script>'` is its
  script.
  """
  def hides_check?(cmd, written \\ [])

  def hides_check?(cmd, written) when is_binary(cmd), do: hides(script(cmd), written)
  def hides_check?(_, _), do: true

  # `hides_check?/2` of shell text as it is: a substitution's `bash -c '...'` is nested,
  # its status not the command's.
  defp hides(cmd, written) do
    {shell, bodies, placed} = heredocs(cmd)
    expanded = for {body, true} <- bodies, do: body

    with true <- placed and String.trim(cmd) != "",
         {:ok, shell} <- subst(String.to_charlist(shell), :none, [], written),
         true <-
           Enum.all?(expanded, &(subst(String.to_charlist(&1), :doc, [], written) != :error)),
         {:ok, _} <- tokens(shell) do
      {cmds, _} = commands(shell)
      Enum.any?(cmds, &runs_script?(&1, written))
    else
      _ -> true
    end
  end

  # A simple command's words: whether they run a script this does not read.
  defp runs_script?(words, written) do
    case Enum.drop_while(words, &(&1 in @reserved or Regex.match?(~r/^\w+=/, &1))) do
      [] -> false
      [first | args] -> runs_script?(head([first]), args, written)
    end
  end

  defp runs_script?("eval", _, _), do: true

  defp runs_script?(dot, [file | _], written) when dot in ["source", "."],
    do: head([file]) in written

  defp runs_script?("command", [flag | _], _) when flag in ["-v", "-V"], do: false

  defp runs_script?(name, args, written) do
    cond do
      name in @shells ->
        shell_script?(args, written)

      String.starts_with?(name, "python") and Regex.match?(@interpreter, name) ->
        not python_reads?(args)

      Regex.match?(@interpreter, name) ->
        inline?(name, args)

      # `timeout 60 bash -c ...`, `find . -exec sh -c ... +`, `xargs -n1 node -e ...`.
      name in @wrappers ->
        case Enum.drop_while(args, &(not runner?(head([&1])))) do
          [] -> false
          [run | rest] -> runs_script?(head([run]), rest, written)
        end

      true ->
        false
    end
  end

  # A shell's words: a `-c` script, or none (it reads stdin), or a script written this turn.
  defp shell_script?([opt, _ | rest], written) when opt in ["-o", "+o", "-O", "+O"],
    do: shell_script?(rest, written)

  defp shell_script?(["-" <> flags | rest], written),
    do: String.contains?(flags, "c") or shell_script?(rest, written)

  defp shell_script?(["+" <> _ | rest], written), do: shell_script?(rest, written)
  defp shell_script?([file | _], written), do: head([file]) in written
  defp shell_script?([], _), do: true

  # Whether an interpreter's words hand it code: an eval flag of its own anywhere before a
  # `--` (`-e`, `-pe`, `-c`, `--eval`, `--print`, php's `-r`, `deno eval`), whatever
  # order its flags and their values come in, or no program and no flag that reads none,
  # so it reads stdin. A script's own argument spelt as one hides it too, at the cost of a
  # turn not learned.
  defp inline?(name, args) do
    words = Enum.take_while(args, &(&1 != "--"))
    operands = operands_of(words)

    cond do
      name in ~w(deno bun) and List.first(operands) == "eval" -> true
      Enum.any?(words, &eval_flag?(name, &1)) -> true
      true -> operands == [] and not Enum.any?(words, &Regex.match?(@no_stdin_flag, &1))
    end
  end

  defp eval_flag?("php", flag), do: Regex.match?(~r/^-[A-Za-z]*[rBRE]/, flag)

  defp eval_flag?(_, flag),
    do: not Regex.match?(@attached_value, flag) and Regex.match?(@eval_flag, flag)

  # The words that are not flags nor a flag's separate value (`-r ./setup.js`,
  # `--input-type commonjs`): what may be the program.
  defp operands_of([flag, _ | rest]) when flag in @separate_value, do: operands_of(rest)
  defp operands_of(["-" <> _ | rest]), do: operands_of(rest)
  defp operands_of([word | rest]), do: [word | operands_of(rest)]
  defp operands_of([]), do: []

  # The shell text with each command substitution (`$(...)`, backticks, `<(...)`,
  # `>(...)`) and parameter expansion (`${...}`) put as one plain word; :error when a
  # substitution's command hides a check (`hides_check?/2`), or one is left open. `quote`
  # is the quoting context: :none, ?', ?", :ansi, or :doc for an expanded heredoc body,
  # whose quotes are its text.
  defp subst([], quote, acc, _) when quote in [:none, :doc],
    do: {:ok, acc |> Enum.reverse() |> List.to_string()}

  defp subst([], _, _, _), do: :error

  defp subst([?\\, c | rest], quote, acc, w) when quote != ?',
    do: subst(rest, quote, [c, ?\\ | acc], w)

  defp subst([?$, ?( | rest], quote, acc, w) when quote in [:none, ?", :doc],
    do: substitution(closing(rest, 0, :none, []), quote, acc, w)

  defp subst([c, ?( | rest], :none, acc, w) when c in [?<, ?>],
    do: substitution(closing(rest, 0, :none, []), :none, [c | acc], w)

  defp subst([?` | rest], quote, acc, w) when quote in [:none, ?", :doc],
    do: substitution(backtick(rest, []), quote, acc, w)

  defp subst([?$, ?{ | rest], quote, acc, w) when quote in [:none, ?", :doc] do
    with {inner, rest} <- brace(rest, 0, []),
         {:ok, _} <- subst(String.to_charlist(inner), :doc, [], w) do
      subst(rest, quote, [?_ | acc], w)
    end
  end

  defp subst([?$, q | rest], :none, acc, w) when q in [?', ?"],
    do: subst(rest, if(q == ?', do: :ansi, else: ?"), [q, ?$ | acc], w)

  defp subst([q | rest], :none, acc, w) when q in [?', ?"], do: subst(rest, q, [q | acc], w)
  defp subst([?' | rest], :ansi, acc, w), do: subst(rest, :none, [?' | acc], w)
  defp subst([q | rest], q, acc, w) when q in [?', ?"], do: subst(rest, :none, [q | acc], w)
  defp subst([c | rest], quote, acc, w), do: subst(rest, quote, [c | acc], w)

  defp substitution(:error, _, _, _), do: :error

  defp substitution({inner, rest}, quote, acc, w),
    do: if(hides(inner, w), do: :error, else: subst(rest, quote, [?_ | acc], w))

  # The text before the `)` that closes a substitution, and the text after it.
  defp closing([], _, _, _), do: :error
  defp closing([?\\, c | rest], d, q, acc) when q != ?', do: closing(rest, d, q, [c, ?\\ | acc])
  defp closing([?) | rest], 0, :none, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp closing([?) | rest], d, :none, acc), do: closing(rest, d - 1, :none, [?) | acc])
  defp closing([?( | rest], d, :none, acc), do: closing(rest, d + 1, :none, [?( | acc])
  defp closing([q | rest], d, :none, acc) when q in [?', ?"], do: closing(rest, d, q, [q | acc])
  defp closing([q | rest], d, q, acc), do: closing(rest, d, :none, [q | acc])
  defp closing([c | rest], d, q, acc), do: closing(rest, d, q, [c | acc])

  defp backtick([], _), do: :error
  defp backtick([?\\, c | rest], acc) when c in ~c"`\\$", do: backtick(rest, [c | acc])
  defp backtick([?` | rest], acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp backtick([c | rest], acc), do: backtick(rest, [c | acc])

  defp brace([], _, _), do: :error
  defp brace([?\\, c | rest], d, acc), do: brace(rest, d, [c, ?\\ | acc])
  defp brace([?} | rest], 0, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp brace([?} | rest], d, acc), do: brace(rest, d - 1, [?} | acc])
  defp brace([?{ | rest], d, acc), do: brace(rest, d + 1, [?{ | acc])
  defp brace([c | rest], d, acc), do: brace(rest, d, [c | acc])

  defp runs_code?(["eval" | _]), do: true

  defp runs_code?([first | args]) do
    name = head([first])
    flags_only = Enum.all?(args, &String.starts_with?(&1, "-"))

    cond do
      name in @shells ->
        flags_only or Enum.any?(args, &Regex.match?(~r/^-[a-zA-Z]*c[a-zA-Z]*$/, &1))

      String.starts_with?(name, "python") and Regex.match?(@interpreter, name) ->
        not python_reads?(args)

      Regex.match?(@interpreter, name) ->
        (flags_only and not Enum.any?(args, &Regex.match?(@no_stdin_flag, &1))) or
          List.first(Enum.reject(args, &String.starts_with?(&1, "-"))) == "eval" or
          Enum.any?(args, &(String.starts_with?(&1, "-") and not Regex.match?(@reading_flag, &1)))

      name in @awk ->
        not Enum.any?(args, &(&1 in ~w(-f --file) or String.starts_with?(&1, "--file=")))

      # `timeout 10 node -e ...`, `find . -exec perl -pe ... {} +`.
      name in @wrappers ->
        case Enum.drop_while(args, &(not runner?(head([&1])))) do
          [] -> false
          run -> runs_code?(run)
        end

      true ->
        false
    end
  end

  defp runner?(name),
    do: name in @shells or name in @awk or name == "eval" or Regex.match?(@interpreter, name)

  # Whether Python runs a script or a module with these words, its own flags handing it
  # no code; the words after the script or module are that program's.
  defp python_reads?([flag, _ | rest]) when flag in ["-W", "-X"], do: python_reads?(rest)
  defp python_reads?(["-m" <> _ | _]), do: true
  defp python_reads?(["-W" <> _ | rest]), do: python_reads?(rest)
  defp python_reads?(["-X" <> _ | rest]), do: python_reads?(rest)
  defp python_reads?([flag | rest]) when flag in ["--version", "--help"], do: python_reads?(rest)

  defp python_reads?(["-" <> _ = flag | rest]),
    do: Regex.match?(@python_flag, flag) and python_reads?(rest)

  defp python_reads?([_script | _]), do: true
  defp python_reads?([]), do: false

  @doc """
  Whether this reads every character of a shell command as the shell does, so what it
  says of the command can be shown: its quotes and escapes close, nothing in it opens a
  quoting context this does not follow (`$(...)`, `${...}`, backticks, `$'...'`,
  `$"..."`), and its words, spaces aside, are all its characters (a comment is dropped);
  heredoc bodies aside, and of the script for one run as `bash -lc '<script>'`.
  """
  def legible?(cmd) when is_binary(cmd) do
    {shell, _} = cmd |> script() |> split_heredocs()

    case followed(shell) do
      {:ok, toks} -> unspaced(Enum.join(toks)) == unspaced(shell)
      :error -> false
    end
  end

  def legible?(_), do: false

  # The shell text's words, when its quotes and escapes close and nothing in it opens a
  # quoting context this does not follow.
  defp followed(shell) do
    if Regex.match?(~r/`|\$['"({]/, shell), do: :error, else: tokens(shell)
  end

  defp unspaced(text), do: String.replace(text, ~r/\s/u, "")

  @doc """
  The programs a shell command runs, by name (`sed`, `printf`, `pytest`), without their
  arguments; of the script for one run as `bash -lc '<script>'`.
  """
  def programs(cmd) when is_binary(cmd) do
    {shell, _} = cmd |> script() |> split_heredocs()
    {cmds, _} = commands(shell)
    cmds |> bare() |> Enum.map(&head/1) |> Enum.reject(&(&1 == ""))
  end

  def programs(_), do: []

  defp written_by("sed", tokens, _),
    do:
      in_place(
        "sed",
        tokens,
        &Regex.match?(~r/^(?:-[a-zA-Z]*i|--in-place)/, &1),
        &(&1 in ["-e", "-f", "--expression", "--file"]),
        &Regex.match?(~r/^(?:-[a-zA-Z]*[ef].|--(?:expression|file)=)/, &1)
      )

  defp written_by("perl", tokens, _),
    do:
      in_place(
        "perl",
        tokens,
        &Regex.match?(~r/^-[a-zA-Z]*i/, &1),
        &Regex.match?(~r/^-[a-zA-Z]*e$/, &1),
        &Regex.match?(~r/^-[a-zA-Z]*[eE]./, &1)
      )

  defp written_by("tee", [_ | args], _),
    do: for(a <- args, not String.starts_with?(a, "-"), do: {:capture, a})

  defp written_by("apply_patch", [_ | args], bodies) do
    text = Enum.join(bodies ++ [Enum.join(args, " ")], "\n")

    case Regex.scan(@patch_file, text, capture: :all_but_first) do
      [] -> [{:edit, "(patch)"}]
      found -> for [path] <- found, do: {:edit, path}
    end
  end

  defp written_by("dd", tokens, _), do: for("of=" <> path <- tokens, do: {:capture, path})

  defp written_by("sponge", [_ | args], _), do: for(p <- operands(args, []), do: {:capture, p})

  defp written_by("truncate", [_ | args], _),
    do: for(p <- operands(args, ~w(-s -r)), do: {:capture, p})

  defp written_by(copier, [_ | args], _) when copier in ~w(cp mv install),
    do: for(p <- copied(args), do: {:capture, p})

  # A nested shell's script (`bash -c '...'`), and `eval`'s, write what they would run
  # alone.
  defp written_by(shell, [_ | args], _) when shell in @shells do
    case Enum.drop_while(args, &(not Regex.match?(~r/^-[a-zA-Z]*c[a-zA-Z]*$/, &1))) do
      [_, script | _] -> writes(script)
      _ -> []
    end
  end

  defp written_by("eval", [_ | args], _), do: writes(Enum.join(args, " "))

  # `gawk -i inplace` rewrites its file operands; the program is the first operand,
  # unless `-f` names its file.
  defp written_by(awk, [_ | args], _) when awk in ~w(awk gawk) do
    inplace? =
      Enum.any?(args, &(&1 in ["-iinplace", "--include=inplace"])) or
        Enum.any?(
          Enum.chunk_every(args, 2, 1),
          &(&1 in [["-i", "inplace"], ["--include", "inplace"]])
        )

    files = operands(args, ~w(-i -v -f -F -E --include --assign --file --field-separator))
    files = if Enum.any?(args, &(&1 in ~w(-f -E --file))), do: files, else: Enum.drop(files, 1)
    if inplace?, do: edits(files), else: []
  end

  defp written_by("patch", _, _), do: [{:edit, "(patch)"}]
  defp written_by("git", [_, "apply" | _], _), do: [{:edit, "(patch)"}]
  defp written_by(_, tokens, _), do: edits(restored(tokens))

  defp edits(paths), do: for(p <- paths, do: {:edit, p})

  # The words that are not flags, nor the value of a flag in `valued`.
  defp operands(args, valued) do
    {found, _} =
      Enum.reduce(args, {[], false}, fn t, {found, value?} ->
        cond do
          value? -> {found, false}
          String.starts_with?(t, "-") -> {found, t in valued}
          true -> {[t | found], false}
        end
      end)

    Enum.reverse(found)
  end

  defp target_dir("--target-directory=" <> dir), do: dir
  defp target_dir(_), do: nil

  # The paths a `cp`, `mv` or `install` writes: its last operand, or each source's name
  # in it when it is a directory (`-t dir`, a trailing `/`, or a name with no extension).
  defp copied(args) do
    paths = operands(args, ~w(-t -m -o -g -S -b))

    dir =
      case Enum.drop_while(args, &(&1 != "-t")) do
        ["-t", dir | _] -> dir
        _ -> Enum.find_value(args, fn a -> target_dir(a) end)
      end

    into = fn dir, sources -> for s <- sources, do: Path.join(dir, State.basename(s)) end

    cond do
      is_binary(dir) and dir != "" ->
        into.(dir, paths)

      length(paths) < 2 ->
        []

      true ->
        {sources, [dest]} = Enum.split(paths, -1)

        if String.ends_with?(dest, "/") or not String.contains?(State.basename(dest), "."),
          do: into.(dest, sources),
          else: [dest]
    end
  end

  defp head([first | _]), do: first |> String.split("/") |> List.last()

  defp not_scratch(path),
    do: path != "" and not String.starts_with?(path, ["/dev/", "/proc/", "/tmp/"])

  # A word without its quotes and escapes, as the shell reads it: whole (`'a.py'`) or in
  # part (`a'.py'`, `-e's/a/b/'`, `a\ b.py`, `"a\"b.py"`); `$'...'` keeps its escapes.
  defp unquote_word(t), do: t |> String.to_charlist() |> unquote_chars(:word, [])

  defp unquote_chars([], _, acc), do: acc |> Enum.reverse() |> List.to_string()
  defp unquote_chars([?\\, c | rest], :word, acc), do: unquote_chars(rest, :word, [c | acc])
  defp unquote_chars([?$, ?' | rest], :word, acc), do: unquote_chars(rest, :ansi, acc)
  defp unquote_chars([q | rest], :word, acc) when q in [?', ?"], do: unquote_chars(rest, q, acc)

  defp unquote_chars([?\\, c | rest], ?", acc) when c in ~c"$`\"\\\n",
    do: unquote_chars(rest, ?", [c | acc])

  defp unquote_chars([?\\, c | rest], :ansi, acc),
    do: unquote_chars(rest, :ansi, [c, ?\\ | acc])

  defp unquote_chars([?' | rest], :ansi, acc), do: unquote_chars(rest, :word, acc)
  defp unquote_chars([q | rest], q, acc), do: unquote_chars(rest, :word, acc)
  defp unquote_chars([c | rest], state, acc), do: unquote_chars(rest, state, [c | acc])

  @doc """
  The command's shell text without heredoc bodies, and the bodies: every heredoc a line
  opens (`cat <<A <<B`), read in order. Only a `<<` the shell reads opens one: not one
  quoted, escaped or in a comment (`echo '<<EOF'`), nor a here-string (`<<<`). A body
  ends only at its delimiter alone on a line (after leading tabs, for `<<-`), as the
  shell's does; one never ended runs to the end. A line continued with a backslash is one
  line, and so is one a quote spans: its heredocs start after it.
  """
  def split_heredocs(cmd) do
    {shell, bodies, _} = heredocs(cmd)
    {shell, Enum.map(bodies, &elem(&1, 0))}
  end

  # `split_heredocs/1`, and whether every heredoc is placed: each `<<` had a delimiter,
  # each body ended at it, and no quote was left open.
  defp heredocs(cmd) do
    {shell, bodies, placed} = shell_lines(String.split(cmd, "\n"), :none, [], [], [], true)
    {shell |> Enum.reverse() |> Enum.join("\n"), Enum.reverse(bodies), placed}
  end

  # `quote`: the quote the lines so far end inside; `pending`: the heredocs they opened,
  # whose bodies start after the line that closes it.
  defp shell_lines([], quote, pending, shell, bodies, placed),
    do: {shell, bodies, placed and quote == :none and pending == []}

  defp shell_lines(lines, quote, pending, shell, bodies, placed) do
    {line, rest} = logical_line(lines)
    {docs, quote, found} = heredoc_starts(String.to_charlist(line), quote, true, [], true)
    pending = pending ++ docs

    if quote == :none do
      {bodies, rest, ended} = read_bodies(pending, rest, bodies, true)
      shell_lines(rest, :none, [], [line | shell], bodies, placed and found and ended)
    else
      shell_lines(rest, quote, pending, [line | shell], bodies, placed and found)
    end
  end

  # The heredocs a line opens, `{dash, delimiter}`, the quote it ends inside, and whether
  # each `<<` had a delimiter. `start`: whether the next character starts a word.
  defp heredoc_starts([], quote, _, docs, found), do: {Enum.reverse(docs), quote, found}

  defp heredoc_starts([?\\, _ | rest], :none, _, docs, found),
    do: heredoc_starts(rest, :none, false, docs, found)

  defp heredoc_starts([?$, ?' | rest], :none, _, docs, found),
    do: heredoc_starts(rest, :ansi, false, docs, found)

  defp heredoc_starts([q | rest], :none, _, docs, found) when q in [?', ?"],
    do: heredoc_starts(rest, q, false, docs, found)

  defp heredoc_starts([?# | _], :none, true, docs, found),
    do: heredoc_starts([], :none, true, docs, found)

  defp heredoc_starts([?<, ?<, ?< | rest], :none, _, docs, found),
    do: heredoc_starts(rest, :none, true, docs, found)

  defp heredoc_starts([?<, ?< | rest], :none, _, docs, found) do
    text = List.to_string(rest)

    case Regex.run(@heredoc_word, text) do
      [all, dash, word] ->
        tag = Regex.replace(~r/\\(.)|['"]/, word, "\\1")
        doc = {dash == "-", tag, tag == word}
        rest = text |> binary_part(byte_size(all), byte_size(text) - byte_size(all))
        heredoc_starts(String.to_charlist(rest), :none, false, [doc | docs], found)

      nil ->
        heredoc_starts(rest, :none, true, docs, false)
    end
  end

  defp heredoc_starts([c | rest], :none, _, docs, found),
    do: heredoc_starts(rest, :none, c in @boundary, docs, found)

  defp heredoc_starts([?\\, _ | rest], quote, _, docs, found) when quote in [?", :ansi],
    do: heredoc_starts(rest, quote, false, docs, found)

  defp heredoc_starts([?' | rest], :ansi, _, docs, found),
    do: heredoc_starts(rest, :none, false, docs, found)

  defp heredoc_starts([q | rest], q, _, docs, found),
    do: heredoc_starts(rest, :none, false, docs, found)

  defp heredoc_starts([_ | rest], quote, _, docs, found),
    do: heredoc_starts(rest, quote, false, docs, found)

  defp logical_line([line | rest]) do
    if rest != [] and Regex.match?(~r/(?<!\\)(?:\\\\)*\\$/, line) do
      {next, rest} = logical_line(rest)
      {binary_part(line, 0, byte_size(line) - 1) <> next, rest}
    else
      {line, rest}
    end
  end

  defp read_bodies([], lines, bodies, ended), do: {bodies, lines, ended}

  defp read_bodies([{dash, tag, expands} | docs], lines, bodies, ended) do
    ends? = fn line -> if(dash, do: String.trim_leading(line, "\t"), else: line) == tag end
    {body, rest} = Enum.split_while(lines, &(not ends?.(&1)))
    bodies = [{Enum.join(body, "\n"), expands} | bodies]
    read_bodies(docs, Enum.drop(rest, 1), bodies, ended and rest != [])
  end

  # Simple commands as unquoted word lists, and the files their redirects write.
  defp commands(shell) do
    streams =
      case tokens(shell) do
        {:ok, toks} ->
          [toks]

        # One bad line must not hide the others.
        :error ->
          for line <- String.split(shell, "\n"), {:ok, toks} <- [tokens(line)], do: toks ++ ["\n"]
      end

    Enum.reduce(streams, {[], []}, fn toks, {cmds, writes} ->
      {cmds, writes, cur} = simple(toks, cmds, writes, [])
      cmds = if cur == [], do: cmds, else: cmds ++ [Enum.reverse(cur)]
      {cmds, writes}
    end)
  end

  defp simple([], cmds, writes, cur), do: {cmds, writes, cur}

  defp simple([t | rest], cmds, writes, cur) when t in @ops do
    cmds = if cur == [], do: cmds, else: cmds ++ [Enum.reverse(cur)]
    simple(rest, cmds, writes, [])
  end

  defp simple([t | rest], cmds, writes, cur) when t in @out or t in @skip_operand do
    # `2>`: the fd number is not an operand.
    cur =
      case cur do
        [fd | earlier] -> if Regex.match?(~r/^[0-9]+$/, fd), do: earlier, else: cur
        [] -> cur
      end

    # Anything but a read (`<`), a heredoc's tag or a here-string, or a duplication or
    # close of a descriptor (`2>&1`, `>&-`) may write: `>& file` writes it, as `&>` does,
    # and a target the shell computes (`>&$fd`) or a process (`> >(cmd)`) may be a file.
    writes =
      case rest do
        [next | _] when next not in @ops ->
          if t in @out or (t in [">&", "<&"] and not Regex.match?(~r/^(?:\d+|-)$/, next)),
            do: writes ++ [unquote_word(next)],
            else: writes

        _ when t in @out ->
          writes ++ ["(redirect)"]

        _ ->
          writes
      end

    simple(Enum.drop(rest, 1), cmds, writes, cur)
  end

  defp simple([t | rest], cmds, writes, cur),
    do: simple(rest, cmds, writes, [unquote_word(t) | cur])

  # The files an in-place editor (`sed -i`, `perl -pi`) edits: its file operands, or
  # "(sed)" when it names none, as when `xargs` or `find -exec` feeds them in; [] when it
  # is not in place. A script flag takes the next word (`-e 's/a/b/'`) or carries it
  # (`-e's/a/b/'`); without one the first operand is the script.
  defp in_place(name, [_ | args], inplace?, script_flag?, attached?) do
    if Enum.any?(args, inplace?) do
      case args |> inplace_files(script_flag?, attached?) |> Enum.reject(&(&1 in @fed)) do
        [] -> [{:edit, "(#{name})"}]
        files -> edits(files)
      end
    else
      []
    end
  end

  defp inplace_files(args, script_flag?, attached?) do
    {files, _, _} =
      Enum.reduce(args, {[], false, false}, fn t, {files, have_script, skip} ->
        cond do
          skip ->
            {files, true, false}

          t == "" or String.starts_with?(t, "-") ->
            {files, have_script or attached?.(t), t != "" and script_flag?.(t)}

          # The first operand is the script.
          not have_script ->
            {files, true, false}

          true ->
            {[t | files], have_script, false}
        end
      end)

    Enum.reverse(files)
  end

  # Paths an inline Python script writes; "(script)" for a write whose path this cannot
  # resolve.
  defp py_writes(text) do
    lit =
      for [_, _, path, _, mode] <- Regex.scan(@py_open_lit, text), write_mode?(mode), do: path

    vars = for [_, var, _, mode] <- Regex.scan(@py_open_var, text), write_mode?(mode), do: var
    lit = lit ++ for([_, _, path] <- Regex.scan(@py_write_path_lit, text), do: path)
    vars = vars ++ for([_, var] <- Regex.scan(@py_write_path_var, text), do: var)

    lit ++
      Enum.flat_map(Enum.uniq(vars), fn var ->
        v = Regex.escape(var)

        found =
          for [_, _, path] <-
                Regex.scan(
                  ~r/\b#{v}\s*=\s*(?:(?:pathlib\.)?Path\(\s*)?(['"])([^'"\n]+)\1/,
                  text
                ),
              do: path

        loop =
          case Regex.run(~r/\bfor\s+#{v}\s+in\s+[\[(]([^\])]*)[\])]/, text) do
            [_, items] -> for [_, p] <- Regex.scan(~r/['"]([^'"\n]+)['"]/, items), do: p
            nil -> []
          end

        case found ++ loop do
          [] -> ["(script)"]
          paths -> paths
        end
      end)
  end

  defp write_mode?(mode), do: String.contains?(mode, ["w", "a", "x", "+"])

  # The paths a `git checkout -- <path>` or `git restore <path>` puts back; [] for any
  # other command.
  defp restored([first, sub | rest] = tokens)
       when sub in ["checkout", "restore"] and rest != [] do
    if head([first]) == "git" do
      rest =
        case Enum.split_while(tokens, &(&1 != "--")) do
          {_, ["--" | after_dashes]} -> after_dashes
          _ when sub == "restore" -> rest
          _ -> []
        end

      Enum.reject(rest, &String.starts_with?(&1, "-"))
    else
      []
    end
  end

  defp restored(_), do: []

  # Each command as the program it runs: the `VAR=1` and the shell's own words (`{`,
  # `then`, `do`, `!`) before it dropped, a wrapper's
  # (`sudo -u me`, `timeout 10`, `xargs`, `find ... -exec`) words up to the editor it
  # runs, and git's global options (`git -C repo`); empty ones left out.
  defp bare(cmds), do: cmds |> Enum.map(&unwrap/1) |> Enum.reject(&(&1 == []))

  defp unwrap(tokens) do
    case Enum.drop_while(tokens, &(&1 in @reserved or Regex.match?(~r/^\w+=/, &1))) do
      [first | args] = tokens ->
        cond do
          head([first]) == "git" ->
            ["git" | git_command(args)]

          head([first]) not in @wrappers ->
            tokens

          (run = Enum.drop_while(args, &(head([&1]) not in @writers))) != [] ->
            unwrap(run)

          first in ~w(sudo command env time nohup) ->
            unwrap(args)

          true ->
            tokens
        end

      [] ->
        []
    end
  end

  defp git_command([opt, _ | rest]) when opt in ~w(-C -c --git-dir --work-tree --namespace),
    do: git_command(rest)

  defp git_command(["-" <> _ | rest]), do: git_command(rest)
  defp git_command(args), do: args

  @doc """
  The script of a command recorded as `bash -lc '<script>'` (as Codex records them), else
  the command itself: also when anything runs around the shell (`bash -lc 'true' &&
  pytest`), whose script is then read as a nested shell's.
  """
  def script(cmd) when is_binary(cmd) do
    with [shell, "-" <> flags, script | _] <- posix_split(cmd),
         true <- State.basename(shell) in @shells and String.contains?(flags, "c"),
         {:ok, toks} <- tokens(cmd),
         false <- Enum.any?(toks, &(&1 in @ops or &1 in @out or &1 in @skip_operand)) do
      script
    else
      _ -> cmd
    end
  end

  def script(cmd), do: cmd

  # ---- Python's shlex.split (POSIX, no comments): only the first words matter, to find
  # `bash -lc '<script>'`. [] when the quotes do not balance, as shlex raises.

  defp posix_split(text) do
    case psplit(String.to_charlist(text), :space, [], false, []) do
      :error -> []
      words -> words
    end
  end

  @ws ~c" \t\r\n"

  defp psplit([], {:quote, _}, _, _, _), do: :error
  defp psplit([], _, tok, quoted, acc), do: Enum.reverse(pemit(tok, quoted, acc))

  defp psplit([c | rest], state, tok, quoted, acc) when state in [:space, :word] do
    cond do
      c in @ws -> psplit(rest, :space, [], false, pemit(tok, quoted, acc))
      c in [?', ?"] -> psplit(rest, {:quote, c}, tok, true, acc)
      c == ?\\ -> pescape(rest, :word, tok, quoted, acc)
      true -> psplit(rest, :word, [c | tok], quoted, acc)
    end
  end

  defp psplit([q | rest], {:quote, q}, tok, quoted, acc),
    do: psplit(rest, :word, tok, quoted, acc)

  defp psplit([?\\, c | rest], {:quote, ?"} = state, tok, quoted, acc) when c in [?", ?\\],
    do: psplit(rest, state, [c | tok], quoted, acc)

  defp psplit([c | rest], {:quote, _} = state, tok, quoted, acc),
    do: psplit(rest, state, [c | tok], quoted, acc)

  defp pescape([], _, _, _, _), do: :error

  defp pescape([c | rest], state, tok, quoted, acc),
    do: psplit(rest, state, [c | tok], quoted, acc)

  defp pemit([], false, acc), do: acc
  defp pemit(tok, _, acc), do: [tok |> Enum.reverse() |> List.to_string() | acc]

  # ---- Python's shlex.shlex(text, posix=False, punctuation_chars="();<>|&\n"), with
  # whitespace " \t\r" and whitespace_split: shell words and operators, a run of operator
  # characters split into the shell's operators (shlex keeps it whole). Quotes stay on
  # quoted words, so a quoted `'>'` or `'|'` is never read as an operator; :error on
  # unbalanced quotes. As in shlex, `#` at a word's start starts a comment that runs to
  # the end of the line, newline included; unlike it, quotes and escapes are read as the
  # shell reads them: a word's quoted parts are quoted wherever they are (`-e'a;b'`,
  # `x'|'y` is one word), a backslash escapes the next character outside quotes and
  # inside `$'...'` (`a\;b`, `it\'s`) and does not end double quotes (`"a\"b"`), a
  # backslash before a newline continues the line, and `#` inside a word is the word's
  # (`x#y`). Escapes and quotes stay on the word; :error on one left open.

  @punct ~c"();<>|&\n"
  @space ~c" \t\r"
  @quotes ~c"'\""

  @doc false
  def tokens(text), do: lex(String.to_charlist(text), :space, [], [])

  defp lex([], :space, [], acc), do: {:ok, Enum.reverse(acc)}

  defp lex([], state, tok, acc) when state in [:space, :word],
    do: {:ok, Enum.reverse(emit(tok, acc))}

  defp lex([], :punct, tok, acc), do: {:ok, Enum.reverse(emit_ops(tok, acc))}

  defp lex([], {:quote, _}, _, _), do: :error
  defp lex([], :ansi, _, _), do: :error
  defp lex([?\\], _, _, _), do: :error

  defp lex([?\\, ?\n | rest], state, tok, acc) when state in [:space, :word],
    do: lex(rest, state, tok, acc)

  defp lex([?\\, c | rest], state, tok, acc) when state in [:space, :word],
    do: lex(rest, :word, [c, ?\\ | tok], acc)

  defp lex([?$, ?' | rest], state, tok, acc) when state in [:space, :word],
    do: lex(rest, :ansi, [?', ?$ | tok], acc)

  defp lex([c | rest], :space, [], acc) do
    cond do
      c in @space -> lex(rest, :space, [], acc)
      c == ?# -> lex(drop_line(rest), :space, [], acc)
      c in @punct -> lex(rest, :punct, [c], acc)
      c in @quotes -> lex(rest, {:quote, c}, [c], acc)
      true -> lex(rest, :word, [c], acc)
    end
  end

  defp lex([c | rest], :word, tok, acc) do
    cond do
      c in @space -> lex(rest, :space, [], emit(tok, acc))
      c in @punct -> lex([c | rest], :space, [], emit(tok, acc))
      c in @quotes -> lex(rest, {:quote, c}, [c | tok], acc)
      true -> lex(rest, :word, [c | tok], acc)
    end
  end

  defp lex([c | rest], :punct, tok, acc) do
    cond do
      c in @space -> lex(rest, :space, [], emit_ops(tok, acc))
      c == ?# -> lex(drop_line(rest), :punct, tok, acc)
      c in @punct -> lex(rest, :punct, [c | tok], acc)
      true -> lex([c | rest], :space, [], emit_ops(tok, acc))
    end
  end

  defp lex([?\\, c | rest], {:quote, ?"} = state, tok, acc),
    do: lex(rest, state, [c, ?\\ | tok], acc)

  defp lex([?\\, c | rest], :ansi, tok, acc), do: lex(rest, :ansi, [c, ?\\ | tok], acc)
  defp lex([?' | rest], :ansi, tok, acc), do: lex(rest, :word, [?' | tok], acc)
  defp lex([c | rest], :ansi, tok, acc), do: lex(rest, :ansi, [c | tok], acc)

  defp lex([c | rest], {:quote, q}, tok, acc) do
    if c == q,
      do: lex(rest, :word, [c | tok], acc),
      else: lex(rest, {:quote, q}, [c | tok], acc)
  end

  defp emit([], acc), do: acc
  defp emit(tok, acc), do: [tok |> Enum.reverse() |> List.to_string() | acc]

  # A run of operator characters, which shlex keeps as one token, as the shell splits it:
  # longest operator first, so `)>` is `)` then `>`, and `;>` or `&&>` a redirect.
  @operators ~w(&>> <<< ;; && || |& &> >> >| >& << <& <>) ++
               ["<", ">", "|", "&", ";", "(", ")", "\n"]

  defp emit_ops([], acc), do: acc
  defp emit_ops(tok, acc), do: split_ops(tok |> Enum.reverse() |> List.to_string(), acc)

  defp split_ops("", acc), do: acc

  defp split_ops(run, acc) do
    op = Enum.find(@operators, &String.starts_with?(run, &1)) || String.first(run)
    split_ops(binary_part(run, byte_size(op), byte_size(run) - byte_size(op)), [op | acc])
  end

  defp drop_line(chars) do
    case Enum.drop_while(chars, &(&1 != ?\n)) do
      [?\n | rest] -> rest
      [] -> []
    end
  end
end
