defmodule HalC2.Acp.CursorSkillsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias HalC2.Acp.CursorSkills

  defp skill!(dir, header \\ "", body \\ "Do the thing.\n") do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n#{header}---\n#{body}")
    dir
  end

  defp names(skills), do: Enum.map(skills, & &1["name"])

  test "every skill folder Cursor reads is read, project before user", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    home = Path.join(dir, "home")

    for root <- ~w(.cursor .agents .codex .claude) do
      skill!(Path.join([project, root, "skills", "p-#{root}"]))
      skill!(Path.join([home, root, "skills", "u-#{root}"]))
    end

    found = CursorSkills.discover(project, home)

    assert names(found) ==
             ~w(p-.agents p-.claude p-.codex p-.cursor u-.agents u-.claude u-.codex u-.cursor)

    assert Enum.find(found, &(&1["name"] == "p-.cursor"))["scope"] == "project"
    assert Enum.find(found, &(&1["name"] == "u-.cursor"))["scope"] == "user"
  end

  test "the first skill of a name wins, built-in skills last as system", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    home = Path.join(dir, "home")
    skill!(Path.join([project, ".cursor", "skills", "review"]), "description: project one\n")
    skill!(Path.join([home, ".cursor", "skills", "review"]), "description: user one\n")
    skill!(Path.join([home, ".cursor", "skills-cursor", "review"]), "description: built in\n")
    skill!(Path.join([home, ".cursor", "skills-cursor", "helper"]))

    found = CursorSkills.discover(project, home)
    review = Enum.find(found, &(&1["name"] == "review"))
    assert review["description"] == "project one"
    assert review["scope"] == "project"
    assert Enum.count(found, &(&1["name"] == "review")) == 1
    assert Enum.find(found, &(&1["name"] == "helper"))["scope"] == "system"
  end

  test "a skill is known by its folder and shown by the name in its header", %{tmp_dir: dir} do
    project = Path.join(dir, "project")

    skill!(
      Path.join([project, ".cursor", "skills", "deploy"]),
      "name: Ship it\ndescription: Go\n"
    )

    assert [%{"name" => "deploy", "displayName" => "Ship it", "description" => "Go"}] =
             CursorSkills.discover(project, Path.join(dir, "home"))
  end

  test "header flags: only the user may run it, or the user may not start it", %{tmp_dir: dir} do
    project = Path.join(dir, "project")

    skill!(
      Path.join([project, ".cursor", "skills", "manual"]),
      "disable-model-invocation: true\n"
    )

    skill!(Path.join([project, ".cursor", "skills", "agent-only"]), "user-invocable: false\n")

    found = CursorSkills.discover(project, Path.join(dir, "home"))
    assert Enum.find(found, &(&1["name"] == "manual"))["userInvocationOnly"] == true
    assert Enum.find(found, &(&1["name"] == "agent-only"))["userInvocable"] == false
  end

  test "a skill meant for surfaces other than the CLI is not offered", %{tmp_dir: dir} do
    project = Path.join(dir, "project")

    skill!(
      Path.join([project, ".cursor", "skills", "ide-only"]),
      "metadata:\n  surfaces: [ide, web]\n"
    )

    skill!(
      Path.join([project, ".cursor", "skills", "cli-too"]),
      "metadata:\n  surfaces: ide, cli\n"
    )

    assert names(CursorSkills.discover(project, Path.join(dir, "home"))) == ["cli-too"]
  end

  test "an unreadable header drops only its own skill", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    skill!(Path.join([project, ".cursor", "skills", "broken"]), "name: \"unclosed\n")
    skill!(Path.join([project, ".cursor", "skills", "fine"]))

    assert names(CursorSkills.discover(project, Path.join(dir, "home"))) == ["fine"]
  end

  test "a skill file over 1 MB is offered without its header", %{tmp_dir: dir} do
    project = Path.join(dir, "project")

    skill!(
      Path.join([project, ".cursor", "skills", "manual"]),
      "name: The Manual\ndescription: Big\n",
      String.duplicate("x", 1_100_000)
    )

    assert [%{"name" => "manual"} = manual] =
             CursorSkills.discover(project, Path.join(dir, "home"))

    refute Map.has_key?(manual, "description")
    refute Map.has_key?(manual, "displayName")
  end

  test "skills in sub-folders are found; node_modules is never searched", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    skill!(Path.join([project, ".cursor", "skills", "team", "release", "deploy"]))
    skill!(Path.join([project, ".cursor", "skills", "withdeps"]))
    skill!(Path.join([project, ".cursor", "skills", "withdeps", "node_modules", "pkg", "hidden"]))

    assert names(CursorSkills.discover(project, Path.join(dir, "home"))) == ["deploy", "withdeps"]
  end

  test "a root linked from a second root is read once, within budget", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    claude_skills = Path.join([home, ".claude", "skills"])
    skill!(Path.join(claude_skills, "review"))
    for i <- 1..5_999, do: File.mkdir_p!(Path.join(claude_skills, "d#{i}"))
    File.mkdir_p!(Path.join([home, ".agents"]))
    File.ln_s!(claude_skills, Path.join([home, ".agents", "skills"]))

    assert {:ok, found} = CursorSkills.probe(Path.join(dir, "project"), home)
    assert names(found) == ["review"]
  end

  test "a skill linked from outside its root is offered without searching below it",
       %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    elsewhere = Path.join([dir, "elsewhere", "kept"])
    skill!(elsewhere)
    skill!(Path.join(elsewhere, "nested"))
    File.mkdir_p!(Path.join([project, ".cursor", "skills"]))
    File.ln_s!(elsewhere, Path.join([project, ".cursor", "skills", "shared"]))

    assert names(CursorSkills.discover(project, Path.join(dir, "home"))) == ["shared"]
  end

  test "a scan over its folder budget is reported, not cut short", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    root = Path.join([project, ".cursor", "skills"])
    File.mkdir_p!(root)
    for i <- 1..10_001, do: File.mkdir!(Path.join(root, "d#{i}"))

    assert {:error, detail} = CursorSkills.probe(project, Path.join(dir, "home"))
    assert detail =~ "was incomplete (scan-budget-exhausted)"
  end

  test "a scan over its byte budget is reported, not cut short", %{tmp_dir: dir} do
    project = Path.join(dir, "project")

    for i <- 1..9 do
      skill!(
        Path.join([project, ".cursor", "skills", "s#{i}"]),
        "description: skill #{i}\n",
        String.duplicate("x", 950_000)
      )
    end

    assert {:error, detail} = CursorSkills.probe(project, Path.join(dir, "home"))
    assert detail =~ "was incomplete (scan-budget-exhausted)"
  end

  test "a folder tree deeper than the scan reaches is left, not a failure", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    skill!(Path.join([project, ".cursor", "skills", "review"]))

    deep =
      Enum.reduce(1..12, Path.join([project, ".claude", "skills"]), fn i, path ->
        Path.join(path, "level#{i}")
      end)

    skill!(Path.join(deep, "buried"))

    assert {:ok, found} = CursorSkills.probe(project, Path.join(dir, "home"))
    assert names(found) == ["review"]
  end

  test "a skill folder that cannot be read is reported", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    locked = Path.join([project, ".cursor", "skills", "locked"])
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    assert {:error, detail} = CursorSkills.probe(project, Path.join(dir, "home"))
    assert detail =~ "was incomplete (filesystem-error)"
  end
end
