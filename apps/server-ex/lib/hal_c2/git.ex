defmodule HalC2.Git do
  @moduledoc """
  Runs git for checkpoints and review diffs. Output past `:max_bytes` is dropped
  and reported as truncated, so a huge diff never lands in memory whole.
  """

  @type result :: %{status: integer | term, out: binary, err: binary, truncated: boolean}

  @doc """
  Runs `git args` in `cwd`. Options: `:env` (`[{name, value}]`), `:input` (stdin),
  `:max_bytes` (default 50 MB) and `:timeout` (ms; none by default). Fails only when
  git cannot be started, will not exit, or runs past its timeout, saying which.
  `Application.get_env(:hal_c2, :git_command)` stands in for `git`.
  """
  @spec run(Path.t(), [String.t()], keyword) :: {:ok, result} | {:error, String.t()}
  def run(cwd, args, opts \\ []) do
    case opts[:timeout] do
      nil ->
        stream(cwd, args, opts)

      ms ->
        # Killing the task takes git with it: Exile stops a process its owner left.
        task = Task.async(fn -> stream(cwd, args, opts) end)

        case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> {:error, "git #{hd(args)} timed out after #{ms} ms"}
        end
    end
  end

  defp stream(cwd, args, opts) do
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
      [Application.get_env(:hal_c2, :git_command, "git") | args]
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
    error -> {:error, "git could not be started: #{Exception.message(error)}"}
  catch
    # Exile exits the caller when git outlives every signal (`:kill_timeout`).
    :exit, reason -> {:error, "git did not exit: #{inspect(reason)}"}
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
  with the GitHub CLI's sign-in: GitHub's SSH addresses go over HTTPS, and
  `gh auth git-credential` answers for them. An MC running as a service has no SSH
  agent, so a key behind a passphrase never answers there. Does nothing when gh is
  not installed or not signed in to github.com.
  """
  def use_gh_for_github do
    # GIT_CONFIG_COUNT entries come after every config file, as `-c` does.
    count = String.to_integer(System.get_env("GIT_CONFIG_COUNT") || "0")

    with gh when is_binary(gh) <- System.find_executable("gh"),
         helper = "!#{gh} auth git-credential",
         # Set up once: a hot update asks again.
         false <-
           Enum.any?(0..(count - 1)//1, &(System.get_env("GIT_CONFIG_VALUE_#{&1}") == helper)),
         true <- gh_signed_in?() do
      entries = [
        {"url.https://github.com/.insteadOf", "git@github.com:"},
        {"url.https://github.com/.insteadOf", "ssh://git@github.com/"},
        # An empty helper drops the ones configured before, as `gh auth setup-git` does.
        {"credential.https://github.com.helper", ""},
        {"credential.https://github.com.helper", helper}
      ]

      for {{key, value}, i} <- Enum.with_index(entries, count) do
        System.put_env("GIT_CONFIG_KEY_#{i}", key)
        System.put_env("GIT_CONFIG_VALUE_#{i}", value)
      end

      System.put_env("GIT_CONFIG_COUNT", Integer.to_string(count + length(entries)))
    end

    :ok
  end

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
