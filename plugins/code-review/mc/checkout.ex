defmodule HalC2Plugins.CodeReview.Checkout do
  @moduledoc """
  The checkout a review's agent works in: a detached worktree, at the pull request's
  head, of the plugin's own bare clone of the repository. Both live under the plugin's
  data directory, so the user's repository is never fetched into or given a worktree.
  The clone is fetched over HTTP(S), which a service can where it may have no SSH
  agent: from GitHub with gh's credentials, from Forgejo with the token the MC reads
  it with.
  """

  # The attempts whose refs a process holds: `{clone, attempt}` to its pid.
  @held HalC2Plugins.CodeReview.Checkout.Held

  @doc """
  Fetches pull request `number` and its base branch `base` from `remote` into the bare
  clone at `clone`, made on first use, and puts the worktree at `path` on its head.
  `remote` is `%{"url"}` with how to sign in: `"gh" => true` for gh's credentials, or
  a `"username"` and `"token"`. Answers `{:ok, %{"path", "headSha", "baseSha",
  "mergeBase", "headRef", "baseRef"}}`: `baseSha` is the base branch as fetched,
  `mergeBase` nil when it shares no history with the head, and the two refs hold the
  head and base in the clone until `release/0`.
  """
  def prepare(clone, path, %{"url" => url} = remote, number, base) do
    # Each attempt fetches into refs of its own: a stopped review's fetch may still
    # finish, and must not move the head or base this one reads.
    attempt = "refs/hal-c2/code-review/#{number}/attempt-#{System.unique_integer([:positive])}"

    with :ok <- hold(clone, attempt) do
      case prepare_attempt(clone, path, remote, url, number, base, attempt) do
        {:ok, checkout} ->
          {:ok,
           Map.merge(checkout, %{"headRef" => "#{attempt}/head", "baseRef" => "#{attempt}/base"})}

        error ->
          release()
          error
      end
    end
  end

  @doc """
  Makes the table of the attempts being held, owned by the calling process: the
  plugin's server, which the runs holding them are linked to. It is this machine's
  alone, as the clones are: a lookup in it asks no other node.
  """
  def start do
    if :ets.whereis(@held) == :undefined,
      do: :ets.new(@held, [:named_table, :public, :set, read_concurrency: true])

    :ok
  end

  # Records this process as the holder of `attempt`'s refs, until `release/0` or its end.
  defp hold(clone, attempt) do
    if :ets.insert_new(@held, {{clone, attempt}, self()}) do
      Process.put(__MODULE__, [{clone, attempt} | Process.get(__MODULE__, [])])
      :ok
    else
      {:error, "Another checkout holds #{attempt}."}
    end
  rescue
    ArgumentError -> {:error, "The code review plugin is not running."}
  end

  # Whether a process still holds `attempt`, forgetting a holder that ended.
  defp held?(clone, attempt) do
    case :ets.lookup(@held, {clone, attempt}) do
      [{_key, pid}] ->
        if Process.alive?(pid) do
          true
        else
          :ets.delete(@held, {clone, attempt})
          false
        end

      [] ->
        false
    end
  end

  @doc """
  Drops the refs of the checkouts this process prepared, which hold the head and base
  they fetched until a sandbox is made from them. Those of a process that ends first
  are dropped by the next checkout of the pull request.
  """
  def release do
    for {clone, attempt} <- Process.delete(__MODULE__) || [] do
      drop(clone, attempt)
      if :ets.whereis(@held) != :undefined, do: :ets.delete(@held, {clone, attempt})
    end

    :ok
  end

  defp prepare_attempt(clone, path, remote, url, number, base, attempt) do
    head_ref = "refs/hal-c2/code-review/#{number}/head"
    base_ref = "refs/hal-c2/code-review/#{number}/base"

    with :ok <- alone(clone, fn -> init(clone, url) end),
         :ok <- sweep(clone, number),
         {:ok, {credentials, env}} <- credentials(clone, remote, url),
         {:ok, _} <-
           git(
             clone,
             credentials ++
               [
                 "fetch",
                 "-q",
                 "--no-tags",
                 # Reviews fetch side by side; FETCH_HEAD is the one file they would share.
                 "--no-write-fetch-head",
                 url,
                 "+refs/pull/#{number}/head:#{attempt}/head",
                 "+refs/heads/#{base}:#{attempt}/base"
               ],
             env
           ),
         {:ok, head} <- git(clone, ["rev-parse", "#{attempt}/head"]),
         {:ok, base_sha} <- git(clone, ["rev-parse", "#{attempt}/base"]),
         :ok <- publish(clone, [{head_ref, head}, {base_ref, base_sha}]),
         :ok <- alone(clone, fn -> place(clone, path, head) end) do
      # Nil when the two have no common ancestor, as after the base branch was rewritten:
      # a merge-base git did not find is not one the sandbox can check its checkout for.
      merge_base =
        case git(clone, ["merge-base", base_sha, head]) do
          {:ok, sha} when sha != "" -> sha
          _ -> nil
        end

      {:ok,
       %{"path" => path, "headSha" => head, "baseSha" => base_sha, "mergeBase" => merge_base}}
    end
  end

  # The pull request's refs, which keep what the last checkout of it fetched, are set
  # to what this attempt fetched. A sandbox is made from the attempt's own refs, which
  # an attempt stopped meanwhile cannot move.
  defp publish(clone, refs) do
    Enum.reduce_while(refs, :ok, fn {ref, sha}, :ok ->
      case git(clone, ["update-ref", ref, sha]) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp drop(clone, attempt) do
    for side <- ~w(head base), do: git(clone, ["update-ref", "-d", "#{attempt}/#{side}"])
    :ok
  end

  # The refs of attempts no process holds any more: a stopped review's fetch that
  # finished after it was stopped leaves its refs, as nothing is left to drop them. A
  # live attempt is held in `@held` until it is released.
  defp sweep(clone, number) do
    with {:ok, refs} <-
           git(clone, [
             "for-each-ref",
             "--format=%(refname)",
             "refs/hal-c2/code-review/#{number}/"
           ]) do
      refs
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn ref ->
        case Regex.run(~r{^(.+/attempt-\d+)/(?:head|base)$}, ref) do
          [_, attempt] -> [attempt]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.reject(&held?(clone, &1))
      |> Enum.each(&drop(clone, &1))
    end

    :ok
  end

  @doc """
  Checks out the submodules of the worktree at `path`, of the bare clone at `clone`,
  at the commits its head pins, nested ones included; `remote` signs in as for
  `prepare/5`. Answers `:ok` at once when the head has no `.gitmodules`, else `:ok`
  or `{:error, reason}`: a checkout missing some submodules is still reviewed.

  Git keeps a worktree's submodule repositories under its own admin directory in the
  clone, which `remove/2` takes with it. Each is cloned with the clone's shared store
  of submodule objects as an alternate, and what it fetched goes into the store after,
  so the next review downloads only what is new. Nothing is written to the clone's
  config, which every review of the repository shares: the submodules are made active
  and cloned from the head's `.gitmodules` for this command alone. Only HTTP(S) and SSH
  are used, so a `.gitmodules` cannot point git at a local path, run a command through
  `ext::` or reach a `git://` server, which nothing times out. A transfer that stalls is
  dropped (HTTP under 1 KB/s for a minute, SSH that stops answering), and the whole
  update has `@submodules_ms` before it and what it started are killed.
  """
  def submodules(clone, path, %{"url" => url} = remote) do
    if File.regular?(Path.join(path, ".gitmodules")) do
      store = Path.join(clone, "hal-c2-submodules")

      with {:ok, _} <- git(clone, ["init", "-q", "--bare", store]),
           {:ok, {credentials, env}} <- credentials(clone, remote, url),
           {:ok, _} <-
             bounded_git(
               path,
               credentials ++
                 [
                   "-c",
                   "submodule.active=.",
                   "-c",
                   "http.lowSpeedLimit=1000",
                   "-c",
                   "http.lowSpeedTime=60",
                   "submodule",
                   "update",
                   "--recursive",
                   "--reference",
                   store
                 ],
               [{"GIT_ALLOW_PROTOCOL", "https:http:ssh"} | ssh_env() ++ env]
             ),
           do: store(store, path)
    else
      :ok
    end
  end

  @submodules_ms 15 * 60_000

  # SSH that gives up on a server that does not connect or stops answering, unless the
  # MC's environment names its own SSH command, which the overall timeout still bounds.
  defp ssh_env do
    if System.get_env("GIT_SSH_COMMAND") in [nil, ""],
      do: [
        {"GIT_SSH_COMMAND",
         "ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"}
      ],
      else: []
  end

  # Puts the objects of the checkout's submodules into the store, under refs named for
  # each one's remote so a later clone of it finds them, as far as it can: the checkout
  # is whole without them. Git never collects garbage in the store (`gc.auto=0`), as the
  # checkouts borrowing its objects do not hold its refs. Paths come NUL-separated, as a
  # submodule's path can hold any character but NUL.
  defp store(store, path) do
    with {:ok, paths} <-
           git(path, [
             "submodule",
             "foreach",
             "--recursive",
             "--quiet",
             ~S(printf '%s\0' "$displaypath")
           ]) do
      for sub <- String.split(paths, <<0>>, trim: true),
          sub = Path.join(path, sub),
          {:ok, from} <- [git(sub, ["config", "remote.origin.url"])] do
        key = :crypto.hash(:sha256, from) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        git(
          store,
          [
            "-c",
            "gc.auto=0",
            "fetch",
            "-q",
            "--no-tags",
            "--no-write-fetch-head",
            sub,
            "+HEAD:refs/hal-c2/submodules/#{key}/head",
            "+refs/remotes/origin/*:refs/hal-c2/submodules/#{key}/remotes/*"
          ],
          [{"GIT_ALLOW_PROTOCOL", "file"}]
        )
      end
    end

    :ok
  end

  @doc "Removes the worktree at `path` from the repository at `root`, if it is there."
  def remove(root, path) do
    alone(root, fn ->
      git(root, ["worktree", "remove", "--force", path])
      File.rm_rf(path)
      git(root, ["worktree", "prune"])
    end)

    :ok
  end

  @doc """
  The text of `file` at commit `sha` in the checkout at `path`, or nil when the commit
  has no such regular file, it is over `limit` bytes or it is not UTF-8 text. It is read
  from git rather than the worktree: the pull request decides what the worktree holds,
  links included.
  """
  def read(path, sha, file, limit) do
    with {:ok, entry} <- git(path, ["ls-tree", "-l", sha, "--", file]),
         [mode, "blob", object, size | _] when mode in ~w(100644 100755) <- String.split(entry),
         true <- String.to_integer(size) <= limit,
         {:ok, text} <- git(path, ["cat-file", "blob", object]),
         true <- String.valid?(text) do
      text
    else
      _ -> nil
    end
  end

  @doc """
  The lines of the change `from`..`to` in the checkout at `path` a review comment
  can sit on, as `%{path => %{{side, line} => kind}}`: `side` is `"new"` or `"old"`
  and `kind` is `"added"`, `"deleted"` or `"context"`.
  """
  def diff_lines(path, from, to) do
    case git(path, ["diff", "--no-color", "--no-ext-diff", "-U3", from, to]) do
      {:ok, diff} -> parse(diff)
      _ -> %{}
    end
  end

  @doc """
  The position `pullRequests.submitReview` takes for a comment on `line` of `file`
  (`side` `"new"` or `"old"`), or nil when the change does not show that line.
  """
  def position(lines, file, line, side) do
    case {side, get_in(lines, [file, {side, line}])} do
      {"new", "added"} -> %{"kind" => "added", "newLine" => line}
      {"new", "context"} -> %{"kind" => "context", "newLine" => line}
      {"old", "deleted"} -> %{"kind" => "deleted", "oldLine" => line}
      {"old", "context"} -> %{"kind" => "context", "side" => "left", "oldLine" => line}
      _ -> nil
    end
  end

  # File names are read from each file's header only, as a changed line can look
  # like one. A deleted file is named by its old path alone.
  defp parse(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({%{}, nil, 0, 0, false}, fn text, {files, file, old, new, header?} = acc ->
      cond do
        String.starts_with?(text, "diff --git ") ->
          {files, nil, 0, 0, true}

        header? and String.starts_with?(text, "--- ") ->
          {files, header_path(text, "a/") || file, 0, 0, true}

        header? and String.starts_with?(text, "+++ ") ->
          {files, header_path(text, "b/") || file, 0, 0, true}

        match = Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, text) ->
          [_, old, new] = match
          {files, file, String.to_integer(old), String.to_integer(new), false}

        header? or file == nil ->
          acc

        String.starts_with?(text, "+") ->
          {mark(files, file, {"new", new}, "added"), file, old, new + 1, false}

        String.starts_with?(text, "-") ->
          {mark(files, file, {"old", old}, "deleted"), file, old + 1, new, false}

        String.starts_with?(text, " ") ->
          files =
            files |> mark(file, {"new", new}, "context") |> mark(file, {"old", old}, "context")

          {files, file, old + 1, new + 1, false}

        true ->
          acc
      end
    end)
    |> elem(0)
  end

  # The path of a `---`/`+++` line, nil for /dev/null. Git quotes a path with
  # unusual characters as a C string ("a/\303\251.ts") and ends one with a space
  # in a tab.
  defp header_path(<<_marker::binary-size(4), path::binary>>, prefix) do
    path = String.trim_trailing(path, "\t")

    path =
      if String.starts_with?(path, "\"") and String.ends_with?(path, "\""),
        do: path |> binary_part(1, byte_size(path) - 2) |> unquote_c(<<>>),
        else: path

    if String.starts_with?(path, prefix), do: String.replace_prefix(path, prefix, "")
  end

  defp unquote_c(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: unquote_c(rest, <<acc::binary, (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)>>)

  defp unquote_c(<<?\\, char, rest::binary>>, acc),
    do: unquote_c(rest, <<acc::binary, escaped(char)>>)

  defp unquote_c(<<char, rest::binary>>, acc), do: unquote_c(rest, <<acc::binary, char>>)
  defp unquote_c(<<>>, acc), do: acc

  defp escaped(?n), do: ?\n
  defp escaped(?t), do: ?\t
  defp escaped(?r), do: ?\r
  defp escaped(?a), do: 7
  defp escaped(?b), do: ?\b
  defp escaped(?f), do: ?\f
  defp escaped(?v), do: ?\v
  defp escaped(char), do: char

  defp mark(files, file, key, kind),
    do: Map.update(files, file, %{key => kind}, &Map.put(&1, key, kind))

  # Each review gets a worktree of its own, so whatever is left at `path` goes.
  defp place(root, path, sha) do
    File.rm_rf(path)
    git(root, ["worktree", "prune"])
    File.mkdir_p!(Path.dirname(path))

    with {:ok, _} <- git(root, ["worktree", "add", "-q", "--detach", "--force", path, sha]),
         do: :ok
  end

  # Reviews of one repository share its clone; one at a time makes it or changes its
  # worktrees, or one's prune takes another's worktree while it is being added.
  defp alone(repository, fun),
    do: :global.trans({{__MODULE__, repository}, self()}, fun, [node()])

  # Run each time, as `git init` leaves a clone alone and finishes one it was cut short making.
  # `origin` is for the agent's git in a checkout; the plugin fetches `url` itself.
  defp init(clone, url) do
    File.mkdir_p!(Path.dirname(clone))

    with {:ok, _} <- git(Path.dirname(clone), ["init", "-q", "--bare", clone]),
         {:ok, _} <- git(clone, ["config", "remote.origin.url", url]),
         {:ok, _} <-
           git(clone, ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"]),
         do: :ok
  end

  # The address git fetches `url` from, after the `insteadOf` rewrites in the config it
  # is given: the server a token's helper is for.
  defp fetched_url(clone, url) do
    case git(clone, ["ls-remote", "--get-url", url]) do
      {:ok, fetched} when fetched != "" -> fetched
      _ -> url
    end
  end

  # Git's only credential helper for the fetch, with what it reads from the environment,
  # `{:ok, {args, env}}`. gh's is as `gh auth setup-git` would make it. A token goes in
  # the environment, never in the command line, where any process could read it. Git
  # runs a helper through a shell.
  defp credentials(_clone, %{"gh" => true}, _url) do
    case System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) do
      nil ->
        {:ok, {[], []}}

      gh ->
        gh = String.replace(gh, "'", "'\\''")

        {:ok,
         {["-c", "credential.helper=", "-c", "credential.helper=!'#{gh}' auth git-credential"],
          []}}
    end
  end

  # A token goes only to the server it was issued for (`server`, else `url`'s), and over
  # a checked certificate: the configuration the MC's environment hands git
  # (`GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS`) can rewrite `url` to another server
  # or turn the check off, and is refused when it does. The helper is configured for
  # that origin alone (`credential.<url>.helper`), so git asks it about no other: a
  # fetch redirected elsewhere gets nothing.
  defp credentials(clone, %{"token" => token} = remote, url)
       when is_binary(token) and token != "" do
    helper =
      ~S|!f() { test "$1" = get && printf 'username=%s\npassword=%s\n' "$HAL_C2_GIT_USERNAME" "$HAL_C2_GIT_TOKEN"; }; f|

    fetched = fetched_url(clone, url)
    issuer = origin(remote["server"] || url)

    cond do
      is_nil(issuer) or origin(fetched) != issuer ->
        {:error,
         "git would fetch #{url} from #{origin(fetched) || fetched}, not from the server " <>
           "its token is for; check the git configuration the MC is started with."}

      git(clone, ["config", "--type=bool", "--get-urlmatch", "http.sslVerify", fetched]) ==
          {:ok, "false"} ->
        {:error,
         "git is configured not to check #{issuer}'s certificate, so its token is not " <>
           "sent; check the git configuration the MC is started with."}

      true ->
        {:ok,
         {["-c", "credential.helper=", "-c", "credential.#{issuer}.helper=" <> helper],
          [{"HAL_C2_GIT_USERNAME", remote["username"] || "hal-c2"}, {"HAL_C2_GIT_TOKEN", token}]}}
    end
  end

  defp credentials(_clone, _remote, _url), do: {:ok, {["-c", "credential.helper="], []}}

  # `scheme://host[:port]` of an HTTP(S) URL, or nil.
  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ~w(http https) and is_binary(host) and host != "" ->
        if port && port != URI.default_port(scheme),
          do: "#{scheme}://#{host}:#{port}",
          else: "#{scheme}://#{host}"

      _ ->
        nil
    end
  end

  # The clone is the plugin's, so the user's git config is left out: its `insteadOf`
  # can turn the HTTPS address back into SSH, and its hooks have no business here. Nor
  # does an inherited `GIT_SSL_NO_VERIFY` turn off the server's certificate check, or
  # `GIT_CONFIG` point `git config` at a file other than the one `git fetch` reads, so
  # the certificate check is read from what the fetch uses. Tracing is off, as a trace
  # of the fetch can carry its token into the error a failed one answers; the token is
  # taken out of that error as well.
  @untraced ~w(GIT_TRACE GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE
               GIT_TRACE_PACKET GIT_TRACE_PACKFILE GIT_TRACE_SETUP GIT_TRACE2
               GIT_TRACE2_EVENT GIT_TRACE2_PERF)

  defp git(cwd, args, env \\ []) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: git_env() ++ env) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, failed(args, out, env)}
    end
  rescue
    e in [ErlangError, File.Error] ->
      {:error, "git #{command(args)} failed: #{Exception.message(e)}"}
  end

  defp git_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG", nil},
      {"GIT_SSL_NO_VERIFY", nil},
      {"GIT_TRACE_REDACT", "1"}
    ] ++ Enum.map(@untraced, &{&1, nil})
  end

  defp failed(args, out, env) do
    said =
      out
      |> redact(env)
      |> String.split("\n", trim: true)
      |> Enum.map_join(" ", &String.trim/1)

    "git #{command(args)} failed: #{said}"
  end

  # `git/3` under `@submodules_ms`: past it git and the programs it started are killed.
  defp bounded_git(cwd, args, env) do
    {unset, set} = Enum.split_with(git_env() ++ env, &match?({_, nil}, &1))

    case HalC2.Git.run(cwd, args,
           env: set,
           unset: Enum.map(unset, &elem(&1, 0)),
           timeout: @submodules_ms,
           stop_children: {__MODULE__, cwd}
         ) do
      {:ok, %{status: 0, out: out}} -> {:ok, String.trim(out)}
      {:ok, %{out: out, err: err}} -> {:error, failed(args, out <> err, env)}
      {:error, reason} -> {:error, redact(reason, env)}
    end
  end

  defp redact(out, env) do
    case List.keyfind(env, "HAL_C2_GIT_TOKEN", 0) do
      {_, token} when is_binary(token) and token != "" -> String.replace(out, token, "[token]")
      _ -> out
    end
  end

  defp command(["-c", _ | args]), do: command(args)
  defp command([command | _]), do: command
end
