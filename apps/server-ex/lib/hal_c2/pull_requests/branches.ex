defmodule HalC2.PullRequests.Branches do
  @moduledoc """
  The one answer to "which pull request is this branch's?" on GitHub
  (`HalC2.PullRequests.GitHub.branch_pull_request/2`), for every reader that asks it: a
  checkout's branch status (`HalC2.Vcs`), thread pull request discovery
  (`HalC2.PullRequests.Discovery`) and storage cleanup. Keys are `{cwd, branch}`.

  An answer is believed for a minute while its pull request is open and five otherwise.
  A failure is answered again until its wait passes: 20 seconds, doubling with each
  failure in a row up to 15 minutes, and kept past its wait for a long quiet so the
  next one waits longer. `fresh: true` asks past a believed answer, not past a failure's
  wait. Readers asking for the same branch while it is being read get that read's
  answer rather than asking again.

  A change made through the MC forgets what is held (`forget/0,1`, or of one pull
  request with `forget_pull_request/3`), and a read that was under way then answers its
  callers but is not kept. A call made for something the
  user asked (`HalC2.GitHub.asked/1`) is never held nor shared. With the service down,
  every read asks the host. Times come from `:github_clock` (milliseconds), as in
  `HalC2.GitHub`.
  """

  use GenServer

  alias HalC2.PullRequests.GitHub

  @open_ttl 60_000
  @quiet_ttl 5 * 60_000
  @failure_ttl 20_000
  @failure_max_ttl 15 * 60_000

  @doc "Options: `fetch`, `(cwd, branch) -> {:ok, pull request | nil} | {:error, reason}`."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The branch's pull request: `{:ok, pull request | nil}` or `{:error, reason}`, as
  `HalC2.PullRequests.GitHub.branch_pull_request/2` gives it. Option `fresh: true`.
  """
  def pull_request(cwd, branch, opts \\ []), do: cwd |> lookup(branch, opts) |> elem(0)

  @doc """
  As `pull_request/3`, with whether the answer was read for this call (or a read under
  way it joined) rather than held: `{answer, read?}`.
  """
  def lookup(cwd, branch, opts \\ []) do
    if GenServer.whereis(__MODULE__) && not HalC2.GitHub.asked?() do
      GenServer.call(__MODULE__, {:lookup, {cwd, branch}, opts[:fresh] == true}, :infinity)
    else
      {GitHub.branch_pull_request(cwd, branch), true}
    end
  end

  @doc "Forgets what is held of the branches of checkout `cwd`, or of every one."
  def forget(cwd \\ nil) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:forget, cwd})
    :ok
  end

  @doc """
  Forgets the branches held as having pull request `number` of `repository` on `host`,
  and drops every read under way, whose answer could be that pull request.
  """
  def forget_pull_request(host, repository, number) do
    if GenServer.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:forget_pull_request, host, repository, number})

    :ok
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       fetch: Keyword.get(opts, :fetch, &GitHub.branch_pull_request/2),
       entries: %{},
       reading: %{},
       readers: %{}
     }}
  end

  @impl true
  def handle_call({:lookup, key, fresh?}, from, state) do
    now = now()
    entry = state.entries[key]

    cond do
      entry && entry.expires > now && (match?({:error, _}, entry.answer) or not fresh?) ->
        {:reply, {entry.answer, false}, state}

      ref = state.reading[key] ->
        {:noreply, update_in(state.readers[ref], &[from | &1])}

      true ->
        {cwd, branch} = key
        fetch = state.fetch
        %Task{ref: ref} = Task.async(fn -> safely(fetch, cwd, branch) end)

        {:noreply,
         %{
           state
           | reading: Map.put(state.reading, key, ref),
             readers: Map.put(state.readers, ref, [from])
         }}
    end
  end

  def handle_call({:forget, cwd}, _from, state) do
    keep = fn {{key_cwd, _}, _} -> cwd != nil and key_cwd != cwd end

    {:reply, :ok,
     %{
       state
       | entries: state.entries |> Enum.filter(keep) |> Map.new(),
         reading: state.reading |> Enum.filter(keep) |> Map.new()
     }}
  end

  # Matched on the URL's path alone: a remote's host (`ssh.github.com`) need not be the
  # one in gh's URL, and a held answer from another host's same path is only forgotten
  # too soon.
  def handle_call({:forget_pull_request, _host, repository, number}, _from, state) do
    path = String.downcase("/#{repository}/pull/#{number}")

    held? = fn
      {_, %{answer: {:ok, %{"url" => url}}}} when is_binary(url) ->
        String.downcase(URI.parse(url).path || "") == path

      _ ->
        false
    end

    {:reply, :ok, %{state | entries: Map.reject(state.entries, held?), reading: %{}}}
  end

  @impl true
  def handle_info({ref, answer}, %{readers: readers} = state) when is_map_key(readers, ref) do
    Process.demonitor(ref, [:flush])
    now = now()
    {readers, state} = pop_in(state.readers[ref])
    Enum.each(readers, &GenServer.reply(&1, {answer, true}))

    case Enum.find(state.reading, fn {_, reading} -> reading == ref end) do
      {key, _} ->
        entries = prune(state.entries, now)

        {:noreply,
         %{
           state
           | reading: Map.delete(state.reading, key),
             entries: Map.put(entries, key, entry(answer, entries[key], now))
         }}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp safely(fetch, cwd, branch) do
    fetch.(cwd, branch)
  catch
    kind, reason -> {:error, {:failed, Exception.format_banner(kind, reason)}}
  end

  defp entry({:ok, found}, _before, now) do
    ttl = if match?(%{"state" => "open"}, found), do: @open_ttl, else: @quiet_ttl
    %{answer: {:ok, found}, failures: 0, expires: now + ttl}
  end

  defp entry(error, before, now) do
    failures = ((before || %{})[:failures] || 0) + 1
    ttl = min(@failure_ttl * Integer.pow(2, failures - 1), @failure_max_ttl)
    %{answer: error, failures: failures, expires: now + ttl}
  end

  # A failure is kept past its wait, so the next one waits longer, until a long quiet.
  defp prune(entries, now) do
    Map.reject(entries, fn {_, e} ->
      e.expires + if(match?({:error, _}, e.answer), do: @failure_max_ttl, else: 0) <= now
    end)
  end

  defp now, do: (Application.get_env(:hal_c2, :github_clock) || (&system_ms/0)).()
  defp system_ms, do: System.system_time(:millisecond)
end
