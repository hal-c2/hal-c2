defmodule HalC2.GitHub do
  @moduledoc """
  The one way the MC runs `gh`. Pull requests, issues, the branch status, commit
  messages, repository lookups and plugins all call `gh/3`, so every call that reaches
  GitHub's API passes `HalC2.GitHub.Limits`: while the host's budget for it is spent,
  the call is refused without asking GitHub, and the first call to meet a limit asks
  GitHub when it resets (`gh api rate_limit`, which costs nothing). What the user asked
  for (`asked/1`) goes through a pause.

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
        gated(path, cwd, args, opts, opts[:host] || host(args), bucket)
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

  defp asked?, do: Enum.any?([self() | Process.get(:"$callers", [])], &asked?/1)

  defp asked?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, entries} -> List.keyfind(entries, @asked, 0) == {@asked, true}
      nil -> false
    end
  end

  defp gated(path, cwd, args, opts, _host, nil), do: run(path, cwd, args, opts)

  defp gated(path, cwd, args, opts, host, bucket) do
    case Limits.check(host, bucket, now()) do
      {:paused, until} ->
        {:error, {:rate_limited, paused(host, until)}}

      :ok ->
        case run(path, cwd, args, opts) do
          {:error, {:rate_limited, _}} ->
            {scope, reset} = budget(path, cwd, host, bucket)
            {:error, {:rate_limited, paused(host, Limits.limited(host, scope, now(), reset))}}

          {:ok, _} = ok ->
            Limits.answered(host, bucket, now())
            ok

          error ->
            error
        end
    end
  end

  defp paused(host, until) do
    resets = DateTime.from_unix!(until, :millisecond) |> Calendar.strftime("%H:%M:%S UTC")
    "#{host}'s API rate limit was reached; calls are paused until it resets at #{resets}."
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

  @doc "The host a `gh` call names (`--hostname`, `--repo host/owner/name`), else github.com."
  def host(args) do
    Enum.find_value(pairs(args), "github.com", fn
      {"--hostname", host} -> String.downcase(host)
      {flag, repo} when flag in ["--repo", "-R"] -> repo_host(repo)
      _ -> nil
    end)
  end

  defp pairs(args), do: Enum.zip(args, Enum.drop(args, 1))

  defp repo_host(repo) do
    case String.split(repo, "/") do
      [host, _, _] -> String.downcase(host)
      _ -> nil
    end
  end

  defp now, do: (Application.get_env(:hal_c2, :github_clock) || (&system_ms/0)).()
  defp system_ms, do: System.system_time(:millisecond)

  defp run(path, cwd, args, opts) do
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
      {:ok, {_, _, size, {:status, 0}}} when size > max ->
        {:error, {:too_large, "gh answered with more than #{max} bytes."}}

      {:ok, {out, _, _, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {out, err, _, _}} ->
        {:error, failure(IO.iodata_to_binary(err), IO.iodata_to_binary(out))}

      nil ->
        {:error, {:failed, "gh did not answer in time."}}
    end
  rescue
    error -> {:error, {:failed, Exception.message(error)}}
  end

  defp failure(err, out) do
    said = String.downcase(err <> "\n" <> out)

    detail =
      (api_error(err) || first_line(err) || first_line(out) || "gh failed.")
      |> String.replace_prefix("gh: ", "")

    cond do
      String.contains?(said, [
        "gh auth login",
        "not logged in",
        "authentication failed",
        "no oauth token",
        "bad credentials",
        "http 401"
      ]) ->
        {:unauthenticated, detail}

      String.contains?(said, [
        "api rate limit",
        "secondary rate limit",
        "rate limit exceeded",
        "http 429",
        "abuse detection"
      ]) ->
        {:rate_limited, detail}

      String.contains?(said, ["http 404", "could not resolve to a pullrequest", "not found"]) ->
        {:not_found, detail}

      true ->
        {:failed, detail}
    end
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
