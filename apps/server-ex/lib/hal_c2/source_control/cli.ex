defmodule HalC2.SourceControl.Cli do
  @moduledoc """
  Runs a source control host's CLI (`glab`, `az`, `tea`, `fj`, ...): bounded in time
  and output, and a failure named for what the host said.
  `Application.get_env(:hal_c2, :"<exe>_command")` stands in for the CLI.
  """

  @timeout 30_000
  @max_bytes 8 * 1024 * 1024

  @typedoc """
  Why a run failed: the CLI is not installed, did not answer in time, answered with too
  much, or exited non-zero as one of the kinds `classify/2` names.
  """
  @type reason ::
          :missing
          | :timeout
          | :too_large
          | :unauthenticated
          | :rate_limited
          | :not_found
          | :failed

  @doc """
  Runs `exe args`: `{:ok, stdout, stderr}` when it exits 0, else
  `{:error, {reason, detail}}` with what the CLI said. Options: `:cd`, `:input`
  (stdin), `:env`, `:timeout` (ms, default 30 s) and `:max_bytes` (stdout, default 8 MB).
  """
  @spec run(String.t(), [String.t()], keyword) ::
          {:ok, binary, binary} | {:error, {reason, String.t()}}
  def run(exe, args, opts \\ []) do
    command = Application.get_env(:hal_c2, :"#{exe}_command", exe)

    case System.find_executable(command) do
      nil -> {:error, {:missing, "#{exe} is not installed"}}
      path -> spawn(exe, path, args, opts)
    end
  end

  defp spawn(exe, path, args, opts) do
    max = opts[:max_bytes] || @max_bytes

    exile =
      [stderr: :consume, ignore_epipe: true, env: opts[:env] || []] ++
        if(opts[:cd] && File.dir?(opts[:cd]), do: [cd: opts[:cd]], else: []) ++
        if(opts[:input], do: [input: [opts[:input]]], else: [])

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
      {:ok, {_, _, size, _}} when size > max ->
        {:error, {:too_large, "#{exe} produced more than #{max} bytes of output"}}

      {:ok, {out, err, _, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out), IO.iodata_to_binary(err)}

      {:ok, {out, err, _, _}} ->
        err = IO.iodata_to_binary(err)
        out = IO.iodata_to_binary(out)
        {:error, {classify(exe, err), first_line(err) || first_line(out) || "#{exe} failed"}}

      nil ->
        {:error, {:timeout, "#{exe} did not answer in time"}}
    end
  rescue
    error -> {:error, {:failed, Exception.message(error)}}
  end

  @doc """
  What a CLI's non-zero exit means, from what it printed on stderr.
  """
  def classify(exe, stderr) do
    said = String.downcase(stderr)

    cond do
      String.contains?(said, [
        "authentication failed",
        "not logged in",
        "gh auth login",
        "glab auth login",
        "az devops login",
        "please run az login",
        "no oauth token",
        "unauthorized"
      ]) ->
        :unauthenticated

      String.contains?(said, [
        "api rate limit",
        "rate limit exceeded",
        "secondary rate limit",
        "too many requests",
        "http 429"
      ]) ->
        :rate_limited

      not_found?(exe, said) ->
        :not_found

      true ->
        :failed
    end
  end

  defp not_found?("gh", said),
    do:
      String.contains?(said, [
        "could not resolve to a pullrequest",
        "repository.pullrequest",
        "no pull requests found for branch",
        "pull request not found"
      ])

  defp not_found?("glab", said), do: String.contains?(said, ["not found", "404"])

  defp not_found?("az", said),
    do:
      String.contains?(said, "pull request") and
        String.contains?(said, ["not found", "does not exist"])

  defp not_found?(_exe, _said), do: false

  @doc "The first non-blank line of `text`, trimmed, or nil."
  def first_line(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end
end
