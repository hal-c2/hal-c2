defmodule T3.Steps.Files.FileViewerAndEditing do
  @moduledoc """
  Steps for `features/files/file-viewer-and-editing.feature`: `projects.readFile`
  and `projects.writeFile` over the socket. Absolute paths are the scenario's host
  paths (`T3.Test.Node.Host`).
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.{Host, World}

  # A PNG's signature and header: bytes that are not text.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137>>

  step "{string} holds the text file {string}", %{args: [project, file]} = context do
    write(context, project, file, "export const app = () => \"shop\";\n")
  end

  step "a client reads {string} from {string}", %{args: [file, project]} = context do
    read(context, project, Host.path(context, file), %{})
  end

  step "the file's contents are returned", context do
    assert {:ok, %{"contents" => contents}} = context.reply
    assert contents == context.contents
    context
  end

  step "the result is not marked as truncated", context do
    assert {:ok, %{"truncated" => false}} = context.reply
    context
  end

  step "{string} in {string} is {int} MB", %{args: [file, project, mb]} = context do
    write(context, project, file, String.duplicate("log line\n", div(mb * 1_048_576, 9) + 1))
  end

  step "the first megabyte is returned", context do
    assert {:ok, %{"contents" => contents, "byteLength" => size}} = context.reply
    assert contents == binary_part(context.contents, 0, 1_048_576)
    assert size == byte_size(context.contents)
    context
  end

  step "a client reads {string} from {string} as text", %{args: [file, project]} = context do
    # The examples name a binary file the project holds, or one of its folders.
    path = Path.join(World.project(context, project).root, file)
    unless File.exists?(path), do: write(context, project, file, <<0, 1, 2, 255, 0>> <> @png)
    read(context, project, file, %{"encoding" => "utf8"})
  end

  step "the node answers that {string} is not a text file", %{args: [file]} = context do
    refused(context, "binary_file", "'#{file}' is not a text file.")
  end

  step "the node answers that {string} is not a file", %{args: [file]} = context do
    refused(context, "path_not_file", "'#{file}' is not a file.")
  end

  step "{string} is an image in {string}", %{args: [file, project]} = context do
    write(context, project, file, @png)
  end

  step "a client reads {string} from {string} as base64", %{args: [file, project]} = context do
    read(context, project, file, %{"encoding" => "base64"})
  end

  step "the image bytes are returned", context do
    assert {:ok, %{"contents" => contents, "byteLength" => size}} = context.reply
    assert Base.decode64!(contents) == context.contents
    assert size == byte_size(context.contents)
    context
  end

  step "the host has the file {string}", %{args: [file]} = context do
    path = Host.path(context, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "- buy milk\n")
    Map.put(context, :contents, "- buy milk\n")
  end

  step "the file is marked as one that cannot be written back", context do
    assert {:ok, %{"relativePath" => path}} = context.reply
    assert Path.type(path) == :absolute

    {reply, context} =
      World.call(context, "projects.writeFile", %{
        "cwd" => World.project(context).root,
        "relativePath" => path,
        "contents" => "changed\n"
      })

    assert {:error, _, %{"failure" => "workspace_path_outside_root"}} = reply
    assert File.read!(path) == context.contents
    context
  end

  step "{string} exists with the written contents", %{args: [file]} = context do
    assert {:ok, _} = context.reply
    assert File.read!(Path.join(World.project(context).root, file)) == context.written
    context
  end

  step "a client reads {string} in {string}", %{args: [file, project]} = context do
    # A link out of the project, to a home folder with its own files.
    if String.starts_with?(file, "link-to-home/") do
      home = Host.path(context, "/home/sam")
      File.mkdir_p!(home)
      File.write!(Path.join(home, ".bashrc"), "export SECRET=1\n")
      File.ln_s!(home, Path.join(World.project(context, project).root, "link-to-home"))
    end

    read(context, project, file, %{})
  end

  step "the node answers that the path is outside the project", context do
    assert {:error, _, %{"failure" => failure}} = context.reply
    assert failure in ["workspace_path_outside_root", "resolved_path_outside_root"]
    context
  end

  step "the folder of {string} was deleted", %{args: [project]} = context do
    File.rm_rf!(World.project(context, project).root)
    context
  end

  step "a client lists the files of {string}", %{args: [project]} = context do
    Node.ensure(T3.Workspace)

    {reply, context} =
      World.call(context, "projects.listEntries", %{"cwd" => World.project(context, project).root})

    Map.put(context, :reply, reply)
  end

  step "the node answers that the project folder does not exist", context do
    assert {:error, message, %{"failure" => "workspace_root_not_found"}} = context.reply
    assert message =~ "does not exist"
    context
  end

  defp write(context, project, file, contents) do
    path = Path.join(World.project(context, project).root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Map.put(context, :contents, contents)
  end

  defp read(context, project, file, input) do
    Node.ensure(T3.Workspace)

    {reply, context} =
      World.call(
        context,
        "projects.readFile",
        Map.merge(input, %{"cwd" => World.project(context, project).root, "relativePath" => file})
      )

    Map.put(context, :reply, reply)
  end

  defp refused(context, failure, message) do
    assert {:error, ^message, %{"failure" => ^failure}} = context.reply
    context
  end
end
