defmodule HalC2.Git do
  @moduledoc """
  Runs git for checkpoints and review diffs. Output past `:max_bytes` is dropped
  and reported as truncated, so a huge diff never lands in memory whole.
  """

  require Logger

  # The process asking whether SSH answers for GitHub (`use_gh_for_github/0`).
  @asking HalC2.Git.GitHubSsh

  @type result :: %{status: integer | term, out: binary, err: binary, truncated: boolean}

  @doc """
  Runs `git args` in `cwd`. Options: `:env` (`[{name, value}]`), `:input` (stdin),
  `:max_bytes` (default 50 MB) and `:timeout` (ms; none by default). Fails only when
  git cannot be started, will not exit, or runs past its timeout, saying which.
  `Application.get_env(:hal_c2, :git_command)` stands in for `git`.
  """
  @spec run(Path.t(), [String.t()], keyword) :: {:ok, result} | {:error, String.t()}
  def run(cwd, args, opts \\ []) do
    argv = [Application.get_env(:hal_c2, :git_command, "git") | args]

    case within(opts[:timeout], fn -> stream("git", argv, cwd, opts) end) do
      {:ok, result} -> result
      :timeout -> {:error, "git #{hd(args)} timed out after #{opts[:timeout]} ms"}
    end
  end

  # Killing the task takes the program with it: Exile stops a process its owner left.
  defp within(nil, fun), do: {:ok, fun.()}

  defp within(ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> :timeout
    end
  end

  defp stream(name, argv, cwd, opts) do
    max = Keyword.get(opts, :max_bytes, 50_000_000)

    # Git that closed its output gets time to exit before it is killed: on a machine
    # deep in swap that takes longer than Exile's default.
    exile_opts =
      [
        cd: cwd,
        env: Keyword.get(opts, :env, []),
        stderr: :consume,
        ignore_epipe: true,
        exit_timeout: 30_000
      ] ++
        if(input = opts[:input], do: [input: [input]], else: [])

    {out, err, size, status} =
      argv
      |> Exile.stream(exile_opts)
      |> Enum.reduce({[], [], 0, nil}, fn
        {:stdout, data}, {out, err, size, status} when size < max ->
          {[out, data], err, size + IO.iodata_length(data), status}

        {:stdout, data}, {out, err, size, status} ->
          {out, err, size + IO.iodata_length(data), status}

        {:stderr, data}, {out, err, size, status} ->
          {out, [err, data], size, status}

        {:exit, status}, {out, err, size, _} ->
          {out, err, size, status}
      end)

    out = IO.iodata_to_binary(out)

    {:ok,
     %{
       status: exit_code(status),
       out: binary_part(out, 0, min(byte_size(out), max)),
       err: IO.iodata_to_binary(err),
       truncated: size > max
     }}
  rescue
    error -> {:error, "#{name} could not be started: #{Exception.message(error)}"}
  catch
    # Exile exits the caller when the program outlives every signal (`:kill_timeout`).
    :exit, reason -> {:error, "#{name} did not exit: #{inspect(reason)}"}
  end

  @doc "Runs git and returns its stdout when it exits 0."
  @spec ok(Path.t(), [String.t()], keyword) :: {:ok, binary} | {:error, term}
  def ok(cwd, args, opts \\ []) do
    case run(cwd, args, opts) do
      {:ok, %{status: 0, out: out}} -> {:ok, out}
      {:ok, %{status: status, err: err}} -> {:error, {status, String.trim(err)}}
      error -> error
    end
  end

  @doc "The checked-out branch, or nil when HEAD is detached."
  def current_branch(root) do
    case ok(root, ~w(symbolic-ref --short -q HEAD)) do
      {:ok, branch} -> String.trim(branch) |> then(&if(&1 == "", do: nil, else: &1))
      _ -> nil
    end
  end

  @doc """
  The branch this one merges into: its gh-merge-base, the remote's default
  branch, then main or master; remote-tracking refs preferred.
  """
  def base_branch(root, branch) do
    configured = git_line(root, ["config", "--get", "branch.#{branch}.gh-merge-base"])
    remote = primary_remote(root)

    default =
      remote &&
        case git_line(root, ["symbolic-ref", "refs/remotes/#{remote}/HEAD"]) do
          "refs/remotes/" <> rest -> String.replace_prefix(rest, "#{remote}/", "")
          _ -> nil
        end

    [configured, default, "main", "master"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(fn candidate ->
      candidate
      |> String.replace_prefix("origin/", "")
      |> then(
        &if(remote && remote != "origin",
          do: String.replace_prefix(&1, "#{remote}/", ""),
          else: &1
        )
      )
    end)
    |> Enum.reject(&(&1 == "" or &1 == branch))
    |> Enum.find_value(fn candidate ->
      cond do
        remote && ref?(root, "refs/remotes/#{remote}/#{candidate}") -> "#{remote}/#{candidate}"
        ref?(root, "refs/heads/#{candidate}") -> candidate
        true -> nil
      end
    end)
  end

  @doc "`origin` when it exists, else the first remote, or nil."
  def primary_remote(root) do
    case ok(root, ["remote"]) do
      {:ok, out} ->
        remotes = String.split(out, "\n", trim: true)
        if "origin" in remotes, do: "origin", else: List.first(remotes)

      _ ->
        nil
    end
  end

  @doc """
  Whether another branch sits on `name`'s path, so git cannot create it: branches are
  files under `refs/heads`, and `hal-c2` and `hal-c2/x` would need one path to be both
  a file and a folder. A branch named exactly `name` is not in the way.
  """
  def branch_path_taken?(root, name) do
    [first | _] = String.split(name, "/")

    case ok(root, ["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/#{first}"]) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> branch_path_taken_by?(name)
      _ -> false
    end
  end

  @doc "Whether any of `branches` sits on `name`'s path (`branch_path_taken?/2`)."
  def branch_path_taken_by?(branches, name) do
    Enum.any?(branches, fn branch ->
      String.starts_with?(name, branch <> "/") or String.starts_with?(branch, name <> "/")
    end)
  end

  @doc """
  Has every git the MC starts (its own, its agents' and its terminals') reach GitHub
  with the GitHub CLI's sign-in when there is one: GitHub's SSH addresses go over
  HTTPS, and `gh auth git-credential` answers for them. An MC running as a service
  has no SSH agent, so a key behind a passphrase never answers there.

  Where SSH does answer for GitHub, git is left on SSH: the CLI's sign-in has no
  `workflow` scope when it was made for SSH, and HTTPS would refuse a push that
  changes a workflow. Only an MC with an SSH agent asks (`ssh -T git@github.com`,
  which GitHub greets for a key it takes, the agent's or a file's), so a service
  stays off the network here, and an MC without an agent stays on HTTPS even where
  a key file without a passphrase would answer.

  Asking does not hold up the caller (the upgrader, at boot). It runs in a process
  of its own; until SSH answers or is refused, git keeps the route the last call
  chose (HTTPS when there was none), and an SSH that cannot reach GitHub or runs past
  its time leaves that route as it is. A later call stops an earlier one still
  asking. Returns `{:asking, pid}` while it asks, the process ending once git has the
  answer, and `:ok` when there was nothing to ask. Each choice is logged with why.

  A user's own `https://github.com/` rule would undo the rewrite (git rewrites an
  address once, by the longest matching prefix, and the first one on a tie), so the
  file also holds a rule for each first character of an owner's name, one character
  longer than theirs, that keeps the address on HTTPS. It beats any rule for the
  whole host, one to an HTTPS mirror as much as one to SSH. A rule for one owner
  (`https://github.com/acme/`) is longer and still wins for a fetch; a push stays on
  HTTPS, as git takes a `pushInsteadOf` over any `insteadOf`.

  Git includes a file the MC owns and writes again on each call (at boot and after
  a hot update), so a later sign-in or sign-out reaches git already running too.
  """
  def use_gh_for_github do
    file = Path.join(HalC2.Paths.state_dir(), "github.gitconfig")
    include(file)
    stop_asking()

    case github_route() do
      {:ask, ssh, https} ->
        # A file left empty by the last call is git on SSH, which stands until SSH answers.
        if File.read(file) != {:ok, ""}, do: write_config(file, https)

        {:ok, pid} = Task.start(fn -> receive(do: (:ask -> ask_ssh(file, ssh, https))) end)
        Process.register(pid, @asking)
        send(pid, :ask)
        {:asking, pid}

      config ->
        write_config(file, config)
        :ok
    end
  end

  # GIT_CONFIG_COUNT entries come after every config file, as `-c` does.
  defp include(file) do
    count = String.to_integer(System.get_env("GIT_CONFIG_COUNT") || "0")

    unless Enum.any?(0..(count - 1)//1, &(System.get_env("GIT_CONFIG_VALUE_#{&1}") == file)) do
      System.put_env(%{
        "GIT_CONFIG_KEY_#{count}" => "include.path",
        "GIT_CONFIG_VALUE_#{count}" => file,
        "GIT_CONFIG_COUNT" => Integer.to_string(count + 1)
      })
    end
  end

  # A file that could not be written is left out: git skips a missing include.
  defp write_config(file, config) do
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, config),
         do: File.rename(tmp, file)
  end

  # The config git gets, or `{:ask, ssh, https}` when SSH may answer for GitHub instead
  # of the HTTPS config.
  defp github_route do
    with gh when is_binary(gh) <- System.find_executable("gh"),
         true <- gh_signed_in?() do
      https = https_config(gh)

      with sock when sock not in [nil, ""] <- System.get_env("SSH_AUTH_SOCK"),
           ssh when is_binary(ssh) <- System.find_executable("ssh") do
        {:ask, ssh, https}
      else
        _ ->
          Logger.info(
            "Git reaches GitHub over HTTPS with the GitHub CLI's sign-in: no SSH agent."
          )

          https
      end
    else
      _ ->
        Logger.info("Git reaches GitHub as it is configured: the GitHub CLI is not signed in.")
        ""
    end
  end

  defp https_config(gh) do
    # Git runs the helper through a shell, which would split a path with a space.
    helper = "!'#{String.replace(gh, "'", "'\\''")}' auth git-credential"

    """
    [url "https://github.com/"]
    \tinsteadOf = git@github.com:
    \tinsteadOf = ssh://git@github.com/
    #{keep_https_rules()}\
    [credential "https://github.com"]
    \t# An empty helper drops the ones configured before, as `gh auth setup-git` does.
    \thelper =
    \thelper = "#{String.replace(helper, ~w(\\ "), &("\\" <> &1))}"
    """
  end

  # `https://github.com/a` kept as it is, for a..z, A..Z and 0..9 (the first character
  # of any owner name GitHub allows): each is longer than a user's `https://github.com/`
  # rule, so it wins. `pushInsteadOf` does the same for pushes, which a user's own
  # `pushInsteadOf` would take over.
  defp keep_https_rules do
    for first <- Enum.concat([?a..?z, ?A..?Z, ?0..?9]), into: "" do
      prefix = "https://github.com/" <> <<first>>
      "[url \"#{prefix}\"]\n\tinsteadOf = #{prefix}\n\tpushInsteadOf = #{prefix}\n"
    end
  end

  defp stop_asking do
    with pid when is_pid(pid) <- Process.whereis(@asking) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
    end
  end

  # Runs as `@asking`. An ssh past its time is not left behind: `within/2` kills the
  # task that owns it, and Exile then the program. An agent without keys is refused too.
  defp ask_ssh(file, ssh, https) do
    ms = Application.get_env(:hal_c2, :github_ssh_timeout, 8_000)

    argv = [
      ssh | ~w(-T -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=3 git@github.com)
    ]

    case within(ms, fn -> stream("ssh", argv, Path.dirname(file), max_bytes: 65_536) end) do
      {:ok, {:ok, %{out: out, err: err}}} ->
        said = String.trim(out <> err)

        cond do
          # GitHub greets a key it knows and then exits 1, as it gives no shell.
          said =~ "successfully authenticated" ->
            Logger.info("Git stays on SSH for GitHub, which answers it.")
            write_config(file, "")

          said =~ "Permission denied" ->
            Logger.info(
              "Git reaches GitHub over HTTPS with the GitHub CLI's sign-in: " <>
                "GitHub refused SSH (#{last_line(said)})."
            )

            write_config(file, https)

          true ->
            Logger.info(
              "Git keeps its route to GitHub: SSH did not reach it (#{last_line(said)})."
            )
        end

      {:ok, {:error, reason}} ->
        Logger.info("Git keeps its route to GitHub: #{reason}.")

      :timeout ->
        Logger.info("Git keeps its route to GitHub: SSH did not answer in #{ms} ms.")
    end
  end

  defp last_line(text), do: text |> String.split("\n") |> List.last()

  # Read from gh's hosts file rather than asked of gh, which would open the keyring
  # holding the token at boot.
  defp gh_signed_in? do
    dir =
      System.get_env("GH_CONFIG_DIR") ||
        Path.join(System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"), "gh")

    case File.read(Path.join(dir, "hosts.yml")) do
      {:ok, hosts} -> Regex.match?(~r/^github\.com:/m, hosts)
      {:error, _} -> false
    end
  end

  defp ref?(root, ref),
    do: match?({:ok, _}, ok(root, ["show-ref", "--verify", "--quiet", ref]))

  defp git_line(root, args) do
    case ok(root, args) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  defp exit_code({:status, code}), do: code
  defp exit_code(other), do: other
end
