defmodule HalC2.ThreadMove do
  @moduledoc """
  Moves a thread to another member of the cluster. The thread keeps its id; the
  machine it left keeps only a forwarding record (`movedTo` on its thread entity), so
  links and forks that name it still find it (`locate/1`).

  `move/3` runs on the thread's MC. It refuses a thread that is running, waiting for
  an answer or already moving, asks the destination whether it can take it (`fit/1`:
  the agent, the project, the space), and returns what does not come along for the
  user to confirm. The thread is then marked `moving` and read-only, sent as a
  `HalC2.ThreadArchive`, and the destination stages it before importing it
  (`accept/3`). The files it carries (the agent's session, the git bundles, the
  attachments) go from disk to disk a chunk at a time (`read/3`), so neither machine
  holds a large thread in memory. Only once the destination has it does the source let
  go.

  A move that breaks off must not leave the thread on both machines, and the call the
  source waits on can end (a lost connection, a timeout) while the destination works
  on. So the destination asks before it imports (`taking/2`), and the source answers
  yes only while the thread is still in that move. A move that breaks off before that
  clears `moving` and leaves the thread where it was: the destination is refused when
  it asks. One that breaks off after it stays `moving` until the destination says
  whether it holds the thread (`arrived?/1`).

  This process settles those, and moves a restart cut off: at boot, when a destination
  comes back, and again while a destination is still taking a thread, a thread marked
  `moving` becomes a forwarding record if the destination holds it, and is released if
  it does not. At boot it also discards copies this MC was receiving when it stopped.

  Results are `{:ok, %{"status" => ...}}`: `"moved"`, `"confirm"` (call again with
  `confirmed: true`) or `"choose_project"` (call again with `project:`), or
  `{:error, %{"code", "message"}}`.
  """

  use GenServer

  require Logger

  alias HalC2.{Orchestration, Patch, Shell, StreamState, Streams, ThreadArchive}

  @active ~w(preparing starting running waiting)
  @names %{"codex" => "Codex", "claudeAgent" => "Claude", "pi" => "Pi"}
  # Free space a move leaves on the destination, beyond the thread itself.
  @reserve 256 * 1024 * 1024
  @timeout 600_000
  # How much of a carried file crosses the cluster connection at a time.
  @chunk 512 * 1024
  # Bytes a second: the slowest connection a move is still waited on over.
  @slowest 128 * 1024
  # How long until a destination still taking a thread is asked again whether it has it.
  @again 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # --- source --------------------------------------------------------------------

  @doc """
  Moves the thread `ref` (id or title) to the machine `to` (its environment id, or its
  label when no other machine has the same one). `opts`: `project:` the destination project (id or title), `confirmed:` true
  once the user accepted what does not come along.
  """
  def move(ref, to, opts \\ []) do
    with {:ok, id} <- thread_id(ref),
         thread = thread(id),
         :ok <- movable(state(id), thread),
         {:ok, dest} <- destination(to, thread),
         :ok <- online(dest, thread),
         :ok <- save_terminals(id),
         have = has(dest, thread, opts[:project]),
         {:ok, archive} <- build(id, have: have) do
      try do
        with {:ok, %{"project" => _} = fit} <-
               ask(dest, :fit, [request(archive, opts[:project])], thread),
             notes = fit["notes"] ++ source_notes(id, thread, archive, dest),
             :ok <- confirmed(notes, opts[:confirmed] == true),
             {:ok, archive, moving} <- begin(id, dest, archive, have) do
          try do
            transfer(id, dest, archive, moving, fit, notes)
          after
            GenServer.cast(__MODULE__, {:done, id, moving["id"]})
          end
        end
      after
        ThreadArchive.discard(archive)
      end
    end
  end

  @doc """
  Moves the thread `ref` once its running turn ends, as `move/3` with `confirmed:
  true`: an agent moving its own thread cannot stop its turn to do it. The
  destination is checked now; the rest when the move runs, and a move that is
  then refused is logged. Returns `{:ok, %{"status" => "scheduled", ...}}`.
  """
  def after_turn(ref, to, opts \\ []) do
    with {:ok, id} <- thread_id(ref),
         thread = thread(id),
         :ok <- movable(state(id), thread, true),
         {:ok, dest} <- destination(to, thread),
         :ok <- online(dest, thread) do
      :ok = GenServer.call(__MODULE__, {:after_turn, id, to, opts})

      {:ok,
       %{
         "status" => "scheduled",
         "threadId" => id,
         "machine" => dest.label,
         "environmentId" => dest.environment,
         "message" => "#{thread["title"]} moves to #{dest.label} when this turn ends."
       }}
    end
  end

  @doc """
  The machines the thread `ref` could move to: `%{"machine", "environmentId",
  "online", "projects"}`, each project as `%{"id", "title", "workspaceRoot",
  "sameRepository"}` (only for a machine that is online).
  """
  def destinations(ref) do
    with {:ok, id} <- thread_id(ref),
         {:ok, meta} <- describe(thread(id)) do
      online = Node.list()

      {:ok,
       for {mc, descriptor} <- Enum.sort_by(Shell.environments(), &elem(&1, 1)["label"]),
           mc != node() do
         up = mc in online

         %{
           "machine" => descriptor["label"],
           "environmentId" => descriptor["environmentId"],
           "online" => up,
           "projects" => if(up, do: remote(mc, :projects, [meta]) |> ok_or([]), else: [])
         }
       end}
    end
  end

  @doc """
  Where a thread lives now, following forwarding records: `{:ok, %{"mc",
  "environmentId", "machine"}}`, or `{:error, message}` when it was deleted or is
  not known.
  """
  def locate(id) do
    rows = for {{mc, ^id}, {"thread", row}} <- Shell.rows(), do: {mc, row}
    # Late in a move both ends list it: the one it is going to holds it by then.
    live = Enum.filter(rows, fn {_mc, row} -> row["movedTo"] == nil end)

    case Enum.find(live, List.first(live), fn {_mc, row} -> row["moving"] == nil end) do
      {_mc, %{"deletedAt" => deleted, "title" => title}} when deleted != nil ->
        {:error, "#{title} was deleted."}

      {mc, _row} ->
        {:ok, where(mc)}

      nil ->
        follow(id, rows)
    end
  end

  # Only forwarding records are known here: ask where the last one points.
  defp follow(id, [_ | _] = rows) do
    {_, row} = Enum.max_by(rows, fn {_, row} -> row["movedTo"]["at"] || "" end)
    mc = String.to_atom(row["movedTo"]["mc"])

    case remote(mc, :holds?, [id]) do
      true ->
        {:ok, where(mc)}

      :deleted ->
        {:error, "#{row["title"]} was deleted on #{row["movedTo"]["label"]}."}

      false ->
        {:error, "#{row["title"]} is not on #{row["movedTo"]["label"]} any more."}

      {:error, _} ->
        {:ok, where(mc) |> Map.put("online", false)}
    end
  end

  defp follow(id, []), do: {:error, "There is no thread #{id} in the cluster."}

  defp where(mc) do
    descriptor = Enum.find_value(Shell.environments(), %{}, fn {n, d} -> if n == mc, do: d end)

    %{
      "mc" => Atom.to_string(mc),
      "environmentId" => descriptor["environmentId"],
      "machine" => descriptor["label"]
    }
  end

  defp thread_id(ref) do
    case ThreadArchive.find_thread(ref) do
      {:ok, id} -> {:ok, id}
      {:error, message} -> error(:invalid_request, message)
    end
  end

  # A machine is named by what only it has (its environment id or MC name), or by its
  # label, which the user gave it and another machine may share.
  defp destination(to, thread) do
    environments = Shell.environments()

    named =
      case Enum.filter(environments, fn {mc, d} ->
             to in [d["environmentId"], Atom.to_string(mc)]
           end) do
        [] -> Enum.filter(environments, fn {_, d} -> d["label"] == to end)
        named -> named
      end

    case named do
      [] ->
        error(:invalid_request, "There is no machine #{to} in the cluster.")

      [{mc, descriptor}] when mc == node() ->
        error(:invalid_request, "#{thread["title"]} is already on #{descriptor["label"]}.")

      [{mc, descriptor}] ->
        {:ok, %{mc: mc, label: descriptor["label"], environment: descriptor["environmentId"]}}

      several ->
        ids = Enum.map_join(several, ", ", fn {_, d} -> d["environmentId"] end)

        error(
          :invalid_request,
          "Several machines are called #{to}. Name the one meant by its environment id: #{ids}."
        )
    end
  end

  # `after_turn`: the thread's own agent asked, so its running turn is expected.
  defp movable(state, thread, after_turn \\ false) do
    title = thread["title"]
    runs = StreamState.list(state, "run")
    requests = StreamState.list(state, "runtime-request")

    cond do
      moved = thread["movedTo"] ->
        error(:thread_not_movable, "#{title} has already moved to #{moved["label"]}.")

      moving = thread["moving"] ->
        error(:thread_not_movable, "#{title} is already moving to #{moving["label"]}.")

      thread["deletedAt"] ->
        error(:thread_not_movable, "#{title} was deleted.")

      # What the plugin keeps of its thread (and the tools it gives the thread's agent)
      # stays on this machine; once the plugin stops, the thread is an ordinary one.
      (owner = thread["plugin"]["id"]) && HalC2.Plugins.running?(owner) ->
        error(
          :thread_not_movable,
          "#{title} was started by #{owner} and stays on this machine while #{owner} runs."
        )

      after_turn ->
        :ok

      Enum.any?(requests, &(&1["status"] == "pending")) ->
        error(
          :thread_not_movable,
          "#{title} is waiting for an answer. Answer or stop #{title} before moving it."
        )

      Enum.any?(runs, &(&1["status"] in @active)) ->
        error(
          :thread_not_movable,
          "#{title} is running. Stop it or wait for it to finish before moving it."
        )

      true ->
        :ok
    end
  end

  defp online(dest, thread) do
    if dest.mc in Node.list(),
      do: :ok,
      else: error(:mc_unavailable, "#{dest.label} is offline. #{thread["title"]} was not moved.")
  end

  defp build(id, opts) do
    case ThreadArchive.build(id, opts) do
      {:ok, archive} -> {:ok, archive}
      {:error, message} -> error(:thread_not_movable, message)
    end
  end

  defp describe(thread) do
    case ThreadArchive.describe(thread) do
      {:ok, meta} -> {:ok, meta}
      {:error, message} -> error(:thread_not_movable, message)
    end
  end

  # The commits the destination's checkout for the thread has, which a move leaves out.
  defp has(dest, thread, project) do
    with {:ok, meta} <- ThreadArchive.describe(thread),
         have when is_list(have) <-
           remote(dest.mc, :have, [%{"thread" => meta, "project" => project}]) do
      have
    else
      _ -> []
    end
  end

  defp meta(archive), do: archive["thread"]

  # What the destination needs to decide whether it can take the thread.
  defp request(archive, project) do
    %{
      "thread" => meta(archive),
      "instanceId" => meta(archive)["instanceId"],
      "size" =>
        :erlang.external_size(archive) +
          Enum.sum(for file <- ThreadArchive.files(archive), do: file["size"] || 0),
      "checkpoints" => archive["checkpoints"] != nil,
      "project" => project
    }
  end

  # What the source knows does not come along.
  defp source_notes(id, thread, archive, dest) do
    title = thread["title"]
    state = state(id)

    terminals =
      for terminal <- running_terminals(id),
          do:
            "The terminal #{terminal} of #{title} is running on #{ThreadArchive.label()}; it will be closed. Its scrollback goes with #{title}."

    changes =
      with nil <- thread["worktreePath"],
           root when is_binary(root) <- archive["thread"]["projectRoot"],
           {:ok, status} when status != "" <- HalC2.Git.ok(root, ~w(status --porcelain)) do
        [
          "The uncommitted changes in #{archive["thread"]["projectTitle"] || "the project"} stay on #{ThreadArchive.label()}; the checkout on #{dest.label} is left as it was."
        ]
      else
        _ -> []
      end

    handoff =
      if archive["session"] == nil and StreamState.list(state, "provider-thread") != [],
        do: [
          "#{provider_name(archive["thread"]["instanceId"])} on #{dest.label} will get a summary of the conversation instead of continuing its own session."
        ],
        else: []

    changes ++ terminals ++ handoff
  end

  defp confirmed([], _), do: :ok
  defp confirmed(_notes, true), do: :ok

  defp confirmed(notes, false),
    do:
      {:ok,
       %{
         "status" => "confirm",
         "message" => "Moving leaves some things behind. Confirm to move.",
         "notes" => notes
       }}

  # Marks the thread moving, unless something changed it since it was checked; the
  # archive is rebuilt when the thread changed since it was built. `moving["id"]` names
  # this move: a destination still working on an earlier one is told apart by it.
  defp begin(id, dest, archive, have) do
    at = Orchestration.Entities.now()
    move = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    marked =
      Streams.transact(id, :thread, fn state ->
        thread = StreamState.get(state, "thread")[id]

        case movable(state, thread) do
          :ok ->
            moving = %{
              "id" => move,
              "label" => dest.label,
              "environmentId" => dest.environment,
              "mc" => Atom.to_string(dest.mc),
              "at" => at
            }

            {[Orchestration.upsert(state, "thread", id, &Map.put(&1, "moving", moving))],
             {:ok, state.updated_at == archive["updatedAt"], moving}}

          error ->
            {[], error}
        end
      end)

    with {:ok, unchanged?, moving} <- marked do
      Streams.flush_shell(id)
      # The process moving the thread may die anywhere from here (its client went
      # away); this process then settles the move at once rather than leave the thread
      # read-only until the destination comes back.
      GenServer.cast(__MODULE__, {:watch, self(), id, move})

      with {:ok, archive} <-
             if(unchanged?,
               do: {:ok, archive},
               else: with_release(id, move, fn -> build(id, have: have) end)
             ),
           do: {:ok, archive, moving}
    end
  end

  # How long the destination gets to take a thread: the time its files take over a slow
  # connection on top of what any move gets, so a large thread that is still arriving
  # is not cut off. A destination that goes offline ends the wait at once.
  defp patience(archive, data) do
    files = for file <- ThreadArchive.files(archive), do: file["size"] || 0
    @timeout + div((byte_size(data) + Enum.sum(files)) * 1000, @slowest)
  end

  # `archive` may be one `begin/4` built again, so its files are discarded here too.
  defp transfer(id, dest, archive, moving, fit, notes) do
    data = ThreadArchive.encode(archive)
    title = archive["thread"]["title"]
    hook(:sending, id)

    result =
      try do
        :erpc.call(
          dest.mc,
          __MODULE__,
          :accept,
          [data, node(), [project: fit["project"], move: moving["id"]]],
          patience(archive, data)
        )
      catch
        kind, reason -> {:broken, {kind, reason}}
      after
        ThreadArchive.discard(archive)
      end

    case result do
      {:ok, imported} ->
        hook(:accepted, id)
        let_go(id, dest, imported)
        carried = imported[:session] == true

        {:ok,
         %{
           "status" => "moved",
           "threadId" => id,
           "machine" => dest.label,
           "environmentId" => dest.environment,
           "projectId" => imported[:project],
           "sessionCarried" => carried,
           "message" => moved_message(title, dest.label, carried, archive),
           "notes" => Enum.uniq(notes ++ (imported[:notes] || []))
         }}

      {:error, message} ->
        release_own(id, moving["id"])
        error(:thread_not_movable, message)

      {:broken, reason} ->
        Logger.warning("move of #{id} to #{dest.mc} broke off: #{inspect(reason)}")

        # The call ending does not stop the destination: it is refused from here on if
        # it had not asked to take the thread yet, and has the last word if it had.
        release(id, moving)

        if thread(id)["moving"] do
          error(
            :mc_unavailable,
            "The move of #{title} to #{dest.label} was cut off while #{dest.label} was taking it. #{title} stays read-only until #{dest.label} says whether it has it."
          )
        else
          error(
            :mc_unavailable,
            "The move of #{title} to #{dest.label} did not finish. #{title} is still on #{ThreadArchive.label()} and can be moved again."
          )
        end
    end
  end

  defp moved_message(title, label, true, _archive),
    do: "#{title} moved to #{label}. The agent continues its own session there."

  defp moved_message(title, label, false, archive) do
    if Enum.any?(archive["entities"], &(hd(&1) == "provider-thread")),
      do: "#{title} moved to #{label}. The agent there will get a summary of the conversation.",
      else: "#{title} moved to #{label}."
  end

  # The destination holds the thread: this MC keeps only the forwarding record. Its
  # provider processes stop, and its terminals close (their scrollback travelled).
  defp let_go(id, dest, imported) do
    _ = Orchestration.release_session(id)
    at = Orchestration.Entities.now()

    moved = %{
      "label" => dest.label,
      "environmentId" => dest.environment,
      "mc" => Atom.to_string(dest.mc),
      "projectId" => imported[:project],
      "at" => at
    }

    :ok =
      Streams.transact(id, :thread, fn state ->
        others =
          for {kind, eid, _} <- StreamState.rows(state),
              {kind, eid} != {"thread", id},
              do: {kind, eid, Patch.delete()}

        # The agent sessions the thread ran here stay in the providers' homes; they
        # are the thread's, so an import of this machine's history skips them.
        sessions =
          for pt <- StreamState.list(state, "provider-thread"),
              %{"driver" => driver, "nativeId" => native} <- [pt["nativeThreadRef"]],
              is_binary(native),
              do: "#{driver}:#{native}"

        moved = if sessions == [], do: moved, else: Map.put(moved, "sessions", sessions)

        forward =
          Orchestration.upsert(state, "thread", id, fn thread ->
            thread
            |> Map.drop(["moving", "arrived"])
            |> Map.merge(%{"movedTo" => moved, "worktreePath" => nil, "updatedAt" => at})
          end)

        {Enum.reject([forward | others], &is_nil/1), :ok}
      end)

    if Process.whereis(HalC2.Terminal.Registry),
      do: HalC2.Terminal.close(%{"threadId" => id, "deleteHistory" => true})

    Streams.flush_shell(id)
  end

  # Clears `moving` if it is still the move `move`: a mover that comes back after a
  # later move began must not call that one off.
  defp release_own(id, move) do
    release(id, &match?(%{"id" => ^move}, &1))
    :ok
  end

  # Clears `moving`, and says whether it did. Given the move as it was last seen
  # (`moving`), only if it still is that: not once the destination was told to take it.
  defp release(id, seen) when is_map(seen), do: release(id, &(&1 == seen))

  defp release(id, seen?) do
    released =
      Streams.transact(id, :thread, fn state ->
        case StreamState.get(state, "thread")[id] do
          %{"moving" => moving} ->
            if seen?.(moving),
              do: {[Orchestration.upsert(state, "thread", id, &Map.delete(&1, "moving"))], true},
              else: {[], false}

          _ ->
            {[], false}
        end
      end)

    Streams.flush_shell(id)
    released
  end

  @doc """
  The destination of the move `move` of the thread `id` asks to take it, having staged
  its files: `:ok` while the thread is still in that move here, which then waits for
  the destination's word (`arrived?/1`); `:gone` once the move was called off.
  """
  def taking(id, move) do
    Streams.transact(id, :thread, fn state ->
      case StreamState.get(state, "thread")[id] do
        %{"moving" => %{"id" => ^move}} ->
          {[Orchestration.upsert(state, "thread", id, &put_in(&1, ["moving", "taking"], true))],
           :ok}

        _ ->
          {[], :gone}
      end
    end)
  end

  defp with_release(id, move, fun) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      error ->
        release_own(id, move)
        error
    end
  end

  # Running terminals' scrollback travels as it is now.
  defp save_terminals(id) do
    if Process.whereis(HalC2.Terminal.Registry), do: HalC2.Terminal.save(id)
    :ok
  end

  defp running_terminals(id) do
    if Process.whereis(HalC2.Terminal.Registry),
      do: HalC2.Terminal.running(id),
      else: []
  end

  # --- destination ---------------------------------------------------------------

  @doc """
  Whether this MC can take a thread (`request/2` on the source): its agent is
  here, a project is chosen and its folder exists, and there is room. Returns
  `{:ok, %{"project", "notes"}}`, a `"choose_project"` result, or an error.
  """
  def fit(%{"thread" => meta} = request) do
    here = ThreadArchive.label()
    title = meta["title"]

    with :ok <- has_agent(request["instanceId"], here, title),
         {:ok, project} <- pick_project(request, here, title),
         :ok <- folder(project, here, title),
         :ok <- room(request["size"], here, title) do
      same = ThreadArchive.same_repository([project], %{"thread" => meta}) != []

      notes =
        if request["checkpoints"] and not same,
          do: [ThreadArchive.checkpoints_note(meta, project, :different)],
          else: []

      {:ok, %{"project" => project["id"], "notes" => notes}}
    else
      {:choose, result} -> result
      error -> error
    end
  end

  @doc """
  The commits at the branches of the checkout a thread would move into here. A move
  carries the thread's commits without what these reach, which this MC has.
  """
  def have(%{"thread" => meta} = request) do
    refs =
      ~w[for-each-ref --sort=-committerdate --count=1000 --format=%(objectname)] ++
        ~w[refs/heads refs/remotes]

    with {:ok, project} <- pick_project(request, ThreadArchive.label(), meta["title"]),
         [_] <- ThreadArchive.same_repository([project], %{"thread" => meta}),
         {:ok, out} <- HalC2.Git.ok(project["workspaceRoot"], refs) do
      out |> String.split("\n", trim: true) |> Enum.uniq()
    else
      _ -> []
    end
  end

  @doc "This MC's projects, and which are checkouts of the thread's repository."
  def projects(meta) do
    same = MapSet.new(ThreadArchive.same_repository(%{"thread" => meta}), & &1["id"])

    {:ok,
     for project <- ThreadArchive.local_projects(),
         File.dir?(project["workspaceRoot"] || "") do
       %{
         "id" => project["id"],
         "title" => project["title"],
         "workspaceRoot" => project["workspaceRoot"],
         "sameRepository" => MapSet.member?(same, project["id"])
       }
     end}
  end

  @doc """
  Receives a thread (its archive's JSON) from the member `from` in the move
  `opts[:move]`: stages the files it carries under this MC's data, asks `from` whether
  the move still stands (`taking/2`), then imports it into `opts[:project]`. `from` may
  have stopped waiting by then, so its answer is what decides.
  """
  def accept(data, from, opts) do
    {:ok, %{"thread" => %{"id" => id, "title" => title}} = archive} = JSON.decode(data)
    # A move's own directory: an earlier move of the thread may still be staging.
    staged = Path.join(incoming(), opts[:move])
    File.mkdir_p!(staged)

    try do
      archive = ThreadArchive.map_files(archive, &pull(&1, from, staged))
      hook(:staged, id)

      # Held from asking until the thread is here or not, so `arrived?/1` never
      # answers in between.
      :global.trans(taking_lock(id), fn -> take(archive, from, opts, id, title) end, [node()])
    after
      File.rm_rf(staged)
    end
  end

  defp take(archive, from, opts, id, title) do
    case remote(from, :taking, [id, opts[:move]]) do
      :ok ->
        hook(:taking, id)
        ThreadArchive.import_archive(archive, project: opts[:project])

      _ ->
        {:error, "The move of #{title} was called off. #{title} was not moved."}
    end
  end

  defp taking_lock(id), do: {{__MODULE__, id}, self()}

  # Copies a carried file from where it is on `from` into `dir`.
  defp pull(%{"path" => path, "size" => size} = file, from, dir) do
    staged = Path.join(dir, Integer.to_string(System.unique_integer([:positive])))

    File.open!(staged, [:write, :raw, :binary], fn out ->
      for offset <- Range.new(0, size - 1, @chunk) do
        length = min(@chunk, size - offset)
        {:ok, bytes} = :erpc.call(from, __MODULE__, :read, [path, offset, length], 60_000)
        :ok = :file.write(out, bytes)
      end
    end)

    file |> Map.delete("temporary") |> Map.put("path", staged)
  end

  defp pull(file, _from, _dir), do: file

  @doc "A chunk of a file a thread leaving this MC carries; its destination asks for it."
  def read(path, offset, bytes),
    do: File.open!(path, [:read, :raw, :binary], &:file.pread(&1, offset, bytes))

  @doc "Whether this MC holds the thread `id` (not a forwarding record); `:deleted` if deleted here."
  def holds?(id) do
    case ThreadArchive.local_thread(id) do
      nil -> false
      %{"movedTo" => %{}} -> false
      %{"deletedAt" => at} when at != nil -> :deleted
      _ -> true
    end
  end

  @doc """
  As `holds?/1`, for the MC a thread is moving from: `:arriving` while a move is
  bringing it here, which is neither yet.
  """
  def arrived?(id) do
    case :global.trans(taking_lock(id), fn -> holds?(id) end, [node()], 0) do
      :aborted -> :arriving
      held -> held
    end
  end

  @doc "Whether this MC can run the agent `instance`: `:ok`, `:missing` or `:signed_out`."
  def agent(instance) do
    entry = Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == instance))

    cond do
      entry == nil or entry["installed"] == false or entry["availability"] == "unavailable" ->
        :missing

      get_in(entry, ["auth", "status"]) == "unauthenticated" ->
        :signed_out

      true ->
        :ok
    end
  end

  defp has_agent(instance, here, title) do
    case agent(instance) do
      :missing ->
        error(
          :thread_not_movable,
          "#{here} does not have #{provider_name(instance)}. #{title} was not moved."
        )

      :signed_out ->
        error(
          :thread_not_movable,
          "#{provider_name(instance)} is not signed in on #{here}. Sign in there, then move #{title} again."
        )

      :ok ->
        :ok
    end
  end

  defp pick_project(%{"project" => name}, here, title) when is_binary(name) do
    projects = ThreadArchive.local_projects()

    case Enum.find(projects, &(&1["id"] == name)) || Enum.find(projects, &(&1["title"] == name)) do
      nil ->
        error(:invalid_request, "There is no project #{name} on #{here}. #{title} was not moved.")

      project ->
        {:ok, project}
    end
  end

  defp pick_project(%{"thread" => meta}, here, title) do
    projects = ThreadArchive.local_projects()

    case ThreadArchive.same_repository(projects, %{"thread" => meta}) do
      [project] ->
        {:ok, project}

      [] ->
        choose(
          "No project on #{here} is a checkout of the repository of #{title}. Pick a project on #{here} or add one there, then move #{title} again.",
          projects
        )

      several ->
        choose(
          "Several projects on #{here} are checkouts of the repository of #{title} (#{Enum.map_join(several, ", ", & &1["title"])}). Choose which one to move #{title} into.",
          several
        )
    end
  end

  # The user is to choose a project: that is the answer to the move.
  defp choose(message, projects),
    do:
      {:choose,
       {:ok,
        %{
          "status" => "choose_project",
          "message" => message,
          "projects" => for(p <- projects, do: Map.take(p, ~w(id title workspaceRoot)))
        }}}

  defp folder(project, here, title) do
    if File.dir?(project["workspaceRoot"] || ""),
      do: :ok,
      else:
        error(
          :thread_not_movable,
          "The project folder on #{here} no longer exists. #{title} was not moved."
        )
  end

  defp room(size, here, title) do
    reserve = Application.get_env(:hal_c2, :thread_move_reserve, @reserve)

    needed = 2 * (size || 0) + reserve

    case free_bytes(HalC2.Paths.data_dir()) do
      free when is_integer(free) and free < needed ->
        error(
          :thread_not_movable,
          "#{here} does not have enough free space for #{title}. #{title} was not moved."
        )

      _ ->
        :ok
    end
  end

  defp free_bytes(dir) do
    File.mkdir_p(dir)

    with {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_, line | _] <- String.split(out, "\n", trim: true),
         [_, _, _, avail | _] <- String.split(line),
         {kb, ""} <- Integer.parse(avail) do
      kb * 1024
    else
      _ -> nil
    end
  end

  defp incoming, do: Path.join(HalC2.Paths.data_dir(), "incoming-moves")

  # --- settling cut-off moves ------------------------------------------------------

  @impl true
  def init(_opts) do
    :ok = :net_kernel.monitor_nodes(true)

    # Once an MC: a restart of this process alone must not take the files from under
    # the moves still staging or sending.
    unless :persistent_term.get({__MODULE__, :booted, incoming()}, false) do
      File.rm_rf(incoming())
      ThreadArchive.clear_scratch()
      :persistent_term.put({__MODULE__, :booted, incoming()}, true)
    end

    send(self(), {:settle, :all})
    {:ok, %{after_turn: %{}, again: MapSet.new(), movers: %{}}}
  end

  @impl true
  def handle_call({:after_turn, id, to, opts}, _from, state) do
    :ok = Streams.watch(id, self())
    send(self(), {:turn_check, id})
    {:reply, :ok, put_in(state, [:after_turn, id], {to, opts})}
  end

  @impl true
  def handle_cast({:watch, pid, id, move}, state),
    do: {:noreply, put_in(state, [:movers, Process.monitor(pid)], {id, move})}

  # The transfer of the move ended, however it did: it settles if it was cut off.
  def handle_cast({:done, id, move}, state) do
    movers =
      Map.reject(state.movers, fn {ref, {_id, watched}} ->
        watched == move and Process.demonitor(ref, [:flush])
      end)

    settle_cut_off(id, move, %{state | movers: movers})
  end

  @impl true
  def handle_info({:settle, which}, state) do
    # One timer a thread, however many times it is found unsettled meanwhile.
    waiting = MapSet.delete(state.again, which)
    again = MapSet.new(settle(which))

    for id <- MapSet.difference(again, waiting),
        do: Process.send_after(self(), {:settle, id}, @again)

    {:noreply, %{state | again: MapSet.union(waiting, again)}}
  end

  def handle_info({:nodeup, mc}, state), do: handle_info({:settle, mc}, state)

  # The process moving a thread died.
  def handle_info({:DOWN, ref, :process, _, _}, %{movers: movers} = state)
      when is_map_key(movers, ref) do
    {{id, move}, movers} = Map.pop(movers, ref)
    settle_cut_off(id, move, %{state | movers: movers})
  end

  # A thread waiting for its turn to end: every commit may be the one that ends it.
  def handle_info({:hal_c2_stream, id, _}, state), do: handle_info({:turn_check, id}, state)

  def handle_info({:turn_check, id}, %{after_turn: waiting} = state)
      when is_map_key(waiting, id) do
    if Enum.any?(StreamState.list(state(id), "run"), &(&1["status"] in @active)) do
      {:noreply, state}
    else
      {{to, opts}, waiting} = Map.pop(waiting, id)
      Streams.unsubscribe(id, self())

      Task.start(fn ->
        with {:error, %{"message" => message}} <-
               move(id, to, Keyword.put(opts, :confirmed, true)),
             do: Logger.warning("thread #{id} did not move to #{to} after its turn: #{message}")
      end)

      {:noreply, %{state | after_turn: waiting}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A move whose transfer ended or whose mover died settles, unless it was over.
  defp settle_cut_off(id, move, state) do
    case thread(id) do
      %{"moving" => %{"id" => ^move}} -> handle_info({:settle, id}, state)
      _ -> {:noreply, state}
    end
  end

  @doc """
  Settles moves that were cut off: to `mc`, of the thread `id`, or all (`:all`). A
  thread marked `moving` becomes a forwarding record if its destination holds it, and
  is released if the destination is reachable and does not. Returns the threads to
  settle again: those a destination is still taking, or did not answer for.
  """
  def settle(which \\ :all) do
    for {"thread", %{"id" => id, "moving" => %{"mc" => name}}} <- local_rows(),
        mc = String.to_atom(name),
        which in [:all, mc, id],
        # As the move is now: the destination may be told to take it while it is asked.
        moving = thread(id)["moving"],
        again?(id, mc, moving),
        do: id
  end

  defp again?(id, mc, moving) do
    case remote(mc, :arrived?, [id]) do
      true ->
        dest = %{mc: mc, label: moving["label"], environment: moving["environmentId"]}
        let_go(id, dest, %{project: nil})
        false

      :arriving ->
        true

      # A destination that is offline settles when it comes back.
      {:error, _} ->
        mc in Node.list()

      _ ->
        not release(id, moving)
    end
  end

  defp local_rows,
    do: for({_id, kind, row} <- HalC2.Store.list_shell(HalC2.Store.path()), do: {kind, row})

  # --- helpers ---------------------------------------------------------------------

  defp thread(id), do: StreamState.get(state(id), "thread")[id]
  defp state(id), do: Streams.Server.state(Streams.ensure(id))

  defp ask(dest, fun, args, thread) do
    case remote(dest.mc, fun, args) do
      {:error, %{}} = error ->
        error

      {:error, _} ->
        error(:mc_unavailable, "#{dest.label} is offline. #{thread["title"]} was not moved.")

      other ->
        other
    end
  end

  defp remote(mc, fun, args) do
    :erpc.call(mc, __MODULE__, fun, args, 30_000)
  catch
    _, reason -> {:error, reason}
  end

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_, default), do: default

  @doc "A provider instance's name, as the user knows it."
  def provider_name(instance) do
    @names[instance] ||
      if(HalC2.Acp.agent?(instance), do: HalC2.Acp.label(instance)) ||
      Enum.find_value(HalC2.Environment.providers(), instance, fn entry ->
        if entry["instanceId"] == instance, do: entry["displayName"] || @names[entry["driver"]]
      end)
  end

  defp error(code, message),
    do: {:error, %{"code" => Atom.to_string(code), "message" => message}}

  # Tests pause or break a move at a stage: `{module, function, args}`, called with the
  # stage and the thread id.
  defp hook(stage, id) do
    case Application.get_env(:hal_c2, :thread_move_hook) do
      {m, f, a} -> apply(m, f, a ++ [stage, id])
      nil -> :ok
    end
  end
end
