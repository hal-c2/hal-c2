# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/shell_edits.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: Python's `shlex` (non-POSIX, with punctuation
# characters) is reimplemented here, quirks included, so commands split as upstream's do,
# but for a run of operators (`)>`), split as the shell splits it; `fold_shell_edits` lives
# in State; a heredoc ends where the shell's does, its delimiter any word (`<<'EOF-CODE'`,
# `<<123`), and every heredoc a line opens is read; `dd`, `sponge`, `cp`, `mv`, `install`
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
  # A heredoc: `<<` or `<<-`, then its delimiter, any word, quoted in whole or part or
  # not (`<<'EOF-CODE'`, `<<"E"OF`, `<<\EOF`, `<<123`); not a here-string (`<<<`).
  @heredoc_start ~r/(?<!<)<<(-?)[ \t]*((?:'[^'\n]*'|"(?:\\.|[^"\\\n])*"|\\.|[^\s'"<>|&;()\\])+)/
  @ops ["&&", "||", ";", ";;", "|", "|&", "&", "\n", "(", ")"]
  # Redirects that write their operand.
  @out [">", ">>", ">|", "&>", "&>>"]
  # Programs that run another, given after their own words, and the programs this reads
  # writes off, which a wrapper is unwrapped to.
  @wrappers ~w(sudo doas command env time nohup timeout nice ionice stdbuf chronic flock xargs find)
  @writers ~w(sed perl awk gawk tee dd sponge truncate cp mv install patch git apply_patch eval) ++
             @shells
  # The operands `find -exec` and `xargs -I` put file names in place of.
  @fed ["{}", "+", ";", "\\"]
  # Input, heredoc tags, fd duplication.
  @skip_operand ["<", "<<", "<<<", "<&", ">&", "<>"]
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

  # A word without its quotes, whole (`'a.py'`) or in part (`a'.py'`, `-e's/a/b/'`).
  defp unquote_word(t), do: Regex.replace(~r/'([^']*)'|"((?:\\.|[^"\\])*)"/, t, "\\1\\2")

  @doc """
  The command's shell text without heredoc bodies, and the bodies: every heredoc a line
  opens (`cat <<A <<B`), read in order. A body ends only at its delimiter alone on a line
  (after leading tabs, for `<<-`), as the shell's does; one never ended runs to the end. A
  line continued with a backslash is one line, and its heredocs start after it.
  """
  def split_heredocs(cmd) do
    {shell, bodies} = shell_lines(String.split(cmd, "\n"), [], [])
    {shell |> Enum.reverse() |> Enum.join("\n"), Enum.reverse(bodies)}
  end

  defp shell_lines([], shell, bodies), do: {shell, bodies}

  defp shell_lines(lines, shell, bodies) do
    {line, rest} = logical_line(lines)

    docs =
      for [_, dash, word] <- Regex.scan(@heredoc_start, line),
          do: {dash == "-", Regex.replace(~r/\\(.)|['"]/, word, "\\1")}

    {bodies, rest} = read_bodies(docs, rest, bodies)
    shell_lines(rest, [line | shell], bodies)
  end

  defp logical_line([line | rest]) do
    if rest != [] and Regex.match?(~r/(?<!\\)(?:\\\\)*\\$/, line) do
      {next, rest} = logical_line(rest)
      {binary_part(line, 0, byte_size(line) - 1) <> next, rest}
    else
      {line, rest}
    end
  end

  defp read_bodies([], lines, bodies), do: {bodies, lines}

  defp read_bodies([{dash, tag} | docs], lines, bodies) do
    ends? = fn line -> if(dash, do: String.trim_leading(line, "\t"), else: line) == tag end
    {body, rest} = Enum.split_while(lines, &(not ends?.(&1)))
    read_bodies(docs, Enum.drop(rest, 1), [Enum.join(body, "\n") | bodies])
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

    writes =
      case rest do
        [next | _] when next not in @ops ->
          # `>& file` writes it, as `&>` does; `>&2` and `>&-` only duplicate or close.
          if t in @out or (t == ">&" and not Regex.match?(~r/^(?:\d+|-)$/, next)),
            do: writes ++ [unquote_word(next)],
            else: writes

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

  # Each command as the program it runs: the `VAR=1` before it dropped, a wrapper's
  # (`sudo -u me`, `timeout 10`, `xargs`, `find ... -exec`) words up to the editor it
  # runs, and git's global options (`git -C repo`); empty ones left out.
  defp bare(cmds), do: cmds |> Enum.map(&unwrap/1) |> Enum.reject(&(&1 == []))

  defp unwrap(tokens) do
    case Enum.drop_while(tokens, &Regex.match?(~r/^\w+=/, &1)) do
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
  the command itself.
  """
  def script(cmd) when is_binary(cmd) do
    case posix_split(cmd) do
      [shell, "-" <> flags, script | _] ->
        if State.basename(shell) in @shells and String.contains?(flags, "c"),
          do: script,
          else: cmd

      _ ->
        cmd
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
  # unbalanced quotes. As in shlex, `#` starts a comment that runs to the end of the
  # line, newline included, and a quote inside a word is part of the word.

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
      # A comment inside a word drops the rest of the line and the word goes on.
      c == ?# -> lex(drop_line(rest), :word, tok, acc)
      c in @punct -> lex([c | rest], :space, [], emit(tok, acc))
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

  defp lex([c | rest], {:quote, q}, tok, acc) do
    if c == q,
      do: lex(rest, :space, [], emit([c | tok], acc)),
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
