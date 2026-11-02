defmodule HalC2.ClaudeSkillsTest do
  use ExUnit.Case, async: true

  alias HalC2.Claude.Skills

  describe "dispatch/2" do
    test "the last known mention runs, earlier ones become /name" do
      names = MapSet.new(["review", "ship"])

      assert {"/review the diff, then", "/ship it"} =
               Skills.dispatch("$review the diff, then $ship it", names)

      assert {nil, "/review the diff"} = Skills.dispatch("$review the diff", names)
      assert {"Please", "/review the diff"} = Skills.dispatch("Please $review the diff", names)
    end

    test "amounts, variables, and embedded mentions stay typed" do
      names = MapSet.new(["review", "20k"])

      for text <- [
            "echo $HOME",
            "it costs $5",
            "a budget of $10k",
            "a budget of $20k",
            "the price$review is wrong",
            "paid $1_000",
            "about $1e6"
          ] do
        assert Skills.dispatch(text, names) == nil, text
      end
    end

    test "digit-starting names and other currency signs mention" do
      names = MapSet.new(["5k-report"])
      assert {nil, "/5k-report for March"} = Skills.dispatch("$5k-report for March", names)
      assert {nil, "/5k-report for March"} = Skills.dispatch("€5k-report for March", names)
    end

    test "unknown mentions stay literal among known ones" do
      names = MapSet.new(["ship"])

      assert {"Use $review then", "/ship now"} =
               Skills.dispatch("Use $review then $ship now", names)
    end
  end

  describe "frontmatter/1" do
    test "no header is fine; an unreadable one drops the skill" do
      assert {:ok, %{}} = Skills.frontmatter("# Just a body\n")

      assert {:ok, %{"description" => "Reviews"}} =
               Skills.frontmatter("---\ndescription: Reviews\n---\nbody")

      assert :error = Skills.frontmatter("---\nname: [unclosed\n---\nbody")
      assert :error = Skills.frontmatter("---\njust words\n---\nbody")
    end
  end

  describe "decode_lenient/1" do
    test "comments and trailing commas are read" do
      text = """
      {
        // the user's switches
        "skillOverrides": {
          /* review is off */
          "review": "off",
        },
      }
      """

      assert {:ok, %{"skillOverrides" => %{"review" => "off"}}} = Skills.decode_lenient(text)
    end

    test "comment markers inside strings survive" do
      assert {:ok, %{"a" => "not // a comment,"}} =
               Skills.decode_lenient(~s({"a": "not // a comment,"}))
    end
  end

  describe "discover/2 and skill_overrides/2" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "hal-c2-claude-skills-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp skill(root, relative, body) do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    defp settings(root, relative, overrides) do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(%{"skillOverrides" => overrides}))
    end

    test "folder name wins, user's skill wins, layers apply low to high", %{root: root} do
      config = Path.join(root, "config")
      project = Path.join(root, "shop")
      skill(config, "skills/review/SKILL.md", "---\nname: Fancy\ndescription: User's own\n---\n")
      skill(project, ".claude/skills/review/SKILL.md", "---\ndescription: Project's\n---\n")
      skill(project, ".agents/skills/agent-only/SKILL.md", "body")

      [review] = Skills.discover("claudeAgent", project, config)
      assert review["name"] == "review"
      assert review["description"] == "User's own"
      assert review["scope"] == "user"
      assert review["enabled"] == true

      settings(config, "settings.json", %{"review" => "off"})
      assert [%{"enabled" => false}] = Skills.discover("claudeAgent", project, config)

      settings(project, ".claude/settings.json", %{"review" => "on"})
      assert [%{"enabled" => true}] = Skills.discover("claudeAgent", project, config)
    end

    test "a settings file with an unreadable value drops all its overrides", %{root: root} do
      config = Path.join(root, "config")
      settings(config, "settings.json", %{"review" => "off", "other" => "maybe"})
      assert Skills.skill_overrides(config, nil) == %{}
    end
  end
end
