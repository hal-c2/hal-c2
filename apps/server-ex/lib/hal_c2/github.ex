defmodule HalC2.GitHub do
  @moduledoc """
  The one way the MC runs `gh`. Pull requests, issues, the branch status, commit
  messages, repository lookups and plugins all call `gh/3`, so every call that reaches
  GitHub's API passes `HalC2.GitHub.Limits`: while the budget it spends is used up for
  the account it is made as (`account/1`), the call is refused without asking GitHub.
  A `gh api` call shows GitHub's own numbers (`--include`): the `Retry-After` or reset
  of a limit it meets sets the pause, and the quota left after it answers keeps a
  tenth back for what the user asks for. A limit met without them (`gh pr`, `gh issue` and the rest show no headers) asks
  GitHub when it resets (`gh api rate_limit`, which costs nothing). What the user
  asked for (`asked/1`) goes through a pause.

  Failures are `{:error, {reason, detail}}` with `reason` one of `:missing`,
  `:unauthenticated`, `:rate_limited`, `:not_found` or `:failed`. The executable is
  `Application.get_env(:hal_c2, :gh_command, "gh")`, and `:github_clock` stands in for
  the system clock (milliseconds).
  """

  alias HalC2.GitHub.Limits

  @timeout 30_000
  @asked {__MODULE__, :asked}

  # `gh api` flags that take a value, so the endpoint is told from them.
  @api_value_flags ~w(--hostname -X --method --input -q --jq -f --raw-field -F --field -H --header -t --template --cache -p --preview)

  @doc """
  Runs `gh args` in `cwd`: `{:ok, stdout}` when it exits 0. Options: `:input` (stdin),
  `:timeout` (ms, default 30 s), `:max_bytes` (stdout, refused past it) and `:host`,
  for a call whose host its arguments do not name (`--hostname`, `--repo host/o/r`).
  """
  def gh(cwd, args, opts \\ []) do
    case System.find_executable(Application.get_env(:hal_c2, :gh_command, "gh")) do
      nil ->
        {:error, {:missing, "gh is not installed."}}

      path ->
        bucket = if asked?(), do: nil, else: bucket(args)
        host = bucket && (opts[:host] || named_host(args) || remote_host(cwd) || "github.com")
        gated(path, cwd, args, opts, host, bucket)
    end
  end

  @doc """
  Runs `fun` as something the user asked for (a merge, a comment, a new pull request):
  its `gh` calls, the reads it needs among them, go through a pause, and their answers
  neither end nor shorten it. Tasks `fun` starts are covered too.
  """
  def asked(fun) do
    previous = Process.put(@asked, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@asked, previous), else: Process.delete(@asked)
    end
  end

  @doc "Whether the calling process runs under `asked/1`, itself or through a task it started."
  def asked?, do: Enum.any?([self() | Process.get(:"$callers", [])], &asked?/1)

  defp asked?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, entries} -> List.keyfind(entries, @asked, 0) == {@asked, true}
      nil -> false
    end
  end

  defp gated(path, cwd, args, opts, _host, nil), do: run(path, cwd, args, opts)

  defp gated(path, cwd, args, opts, host, bucket) do
    account = account(host)

    case Limits.check(account, bucket, now()) do
      {:paused, until} ->
        {:error, {:rate_limited, paused(host, until)}}

      {:reserved, until} ->
        {:error, {:rate_limited, reserved(host, until)}}

      :ok ->
        case answer(path, cwd, args, opts) do
          {{:error, {:rate_limited, _}}, head} ->
            {scope, reset} = resume(head, bucket, now()) || budget(path, cwd, host, bucket)
            until = Limits.limited(account, scope, now(), reset)
            {:error, {:rate_limited, paused(host, until)}}

          {{:ok, _} = ok, head} ->
            Limits.answered(account, bucket, now(), quota(head, bucket))
            ok

          {error, _} ->
            error
        end
    end
  end

  defp paused(host, until),
    do: "#{host}'s API rate limit was reached; calls are paused until it resets at #{at(until)}."

  defp reserved(host, until),
    do:
      "#{host}'s API quota is nearly used up; background reads wait until it resets at " <>
        "#{at(until)}, keeping the rest for what you ask for."

  defp at(ms), do: DateTime.from_unix!(ms, :millisecond) |> Calendar.strftime("%H:%M:%S UTC")

  # What GitHub's own headers say of a limit: `{scope, when calls may resume}` from its
  # `Retry-After` (on the whole account unless the bucket is spent), else from the
  # reset of a spent bucket; nil when they say neither.
  defp resume(nil, _bucket, _now), do: nil

  defp resume(head, bucket, now) do
    spent? = head.headers["x-ratelimit-remaining"] == "0"
    scope = if spent?, do: bucket, else: :all
    reset = integer(head.headers["x-ratelimit-reset"])

    cond do
      at = retry_at(head.headers["retry-after"], now) -> {scope, at}
      spent? and is_integer(reset) and reset * 1_000 > now -> {scope, reset * 1_000}
      true -> nil
    end
  end

  # What is left of the bucket an answer spent, as `HalC2.GitHub.Limits` keeps it.
  defp quota(nil, _bucket), do: nil

  defp quota(%{headers: headers}, bucket) do
    with resource when resource in [nil, bucket] <- headers["x-ratelimit-resource"],
         remaining when is_integer(remaining) <- integer(headers["x-ratelimit-remaining"]),
         limit when is_integer(limit) <- integer(headers["x-ratelimit-limit"]),
         reset when is_integer(reset) <- integer(headers["x-ratelimit-reset"]) do
      %{remaining: remaining, limit: limit, reset: reset * 1_000}
    else
      _ -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # `Retry-After` is seconds, or an HTTP date.
  defp retry_at(nil, _now), do: nil

  defp retry_at(value, now) do
    with nil <- integer(value),
         [_, day, month, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d\d:\d\d:\d\d) GMT$/, value),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         month = String.pad_leading("#{index + 1}", 2, "0"),
         {:ok, at, _} <- DateTime.from_iso8601("#{year}-#{month}-#{day}T#{time}Z") do
      DateTime.to_unix(at, :millisecond)
    else
      seconds when is_integer(seconds) -> now + seconds * 1_000
      _ -> nil
    end
  end

  defp integer(nil), do: nil

  defp integer(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # Which budget ran out: the bucket, until its reset, when it has nothing left;
  # otherwise a secondary limit, on the whole host.
  defp budget(path, cwd, host, bucket) do
    case run(path, cwd, ["api", "rate_limit", "--hostname", host], timeout: 10_000) do
      {:ok, out} ->
        case JSON.decode(out) do
          {:ok, %{"resources" => %{^bucket => %{"remaining" => 0, "reset" => reset}}}}
          when is_integer(reset) ->
            {bucket, reset * 1_000}

          {:ok, %{"resources" => %{^bucket => %{"remaining" => left}}}}
          when is_integer(left) and left > 0 ->
            {:all, nil}

          _ ->
            {bucket, nil}
        end

      _ ->
        {bucket, nil}
    end
  end

  @doc """
  The budget a `gh` call spends: `"core"`, `"graphql"` or `"search"`, or nil for one
  that never reaches the API's budget (`auth`, `config`, `api rate_limit`).
  """
  def bucket(["auth" | _]), do: nil
  def bucket(["config" | _]), do: nil

  def bucket(["api" | rest]) do
    case endpoint(rest) do
      "rate_limit" -> nil
      "graphql" -> "graphql"
      "search/" <> _ -> "search"
      _ -> "core"
    end
  end

  def bucket([command | _]) when command in ~w(run workflow release), do: "core"
  # `gh pr`, `gh issue`, `gh repo` and the rest ask GraphQL.
  def bucket(_), do: "graphql"

  defp endpoint([flag, _ | rest]) when flag in @api_value_flags, do: endpoint(rest)
  defp endpoint(["-" <> _ | rest]), do: endpoint(rest)
  defp endpoint([endpoint | _]), do: String.trim_leading(endpoint, "/")
  defp endpoint([]), do: nil

  @doc """
  The host a `gh` call names (`--hostname`, `--repo [host/]owner/name`, `repo view`'s
  repository), else github.com.
  """
  def host(args), do: named_host(args) || "github.com"

  # `gh repo view [host/]owner/name` names its repository without a flag.
  defp named_host(["repo", "view", "-" <> _ | _] = args), do: flagged_host(args)

  defp named_host(["repo", "view", repo | _] = args),
    do: repo_host(repo) || flagged_host(args)

  defp named_host(args), do: flagged_host(args)

  defp flagged_host(args) do
    Enum.find_value(pairs(args), fn
      {"--hostname", host} -> String.downcase(host)
      {flag, repo} when flag in ["--repo", "-R"] -> repo_host(repo)
      _ -> nil
    end)
  end

  @doc """
  The account `gh` calls `host` as, `{host, who}`, read without running gh so it costs
  nothing per call: who is a digest of the token the MC's environment gives gh for the
  host (`GH_TOKEN` or `GITHUB_TOKEN`; off github.com, `GH_ENTERPRISE_TOKEN` or
  `GITHUB_ENTERPRISE_TOKEN`), else the user gh's hosts file has active on it, which
  `gh auth login` and `gh auth switch` change, else "".
  """
  def account(host) do
    host = String.downcase(host)

    who =
      case Enum.find_value(token_env(host), &System.get_env/1) do
        token when is_binary(token) and token != "" ->
          "token:" <> (:crypto.hash(:sha256, token) |> binary_part(0, 12) |> Base.encode16())

        _ ->
          hosts_user(host) || ""
      end

    {host, who}
  end

  # As gh reads them: github.com and its data-residency tenancies (`*.ghe.com`) take
  # the plain tokens, a GitHub Enterprise Server the enterprise ones.
  defp token_env(host) do
    if host in ["github.com", "github.localhost"] or String.ends_with?(host, ".ghe.com"),
      do: ~w(GH_TOKEN GITHUB_TOKEN),
      else: ~w(GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN)
  end

  @doc "gh's configuration directory, where its `hosts.yml` names who is signed in."
  def config_dir do
    System.get_env("GH_CONFIG_DIR") ||
      Path.join(System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"), "gh")
  end

  # The `user:` directly under the host's entry of `hosts.yml`, not one of its `users:`.
  defp hosts_user(host) do
    with {:ok, text} <- File.read(Path.join(config_dir(), "hosts.yml")),
         [_ | _] = entry <- host_entry(String.split(text, ~r/\r?\n/), host),
         [indent | _] <- Regex.run(~r/^\s+/, hd(entry)) do
      Enum.find_value(entry, fn line ->
        with true <- String.starts_with?(line, indent <> "user:"),
             [_, user] <- Regex.run(~r/^\s*user:\s*["']?([^"'\s]+)/, line),
             do: "user:" <> user,
             else: (_ -> nil)
      end)
    else
      _ -> nil
    end
  end

  # A call that names no host asks the one gh picks from `cwd`'s remotes: `upstream`,
  # then `github`, then `origin`, then any.
  defp remote_host(cwd) when is_binary(cwd) do
    with true <- File.dir?(cwd),
         {:ok, out} <- HalC2.Git.ok(cwd, ~w(remote -v)),
         remotes =
           for(
             [name, url | _] <- Enum.map(String.split(out, "\n"), &String.split/1),
             do: {name, url}
           ),
         {_, url} <-
           Enum.find_value(~w(upstream github origin), &List.keyfind(remotes, &1, 0)) ||
             List.first(remotes),
         %{host: host} <- HalC2.PullRequests.parse_remote(url) do
      host
    else
      _ -> nil
    end
  end

  defp remote_host(_), do: nil

  defp host_entry(lines, host) do
    lines
    |> Enum.drop_while(&(String.downcase(String.trim_trailing(&1)) != host <> ":"))
    |> Enum.drop(1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take_while(&String.match?(&1, ~r/^\s/))
  end

  defp pairs(args), do: Enum.zip(args, Enum.drop(args, 1))

  defp repo_host(repo) do
    case String.split(repo, "/") do
      [host, _, _] -> String.downcase(host)
      # `owner/name` alone is github.com's (or GH_HOST's), whatever the checkout's remote.
      [_, _] -> System.get_env("GH_HOST", "github.com") |> String.downcase()
      _ -> nil
    end
  end

  defp now, do: (Application.get_env(:hal_c2, :github_clock) || (&system_ms/0)).()
  defp system_ms, do: System.system_time(:millisecond)

  defp run(path, cwd, args, opts) do
    {result, _head} = answer(path, cwd, args, opts)
    result
  end

  # `{result, head}`. A `gh api` call is made with `--include`, so GitHub's status and
  # headers (its rate limit numbers among them) come ahead of the body; head is them,
  # `%{status: 403, headers: %{"lowercase name" => value}}`, and the result has only
  # the body. `gh pr`, `gh issue` and the rest show no headers: their head is nil.
  defp answer(path, cwd, args, opts) do
    include? = include?(args)
    args = if include?, do: args ++ ["--include"], else: args

    exile =
      [stderr: :consume, ignore_epipe: true, env: [{"GH_PROMPT_DISABLED", "1"}]] ++
        if(cwd && File.dir?(cwd), do: [cd: cwd], else: []) ++
        if(opts[:input], do: [input: [opts[:input]]], else: [])

    max = opts[:max_bytes] || :infinity

    # Output past `:max_bytes` is dropped rather than held, and the answer refused.
    task =
      Task.async(fn ->
        [path | args]
        |> Exile.stream(exile)
        |> Enum.reduce({[], [], 0, nil}, fn
          {:stdout, data}, {out, err, size, status} when size < max ->
            {[out, data], err, size + byte_size(data), status}

          {:stdout, data}, {out, err, size, status} ->
            {out, err, size + byte_size(data), status}

          {:stderr, data}, {out, err, size, status} ->
            {out, [err, data], size, status}

          {:exit, status}, {out, err, size, _} ->
            {out, err, size, status}
        end)
      end)

    case Task.yield(task, opts[:timeout] || @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, err, size, status}} ->
        {head, out} = if include?, do: head(IO.iodata_to_binary(out)), else: {nil, out}

        result =
          case status do
            {:status, 0} when size > max ->
              {:error, {:too_large, "gh answered with more than #{max} bytes."}}

            {:status, 0} ->
              {:ok, IO.iodata_to_binary(out)}

            _ ->
              {:error, failure(IO.iodata_to_binary(err), IO.iodata_to_binary(out), head)}
          end

        {result, head}

      nil ->
        {{:error, {:failed, "gh did not answer in time."}}, nil}
    end
  rescue
    error -> {{:error, {:failed, Exception.message(error)}}, nil}
  end

  # `--paginate` would print a head per page, and `--silent` none.
  defp include?(["api" | rest]),
    do: not Enum.any?(rest, &(&1 in ~w(--include -i --paginate --silent)))

  defp include?(_args), do: false

  defp head("HTTP/" <> _ = out) do
    [head, body] =
      case String.split(out, ~r/\r?\n\r?\n/, parts: 2) do
        [head, body] -> [head, body]
        [head] -> [head, ""]
      end

    [status | lines] = String.split(head, ~r/\r?\n/)

    headers =
      for line <- lines,
          [name, value] <- [String.split(line, ":", parts: 2)],
          into: %{},
          do: {String.downcase(String.trim(name)), String.trim(value)}

    status =
      case String.split(status, " ") do
        [_, code | _] -> integer(code)
        _ -> nil
      end

    {%{status: status, headers: headers}, body}
  end

  defp head(out), do: {nil, out}

  # gh's own messages, auth trouble, a rate limit or a missing object, are matched only on
  # stderr: a GraphQL answer with `errors` still prints its body, user-written titles
  # and comments included, on stdout.
  defp failure(err, out, head) do
    told = String.downcase(err)

    detail =
      (api_error(err) || first_line(err) || first_line(out) || "gh failed.")
      |> String.replace_prefix("gh: ", "")

    cond do
      String.contains?(told, [
        "gh auth login",
        "not logged in",
        "authentication failed",
        "no oauth token",
        "bad credentials",
        "http 401"
      ]) ->
        {:unauthenticated, detail}

      limited?(told, head) ->
        {:rate_limited, detail}

      String.contains?(told, ["http 404", "could not resolve to a pullrequest", "not found"]) ->
        {:not_found, detail}

      true ->
        {:failed, detail}
    end
  end

  # A 403 is a limit only when GitHub says so: in its text, or by a `Retry-After` or no
  # quota left. Without them it is a plain refusal, which pauses nothing.
  defp limited?(told, head) do
    String.contains?(told, [
      "api rate limit",
      "secondary rate limit",
      "rate limit exceeded",
      "http 429",
      "abuse detection"
    ]) or
      match?(%{status: 429}, head) or
      (match?(%{status: 403}, head) and
         (head.headers["x-ratelimit-remaining"] == "0" or
            Map.has_key?(head.headers, "retry-after")))
  end

  # `gh api` puts GitHub's message and each of its `errors` on a line of their own,
  # the last ending in `(HTTP 422)`; the reason is usually in the later lines.
  defp api_error(err) do
    lines = err |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case Enum.split_while(lines, &(not (&1 =~ ~r/\(HTTP \d{3}\)$/))) do
      {["gh: " <> _ | _] = before, [last | _]} -> Enum.join(before ++ [last], ": ")
      _ -> nil
    end
  end

  defp first_line(text) do
    text |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))
  end
end
