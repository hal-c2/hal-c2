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
  """

  use GenServer

  @cooldown 30_000
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

  defp backoff(attempt), do: min(@cooldown * 2 ** attempt, @max_cooldown)

  defp lower(nil), do: ""
  defp lower(text), do: String.downcase(text)
end
