defmodule HalC2.GitHubRoutePropTest do
  @moduledoc """
  `HalC2.Git.use_gh_for_github/0` against a model of the route git takes to GitHub:
  git as configured (an empty include), or HTTPS with the GitHub CLI's sign-in. The
  GitHub CLI signs in and out, an SSH agent comes and goes, and SSH to GitHub is
  answered, refused or cannot reach it, or hangs past the time it is given or stalls
  until a later call, between calls made at boot and at hot updates. A call never waits for SSH: until it answers, git keeps the route it had;
  a later call stops an earlier one still asking; and no ssh outlives the asking.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  # The time SSH is given: short where it hangs, so the time is what is tested, and
  # past the case where it stalls, so only a later call or the end of the case stops it.
  @hang_ms 300
  @stall_ms 600_000

  property "git keeps its route to GitHub until SSH answers, and the latest call decides",
    numtests: HalC2.Prop.numtests(40),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        restore = setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        leftover = teardown(restore)

        (result == :ok and leftover == [])
        |> when_fail(
          IO.puts("""
          #{HalC2.Prop.report(cmds, history, state, result)}
          ssh still running: #{inspect(leftover)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  # A gh and an ssh that answer as the case says (`set_gh/1`, `set_ssh/1`).
  defp setup do
    home = HalC2.Prop.scratch_home("github-route")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(home, "gh"))
    File.write!(Path.join(bin, "gh"), "#!/bin/sh\n")

    File.write!(Path.join(bin, "ssh"), """
    #!/bin/sh
    echo $$ >> '#{bin}/ssh.pids'
    case "$(cat '#{bin}/outcome')" in
      answers) echo "Hi acme! You've successfully authenticated, but GitHub does not provide shell access." >&2; exit 1 ;;
      refused) echo 'git@github.com: Permission denied (publickey).' >&2; exit 255 ;;
      unreachable) echo 'ssh: Could not resolve hostname github.com' >&2; exit 255 ;;
      hangs) exec sleep 600 ;;
    esac
    """)

    for program <- ~w(gh ssh), do: File.chmod!(Path.join(bin, program), 0o755)
    File.write!(Path.join(bin, "outcome"), "answers")
    Process.put(:bin, bin)
    Process.put(:home, home)

    names = ~w(PATH GH_CONFIG_DIR SSH_AUTH_SOCK) ++ git_config_names()
    restore = for name <- names, do: {name, System.get_env(name)}
    for name <- git_config_names(), do: System.delete_env(name)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("GH_CONFIG_DIR", Path.join(home, "gh"))
    # Signed in with an agent, where SSH is asked; commands sign out and drop it.
    set_gh(true)
    set_agent(true)
    Application.put_env(:hal_c2, :github_ssh_timeout, @hang_ms)
    restore
  end

  # Stops what a case left asking, puts the environment back, and returns the ssh
  # processes still running once Exile's watcher had time to stop them.
  defp teardown(restore) do
    if pid = Process.whereis(HalC2.Git.GitHubSsh),
      do: await(pid, fn -> Process.exit(pid, :kill) end)

    for name <- git_config_names(), do: System.delete_env(name)

    for {name, value} <- restore,
        do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

    Application.delete_env(:hal_c2, :github_ssh_timeout)

    pids =
      case File.read(Path.join(Process.get(:bin), "ssh.pids")) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        {:error, _} -> []
      end

    # The watcher signals the program after its owner dies and sends nothing when it
    # is gone, so this waits a bounded time for each, well past its signals and well
    # short of a stalled SSH's time.
    Enum.reject(pids, &stopped_within?(&1, 50))
  end

  defp git_config_names,
    do: for({"GIT_CONFIG_" <> _ = name, _} <- System.get_env(), do: name)

  # --- model ------------------------------------------------------------------

  # routes: what the include may hold, :missing, :git (empty) or :https. asking: the
  # process of the last call while it may still ask, and settles: the routes it
  # leaves. An asking no command waited for may have ended already, so a route is the
  # set of those it may be.
  def initial_state,
    do: %{
      gh: true,
      agent: true,
      ssh: :answers,
      routes: [:missing],
      asking: nil,
      asks: nil,
      settles: []
    }

  def command(state) do
    frequency(
      [
        {1, {:call, __MODULE__, :set_gh, [boolean()]}},
        {1, {:call, __MODULE__, :set_agent, [boolean()]}},
        {5, {:call, __MODULE__, :set_up, []}}
      ] ++
        if(state.asking,
          do: [{4, {:call, __MODULE__, :settle, [state.asking]}}],
          else: [
            {3,
             {:call, __MODULE__, :set_ssh,
              [oneof([:answers, :refused, :unreachable, :hangs, :stalls])]}}
          ]
        )
    )
  end

  # ssh reads its answer when it starts, so it changes only while no call asks.
  def precondition(state, {:call, _, :set_ssh, _}), do: state.asking == nil
  # A stalled SSH ends only with a later call or the case.
  def precondition(state, {:call, _, :settle, [asking]}),
    do: state.asking == asking and state.asks != :stalls

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :set_gh, [gh]}), do: %{state | gh: gh}
  def next_state(state, _result, {:call, _, :set_agent, [agent]}), do: %{state | agent: agent}
  def next_state(state, _result, {:call, _, :set_ssh, [ssh]}), do: %{state | ssh: ssh}

  def next_state(state, result, {:call, _, :set_up, []}) do
    cond do
      not state.gh ->
        %{state | routes: [:git], asking: nil, settles: []}

      not state.agent ->
        %{state | routes: [:https], asking: nil, settles: []}

      true ->
        before = if state.asking, do: state.routes ++ state.settles, else: state.routes
        # An empty include is git on SSH already, which stands until SSH answers.
        routes = before |> Enum.map(&if(&1 == :git, do: :git, else: :https)) |> Enum.uniq()

        settles =
          case state.ssh do
            :answers -> [:git]
            :refused -> [:https]
            _ -> routes
          end

        %{state | routes: routes, asking: result, asks: state.ssh, settles: settles}
    end
  end

  def next_state(state, _result, {:call, _, :settle, _}),
    do: %{state | routes: state.settles, asking: nil, settles: []}

  # A call returns at once, with the route git keeps meanwhile already in place.
  def postcondition(state, {:call, _, :set_up, []}, result) do
    after_call = next_state(state, result, {:call, __MODULE__, :set_up, []})

    shape =
      if after_call.asking,
        do: match?({:asking, pid} when is_pid(pid), result),
        else: result == :ok

    shape and route() in after_call.routes
  end

  def postcondition(state, {:call, _, :settle, _}, route), do: route in state.settles
  def postcondition(_state, _call, _result), do: true

  # --- commands ---------------------------------------------------------------

  def set_gh(true), do: File.write!(hosts(), "github.com:\n    user: acme\n")
  def set_gh(false), do: File.rm_rf!(hosts())

  def set_agent(true),
    do: System.put_env("SSH_AUTH_SOCK", Path.join(Process.get(:home), "agent.sock"))

  def set_agent(false), do: System.delete_env("SSH_AUTH_SOCK")

  def set_ssh(outcome) do
    ms = if outcome == :stalls, do: @stall_ms, else: @hang_ms
    Application.put_env(:hal_c2, :github_ssh_timeout, ms)
    script = if outcome == :stalls, do: "hangs", else: to_string(outcome)
    File.write!(Path.join(Process.get(:bin), "outcome"), script)
  end

  def set_up, do: HalC2.Git.use_gh_for_github()

  # Waits for the asking to end, its receipt, and returns the route it left.
  def settle({:asking, pid}) do
    await(pid, fn -> :ok end)
    route()
  end

  defp await(pid, then) do
    ref = Process.monitor(pid)
    then.()

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      30_000 -> raise "the call asking SSH never ended"
    end
  end

  defp hosts, do: Path.join([Process.get(:home), "gh", "hosts.yml"])

  defp route do
    case File.read(Path.join(HalC2.Paths.state_dir(), "github.gitconfig")) do
      {:error, :enoent} ->
        :missing

      {:ok, ""} ->
        :git

      {:ok, text} ->
        if text =~ "insteadOf = git@github.com:", do: :https, else: {:unexpected, text}
    end
  end

  # Gone, or a zombie no one has reaped yet: either way it runs no more.
  defp stopped_within?(_os_pid, 0), do: false

  defp stopped_within?(os_pid, tries) do
    stopped =
      case File.read("/proc/#{os_pid}/stat") do
        {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.starts_with?("Z")
        {:error, _} -> true
      end

    stopped or (Process.sleep(20) == :ok and stopped_within?(os_pid, tries - 1))
  end
end
