# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/microskills/distiller.py, its generic reading (the plugin's)
# only (microsoft/TokenEconomizer@cb42207e3e09). Changed: a pure module over the
# micro-skills' `EnvFacts` state instead of an object reading transcripts: it digests a
# turn's calls, and its facts live beside the environment facts, added through
# `EnvFacts.add_candidate/2` and folded by the same `Lifecycle` on the same clock. The
# model call is the plugin's (`Host.generate/3`, off its process); this builds the prompt
# and admits the reply. A call's failure is read from its exit code where the provider
# gives one, from its output only where it does not. Only the home directory is made
# relative (`~`), as the plugin does not know the repository's root. Regexes the model
# writes run as PCRE, with a match limit, and one that matches past the limit matches
# nothing. A fact's id is a slug, its line passes the micro-skills' lint and holds no
# credential, and a fact a person dropped is named to the model so it is not authored
# again; credential-shaped words are masked in everything the proposer reads or keeps.

defmodule HalC2Plugins.TokenEconomizer.MicroSkills.Distiller do
  @moduledoc """
  The paid proposer: a model that authors repository facts, each with a host-checked
  detector.

  As a project's turns finish, each is folded into a compact digest (files edited,
  command templates, the build, test and lint commands run, the commands that failed
  with a normalized error line, and a few flags -- never raw transcripts or file
  contents). Every few turns one model call reads the latest digests and authors two
  kinds of artifacts:

    * facts -- one declarative line an agent would want stated up front (how the
      project is built or checked here, a setup step it needs), each with a detector:
      regexes or named predicates over a turn's commands and output, which the plugin
      checks on every later turn, so no model runs on the hot path;
    * extractors -- small named predicates over the raw commands and output, which
      surface evidence the digest does not, for a detector to name.

  A fact is admitted only when its detector confirms it on at least #{2} of the turns it
  cites, and enters the shared `Lifecycle` with its history replayed over the window.
  Only a fact's contradiction condition may be revised later; the counters it earned
  stay. A malformed reply admits nothing; a detector that does not compile admits
  nothing.
  """

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{EnvFacts, Lifecycle, Observe}

  # Digests handed to the proposer per call (rolling).
  @window 8
  # Facts admitted per call, at most.
  @max_cands 4
  # Window turns a new fact's detector must confirm.
  @min_cite 2
  # Authored extractors, at most (keeps the digest bounded).
  @max_extractors 12
  # Raw excerpts shown on an abstaining call.
  @raw_sample 3
  # A call abstains when the commands the senses read are less than this share.
  @abstain_gate 0.5
  # Characters of a saved digest's raw commands (twice that of output).
  @blob_cap 20_000
  # Facts' lines and claims, at most.
  @line_cap 400
  # The family proposer facts carry in `EnvFacts`.
  @family "proposer"

  # Guards a regex the model wrote, which runs over a turn's output on every fold.
  @match_opts [{:capture, :none}, {:match_limit, 1_000_000}, {:match_limit_recursion, 100_000}]

  defstruct turns: 0,
            last_propose: -1,
            window: [],
            raw_window: [],
            extractors: %{},
            calls: 0,
            tokens: 0

  def window_size, do: @window
  def max_cands, do: @max_cands
  def min_cite, do: @min_cite
  def max_extractors, do: @max_extractors
  def family, do: @family

  # --- the generic digest ------------------------------------------------------------

  @check_re ~r/\b(?:pytest|py\.test|tox|nox|unittest|runtests\.py|jest|vitest|mocha|rspec|phpunit|ctest|tsc|eslint|prettier|ruff|flake8|pylint|mypy|pyright|golangci-lint|cmake|ninja|bazel)\b|(?:^|[\s;&|(])make\b|\b(?:npm|yarn|pnpm|bun)\s+(?:run\s+)?(?:test|build|lint|check|typecheck)\b|\b(?:cargo|go|mvn|gradle|gradlew|dotnet|mix|swift)\s+(?:test|build|check|vet|clippy|compile|package|verify)\b/u
  @test_re ~r/\b(?:pytest|py\.test|tox|nox|unittest|runtests\.py|jest|vitest|mocha|rspec|phpunit|ctest)\b|\b(?:make|npm|yarn|pnpm|bun|cargo|go|mvn|gradle|gradlew|dotnet|mix|swift|rake)\s+(?:run\s+)?test\b/u
  @missing_cmd_re ~r/command not found|: not found\b|is not recognized as/iu
  @missing_dep_re ~r/ModuleNotFoundError|No module named|ImportError|Cannot find module|ERR_MODULE_NOT_FOUND|cannot find package|could not find (?:package|crate|module|gem)|unresolved import|cannot load such file|undefined reference to|fatal error: [^\n]*: No such file/iu
  @bad_usage_re ~r/^usage:|unrecognized arguments?|no such option|unknown (?:option|flag|command)|invalid option|unexpected argument|error: argument/imu
  @exit_re ~r/\bexit(?:ed with)?(?: code| status)?[:=\s]+(\d+)/iu
  @failed_out_re ~r/Traceback \(most recent call last\)|^\w*Error\b/mu
  @error_line_re ~r/\b(?:error|failed|failure|fatal|exception|traceback|cannot|not found|denied|refused|panic)\b/iu

  # The predicates a detector may name, under the generic reading. The experiments'
  # names read the generic flags too, so a fact naming one keeps a meaning.
  @predicates ~w(ran_checks ran_tests command_failed missing_command missing_dependency bad_usage edited)

  @doc "The predicates a detector may name, in the order the prompt lists them."
  def predicates, do: @predicates

  defp predicate("ran_checks", dg), do: dg["check_commands"] != []
  defp predicate("ran_tests", dg), do: dg["_ran_tests"] == true
  defp predicate("command_failed", dg), do: dg["failed_commands"] != []
  defp predicate("missing_command", dg), do: dg["missing_command"] == true

  defp predicate(name, dg) when name in ["missing_dependency", "importerror"],
    do: dg["missing_dependency"] == true

  defp predicate(name, dg) when name in ["bad_usage", "badarg"], do: dg["bad_usage"] == true
  defp predicate("edited", dg), do: dg["edited_files"] != []
  defp predicate("repro_written", _dg), do: false
  defp predicate(_name, _dg), do: nil

  @doc """
  A turn's shell commands as `{command, output}`, credential-shaped words masked: the
  calls a `bash`, `shell` or `stop_bash` tool ran.
  """
  def commands(calls) do
    for {tool, args, out, code} <- calls,
        String.downcase(tool || "") in ["bash", "shell", "stop_bash"] do
      args = if is_map(args), do: args, else: %{}
      cmd = args["command"] || args["cmd"] || ""
      {Observe.redact(text(cmd)), Observe.redact(text(out)), code}
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  @doc "Whether a command failed: by its exit code when there is one, else by its output."
  def command_failed?(code, _out) when is_integer(code), do: code != 0

  def command_failed?(_code, out) do
    case Regex.run(@exit_re, out) do
      [_, n] ->
        String.to_integer(n) != 0

      _ ->
        Regex.match?(@missing_cmd_re, out) or Regex.match?(@missing_dep_re, out) or
          Regex.match?(@failed_out_re, out)
    end
  end

  @doc """
  The first line of a failing output that names the failure, normalized so two turns
  that fail the same way read the same: the home directory written `~`, then paths,
  numbers and addresses masked; "" when no line does.
  """
  def error_signature(out) do
    (out || "")
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value("", fn line ->
      if Regex.match?(@error_line_re, line) or Regex.match?(@missing_cmd_re, line) do
        line
        |> String.trim()
        |> relative()
        |> then(&Regex.replace(~r/0x[0-9a-fA-F]+/u, &1, "<hex>"))
        |> then(&Regex.replace(~r|(?<![\w.~])/[^\s'"`:,)]+|u, &1, "<path>"))
        |> then(&Regex.replace(~r/\b\d+\b/u, &1, "N"))
        |> String.split()
        |> Enum.join(" ")
        |> String.slice(0, 120)
      end
    end)
  end

  # The home directory written `~`: the same shape on every machine, and no one's
  # paths in a prompt.
  defp relative(text) do
    case System.user_home() do
      home when is_binary(home) and home not in ["", "/"] -> String.replace(text, home, "~")
      _ -> text
    end
  end

  # Command shapes, deduped: whitespace collapsed and long tails cut, so the proposer
  # sees forms.
  defp templates(cmds, cap \\ 12) do
    cmds
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ") |> String.slice(0, 80)))
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  @doc """
  One finished turn's digest: what the proposer reads (keys not starting with `_`) and
  the raw blobs the detectors read, which never reach a prompt.
  """
  def digest(calls, iid) do
    cmds = commands(calls)
    out_blob = Enum.map_join(cmds, "\n", &elem(&1, 1))

    failed =
      cmds
      |> Enum.filter(fn {_c, o, code} -> command_failed?(code, o) end)
      |> Enum.map(fn {c, o, _} ->
        %{"cmd" => List.first(templates([relative(c)], 1), ""), "error" => error_signature(o)}
      end)
      |> Enum.uniq()
      |> Enum.take(6)

    %{
      "iid" => iid,
      "edited_files" => calls |> Observe.edited_files() |> Enum.sort(),
      "n_cmds" => length(cmds),
      "cmd_templates" => templates(Enum.map(cmds, &relative(elem(&1, 0)))),
      "check_commands" =>
        cmds
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&Regex.match?(@check_re, &1))
        |> Enum.map(&relative/1)
        |> templates()
        |> Enum.take(6),
      "failed_commands" => failed,
      "missing_command" => Regex.match?(@missing_cmd_re, out_blob),
      "missing_dependency" => Regex.match?(@missing_dep_re, out_blob),
      "bad_usage" => Regex.match?(@bad_usage_re, out_blob),
      "_ran_tests" => Enum.any?(cmds, &Regex.match?(@test_re, elem(&1, 0))),
      "_cmd_blob" => Enum.map_join(cmds, "\n", &elem(&1, 0)),
      "_out_blob" => out_blob
    }
  end

  # The token-cheap projection the model is shown: no raw blobs.
  defp proposer_view(dg), do: Map.reject(dg, fn {key, _} -> String.starts_with?(key, "_") end)

  # --- regexes the model writes --------------------------------------------------------

  @doc "A regex the model wrote, compiled, or nil when it is empty or does not compile."
  def rx(pattern) when is_binary(pattern) and pattern != "" and byte_size(pattern) <= 2_000 do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> regex
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def rx(_pattern), do: nil

  @doc "Whether `regex` matches `text`; past the match limit, or with no regex, it does not."
  def search?(nil, _text), do: false

  def search?(%Regex{} = regex, text) do
    :re.run(text, regex.re_pattern, @match_opts) == :match
  rescue
    _ -> false
  end

  # --- extractors ----------------------------------------------------------------------

  @extractor_kinds ~w(cmd_regex out_regex cmd_count)

  @doc """
  An authored feature over a turn's `{command, output}` pairs: `cmd_regex` and
  `out_regex` say whether any command (or output) matches, `cmd_count` how many
  commands do.
  """
  def compute(%{"pattern" => pattern} = spec, cmds) do
    kind = spec["kind"] || "cmd_regex"

    case rx(pattern) do
      nil ->
        if kind == "cmd_count", do: 0, else: false

      regex ->
        case kind do
          "out_regex" -> Enum.any?(cmds, fn {_c, o} -> search?(regex, o) end)
          "cmd_count" -> Enum.count(cmds, fn {c, _o} -> search?(regex, c) end)
          _ -> Enum.any?(cmds, fn {c, _o} -> search?(regex, c) end)
        end
    end
  end

  defp featurize(dg, extractors, cmds),
    do:
      Map.put(
        dg,
        "features",
        Map.new(extractors, fn {name, spec} -> {name, compute(spec, cmds)} end)
      )

  # A digest's pairs recovered from its blobs, for features authored after it was folded.
  defp reparse(dg) do
    cmds = String.split(dg["_cmd_blob"] || "", "\n")
    outs = String.split(dg["_out_blob"] || "", "\n")
    outs = outs ++ List.duplicate("", max(length(cmds) - length(outs), 0))
    Enum.zip(cmds, outs)
  end

  # --- the detector ----------------------------------------------------------------------

  @doc """
  A detector's reading of one digest, `{verdict, fired, exercised}`: not exercised when
  its `scope` does not hold; else `"contradict"` when `contradict` matches the turn's
  commands and output, `"confirm"` when `confirm` does, nil otherwise. `scope` and
  `fired` name an extractor's feature, then a predicate, else are a regex over the
  commands; `fired` defaults to `scope`.
  """
  def verdict(detector, dg) do
    features = dg["features"] || %{}
    scope = detector["scope"] || ""
    fired_name = detector["fired"] || scope

    if lookup(scope, dg, features) do
      blob = (dg["_cmd_blob"] || "") <> "\n" <> (dg["_out_blob"] || "")

      cond do
        search?(rx(detector["contradict"]), blob) ->
          {"contradict", true, true}

        search?(rx(detector["confirm"]), blob) ->
          {"confirm", lookup(fired_name, dg, features), true}

        true ->
          {nil, lookup(fired_name, dg, features), true}
      end
    else
      {nil, false, false}
    end
  end

  defp lookup(name, dg, features) do
    cond do
      Map.has_key?(features, name) ->
        truthy?(features[name])

      (value = predicate(name, dg)) != nil ->
        value

      true ->
        search?(rx(name), dg["_cmd_blob"] || "")
    end
  end

  defp truthy?(value), do: value not in [false, nil, 0]

  # --- folding a finished turn in ---------------------------------------------------------

  @doc "Whether `fact` is one the proposer authored."
  def fact?(%EnvFacts.Fact{family: @family}), do: true
  def fact?(_), do: false

  @doc """
  Folds one finished turn into the proposer: its digest joins the window, its commands
  the raw window, and every proposer fact reads it through its detector at the
  micro-skills' clock. Call before `EnvFacts.update_turn/3`, which advances that clock;
  a turn already folded (`iid`) changes nothing.
  """
  def fold(%EnvFacts{} = skills, calls, iid) do
    if iid != nil and iid in skills.folded do
      skills
    else
      proposer = skills.proposer || %__MODULE__{}
      cmds = commands(calls)
      pairs = Enum.map(cmds, fn {c, o, _} -> {c, o} end)

      dg =
        calls
        |> digest(iid)
        |> featurize(proposer.extractors, pairs)
        |> Map.put("_at", skills.now)

      files = MapSet.new(dg["edited_files"])

      facts =
        Map.new(skills.facts, fn
          {id, %EnvFacts.Fact{family: @family} = fact} ->
            {verdict, fired, exercised} = verdict(fact.params["detector"] || %{}, dg)

            {id,
             %{
               fact
               | life: Lifecycle.update(fact.life, skills.now, verdict, fired, exercised, files)
             }}

          other ->
            other
        end)

      proposer = %{
        proposer
        | turns: proposer.turns + 1,
          window: Enum.take(proposer.window ++ [dg], -@window),
          raw_window: Enum.take(proposer.raw_window ++ [Enum.map(pairs, &elem(&1, 0))], -@window)
      }

      %{skills | facts: facts, proposer: proposer}
    end
  end

  @doc "Whether a proposal is due: `every` turns folded since the last, with a window to read."
  def due?(%EnvFacts{proposer: %__MODULE__{} = p}, every),
    do: p.window != [] and p.turns - p.last_propose >= every

  def due?(_skills, _every), do: false

  @doc """
  Marks a proposal made now. It counts as made whatever its answer: a model that keeps
  failing is asked again `every` turns later, never at each fold.
  """
  def proposed(%EnvFacts{proposer: %__MODULE__{} = p} = skills),
    do: %{skills | proposer: %{p | last_propose: p.turns, calls: p.calls + 1}}

  # --- the prompt ------------------------------------------------------------------------

  @head "You mine a DURABLE, REPO-SPECIFIC operating manual for a coding agent from a " <>
          "window of finished-session digests in ONE repository, whatever its language and " <>
          "toolchain. Each digest lists the files edited, command templates (paths relative to " <>
          "the repository), the build, test and lint commands run, the commands that failed " <>
          "with a normalized error line, and boolean flags — NOT raw logs or file contents. " <>
          "(Each session is called a task below.)\n\n" <>
          "Emit facts that a FUTURE session in this repository would want stated up front to " <>
          "avoid wasted commands: how to build, run or check it here and the exact invocation " <>
          "that works; the toolchain (interpreter, package manager, compiler, version manager) " <>
          "and how it is reached; a setup, install, code-generation or rebuild step that is " <>
          "needed (or NOT needed); an environment variable, service or working directory a " <>
          "command needs; where generated, configured or vendored files live; a command that " <>
          "fails here and the variant that works; a hook or formatter that rewrites files. " <>
          "Tests are one such topic, not the focus. Do NOT emit task-specific fixes or which " <>
          "lines to change — only durable facts true across sessions.\n\n"

  @rules "For EACH fact return an object with:\n" <>
           "  id          short kebab slug\n" <>
           "  claim       one sentence, what is true about this repo\n" <>
           "  injection   the exact line to inject into the agent prefix. State it as a " <>
           "DECLARATIVE fact about the repo (where things are, what the canonical command is). " <>
           "NEVER phrase it as a prohibition on exploration or tool use — do NOT tell the agent " <>
           "to avoid `find`/`grep`/searching/reading, or to skip discovering files. A prior " <>
           "that suppresses exploration silently breaks later tasks on a growing codebase where " <>
           "the agent must discover accreted files. State what is true; never forbid a tool.\n" <>
           "  high_stakes true if a wrong belief would break the run (test cmd, build step)\n" <>
           "  detector    {scope, confirm, contradict?, fired?} where scope is a python " <>
           "regex over the command string (or one of: PREDICATES) " <>
           "selecting tasks where the fact is RELEVANT; confirm is a regex whose " <>
           "match in commands+output means the fact HELD this task; contradict (optional) a " <>
           "regex meaning the fact was FALSE this task; fired (optional) a predicate/regex " <>
           "meaning the waste the fact prevents actually occurred.\n" <>
           "  cite        list of >=2 iids from the window where confirm matches (grounding)\n\n" <>
           "Return ONLY a JSON list of <=#{@max_cands} such objects. Be conservative: a fact you cannot " <>
           "ground with a working detector + 2 citations is worse than no fact." <>
           "\n\nADDITIONALLY: if a durable repo fact would need evidence NOT present in " <>
           "the digest flags, first author an EXTRACTOR that surfaces it, then reference the " <>
           "extractor's feature name as your detector scope/fired. Extractors are cheap " <>
           "host-run predicates over raw commands/outputs.\n" <>
           "Return a JSON OBJECT: {\"extractors\": [{name, kind, pattern}], \"facts\": [...]}\n" <>
           "  extractor.kind in {cmd_regex, out_regex, cmd_count}; pattern is a python regex.\n" <>
           "  A fact's detector.scope/fired may name any extractor you define here or a " <>
           "built-in (PREDICATES)." <>
           "\n\nREVISION: the CONTRADICTION condition of an existing note may be corrected — " <>
           "and nothing else. Re-emit a note with the SAME id and the SAME " <>
           "claim/injection/high_stakes and the SAME detector.scope/detector.confirm/detector.fired, " <>
           "changing ONLY detector.contradict, to fix or tighten the regex that marks the fact " <>
           "FALSE this task. The note KEEPS its earned firing history and the new condition applies " <>
           "going forward. Re-emitting an id while changing any other field is rejected; extractors " <>
           "remain append-only."

  @doc "The proposer's instructions: upstream's generic system prompt."
  def system_prompt,
    do: @head <> String.replace(@rules, "PREDICATES", Enum.join(@predicates, ", "))

  @doc """
  The prompt for one proposal over `skills`' window: the existing proposer facts as
  `id: claim`, the extractors, the digests, raw excerpts the senses do not cover when
  most commands are unread, the environment facts already staged, and the ids a
  person dropped. The plugin asks for it in one JSON key, `payload`.
  """
  def prompt(%EnvFacts{proposer: %__MODULE__{} = p} = skills, repo) do
    proposer_facts = skills.facts |> Map.values() |> Enum.filter(&fact?/1)

    existing =
      proposer_facts
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&"  - #{&1.id}: #{&1.params["claim"]}")

    excerpts =
      if abstaining?(p), do: p |> abstaining_excerpts() |> Enum.take(@raw_sample), else: []

    external =
      skills |> EnvFacts.injectable_claims() |> Enum.reject(&(&1 == ""))

    prompt =
      system_prompt() <>
        "\n\nRepo: #{repo}" <>
        "\n\nExisting facts, as `id: claim` (do NOT restate or paraphrase one under a " <>
        "NEW id; re-emit an id with ONLY detector.contradict changed to revise its " <>
        "contradiction condition, else use a NEW id for a fact not listed here):\n" <>
        if(existing == [], do: "(none)", else: Enum.join(existing, "\n")) <>
        "\n\nExisting feature names:\n" <>
        if(map_size(p.extractors) == 0,
          do: "(none)",
          else: p.extractors |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        ) <>
        "\n\nTask digests (chronological):\n" <>
        JSON.encode!(Enum.map(p.window, &proposer_view/1))

    prompt =
      if excerpts == [],
        do: prompt,
        else:
          prompt <>
            "\n\nRAW command excerpts from recent tasks the current extractors did " <>
            "NOT cover (author extractors to reach these if they hide a durable " <>
            "fact):\n" <> Enum.map_join(excerpts, "\n", &"  $ #{&1}")

    prompt =
      if external == [],
        do: prompt,
        else:
          prompt <>
            "\n\nFacts ALREADY injected before every task by a separate layer (do NOT " <>
            "restate or paraphrase them; author only facts beyond these):\n" <>
            Enum.map_join(external, "\n", &"  - #{&1}")

    dropped = skills.dropped |> MapSet.to_list() |> Enum.reject(&String.contains?(&1, ":"))

    prompt =
      if dropped == [],
        do: prompt,
        else:
          prompt <>
            "\n\nFact ids a person removed (do NOT author them again, under these ids " <>
            "or new ones): " <> Enum.join(Enum.sort(dropped), ", ")

    prompt <>
      "\n\nReturn the JSON object {extractors, facts} as the string value of the one key " <>
      "\"payload\" of a JSON object."
  end

  # Does a built-in sense already read this command?
  defp sensed?(cmd), do: Regex.match?(@check_re, cmd)

  defp covered?(p, cmd) do
    sensed?(cmd) or
      Enum.any?(p.extractors, fn {_name, spec} -> search?(rx(spec["pattern"]), cmd) end)
  end

  defp coverage(_p, []), do: 1.0
  defp coverage(p, cmds), do: Enum.count(cmds, &covered?(p, &1)) / length(cmds)

  defp abstaining?(%__MODULE__{raw_window: []}), do: false

  defp abstaining?(p) do
    cov = Enum.map(p.raw_window, &coverage(p, &1))
    Enum.sum(cov) / length(cov) < @abstain_gate
  end

  defp abstaining_excerpts(p) do
    p.raw_window
    |> Enum.concat()
    |> Enum.reject(&covered?(p, &1))
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ") |> String.slice(0, 100)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@raw_sample * 4)
  end

  # --- the reply ---------------------------------------------------------------------------

  @doc """
  The extractors and facts a reply holds, `{extractors, facts}`: the outermost JSON
  object in it, keeping extractors with a name and a pattern and facts with an id and
  a detector. Anything else is nothing.
  """
  def parse_payload(raw) when is_binary(raw) do
    with [object] <- Regex.run(~r/\{.*\}/s, raw),
         {:ok, %{} = obj} <- JSON.decode(object) do
      extractors =
        for e <- list(obj["extractors"]),
            is_map(e) and is_binary(e["name"]) and e["name"] != "" and is_binary(e["pattern"]) and
              e["pattern"] != "",
            do: e

      facts =
        for f <- list(obj["facts"]),
            is_map(f) and is_binary(f["id"]) and f["id"] != "" and is_map(f["detector"]) and
              map_size(f["detector"]) > 0,
            do: f

      {extractors, facts}
    else
      _ -> {[], []}
    end
  end

  def parse_payload(_raw), do: {[], []}

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  @doc """
  Admits what a reply authored, against the window as it is now: extractors first
  (append-only), then at most #{@max_cands} facts. `{skills, outcomes}`, an outcome per
  item, `{:extractor | :fact, name, reason}` with reason `"admitted"`, `"revised"` or why
  it was refused.
  """
  def admit(%EnvFacts{proposer: %__MODULE__{}} = skills, raw) do
    {extractors, facts} = parse_payload(raw)

    {skills, outcomes} =
      Enum.reduce(extractors, {skills, []}, fn spec, {skills, outcomes} ->
        {skills, reason} = admit_extractor(skills, spec)
        {skills, [{:extractor, spec["name"], reason} | outcomes]}
      end)

    {skills, outcomes} =
      facts
      |> Enum.take(@max_cands)
      |> Enum.reduce({skills, outcomes}, fn spec, {skills, outcomes} ->
        {skills, reason} = admit_fact(skills, spec)
        {skills, [{:fact, spec["id"], reason} | outcomes]}
      end)

    {skills, Enum.reverse(outcomes)}
  end

  def admit(skills, _raw), do: {skills, []}

  @doc "A proposal's spend, from `Host.generate/3`'s usage: input and output tokens."
  # `cachedInputTokens` is a part of `inputTokens`, not more of them.
  def tokens(usage) when is_map(usage),
    do: Enum.sum(for key <- ~w(inputTokens outputTokens), is_number(usage[key]), do: usage[key])

  def tokens(_usage), do: 0

  @doc "Adds a proposal's token spend to the project's own count."
  def spent(%EnvFacts{proposer: %__MODULE__{} = p} = skills, tokens) when is_number(tokens),
    do: %{skills | proposer: %{p | tokens: p.tokens + tokens}}

  def spent(skills, _tokens), do: skills

  @name_re ~r/^[A-Za-z][A-Za-z0-9_]{0,63}$/

  defp admit_extractor(%EnvFacts{proposer: p} = skills, spec) do
    kind = spec["kind"] || "cmd_regex"
    name = spec["name"]

    cond do
      Map.has_key?(p.extractors, name) ->
        {skills, "exists"}

      map_size(p.extractors) >= @max_extractors ->
        {skills, "full"}

      not Regex.match?(@name_re, name) ->
        {skills, "bad-name"}

      kind not in @extractor_kinds ->
        {skills, "bad-kind"}

      rx(spec["pattern"]) == nil ->
        {skills, "bad-regex"}

      Observe.secret_value?(spec["pattern"]) ->
        {skills, "secret"}

      true ->
        spec = %{"name" => name, "kind" => kind, "pattern" => spec["pattern"]}

        # The window is featurized again, so a fact of the same reply can name it.
        window =
          Enum.map(p.window, fn dg ->
            Map.update(
              dg,
              "features",
              %{name => compute(spec, reparse(dg))},
              &Map.put(&1, name, compute(spec, reparse(dg)))
            )
          end)

        {%{
           skills
           | proposer: %{p | extractors: Map.put(p.extractors, name, spec), window: window}
         }, "admitted"}
    end
  end

  @id_re ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/
  @detector_keys ~w(scope confirm contradict fired)

  # A fact as it is kept: its lines (the claim defaults to the id, the injection to the
  # claim), whether it is high stakes, and its detector's string fields. Its citations
  # are read once, at admission.
  defp normalize(spec) do
    claim = string(spec["claim"]) || spec["id"]

    detector =
      for {key, value} <- spec["detector"],
          key in @detector_keys and is_binary(value) and value != "",
          into: %{},
          do: {key, value}

    %{
      "id" => spec["id"],
      "claim" => claim,
      "injection" => string(spec["injection"]) || claim,
      "high_stakes" => spec["high_stakes"] == true,
      "detector" => detector
    }
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  # What a fact's detector names: an extractor's feature, a predicate, else a regex that
  # must compile. Every regex it carries must compile too.
  defp detector_ok?(detector, extractors) do
    named = fn name ->
      Map.has_key?(extractors, name) or name in @predicates or
        name in ~w(importerror badarg repro_written) or rx(name) != nil
    end

    Map.has_key?(detector, "scope") and Map.has_key?(detector, "confirm") and
      named.(detector["scope"]) and named.(Map.get(detector, "fired", detector["scope"])) and
      Enum.all?(
        ~w(confirm contradict),
        &(not Map.has_key?(detector, &1) or rx(detector[&1]) != nil)
      )
  end

  defp lines_ok?(fact) do
    Enum.all?([fact["claim"], fact["injection"]], fn line ->
      String.length(line) <= @line_cap and not String.contains?(line, ["\n", "\r"]) and
        EnvFacts.lint_ok?(line)
    end)
  end

  defp leaks?(fact) do
    [fact["id"], fact["claim"], fact["injection"] | Map.values(fact["detector"])]
    |> Enum.any?(&Observe.secret_value?/1)
  end

  defp admit_fact(%EnvFacts{} = skills, spec) do
    fact = normalize(spec)
    id = fact["id"]

    cond do
      not Regex.match?(@id_re, id) ->
        {skills, "bad-id"}

      MapSet.member?(skills.dropped, id) ->
        {skills, "dropped"}

      Map.has_key?(skills.facts, id) ->
        revise(skills, skills.facts[id], fact)

      not detector_ok?(fact["detector"], skills.proposer.extractors) ->
        {skills, "bad-detector"}

      not lines_ok?(fact) ->
        {skills, "lint"}

      leaks?(fact) ->
        {skills, "secret"}

      (hits = ground(skills, fact["detector"], spec["cite"])) < @min_cite ->
        {skills, "grounding-fail(#{hits}/#{@min_cite})"}

      true ->
        params = %{
          "claim" => fact["claim"],
          "injection" => fact["injection"],
          "detector" => fact["detector"],
          "rev" => 1
        }

        skills =
          EnvFacts.add_candidate(skills, %{
            id: id,
            family: @family,
            high: fact["high_stakes"],
            drift: true,
            params: params
          })

        # It enters with the history its detector reads in the window, at each turn's
        # own place on the clock.
        life =
          Enum.reduce(skills.proposer.window, skills.facts[id].life, fn dg, life ->
            {verdict, fired, exercised} = verdict(fact["detector"], dg)

            Lifecycle.update(
              life,
              dg["_at"] || 0,
              verdict,
              fired,
              exercised,
              MapSet.new(dg["edited_files"] || [])
            )
          end)

        {put_in(skills.facts[id].life, life), "admitted"}
    end
  end

  @doc "How many of `cite`'s window turns the detector confirms, under the current features."
  def ground(%EnvFacts{proposer: p}, detector, cite) do
    by_iid = Map.new(p.window, &{&1["iid"], &1})

    cite
    |> list()
    |> Enum.uniq()
    |> Enum.count(fn iid ->
      case by_iid[iid] do
        nil -> false
        dg -> match?({"confirm", _, _}, verdict(detector, dg))
      end
    end)
  end

  # Only the contradiction condition of a fact may change, and only to a regex that
  # compiles: it can only ever retire the fact, so revising it earns nothing, and the
  # counters stay.
  defp revise(skills, %EnvFacts.Fact{family: @family} = old, fact) do
    frozen = fn claim, injection, high, detector ->
      {claim, injection, high, Map.delete(detector, "contradict")}
    end

    old_detector = old.params["detector"] || %{}
    new_contra = fact["detector"]["contradict"]

    cond do
      frozen.(fact["claim"], fact["injection"], fact["high_stakes"], fact["detector"]) !=
          frozen.(old.params["claim"], old.params["injection"], old.life.high, old_detector) ->
        {skills, "revise-not-contradict-only"}

      new_contra != nil and rx(new_contra) == nil ->
        {skills, "revise-bad-regex"}

      new_contra != nil and Observe.secret_value?(new_contra) ->
        {skills, "secret"}

      new_contra == old_detector["contradict"] ->
        {skills, "revise-noop"}

      true ->
        detector =
          if new_contra,
            do: Map.put(old_detector, "contradict", new_contra),
            else: Map.delete(old_detector, "contradict")

        params =
          old.params
          |> Map.put("detector", detector)
          |> Map.put("rev", (old.params["rev"] || 1) + 1)

        {put_in(skills.facts[old.id].params, params), "revised"}
    end
  end

  defp revise(skills, _old, _fact), do: {skills, "exists"}

  # --- persistence ---------------------------------------------------------------------------

  @doc "The proposer's bookkeeping as JSON-shaped maps, its digests' raw blobs capped."
  def dump(%__MODULE__{} = p) do
    %{
      "turns" => p.turns,
      "lastPropose" => p.last_propose,
      "calls" => p.calls,
      "tokens" => p.tokens,
      "extractors" => p.extractors,
      "window" =>
        Enum.map(p.window, fn dg ->
          dg
          |> Map.update("_cmd_blob", "", &String.slice(&1, -@blob_cap, @blob_cap))
          |> Map.update("_out_blob", "", &String.slice(&1, -2 * @blob_cap, 2 * @blob_cap))
        end),
      "rawCmds" => p.raw_window
    }
  end

  def dump(nil), do: nil

  @doc "The bookkeeping read back from `dump/1`; nil when there is none."
  def load(%{} = saved) do
    extractors =
      for {name, %{"pattern" => pattern} = spec} <- map(saved["extractors"]),
          is_binary(name) and is_binary(pattern),
          into: %{},
          do: {name, spec}

    %__MODULE__{
      turns: int(saved["turns"], 0),
      last_propose: int(saved["lastPropose"], -1),
      calls: int(saved["calls"], 0),
      tokens: if(is_number(saved["tokens"]), do: saved["tokens"], else: 0),
      extractors: extractors,
      window:
        saved["window"]
        |> list()
        |> Enum.filter(
          &(is_map(&1) and is_binary(&1["_cmd_blob"]) and is_binary(&1["_out_blob"]))
        )
        |> Enum.take(-@window),
      raw_window:
        saved["rawCmds"]
        |> list()
        |> Enum.map(fn cmds -> cmds |> list() |> Enum.filter(&is_binary/1) end)
        |> Enum.take(-@window)
    }
  end

  def load(_saved), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp int(value, _default) when is_integer(value), do: value
  defp int(_value, default), do: default
end
