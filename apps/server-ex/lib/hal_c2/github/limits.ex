defmodule HalC2.GitHub.Limits do
  @moduledoc """
  When each GitHub account's API budget may be spent again. `HalC2.GitHub.gh/3`
  checks here before every call that reaches the API and reports what the host
  answered, so the first caller to meet a rate limit pauses every other caller of the
  same budget instead of each finding out for itself.

  An account is `{host, who}` (`HalC2.GitHub.account/1`): GitHub budgets each signed-in
  account apart, so a pause on one holds back no other, on the same host or another.
  GitHub budgets an account per bucket: `"core"` (REST), `"graphql"` and `"search"`. A
  bucket that ran out is paused until the reset GitHub gives for it. A limit with no
  known reset, and a secondary limit (scope `:all`: too many calls at once, which
  pauses every bucket of the account), are paused for 30 seconds, doubling with each
  limit in a row up to 15 minutes. A limit reported while its pause still holds (a
  call that was already in flight) does not lengthen it, and a reset never shortens
  it. An answer once a pause is over ends its backoff, and the account's secondary one.
  Hosts are compared in lowercase; times are milliseconds from the caller's clock.
  """

  use GenServer

  @cooldown 30_000
  @max_cooldown 900_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`:ok`, or `{:paused, until}` while `bucket` of `account`, or all of it, is paused at `now`."
  def check(account, bucket, now), do: call({:check, key(account), bucket, now}, :ok)

  @doc """
  Records that `scope` of `account` (a bucket, or `:all`) was rate limited at `now`.
  `reset` is when GitHub says the bucket resets, or nil. Returns when calls may resume.
  """
  def limited(account, scope, now, reset \\ nil),
    do: call({:limited, key(account), scope, now, reset}, now + @cooldown)

  @doc "Records that `bucket` of `account` answered at `now`."
  def answered(account, bucket, now), do: call({:answered, key(account), bucket, now}, :ok)

  # The gate is only a saving: with it down, every call asks the host.
  defp call(message, down) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, message), else: down
  catch
    :exit, _ -> down
  end

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:check, account, bucket, now}, _from, pauses) do
    until =
      [pauses[{account, bucket}], pauses[{account, :all}]]
      |> Enum.filter(&(&1 && &1.until > now))
      |> Enum.map(& &1.until)
      |> Enum.max(fn -> nil end)

    {:reply, if(until, do: {:paused, until}, else: :ok), pauses}
  end

  def handle_call({:limited, account, scope, now, reset}, _from, pauses) do
    entry = pauses[{account, scope}] || %{attempt: 0, until: 0}

    entry =
      cond do
        is_integer(reset) and reset > now -> %{entry | until: max(reset, entry.until)}
        entry.until > now -> entry
        true -> %{attempt: entry.attempt + 1, until: now + backoff(entry.attempt)}
      end

    {:reply, entry.until, Map.put(pauses, {account, scope}, entry)}
  end

  def handle_call({:answered, account, bucket, now}, _from, pauses) do
    {:reply, :ok,
     Map.reject(pauses, fn {{a, scope}, entry} ->
       a == account and scope in [bucket, :all] and entry.until <= now
     end)}
  end

  defp backoff(attempt), do: min(@cooldown * 2 ** attempt, @max_cooldown)

  defp key({host, who}), do: {String.downcase(host || ""), who}
end
