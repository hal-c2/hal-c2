defmodule HalC2.Steps.Files.FileExplorer do
  @moduledoc """
  Steps for `features/files/file-explorer.feature`: `projects.listEntries` over the
  socket. A listing's paths go in `context.listing` for the shared "is returned"
  steps.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

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

  step "the node answers with a folder listing failure", context do
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
    Node.ensure(HalC2.Workspace)
    # Absolute paths are the scenario's host paths, so a stray write stays in it.
    path = HalC2.Test.Node.Host.path(context, file)
    contents = "export const written = #{System.unique_integer([:positive])};\n"

    {reply, context} =
      World.call(context, "projects.writeFile", %{
        "cwd" => World.project(context, project).root,
        "relativePath" => path,
        "contents" => contents
      })

    Map.merge(context, %{reply: reply, written: contents})
  end

  defp list(context, project, input) do
    Node.ensure(HalC2.Workspace)
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
