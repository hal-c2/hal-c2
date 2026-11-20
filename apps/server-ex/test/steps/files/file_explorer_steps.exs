defmodule HalC2.Steps.Files.FileExplorer do
  @moduledoc """
  Steps for `features/files/file-explorer.feature`: `projects.listEntries` over the
  socket. A listing's paths go in `context.listing` for the shared "is returned"
  steps.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "{string} holds {string}, {string}, {string} and an ignored {string} folder",
       %{args: [project, a, b, c, ignored]} = context do
    root = World.project(context, project).root
    for file <- [a, b, c], do: write(root, file)
    write(root, ".gitignore", "#{ignored}/\n")
    write(root, "#{ignored}/left-pad/index.js")
    context
  end

  step "a client lists the folder {string} of {string}", %{args: [dir, project]} = context do
    list(context, project, %{"directoryPath" => dir})
  end

  step "a client lists the top folder of {string}", %{args: [project]} = context do
    list(context, project, %{"directoryPath" => ""})
  end

  step "a client lists every entry of {string}", %{args: [project]} = context do
    list(context, project, %{})
  end

  step "{string}, {string} and {string} are returned", %{args: names} = context do
    for name <- names,
        do: assert(name in context.listing, "#{name} not in #{inspect(context.listing)}")

    context
  end

  step "{string} and {string} are returned", %{args: names} = context do
    for name <- names,
        do: assert(name in context.listing, "#{name} not in #{inspect(context.listing)}")

    context
  end

  step "{string} is marked as ignored", %{args: [name]} = context do
    {:ok, %{"entries" => entries}} = context.reply
    assert %{"ignored" => true} = Enum.find(entries, &(&1["path"] == name))
    context
  end

  step "the MC answers with a folder listing failure", context do
    assert {:error, _message, %{"_tag" => "ProjectListEntriesError"}} = context.reply
    context
  end

  step "{string} is a git repository with an untracked {string}",
       %{args: [project, file]} = context do
    root = World.project(context, project).root
    assert File.dir?(Path.join(root, ".git"))
    write(root, file)
    context
  end

  step "nothing under {string} is returned", %{args: [dir]} = context do
    assert context.listing != []
    refute Enum.any?(context.listing, &under?(&1, dir))
    context
  end

  step "{string} is not a git repository and holds {string} and {string}",
       %{args: [project, a, b]} = context do
    root = World.project(context, project).root
    File.rm_rf!(Path.join(root, ".git"))
    for file <- [a, b], do: write(root, file)
    context
  end

  step "nothing under {string} or {string} is returned", %{args: dirs} = context do
    assert context.listing != []
    refute Enum.any?(context.listing, fn path -> Enum.any?(dirs, &under?(path, &1)) end)
    context
  end

  step "{string} holds more than 25,000 files", %{args: [project]} = context do
    dir = Path.join(World.project(context, project).root, "generated")
    File.mkdir_p!(dir)
    for i <- 1..25_001, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
    context
  end

  step "25,000 entries are returned", context do
    assert length(context.listing) == 25_000
    context
  end

  step "the result is marked as truncated", context do
    assert {:ok, %{"truncated" => true}} = context.reply
    context
  end

  step "a client writes {string} in {string}", %{args: [file, project]} = context do
    Mc.ensure(HalC2.Workspace)
    # Absolute paths are the scenario's host paths, so a stray write stays in it.
    path = HalC2.Test.Mc.Host.path(context, file)
    contents = "export const written = #{System.unique_integer([:positive])};\n"
    # What was there, for "nothing at ... changed" (`{:error, :eisdir}` for a folder).
    before =
      if Path.type(path) == :relative,
        do: {file, File.read(Path.join(World.project(context, project).root, path))}

    {reply, context} =
      World.call(context, "projects.writeFile", %{
        "cwd" => World.project(context, project).root,
        "relativePath" => path,
        "contents" => contents
      })

    Map.merge(context, %{reply: reply, written: contents, written_before: before})
  end

  step "{string} is a git repository that tracks {string} and {string}",
       %{args: [project, a, b]} = context do
    root = World.project(context, project).root
    assert File.dir?(Path.join(root, ".git"))
    for file <- [a, b], do: write(root, file)
    git!(root, ["add", a, b])
    git!(root, ["commit", "-q", "-m", "track them"])
    context
  end

  step "{string} now ignores {string}", %{args: [file, pattern]} = context do
    path = Path.join(World.project(context).root, file)
    File.write!(path, "#{pattern}\n", [:append])
    context
  end

  step ~r/^"(?<project>[^"]+)" holds "(?<file>[^"]*\/[^"]*)"$/,
       %{args: [project, file]} = context do
    write(World.project(context, project).root, file)
    context
  end

  step "{string} holds a link {string} to a folder elsewhere on the machine",
       %{args: [project, link]} = context do
    root = World.project(context, project).root
    outside = elsewhere(root)
    File.write!(Path.join(outside, "secret.txt"), "outside\n")
    File.ln_s!(outside, Path.join(root, link))
    context
  end

  step "nothing from the linked folder is returned", context do
    assert context.listing == []
    context
  end

  step "{string} holds a named pipe next to {string}", %{args: [project, _file]} = context do
    root = World.project(context, project).root
    {_, 0} = System.cmd("mkfifo", [Path.join(root, "events.pipe")])
    Map.put(context, :named_pipe, "events.pipe")
  end

  step "the named pipe is not", context do
    refute context.named_pipe in context.listing
    context
  end

  step "{string} holds {string}, a link to {string}, and {string}, a link to the folder {string}",
       %{args: [project, link_file, real_file, link_dir, real_dir]} = context do
    root = World.project(context, project).root
    write(root, real_file)
    File.mkdir_p!(Path.join(root, real_dir))
    File.ln_s!(real_file, Path.join(root, link_file))
    File.ln_s!(real_dir, Path.join(root, link_dir))
    context
  end

  step "{string} is returned as a file", %{args: [name]} = context do
    {:ok, %{"entries" => entries}} = context.reply
    assert %{"kind" => "file"} = Enum.find(entries, &(&1["path"] == name))
    context
  end

  step "{string} is returned as a folder", %{args: [name]} = context do
    {:ok, %{"entries" => entries}} = context.reply
    assert %{"kind" => "directory"} = Enum.find(entries, &(&1["path"] == name))
    context
  end

  step ~r/^"(?<project>[^"]+)" holds a link "(?<link>[^"]+)" that (?<points>.+)$/,
       %{args: [project, link, points]} = context do
    root = World.project(context, project).root

    target =
      case points do
        "points to nothing" -> "gone-target"
        "points to a folder elsewhere on the machine" -> elsewhere(root)
        "points into \".git\"" -> Path.join(root, ".git")
        "points to the folder it is in" -> root
        "points to the folder above it" -> Path.dirname(root)
      end

    File.ln_s!(target, Path.join(root, link))
    context
  end

  step "{string} is not a git repository or git is not installed",
       %{args: [project]} = context do
    File.rm_rf!(Path.join(World.project(context, project).root, ".git"))
    context
  end

  step "its entries are returned with none marked as ignored", context do
    assert {:ok, %{"entries" => entries}} = context.reply
    assert entries != []
    refute Enum.any?(entries, &(&1["ignored"] == true))
    context
  end

  step "{string}, {string} and {string} are returned as folders", %{args: names} = context do
    {:ok, %{"entries" => entries}} = context.reply

    for name <- names do
      assert %{"kind" => "directory"} = Enum.find(entries, &(&1["path"] == name)),
             "#{name} not a folder in #{inspect(Enum.map(entries, & &1["path"]))}"
    end

    context
  end

  defp elsewhere(root) do
    outside = Path.join(root, "../elsewhere-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    outside
  end

  defp git!(root, args) do
    {_out, 0} =
      System.cmd("git", args,
        cd: root,
        env: %{
          "GIT_AUTHOR_NAME" => "Scenario",
          "GIT_AUTHOR_EMAIL" => "scenario@example.invalid",
          "GIT_COMMITTER_NAME" => "Scenario",
          "GIT_COMMITTER_EMAIL" => "scenario@example.invalid"
        }
      )

    :ok
  end

  defp list(context, project, input) do
    Mc.ensure(HalC2.Workspace)
    input = Map.put(input, "cwd", World.project(context, project).root)
    {reply, context} = World.call(context, "projects.listEntries", input)

    listing =
      case reply do
        {:ok, %{"entries" => entries}} -> Enum.map(entries, & &1["path"])
        _ -> []
      end

    Map.merge(context, %{reply: reply, listing: listing})
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp write(root, file, contents \\ "x\n") do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
