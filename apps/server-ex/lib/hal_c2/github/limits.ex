defmodule HalC2.GitHub.Limits do
  @moduledoc """
  When each GitHub host's API may be asked again. `HalC2.GitHub.gh/3` checks here
  before every call that reaches the API and reports what the host answered, so the
  first caller to meet a rate limit pauses every other caller of the same budget
  instead of each finding out for itself.

  GitHub budgets a token per bucket: `"core"` (REST), `"graphql"` and `"search"`. A
  bucket that ran out is paused until the reset GitHub gives for it. A limit with no
  known reset, and a secondary limit (scope `:all`: too many calls at once, which
  pauses every bucket of the host), are paused for 30 seconds, doubling with each
  limit in a row up to 15 minutes. A limit reported while its pause still holds (a
  call that was already in flight) does not lengthen it, and a reset never shortens
  it. An answer once a pause is over ends its backoff, and the host's secondary one.
  Hosts are lowercase; times are milliseconds from the caller's clock.

  A repository GitHub keeps giving up on (a gateway's 502 or 504, an answer cut off)
  is held back from background reads the same way, keyed by host and repository: 30
  seconds after its first failure, doubling up to 15 minutes, a failure while it is
  held back changing nothing. `release/2` lets the next read through without ending
  the doubling (a hand refresh); the first read that succeeds ends it. Each repository
  also keeps the page size its last read shrank to, so the reads that follow start
  there rather than at a size GitHub already gave up on; 15 minutes after it shrank,
  a read tries the usual size again.
  """

  use GenServer

  @cooldown 30_000
  @page_memory 900_000
  @max_cooldown 900_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`:ok`, or `{:paused, until}` while `bucket` of `host`, or all of it, is paused at `now`."
  def check(host, bucket, now), do: call({:check, lower(host), bucket, now}, :ok)

  @doc """
  Records that `scope` of `host` (a bucket, or `:all`) was rate limited at `now`.
  `reset` is when GitHub says the bucket resets, or nil. Returns when calls may resume.
  """
  def limited(host, scope, now, reset \\ nil),
    do: call({:limited, lower(host), scope, now, reset}, now + @cooldown)

  @doc "Records that `bucket` of `host` answered at `now`."
  def answered(host, bucket, now), do: call({:answered, lower(host), bucket, now}, :ok)

  @doc """
  How `repository` of `host` may be read at `now`: `{:ok, page}`, with the page size
  that last got through or nil, or `{:held, until, page, detail}` while it is held
  back after failing with `detail`.
  """
  def repository(host, repository, now),
    do: call({:repository, lower(host), lower(repository), now}, {:ok, nil})

  @doc """
  Records that GitHub gave up on reading `repository` at `now` with `detail`. Returns
  `{until, new?}`: when it may be read again, and whether this failure set that time
  (rather than meeting a hold that was already there); nil while the gate is down,
  which holds nothing back.
  """
  def repository_failed(host, repository, now, detail),
    do: call({:repository_failed, lower(host), lower(repository), now, detail}, nil)

  @doc """
  Records that `repository` was read at `now` with pages of `page` (nil: the usual
  size). A page that differs from the one kept restarts its 15 minutes.
  """
  def repository_read(host, repository, page, now),
    do: call({:repository_read, lower(host), lower(repository), page, now}, :ok)

  @doc """
  Lets the next read of `repository` of `host` through its hold; nil for every
  repository (of every host).
  """
  def release(host \\ nil, repository \\ nil),
    do: call({:release, host && lower(host), repository && lower(repository)}, :ok)

  # The gate is only a saving: with it down, every call asks the host.
  defp call(message, down) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, message), else: down
  catch
    :exit, _ -> down
  end

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:check, host, bucket, now}, _from, pauses) do
    until =
      [pauses[{host, bucket}], pauses[{host, :all}]]
      |> Enum.filter(&(&1 && &1.until > now))
      |> Enum.map(& &1.until)
      |> Enum.max(fn -> nil end)

    {:reply, if(until, do: {:paused, until}, else: :ok), pauses}
  end

  def handle_call({:limited, host, scope, now, reset}, _from, pauses) do
    entry = pauses[{host, scope}] || %{attempt: 0, until: 0}

    entry =
      cond do
        is_integer(reset) and reset > now -> %{entry | until: max(reset, entry.until)}
        entry.until > now -> entry
        true -> %{attempt: entry.attempt + 1, until: now + backoff(entry.attempt)}
      end

    {:reply, entry.until, Map.put(pauses, {host, scope}, entry)}
  end

  def handle_call({:answered, host, bucket, now}, _from, pauses) do
    {:reply, :ok,
     Map.reject(pauses, fn {{h, scope}, entry} ->
       h == host and scope in [bucket, :all] and entry.until <= now
     end)}
  end

  def handle_call({:repository, host, repository, now}, _from, pauses) do
    reply =
      case pauses[{host, {:repository, repository}}] do
        %{until: until} = entry when until > now ->
          {:held, until, page(entry, now), entry.detail}

        %{} = entry ->
          {:ok, page(entry, now)}

        nil ->
          {:ok, nil}
      end

    {:reply, reply, pauses}
  end

  def handle_call({:repository_failed, host, repository, now, detail}, _from, pauses) do
    key = {host, {:repository, repository}}
    entry = pauses[key] || %{attempt: 0, until: 0, page: nil, page_at: 0, detail: nil}

    {entry, new?} =
      if entry.until > now,
        do: {entry, false},
        else:
          {%{
             entry
             | attempt: entry.attempt + 1,
               until: now + backoff(entry.attempt),
               detail: detail
           }, true}

    {:reply, {entry.until, new?}, Map.put(pauses, key, entry)}
  end

  def handle_call({:repository_read, host, repository, page, now}, _from, pauses) do
    key = {host, {:repository, repository}}

    page_at =
      case pauses[key] do
        %{page: ^page, page_at: at} -> at
        _ -> now
      end

    pauses =
      if page,
        do:
          Map.put(pauses, key, %{attempt: 0, until: 0, page: page, page_at: page_at, detail: nil}),
        else: Map.delete(pauses, key)

    {:reply, :ok, pauses}
  end

  def handle_call({:release, host, repository}, _from, pauses) do
    {:reply, :ok,
     Map.new(pauses, fn
       {{h, {:repository, r}} = key, entry}
       when host in [nil, h] and repository in [nil, r] ->
         {key, %{entry | until: 0}}

       other ->
         other
     end)}
  end

  defp page(%{page: page, page_at: at}, now) when page != nil and at + @page_memory > now,
    do: page

  defp page(_entry, _now), do: nil

  defp backoff(attempt), do: min(@cooldown * 2 ** attempt, @max_cooldown)

  defp lower(nil), do: ""
  defp lower(text), do: String.downcase(text)
end
