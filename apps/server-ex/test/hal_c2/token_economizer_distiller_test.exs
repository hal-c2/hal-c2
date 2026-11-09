# SPDX-License-Identifier: Apache-2.0
# Ported in part from tests/test_injection.py (the distiller's) and
# tests/test_generic_microskills.py (the proposer's digest, window and prompt)
# (microsoft/TokenEconomizer@cb42207e3e09). Changed: a turn's calls are given
# as the plugin folds them, `{name, args, output, exit_code}`, not as
# transcript files, and the model's reply is handed to `Distiller.admit/2`
# instead of a runner; only the generic reading is ported, so the
# experiments' prompt and vocabularies are left out.

for file <-
      ~w(micro_skills_lifecycle micro_skills_observe micro_skills_envfacts micro_skills_distiller),
    do: Code.require_file("../../../../plugins/token-economizer/mc/#{file}.ex", __DIR__)

defmodule HalC2.TokenEconomizerDistillerTest do
  @moduledoc """
  TokenEconomizer's paid proposer (`plugins/token-economizer/mc/micro_skills_distiller.ex`),
  as plain functions: what a turn's digest holds, when a proposal is due, what the
  prompt shows, and which of a reply's facts and extractors are admitted. The model
  call and the plugin process are covered by
  `features/plugins/token-economizer-micro-skills.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.TokenEconomizer.MicroSkills.{Distiller, EnvFacts, Lifecycle, Observe}

  # --- helpers --------------------------------------------------------------------------

  defp bash(command, output, code \\ 0), do: {"Bash", %{"command" => command}, output, code}

  defp edit(path),
    do: {"Edit", %{"file_path" => path, "old_string" => "a", "new_string" => "b"}, "ok", nil}

  # A turn folded as the plugin folds it with the proposer on: the proposer first,
  # then the environment facts, which advance the clock.
  defp fold(skills, calls, iid),
    do: skills |> Distiller.fold(calls, iid) |> EnvFacts.update_turn(calls, iid)

  # The file the plugin keeps, written and read back.
  defp reload(skills, opts \\ [proposing: true]),
    do: skills |> EnvFacts.dump() |> JSON.encode!() |> JSON.decode!() |> EnvFacts.load(opts)

  defp pytest_turn(i),
    do: [edit("pkg/mod#{i}.py"), bash("python -m pytest tests/test_x.py", "1 passed")]

  defp make_turn(i),
    do: [edit("src/m#{i}.go"), bash("make build", "built"), bash("make test", "ok  ./... 0.01s")]

  defp payload(facts, extractors \\ []),
    do: JSON.encode!(%{"extractors" => extractors, "facts" => facts})

  @use_pytest %{
    "id" => "use-pytest",
    "claim" => "pytest is canonical",
    "injection" => "run tests with pytest",
    "high_stakes" => true,
    "detector" => %{"scope" => "ran_tests", "confirm" => "passed", "fired" => "ran_tests"},
    "cite" => ["w-0", "w-1"]
  }

  @build_first %{
    "id" => "build-before-test",
    "claim" => "make test needs make build first",
    "injection" => "`make test` runs the built binary: run `make build` first.",
    "detector" => %{"scope" => "make test", "confirm" => "make build"},
    "cite" => ["s0", "s1"]
  }

  # Folds `turns` and proposes with `reply` whenever one is due: the state and
  # the prompts sent.
  defp run_proposer(turns, reply, every, skills \\ EnvFacts.new(proposing: true)) do
    Enum.reduce(turns, {skills, []}, fn {calls, iid}, {skills, prompts} ->
      skills = fold(skills, calls, iid)

      if Distiller.due?(skills, every) do
        prompt = Distiller.prompt(skills, "acme/tool")
        {skills, _outcomes} = skills |> Distiller.proposed() |> Distiller.admit(reply)
        {skills, prompts ++ [prompt]}
      else
        {skills, prompts}
      end
    end)
  end

  defp outcomes(skills, reply), do: skills |> Distiller.admit(reply) |> elem(1)

  defp windowed(n, turn \\ &make_turn/1) do
    Enum.reduce(0..(n - 1), EnvFacts.new(proposing: true), &fold(&2, turn.(&1), "s#{&1}"))
  end

  # --- upstream's distiller tests ----------------------------------------------------------

  describe "the distiller" do
    test "renders nothing before a fact forms" do
      skills = fold(EnvFacts.new(proposing: true), [bash("pytest", "ok")], "widget-1")
      assert render(skills) == ""
      assert skills.now == 1
      assert skills.proposer.turns == 1
    end

    test "persists and reads back what it learned" do
      skills = fold(EnvFacts.new(proposing: true), [bash("pytest", "ok")], "w-1")
      again = reload(skills)
      assert again.now == skills.now
      assert again.proposer == skills.proposer
    end

    test "grounds a fact on two cited turns and fires it" do
      turns = for i <- 0..7, do: {pytest_turn(i), "w-#{i}"}
      {skills, prompts} = run_proposer(turns, payload([@use_pytest]), 1)

      # Asked at every turn, as `every` is 1; at the first only one cited turn is in
      # the window, so the fact waits for the second.
      assert length(prompts) == 8
      assert %EnvFacts.Fact{family: "proposer"} = fact = skills.facts["use-pytest"]
      assert fact.life.fire_den >= 1
      assert fact.life.state == "ACTIVE"
      assert Lifecycle.injectable?(fact.life)

      assert render(skills) =~ "# repo operating manual"
      assert render(skills) =~ "- run tests with pytest"
      # The proposer off, its facts are kept and not staged.
      assert render(%{skills | proposing: false}) == ""
    end
  end

  # --- the generic digest ----------------------------------------------------------------------

  describe "the digest" do
    test "is language neutral, relative to the home directory, and keeps its blobs to itself" do
      home = System.user_home!()
      repo = Path.join(home, "repo")

      calls = [
        edit(Path.join(repo, "src/main.ts")),
        bash(
          "cd #{repo} && npm run build",
          "Exit code 2\n#{repo}/src/main.ts(3,5): error TS2304: Cannot find name 'foo'.",
          2
        ),
        bash("node scripts/gen.js", "Error: Cannot find module 'left-pad'\nExit code 1", 1),
        bash("cargo build", "Finished dev", 0)
      ]

      dg = Distiller.digest(calls, "s0")
      assert dg["edited_files"] == ["main.ts"]
      assert dg["check_commands"] == ["cd ~/repo && npm run build", "cargo build"]

      assert dg["failed_commands"] == [
               # line and column masked; the error's own code kept, as it names the failure
               %{
                 "cmd" => "cd ~/repo && npm run build",
                 "error" => "~/repo/src/main.ts(N,N): error TS2304: Cannot find name 'foo'."
               },
               %{
                 "cmd" => "node scripts/gen.js",
                 "error" => "Error: Cannot find module 'left-pad'"
               }
             ]

      assert dg["missing_dependency"] and not dg["missing_command"]

      skills = fold(EnvFacts.new(proposing: true), calls, "s0")
      prompt = Distiller.prompt(skills, "acme/web")
      refute prompt =~ home
      refute prompt =~ "_cmd_blob"
      refute prompt =~ "_out_blob"
    end

    test "reads a failure from the exit code when there is one, else from the output" do
      assert Distiller.command_failed?(1, "all good")
      refute Distiller.command_failed?(0, "Traceback (most recent call last):")
      assert Distiller.command_failed?(nil, "Traceback (most recent call last):\n  x")
      assert Distiller.command_failed?(nil, "bash: rg: command not found")
      refute Distiller.command_failed?(nil, "Exit code 0\nError: none")
    end

    test "holds no credential a command or its output carried" do
      token = "ghp_" <> String.duplicate("a1B2", 9)

      calls = [
        bash(
          "curl -H 'Authorization: token #{token}' https://user:pw@example.com/x",
          "denied #{token}",
          1
        )
      ]

      skills = fold(EnvFacts.new(proposing: true), calls, "s0")
      saved = skills |> EnvFacts.dump() |> JSON.encode!()
      refute saved =~ token
      refute saved =~ "user:pw"
      refute Distiller.prompt(skills, "acme") =~ token
      assert Observe.redact("x #{token} y") == "x <secret> y"
    end

    test "is folded once per turn" do
      calls = [bash("make test", "ok")]
      skills = fold(EnvFacts.new(proposing: true), calls, "s0")
      assert fold(skills, calls, "s0").proposer == skills.proposer
    end
  end

  # --- cadence, window and prompt ----------------------------------------------------------------

  describe "the proposer" do
    test "is due after the second turn, then every `every` turns" do
      due =
        Enum.map_reduce(0..7, EnvFacts.new(proposing: true), fn i, skills ->
          skills = fold(skills, make_turn(i), "s#{i}")

          if Distiller.due?(skills, 3),
            do: {i + 1, Distiller.proposed(skills)},
            else: {nil, skills}
        end)
        |> elem(0)
        |> Enum.reject(&is_nil/1)

      assert due == [2, 5, 8]
    end

    test "keeps its window across folds, so a fact can cite two turns" do
      {skills, prompts} =
        Enum.reduce(0..1, {EnvFacts.new(proposing: true), []}, fn i, {skills, prompts} ->
          skills = skills |> reload() |> fold(make_turn(i), "s#{i}")

          if Distiller.due?(skills, 3) do
            prompt = Distiller.prompt(skills, "acme/tool")

            {skills, _} =
              skills |> Distiller.proposed() |> Distiller.admit(payload([@build_first]))

            {skills, prompts ++ [prompt]}
          else
            {skills, prompts}
          end
        end)

      assert [prompt] = prompts
      assert prompt =~ "whatever its language"
      assert Map.has_key?(skills.facts, "build-before-test")
      assert Enum.map(reload(skills).proposer.window, & &1["iid"]) == ["s0", "s1"]
    end

    test "is shown the facts it already has" do
      turns = for i <- 0..4, do: {make_turn(i), "s#{i}"}
      {_skills, prompts} = run_proposer(turns, payload([@build_first]), 3)

      assert [first, second] = prompts
      assert first =~ "Existing facts, as `id: claim`" and first =~ "(none)"
      assert second =~ "  - build-before-test: make test needs make build first"
    end

    test "names the generic predicates, not the experiments'" do
      prompt = Distiller.system_prompt()
      refute prompt =~ "repro_written"
      refute prompt =~ "importerror"
      assert length(String.split(prompt, Enum.join(Distiller.predicates(), ", "))) - 1 == 2
    end

    test "is shown the environment facts staged and the ids a person dropped" do
      skills = windowed(2)
      {skills, _} = Distiller.admit(skills, payload([@build_first]))
      {:ok, skills} = EnvFacts.drop(skills, "build-before-test")
      prompt = Distiller.prompt(skills, "acme/tool")
      assert prompt =~ "Fact ids a person removed"
      assert prompt =~ "build-before-test"
    end

    test "shows raw commands its senses do not read when most go unread" do
      skills =
        Enum.reduce(0..1, EnvFacts.new(proposing: true), fn i, skills ->
          fold(
            skills,
            [bash("./scripts/regen-protos.sh --all", "done"), edit("x#{i}.go")],
            "s#{i}"
          )
        end)

      assert Distiller.prompt(skills, "acme") =~ "  $ ./scripts/regen-protos.sh --all"

      {skills, _} =
        Distiller.admit(
          skills,
          payload([], [%{"name" => "regen", "kind" => "cmd_regex", "pattern" => "regen-protos"}])
        )

      refute Distiller.prompt(skills, "acme") =~ "RAW command excerpts"
    end
  end

  # --- admission ------------------------------------------------------------------------------------

  describe "admitting a reply" do
    test "a malformed reply admits nothing" do
      skills = windowed(2)
      assert Distiller.admit(skills, "claude payload") == {skills, []}
      assert Distiller.admit(skills, "{\"facts\": 3") == {skills, []}
      assert Distiller.admit(skills, "[1, 2]") == {skills, []}
    end

    test "a fact its detector confirms on fewer than two cited turns is refused" do
      skills = windowed(2)
      one = %{@build_first | "cite" => ["s0", "nowhere"]}

      assert outcomes(skills, payload([one])) == [
               {:fact, "build-before-test", "grounding-fail(1/2)"}
             ]

      # Citing the same turn twice is one citation.
      twice = %{@build_first | "cite" => ["s0", "s0"]}

      assert outcomes(skills, payload([twice])) == [
               {:fact, "build-before-test", "grounding-fail(1/2)"}
             ]
    end

    test "a detector that does not compile admits nothing" do
      skills = windowed(2)
      bad = put_in(@build_first["detector"]["confirm"], "make (build")
      assert outcomes(skills, payload([bad])) == [{:fact, "build-before-test", "bad-detector"}]
      no_confirm = put_in(@build_first["detector"], %{"scope" => "make test"})

      assert outcomes(skills, payload([no_confirm])) == [
               {:fact, "build-before-test", "bad-detector"}
             ]
    end

    test "a line that reads as completion or verification advice is refused" do
      skills = windowed(2)
      advice = %{@build_first | "injection" => "Skip the tests once `make build` passes."}
      assert outcomes(skills, payload([advice])) == [{:fact, "build-before-test", "lint"}]
      long = %{@build_first | "injection" => "run make build\nthen anything"}
      assert outcomes(skills, payload([long])) == [{:fact, "build-before-test", "lint"}]
    end

    test "a fact holding a credential is refused" do
      skills = windowed(2)
      token = "ghp_" <> String.duplicate("a1B2", 9)
      leak = %{@build_first | "injection" => "Use the token #{token} for `make build`."}
      assert outcomes(skills, payload([leak])) == [{:fact, "build-before-test", "secret"}]
    end

    test "an id that is not a slug is refused" do
      skills = windowed(2)
      bad = %{@build_first | "id" => "form_repair:run_tests:make"}
      assert outcomes(skills, payload([bad])) == [{:fact, "form_repair:run_tests:make", "bad-id"}]
    end

    test "at most four facts are read from one reply" do
      skills = windowed(2)
      facts = for i <- 1..6, do: %{@build_first | "id" => "build-#{i}"}
      {skills, outcomes} = Distiller.admit(skills, payload(facts))
      assert length(outcomes) == 4
      assert skills.facts |> Map.keys() |> Enum.sort() == ~w(build-1 build-2 build-3 build-4)
    end

    test "an admitted fact enters with the history its detector reads in the window" do
      skills = windowed(4)
      {skills, [{:fact, _, "admitted"}]} = Distiller.admit(skills, payload([@build_first]))
      fact = skills.facts["build-before-test"]
      assert fact.params["rev"] == 1
      assert fact.life.fire_den == 4
      assert fact.life.state == "ACTIVE"
      # Its citations are read once and not kept.
      refute Map.has_key?(fact.params, "cite")

      assert EnvFacts.view(skills)["skills"] |> hd() |> Map.take(~w(source detector rev)) == %{
               "source" => "proposer",
               "detector" => @build_first["detector"],
               "rev" => 1
             }
    end

    test "a dropped fact is not admitted again until restored" do
      skills = windowed(2)
      {skills, _} = Distiller.admit(skills, payload([@build_first]))
      {:ok, skills} = EnvFacts.drop(skills, "build-before-test")

      assert outcomes(skills, payload([@build_first])) == [
               {:fact, "build-before-test", "dropped"}
             ]

      {:ok, skills} = EnvFacts.restore(skills, "build-before-test")

      assert outcomes(skills, payload([@build_first])) == [
               {:fact, "build-before-test", "admitted"}
             ]
    end

    test "only a fact's contradiction condition may be revised, keeping what it earned" do
      skills = windowed(4)
      {skills, _} = Distiller.admit(skills, payload([@build_first]))
      life = skills.facts["build-before-test"].life

      revised = put_in(@build_first["detector"]["contradict"], "No rule to make target")
      {skills, outcomes} = Distiller.admit(skills, payload([revised]))
      assert outcomes == [{:fact, "build-before-test", "revised"}]
      fact = skills.facts["build-before-test"]
      assert fact.params["rev"] == 2
      assert fact.params["detector"]["contradict"] == "No rule to make target"
      assert fact.life == life

      assert outcomes(skills, payload([revised])) == [{:fact, "build-before-test", "revise-noop"}]

      bad = put_in(@build_first["detector"]["contradict"], "No (rule")

      assert outcomes(skills, payload([bad])) == [
               {:fact, "build-before-test", "revise-bad-regex"}
             ]

      reworded = %{revised | "claim" => "make test needs a build"}

      assert outcomes(skills, payload([reworded])) == [
               {:fact, "build-before-test", "revise-not-contradict-only"}
             ]
    end

    test "an environment fact's id is never revised by the proposer" do
      skills =
        EnvFacts.add_candidate(windowed(2), %{
          id: "absent-tool",
          family: "absent_tool",
          high: false,
          params: %{"claim" => "x"}
        })

      fact = %{@build_first | "id" => "absent-tool"}
      assert outcomes(skills, payload([fact])) == [{:fact, "absent-tool", "exists"}]
    end
  end

  describe "extractors" do
    test "one a fact of the same reply names is admitted first, and the window read with it" do
      skills = windowed(2)
      extractor = %{"name" => "built", "kind" => "out_regex", "pattern" => "^built$"}
      fact = put_in(@build_first["detector"]["scope"], "built")
      {skills, outcomes} = Distiller.admit(skills, payload([fact], [extractor]))

      assert outcomes == [
               {:extractor, "built", "admitted"},
               {:fact, "build-before-test", "admitted"}
             ]

      assert Enum.all?(skills.proposer.window, &(&1["features"]["built"] == true))
      assert EnvFacts.view(skills)["extractors"] == ["built"]
    end

    test "are append-only and bounded, and one that does not compile is refused" do
      skills = windowed(2)
      first = for i <- 1..12, do: %{"name" => "x#{i}", "pattern" => "x#{i}"}
      {skills, _} = Distiller.admit(skills, payload([], first))
      assert map_size(skills.proposer.extractors) == 12

      assert outcomes(skills, payload([], [%{"name" => "x13", "pattern" => "y"}])) ==
               [{:extractor, "x13", "full"}]

      assert outcomes(skills, payload([], [%{"name" => "x1", "pattern" => "z"}])) ==
               [{:extractor, "x1", "exists"}]

      assert outcomes(windowed(2), payload([], [%{"name" => "bad", "pattern" => "("}])) ==
               [{:extractor, "bad", "bad-regex"}]

      assert outcomes(
               windowed(2),
               payload([], [%{"name" => "n", "kind" => "x", "pattern" => "y"}])
             ) ==
               [{:extractor, "n", "bad-kind"}]
    end

    test "count matching commands, and a regex past its match limit matches nothing" do
      cmds = [{"make a", ""}, {"make b", "boom"}, {"ls", ""}]
      assert Distiller.compute(%{"kind" => "cmd_count", "pattern" => "^make"}, cmds) == 2
      assert Distiller.compute(%{"kind" => "out_regex", "pattern" => "boom"}, cmds)
      refute Distiller.compute(%{"pattern" => "("}, cmds)

      evil = Distiller.rx("^(a+)+$")
      refute Distiller.search?(evil, String.duplicate("a", 40) <> "b")
    end
  end

  describe "the detector" do
    test "is not exercised outside its scope, and a contradiction wins over a confirmation" do
      dg = Distiller.digest([bash("make test", "No rule to make target 'build'")], "s0")
      detector = %{"scope" => "make test", "confirm" => "make", "contradict" => "No rule"}
      assert Distiller.verdict(detector, dg) == {"contradict", true, true}
      assert Distiller.verdict(%{detector | "scope" => "cargo"}, dg) == {nil, false, false}

      assert Distiller.verdict(Map.delete(detector, "contradict"), dg) ==
               {"confirm", true, true}

      assert Distiller.verdict(%{"scope" => "ran_tests", "confirm" => "make"}, dg) ==
               {"confirm", true, true}
    end
  end

  defp render(skills), do: skills |> EnvFacts.render() |> elem(0)
end
