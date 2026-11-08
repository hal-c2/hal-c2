# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/shell_edits.py (microsoft/TokenEconomizer@cb42207e3e09),
# into Elixir for HAL-C2's MC. Changed: Python's `shlex` (non-POSIX, with punctuation
# characters) is reimplemented here, quirks included, so commands split as upstream's do;
# `fold_shell_edits` lives in State; a heredoc's delimiter may be any word (`<<'EOF-CODE'`),
# not only an identifier; `programs/1` is new.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.ShellEdits do
  @moduledoc """
  Edits made through the shell, which an edit-tool counter does not see.

  An agent that edits through Bash (`sed -i`, `perl -pi`, a redirect or `tee` into a
  source file, an inline Python script that writes the file back, `patch` or `git apply`,
  Codex's `apply_patch` fed a patch on stdin) would otherwise look like one that edited
  nothing, and a judge reading the digest would be told no file had been edited when four
  had. `targets/1` reads those writes off the command; `State.fold_shell_edits/2` counts
  them after the regular update, so the call still counts once.
  """

  alias HalC2Plugins.TokenEconomizer.LoopGuard.State

  @shells ~w(sh bash zsh dash ksh)
  # A heredoc's delimiter, quoted (`<<'EOF-CODE'`, `<<"END"`) or not (`<<EOF`, `<<\EOF`);
  # not a here-string (`<<<`).
  @heredoc_start ~r/(?<!<)<<-?\s*(?:'([^'\n]+)'|"([^"\n]+)"|\\?([A-Za-z_][^\s'"<>|&;()]*))/
  @ops ["&&", "||", ";", ";;", "|", "|&", "&", "\n", "(", ")"]
  # Redirects that write their operand.
  @out [">", ">>", ">|", "&>", "&>>"]
  # Input, heredoc tags, fd duplication.
  @skip_operand ["<", "<<", "<<<", "<&", ">&", "<>"]
  # Redirect and `tee` targets count only when they look like source, so `> out.log` or
  # `| tee /tmp/run.txt`, capturing output, is not mistaken for an edit.
  @source_file ~r/\.(?:py|pyi|pyx|pxd|js|jsx|mjs|cjs|ts|tsx|rs|go|java|kt|kts|scala|c|cc|cpp|cxx|h|hh|hpp|rb|php|cs|swift|m|mm|sh|bash|zsh|lua|jl|ex|exs|erl|hs|ml|clj|sql|toml|ya?ml|json|cfg|ini|conf|md|rst|html?|css|scss|vue|svelte|xml|gradle|properties|in)$/i
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
    cmd = script(cmd)

    if String.trim(cmd) == "" do
      []
    else
      {shell, bodies} = split_heredocs(cmd)
      {cmds, writes} = commands(shell)
      found = Enum.filter(writes, &Regex.match?(@source_file, &1))

      found =
        Enum.reduce(bare(cmds), found, fn tokens, found ->
          found ++ written_by(head(tokens), tokens, bodies)
        end)

      found =
        if Regex.match?(@python, shell),
          do: found ++ py_writes(Enum.join([shell | bodies], "\n")),
          else: found

      found
      |> Enum.filter(&(String.starts_with?(&1, "(") or not_scratch(&1)))
      |> Enum.map(&if(String.starts_with?(&1, "("), do: &1, else: State.basename(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  def targets(_), do: []

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
      inplace_files(
        tokens,
        &Regex.match?(~r/^(?:-[a-zA-Z]*i|--in-place)/, &1),
        &(&1 in ["-e", "-f", "--expression", "--file"])
      )

  defp written_by("perl", tokens, _),
    do:
      inplace_files(
        tokens,
        &Regex.match?(~r/^-[a-zA-Z]*i/, &1),
        &Regex.match?(~r/^-[a-zA-Z]*e$/, &1)
      )

  defp written_by("tee", [_ | args], _),
    do: Enum.filter(args, &(not String.starts_with?(&1, "-") and Regex.match?(@source_file, &1)))

  defp written_by("apply_patch", [_ | args], bodies) do
    text = Enum.join(bodies ++ [Enum.join(args, " ")], "\n")

    case Regex.scan(@patch_file, text, capture: :all_but_first) do
      [] -> ["(patch)"]
      found -> Enum.map(found, &hd/1)
    end
  end

  defp written_by("patch", _, _), do: ["(patch)"]
  defp written_by("git", [_, "apply" | _], _), do: ["(patch)"]
  defp written_by(_, tokens, _), do: restored(tokens)

  defp head([first | _]), do: first |> String.split("/") |> List.last()

  defp not_scratch(path),
    do: path != "" and not String.starts_with?(path, ["/dev/", "/proc/", "/tmp/"])

  defp unquote_word(t) do
    size = byte_size(t)

    if size >= 2 and binary_part(t, 0, 1) == binary_part(t, size - 1, 1) and
         binary_part(t, 0, 1) in ["'", "\""],
       do: binary_part(t, 1, size - 2),
       else: t
  end

  @doc "The command's shell text without heredoc bodies, and the bodies."
  def split_heredocs(cmd) do
    {shell, bodies, tag, body} =
      cmd
      |> String.split("\n")
      |> Enum.reduce({[], [], nil, []}, fn
        line, {shell, bodies, nil, []} ->
          tag =
            case Regex.run(@heredoc_start, line) do
              [_ | tags] -> Enum.find(tags, &(&1 != ""))
              nil -> nil
            end

          {[line | shell], bodies, tag, []}

        line, {shell, bodies, tag, body} ->
          if String.trim(line) == tag,
            do: {shell, [Enum.join(Enum.reverse(body), "\n") | bodies], nil, []},
            else: {shell, bodies, tag, [line | body]}
      end)

    bodies = if tag, do: [Enum.join(Enum.reverse(body), "\n") | bodies], else: bodies
    {shell |> Enum.reverse() |> Enum.join("\n"), Enum.reverse(bodies)}
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
        [next | _] when t in @out and next not in @ops -> writes ++ [unquote_word(next)]
        _ -> writes
      end

    simple(Enum.drop(rest, 1), cmds, writes, cur)
  end

  defp simple([t | rest], cmds, writes, cur),
    do: simple(rest, cmds, writes, [unquote_word(t) | cur])

  # File operands of an in-place editor (`sed -i`, `perl -pi`), or [] if not in place.
  defp inplace_files([_ | args], inplace?, script_flag?) do
    if Enum.any?(args, inplace?) do
      {files, _, _} =
        Enum.reduce(args, {[], false, false}, fn t, {files, have_script, skip} ->
          cond do
            skip ->
              {files, true, false}

            t == "" or String.starts_with?(t, "-") ->
              {files, have_script, t != "" and script_flag?.(t)}

            # The first operand is the script.
            not have_script ->
              {files, true, false}

            true ->
              {[t | files], have_script, false}
          end
        end)

      Enum.reverse(files)
    else
      []
    end
  end

  # Paths an inline Python script writes; "(script)" for a write whose path this cannot
  # resolve.
  defp py_writes(text) do
    lit =
      for [_, _, path, _, mode] <- Regex.scan(@py_open_lit, text), writes?(mode), do: path

    vars = for [_, var, _, mode] <- Regex.scan(@py_open_var, text), writes?(mode), do: var
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

  defp writes?(mode), do: String.contains?(mode, ["w", "a", "x", "+"])

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

  # Each command with the `sudo`, `env`, `VAR=1` ... before it dropped; empty ones left out.
  defp bare(cmds) do
    cmds
    |> Enum.map(fn tokens ->
      Enum.drop_while(
        tokens,
        &(&1 in ~w(sudo command env time nohup) or Regex.match?(~r/^\w+=/, &1))
      )
    end)
    |> Enum.reject(&(&1 == []))
  end

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
  # whitespace " \t\r" and whitespace_split: shell words and operators. Quotes stay on
  # quoted words, so a quoted `'>'` or `'|'` is never read as an operator; :error on
  # unbalanced quotes. As in shlex, `#` starts a comment that runs to the end of the
  # line, newline included, and a quote inside a word is part of the word.

  @punct ~c"();<>|&\n"
  @space ~c" \t\r"
  @quotes ~c"'\""

  @doc false
  def tokens(text), do: lex(String.to_charlist(text), :space, [], [])

  defp lex([], :space, [], acc), do: {:ok, Enum.reverse(acc)}

  defp lex([], state, tok, acc) when state in [:space, :word, :punct],
    do: {:ok, Enum.reverse(emit(tok, acc))}

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
      c in @space -> lex(rest, :space, [], emit(tok, acc))
      c == ?# -> lex(drop_line(rest), :punct, tok, acc)
      c in @punct -> lex(rest, :punct, [c | tok], acc)
      true -> lex([c | rest], :space, [], emit(tok, acc))
    end
  end

  defp lex([c | rest], {:quote, q}, tok, acc) do
    if c == q,
      do: lex(rest, :space, [], emit([c | tok], acc)),
      else: lex(rest, {:quote, q}, [c | tok], acc)
  end

  defp emit([], acc), do: acc
  defp emit(tok, acc), do: [tok |> Enum.reverse() |> List.to_string() | acc]

  defp drop_line(chars) do
    case Enum.drop_while(chars, &(&1 != ?\n)) do
      [?\n | rest] -> rest
      [] -> []
    end
  end
end
