defmodule HalC2.GitHub.Limits do
  @moduledoc """
  When each GitHub account's API budget may be spent again. `HalC2.GitHub.gh/3`
  checks here before every background call that reaches the API and reports what the
  host answered, so the first caller to meet a rate limit pauses every other caller
  of the same budget instead of each finding out for itself.

  An account is `{host, who}` (`HalC2.GitHub.account/1`): GitHub budgets each signed-in
  account apart, so a pause on one holds back no other, on the same host or another.
  GitHub budgets an account per bucket: `"core"` (REST), `"graphql"` and `"search"`. A
  bucket that ran out is paused until the reset GitHub gives for it. A limit with no
  known reset, and a secondary limit (scope `:all`: too many calls at once, which
  pauses every bucket of the account), are paused for 30 seconds, doubling with each
  limit in a row up to 15 minutes. A limit reported while its pause still holds (a
  call that was already in flight) does not lengthen it, and a reset never shortens
  it. An answer once a pause is over ends its backoff, and the account's secondary one.

  An answer can carry the bucket's quota, what GitHub said is left of it: while fewer
  than a tenth of it is left, background calls wait for its reset, leaving the rest
  to what the user asks for (which never checks here). Of answers that arrive out of
  order, the one with the later reset, or the least left, is believed.
  Hosts are compared in lowercase; times are milliseconds from the caller's clock.
  """

  use GenServer

  @cooldown 30_000
  @max_cooldown 900_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  `:ok`; `{:paused, until}` while `bucket` of `account`, or all of it, is paused at
  `now`; or `{:reserved, reset}` while only the tenth of its quota kept for what the
  user asks for holds it back.
  """
  def check(account, bucket, now), do: call({:check, key(account), bucket, now}, :ok)

  @doc """
  Records that `scope` of `account` (a bucket, or `:all`) was rate limited at `now`.
  `reset` is when GitHub says calls may resume, or nil. Returns when calls may resume.
  """
  def limited(account, scope, now, reset \\ nil),
    do: call({:limited, key(account), scope, now, reset}, now + @cooldown)

  @doc """
  Records that `bucket` of `account` answered at `now`, with its `quota` when GitHub
  gave it: `%{remaining: n, limit: n, reset: ms}`.
  """
  def answered(account, bucket, now, quota \\ nil),
    do: call({:answered, key(account), bucket, now, quota}, :ok)

  # The gate is only a saving: with it down, every call asks the host.
  defp call(message, down) do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, message), else: down
  catch
    :exit, _ -> down
  end

  @impl true
  def init(nil), do: {:ok, %{pauses: %{}, quotas: %{}}}

  @impl true
  def handle_call({:check, account, bucket, now}, _from, state) do
    reserve =
      case state.quotas[{account, bucket}] do
        %{reset: reset} = quota when reset > now and quota.remaining * 10 < quota.limit -> reset
        _ -> nil
      end

    paused =
      for pause <- [state.pauses[{account, bucket}], state.pauses[{account, :all}]],
          pause && pause.until > now,
          do: pause.until

    reply =
      cond do
        paused != [] -> {:paused, Enum.max([reserve || 0 | paused])}
        reserve -> {:reserved, reserve}
        true -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:limited, account, scope, now, reset}, _from, state) do
    entry = state.pauses[{account, scope}] || %{attempt: 0, until: 0}

    entry =
      cond do
        is_integer(reset) and reset > now -> %{entry | until: max(reset, entry.until)}
        entry.until > now -> entry
        true -> %{attempt: entry.attempt + 1, until: now + backoff(entry.attempt)}
      end

    {:reply, entry.until, put_in(state.pauses[{account, scope}], entry)}
  end

  def handle_call({:answered, account, bucket, now, quota}, _from, state) do
    pauses =
      Map.reject(state.pauses, fn {{a, scope}, entry} ->
        a == account and scope in [bucket, :all] and entry.until <= now
      end)

    quotas =
      if quota && quota.limit > 0 && believed?(quota, state.quotas[{account, bucket}]),
        do: Map.put(state.quotas, {account, bucket}, Map.take(quota, ~w(remaining limit reset)a)),
        else: state.quotas

    {:reply, :ok, %{state | pauses: pauses, quotas: quotas}}
  end

  defp believed?(_new, nil), do: true
  defp believed?(new, old), do: {new.reset, -new.remaining} >= {old.reset, -old.remaining}

  defp backoff(attempt), do: min(@cooldown * 2 ** attempt, @max_cooldown)

  defp key({host, who}), do: {String.downcase(host || ""), who}
end
