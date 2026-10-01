defmodule HalC2.Steps.SourceControl.ReviewDiffs do
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  defp write(context, path, content) do
    file = Path.join(context.cwd, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  defp git(context, args), do: World.git!(context.cwd, args)

  defp review(context, extra \\ %{}) do
    {reply, context} =
      World.call(context, "review.getDiffPreview", Map.put(extra, "cwd", context.cwd))

    Map.put(context, :reply, reply)
  end

  defp source(context, kind) do
    assert {:ok, %{"sources" => sources}} = context.reply
    Enum.find(sources, &(&1["kind"] == kind)) || flunk("no #{kind} source in #{inspect(sources)}")
  end

  defp stats(context, kind), do: Map.new(source(context, kind)["files"], &{&1["path"], &1})

  defp contents(context) do
    assert {:ok, %{"oldContents" => old, "newContents" => new}} = context.reply
    {old, new}
  end

  step "the user changed {string} and created the untracked {string}",
       %{args: [changed, created]} = context do
    World.commit!(context.cwd, %{changed => "one\ntwo\n"}, "Add #{changed}")
    write(context, changed, "one\n2\nthree\n")
    write(context, created, "a\nb\nc\n")

    Map.put(context, :expected, %{
      changed => {2, 1},
      created => {3, 0}
    })
  end

  step "the user reviews the working tree", context do
    review(context)
  end

  step "both files are in the diff with their line counts", context do
    files = stats(context, "working-tree")

    for {path, {additions, deletions}} <- context.expected do
      assert %{"additions" => ^additions, "deletions" => ^deletions} = files[path],
             "#{path}: #{inspect(files)}"
    end

    context
  end

  step "the user staged {string} and left {string} untracked",
       %{args: [staged, untracked]} = context do
    World.commit!(context.cwd, %{staged => "one\n"}, "Add #{staged}")
    write(context, staged, "two\n")
    git(context, ["add", staged])
    write(context, untracked, "new\n")
    context
  end

  step "{string} is still the only staged file afterwards", %{args: [staged]} = context do
    # The review saw the untracked file, through its own scratch index...
    assert Map.has_key?(stats(context, "working-tree"), "src/tax.ts")
    # ...and the user's index is as it was.
    assert git(context, ~w(diff --cached --name-only)) == staged
    assert git(context, ~w(status --porcelain -- src/tax.ts)) == "?? src/tax.ts"
    context
  end

  step "{string} has {int} commits on top of {string}", %{args: [branch, n, base]} = context do
    assert git(context, ~w(branch --show-current)) == branch

    files =
      for i <- 1..n do
        path = "src/step#{i}.ts"
        World.commit!(context.cwd, %{path => "export const step = #{i}\n"}, "Step #{i}")
        path
      end

    assert git(context, ["rev-list", "--count", "#{base}..HEAD"]) == "#{n}"
    Map.put(context, :branch_files, files)
  end

  step "the user reviews the branch against {string}", %{args: [base]} = context do
    context |> review(%{"baseRef" => base}) |> Map.put(:base, base)
  end

  step "the diff shows every change the {int} commits made", %{args: [n]} = context do
    source = source(context, "branch-range")
    assert source["baseRef"] == context.base
    assert length(context.branch_files) == n
    assert Enum.sort(Map.keys(stats(context, "branch-range"))) == Enum.sort(context.branch_files)

    for path <- context.branch_files do
      assert source["diff"] =~ "+++ b/#{path}"
      assert %{"additions" => 1, "deletions" => 0} = stats(context, "branch-range")[path]
    end

    context
  end

  step "the only change in {string} is re-indentation", %{args: [path]} = context do
    World.commit!(context.cwd, %{path => "if (a) {\n  pay()\n}\n"}, "Add #{path}")
    write(context, path, "if (a) {\n      pay()\n}\n")
    assert git(context, ["diff", "--numstat", "--", path]) =~ ~r/^1\t1\t/
    context
  end

  step "the user reviews the working tree hiding whitespace changes", context do
    review(context, %{"ignoreWhitespace" => true})
  end

  step "{string} shows no changed lines", %{args: [path]} = context do
    source = source(context, "working-tree")

    case stats(context, "working-tree")[path] do
      nil -> :ok
      stat -> assert %{"additions" => 0, "deletions" => 0} = stat
    end

    refute source["diff"] =~ ~r/^[+-]\s+pay\(\)/m
    context
  end

  step "the working tree changes {int} files", %{args: [n]} = context do
    paths = for i <- 1..n, do: "gen/file#{i}.ts"
    for path <- paths, do: write(context, path, "export const value = 'before'\n")
    git(context, ["add", "gen"])
    git(context, ["commit", "-q", "-m", "Generated files"])
    for path <- paths, do: write(context, path, "export const value = 'after'\n")
    Map.put(context, :changed_paths, paths)
  end

  step "the diff says it was truncated", context do
    source = source(context, "working-tree")
    assert source["truncated"] == true
    assert String.ends_with?(source["diff"], "[truncated]")
    context
  end

  step "the line counts of every changed file are still reported", context do
    files = stats(context, "working-tree")
    assert map_size(files) == length(context.changed_paths)

    for path <- context.changed_paths,
        do: assert(%{"additions" => 1, "deletions" => 1} = files[path])

    context
  end

  # A path with an extension; mcp-server's `"<thread>" was deleted` takes the rest.
  step ~r/^"(?<file>[^"]*\.[^"]*)" was (?<change>changed|added|deleted|renamed without changes|renamed and changed)$/,
       %{args: [path, change]} = context do
    old_path = String.replace_suffix(path, ".ts", "_old.ts")

    {old, new} =
      case change do
        "changed" ->
          World.commit!(context.cwd, %{path => "old\n"}, "Add #{path}")
          write(context, path, "new\n")
          {"old\n", "new\n"}

        "added" ->
          write(context, path, "new\n")
          {"", "new\n"}

        "deleted" ->
          World.commit!(context.cwd, %{path => "old\n"}, "Add #{path}")
          File.rm!(Path.join(context.cwd, path))
          {"old\n", ""}

        "renamed without changes" ->
          World.commit!(context.cwd, %{old_path => "same\n"}, "Add #{old_path}")
          git(context, ["mv", old_path, path])
          {"same\n", "same\n"}

        "renamed and changed" ->
          body = Enum.map_join(1..10, &"line #{&1}\n")
          World.commit!(context.cwd, %{old_path => body}, "Add #{old_path}")
          git(context, ["mv", old_path, path])
          write(context, path, body <> "line 11\n")
          {body, body <> "line 11\n"}
      end

    Map.put(context, :sides, {old, new})
  end

  step "the old and new contents are shown", context do
    assert contents(context) == context.sides
    {old, new} = context.sides
    assert old != "" and new != "" and old != new
    context
  end

  step "only the new contents are shown", context do
    assert context.change_type == "new"
    assert {"", new} = contents(context)
    assert new == elem(context.sides, 1)
    context
  end

  step "only the old contents are shown", context do
    assert context.change_type == "deleted"
    assert {old, ""} = contents(context)
    assert old == elem(context.sides, 0)
    context
  end

  step "the contents are shown once under both names", context do
    assert context.change_type == "rename-pure"
    {old, new} = contents(context)
    assert old == new and old == elem(context.sides, 0)
    context
  end

  step "{string} changed", %{args: [path]} = context do
    World.commit!(context.cwd, %{path => <<0x89, "PNG", 0, 1, 2>>}, "Add #{path}")
    write(context, path, <<0x89, "PNG", 0, 3, 4>>)
    context
  end

  step "the user is told the file cannot be shown", context do
    assert {:error, _, %{"detail" => detail}} = context.reply
    assert detail =~ "Cannot expand binary file"
    context
  end

  step "the user expands a file of the branch review without naming the base", context do
    {reply, context} =
      World.call(context, "review.getDiffFileContents", %{
        "cwd" => context.cwd,
        "sourceKind" => "branch-range",
        "changeType" => "change",
        "baseRef" => nil,
        "headRef" => "feature/tax",
        "oldPath" => "README.md",
        "newPath" => "README.md"
      })

    Map.put(context, :reply, reply)
  end

  step "a client asks to review {string}", %{args: [cwd]} = context do
    review(Map.put(context, :cwd, cwd)) |> Map.put(:cwd, context.cwd)
  end
end
