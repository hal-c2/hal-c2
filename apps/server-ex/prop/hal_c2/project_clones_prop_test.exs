defmodule HalC2.ProjectClonesPropTest do
  @moduledoc """
  `HalC2.ProjectClones` against a model of what a clone promises, with real `git`
  cloning a local repository through gates (`HalC2.Test.CloneGate`) the property holds
  and releases, one at the fetch and one at the checkout of the last file: a clone
  runs until it is let on, finish or fail, is cancelled, retried, or its project
  deleted; git reports progress; the user puts files of their own in a clone's folder
  at any time; and threads are started in its project.

  The invariant under all of it is about the user's files: after every step each
  folder holds exactly what the model says, the user's files always and of the
  clone's only what git wrote and has not been taken away. Cancelling, deleting the
  project or retrying takes away the clone's `.git` and what it checked out, and
  nothing else; a finished checkout is never taken away. Nothing outside the clones'
  folders is touched. (git's own cleanup of a fetch that failed empties the folder,
  the user's files included; the model says so. A failed checkout git leaves.)

  Two folders and fresh project ids keep clones colliding on a folder: a second
  clone into a folder another clone holds is refused, as is one into a folder with
  files, and a retry into a folder the user has since put files in.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.ProjectClones
  alias HalC2.Test.CloneGate

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @slots ["a", "b"]
  # What git has written once it holds at the checkout of zz.txt, and once done.
  @partial [".git", ".gitattributes", "README.md", "src"]
  @checkout @partial ++ ["zz.txt"]
  @files %{
    ".gitattributes" => "zz.txt filter=gate\n",
    "README.md" => "shop\n",
    "src/app.txt" => "app\n",
    "src/lib/util.txt" => "util\n",
    "zz.txt" => "last\n"
  }
  @lines [
    {"remote: Counting objects:  40% (4/10)", "counting"},
    {"Receiving objects:  45% (45/100)", "receiving"},
    {"Resolving deltas: 100% (3/3), done.", "resolving"},
    {"Updating files:  80% (8/10)", "checkout"}
  ]

  property "a clone never touches files it did not write",
    numtests: HalC2.Prop.numtests(30),
    max_size: 25 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("project-clones")
        root = Path.join(home, "fs")
        File.mkdir_p!(root)
        File.write!(Path.join(root, "outside.txt"), "not a clone's")
        Process.put(:root, root)
        port = CloneGate.listen()
        Process.put(:port, port)
        Process.put(:bare, CloneGate.repo(Path.join(home, "repos"), @files))

        unset =
          CloneGate.git_config(%{
            "protocol.ext.allow" => "always",
            "filter.gate.smudge" => CloneGate.smudge(port, "@cwd"),
            "filter.gate.required" => "true"
          })

        drain()

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Streams,
          HalC2.Shell,
          ProjectClones
        ])

        {:ok, _} = ProjectClones.subscribe(self())
        {history, state, result} = run_commands(__MODULE__, cmds)

        # Stops every git still running before the services go.
        for {id, %{phase: :running}} <- state.clones,
            do: ProjectClones.cancel(%{"projectId" => id})

        HalC2.Prop.stop_services()
        CloneGate.stop()
        unset.()
        drain()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------

  # clones: id => %{phase: :running | :done | :failed | :cancelled | :deleted, slot,
  # stage: :fetch | :checkout}, the gate a running clone is held at.
  # made: the folders that exist; user: slot => the user's files in it;
  # wrote: slot => what of the clone's is in it.
  def initial_state,
    do: %{
      next: 1,
      clones: %{},
      made: MapSet.new(),
      user: Map.new(@slots, &{&1, []}),
      wrote: Map.new(@slots, &{&1, []}),
      files: 0,
      threads: 0
    }

  def command(state) do
    ids = Map.keys(state.clones)
    at = fn stage -> for {id, %{phase: :running, stage: ^stage}} <- state.clones, do: id end
    running = at.(:fetch) ++ at.(:checkout)

    always = [
      {2, {:call, __MODULE__, :start, ["p#{state.next}", oneof(@slots)]}},
      {1, {:call, __MODULE__, :user_writes, [oneof(@slots), "u#{state.files + 1}"]}}
    ]

    some = fn weight, list, call ->
      if list == [], do: [], else: [{weight, call.(oneof(list))}]
    end

    frequency(
      always ++
        some.(1, running, &{:call, __MODULE__, :progress, [&1, oneof(@lines)]}) ++
        some.(3, at.(:fetch), &{:call, __MODULE__, :checkout, [&1]}) ++
        some.(3, at.(:checkout), &{:call, __MODULE__, :finish, [&1]}) ++
        some.(2, running, &{:call, __MODULE__, :fail, [&1]}) ++
        some.(2, ids, &{:call, __MODULE__, :cancel, [&1]}) ++
        some.(2, ids, &{:call, __MODULE__, :retry, [&1]}) ++
        some.(2, ids, &{:call, __MODULE__, :delete, [&1]}) ++
        some.(1, ids, &{:call, __MODULE__, :thread_create, [&1, "t#{state.threads + 1}"]})
    )
  end

  def precondition(state, {:call, _, :start, [id, _]}), do: id == "p#{state.next}"
  def precondition(state, {:call, _, :user_writes, [_, name]}), do: name == "u#{state.files + 1}"

  def precondition(state, {:call, _, command, [id | _]}) when command in [:progress, :fail],
    do: phase(state, id) == :running

  def precondition(state, {:call, _, :checkout, [id]}),
    do: phase(state, id) == :running and state.clones[id].stage == :fetch

  def precondition(state, {:call, _, :finish, [id]}),
    do: phase(state, id) == :running and state.clones[id].stage == :checkout

  def precondition(state, {:call, _, :thread_create, [id, name]}),
    do: phase(state, id) not in [nil, :deleted] and name == "t#{state.threads + 1}"

  def precondition(state, {:call, _, :delete, [id]}), do: phase(state, id) not in [nil, :deleted]
  def precondition(state, {:call, _, _, [id]}), do: Map.has_key?(state.clones, id)

  def next_state(state, _result, {:call, _, :start, [id, slot]}) do
    state = %{state | next: state.next + 1}

    case start_outcome(state, slot) do
      :ok ->
        %{
          state
          | clones: Map.put(state.clones, id, %{phase: :running, slot: slot, stage: :fetch})
        }
        |> made(slot)
        |> wrote(slot, [".git"])

      _refused ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :user_writes, [slot, name]}) do
    %{state | files: state.files + 1, user: Map.update!(state.user, slot, &[name | &1])}
    |> made(slot)
  end

  def next_state(state, _result, {:call, _, :progress, _}), do: state

  def next_state(state, _result, {:call, _, :checkout, [id]}) do
    state
    |> put_in([:clones, id, :stage], :checkout)
    |> wrote(slot(state, id), @partial)
  end

  def next_state(state, _result, {:call, _, :finish, [id]}),
    do: state |> phase(id, :done) |> wrote(slot(state, id), @checkout)

  # git empties the folder of a clone whose fetch failed, the user's files included;
  # a failed checkout it leaves as it was.
  def next_state(state, _result, {:call, _, :fail, [id]}) do
    slot = slot(state, id)
    state = phase(state, id, :failed)

    if state.clones[id].stage == :fetch,
      do: %{state | user: Map.put(state.user, slot, [])} |> wrote(slot, []),
      else: state
  end

  def next_state(state, _result, {:call, _, :cancel, [id]}) do
    if phase(state, id) == :running,
      do: state |> phase(id, :cancelled) |> wrote(slot(state, id), []),
      else: state
  end

  # A retry takes away what the failed clone left, then starts again if nothing else is there.
  def next_state(state, _result, {:call, _, :retry, [id]}) do
    slot = slot(state, id)

    case retry_outcome(state, id) do
      :applied ->
        state
        |> put_in([:clones, id], %{phase: :running, slot: slot, stage: :fetch})
        |> wrote(slot, [".git"])

      :user_files ->
        wrote(state, slot, [])

      :nothing ->
        state
    end
  end

  def next_state(state, _result, {:call, _, :delete, [id]}) do
    state = if phase(state, id) == :done, do: state, else: wrote(state, slot(state, id), [])
    phase(state, id, :deleted)
  end

  def next_state(state, _result, {:call, _, :thread_create, _}),
    do: %{state | threads: state.threads + 1}

  def postcondition(state, call, {result, listing}) do
    after_call = next_state(state, result, call)
    listing == expected_listing(after_call) and answer?(state, call, result)
  end

  defp answer?(state, {:call, _, :start, [_, slot]}, result) do
    case start_outcome(state, slot) do
      :ok -> result == :held
      :claimed -> result == {:error, "A clone into this destination is already in progress."}
      :not_empty -> result == {:error, "Destination path already exists and is not empty."}
    end
  end

  defp answer?(_state, {:call, _, :user_writes, _}, result), do: result == :ok

  # git's own lines from before it got to its gate may still be on their way.
  defp answer?(_state, {:call, _, :progress, _}, result),
    do: match?({"running", stage} when stage in ~w(counting receiving resolving checkout), result)

  defp answer?(_state, {:call, _, :checkout, _}, result), do: result == :held
  defp answer?(_state, {:call, _, :finish, _}, result), do: result == "done"

  defp answer?(_state, {:call, _, :fail, _}, result),
    do: match?({"failed", error} when is_binary(error), result) and elem(result, 1) =~ "denied"

  defp answer?(state, {:call, _, :cancel, [id]}, result),
    do: result == {:ok, %{"applied" => phase(state, id) == :running}}

  defp answer?(state, {:call, _, :retry, [id]}, result) do
    case retry_outcome(state, id) do
      :applied ->
        result == :held

      :user_files ->
        result == {:error, "Destination path contains files that are not from the clone."}

      :nothing ->
        result == {:ok, %{"applied" => false}}
    end
  end

  defp answer?(_state, {:call, _, :delete, _}, result), do: result == :gone

  defp answer?(state, {:call, _, :thread_create, [id, _]}, result) do
    case phase(state, id) do
      :running ->
        result == {:error, "The repository is still being cloned."}

      p when p in [:failed, :cancelled] ->
        result == {:error, "The repository was not cloned. Retry the clone first."}

      :done ->
        match?({:ok, _}, result)
    end
  end

  defp start_outcome(state, slot) do
    cond do
      Enum.any?(state.clones, fn {_, c} ->
        c.slot == slot and c.phase in [:running, :failed, :cancelled]
      end) ->
        :claimed

      state.user[slot] != [] or state.wrote[slot] != [] ->
        :not_empty

      true ->
        :ok
    end
  end

  defp retry_outcome(state, id) do
    cond do
      phase(state, id) not in [:failed, :cancelled] -> :nothing
      state.user[slot(state, id)] != [] -> :user_files
      true -> :applied
    end
  end

  # What each folder holds: the user's files and what of the clone's is left.
  # `nil` for a folder never made.
  defp expected_listing(state) do
    folders =
      Map.new(@slots, fn slot ->
        if MapSet.member?(state.made, slot),
          do: {slot, Enum.sort(state.user[slot] ++ state.wrote[slot])},
          else: {slot, nil}
      end)

    Map.put(folders, :outside, "not a clone's")
  end

  defp phase(state, id), do: state.clones[id][:phase]
  defp phase(state, id, phase), do: put_in(state.clones[id].phase, phase)
  defp slot(state, id), do: state.clones[id].slot
  defp made(state, slot), do: %{state | made: MapSet.put(state.made, slot)}
  defp wrote(state, slot, names), do: %{state | wrote: Map.put(state.wrote, slot, names)}

  # --- commands -------------------------------------------------------------------

  def start(id, slot) do
    url = CloneGate.transport_url(Process.get(:port), id, Process.get(:bare))

    result =
      case ProjectClones.start(%{
             "projectId" => id,
             "title" => slot,
             "remoteUrl" => url,
             "destinationPath" => folder(slot)
           }) do
        {:ok, _} -> held(id)
        error -> error
      end

    {result, listing()}
  end

  def user_writes(slot, name) do
    File.mkdir_p!(folder(slot))
    File.write!(Path.join(folder(slot), name), "the user's")
    {:ok, listing()}
  end

  def progress(id, {line, _stage}) do
    send(ProjectClones, {:clone_progress, id, ProjectClones.progress(line)})
    snapshot = :sys.get_state(ProjectClones).clones[id]
    {{snapshot["phase"], snapshot["stage"]}, listing()}
  end

  # Lets the fetch go on until git holds at the checkout of the last file, which is
  # named after the clone's folder.
  def checkout(id) do
    drain()
    CloneGate.release(Process.delete({:gate, id}), "ok")
    slot = Path.basename(:sys.get_state(ProjectClones).clones[id]["destinationPath"])
    Process.put({:gate, id}, CloneGate.await(slot))
    {:held, listing()}
  end

  def finish(id) do
    drain()
    CloneGate.release(Process.delete({:gate, id}), "ok")
    {await(id, &(&1["phase"] in ["done", "failed"]))["phase"], listing()}
  end

  def fail(id) do
    drain()
    CloneGate.release(Process.delete({:gate, id}), "access denied")
    snapshot = await(id, &(&1["phase"] in ["done", "failed"]))
    {{snapshot["phase"], snapshot["error"]}, listing()}
  end

  def cancel(id) do
    result = ProjectClones.cancel(%{"projectId" => id})
    drop_gate(id)
    {result, listing()}
  end

  def retry(id) do
    result =
      case ProjectClones.retry(%{"projectId" => id}) do
        {:ok, %{"applied" => true}} -> held(id)
        other -> other
      end

    {result, listing()}
  end

  def delete(id) do
    {:ok, _} =
      HalC2.Projects.mutate(%{"type" => "project.delete", "projectId" => id, "force" => true})

    drop_gate(id)
    reported = Enum.any?(:sys.get_state(ProjectClones).clones, fn {other, _} -> other == id end)
    {if(reported, do: :still_reported, else: :gone), listing()}
  end

  def thread_create(id, thread) do
    result =
      HalC2.Orchestration.dispatch(%{
        "type" => "thread.create",
        "commandId" => "cmd-#{thread}",
        "threadId" => "#{id}-#{thread}",
        "projectId" => id,
        "title" => thread
      })

    {result, listing()}
  end

  # --- helpers --------------------------------------------------------------------

  defp folder(slot), do: Path.join(Process.get(:root), slot)

  defp listing do
    folders =
      Map.new(@slots, fn slot ->
        case File.ls(folder(slot)) do
          {:ok, names} -> {slot, Enum.sort(names)}
          {:error, :enoent} -> {slot, nil}
        end
      end)

    Map.put(folders, :outside, File.read!(Path.join(Process.get(:root), "outside.txt")))
  end

  # git has made the clone's `.git` and waits at its gate.
  defp held(id) do
    Process.put({:gate, id}, CloneGate.await(id))
    :held
  end

  # A gate git no longer waits on; closing it lets the gate process end.
  defp drop_gate(id) do
    case Process.delete({:gate, id}) do
      nil -> :ok
      socket -> :gen_tcp.close(socket)
    end
  end

  # Forgets the changes so far, so `await/2` sees only those that come after.
  defp drain do
    receive do
      {:hal_c2_project_clones, _mc, _snapshots} -> drain()
    after
      0 -> :ok
    end
  end

  # The clone's snapshot once a change satisfies `fun`, from the changes this case
  # subscribed to, in order.
  defp await(id, fun) do
    receive do
      {:hal_c2_project_clones, _mc, snapshots} ->
        snapshot = Enum.find(snapshots, &(&1["projectId"] == id))
        if snapshot && fun.(snapshot), do: snapshot, else: await(id, fun)
    after
      15_000 -> raise "clone #{id} never got there"
    end
  end
end
