# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported in part from tokeneconomizer/microskills/observe.py and
# tokeneconomizer/microskills/lifecycle.py (`edited_files`), with `strip_rtk_prefix`
# from tokeneconomizer/trace/calls.py (microsoft/TokenEconomizer@cb42207e3e09).
# Changed: a turn's calls come from the MC as they end (`{name, args, output,
# exit_code}`), not from a transcript file, so there is no per-call directory to
# read: a `cd` inside one command still shapes its forms, but a directory an
# earlier call left the shell in is not known here. Only upstream's generic
# vocabulary -- the reading the plugin uses -- is ported; the experiments'
# Python/git and Node vocabularies are not. Review on the port also fixed
# readings upstream shares: `yarn run`/`pnpm run` reach the package-script
# handler, an `exec` launcher keeps its subcommand, an environment value is
# learned whole or not at all, an unknown exit status is no success, and a
# probe is empty only on genuinely empty output.

defmodule HalC2Plugins.TokenEconomizer.MicroSkills.Observe do
  @moduledoc """
  What a finished turn shows about its environment: classified commands and
  outcomes.

  Each shell command is split into segments, and each segment classified by
  intent (run the interpreter, run the tests, use the package tool, fetch from
  a host, probe the VCS) and form (how it was spelled: `python -m pytest`,
  `/opt/env/bin/python -m pytest`, `cd tests && python runtests.py`). Its
  outcome is read off the output as an environmental error class
  (`module_missing`, `command_missing`, `connection_refused`, ...) or a sign
  that tests ran. `observe_turn/1` returns everything the environment-fact
  families need from one turn: observations with outcomes, the files it
  edited (by basename), what it said about environment variables, and the
  call count. Nothing here keeps file contents: an observation is a form, an
  intent and short outcome facts.
  """

  # The generic vocabulary: every ecosystem at once, since a repository a
  # person works in may mix them.
  @interpreters ~w(python python2 python3 pypy pypy3 node nodejs deno bun tsx ts-node
                   ruby perl php Rscript julia lua elixir)
  @runner_heads ~w(pytest py.test tox nox nosetests trial jest vitest mocha playwright
                   cypress ava karma rspec phpunit ctest bats)
  @runner_scripts ["runtests.py", "bin/test", "bin/doctest", "manage.py"]
  @runner_modules ~w(pytest unittest nose django tox nox)
  @package_tools ~w(pip pip3 conda mamba poetry pipenv uv apt apt-get npm yarn pnpm
                    corepack gem bundle composer cargo go mvn gradle dotnet brew rustup
                    pyenv nvm asdf)
  @fetch_heads ~w(curl wget)
  @env_probe_heads ~w(which command type whereis)
  @task_heads ~w(make npm yarn pnpm cargo go mvn gradle gradlew dotnet mix swift rake)
  @build_heads ~w(make cmake ninja bazel tsc eslint prettier ruff flake8 pylint mypy
                  pyright black isort golangci-lint gcc g++ clang javac webpack vite
                  pre-commit shellcheck)
  @build_subs ~w(build check compile lint vet typecheck type-check clippy package
                 verify fmt format)
  @run_script_heads ~w(npm yarn pnpm bun)
  @git_fetch_subs ~w(fetch clone pull ls-remote)
  @git_probe_subs ~w(remote branch tag fsck stash show-ref for-each-ref)
  @prefix_heads ~w(sudo env time exec nice nohup timeout)
  @passthrough ~w(cd echo head tail cat sort uniq tee true printf less more)

  @activate_re ~r/^(?:source|\.)\s+\S*activate\s+([\w.-]+)\s*$/
  @cd_re ~r/^cd\s+(['"]?)([^\s;&|'"]+)\1\s*$/
  @cd_failed_re ~r/\bcd: [^\n]*: (?:No such file or directory|Not a directory)/
  @conda_activate_re ~r/^(?:conda|mamba)\s+activate\s+([\w.-]+)\s*$/
  @conda_run_re ~r/^(?:conda|mamba)\s+run\s+(?:--no-capture-output\s+|--live-stream\s+)*(?:-n|--name)\s+([\w.-]+)\s+/
  # `yarn run`/`pnpm run` are package scripts, not launchers: only their
  # `exec` unwraps, so the script handler still sees the run. The subcommand
  # as typed is kept: `bundle exec rspec` is not `bundle run rspec`.
  @tool_run_re ~r/^(poetry|pipenv|uv|npx|bundle)\s+(run|exec)\s+/
  @tool_exec_re ~r/^(yarn|pnpm)\s+(exec)\s+/
  @npx_re ~r/^npx\s+(?:(?:--yes|-y|--no-install|--no)\s+)*/
  @tool_launch_re ~r/^(uvx|uv\s+tool\s+run|pipx\s+run)\s+/
  @interp_versioned_re ~r/^(?:python|node)\d(?:\.\d+)?$/
  @env_assign_re ~r/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)+/
  @assign_token_re ~r/^[A-Za-z_][A-Za-z0-9_]*=/
  @wrap_re ~r|^/bin/(?:ba)?sh\s+-l?c\s+(.*)$|s
  @heredoc_re ~r|<<-?\s*['"]?(\w+)['"]?[^\n]*\n.*?\n\s*\1\b|s
  # The host and port a URL names. Its userinfo (`alice:secret@`) is left out:
  # a learned host is shown and staged, and a credential must not be.
  @url_host_re ~r|https?://(?:[^/\s'"`@]*@)?([^/\s'"`@]+)|
  # Variables whose values are credentials: never learned, so never staged.
  @secret_var_re ~r/TOKEN|SECRET|PASSW|PASSPHRASE|CREDENTIAL|AUTH|API_?KEY|PRIVATE|COOKIE|SESSION/
  @rtk_prefix_re ~r/^rtk\s+(?:proxy\s+)?(?=\S)/

  # Error classes an environment produces, in upstream's order: first match wins.
  @error_classes [
    {"module_missing",
     ~r/ModuleNotFoundError|No module named|Cannot find module|ERR_MODULE_NOT_FOUND/i},
    {"command_missing", ~r/command not found|: not found\b|is not recognized/i},
    {"script_missing", ~r/can't open file .*No such file or directory/i},
    {"permission_denied", ~r/Permission denied|EACCES/i},
    {"usage_error",
     ~r/(?m)^usage:|unrecognized arguments|no such option|error: argument|unknown option/i},
    {"connection_refused",
     ~r/Connection refused|Failed to connect to|couldn't connect to|Could not connect|ECONNREFUSED/i},
    {"name_resolution",
     ~r/Could not resolve host|Temporary failure in name resolution|Name or service not known|getaddrinfo|nodename nor servname|ENOTFOUND/i},
    {"unreachable",
     ~r/Network is unreachable|No route to host|Connection timed out|Operation timed out|timed out after|ETIMEDOUT/i}
  ]
  @network_errors ~w(connection_refused name_resolution unreachable)
  @form_errors ~w(module_missing command_missing script_missing usage_error permission_denied)

  @not_found_name_re ~r/([^\s:'"]+):\s+(?:command\s+)?not found\b(?!:)|command not found:\s+(\S+)|'([^']+)' is not recognized/i

  # What "the probe returned something" looks like, per VCS probe kind:
  # `git remote` names a remote per line (with `-v`, name, URL and direction),
  # `git branch -r`/`-a` a remote branch as `origin/name`, and `git tag
  # --contains` one tag name per line, version-shaped or not.
  @probe_hit %{
    "remote" => ~r/(?m)^\S+(?:\s+\S+\s+\((?:fetch|push)\))?\s*$/,
    "branch" => ~r/(?m)^\s*\*?\s*(?:remotes\/)?\S+\/\S+/,
    "tag" => ~r/(?m)^\S+\s*$/,
    "fsck" => ~r/(?m)^(?:unreachable|dangling)\s+(?:commit|tree|blob|tag)\s+[0-9a-f]{7,}/,
    "stash" => ~r/(?m)^stash@\{\d+\}/,
    "refs" => ~r/(?m)^[0-9a-f]{7,}\s+refs\//
  }

  @label_err_re ~r/Failed to import test module|unittest\.loader\._FailedTest|ERROR: (?:file or directory )?not found|no tests ran|module '[\w.]+' has no attribute/i
  @no_module_re ~r/No module named ['"]?([\w.]+)/
  @loaded_re ~r/\bRan [1-9]\d* tests?\b|\b[1-9]\d* (?:passed|failed|passing|failing)\b|\bcollected [1-9]\d* items?\b/
  @loaded_generic_re ~r/(?m)^ok\s+\S+\s+[\d.]+s\b|^--- (?:PASS|FAIL)\b|\btest result: (?:ok|FAILED)\b|\b[1-9]\d* examples?, \d+ failures?\b|\b(?:Passed|Failed)!\s+-|\bTests run: [1-9]\d*/
  @env_need_re ~r/environment variable\s+['"`]?([A-Z][A-Z0-9_]{2,})/
  # The value must end at a boundary: `APP_SETTINGS=conf.dev,conf.extra` is
  # not the assignment `APP_SETTINGS=conf.dev`, and its prefix never ran.
  @env_prefix_re ~r/(?:^|[\s;&(])(?:export\s+)?([A-Z][A-Z0-9_]{2,})=(['"]?)([\w.\-\/:]+)\2(?=$|[\s;&|])/
  @launcher_re ~r/^(?:conda|poetry|pipenv|uv|npx|uvx|bundle|yarn|pnpm|pipx)\s+(?:run|exec)\b/
  @env_incode_re ~r/os\.environ(?:\.setdefault\(\s*|\[\s*)['"]([A-Z][A-Z0-9_]{2,})['"]\s*(?:,|\]\s*=)\s*['"]([\w.\-\/:]+)['"]/
  @failed_re ~r/(?m)Traceback \(most recent call last\)|^\w*Error\b|\b[Ee]xit [Cc]ode[:=\s]+[1-9]/
  @label_token_re ~r/^[A-Za-z_][\w.\-\/]*(?:::[\w.\-\[\]]+)*$/

  @doc "The error classes a network produces."
  def network_errors, do: @network_errors
  @doc "The error classes that say the way a command was called fails here."
  def form_errors, do: @form_errors

  defp observation(call, intent, form, head, segment, opts \\ []) do
    %{
      call: call,
      intent: intent,
      form: form,
      head: head,
      segment: segment,
      hosts: Keyword.get(opts, :hosts, []),
      probe: Keyword.get(opts, :probe),
      outcome: nil,
      labels: [],
      label_err: false,
      loaded: false,
      tests_ran: false,
      # Typed with `VAR=value` before it, which its form leaves out.
      env: false,
      # The "command not found" line names this command, not one it started.
      not_found: false
    }
  end

  # --- command reading ------------------------------------------------------------

  @doc "Strip an agent's `/bin/bash -lc \"<cmd>\"` wrapper, if present."
  def unwrap(cmd) do
    cmd = cmd || ""

    case Regex.run(@wrap_re, String.trim(cmd)) do
      [_, inner] ->
        inner = String.trim(inner)

        if String.length(inner) >= 2 and String.first(inner) == String.last(inner) and
             String.first(inner) in ["\"", "'"] do
          quote = String.first(inner)
          inner = String.slice(inner, 1, String.length(inner) - 2)

          if quote == "\"" do
            inner
            |> String.replace("\\\"", "\"")
            |> String.replace("\\$", "$")
            |> String.replace("\\\\", "\\")
          else
            inner
          end
        else
          inner
        end

      _ ->
        cmd
    end
  end

  @doc """
  Split a shell command into simple segments on `&&`, `||`, `;`, `|` and
  newlines, outside quotes. Heredoc bodies are elided first so their contents
  are never mistaken for commands.
  """
  def segments(cmd) do
    cmd =
      Regex.replace(@heredoc_re, cmd || "", fn whole, _tag ->
        hd(String.split(whole, "\n", parts: 2)) <> " <heredoc>"
      end)

    chars = cmd |> String.graphemes() |> List.to_tuple()
    next = fn i -> if i + 1 < tuple_size(chars), do: elem(chars, i + 1) end

    {out, {buf, _quote, _skip}} =
      chars
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce({[], {[], nil, false}}, fn {char, i}, {out, {buf, quote, skip}} ->
        cond do
          skip ->
            {out, {buf, quote, false}}

          quote != nil ->
            buf = [char | buf]

            cond do
              char == quote -> {out, {buf, nil, false}}
              char == "\\" and next.(i) != nil -> {out, {[next.(i) | buf], quote, true}}
              true -> {out, {buf, quote, false}}
            end

          char in ["\"", "'"] ->
            {out, {[char | buf], char, false}}

          char in ["\n", ";", "|"] or (char == "&" and next.(i) == "&") ->
            {[buf | out], {[], nil, (char <> (next.(i) || "")) in ["&&", "||"]}}

          true ->
            {out, {[char | buf], quote, false}}
        end
      end)

    [buf | out]
    |> Enum.reverse()
    |> Enum.map(fn rev -> rev |> Enum.reverse() |> Enum.join() end)
    |> Enum.map(&(&1 |> String.trim() |> String.trim("()") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "`rtk pytest -q` becomes `pytest -q`; anything else is unchanged."
  def strip_rtk_prefix(command) do
    Regex.replace(@rtk_prefix_re, String.trim_leading(command || ""), "", global: false)
  end

  # Where `cd target` from `cur` (relative to where the command started) lands,
  # relative to that start; nil when it leaves it or cannot be told. Without the
  # session's directory (the MC does not give one per call), an absolute target
  # is taken as typed, as upstream takes it when no root is known.
  defp cd_target(_cur, target)
       when target in [nil, ""] or binary_part(target, 0, 1) in ["~", "$", "-"],
       do: nil

  defp cd_target(cur, target) do
    if String.starts_with?(target, "/") do
      nil
    else
      rel = normpath(join_rel(cur || ".", target))

      cond do
        rel == "." -> ""
        rel == ".." or String.starts_with?(rel, "../") -> nil
        true -> rel
      end
    end
  end

  defp join_rel(".", target), do: target
  defp join_rel(cur, target), do: cur <> "/" <> target

  defp normpath(path) do
    parts =
      path
      |> String.split("/")
      |> Enum.reduce([], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] -> [".."]
        "..", [".." | _] = acc -> [".." | acc]
        "..", [_ | rest] -> rest
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()

    case parts do
      [] -> "."
      _ -> Enum.join(parts, "/")
    end
  end

  @doc """
  Observations for one shell command (possibly compound). Activation prefixes
  and directory changes carry across the segments of one command, which is how
  `source activate X && python ...` and `cd tests && python runtests.py`
  become single forms.
  """
  def classify_command(cmd, call_index \\ 0) do
    {obs, _carried, _here, _cd} =
      cmd
      |> unwrap()
      |> segments()
      |> Enum.reduce({[], "", "", ""}, fn seg, {obs, carried, here, cd} ->
        # Transparent wrappers first: `K=V rtk pytest`, `rtk K=V pytest` and
        # `rtk proxy pytest` are all a pytest run.
        typed = String.trim(seg)
        stripped = typed |> strip_env_assigns() |> String.trim()
        assigned = stripped != typed
        unwrapped = stripped |> strip_rtk_prefix() |> String.trim()
        seg = unwrapped |> strip_env_assigns() |> String.trim()
        assigned = assigned or seg != unwrapped

        cond do
          seg == "" ->
            {obs, carried, here, cd}

          match = Regex.run(@cd_re, seg) ->
            target = Enum.at(match, 2)

            case here != nil && cd_target(here, target) do
              nil -> {obs, carried, nil, "cd #{target} &&"}
              false -> {obs, carried, nil, "cd #{target} &&"}
              there -> {obs, carried, there, if(there == "", do: "", else: "cd #{there} &&")}
            end

          match = Regex.run(@activate_re, seg) || Regex.run(@conda_activate_re, seg) ->
            name = Enum.at(match, 1)

            carried =
              if String.starts_with?(seg, ["conda", "mamba"]),
                do: "conda activate #{name} &&",
                else: "source activate #{name} &&"

            {obs, carried, here, cd}

          true ->
            prefix = Enum.join(Enum.reject([cd, carried], &(&1 == "")), " ")
            {prefix, body} = prefixed(prefix, seg)
            {toks, assigned} = drop_prefix_heads(String.split(body), assigned)

            case toks do
              [] ->
                {obs, carried, here, cd}

              [head | rest] ->
                base = basename(head)

                case classify(head, base, rest, body, prefix, seg, call_index) do
                  nil -> {obs, carried, here, cd}
                  o -> {obs ++ [%{o | env: assigned}], carried, here, cd}
                end
            end
        end
      end)

    obs
  end

  defp strip_env_assigns(text), do: Regex.replace(@env_assign_re, text, "", global: false)

  # `conda run -n X cmd`, `poetry run cmd`, `npx cmd`, `uvx cmd`: the launcher
  # is part of the form, the command that follows names the intent.
  defp prefixed(prefix, body) do
    join = fn extra -> if prefix == "", do: extra, else: prefix <> " " <> extra end

    cond do
      match = Regex.run(@conda_run_re, body) ->
        {join.("conda run -n #{Enum.at(match, 1)}"), strip_match(body, hd(match))}

      match = Regex.run(@tool_run_re, body) || Regex.run(@tool_exec_re, body) ->
        {join.("#{Enum.at(match, 1)} #{Enum.at(match, 2)}"), strip_match(body, hd(match))}

      match = Regex.run(@npx_re, body) ->
        if hd(match) == "" do
          tool_launched(prefix, body, join)
        else
          {join.("npx"), strip_match(body, hd(match))}
        end

      true ->
        tool_launched(prefix, body, join)
    end
  end

  defp tool_launched(prefix, body, join) do
    case Regex.run(@tool_launch_re, body) do
      [whole, launcher] ->
        {join.(if(String.starts_with?(launcher, "pipx"), do: "pipx run", else: "uvx")),
         strip_match(body, whole)}

      _ ->
        {prefix, body}
    end
  end

  defp strip_match(body, whole),
    do: binary_part(body, byte_size(whole), byte_size(body) - byte_size(whole))

  defp drop_prefix_heads([], assigned), do: {[], assigned}

  defp drop_prefix_heads([head | rest] = toks, assigned) do
    cond do
      Regex.match?(@assign_token_re, head) -> drop_prefix_heads(rest, true)
      head == "timeout" -> drop_prefix_heads(Enum.drop(rest, 1), assigned)
      head in @prefix_heads -> drop_prefix_heads(rest, assigned)
      true -> {toks, assigned}
    end
  end

  defp runner_script(rest) do
    case Enum.find(rest, &(not String.starts_with?(&1, "-"))) do
      nil ->
        nil

      token ->
        Enum.find_value(@runner_scripts, fn script ->
          if token == script or String.ends_with?(token, "/" <> script) or
               String.ends_with?(token, script) do
            if String.starts_with?(token, "./"),
              do: binary_part(token, 2, byte_size(token) - 2),
              else: token
          end
        end)
    end
  end

  defp classify(head, base, rest, body, prefix, seg, call) do
    form = fn expr -> if prefix == "", do: expr, else: prefix <> " " <> expr end

    cond do
      # `bun run test:unit` is a package script, as `npm run test:unit` is, not
      # the interpreter running a file.
      (base in @interpreters or Regex.match?(@interp_versioned_re, base)) and
          not package_script?(base, rest) ->
        cond do
          rest != [] and Enum.all?(rest, &(&1 in ["--version", "-V", "-VV", "-v"])) ->
            observation(call, "probe_env", form.(head), head, seg)

          "-m" in rest ->
            mod = Enum.at(rest, Enum.find_index(rest, &(&1 == "-m")) + 1) || ""

            cond do
              mod in @runner_modules ->
                observation(call, "run_tests", form.("#{head} -m #{mod}"), head, seg)

              # `python -m mypy` runs the checker itself, not the interpreter.
              mod in @build_heads ->
                observation(call, "run_build", form.("#{head} -m #{mod}"), head, seg)

              true ->
                interpreter_or_script(call, head, rest, form, seg)
            end

          true ->
            interpreter_or_script(call, head, rest, form, seg)
        end

      base in @runner_heads ->
        observation(call, "run_tests", form.(head), head, seg)

      # A script run through its shebang keeps the spelling that ran it: its
      # interpreter is the shebang's, which may not be Python at all.
      direct_runner_script(head, rest) ->
        observation(call, "run_tests", form.(head), head, seg)

      base in @task_heads and hd(rest ++ [nil]) == "test" ->
        observation(call, "run_tests", form.("#{head} test"), head, seg)

      base in @run_script_heads and length(rest) > 1 and hd(rest) == "run" ->
        script = Enum.at(rest, 1)
        kind = script |> String.split(":", parts: 2) |> hd()

        cond do
          kind == "test" ->
            observation(call, "run_tests", form.("#{head} run #{script}"), head, seg)

          kind in @build_subs ->
            observation(call, "run_build", form.("#{head} run #{script}"), head, seg)

          true ->
            classify_rest(call, head, base, rest, body, form, seg)
        end

      base in @task_heads and hd(rest ++ [nil]) in @build_subs ->
        observation(call, "run_build", form.("#{head} #{hd(rest)}"), head, seg)

      base in @build_heads ->
        observation(call, "run_build", form.(head), head, seg)

      true ->
        classify_rest(call, head, base, rest, body, form, seg)
    end
  end

  # A package script that runs the tests or a build: `npm run build`, `bun run test:unit`.
  defp package_script?(base, ["run", script | _]) when base in @run_script_heads,
    do: (script |> String.split(":", parts: 2) |> hd()) in ["test" | @build_subs]

  defp package_script?(_base, _rest), do: false

  defp interpreter_or_script(call, head, rest, form, seg) do
    script = runner_script(rest)

    if script && (script != "manage.py" or "test" in rest) do
      observation(call, "run_tests", form.("#{head} #{script}"), head, seg)
    else
      observation(call, "run_interpreter", form.(head), head, seg)
    end
  end

  # The head itself is a runner script, unless it is `manage.py` not running tests.
  defp direct_runner_script(head, rest) do
    Enum.find_value(@runner_scripts, fn script ->
      if head == script or String.ends_with?(head, "/" <> script) or head == "./" <> script do
        if script == "manage.py" and "test" not in rest, do: nil, else: head
      end
    end)
  end

  defp classify_rest(call, head, base, rest, body, form, seg) do
    cond do
      base in @env_probe_heads ->
        observation(call, "probe_env", form.(base), head, seg)

      base in @fetch_heads ->
        observation(call, "fetch_remote", form.(base), head, seg, hosts: hosts(body))

      base == "git" and rest != [] ->
        sub = hd(rest)

        cond do
          sub in @git_fetch_subs ->
            observation(call, "fetch_remote", form.("git #{sub}"), head, seg, hosts: hosts(body))

          sub in @git_probe_subs ->
            case probe_kind(sub, tl(rest)) do
              nil ->
                nil

              kind ->
                observation(call, "probe_vcs_refs", form.("git #{sub}"), head, seg, probe: kind)
            end

          true ->
            nil
        end

      base in @package_tools ->
        if String.starts_with?(base, ["pip", "npm", "yarn", "pnpm"]) and
             hd(rest ++ [nil]) in ["install", "download", "add", "ci"] do
          observation(call, "fetch_remote", form.("#{base} #{hd(rest)}"), head, seg,
            hosts: hosts(body)
          )
        else
          observation(call, "package_tool", form.(head), head, seg)
        end

      true ->
        nil
    end
  end

  defp hosts(body) do
    @url_host_re |> Regex.scan(body) |> Enum.map(fn [_, host] -> host end)
  end

  # `git remote` and its listings read the remotes; `set-url`, `add` and the
  # rest change them and print nothing either way.
  defp probe_kind("remote", args)
       when args in [[], ["-v"], ["--verbose"], ["show"]],
       do: "remote"

  defp probe_kind("remote", _args), do: nil

  defp probe_kind("branch", args) do
    if Enum.any?(args, &(&1 in ["-a", "-r", "--all", "--remotes", "-ar", "-ra"])),
      do: "branch"
  end

  # A plain `git tag` lists past tags too: not a beyond-HEAD probe.
  defp probe_kind("tag", args), do: if("--contains" in args, do: "tag")
  defp probe_kind("fsck", _args), do: "fsck"
  defp probe_kind("stash", ["list" | _]), do: "stash"
  defp probe_kind(sub, _args) when sub in ["show-ref", "for-each-ref"], do: "refs"
  defp probe_kind(_sub, _args), do: nil

  defp basename(path), do: path |> String.replace("\\", "/") |> String.split("/") |> List.last()

  # --- outcomes ---------------------------------------------------------------------

  @doc "The environmental error class an output shows, or nil."
  def error_class(output) do
    Enum.find_value(@error_classes, fn {name, re} ->
      if Regex.match?(re, output || ""), do: name
    end)
  end

  defp exit_code_hint(output) do
    case Regex.run(~r/\bexit code[:=\s]+(\d+)/i, output || "") do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  # Did the runner fail to load one of these labels? Either it says so, or the
  # module it cannot import is the label's own -- a missing `pytest` is not.
  @doc false
  def label_failed(labels, out) do
    out = out || ""

    if Regex.match?(@label_err_re, out) do
      true
    else
      heads =
        MapSet.new(labels, fn label -> label |> String.split(~r/[.\/:]/, parts: 2) |> hd() end)

      @no_module_re
      |> Regex.scan(out)
      |> Enum.any?(fn [_, mod] -> hd(String.split(mod, ".")) in heads end)
    end
  end

  @doc """
  The test labels a runner observation was given: positional arguments after
  the runner's own token that look like a module, a path or a test id. A plain
  name right after an option is taken to be that option's value (`-k name`),
  so it is not a label.
  """
  def test_labels(o) do
    toks = String.split(o.segment)
    last = o.form |> String.split() |> List.last("")

    start =
      case Enum.find_index(toks, fn token ->
             token == last or Regex.replace(~r/^[.\/]+/, token, "") == last or
               String.ends_with?(token, "/" <> last)
           end) do
        nil -> length(toks)
        i -> i + 1
      end

    {labels, _skip, _prev} =
      toks
      |> Enum.drop(start)
      |> Enum.reduce({[], false, ""}, fn token, {out, skip, prev} ->
        cond do
          skip ->
            {out, false, token}

          token in [">", ">>", "2>", "<", "|"] or
              String.starts_with?(token, ["2>", ">", "<", "|"]) ->
            {out, token in [">", ">>", "2>", "<"], token}

          true ->
            structured = Enum.any?([".", "::", "/"], &String.contains?(token, &1))
            after_option = String.starts_with?(prev, "-") and not String.contains?(prev, "=")

            if not String.starts_with?(token, "-") and Regex.match?(@label_token_re, token) and
                 (structured or not after_option) do
              {out ++ [token], false, token}
            else
              {out, false, token}
            end
        end
      end)

    labels
  end

  @doc """
  `{"sep", "::"}` or `{"strip", prefix}` when label `b` is label `a` rewritten
  into the shape the runner loads, else nil.
  """
  def label_rule(a, b) do
    sep =
      if String.contains?(a, "::") and not String.contains?(b, "::") do
        dotted = String.replace(a, "::", ".")

        if b == dotted or String.starts_with?(dotted, b <> ".") or
             String.starts_with?(b, dotted <> ".") do
          {"sep", "::"}
        end
      end

    sep ||
      Enum.find_value([".", "/"], fn separator ->
        if String.contains?(a, separator) do
          prefix = hd(String.split(a, separator, parts: 2)) <> separator
          rest = binary_part(a, byte_size(prefix), byte_size(a) - byte_size(prefix))

          if rest != "" and not String.starts_with?(b, prefix) and
               (b == rest or String.starts_with?(rest, b <> separator) or
                  String.starts_with?(b, rest <> separator)) do
            {"strip", prefix}
          end
        end
      end)
  end

  # What one call says about environment variables: those its output asks for,
  # and those its command sets (inline, exported or in the code it runs).
  defp env_calls(cmd, out, success) do
    sets =
      @env_prefix_re
      |> Regex.scan(assignments(cmd))
      |> Map.new(fn [_, var, _quote, value] -> {var, value} end)

    sets =
      @env_incode_re
      |> Regex.scan(cmd)
      |> Enum.reduce(sets, fn [_, var, value], acc -> Map.put(acc, var, value) end)

    %{
      need:
        @env_need_re
        |> Regex.scan(out || "")
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.reject(&secret_var?/1)
        |> Enum.uniq()
        |> Enum.sort(),
      sets: Map.reject(sets, fn {var, _} -> secret_var?(var) end),
      ok: success == true and not Regex.match?(@failed_re, out || "")
    }
  end

  defp secret_var?(var), do: Regex.match?(@secret_var_re, var)

  # The assignments a command makes: each segment's leading `K=V`s, after an
  # `export` or `env` and around an `rtk`. Text that only looks like one, as
  # in `echo K=V` or a string in the code a command runs, sets nothing.
  defp assignments(cmd) do
    cmd
    |> unwrap()
    |> segments()
    |> Enum.map_join(" ", fn seg ->
      seg = Regex.replace(~r/^(?:export|env)\s+/, String.trim(seg), "") <> " "
      first = leading_assigns(seg)
      rest = seg |> binary_part(byte_size(first), byte_size(seg) - byte_size(first))
      first <> leading_assigns(strip_rtk_prefix(rest) <> " ")
    end)
  end

  defp leading_assigns(text) do
    case Regex.run(@env_assign_re, text) do
      [block] -> block
      nil -> ""
    end
  end

  @doc """
  Did this run show that the way the command was called fails here? Not when
  the runner started and rejected what it was given: a label it could not load
  or an option it does not take is a mistake in the arguments.
  """
  def form_failed(o) do
    o.outcome in @form_errors and not o.label_err and
      not (o.intent == "run_tests" and o.outcome == "usage_error")
  end

  @doc """
  Did this run show the form works? A test run must show tests running: one
  whose output was filtered away or that stopped before any test proves nothing.
  """
  def form_worked(o), do: o.outcome == "ran" and (o.intent != "run_tests" or o.tests_ran)

  @doc "A form with no activation prefix and no explicit path is bare."
  def bare?(form) do
    head = form |> String.split() |> List.first("")

    not String.contains?(head, "/") and not String.contains?(form, " activate ") and
      not String.contains?(form, " run ") and not String.contains?(form, " exec ") and
      not Regex.match?(@launcher_re, form) and
      not String.starts_with?(form, ["npx ", "uvx "])
  end

  @doc "Every file an edit tool wrote, by basename, whatever its language."
  def edited_files(calls) do
    files =
      Enum.reduce(calls, MapSet.new(), fn {tool, args, _out, _code}, acc ->
        args = if is_map(args), do: args, else: %{}

        cond do
          String.downcase(tool || "") in [
            "edit",
            "multiedit",
            "write",
            "create",
            "str_replace_editor"
          ] ->
            case args["file_path"] || args["path"] || "" do
              "" -> acc
              path -> MapSet.put(acc, basename(path))
            end

          String.downcase(tool || "") == "apply_patch" ->
            Enum.reduce(args["paths"] || [], acc, &MapSet.put(&2, basename(&1)))

          true ->
            acc
        end
      end)

    MapSet.to_list(files)
  end

  # --- one turn -----------------------------------------------------------------------

  @doc """
  A turn's digest from its calls, `[{name, args, output, exit_code}]` as the
  plugin folds them (`exit_code` nil when the provider gave none and the
  command's exit status would not cover it): observations with outcomes, the
  edited files, what its calls said about environment variables, and the call
  count.

  Outcome attribution inside a compound command is heuristic and conservative,
  as upstream's: an infrastructure error is attributed to the segment whose
  executable the error names, else to the last relevant segment; a call that
  succeeded marks every relevant segment as having run; a failed call with no
  infrastructure error marks only the first relevant segment as having run and
  leaves the others unknown (an `&&` chain may not have reached them).
  """
  def observe_turn(calls) do
    {obs_all, env} =
      calls
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{name, args, out, code}, idx}, {obs_all, env} ->
        tool = String.downcase(name || "")

        if tool in ["shell", "bash", "stop_bash"] do
          args = if is_map(args), do: args, else: %{}
          cmd = args["command"] || args["cmd"] || ""
          out = out || ""

          if Regex.match?(@cd_failed_re, out) do
            # Stopped at its `cd`: nothing after it ran.
            {obs_all, env}
          else
            obs = classify_command(cmd, idx)
            hint = exit_code_hint(out)
            # An unknown status (a pipe hid it) is no evidence of success.
            ok = code == 0
            success = if hint == nil, do: ok, else: hint == 0

            env =
              case env_calls(cmd, out, success) do
                %{need: [], sets: sets} when map_size(sets) == 0 -> env
                entry -> env ++ [Map.put(entry, :call, idx)]
              end

            if obs == [] do
              {obs_all, env}
            else
              {obs_all ++ outcomes(obs, cmd, out, success), env}
            end
          end
        else
          {obs_all, env}
        end
      end)

    %{
      obs: obs_all,
      edited: calls |> edited_files() |> Enum.sort(),
      n_calls: length(calls),
      env: env
    }
  end

  defp outcomes(obs, cmd, out, success) do
    obs =
      Enum.map(obs, fn o ->
        if o.intent == "run_tests" do
          labels = test_labels(o)
          label_err = labels != [] and label_failed(labels, out)

          tests_ran =
            Regex.match?(@loaded_re, out) or Regex.match?(@loaded_generic_re, out)

          %{
            o
            | labels: labels,
              label_err: label_err,
              tests_ran: tests_ran,
              loaded: labels != [] and not label_err and tests_ran
          }
        else
          o
        end
      end)

    # Pass-through segments (a leading `cd`, a trailing `| head`) neither add
    # evidence nor pollute the output, so they do not break a call's
    # homogeneity; filters that rewrite content (grep, sed) do.
    n_seg =
      Enum.count(segments(unwrap(cmd)), fn seg ->
        first = seg |> String.split() |> List.first("")
        basename(first) not in @passthrough
      end)

    homogeneous = n_seg == length(obs) and length(Enum.uniq(Enum.map(obs, & &1.intent))) == 1
    err = error_class(out)

    obs =
      cond do
        err in @form_errors or err in @network_errors ->
          attribute_error(obs, err, out, success)

        success ->
          Enum.map(obs, &%{&1 | outcome: "ran"})

        true ->
          {obs, _first} =
            Enum.map_reduce(obs, true, fn o, first ->
              if o.intent in [
                   "run_interpreter",
                   "run_tests",
                   "run_build",
                   "package_tool",
                   "fetch_remote"
                 ] do
                {%{o | outcome: if(first, do: "ran")}, false}
              else
                {%{o | outcome: if(o.intent != "probe_vcs_refs", do: "ran")}, first}
              end
            end)

          obs
      end

    Enum.map(obs, fn o ->
      o =
        if o.intent == "probe_vcs_refs" do
          # Judged only when every segment is a probe: another segment's output
          # would otherwise be read as the probe's.
          # Empty is genuinely empty output from a call that exited 0;
          # output in no recognized shape says nothing either way.
          outcome =
            cond do
              not homogeneous -> nil
              String.trim(out) == "" -> if success, do: "empty"
              Regex.match?(@probe_hit[o.probe], out) -> "hit"
              true -> nil
            end

          %{o | outcome: outcome}
        else
          o
        end

      if o.intent == "fetch_remote" and o.outcome == "ran" and
           (not homogeneous or not success or String.trim(out) == "" or
              err in @network_errors) do
        # Reachability needs a homogeneous call that exited 0 with real output.
        %{o | outcome: nil}
      else
        o
      end
    end)
  end

  defp attribute_error(obs, err, out, success) do
    targets =
      Enum.filter(
        obs,
        &(&1.intent in [
            "run_interpreter",
            "run_tests",
            "run_build",
            "package_tool",
            "fetch_remote"
          ])
      )

    line = error_line(out, err)

    named =
      Enum.filter(targets, fn o ->
        (o.head != "" and String.contains?(out, o.head)) or
          (o.head != "" and String.contains?(line, basename(o.head)))
      end)

    named =
      if err in @network_errors do
        fetches = Enum.filter(targets, &(&1.intent == "fetch_remote"))

        Enum.filter(fetches, fn o ->
          o.hosts == [] or Enum.any?(o.hosts, &String.contains?(out, &1))
        end)
        |> case do
          [] -> fetches
          some -> some
        end
      else
        named
      end

    chosen =
      cond do
        named != [] -> named
        not success -> Enum.take(targets, -1)
        true -> []
      end

    missing = if err == "command_missing", do: not_found_name(line), else: ""
    chosen_calls = MapSet.new(Enum.map(chosen, & &1.segment))

    Enum.map(obs, fn o ->
      cond do
        o in chosen or (chosen != [] and o.segment in chosen_calls and o in targets) ->
          %{o | outcome: err, not_found: missing != "" and basename(o.head) == missing}

        success and o.outcome == nil ->
          %{o | outcome: "ran"}

        true ->
          o
      end
    end)
  end

  defp error_line(out, err) do
    re = Map.new(@error_classes)[err]

    case Regex.run(re, out, return: :index) do
      [{start, len} | _] ->
        line_start =
          case :binary.matches(binary_part(out, 0, start), "\n") do
            [] -> 0
            matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
          end

        rest = binary_part(out, line_start, byte_size(out) - line_start)
        _ = len
        rest |> String.split("\n", parts: 2) |> hd()

      _ ->
        ""
    end
  end

  # The command a "not found" line says is missing, by its last path part.
  defp not_found_name(line) do
    case Regex.run(@not_found_name_re, line || "") do
      nil -> ""
      [_ | groups] -> groups |> Enum.find(&(&1 not in [nil, ""])) |> Kernel.||("") |> basename()
    end
  end
end
