defmodule T3.Steps.Orchestration.WorkflowScripts do
  @moduledoc """
  Steps for `features/node/orchestration/workflow-scripts.feature`: the Claude
  projects folder is a temporary one (`:workflow_scripts_root`), and clients ask
  over the socket (`orchestration.getWorkflowScript`) for `context.script`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node
  alias T3.Test.Node.World

  step "a node whose Claude projects folder exists", context do
    root = Node.tmp_dir(context.node, "claude-projects")
    File.mkdir_p!(Path.join(root, "p"))
    Application.put_env(:t3, :workflow_scripts_root, root)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :workflow_scripts_root) end)
    assert File.dir?(root)
    Map.put(context, :root, root)
  end

  step "a workflow script of {int} KB inside the Claude projects folder",
       %{args: [kb]} = context do
    contents = "// workflow\n" |> String.duplicate(kb * 1024) |> binary_part(0, kb * 1024)
    path = script(context, "#{kb}kb.js", contents)
    # Asked for by a roundabout path: the node answers with the real one.
    asked = Path.join([context.root, "p", "..", "p", "#{kb}kb.js"])
    Map.merge(context, %{script: asked, real: path, contents: contents})
  end

  step "a client asks for that script", context do
    {reply, context} =
      World.call(context, "orchestration.getWorkflowScript", %{"scriptPath" => context.script})

    Map.put(context, :reply, reply)
  end

  step "it receives the script's real path and its contents, not truncated", context do
    assert {:ok, %{"scriptPath" => path, "contents" => contents, "truncated" => false}} =
             context.reply

    assert path == context.real
    assert contents == context.contents
    context
  end

  step "it receives the first 256 KB, marked truncated", context do
    assert {:ok, %{"contents" => contents, "truncated" => true}} = context.reply
    assert contents == binary_part(context.contents, 0, 256 * 1024)
    context
  end

  step "it fails with reason {string}", %{args: [reason]} = context do
    assert {:error, _, %{"reason" => ^reason}} = context.reply
    context
  end

  # --- situations ----------------------------------------------------------------------

  step("the path is relative", context, do: Map.put(context, :script, "p/run.js"))

  step("the path does not end in .js", context,
    do: Map.put(context, :script, script(context, "notes.txt", "notes"))
  )

  step "the Claude projects folder does not exist", context do
    File.rm_rf!(context.root)
    Map.put(context, :script, Path.join([context.root, "p", "run.js"]))
  end

  step("no file exists at the path", context,
    do: Map.put(context, :script, Path.join([context.root, "p", "gone.js"]))
  )

  step("the file is outside the Claude projects folder", context,
    do: Map.put(context, :script, outside(context, "secret.js"))
  )

  step "a link inside the folder points at a file outside it", context do
    link = Path.join([context.root, "p", "link.js"])
    File.ln_s!(outside(context, "secret.js"), link)
    Map.put(context, :script, link)
  end

  step "a .js link inside the folder points at a file that is not .js", context do
    link = Path.join([context.root, "p", "link.js"])
    File.ln_s!(script(context, "notes.txt", "notes"), link)
    Map.put(context, :script, link)
  end

  step "the path is a folder named like a script", context do
    folder = Path.join([context.root, "p", "folder.js"])
    File.mkdir_p!(folder)
    Map.put(context, :script, folder)
  end

  step "the file cannot be opened", context do
    path = script(context, "locked.js", "locked")
    File.chmod!(path, 0o000)
    assert {:error, :eacces} = File.read(path), "the test user can still read #{path}"
    Map.put(context, :script, path)
  end

  step "a workflow script is replaced between finding it and opening it", context do
    path = script(context, "run.js", "first")

    Application.put_env(:t3, :workflow_scripts_opening, fn opening ->
      # A new file renamed over the old one, as an editor saves it.
      File.write!(opening <> ".new", "second")
      File.rename!(opening <> ".new", opening)
    end)

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:t3, :workflow_scripts_opening) end)
    Map.put(context, :script, path)
  end

  defp script(context, name, contents) do
    path = Path.join([context.root, "p", name])
    File.write!(path, contents)
    path
  end

  defp outside(context, name) do
    path = Path.join(Node.tmp_dir(context.node, "elsewhere"), name)
    File.write!(path, "secret")
    path
  end
end
