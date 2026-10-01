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
  (`accept/2`). Only once the destination has it does the source let go; a move that
  breaks off clears `moving` and leaves the thread where it was.

  This process settles moves a restart or a lost connection cut off: at boot, and
  when a destination comes back, a thread still marked `moving` becomes a forwarding
  record if the destination holds it, and is released otherwise. At boot it also
  discards copies this MC was receiving when it stopped.

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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # --- source --------------------------------------------------------------------

  @doc """
  Moves the thread `ref` (id or title) to the machine `to` (a label or environment
  id). `opts`: `project:` the destination project (id or title), `confirmed:` true
  once the user accepted what does not come along.
  """
  def move(ref, to, opts \\ []) do
    with {:ok, id} <- thread_id(ref),
         thread = thread(id),
         {:ok, dest} <- destination(to, thread),
         :ok <- movable(state(id), thread),
         :ok <- online(dest, thread),
         :ok <- save_terminals(id),
         {:ok, archive} <- build(id),
         {:ok, %{"project" => _} = fit} <-
           ask(dest, :fit, [request(archive, opts[:project])], thread),
         notes = fit["notes"] ++ source_notes(id, thread, archive, dest),
         :ok <- confirmed(notes, opts[:confirmed] == true),
         {:ok, archive} <- begin(id, dest, archive) do
      transfer(id, dest, archive, fit, notes)
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
         {:ok, dest} <- destination(to, thread),
         :ok <- movable(state(id), thread, true),
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
         {:ok, archive} <- build(id, session: false) do
      online = Node.list()
      meta = meta(archive)

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

    case Enum.find(rows, fn {_mc, row} -> row["movedTo"] == nil end) do
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

  defp destination(to, thread) do
    case Enum.find(Shell.environments(), fn {mc, d} ->
           to in [d["label"], d["environmentId"], Atom.to_string(mc)]
         end) do
      nil ->
        error(:invalid_request, "There is no machine #{to} in the cluster.")

      {mc, _} when mc == node() ->
        error(:invalid_request, "#{thread["title"]} is already on #{to}.")

      {mc, descriptor} ->
        {:ok, %{mc: mc, label: descriptor["label"], environment: descriptor["environmentId"]}}
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

  defp build(id, opts \\ []) do
    case ThreadArchive.build(id, opts) do
      {:ok, archive} -> {:ok, archive}
      {:error, message} -> error(:thread_not_movable, message)
    end
  end

  defp meta(archive), do: archive["thread"]

  # What the destination needs to decide whether it can take the thread.
  defp request(archive, project) do
    %{
      "thread" => meta(archive),
      "instanceId" => meta(archive)["instanceId"],
      "size" => :erlang.external_size(archive),
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
  # archive is rebuilt when the thread changed since it was built.
  defp begin(id, dest, archive) do
    at = Orchestration.Entities.now()

    marked =
      Streams.transact(id, :thread, fn state ->
        thread = StreamState.get(state, "thread")[id]

        case movable(state, thread) do
          :ok ->
            moving = %{
              "label" => dest.label,
              "environmentId" => dest.environment,
              "mc" => Atom.to_string(dest.mc),
              "at" => at
            }

            {[Orchestration.upsert(state, "thread", id, &Map.put(&1, "moving", moving))],
             {:ok, state.updated_at == archive["updatedAt"]}}

          error ->
            {[], error}
        end
      end)

    with {:ok, unchanged?} <- marked do
      Streams.flush_shell(id)

      if unchanged?,
        do: {:ok, archive},
        else: with_release(id, fn -> build(id) end)
    end
  end

  defp transfer(id, dest, archive, fit, notes) do
    data = JSON.encode!(archive)
    hook(:sending, id)

    result =
      try do
        :erpc.call(dest.mc, __MODULE__, :accept, [data, [project: fit["project"]]], @timeout)
      catch
        kind, reason -> {:broken, {kind, reason}}
      end

    case result do
      {:ok, imported} ->
        hook(:accepted, id)
        let_go(id, dest, imported)
        carried = imported[:session] == true
        title = archive["thread"]["title"]

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
        release(id)
        error(:thread_not_movable, message)

      {:broken, reason} ->
        Logger.warning("move of #{id} to #{dest.mc} broke off: #{inspect(reason)}")
        release(id)

        error(
          :mc_unavailable,
          "The move of #{archive["thread"]["title"]} to #{dest.label} did not finish. #{archive["thread"]["title"]} is still on #{ThreadArchive.label()} and can be moved again."
        )
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

  defp release(id) do
    Streams.transact(id, :thread, fn state ->
      case StreamState.get(state, "thread")[id] do
        %{"moving" => _} ->
          {[Orchestration.upsert(state, "thread", id, &Map.delete(&1, "moving"))], :ok}

        _ ->
          {[], :ok}
      end
    end)

    Streams.flush_shell(id)
  end

  defp with_release(id, fun) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      error ->
        release(id)
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
  Receives a thread (its archive's JSON): stages it under this MC's data, then
  imports it into `opts[:project]`.
  """
  def accept(data, opts) do
    {:ok, %{"thread" => %{"id" => id}}} = JSON.decode(data)
    staged = Path.join(incoming(), Base.url_encode64(id, padding: false))
    File.mkdir_p!(incoming())
    File.write!(staged, data)

    try do
      hook(:staged, id)
      ThreadArchive.import_archive(data, project: opts[:project])
    after
      File.rm(staged)
    end
  end

  @doc "Whether this MC holds the thread `id` (not a forwarding record); `:deleted` if deleted here."
  def holds?(id) do
    case ThreadArchive.local_thread(id) do
      nil -> false
      %{"movedTo" => %{}} -> false
      %{"deletedAt" => at} when at != nil -> :deleted
      _ -> true
    end
  end

  defp has_agent(instance, here, title) do
    entry =
      Enum.find(HalC2.Environment.providers(), &(&1["instanceId"] == instance))

    cond do
      entry == nil or entry["installed"] == false or entry["availability"] == "unavailable" ->
        error(
          :thread_not_movable,
          "#{here} does not have #{provider_name(instance)}. #{title} was not moved."
        )

      get_in(entry, ["auth", "status"]) == "unauthenticated" ->
        error(
          :thread_not_movable,
          "#{provider_name(instance)} is not signed in on #{here}. Sign in there, then move #{title} again."
        )

      true ->
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
    File.rm_rf(incoming())
    send(self(), {:settle, :all})
    {:ok, %{after_turn: %{}}}
  end

  @impl true
  def handle_call({:after_turn, id, to, opts}, _from, state) do
    :ok = Streams.subscribe(id, self(), nil)
    send(self(), {:turn_check, id})
    {:reply, :ok, put_in(state, [:after_turn, id], {to, opts})}
  end

  @impl true
  def handle_info({:settle, which}, state) do
    settle(which)
    {:noreply, state}
  end

  def handle_info({:nodeup, mc}, state) do
    settle(mc)
    {:noreply, state}
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

  @doc """
  Settles moves that were cut off: to `mc`, or all (`:all`). A thread marked
  `moving` becomes a forwarding record if its destination holds it, and is released
  if the destination is reachable and does not.
  """
  def settle(which \\ :all) do
    for {"thread", %{"id" => id, "moving" => %{"mc" => name} = moving}} <- local_rows(),
        mc = String.to_atom(name),
        which in [:all, mc] do
      case remote(mc, :holds?, [id]) do
        true ->
          dest = %{mc: mc, label: moving["label"], environment: moving["environmentId"]}
          let_go(id, dest, %{project: nil})

        {:error, _} ->
          :ok

        _ ->
          release(id)
      end
    end

    :ok
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
