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

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`projectClone.start`: adds the project, then clones into it in the background."
  def start(input) do
    with {:ok, dest} <- destination(input["destinationPath"]),
         {:ok, url, repository} <- HalC2.SourceControl.remote(input) do
      clone = %{project_id: input["projectId"], url: url, dest: dest, repository: repository}
      GenServer.call(__MODULE__, {:start, clone, input["title"]}, 30_000)
    end
  end

  @doc """
  Why a thread cannot start in project `id` yet, or `:ok`: its clone is still
  running, or failed or was cancelled and has to be retried first.
  """
  def thread_block(id) do
    case Process.whereis(__MODULE__) && GenServer.call(__MODULE__, {:phase, id}) do
      "running" ->
        {:error, "The repository is still being cloned."}

      phase when phase in ["failed", "cancelled"] ->
        {:error, "The repository was not cloned. Retry the clone first."}

      _ ->
        :ok
    end
  end

  @doc "Stops the clone of project `id` and removes its partial checkout; a finished one keeps its files."
  def discard(id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:discard, id}, @stop_timeout + 5_000),
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

  defp empty_folder(dir, message) do
    case File.ls(dir) do
      {:ok, [_ | _]} -> {:error, message}
      _ -> :ok
    end
  end

  def retry(%{"projectId" => id}), do: GenServer.call(__MODULE__, {:retry, id})

  def cancel(%{"projectId" => id}),
    do: GenServer.call(__MODULE__, {:cancel, id}, @stop_timeout + 5_000)

  def subscribe(pid, ref \\ nil), do: GenServer.call(__MODULE__, {:subscribe, pid, ref})
  def unsubscribe(pid, ref \\ nil), do: GenServer.cast(__MODULE__, {:unsubscribe, pid, ref})

  # --- server ------------------------------------------------------------------

  # `clones` are the snapshots clients see; `runs` what this MC needs to run, stop
  # and clean up each one: the address as pasted, the folder, and its worker and git
  # while it runs.
  @impl true
  def init(nil) do
    # A clone's worker is linked; its exit must not take this down.
    Process.flag(:trap_exit, true)
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

  def handle_call({:phase, id}, _from, state),
    do: {:reply, state.clones[id] && state.clones[id]["phase"], state}

  def handle_call({:discard, id}, _from, state) do
    case state.clones[id] do
      nil ->
        {:reply, :ok, state}

      snapshot ->
        # A finished checkout (also one git finished meanwhile) is the user's; what
        # a stopped or failed git left behind goes.
        {result, state} = stop(state, id)

        if result not in [:ok, :stuck] and snapshot["phase"] != "done",
          do: remove_checkout(state.runs[id])

        state = %{state | clones: Map.delete(state.clones, id), runs: Map.delete(state.runs, id)}
        {:reply, :ok, changed(state)}
    end
  end

  def handle_call({:retry, id}, _from, state) do
    case state.clones[id] do
      %{"phase" => phase} = snapshot when phase in ["failed", "cancelled"] ->
        clone = %{
          project_id: id,
          url: state.runs[id].url,
          dest: snapshot["destinationPath"],
          repository: snapshot["repository"]
        }

        # What a failed git left goes first; any other file is not the clone's and
        # is never deleted, so it stops the retry.
        remove_checkout(state.runs[id])

        case empty_folder(
               clone.dest,
               "Destination path contains files that are not from the clone."
             ) do
          :ok -> {:reply, {:ok, %{"applied" => true}}, state |> run(clone) |> changed()}
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, {:ok, %{"applied" => false}}, state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    case state.runs[id] do
      %{worker: pid} when is_pid(pid) ->
        case stop(state, id) do
          # git finished before the kill landed: the checkout is kept, as done.
          {:ok, state} ->
            {:reply, {:ok, %{"applied" => false}}, changed(state)}

          {result, state} ->
            if result != :stuck, do: remove_checkout(state.runs[id])
            state = update(state, id, %{"phase" => "cancelled", "endedAt" => now()})
            {:reply, {:ok, %{"applied" => true}}, changed(state)}
        end

      _ ->
        {:reply, {:ok, %{"applied" => false}}, state}
    end
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
  def handle_info({:clone_progress, id, fields}, state) do
    if running?(state, id),
      do: {:noreply, state |> update(id, fields) |> changed()},
      else: {:noreply, state}
  end

  def handle_info({:clone_finished, pid, id, result}, state) do
    if worker?(state, id, pid),
      do: {:noreply, state |> finished(id, result) |> changed()},
      else: {:noreply, state}
  end

  def handle_info({:forget, id}, state) do
    case state.clones[id] do
      %{"phase" => "done"} ->
        state = %{state | clones: Map.delete(state.clones, id), runs: Map.delete(state.runs, id)}
        {:noreply, changed(state)}

      _ ->
        {:noreply, state}
    end
  end

  # A worker that died without reporting (its git crashed it).
  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.runs, fn {id, _} -> worker?(state, id, pid) end) do
      {id, _} ->
        result = {:error, "git clone stopped: #{inspect(reason)}"}
        {:noreply, state |> finished(id, result) |> changed()}

      nil ->
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

  defp run(state, clone) do
    server = self()
    id = clone.project_id
    pid = spawn_link(fn -> worker(server, id, clone.url, clone.dest) end)

    git =
      receive do
        {:clone_git, ^pid, git} -> git
        # Handled again as a worker that died without reporting.
        {:EXIT, ^pid, _} = exit -> tap(nil, fn _ -> send(self(), exit) end)
      after
        5_000 -> nil
      end

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

    run = %{url: clone.url, dest: clone.dest, real: canonical(clone.dest), worker: pid, git: git}
    %{state | clones: Map.put(state.clones, id, snapshot), runs: Map.put(state.runs, id, run)}
  end

  # Kills git and waits for the worker's report, so git is gone before anything
  # is removed. The report is what git made of it: `:ok` when it had finished,
  # `:stuck` when it never came.
  defp stop(state, id) do
    case state.runs[id] do
      %{worker: pid, git: git} when is_pid(pid) ->
        if git, do: kill(git)

        result =
          receive do
            {:clone_finished, ^pid, ^id, result} ->
              result

            {:EXIT, ^pid, reason} ->
              {:error, inspect(reason)}
          after
            # Something git started still runs (git is reported once all it started
            # has exited) and may still write, so nothing is removed.
            @stop_timeout ->
              Process.exit(pid, :kill)
              receive do: ({:EXIT, ^pid, _} -> :stuck)
          end

        state = %{state | runs: put_in(state.runs, [id, :worker], nil)}
        if result == :ok, do: {:ok, finished(state, id, :ok)}, else: {result, state}

      _ ->
        {nil, state}
    end
  end

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
          send(server, {:clone_git, self(), git})
          Exile.Process.close_stdin(git)
          follow(server, id, git, reader(git), [], nil)

        {:error, reason} ->
          send(server, {:clone_git, self(), nil})
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

  defp changed(state) do
    list = snapshots(state)
    HalC2.Watchers.notify(state.watchers, {:hal_c2_project_clones, node(), list})
    state
  end

  defp snapshots(state), do: state.clones |> Map.values() |> Enum.sort_by(& &1["startedAt"])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
