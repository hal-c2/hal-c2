defmodule HalC2.WorkspaceWritePropTest do
  @moduledoc """
  `HalC2.Workspace.write_file/1` by an absolute path, against a model of a few host
  paths outside the project. Each is missing, a small text file, a binary file, a text
  file over 1 MB, a folder, or a link to another of them, in whatever order the agent
  leaves them. A write by full path lands only on a text file already there that
  `read_file/1` gives whole, through any links; every other write is refused and
  changes nothing, and nothing is ever created outside the project.

  Each write is made by a session with or without `terminal:operate`, gated as the
  socket gates it (`HalC2.Rpc.required_scope/2`), and names the file by its full path
  or by a relative path that tries to leave the project (`../outside/a`, or through a
  link in the project to the folder outside). A session without terminal access never
  changes anything outside the project, however it names the file.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Workspace

  @moduletag timeout: :infinity

  @names [:a, :b, :c]
  @texts ["", "one\n", "edited\n"]
  @big_bytes 1_048_577

  property "a full-path write lands only on a text file already there",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()
        {history, state, result} = run_commands(__MODULE__, cmds)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start_case do
    dir = HalC2.Prop.scratch_home("workspace-write")
    root = Path.join(dir, "project")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    # The way out a relative path can try: a link in the project to the folder outside.
    File.ln_s!(outside, Path.join(root, "out"))
    Process.put(:root, root)
    Process.put(:outside, outside)
  end

  # --- model ------------------------------------------------------------------

  # name => {:text, contents} | :binary | :big | :folder | {:link, name}; absent is missing.
  def initial_state, do: %{}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :put_text, [oneof(@names), oneof(@texts)]}},
      {1, {:call, __MODULE__, :put, [oneof(@names), oneof([:binary, :big, :folder])]}},
      {2, {:call, __MODULE__, :link, [oneof(@names), oneof(@names)]}},
      {1, {:call, __MODULE__, :remove, [oneof(@names)]}},
      {5,
       {:call, __MODULE__, :write,
        [oneof(@names), oneof(@texts), oneof([:full, :dotdot, :link]), boolean()]}}
    ])
  end

  def precondition(_state, {:call, _, :link, [name, target]}), do: name != target
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put_text, [name, text]}),
    do: Map.put(state, name, {:text, text})

  def next_state(state, _result, {:call, _, :put, [name, kind]}), do: Map.put(state, name, kind)

  def next_state(state, _result, {:call, _, :link, [name, target]}),
    do: Map.put(state, name, {:link, target})

  def next_state(state, _result, {:call, _, :remove, [name]}), do: Map.delete(state, name)

  def next_state(state, _result, {:call, _, :write, [name, text, how, terminal?]}) do
    case resolve(state, name) do
      {target, {:text, _}} when how == :full and terminal? ->
        Map.put(state, target, {:text, text})

      _ ->
        state
    end
  end

  def postcondition(
        state,
        {:call, _, :write, [name, _, how, terminal?]} = call,
        {result, seen, project}
      ) do
    refused_scope? = how == :full and not terminal?
    written? = how == :full and terminal? and match?({_, {:text, _}}, resolve(state, name))

    answered =
      case result do
        {:ok, %{"relativePath" => shown}} -> written? and shown == path(name)
        :terminal_operate_required -> refused_scope?
        {:error, %{"_tag" => "ProjectWriteFileError"}} -> not written? and not refused_scope?
        _ -> false
      end

    answered and project == ["out"] and seen == next_state(state, nil, call)
  end

  def postcondition(_state, _call, _result), do: true

  # The entry `name` ends at through its links, and its name; nil for a missing
  # one or a loop.
  defp resolve(state, name, seen \\ []) do
    case Map.get(state, name) do
      {:link, target} -> if target in seen, do: nil, else: resolve(state, target, [name | seen])
      nil -> nil
      entry -> {name, entry}
    end
  end

  # --- commands ---------------------------------------------------------------

  def put_text(name, text) do
    clear(name)
    File.write!(path(name), text)
  end

  def put(name, :binary) do
    clear(name)
    File.write!(path(name), <<0, 1, 2, 255>>)
  end

  def put(name, :big) do
    clear(name)
    File.write!(path(name), :binary.copy("a", @big_bytes))
  end

  def put(name, :folder) do
    clear(name)
    File.mkdir!(path(name))
  end

  def link(name, target) do
    clear(name)
    File.ln_s!(path(target), path(name))
  end

  def remove(name), do: clear(name)

  # The write by a session with or without terminal access, as the socket gates it;
  # what the host outside the project holds after it; and the project.
  def write(name, text, how, terminal?) do
    root = Process.get(:root)

    relative =
      case how do
        :full -> path(name)
        :dotdot -> "../outside/#{name}"
        :link -> "out/#{name}"
      end

    input = %{"cwd" => root, "relativePath" => relative, "contents" => text}
    scopes = HalC2.Auth.standard_scopes()
    scopes = if terminal?, do: scopes, else: scopes -- ["terminal:operate"]

    result =
      if HalC2.Rpc.required_scope("projects.writeFile", input) in scopes,
        do: Workspace.write_file(input),
        else: :terminal_operate_required

    {result, seen(), File.ls!(root)}
  end

  defp seen do
    outside = Process.get(:outside)

    for entry <- File.ls!(outside), into: %{} do
      file = Path.join(outside, entry)
      name = String.to_existing_atom(entry)

      case File.lstat!(file) do
        %File.Stat{type: :symlink} ->
          {name,
           {:link, file |> File.read_link!() |> Path.basename() |> String.to_existing_atom()}}

        %File.Stat{type: :directory} ->
          {name, :folder}

        %File.Stat{size: size} when size >= @big_bytes ->
          {name, :big}

        _ ->
          contents = File.read!(file)
          {name, if(String.contains?(contents, <<0>>), do: :binary, else: {:text, contents})}
      end
    end
  end

  defp clear(name), do: File.rm_rf!(path(name))
  defp path(name), do: Path.join(Process.get(:outside), Atom.to_string(name))
end
