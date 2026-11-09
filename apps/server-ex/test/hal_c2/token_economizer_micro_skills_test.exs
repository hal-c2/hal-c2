# SPDX-License-Identifier: Apache-2.0
# Ported in part from tests/test_envfacts.py, tests/test_envfacts_args.py and
# tests/test_generic_microskills.py (microsoft/TokenEconomizer@cb42207e3e09).
# Changed: a turn's calls are given as the plugin folds them,
# `{name, args, output, exit_code}`, not as transcript files; only the generic
# reading is ported, so the experiment vocabularies' cases and the per-call
# directory cases (the MC gives no directory per call) are left out, as are
# the distiller's (a later part of the port).

for file <- ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerMicroSkillsTest do
  @moduledoc """
  TokenEconomizer's micro-skills (`plugins/token-economizer/mc/micro_skills_*`),
  as plain functions: facts form from recurring evidence, fire only while the
  waste recurs, and abstain where the evidence says otherwise. The plugin
  process and the MC are covered by
  `features/plugins/token-economizer-micro-skills.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{EnvFacts, Lifecycle, Observe}

  @base "/opt/env/base/bin/python"
  @proj "/opt/env/proj/bin/python"
  @ok "Ran 4 tests in 0.1s\n\nOK"

  # --- helpers --------------------------------------------------------------------------

  defp bash(command, output, code), do: {"Bash", %{"command" => command}, output, code}

  defp edit(path),
    do: {"Edit", %{"file_path" => path, "old_string" => "a", "new_string" => "b"}, "ok", nil}

  # Renders before each turn, as staging does, and folds each in: the state and
  # the block each turn was given.
  defp stream(tasks, state \\ EnvFacts.new()) do
    {rendered, state} =
      Enum.map_reduce(tasks, state, fn calls, state ->
        {text, state} = EnvFacts.render(state)
        {text, EnvFacts.update_turn(state, calls)}
      end)

    {state, rendered}
  end

  defp render(state), do: state |> EnvFacts.render() |> elem(0)

  defp form(command) do
    case Observe.classify_command(command) do
      [o | _] -> {o.intent, o.form}
      [] -> nil
    end
  end

  # The bare runner is missing; `python -m pytest` works at once.
  defp clean_pytest(i) do
    [
      edit("pkg/c#{i}.py"),
      bash("pytest -q", "bash: pytest: command not found", 127),
      bash("python -m pytest -q", "4 passed in 0.01s", 0)
    ]
  end

  # The bare runner fails on the base interpreter; the explicit path works.
  defp broken_env(i) do
    [
      edit("pkg/mod#{i}.py"),
      bash("python -m pytest tests/test_a.py -q", "#{@base}: No module named pytest", 1),
      bash("#{@proj} -m pytest tests/test_a.py -q", "1 passed in 0.2s", 0)
    ]
  end

  # --- observations -----------------------------------------------------------------------

  test "a separator quoted or escaped as the shell reads it ends no segment" do
    # A backslash in single quotes is literal: the quote ends there.
    assert Observe.segments(~S(printf 'a\' ; pytest -q ; printf '; make build')) ==
             [~S(printf 'a\'), "pytest -q", "printf '; make build'"]

    assert Observe.segments(~S(echo 'C:\' && echo '; npm run build')) ==
             [~S(echo 'C:\'), "echo '; npm run build'"]

    # Outside quotes it escapes the separator after it.
    assert Observe.segments(~S(echo a\;make build)) == [~S(echo a\;make build)]
    assert Observe.classify_command(~S(echo a\;make build)) == []

    assert [%{intent: "run_tests", form: "pytest"}] =
             Observe.classify_command(~S(printf 'a\' ; pytest -q ; printf '; make build'))
  end

  test "a call's status speaks only for the segments it covers" do
    outcomes = fn command, output, code ->
      Observe.observe_turn([bash(command, output, code)]).obs
      |> Enum.map(&{&1.form, &1.outcome})
    end

    # A guard that failed stopped the build before it ran.
    assert outcomes.("test -f Makefile && make build", "", 1) == [{"make build", nil}]

    # Exit 0 after `||` or `;` is the last command's.
    assert outcomes.("make build || cargo build", "make: *** No rule to make target", 0) ==
             [{"make build", nil}, {"cargo build", "ran"}]

    assert outcomes.("python -m pytest -q; true", "No module named 'pytest'", 0) ==
             [{"python -m pytest", nil}]

    # What a call's status does cover still ran.
    assert outcomes.("cd src && make build && cargo build", "", 0) ==
             [{"cd src && make build", "ran"}, {"cd src && cargo build", "ran"}]

    assert outcomes.("pytest -q || python -m pytest -q", "pytest: command not found\n4 passed", 0) ==
             [{"pytest", "command_missing"}, {"python -m pytest", "ran"}]

    # A test run its output shows ran, whatever came before it.
    assert outcomes.("source .venv/bin/activate && pytest -q", "1 failed, 3 passed", 1) ==
             [{"pytest", "ran"}]
  end

  test "classify forms and intents" do
    assert form(
             ~s(/bin/bash -lc "source /opt/env/bin/activate proj && python -m pytest tests -q")
           ) ==
             {"run_tests", "source activate proj && python -m pytest"}

    assert form("conda run -n proj python - <<'PY'\nimport x\nPY") ==
             {"run_interpreter", "conda run -n proj python"}

    # A script run through its shebang keeps the spelling that ran it: its
    # interpreter is the shebang's, not one to guess.
    assert form("PYTHONPATH=/testbed ./tests/runtests.py auth_tests -v 1") ==
             {"run_tests", "./tests/runtests.py"}

    assert form("./bin/test -q") == {"run_tests", "./bin/test"}
    assert form("/testbed/bin/doctest") == {"run_tests", "/testbed/bin/doctest"}

    assert form("#{@proj} bin/test sympy/core/tests/test_a.py") ==
             {"run_tests", "#{@proj} bin/test"}

    obs =
      Observe.classify_command(
        "git remote -v; git tag --contains HEAD | head; git log --oneline -3"
      )

    assert Enum.map(obs, &{&1.intent, &1.probe}) == [
             {"probe_vcs_refs", "remote"},
             {"probe_vcs_refs", "tag"}
           ]

    [fetch] = Observe.classify_command("curl -sS https://api.example.org/x | head -3")
    assert fetch.intent == "fetch_remote" and fetch.hosts == ["api.example.org"]

    # A credential in the URL is never kept; the port is.
    [fetch] = Observe.classify_command("curl https://alice:s3cret@api.example.org:8443/x")
    assert fetch.hosts == ["api.example.org:8443"]
    [fetch] = Observe.classify_command("git clone https://ghp_abc@github.com/o/r.git")
    assert fetch.hosts == ["github.com"]

    # A plain `git tag` lists all tags, past ones included: not a beyond-HEAD probe.
    assert Observe.classify_command("git tag | tail -5") == []
    # Heredoc bodies never become commands.
    assert form("python - <<'PY'\npytest_is_a_word = 1\nPY") == {"run_interpreter", "python"}
  end

  test "package scripts and exec launchers keep their shapes" do
    assert form("pnpm run test:unit") == {"run_tests", "pnpm run test:unit"}
    assert form("yarn run build") == {"run_build", "yarn run build"}
    assert form("pnpm exec tsc -p .") == {"run_build", "pnpm exec tsc"}
    assert form("bundle exec rspec spec") == {"run_tests", "bundle exec rspec"}
    assert form("bundle run rspec spec") == {"run_tests", "bundle run rspec"}
    refute Observe.bare?("bundle exec rspec")
    refute Observe.bare?("pnpm exec tsc")
  end

  test "the generic reading knows builds and other ecosystems" do
    assert form("npm run build") == {"run_build", "npm run build"}
    assert form("npm run test:unit") == {"run_tests", "npm run test:unit"}
    assert form("cargo build --release") == {"run_build", "cargo build"}
    assert form("tsc -p .") == {"run_build", "tsc"}
    assert form("go test ./...") == {"run_tests", "go test"}
    assert form("bundle install") == {"package_tool", "bundle"}
  end

  test "bun's package scripts are package scripts, not the interpreter" do
    assert form("bun run test:unit") == {"run_tests", "bun run test:unit"}
    assert form("bun run build") == {"run_build", "bun run build"}
    assert form("bun run dev") == {"run_interpreter", "bun"}
    assert form("bun src/index.ts") == {"run_interpreter", "bun"}
  end

  test "manage.py runs tests through its test command, which the form keeps" do
    assert form("python manage.py test app") == {"run_tests", "python manage.py test"}
    assert form("./manage.py test app.tests") == {"run_tests", "./manage.py test"}
    assert form("python src/manage.py test app") == {"run_tests", "python src/manage.py test"}
    assert form("python src/manage.py migrate") == {"run_interpreter", "python"}
    assert form("./manage.py migrate") == nil

    [o] = Observe.classify_command("python manage.py test app.tests.test_x")
    assert Observe.test_labels(o) == ["app.tests.test_x"]
  end

  test "a tool run by its path keeps the path in its form" do
    assert form("./gradlew test") == {"run_tests", "./gradlew test"}
    assert form("./gradlew build") == {"run_build", "./gradlew build"}

    assert form("node_modules/.bin/pnpm run lint") ==
             {"run_build", "node_modules/.bin/pnpm run lint"}

    assert form(".venv/bin/ruff check .") == {"run_build", ".venv/bin/ruff"}
    assert form(".venv/bin/pip list") == {"package_tool", ".venv/bin/pip"}
  end

  test "module and launcher runs name the tool they run" do
    assert form("python -m mypy .") == {"run_build", "python -m mypy"}
    assert form("python3 -m ruff check .") == {"run_build", "python3 -m ruff"}
    assert form("uvx ruff check .") == {"run_build", "uvx ruff"}
    assert form("uv tool run ruff check .") == {"run_build", "uvx ruff"}
    assert form("pipx run black .") == {"run_build", "pipx run black"}
    assert form("uvx pytest -q") == {"run_tests", "uvx pytest"}
    assert form("cd pkg && python -m mypy .") == {"run_build", "cd pkg && python -m mypy"}
    assert form("python -m json.tool f.json") == {"run_interpreter", "python"}
    refute Observe.bare?("uvx ruff")
    refute Observe.bare?("pipx run black")
  end

  test "assignments before a command are part of how it was typed" do
    [o] = Observe.classify_command("env PYTHONPATH=. pytest -q")
    assert {o.intent, o.form, o.env} == {"run_tests", "pytest", true}
    [o] = Observe.classify_command("PYTHONPATH=. python -m pytest -q")
    assert {o.form, o.env} == {"python -m pytest", true}
    [o] = Observe.classify_command("python -m pytest -q")
    assert o.env == false
  end

  test "a directory change is part of the form" do
    [o] = Observe.classify_command("cd tests && python runtests.py forms -v 2")
    assert o.form == "cd tests && python runtests.py"
    assert Observe.test_labels(o) == ["forms"]
  end

  test "the classifier sees through rtk's command prefix" do
    for bare <- [
          "python -m pytest tests/ -q",
          "pytest -q",
          "bin/test sympy/x.py",
          "K=1 pytest -q",
          "pip install foo",
          "curl https://x",
          "git status",
          "rg -n foo src"
        ],
        pre <- ["rtk ", "rtk proxy ", "rtk K=2 "] do
      wrapped = pre <> bare

      assert Enum.map(Observe.classify_command(wrapped), &{&1.intent, &1.form}) ==
               Enum.map(Observe.classify_command(bare), &{&1.intent, &1.form}),
             wrapped
    end

    assert Observe.strip_rtk_prefix("rtk pytest -q") == "pytest -q"
    assert Observe.strip_rtk_prefix("rtk proxy make") == "make"
    assert Observe.strip_rtk_prefix("rtk") == "rtk"
    assert Observe.strip_rtk_prefix("rtkfoo bar") == "rtkfoo bar"
    assert Observe.strip_rtk_prefix("pytest") == "pytest"
  end

  test "error classes are environmental only" do
    assert Observe.error_class("ModuleNotFoundError: No module named 'x'") == "module_missing"
    assert Observe.error_class("bash: pytest: command not found") == "command_missing"

    assert Observe.error_class("curl: (7) Failed to connect to h port 443: Connection refused") ==
             "connection_refused"

    assert Observe.error_class("AssertionError: 1 != 2\nFAILED tests/test_a.py::t") == nil
  end

  test "every edited file counts" do
    calls = [
      edit("/r/src/main.go"),
      {"Write", %{"file_path" => "/r/web/app.ts", "content" => "x"}, "ok", nil},
      edit("/r/pkg/m.py")
    ]

    assert Observe.observe_turn(calls).edited == ["app.ts", "m.py", "main.go"]
  end

  describe "labels" do
    test "only a shape rewrite counts as a repair" do
      for {a, b, rule} <- [
            {"tests.model_inheritance", "model_inheritance", {"strip", "tests."}},
            {"tests.admin_views.tests", "admin_views.tests", {"strip", "tests."}},
            {"db.datetime.test_x::DateTests::test_a", "db.datetime.test_x.DateTests.test_a",
             {"sep", "::"}},
            {"db.datetime.test_x::DateTests", "db.datetime.test_x", {"sep", "::"}},
            {"model_fields.DurationFieldTests", "model_fields", nil},
            {"admin_views.ChangeListTests", "admin_views", nil},
            {"app.tests", "other.tests", nil}
          ] do
        assert Observe.label_rule(a, b) == rule, "#{a} -> #{b}"
      end
    end

    test "labels are the structured arguments after the runner" do
      [o] =
        Observe.classify_command(
          "python tests/runtests.py tests.app -v 2 --settings=x 2>&1 | tail"
        )

      assert Observe.test_labels(o) == ["tests.app"]
      [o] = Observe.classify_command("python -m pytest pkg/test_a.py::T::test_b -q > /tmp/o.log")
      assert Observe.test_labels(o) == ["pkg/test_a.py::T::test_b"]
    end

    test "a missing runner is still a form failure, not a label one" do
      refute Observe.label_failed(["tests/test_a.py"], "/usr/bin/python3: No module named pytest")
      assert Observe.label_failed(["tests.app"], "ModuleNotFoundError: No module named 'tests'")

      assert Observe.label_failed(
               ["app.tests.Missing"],
               "AttributeError: module 'app.tests' has no attribute 'Missing'"
             )

      refute Observe.label_failed(
               ["app.tests"],
               "AttributeError: 'NoneType' object has no attribute 'pk'"
             )
    end
  end

  # --- the lifecycle ----------------------------------------------------------------------

  describe "the lifecycle" do
    test "promotion with drift needs confirmations on different files" do
      life = Lifecycle.new("k", false, true)
      life = Lifecycle.update(life, 0, "confirm", false, false, ["a.py"])
      life = Lifecycle.update(life, 1, "confirm", false, false, ["a.py"])
      assert life.state == "CANDIDATE" and Lifecycle.drifted_confirms(life) == 1
      life = Lifecycle.update(life, 2, "confirm", false, false, ["b.py"])
      life = Lifecycle.update(life, 3, "confirm", false, false, ["c.py"])
      assert life.state == "ACTIVE" and life.promoted_at == 3
    end

    test "without drift any three confirmations promote" do
      life =
        Enum.reduce(0..2, Lifecycle.new("k", false, false), fn now, life ->
          Lifecycle.update(life, now, "confirm", false, false, ["same.py"])
        end)

      assert life.state == "ACTIVE"
    end

    test "a high-stakes active fact retires on one contradiction; a low one on score" do
      promote = fn life ->
        Enum.reduce(0..2, life, fn now, life ->
          Lifecycle.update(life, now, "confirm", false, false, [])
        end)
      end

      high = "k" |> Lifecycle.new(true, false) |> promote.()
      assert Lifecycle.update(high, 3, "contradict", false, false, []).state == "RETIRED"

      low = "k" |> Lifecycle.new(false, false) |> promote.()
      # One contradiction weighs five confirmations: the score is already under.
      assert Lifecycle.update(low, 3, "contradict", false, false, []).state == "RETIRED"
    end

    test "evidence is aggregated, in bounded space, with the same score" do
      # Fifty confirmations of one fact keep no list of them, and the score
      # is upstream's sum over every one.
      life =
        Enum.reduce(0..49, Lifecycle.new("k", false, false), fn now, life ->
          Lifecycle.update(life, now, "confirm", true, true, ["f#{now}.py"])
        end)

      assert life.confirms == [] and life.confirm_count == 50
      expected = Enum.sum_by(0..49, fn i -> 0.8 ** (55 - i) end)
      assert_in_delta Lifecycle.score(life, 55), expected, 1.0e-9

      loaded = life |> Lifecycle.dump() |> JSON.encode!() |> JSON.decode!() |> Lifecycle.load()
      assert_in_delta Lifecycle.score(loaded, 55), expected, 1.0e-9
      assert Lifecycle.dump(loaded) == Lifecycle.dump(life)

      # A drifting candidate keeps at most the sets promotion still needs.
      drifting =
        Enum.reduce(0..19, Lifecycle.new("k", false, true), fn now, life ->
          Lifecycle.update(life, now, "confirm", false, false, ["same.py"])
        end)

      assert length(drifting.confirms) <= Lifecycle.k_promote()
      assert drifting.confirm_count == 20

      # A state saved before aggregation loads with the same score.
      legacy = %{
        "key" => "k",
        "high" => false,
        "drift" => false,
        "state" => "ACTIVE",
        "confirms" => [[0, ["a.py"]], [2, ["b.py"]], [5, ["c.py"]]],
        "contradicts" => [4],
        "fire_num" => 3,
        "fire_den" => 4,
        "promoted_at" => 5,
        "retired_at" => nil
      }

      loaded = Lifecycle.load(legacy)
      expected = 0.8 ** 10 + 0.8 ** 8 + 0.8 ** 5 - 5.0 * 0.8 ** 6
      assert_in_delta Lifecycle.score(loaded, 10), expected, 1.0e-9
      assert Lifecycle.drifted_confirms(loaded) == 3
      assert Lifecycle.contradictions(loaded) == 1
    end

    test "the firing gate needs its rate over enough exercised tasks" do
      life =
        Enum.reduce(0..2, Lifecycle.new("k", false, false), fn now, life ->
          Lifecycle.update(life, now, "confirm", true, true, [])
        end)

      assert life.state == "ACTIVE"
      refute Lifecycle.injectable?(life)
      life = Lifecycle.update(life, 3, "confirm", true, true, [])
      assert Lifecycle.injectable?(life)

      life =
        Enum.reduce(4..10, life, fn now, life ->
          Lifecycle.update(life, now, nil, false, true, [])
        end)

      refute Lifecycle.injectable?(life)
    end
  end

  # --- form repair ------------------------------------------------------------------------

  describe "form repair" do
    test "an interpreter fact forms, fires and renders" do
      {state, _} = stream(Enum.map(0..2, &broken_env/1))
      # Active needs 3 confirms and the firing gate 4 exercised turns.
      assert render(state) == ""
      state = EnvFacts.update_turn(state, broken_env(3))
      text = render(state)
      assert String.starts_with?(text, EnvFacts.header())
      assert text =~ @proj and text =~ "python -m pytest …` fails here"
      fact = state.facts["form_repair:run_tests:python -m pytest"]
      assert fact.life.state == "ACTIVE" and fact.life.fire_num == 4 and fact.life.fire_den == 4
      assert EnvFacts.lint_ok?(text)
    end

    test "a clean environment forms nothing" do
      clean = fn i ->
        [edit("pkg/m#{i}.py"), bash("python -m pytest tests/test_a.py -q", "1 passed", 0)]
      end

      {state, _} = stream(Enum.map(0..7, clean))
      assert state.facts == %{} and render(state) == ""
    end

    test "prevented waste still counts as firing" do
      {state, _} = stream(Enum.map(0..3, &broken_env/1))
      {_text, state} = EnvFacts.render(state)
      # The agent followed the fact: the working form straight away.
      state =
        EnvFacts.update_turn(state, [
          edit("pkg/z.py"),
          bash("#{@proj} -m pytest tests/test_z.py -q", "3 passed", 0)
        ])

      fact = state.facts["form_repair:run_tests:python -m pytest"]
      assert fact.life.fire_num == 5 and fact.life.fire_den == 5
      assert render(state) != ""
    end

    test "bare runner success contradicts and retires" do
      {state, _} = stream(Enum.map(0..3, &broken_env/1))
      assert render(state) != ""

      fixed = fn i ->
        [edit("pkg/f#{i}.py"), bash("python -m pytest tests/test_a.py -q", "1 passed", 0)]
      end

      {state, _} = stream(Enum.map(20..22, fixed), state)
      assert state.facts["form_repair:run_tests:python -m pytest"].life.state == "RETIRED"
      assert render(state) == ""
    end

    test "a bare one-liner success is not a contradiction" do
      {state, _} = stream(Enum.map(0..3, &broken_env/1))

      state =
        EnvFacts.update_turn(state, [
          edit("pkg/q.py"),
          bash("python -c 'import pkg; print(pkg.__version__)'", "1.0", 0),
          bash("#{@proj} -m pytest tests -q", "2 passed", 0)
        ])

      assert state.facts["form_repair:run_tests:python -m pytest"].life.state == "ACTIVE"
    end

    test "a fact forms where every turn edits the same file" do
      same_file = fn _i ->
        [
          edit("pkg/stock.py"),
          bash("pytest -q", "bash: pytest: command not found", 127),
          bash("python -m pytest -q", "4 passed in 0.01s", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..3, same_file))
      assert state.facts["form_repair:run_tests:pytest"].life.state == "ACTIVE"
      assert render(state) =~ "`pytest …` fails here with command not found"
    end

    test "facts sharing the working form merge into one line that says works" do
      two_forms = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("pytest tests/test_a.py -q", "bash: pytest: command not found", 127),
          bash("python -m pytest tests/test_a.py -q", "#{@base}: No module named pytest", 1),
          bash("#{@proj} -m pytest tests/test_a.py -q", "1 passed", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..3, two_forms))
      text = render(state)
      assert length(String.split(text, "\n- ")) - 1 == 1
      assert text =~ "pytest …`" and text =~ "python -m pytest …`"

      assert text
             |> String.trim()
             |> String.split("\n")
             |> List.last()
             |> String.ends_with?("`#{@proj} -m pytest …` works.")
    end

    test "a build tool repair becomes a fact under the generic reading" do
      task = fn i ->
        [
          edit("/r/src/m#{i}.ts"),
          bash("tsc -p .", "Exit code 127\nbash: tsc: command not found", 127),
          bash("npx tsc -p .", "", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))
      text = render(state)
      assert String.starts_with?(text, EnvFacts.header())
      assert text =~ "`tsc …` fails here with command not found; `npx tsc …` works."
    end

    test "a build tool missing bare and working by its path is a repair" do
      task = fn i ->
        [
          edit("/r/src/m#{i}.py"),
          bash("ruff check .", "Exit code 127\nbash: ruff: command not found", 127),
          bash(".venv/bin/ruff check .", "All checks passed!", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))

      assert render(state) =~
               "`ruff …` fails here with command not found; `.venv/bin/ruff …` works."

      # A wrapper run by its path fails where the bare one works: the path is named.
      task = fn i ->
        [
          edit("/r/src/m#{i}.kt"),
          bash("gradlew build", "Exit code 127\nbash: gradlew: command not found", 127),
          bash("./gradlew build", "BUILD SUCCESSFUL in 3s", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))

      assert render(state) =~
               "`gradlew build …` fails here with command not found; `./gradlew build …` works."
    end

    test "a run that shows neither its status nor its output proves nothing" do
      hidden = ".venv/bin/ruff check . 2>&1 | head -n 0"
      [o] = Observe.observe_turn([bash(hidden, "", nil)]).obs
      assert o.outcome == nil

      # A known failure still ran its first command; unknown with output did too.
      [o] = Observe.observe_turn([bash(".venv/bin/ruff check .", "", 1)]).obs
      assert o.outcome == "ran"
      [o] = Observe.observe_turn([bash(".venv/bin/ruff check . | tail -1", "1 error", nil)]).obs
      assert o.outcome == "ran"

      task = fn i ->
        [
          edit("/r/pkg/m#{i}.py"),
          bash("ruff check .", "Exit code 127\nbash: ruff: command not found", 127),
          bash(hidden, "", nil)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.keys(state.facts), &String.starts_with?(&1, "form_repair"))
    end

    test "a directory change shared by two builds does not make one repair the other" do
      task = fn i ->
        [
          edit("/r/web/m#{i}.ts"),
          bash("cd web && tsc -p .", "Exit code 127\nbash: tsc: command not found", 127),
          bash("cd web && eslint .", "", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.values(state.facts), &(&1.family == "form_repair"))
    end

    test "a form that only worked with an assignment before it is not named" do
      local = "~/.local/bin/pytest"

      messy = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("pytest -q", "bash: pytest: command not found", 127),
          bash("pytest -q", "bash: pytest: command not found", 127),
          bash(
            "#{local} -q",
            "E   ModuleNotFoundError: No module named 'stock'\nInterrupted: 1 error during collection\n1 error in 0.08s",
            2
          ),
          bash("PYTHONPATH=. #{local} -q", "4 passed in 0.01s", 0),
          bash("PYTHONPATH=. #{local} -q", "4 passed in 0.01s", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..2, &clean_pytest/1))
      {state, _} = stream(Enum.map(3..5, messy), state)
      fact = state.facts["form_repair:run_tests:pytest"]
      refute Map.has_key?(fact.params["b_counts"], local)
      assert render(state) |> String.trim() |> String.ends_with?("`python -m pytest …` works.")
    end

    test "one turn is one piece of evidence per form" do
      repeated = fn i ->
        [edit("pkg/r#{i}.py")] ++
          List.duplicate(bash("pytest -q", "bash: pytest: command not found", 127), 3) ++
          List.duplicate(bash("#{@proj} -m pytest -q", "1 passed", 0), 2)
      end

      {state, _} = stream(Enum.map(0..1, &clean_pytest/1))
      {_text, state} = EnvFacts.render(state)
      state = EnvFacts.update_turn(state, repeated.(2))
      fact = state.facts["form_repair:run_tests:pytest"]

      assert fact.params["b_counts"] == %{
               "python -m pytest" => 2,
               "#{@proj} -m pytest" => 1
             }

      assert EnvFacts.working_form(fact) == "python -m pytest"
    end

    test "a named form that stops working is named no more" do
      {state, _} = stream(Enum.map(0..3, &clean_pytest/1))
      assert render(state) =~ "`python -m pytest …` works"

      gone = fn i ->
        [
          edit("pkg/g#{i}.py"),
          bash("pytest -q", "bash: pytest: command not found", 127),
          bash("python -m pytest -q", "#{@base}: No module named pytest", 1)
        ]
      end

      {state, _} = stream(Enum.map(4..8, gone), state)
      fact = state.facts["form_repair:run_tests:pytest"]
      assert fact.params["b_fails"]["python -m pytest"] == 5
      assert EnvFacts.working_form(fact) == nil
      assert EnvFacts.claim(fact) == ""
      refute render(state) =~ "python -m pytest"
    end

    test "mistyped labels do not teach that the runner fails" do
      bad =
        "tests (unittest.loader._FailedTest) ... ERROR\nImportError: Failed to import test " <>
          "module: tests\nModuleNotFoundError: No module named 'tests.app'"

      task = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("python tests/runtests.py tests.app#{i}.tests.T -v 2 2>&1 | tail -20", bad, 1),
          bash("cd tests && python runtests.py app#{i}.tests.T -v 2", @ok, 0)
        ]
      end

      {state, rendered} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.values(state.facts), &(&1.family == "form_repair"))
      refute List.last(rendered) =~ "fails here"
    end

    test "a runner script run where it is not becomes a fact" do
      cant_open =
        "Exit code 2\npython: can't open file 'runtests.py': [Errno 2] No such file or directory"

      task = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("python runtests.py app#{i}", cant_open, 2),
          bash("cd tests && python runtests.py app#{i}", @ok, 0)
        ]
      end

      {_state, rendered} = stream(Enum.map(0..5, task))

      assert List.last(rendered) =~
               "`python runtests.py …` fails here with a file-not-found error; " <>
                 "`(cd tests && python runtests.py …)` works."
    end

    test "an option the runner rejects is not a failing form" do
      bad =
        "Exit code 2\nusage: runtests.py [-h] [module [module ...]]\nruntests.py: error: " <>
          "unrecognized arguments: test_x"

      task = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("python runtests.py app#{i} -k test_x", bad, 2),
          bash("python tests/runtests.py app#{i}", @ok, 0)
        ]
      end

      {state, _rendered} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.values(state.facts), &(&1.family == "form_repair"))
    end

    test "a run whose output was filtered away does not show a form works" do
      task = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash(
            "python -m pytest tests/app",
            "Exit code 1\n/venv/bin/python: No module named pytest",
            1
          ),
          bash(
            "python runtests.py app#{i} 2>&1 | grep -E '^(OK|FAILED|Ran )'",
            "(Bash completed with no output)",
            0
          )
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.values(state.facts), &(&1.family == "form_repair"))
    end

    test "a working form that leaves the shell where it is is the one named" do
      cant_open =
        "Exit code 2\npython: can't open file 'runtests.py': [Errno 2] No such file or directory"

      task = fn i ->
        [
          edit("pkg/m#{i}.py"),
          bash("python runtests.py app#{i}", cant_open, 2),
          bash("cd tests && python runtests.py app#{i}", @ok, 0),
          bash("cd tests && python runtests.py app#{i}.tests", @ok, 0)
        ]
      end

      tasks = Enum.map(0..5, task)
      tasks = List.update_at(tasks, 3, &(&1 ++ [bash("python tests/runtests.py app3", @ok, 0)]))
      {state, rendered} = stream(tasks)
      fact = state.facts["form_repair:run_tests:python runtests.py"]

      assert fact.params["b_counts"]["cd tests && python runtests.py"] >
               fact.params["b_counts"]["python tests/runtests.py"]

      assert List.last(rendered) =~ "`python tests/runtests.py …` works"
    end
  end

  # --- empty probe and boundary --------------------------------------------------------------

  test "the history fact forms only when probes return nothing" do
    empty = fn i ->
      [
        edit("pkg/e#{i}.py"),
        bash("git remote -v; git tag --contains HEAD | head", "", 0),
        bash("#{@proj} -m pytest tests -q", "1 passed", 0)
      ]
    end

    {state, _} = stream(Enum.map(0..3, empty))
    assert render(state) =~ "no git remote" and render(state) =~ "no tags"

    # And only what was probed is claimed: remote probes alone never
    # mention branches or tags.
    remote_only = fn i ->
      [edit("pkg/r#{i}.py"), bash("git remote -v", "", 0)]
    end

    {state, _} = stream(Enum.map(0..3, remote_only))

    assert render(state) ==
             "# environment facts learned from earlier sessions in this repository\n" <>
               "- Probes of this checkout found no git remote; they have returned nothing every time.\n"

    leaky = fn i ->
      [edit("pkg/l#{i}.py"), bash("git tag --contains HEAD | head", "0.22\n0.22.1\n0.23.0", 0)]
    end

    {state, _} = stream(Enum.map(0..3, leaky))
    assert render(state) == ""
    assert state.facts["empty_probe:vcs_refs"].life.state == "RETIRED"

    # A remote changed, added or removed prints nothing too: it probes nothing.
    for cmd <- [
          "git remote set-url origin https://example.org/repo.git",
          "git remote add upstream https://example.org/up.git",
          "git remote remove upstream",
          "git remote show origin"
        ] do
      assert Observe.classify_command(cmd) == [], cmd
    end

    for cmd <- ["git remote", "git remote -v", "git remote --verbose", "git remote show"] do
      assert [%{probe: "remote"}] = Observe.classify_command(cmd), cmd
    end
  end

  test "refused hosts form a boundary fact, and a reachable host retires it" do
    refused = fn i ->
      [
        edit("pkg/n#{i}.py"),
        bash(
          "curl -sS https://raw.example.org/a/b.py",
          "curl: (7) Failed to connect to raw.example.org port 443: Connection refused",
          7
        ),
        bash(
          "curl -sS https://api.example.org/search?q=x",
          "curl: (7) Failed to connect to api.example.org port 443: Connection refused",
          7
        )
      ]
    end

    {state, _} = stream(Enum.map(0..3, refused))
    text = render(state)
    assert text =~ "raw.example.org" and text =~ "api.example.org" and text =~ "refused"

    {_text, state} = EnvFacts.render(state)

    state =
      EnvFacts.update_turn(state, [
        bash("curl -sS https://api.example.org/ok", "{\"ok\": true}", 0)
      ])

    assert state.facts["boundary:fetch_remote"].life.state == "RETIRED"
  end

  # --- rendering discipline ----------------------------------------------------------------------

  test "the lint refuses completion advice" do
    refute EnvFacts.lint_ok?("You are done once the tests pass; skip the rest.")

    assert EnvFacts.lint_ok?(
             "`python …` fails here with command not found; `/x/bin/python …` works."
           )
  end

  test "the block is capped in facts and tokens" do
    state =
      Enum.reduce(0..6, EnvFacts.new(), fn i, state ->
        id = "form_repair:run_tests:tool#{i}"

        state =
          EnvFacts.add_candidate(state, %{
            id: id,
            family: "form_repair",
            high: false,
            drift: false,
            params: %{
              "intent" => "run_tests",
              "a" => "tool#{i}",
              "b_counts" => %{"/very/long/path/number/#{i}/that/keeps/going/bin/tool#{i}" => 3},
              "error_counts" => %{"command_missing" => 3}
            }
          })

        fact = state.facts[id]
        life = %{fact.life | state: "ACTIVE", fire_num: 10, fire_den: 10}
        put_in(state.facts[id], %{fact | life: life})
      end)

    text = render(state)
    assert text != "" and String.length(text) <= EnvFacts.max_tokens() * 4
    assert length(String.split(text, "\n- ")) - 1 <= EnvFacts.max_facts()
  end

  test "save and load roundtrip changes nothing staged" do
    {state, _} = stream(Enum.map(0..3, &broken_env/1))
    loaded = state |> EnvFacts.dump() |> JSON.encode!() |> JSON.decode!() |> EnvFacts.load()
    assert loaded.now == 4
    assert render(loaded) == render(state)
    assert EnvFacts.dump(loaded) == EnvFacts.dump(state)
  end

  # --- arg repair ----------------------------------------------------------------------------------

  defp run_label(label, output, code) do
    bash("python tests/runtests.py #{label} -v 2 2>&1 | tail -20", output, code)
  end

  describe "arg repair" do
    test "a label prefix the runner rejects becomes a fact" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label("tests.app#{i}", "ModuleNotFoundError: No module named 'tests'", 1),
            run_label("app#{i}", @ok, 0)
          ]
        end)

      {state, rendered} = stream(tasks)
      assert List.last(rendered) =~ "takes test labels without the `tests.` prefix"

      claim =
        state.facts |> Map.values() |> Enum.find(&(&1.family == "arg_repair")) |> EnvFacts.claim()

      assert String.starts_with?(claim, "`python tests/runtests.py` takes") and claim =~ "(`app"
      assert EnvFacts.lint_ok?(claim)
    end

    test "pytest-style separators the runner rejects become a fact" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label(
              "app#{i}.tests::T::test_x",
              "ImportError: Failed to import test module: app#{i}.tests::T::test_x",
              1
            ),
            run_label("app#{i}.tests.T.test_x", @ok, 0)
          ]
        end)

      {_state, rendered} = stream(tasks)
      assert List.last(rendered) =~ "takes dotted test labels"
    end

    test "a plain mistake is not a fact" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label(
              "app#{i}.tests.Missing",
              "AttributeError: module 'app#{i}.tests' has no attribute 'Missing'",
              1
            ),
            run_label("app#{i}", @ok, 0)
          ]
        end)

      {state, rendered} = stream(tasks)
      refute Enum.any?(Map.values(state.facts), &(&1.family == "arg_repair"))
      assert List.last(rendered) == ""
    end

    test "a prefixed label that loads contradicts the fact" do
      tasks =
        Enum.map(0..3, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label("tests.app#{i}", "ModuleNotFoundError: No module named 'tests'", 1),
            run_label("app#{i}", @ok, 0)
          ]
        end) ++ [[edit("/r/pkg/mod9.py"), run_label("tests.app9", @ok, 0)]]

      {state, _} = stream(tasks)
      id = Enum.find(Map.keys(state.facts), &String.starts_with?(&1, "arg_repair:"))
      assert state.last_digest.verdicts[id] |> elem(0) == "contradict"
    end

    test "output filtered away neither teaches nor contradicts" do
      tasks =
        Enum.map(0..3, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label(
              "app#{i}.tests::T::test_x",
              "app#{i}.tests::T::test_x (unittest.loader._FailedTest) ... ERROR",
              1
            ),
            run_label("app#{i}.tests.T.test_x", @ok, 0)
          ]
        end) ++
          [
            [
              edit("/r/pkg/mod8.py"),
              run_label("app8.tests::T::test_x", "FAILED (errors=1)", 1),
              run_label("app8.tests::T::test_y", "", 0)
            ]
          ]

      {state, _} = stream(tasks)
      id = "arg_repair:python tests/runtests.py:sep:::"
      assert state.last_digest.verdicts[id] |> elem(0) != "contradict"
      assert state.facts[id].life.state != "RETIRED"
    end

    test "a repair needs the rewritten label to have run tests" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            run_label("tests.app#{i}", "ModuleNotFoundError: No module named 'tests'", 1),
            run_label("app#{i}", "", 0)
          ]
        end)

      {state, _} = stream(tasks)
      refute Enum.any?(Map.values(state.facts), &(&1.family == "arg_repair"))
    end

    test "a label rewrite the runner loads becomes a fact under the generic reading" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/app/m#{i}.rb"),
            bash(
              "rspec spec/models/user_spec.rb",
              "ERROR: file or directory not found: spec/models/user_spec.rb",
              1
            ),
            bash("rspec models/user_spec.rb", "3 examples, 0 failures", 0)
          ]
        end)

      {state, _} = stream(tasks)
      facts = Enum.filter(Map.values(state.facts), &(&1.family == "arg_repair"))
      assert facts != [] and hd(facts).params["form"] == "rspec"

      assert hd(facts).params["examples"] == %{
               "spec/models/user_spec.rb models/user_spec.rb" => 6
             }
    end

    test "a fact keeps one example however many labels it rewrote" do
      tasks =
        Enum.map(0..40, fn i ->
          [
            edit("/r/app/m#{i}.rb"),
            bash(
              "rspec spec/models/user#{i}_spec.rb",
              "ERROR: file or directory not found: spec/models/user#{i}_spec.rb",
              1
            ),
            bash("rspec models/user#{i}_spec.rb", "3 examples, 0 failures", 0)
          ]
        end)

      {state, _} = stream(tasks)
      [fact] = Enum.filter(Map.values(state.facts), &(&1.family == "arg_repair"))

      # The shortest rewrite, the one the claim shows.
      assert fact.params["examples"] == %{"spec/models/user0_spec.rb models/user0_spec.rb" => 1}
      assert EnvFacts.claim(fact) =~ "(`models/user0_spec.rb`, not `spec/models/user0_spec.rb`)"
    end
  end

  # --- env value -----------------------------------------------------------------------------------

  @need "Traceback (most recent call last):\n  ...\nRuntimeError: settings are missing. Define " <>
          "the environment variable APP_SETTINGS before importing app."

  test "a value set only up to a comma is not learned as its prefix" do
    digest =
      Observe.observe_turn([
        bash("APP_SETTINGS=conf.dev,conf.extra python -c 'import app'", "ran", 0)
      ])

    assert digest.env == []

    digest =
      Observe.observe_turn([
        bash("APP_SETTINGS=conf.dev python -c 'import app'", "ran", 0)
      ])

    assert [%{sets: %{"APP_SETTINGS" => "conf.dev"}, ok: true}] = digest.env
  end

  test "only an assignment sets a variable, never text that looks like one" do
    sets = fn cmd ->
      case Observe.observe_turn([bash(cmd, "ran", 0)]).env do
        [] -> %{}
        [entry] -> entry.sets
      end
    end

    assert sets.("echo APP_SETTINGS=conf.dev") == %{}
    assert sets.("grep -r APP_SETTINGS=conf.dev .") == %{}
    assert sets.(~s{python -c "print('APP_SETTINGS=conf.dev')"}) == %{}
    assert sets.("export APP_SETTINGS=conf.dev") == %{"APP_SETTINGS" => "conf.dev"}

    assert sets.("export APP_SETTINGS=conf.dev && python -c 'import app'") ==
             %{"APP_SETTINGS" => "conf.dev"}

    assert sets.("cd app; APP_SETTINGS=conf.dev DEBUG_LEVEL=2 python -c 'import app'") ==
             %{"APP_SETTINGS" => "conf.dev", "DEBUG_LEVEL" => "2"}

    assert sets.("env APP_SETTINGS=conf.dev python -c 'import app'") ==
             %{"APP_SETTINGS" => "conf.dev"}

    assert sets.("APP_SETTINGS='conf.dev' python -c 'import app'") ==
             %{"APP_SETTINGS" => "conf.dev"}
  end

  test "an unknown exit status is no evidence of success" do
    digest =
      Observe.observe_turn([
        bash("APP_SETTINGS=conf.dev python -c 'import app' 2>&1 | head -n 0", "", nil)
      ])

    assert [%{ok: false}] = digest.env

    digest = Observe.observe_turn([bash("git remote -v", "", nil)])
    assert [%{outcome: nil}] = digest.obs
  end

  test "nonempty probe output in a real shape is a hit, other output unknown" do
    outcome = fn cmd, out ->
      Observe.observe_turn([bash(cmd, out, 0)]).obs |> hd() |> Map.fetch!(:outcome)
    end

    assert outcome.("git remote", "origin") == "hit"
    assert outcome.("git branch -r", "  origin/main\n  origin/release") == "hit"
    assert outcome.("git tag --contains HEAD", "release") == "hit"
    assert outcome.("git remote -v", "") == "empty"
    assert outcome.("git fsck", "Checking object directories: 100% (256/256), done.") == nil
  end

  describe "env value" do
    test "a variable the code asks for and its working value become a fact" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app; app.run()'", @need, 1),
            bash(
              "APP_SETTINGS=conf.missing python -c 'import app; app.run()'",
              "Traceback (most recent call last):\nModuleNotFoundError: No module named 'conf.missing'",
              1
            ),
            bash("APP_SETTINGS=conf.dev python -c 'import app; app.run()'", "ran", 0)
          ]
        end)

      {state, rendered} = stream(tasks)

      assert List.last(rendered) =~
               "Code that imports the project needs `APP_SETTINGS` set here: " <>
                 "`APP_SETTINGS=conf.dev` works, `conf.missing` does not."

      assert EnvFacts.lint_ok?(EnvFacts.claim(state.facts["env_value:APP_SETTINGS"]))
    end

    test "a value set in the code counts too" do
      code = ~s|import os; os.environ.setdefault("APP_SETTINGS", "conf.dev"); import app|

      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app'", @need, 1),
            bash("python -c '#{code}'", "ran", 0)
          ]
        end)

      {state, _} = stream(tasks)
      assert state.facts["env_value:APP_SETTINGS"].params["good"] == %{"conf.dev" => 6}
    end

    test "a variable that holds a credential is never learned" do
      need = String.replace(@need, "APP_SETTINGS", "API_TOKEN")

      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app'", need, 1),
            bash("export API_TOKEN=tok_s3cret && python -c 'import app'", "ran", 0)
          ]
        end)

      {state, rendered} = stream(tasks)
      refute Map.has_key?(state.facts, "env_value:API_TOKEN")
      refute Enum.any?(rendered, &(&1 =~ "s3cret"))
    end

    test "a value only exported proves nothing until the code runs with it" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app'", @need, 1),
            bash("export APP_SETTINGS=conf.missing", "", 0)
          ]
        end)

      {state, _} = stream(tasks)
      refute Map.has_key?(state.facts, "env_value:APP_SETTINGS")

      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app'", @need, 1),
            bash("export APP_SETTINGS=conf.missing; echo set", "set", 0),
            bash("export APP_SETTINGS=conf.dev && python -c 'import app'", "ran", 0)
          ]
        end)

      {state, _} = stream(tasks)
      fact = state.facts["env_value:APP_SETTINGS"]
      assert fact.params["good"] == %{"conf.dev" => 6}
      # Only exported, it did not fail either.
      assert fact.params["bad"] == %{}
    end

    test "no value that worked means no fact" do
      tasks =
        Enum.map(0..5, fn i ->
          [
            edit("/r/pkg/mod#{i}.py"),
            bash("python -c 'import app'", @need, 1),
            bash(
              "APP_SETTINGS=conf.missing python -c 'import app'",
              "Traceback (most recent call last):\nNameError: x",
              1
            )
          ]
        end)

      {state, _} = stream(tasks)
      refute Map.has_key?(state.facts, "env_value:APP_SETTINGS")
    end

    test "being asked for the variable again does not confirm its value" do
      tasks =
        [
          [
            edit("/r/pkg/mod0.py"),
            bash("python -c 'import app'", @need, 1),
            bash("APP_SETTINGS=conf.dev python -c 'import app'", "ran", 0)
          ]
        ] ++
          Enum.map(1..5, fn i ->
            [edit("/r/pkg/mod#{i}.py"), bash("python -c 'import app'", @need, 1)]
          end)

      {state, rendered} = stream(tasks)
      assert state.facts["env_value:APP_SETTINGS"].life.state == "CANDIDATE"
      refute List.last(rendered) =~ "APP_SETTINGS"
    end
  end

  # --- absent tool -----------------------------------------------------------------------------------

  describe "absent tool" do
    defp absent_ruff(i) do
      [
        edit("/r/pkg/m#{i}.py"),
        bash("ruff check .", "Exit code 127\nbash: ruff: command not found", 127),
        bash("make build", "built", 0)
      ]
    end

    test "an absent linter becomes a fact, and a working form is a repair instead" do
      {state, _} = stream(Enum.map(0..3, &absent_ruff/1))
      fact = state.facts["absent_tool:ruff"]
      assert fact.family == "absent_tool" and fact.life.state == "ACTIVE"
      assert render(state) =~ "`ruff …` fails here with command not found"

      refute Enum.any?(
               Map.keys(state.facts),
               &(String.starts_with?(&1, "form_repair") and &1 =~ "ruff")
             )
    end

    test "an absent tool retires when it runs" do
      {state, _} = stream(Enum.map(0..3, fn i -> Enum.take(absent_ruff(i), 2) end))
      assert state.facts["absent_tool:ruff"].life.state == "ACTIVE"
      {_text, state} = EnvFacts.render(state)

      state =
        EnvFacts.update_turn(state, [
          edit("/r/pkg/z.py"),
          bash("ruff check .", "All checks passed!", 0)
        ])

      assert state.facts["absent_tool:ruff"].life.state == "RETIRED"
    end

    test "a program missing inside make is not learned as make missing" do
      task = fn i ->
        [
          edit("/r/src/m#{i}.c"),
          bash(
            "make",
            "Exit code 2\ncc -o app main.c\n/bin/sh: 1: cc: not found\nmake: *** [Makefile:2: app] Error 127",
            2
          ),
          bash("ruff check .", "Exit code 127\n/bin/sh: 1: ruff: not found", 127)
        ]
      end

      {state, _} = stream(Enum.map(0..3, task))
      refute Map.has_key?(state.facts, "absent_tool:make")
      assert state.facts["absent_tool:ruff"].life.state == "ACTIVE"
    end

    test "a staged absent tool counts only turns that ran a check" do
      {state, _} = stream(Enum.map(0..3, fn i -> Enum.take(absent_ruff(i), 2) end))
      {text, state} = EnvFacts.render(state)
      assert text =~ "`ruff …` fails here with command not found"

      state =
        EnvFacts.update_turn(state, [edit("/r/pkg/y.py"), bash("ls", "pkg", 0)])

      assert state.last_digest.verdicts["absent_tool:ruff"] == {nil, false, false}
      {_text, state} = EnvFacts.render(state)

      state =
        EnvFacts.update_turn(state, [
          edit("/r/pkg/z.py"),
          bash("mypy .", "Success: no issues found in 3 source files", 0)
        ])

      assert state.last_digest.verdicts["absent_tool:ruff"] == {"confirm", true, true}
    end

    test "a tool that works another way is not learned as absent" do
      for {bare, working} <- [
            {"mypy .", "python -m mypy ."},
            {"mypy .", "python3 -m mypy ."},
            {"ruff check .", "python -m ruff check ."},
            {"ruff check .", "uvx ruff check ."},
            {"ruff check .", "uv tool run ruff check ."},
            {"black .", "pipx run black ."},
            {"ruff check .", "uv run ruff check ."},
            {"ruff check .", ".venv/bin/ruff check ."}
          ] do
        tool = bare |> String.split() |> hd()

        task = fn i ->
          [
            edit("/r/pkg/m#{i}.py"),
            bash(bare, "Exit code 127\nbash: #{tool}: command not found", 127),
            bash(working, "All checks passed!", 0)
          ]
        end

        {state, _} = stream(Enum.map(0..5, task))
        refute Map.has_key?(state.facts, "absent_tool:#{tool}"), "#{bare} repaired by #{working}"
      end
    end

    test "the working form is named as the repair" do
      for working <- ["python -m mypy .", "uvx mypy .", "pipx run mypy ."] do
        task = fn i ->
          [
            edit("/r/pkg/m#{i}.py"),
            bash("mypy .", "Exit code 127\nbash: mypy: command not found", 127),
            bash(working, "Success: no issues found in 3 source files", 0)
          ]
        end

        {state, _} = stream(Enum.map(0..5, task))
        form = working |> String.split(" ") |> Enum.drop(-1) |> Enum.join(" ")

        assert render(state) =~
                 "`mypy …` fails here with command not found; `#{form} …` works.",
               working
      end
    end

    test "an absent tool retires when it runs another way" do
      for working <- ["python -m mypy .", "uvx mypy .", "pipx run mypy ."] do
        task = fn i ->
          [
            edit("/r/pkg/m#{i}.py"),
            bash("mypy .", "Exit code 127\nbash: mypy: command not found", 127)
          ]
        end

        {state, _} = stream(Enum.map(0..3, task))
        assert state.facts["absent_tool:mypy"].life.state == "ACTIVE"
        {_text, state} = EnvFacts.render(state)

        state =
          EnvFacts.update_turn(state, [
            edit("/r/pkg/z.py"),
            bash(working, "Success: no issues found in 3 source files", 0)
          ])

        assert state.facts["absent_tool:mypy"].life.state == "RETIRED", working
      end
    end

    test "a shared subcommand does not make one tool repair another" do
      task = fn i ->
        [
          edit("/r/src/m#{i}.rs"),
          bash("cargo build", "Exit code 127\nbash: cargo: command not found", 127),
          bash("make build", "built", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))
      refute Enum.any?(Map.keys(state.facts), &String.starts_with?(&1, "form_repair")), "cargo"

      # One package script by another runner is the same tool.
      task = fn i ->
        [
          edit("/r/web/m#{i}.ts"),
          bash("yarn build", "Exit code 127\nbash: yarn: command not found", 127),
          bash("npm run build", "built", 0)
        ]
      end

      {state, _} = stream(Enum.map(0..5, task))

      assert render(state) =~
               "`yarn build …` fails here with command not found; `npm run build …` works."
    end

    test "a shared launcher does not make one tool repair another" do
      for {failing, other} <- [
            {"python -m mypy .", "python -m ruff check ."},
            {"uvx mypy .", "uvx ruff check ."},
            {"pipx run mypy .", "pipx run ruff check ."}
          ] do
        task = fn i ->
          [
            edit("/r/pkg/m#{i}.py"),
            bash(failing, "Exit code 1\n/usr/bin/python: No module named mypy", 1),
            bash(other, "All checks passed!", 0)
          ]
        end

        {state, _} = stream(Enum.map(0..5, task))
        refute Enum.any?(Map.keys(state.facts), &String.starts_with?(&1, "form_repair")), failing
      end
    end
  end

  # --- dropping, restoring, folding once, the view ---------------------------------------------------

  describe "dropping and restoring" do
    test "a dropped fact is not learned again until restored" do
      {state, _} = stream(Enum.map(0..3, &broken_env/1))
      id = "form_repair:run_tests:python -m pytest"
      assert {:ok, state} = EnvFacts.drop(state, id)
      assert render(state) == ""

      {state, _} = stream(Enum.map(4..7, &broken_env/1), state)
      refute Map.has_key?(state.facts, id)
      assert EnvFacts.view(state)["dropped"] == [id]

      assert {:ok, state} = EnvFacts.restore(state, id)
      {state, _} = stream(Enum.map(8..11, &broken_env/1), state)
      assert state.facts[id].life.state == "ACTIVE"
      assert render(state) =~ "python -m pytest"
    end

    test "dropping or restoring what is not there says so" do
      state = EnvFacts.new()
      assert {:error, message} = EnvFacts.drop(state, "form_repair:run_tests:nope")
      assert message =~ "no micro-skill"
      assert {:error, message} = EnvFacts.restore(state, "form_repair:run_tests:nope")
      assert message =~ "not dropped"
    end

    test "a turn is folded once, however often it is heard" do
      state = EnvFacts.update_turn(EnvFacts.new(), broken_env(0), "run-1")
      again = EnvFacts.update_turn(state, broken_env(0), "run-1")
      assert again == state
      assert EnvFacts.update_turn(state, broken_env(1), "run-2").now == state.now + 1
    end

    test "the view names each fact with its evidence" do
      {state, _} = stream(Enum.map(0..3, &broken_env/1))
      view = EnvFacts.view(state)
      assert view["turns"] == 4
      assert [%{} = skill] = view["skills"]
      assert skill["id"] == "form_repair:run_tests:python -m pytest"
      assert skill["state"] == "ACTIVE" and skill["staged"] == true

      assert skill["evidence"] == %{
               "confirms" => 4,
               "contradicts" => 0,
               "fired" => 4,
               "exercised" => 4,
               "firingRate" => 1.0
             }

      assert view["staged"] =~ "python -m pytest"
      assert view["dropped"] == []
    end
  end
end
