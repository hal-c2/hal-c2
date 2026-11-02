defmodule HalC2.PullRequests.Held do
  @moduledoc """
  Pull request previews read a moment ago (`pullRequests.preview`), and when a host's
  rate limit lets them be read again.

  A preview is held for 15 seconds, whether it was read on its own or cut from a full
  details read (`put_detail/4`); the newer of the two answers. Keys are
  `{host, repository, number, project_id}`, with host and repository lowercase.
  `forget/2,3` drops a pull request's or a repository's entries, `forget_all/0` every
  one. A read started before a forget must not put back what it read, so a reader
  takes a token first (`lookup/2`, `token/0`) and passes it to the put, which is
  dropped if anything was forgotten since.

  A host that answered "rate limit" is paused for 30 seconds, doubling with each limit
  hit in a row up to 15 minutes; held previews are still answered while it is. Times
  are milliseconds from the caller's clock.
  """

  use GenServer

  @ttl 15_000
  @cooldown 30_000
  @max_cooldown 900_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The preview held for `key` at `now`: `{:ok, preview}`, `{:paused, retry_at}` when
  none is held and its host is rate limited, or `{:miss, token}`.
  """
  def lookup(key, now), do: call({:lookup, key, now}, {:miss, nil})

  @doc "A token for a read about to start (see the moduledoc)."
  def token, do: call(:token, nil)

  @doc "Holds `preview`, read for `key` at `now`, unless forgotten since `token`."
  def put_preview(key, preview, now, token),
    do: call({:put, :previews, key, preview, now, token}, :ok)

  @doc "Holds the preview cut from a full details read of `key` at `now`."
  def put_detail(key, preview, now, token),
    do: call({:put, :details, key, preview, now, token}, :ok)

  @doc "Records that `host` answered with its rate limit at `now`; returns the retry time."
  def rate_limited(host, now), do: call({:rate_limited, host, now}, now + @cooldown)

  @doc "Drops what is held of pull request `number` of `repository` on `host`, or of all its pull requests."
  def forget(host, repository, number \\ nil),
    do: call({:forget, lower(host), lower(repository), number}, :ok)

  def forget_all, do: call(:forget_all, :ok)

  @doc "Whether anything is held, so a caller can skip working out what to forget."
  def holding?, do: call(:holding?, false)

  # Holding is only a saving: with the service down, nothing is held and every read
  # asks the host.
  defp call(message, down) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, message), else: down
  catch
    :exit, _ -> down
  end

  @impl true
  def init(nil), do: {:ok, %{previews: %{}, details: %{}, limits: %{}, epoch: 0}}

  @impl true
  def handle_call({:lookup, {host, _, _, _} = key, now}, _from, state) do
    held =
      [state.previews[key], state.details[key]]
      |> Enum.filter(fn entry -> entry && now - elem(entry, 0) <= @ttl end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    reply =
      case {held, state.limits[host]} do
        {{_at, preview}, _} -> {:ok, preview}
        {nil, %{until: until}} when until > now -> {:paused, until}
        _ -> {:miss, state.epoch}
      end

    {:reply, reply, prune(state, now)}
  end

  def handle_call(:token, _from, state), do: {:reply, state.epoch, state}

  def handle_call({:put, table, {host, _, _, _} = key, preview, now, token}, _from, state) do
    state =
      if token == state.epoch,
        do: Map.update!(state, table, &Map.put(&1, key, {now, preview})),
        else: state

    # An answer means the host is not limiting us; the next limit starts the backoff over.
    {:reply, :ok, update_in(state.limits, &Map.delete(&1, host))}
  end

  def handle_call({:rate_limited, host, now}, _from, state) do
    attempt = ((state.limits[host] || %{})[:attempt] || 0) + 1
    until = now + min(@cooldown * 2 ** (attempt - 1), @max_cooldown)
    {:reply, until, put_in(state.limits[host], %{attempt: attempt, until: until})}
  end

  def handle_call({:forget, host, repository, number}, _from, state) do
    keep = fn {{h, r, n, _}, _} -> not (h == host and r == repository and number in [nil, n]) end

    {:reply, :ok,
     %{
       state
       | previews: Map.filter(state.previews, keep),
         details: Map.filter(state.details, keep),
         epoch: state.epoch + 1
     }}
  end

  def handle_call(:forget_all, _from, state),
    do: {:reply, :ok, %{state | previews: %{}, details: %{}, epoch: state.epoch + 1}}

  def handle_call(:holding?, _from, state),
    do: {:reply, state.previews != %{} or state.details != %{}, state}

  defp lower(nil), do: ""
  defp lower(text), do: String.downcase(text)

  # Entries past their time are dropped on the next lookup, so the maps only hold what
  # was read in the last few seconds.
  defp prune(state, now) do
    fresh = fn {_, {at, _}} -> now - at <= @ttl end

    %{
      state
      | previews: Map.filter(state.previews, fresh),
        details: Map.filter(state.details, fresh)
    }
  end
end
