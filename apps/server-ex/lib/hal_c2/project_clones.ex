defmodule HalC2.ProjectClones do
  @moduledoc """
  Clones that back freshly added projects (`projectClone.*`). Starting one adds
  the project right away, then clones into its empty folder while clients follow
  git's own progress (`ProjectCloneSnapshot`). Progress is kept in memory only: a
  finished clone is dropped after a short while, a failed one stays until it is
  retried, and a restart forgets them (the project keeps its folder).

  Stopping a clone (cancel, or deleting its project) kills git and waits for it to
  exit before anything is removed, so a clone git finished in the meantime is kept
  as done. What is removed is only what that clone wrote: its `.git` and the files
  of the commit it checked out (`remove_checkout/1`), never the user's own files.

  Watchers (client sockets) get `{:hal_c2_project_clones, mc, snapshots}` on changes.
  """

  use GenServer

  @forget_done_after 30_000
  # The contract's PROJECT_CLONE_DETAIL_MAX_LENGTH and PROJECT_CLONE_ERROR_MAX_LENGTH.
  @detail_max 200
  @error_max 1000
  # git's last words that make a failure's message.
  @error_lines 10
  # git never prompts: without a terminal a prompt would wait forever. An empty
  # GIT_ASKPASS also keeps git off SSH_ASKPASS and core.askPass.
  @git_env [
    {"GIT_TERMINAL_PROMPT", "0"},
    # An askpass that fails: an empty one would let git fall back to a configured
    # `core.askPass` or `SSH_ASKPASS`, which could open a prompt nobody answers.
    {"GIT_ASKPASS", "false"},
    {"SSH_ASKPASS_REQUIRE", "never"},
    {"GCM_INTERACTIVE", "never"},
    {"GIT_PROGRESS_DELAY", "0"},
    {"LC_ALL", "C"}
  ]
  # How long a killed git may take to report before its worker is killed too.
  @stop_timeout 15_000
  # How long a cancel, delete or retry waits for its clone to settle: the stop,
  # then the removal of its files.
  @settle_timeout @stop_timeout + 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`projectClone.start`: adds the project, then clones into it in the background."
  def start(input) do
    with {:ok, dest} <- destination(input["destinationPath"]),
         {:ok, url, repository} <- HalC2.SourceControl.remote(input) do
      clone = %{
        project_id: input["projectId"],
        url: address(url, dest),
        dest: dest,
        repository: repository
      }

      GenServer.call(__MODULE__, {:start, clone, input["title"]}, 30_000)
    end
  end

  @doc """
  Why a thread cannot start in project `id` yet, or `:ok`: its clone is still
  running, or failed or was cancelled and has to be retried first. Read from a
  table the server keeps, so it never waits on a clone being stopped.
  """
  def thread_block(id) do
    case phase(id) do
      "running" ->
        {:error, "The repository is still being cloned."}

      phase when phase in ["failed", "cancelled"] ->
        {:error, "The repository was not cloned. Retry the clone first."}

      _ ->
        :ok
    end
  end

  defp phase(id) do
    case :ets.whereis(__MODULE__) != :undefined and :ets.lookup(__MODULE__, id) do
      [{^id, phase}] -> phase
      _ -> nil
    end
  rescue
    # The server stopped between the two looks.
    ArgumentError -> nil
  end

  @doc "Stops the clone of project `id` and removes its partial checkout; a finished one keeps its files."
  def discard(id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:discard, id}, @settle_timeout),
      else: :ok
  end

  @doc "A clone address without the credentials pasted into it."
  def redact(url) when is_binary(url),
    do: Regex.replace(~r{^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]*@}, url, "\\1")

  def redact(url), do: url

  # Credentials anywhere in a message, such as git's "fatal: ... 'https://u:p@host/x'".
  defp redact_all(text), do: Regex.replace(~r{(://)[^/@\s'"]*@}, text, "\\1")

  @doc false
  # `text` cut to `max` characters, ending in an ellipsis when it was cut.
  def clamp(nil, _max), do: nil
  def clamp(text, max) when byte_size(text) <= max, do: text

  def clamp(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  defp destination(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, "Choose a destination path before cloning."}
      path -> {:ok, path |> HalC2.Projects.expand_home() |> Path.expand()}
    end
  end

  defp destination(_), do: {:error, "Choose a destination path before cloning."}

  @doc false
  # What git is given to clone: a relative local path made absolute against the
  # folder git runs in. git records a local path as `cwd + "/" + path`, dots and
  # slashes as typed; given an absolute one it records exactly that, so the origin
  # of a `.git` can be checked against it. URLs and `host:path` pass as pasted.
  def address(url, dest) do
    if local?(url) and Path.type(url) == :relative,
      do: Path.expand(url, Path.dirname(dest)),
      else: url
  end

  # Not a URL nor `[user@]host:path`, as git tells them apart.
  defp local?(url) do
    case :binary.match(url, ":") do
      :nomatch ->
        true

      {colon, _} ->
        case :binary.match(url, "/") do
          {slash, _} -> slash < colon and not String.contains?(url, "://")
          :nomatch -> false
        end
    end
  end

  defp empty_folder(dir, message) do
    case File.ls(dir) do
      {:ok, [_ | _]} -> {:error, message}
      _ -> :ok
    end
  end

  def retry(%{"projectId" => id}), do: GenServer.call(__MODULE__, {:retry, id}, @settle_timeout)

  def cancel(%{"projectId" => id}),
    do: GenServer.call(__MODULE__, {:cancel, id}, @settle_timeout)

  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})
  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

  # --- server ------------------------------------------------------------------

  # `clones` are the snapshots clients see; `runs` what this MC needs to run, stop
  # and clean up each one: the address git was given, the folder, its worker and
  # git while it runs, the removal of its files while that runs, and the cancels,
  # deletes and retries (`waiters`) answered once those are over.
  #
  # Nothing slow happens in the server: git is stopped by its worker and files are
  # removed by a process of their own, both reporting back, so clients and
  # `thread_block/1` (which reads the phases table) never wait behind a stop.
  @impl true
  def init(nil) do
    # A clone's worker is linked; its exit must not take this down.
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, %{clones: %{}, runs: %{}, watchers: %{}, sequence: 0}}
  end

  # A clone does not outlive the MC: its git is killed and its files left, as of a
  # clone the MC forgot.
  @impl true
  def terminate(_reason, state) do
    for {_id, %{worker: pid, git: git}} <- state.runs, is_pid(pid) and git != nil, do: kill(git)
    :ok
  end

  @impl true
  def handle_call({:start, clone, title}, _from, state) do
    # Checked and claimed in one step, so two gits never race into one folder.
    with :ok <- unclaimed(state, clone),
         :ok <- empty_folder(clone.dest, "Destination path already exists and is not empty."),
         {:ok, _} <-
           HalC2.Projects.mutate(%{
             "type" => "project.create",
             "projectId" => clone.project_id,
             "title" => title,
             "workspaceRoot" => clone.dest,
             "createWorkspaceRootIfMissing" => true
           }) do
      reply = %{
        "projectId" => clone.project_id,
        "cwd" => clone.dest,
        "remoteUrl" => redact(clone.url),
        "repository" => clone.repository
      }

      {:reply, {:ok, reply}, state |> run(clone) |> changed()}
    else
      error -> {:reply, error, state}
    end
  end

  # A finished checkout (also one git finished meanwhile) is the user's; what a
  # stopped or failed git left behind goes, then the clone.
  def handle_call({:discard, id}, from, state) do
    cond do
      state.clones[id] == nil -> {:reply, :ok, state}
      busy?(state, id) -> {:noreply, wait(state, id, {:discard, from})}
      state.clones[id]["phase"] == "done" -> {:reply, :ok, state |> forget(id) |> changed()}
      true -> {:noreply, state |> wait(id, {:discard, from}) |> remove(id)}
    end
  end

  # What a failed git left goes first; any other file is not the clone's and is
  # never deleted, so it stops the retry.
  def handle_call({:retry, id}, from, state) do
    case state.clones[id] do
      %{"phase" => phase} when phase in ["failed", "cancelled"] ->
        state = wait(state, id, {:retry, from})
        if busy?(state, id), do: {:noreply, state}, else: {:noreply, remove(state, id)}

      _ ->
        {:reply, {:ok, %{"applied" => false}}, state}
    end
  end

  def handle_call({:cancel, id}, from, state) do
    if running?(state, id),
      do: {:noreply, wait(state, id, {:cancel, from})},
      else: {:reply, {:ok, %{"applied" => false}}, state}
  end

  def handle_call({:subscribe, pid, ref}, _from, state) do
    watchers = HalC2.Watchers.add(state.watchers, pid, ref)
    {:reply, {:ok, snapshots(state)}, %{state | watchers: watchers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid, ref}, state) do
    watchers = HalC2.Watchers.remove(state.watchers, pid, ref)
    {:noreply, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info({:clone_git, pid, id, git}, state) do
    if worker?(state, id, pid),
      do: {:noreply, put_in(state.runs[id].git, git)},
      else: {:noreply, state}
  end

  def handle_info({:clone_progress, id, fields}, state) do
    if running?(state, id) and state.runs[id].waiters == [],
      do: {:noreply, state |> update(id, fields) |> changed()},
      else: {:noreply, state}
  end

  def handle_info({:clone_finished, pid, id, result}, state) do
    if worker?(state, id, pid),
      do: {:noreply, state |> ended(id, result) |> changed()},
      else: {:noreply, state}
  end

  # A killed git that has not been reported yet: something it started still runs
  # (git is reported once all it started has exited) and may still write, so its
  # worker goes and nothing is removed.
  def handle_info({:stop_timeout, id, pid}, state) do
    if worker?(state, id, pid), do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:removed, id, pid, _result}, state) do
    if state.runs[id][:removing] == pid,
      do: {:noreply, state |> put_in([:runs, id, :removing], nil) |> settle(id) |> changed()},
      else: {:noreply, state}
  end

  def handle_info({:forget, id}, state) do
    case state.clones[id] do
      %{"phase" => "done"} ->
        if busy?(state, id),
          do: {:noreply, state},
          else: {:noreply, state |> forget(id) |> changed()}

      _ ->
        {:noreply, state}
    end
  end

  # A worker that died without reporting (its git crashed it, or a stop timed out),
  # or a removal that crashed.
  def handle_info({:EXIT, pid, reason}, state) do
    worker = Enum.find(state.runs, fn {id, _} -> worker?(state, id, pid) end)
    removal = Enum.find(state.runs, fn {_, run} -> run.removing == pid end)

    cond do
      worker ->
        {id, run} = worker

        result =
          if run.waiters != [],
            do: :stuck,
            else: {:error, "git clone stopped: #{inspect(reason)}"}

        {:noreply, state |> ended(id, result) |> changed()}

      removal && reason != :normal ->
        {id, _} = removal
        {:noreply, state |> put_in([:runs, id, :removing], nil) |> settle(id) |> changed()}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  # --- clones ------------------------------------------------------------------

  defp unclaimed(state, clone) do
    claimed =
      Enum.any?(state.clones, fn {id, snapshot} ->
        snapshot["phase"] != "done" and
          (id == clone.project_id or snapshot["destinationPath"] == clone.dest)
      end)

    if claimed,
      do: {:error, "A clone into this destination is already in progress."},
      else: :ok
  end

  defp running?(state, id), do: is_pid(state.runs[id][:worker])
  defp worker?(state, id, pid), do: running?(state, id) and state.runs[id].worker == pid
  # git still runs or the clone's files are being removed.
  defp busy?(state, id), do: running?(state, id) or is_pid(state.runs[id][:removing])

  defp run(state, clone) do
    server = self()
    id = clone.project_id
    pid = spawn_link(fn -> worker(server, id, clone.url, clone.dest) end)

    snapshot = %{
      "projectId" => id,
      "remoteUrl" => redact(clone.url),
      "destinationPath" => clone.dest,
      "repository" => clone.repository,
      "phase" => "running",
      "stage" => "connecting",
      "percent" => nil,
      "detail" => nil,
      "error" => nil,
      "startedAt" => now(),
      "endedAt" => nil,
      "sequence" => 0
    }

    run = %{
      url: clone.url,
      dest: clone.dest,
      real: canonical(clone.dest),
      worker: pid,
      git: nil,
      removing: nil,
      waiters: []
    }

    %{state | clones: Map.put(state.clones, id, snapshot), runs: Map.put(state.runs, id, run)}
  end

  # `waiter` is answered once the clone settles. The first one to find git running
  # has its worker kill it (also a git not started yet), with a deadline for the
  # report.
  defp wait(state, id, waiter) do
    run = state.runs[id]

    if running?(state, id) and run.waiters == [] do
      send(run.worker, :clone_stop)
      Process.send_after(self(), {:stop_timeout, id, run.worker}, @stop_timeout)
    end

    put_in(state.runs[id].waiters, run.waiters ++ [waiter])
  end

  # git has been reported. Nobody waiting: how it ended is the clone's outcome. A
  # stop that git finished before is kept as done; one it was killed by has its
  # files removed, unless it never reported and something may still write.
  defp ended(state, id, result) do
    state = put_in(state.runs[id].worker, nil)

    case {state.runs[id].waiters, result} do
      {[], result} -> finished(state, id, result)
      {_, :ok} -> state |> finished(id, :ok) |> settle(id)
      {_, :stuck} -> settle(state, id)
      {_, {:error, _}} -> remove(state, id)
    end
  end

  # Removes what the clone wrote in a process of its own, reported as `:removed`.
  defp remove(state, id) do
    server = self()
    run = state.runs[id]
    pid = spawn_link(fn -> send(server, {:removed, id, self(), remove_checkout(run)}) end)
    put_in(state.runs[id].removing, pid)
  end

  # Answers those waiting on clone `id`, in the order they came. A clone whose
  # project is being deleted is not retried.
  defp settle(state, id) do
    waiters = state.runs[id].waiters
    state = put_in(state.runs[id].waiters, [])
    deleting = Enum.any?(waiters, &match?({:discard, _}, &1))

    Enum.reduce(waiters, state, fn
      {:retry, from}, state when deleting ->
        GenServer.reply(from, {:ok, %{"applied" => false}})
        state

      waiter, state ->
        answer(state, id, waiter)
    end)
  end

  defp answer(state, id, {:cancel, from}) do
    case state.clones[id] do
      %{"phase" => "running"} ->
        GenServer.reply(from, {:ok, %{"applied" => true}})
        update(state, id, %{"phase" => "cancelled", "endedAt" => now()})

      _ ->
        GenServer.reply(from, {:ok, %{"applied" => false}})
        state
    end
  end

  defp answer(state, id, {:discard, from}) do
    GenServer.reply(from, :ok)
    forget(state, id)
  end

  defp answer(state, id, {:retry, from}) do
    case state.clones[id] do
      %{"phase" => phase} = snapshot when phase in ["failed", "cancelled"] ->
        dest = snapshot["destinationPath"]

        case empty_folder(dest, "Destination path contains files that are not from the clone.") do
          :ok ->
            GenServer.reply(from, {:ok, %{"applied" => true}})

            clone = %{
              project_id: id,
              url: state.runs[id].url,
              dest: dest,
              repository: snapshot["repository"]
            }

            run(state, clone)

          error ->
            GenServer.reply(from, error)
            state
        end

      _ ->
        GenServer.reply(from, {:ok, %{"applied" => false}})
        state
    end
  end

  defp forget(state, id),
    do: %{state | clones: Map.delete(state.clones, id), runs: Map.delete(state.runs, id)}

  # A git that already exited has nothing left to kill.
  defp kill(git) do
    Exile.Process.kill(git, :sigkill)
  catch
    :exit, _ -> :ok
  end

  defp finished(state, id, result) do
    state = %{state | runs: put_in(state.runs, [id, :worker], nil)}

    fields =
      case result do
        :ok ->
          Process.send_after(self(), {:forget, id}, @forget_done_after)
          %{"phase" => "done", "stage" => "checkout", "percent" => 100, "endedAt" => now()}

        {:error, message} ->
          error = message |> redact_all() |> clamp(@error_max)
          %{"phase" => "failed", "error" => error, "endedAt" => now()}
      end

    update(state, id, fields)
  end

  # `git clone --progress`, reporting each stage it prints on stderr, then how it ended.
  # How it ended is git's exit, not the end of its output: a helper git started (ssh,
  # a credential helper, a transport) can hold stderr open after git is gone.
  defp worker(server, id, url, dest) do
    command = ["git", "clone", "--progress", "--", url, dest]

    result =
      case Exile.Process.start_link(command,
             cd: Path.dirname(dest),
             env: @git_env,
             stderr: :consume
           ) do
        {:ok, git} ->
          send(server, {:clone_git, self(), id, git})
          Exile.Process.close_stdin(git)
          follow(server, id, git, reader(git), [], nil)

        {:error, reason} ->
          {:error, "git could not be started: #{inspect(reason)}"}
      end

    send(server, {:clone_finished, self(), id, result})
  end

  # A process that owns git's output and passes it on, so the worker can wait on
  # the output and on git's exit at once.
  defp reader(git) do
    worker = self()

    reader =
      spawn_link(fn ->
        receive do: (:read -> read_output(worker, git))
      end)

    for pipe <- [:stdout, :stderr], do: Exile.Process.change_pipe_owner(git, pipe, reader)
    send(reader, :read)
    reader
  end

  defp read_output(worker, git) do
    case Exile.Process.read_any(git) do
      {:ok, {pipe, data}} ->
        send(worker, {:clone_output, self(), pipe, data})
        read_output(worker, git)

      _eof ->
        send(worker, {:clone_eof, self()})
    end
  catch
    # git's Exile process stopped under it.
    :exit, _ -> send(worker, {:clone_eof, self()})
  end

  # Once git has exited, what it wrote last is already in the pipe; anything later
  # is from a helper it left behind, which is not waited for.
  @after_exit 500

  defp follow(server, id, git, reader, said, status) do
    exit_ref = git.exit_ref

    receive do
      {:clone_output, ^reader, :stderr, data} ->
        follow(server, id, git, reader, said(server, id, data, said), status)

      {:clone_output, ^reader, :stdout, _data} ->
        follow(server, id, git, reader, said, status)

      {:clone_eof, ^reader} ->
        outcome(status || receive(do: ({^exit_ref, status} -> status)), said)

      {^exit_ref, status} ->
        follow(server, id, git, reader, said, status)

      # SIGKILL: git's own cleanup on SIGTERM would empty a folder that had files.
      :clone_stop ->
        kill(git)
        follow(server, id, git, reader, said, status)
    after
      if(status, do: @after_exit, else: :infinity) -> outcome(status, said)
    end
  end

  defp outcome({:ok, 0}, _said), do: :ok

  defp outcome(_status, said),
    do: {:error, said |> Enum.reverse() |> Enum.join("\n") |> String.trim() |> fallback()}

  # git's progress lines go to the server; the rest are kept as its last words.
  defp said(server, id, data, said) do
    data
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.reduce(said, fn line, said ->
      case progress(line) do
        nil ->
          if String.starts_with?(line, "Cloning into"),
            do: said,
            else: Enum.take([line | said], @error_lines)

        fields ->
          send(server, {:clone_progress, id, fields})
          said
      end
    end)
  end

  defp fallback(""), do: "git clone failed."
  defp fallback(message), do: message

  @doc false
  # The clone's own files in `run.dest`, removed after its git is gone: the `.git`
  # it made and the files of the commit it was checking out. Any other file is the
  # user's and stays, so the folder ends empty only when the user added nothing.
  # Nothing is removed unless the folder is still the one the clone was started in
  # (same canonical path, not `/`, the home folder or above it, holding no other
  # project) and its `.git` names the clone's address as its origin.
  # sobelow_skip ["Traversal.FileModule"]
  def remove_checkout(run) do
    with %{dest: dest, real: real, url: url} <- run,
         true <- removable?(dest, real),
         git_dir = Path.join(real, ".git"),
         true <- clone_git_dir?(git_dir, url) do
      paths = checkout_paths(git_dir)

      for path <- paths,
          file = Path.join(real, path),
          inside_real_dirs?(real, path),
          match?({:ok, %{type: type}} when type in [:regular, :symlink], File.lstat(file)),
          do: File.rm(file)

      # Then the folders they were in, deepest first, when nothing else is in them.
      paths
      |> Enum.flat_map(&parents/1)
      |> Enum.uniq()
      |> Enum.sort_by(&(-length(Path.split(&1))))
      |> Enum.each(&File.rmdir(Path.join(real, &1)))

      File.rm_rf(git_dir)
      :ok
    else
      _ -> :refused
    end
  end

  defp removable?(dest, real) do
    # `$HOME` as the MC sees it now and as it started.
    homes = for home <- [System.get_env("HOME"), System.user_home()], is_binary(home), do: home

    Path.type(dest) == :absolute and Path.expand(dest) == dest and real != nil and
      canonical(dest) == real and real != "/" and
      not Enum.any?(homes, &within?(canonical(&1), real)) and
      not Enum.any?(
        HalC2.Projects.stored_roots() ++ HalC2.Projects.roots(),
        &(&1 != dest and within?(canonical(&1), real))
      )
  end

  # Whether `path` is `dir` or inside it.
  defp within?(path, dir) when is_binary(path),
    do: path == dir or String.starts_with?(path, dir <> "/")

  defp within?(_path, _dir), do: false

  # A real folder (not a link) whose config has the clone's address as its origin.
  defp clone_git_dir?(git_dir, url) do
    with {:ok, %{type: :directory}} <- File.lstat(git_dir),
         {out, 0} <-
           System.cmd(
             "git",
             ["config", "--file", Path.join(git_dir, "config"), "--get", "remote.origin.url"],
             env: @git_env,
             stderr_to_stdout: true
           ) do
      String.trim_trailing(out, "\n") == url
    else
      _ -> false
    end
  end

  # The paths of the commit git checks out, which exists once the fetch is done.
  # Before that git has written nothing outside `.git`.
  defp checkout_paths(git_dir) do
    case System.cmd(
           "git",
           ["--git-dir=" <> git_dir, "ls-tree", "-r", "-z", "--name-only", "HEAD"],
           env: @git_env,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&(Path.safe_relative(&1) == {:ok, &1} and ".git" not in Path.split(&1)))

      _ ->
        []
    end
  end

  defp parents(path) do
    case Path.dirname(path) do
      "." -> []
      dir -> [dir | parents(dir)]
    end
  end

  # Every folder on the way to `path` under `root` is a real folder, not a link
  # git or the user put there.
  defp inside_real_dirs?(root, path) do
    path
    |> parents()
    |> Enum.all?(&match?({:ok, %{type: :directory}}, File.lstat(Path.join(root, &1))))
  end

  @doc false
  # `path` with every link in it resolved; a missing tail is kept as written.
  def canonical(path), do: canonical(Path.split(Path.expand(path)), "/", 0)

  defp canonical(_parts, _at, 40), do: nil
  defp canonical([], at, _depth), do: at
  defp canonical(["/" | rest], _at, depth), do: canonical(rest, "/", depth)

  defp canonical([part | rest], at, depth) do
    next = Path.join(at, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        case :file.read_link_all(next) do
          {:ok, target} ->
            target = Path.expand(to_string(target), at)
            canonical(Path.split(target) ++ rest, "/", depth + 1)

          _ ->
            nil
        end

      {:ok, _} ->
        canonical(rest, next, depth)

      {:error, _} ->
        Path.join([next | rest])
    end
  end

  @stages [
    {~r/^(?:remote: )?(?:Enumerating|Counting|Compressing) objects:\s+(\d+)%\s*(.*)$/,
     "counting"},
    {~r/^Receiving objects:\s+(\d+)%\s*(.*)$/, "receiving"},
    {~r/^Resolving deltas:\s+(\d+)%\s*(.*)$/, "resolving"},
    {~r/^Updating files:\s+(\d+)%\s*(.*)$/, "checkout"}
  ]

  @doc false
  # A git progress line as snapshot fields, or nil.
  def progress(line) do
    Enum.find_value(@stages, fn {pattern, stage} ->
      case Regex.run(pattern, String.trim(line)) do
        [_, percent, rest] ->
          detail =
            rest |> String.replace(~r/^\(\d+\/\d+\),?\s*/, "") |> String.replace(", done.", "")

          %{
            "stage" => stage,
            "percent" => min(String.to_integer(percent), 100),
            "detail" => if(detail == "", do: nil, else: clamp(detail, @detail_max))
          }

        _ ->
          nil
      end
    end)
  end

  defp update(state, id, fields) do
    case state.clones[id] do
      nil ->
        state

      snapshot ->
        sequence = state.sequence + 1
        snapshot = snapshot |> Map.merge(fields) |> Map.put("sequence", sequence)
        %{state | clones: Map.put(state.clones, id, snapshot), sequence: sequence}
    end
  end

  # Every change is published here: to the watchers, and to the phases table.
  defp changed(state) do
    list = snapshots(state)
    phases = Map.new(state.clones, fn {id, snapshot} -> {id, snapshot["phase"]} end)
    :ets.insert(__MODULE__, Map.to_list(phases))

    for [id] <- :ets.match(__MODULE__, {:"$1", :_}),
        not Map.has_key?(phases, id),
        do: :ets.delete(__MODULE__, id)

    HalC2.Watchers.notify(state.watchers, {:hal_c2_project_clones, node(), list})
    state
  end

  defp snapshots(state), do: state.clones |> Map.values() |> Enum.sort_by(& &1["startedAt"])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
