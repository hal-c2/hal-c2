defmodule HalC2.PullRequestSyncPropTest do
  @moduledoc """
  A state machine over two threads and the two pull requests they may link, against
  `HalC2.PullRequests.Sync` reading a fake `gh`: links, the host's answer changing
  (open, merged, closed a moment ago, closed days ago), threads settled and unsettled,
  `request/1`, the 15 minutes between reads passing, and the Sync process restarting.
  The model keeps what each pull request last showed and when it was last read, and
  checks what the sweep promises:

  - a sweep asks the host for exactly the due pull requests, once each however many
    threads link them: open on a thread that is not settled, or closed within a day
    on one that is not settled and not read for 15 minutes (never, after a restart);
  - merged pull requests, a settled thread's, and ones closed over a day ago are
    left alone, and a pull request nobody links is never asked about;
  - a newly linked pull request and `request/1` read at once, whatever the thread or
    the pull request shows, and a read starts the 15 minutes over;
  - settling a thread and unsettling it brings its links back to the sweep.

  A day passing is modelled by the host answering a pull request as closed days ago,
  since the sweep reads the age from the stored snapshot's `closedAt`.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  @threads ~w(t1 t2)
  @numbers [1, 2]
  @fake_gh Path.expand("../../test/support/fake_gh.py", __DIR__)
  @slow 15 * 60_000

  property "a sweep reads exactly the pull requests that are due",
    numtests: HalC2.Prop.numtests(40),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("pull-request-sync")

        {history, state, result} =
          try do
            fake_host(home)

            HalC2.Prop.start_services([
              {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
              HalC2.Settings,
              HalC2.Streams,
              HalC2.Shell,
              {HalC2.PullRequests.Sync, interval: nil}
            ])

            project(home)
            host(initial_state().host)
            run_commands(__MODULE__, cmds)
          after
            HalC2.Prop.stop_services()
            HalC2.Prop.restore_env()
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # linked: %{number => threads linking it}; shown: what each linked pull request showed
  # when last read (:open, :merged, :closed or :old_closed); read: %{number => :fresh |
  # :stale} for those read since the Sync process started, :stale once 15 minutes passed;
  # host: what the host answers now; settled: the threads settled.
  def initial_state,
    do: %{
      linked: %{},
      shown: %{},
      read: %{},
      host: Map.new(@numbers, &{&1, :open}),
      settled: MapSet.new()
    }

  def command(_state) do
    frequency([
      {4, {:call, __MODULE__, :link, [oneof(@threads), oneof(@numbers)]}},
      {6, {:call, __MODULE__, :sweep, []}},
      {4,
       {:call, __MODULE__, :host_says,
        [oneof(@numbers), oneof([:open, :open, :merged, :closed, :old_closed])]}},
      {2, {:call, __MODULE__, :request, [oneof(@numbers)]}},
      {3, {:call, __MODULE__, :minutes_pass, []}},
      {2, {:call, __MODULE__, :restart, []}},
      {2, {:call, __MODULE__, :settle, [oneof(@threads)]}},
      {3, {:call, __MODULE__, :unsettle, [oneof(@threads)]}}
    ])
  end

  def precondition(state, {:call, _, :link, [thread, n]}),
    do: thread not in Map.get(state.linked, n, [])

  def precondition(state, {:call, _, :settle, [thread]}), do: thread not in state.settled
  def precondition(state, {:call, _, :unsettle, [thread]}), do: thread in state.settled
  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :link, [thread, n]}) do
    state
    |> Map.update!(:linked, &Map.update(&1, n, [thread], fn threads -> [thread | threads] end))
    |> read(n)
  end

  def next_state(state, _result, {:call, _, :sweep, []}),
    do: Enum.reduce(due(state), state, &read(&2, &1))

  def next_state(state, _result, {:call, _, :host_says, [n, answer]}),
    do: %{state | host: Map.put(state.host, n, answer)}

  def next_state(state, _result, {:call, _, :request, [n]}),
    do: if(Map.has_key?(state.linked, n), do: read(state, n), else: state)

  def next_state(state, _result, {:call, _, :minutes_pass, []}),
    do: %{state | read: Map.new(state.read, fn {n, _} -> {n, :stale} end)}

  def next_state(state, _result, {:call, _, :restart, []}), do: %{state | read: %{}}

  def next_state(state, _result, {:call, _, :settle, [thread]}),
    do: %{state | settled: MapSet.put(state.settled, thread)}

  def next_state(state, _result, {:call, _, :unsettle, [thread]}),
    do: %{state | settled: MapSet.delete(state.settled, thread)}

  # What the host was asked about, in order of number.
  def postcondition(state, {:call, _, :sweep, []}, asked), do: asked == due(state)
  def postcondition(_state, {:call, _, :link, [_, n]}, asked), do: asked == [n]

  def postcondition(state, {:call, _, :request, [n]}, asked),
    do: asked == if(Map.has_key?(state.linked, n), do: [n], else: [])

  def postcondition(_state, _call, asked), do: asked == []

  defp read(state, n),
    do: %{
      state
      | shown: Map.put(state.shown, n, state.host[n]),
        read: Map.put(state.read, n, :fresh)
    }

  # The pull requests a sweep must ask the host about.
  defp due(state) do
    for {n, threads} <- Enum.sort(state.linked),
        live = Enum.reject(threads, &(&1 in state.settled)),
        live != [],
        state.shown[n] == :open or
          (state.shown[n] == :closed and state.read[n] in [nil, :stale]),
        do: n
  end

  # --- the real side --------------------------------------------------------------

  def link(thread, n) do
    asked(fn ->
      {:ok, _} =
        dispatch(thread, %{
          "type" => "thread.pull-request.link",
          "host" => "github.com",
          "repository" => "acme/app",
          "number" => n,
          "url" => "https://github.com/acme/app/pull/#{n}",
          "source" => "manual"
        })

      # The link is read at once; wait for that and for the snapshot to reach the rows.
      settle()
    end)
  end

  def sweep do
    settle()
    asked(fn -> :ok = HalC2.PullRequests.Sync.sweep() end)
  end

  def host_says(n, answer) do
    host(Map.put(host_now(), n, answer))
    []
  end

  def request(n) do
    settle()

    asked(fn ->
      HalC2.PullRequests.Sync.request(%{
        "host" => "github.com",
        "repository" => "acme/app",
        "number" => n
      })

      flush_sync()
    end)
  end

  # The time since the last read of every pull request passes 15 minutes.
  def minutes_pass do
    settle()
    now = System.system_time(:millisecond)

    asked(fn ->
      :sys.replace_state(HalC2.PullRequests.Sync, fn state ->
        %{
          state
          | last_synced: Map.new(state.last_synced, fn {key, _at} -> {key, now - @slow - 1} end)
        }
      end)
    end)
  end

  def restart do
    settle()
    asked(fn -> HalC2.Prop.restart_service(HalC2.PullRequests.Sync) end)
  end

  def settle(thread) do
    asked(fn ->
      {:ok, _} = dispatch(thread, %{"type" => "thread.settle"})
      settle()
    end)
  end

  def unsettle(thread) do
    asked(fn ->
      {:ok, _} = dispatch(thread, %{"type" => "thread.unsettle"})
      settle()
    end)
  end

  defp dispatch(thread, command) do
    ensure_thread(thread)

    HalC2.Orchestration.dispatch(
      Map.merge(
        %{"commandId" => "cmd-#{System.unique_integer([:positive])}", "threadId" => thread},
        command
      )
    )
  end

  defp ensure_thread(thread) do
    unless Process.get({__MODULE__, thread}) do
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "thread.create",
          "threadId" => thread,
          "projectId" => "demo",
          "title" => thread,
          "modelSelection" => %{"instanceId" => "codex", "model" => "gpt-5.4"},
          "runtimeMode" => "full-access",
          "interactionMode" => "default"
        })

      Process.put({__MODULE__, thread}, true)
    end
  end

  # Brings the sidebar rows up to date and lets Sync handle what that told it, and the
  # read of a newly linked pull request that follows (a message it sends itself).
  defp settle do
    for thread <- @threads,
        Process.get({__MODULE__, thread}),
        do: HalC2.Streams.flush_shell(thread)

    :sys.get_state(HalC2.Shell)
    flush_sync()

    for thread <- @threads,
        Process.get({__MODULE__, thread}),
        do: HalC2.Streams.flush_shell(thread)

    :sys.get_state(HalC2.Shell)
    flush_sync()
  end

  defp flush_sync do
    for _ <- 1..3, do: :sys.get_state(HalC2.PullRequests.Sync)
    :ok
  end

  # The numbers the fake host was asked about while `fun` ran, in order, one per read.
  defp asked(fun) do
    before = File.stat!(log()).size
    fun.()
    lines = binary_part(File.read!(log()), before, File.stat!(log()).size - before)

    lines
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.filter(&(Enum.join(&1["args"], " ") =~ "api graphql"))
    |> Enum.flat_map(fn call ->
      query = JSON.decode!(call["stdin"])["query"] || ""
      if query =~ "PullRequestSummaries", do: numbers(query), else: []
    end)
    |> Enum.sort()
  end

  defp numbers(query),
    do:
      for([_, n] <- Regex.scan(~r/pullRequest\(number: (\d+)\)/, query), do: String.to_integer(n))

  # --- the fake host --------------------------------------------------------------

  defp fake_host(home) do
    Process.put({__MODULE__, :home}, home)
    work = Path.join(home, "work")
    bin = Path.join(home, "bin")
    File.mkdir_p!(work)
    File.mkdir_p!(bin)
    File.ln_s!(@fake_gh, Path.join(bin, "gh"))
    File.write!(rules_path(), "[]")
    File.write!(log_path(), "")

    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    {_, 0} =
      System.cmd("git", ~w(remote add origin https://github.com/acme/app.git), cd: work)

    HalC2.Prop.put_system_env("PATH", bin <> ":" <> System.get_env("PATH"))
    HalC2.Prop.put_system_env("FAKE_GH_RULES", rules_path())
    HalC2.Prop.put_system_env("FAKE_GH_LOG", log_path())
    HalC2.Prop.put_env(:gh_command, "gh")
  end

  defp project(home) do
    {:ok, _} =
      HalC2.Projects.mutate(%{
        "type" => "project.create",
        "projectId" => "demo",
        "title" => "demo",
        "workspaceRoot" => Path.join(home, "work")
      })

    HalC2.Streams.flush_shell("demo")
    :sys.get_state(HalC2.Shell)
  end

  defp rules_path, do: Path.join(Process.get({__MODULE__, :home}), "rules.json")
  defp log_path, do: Path.join(Process.get({__MODULE__, :home}), "calls.jsonl")
  defp log, do: log_path()

  defp host_now, do: Process.get({__MODULE__, :host}) || initial_state().host

  # The host answers each pull request as `answers` says.
  defp host(answers) do
    Process.put({__MODULE__, :host}, answers)
    now = System.system_time(:millisecond)

    nodes =
      Map.new(answers, fn {n, answer} ->
        {"acme/app##{n}",
         %{
           "number" => n,
           "title" => "PR #{n}",
           "url" => "https://github.com/acme/app/pull/#{n}",
           "state" => state(answer),
           "isDraft" => false,
           "mergeable" => "MERGEABLE",
           "headRefName" => "feature/#{n}",
           "baseRefName" => "main",
           "updatedAt" => "2030-01-01T00:00:00Z",
           "mergedAt" => if(answer == :merged, do: iso(now - 3_600_000)),
           "closedAt" =>
             case answer do
               :closed -> iso(now - 3_600_000)
               :old_closed -> iso(now - 2 * 86_400_000)
               _ -> nil
             end,
           "author" => %{"login" => "octocat"},
           "commits" => %{"nodes" => []},
           "comments" => %{"nodes" => []},
           "reviews" => %{"nodes" => []}
         }}
      end)

    rules = [
      %{"args" => ["stacks?pull_request="], "stdout" => []},
      %{
        "args" => ["api graphql"],
        "stdin" => ["PullRequestSummaries"],
        "summaries" => nodes,
        "viewer" => "monalisa"
      }
    ]

    File.write!(rules_path(), JSON.encode!(rules))
  end

  defp state(:open), do: "OPEN"
  defp state(:merged), do: "MERGED"
  defp state(_closed), do: "CLOSED"

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
