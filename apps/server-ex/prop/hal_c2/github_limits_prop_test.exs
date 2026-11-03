defmodule HalC2.GitHubLimitsPropTest do
  @moduledoc """
  A state machine over `HalC2.GitHub.Limits`: two accounts on each of two hosts (one
  host spelled two ways), their buckets limited with and without a reset GitHub gave,
  secondary limits on the whole account, answers with and without the quota GitHub
  says is left, and time passing, with checks between any of them. The model checks
  what `HalC2.GitHub.gh/3` is promised:

  - a check is paused exactly while its bucket's pause or its account's secondary pause
    holds, until the later of the two, and a pause on one account or bucket holds back
    no other, another account on the same host included;
  - a limit with a reset still ahead pauses until that reset, and never shortens a
    longer pause;
  - a limit with no reset pauses for 30 seconds, doubling with each limit in a row up
    to 15 minutes, and one reported while its pause holds changes nothing;
  - an answer ends the backoff of its bucket and of its account's secondary pause once
    they are over, and ends no pause that still holds;
  - while the last quota believed for a bucket has fewer than a tenth left, before its
    reset, the bucket is held back until that reset, as reserved when no pause holds it; of quotas that arrive out of order,
    the one with the later reset, then the least left, is believed.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.GitHub.Limits

  @moduletag timeout: :infinity

  @hosts ["github.com", "GitHub.com", "ghe.test"]
  @who ["user:monalisa", "user:hubot"]
  @buckets ["core", "graphql", "search"]

  property "GitHub is left alone while its budget is spent",
    numtests: HalC2.Prop.numtests(300),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.start_services([Limits])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # pauses: `%{{{lowercase host, who}, bucket | :all} => {attempt, until}}`;
  # quotas: `%{{{lowercase host, who}, bucket} => %{remaining, limit, reset}}`.
  def initial_state, do: %{now: 0, pauses: %{}, quotas: %{}}

  def command(state) do
    frequency(
      again(state) ++
        [
          {4, {:call, __MODULE__, :check, [account(), bucket(), state.now]}},
          {3, {:call, __MODULE__, :limited, [account(), scope(), state.now, reset(state.now)]}},
          {2, {:call, __MODULE__, :answered, [account(), bucket(), state.now, quota(state.now)]}},
          {2, {:call, __MODULE__, :pass, [oneof([1_000, 29_000, 30_000, 60_000, 900_000])]}}
        ]
    )
  end

  defp account, do: {oneof(@hosts), oneof(@who)}
  defp bucket, do: oneof(@buckets)
  defp scope, do: oneof([:all | @buckets])

  defp quota(now) do
    oneof([
      nil,
      let [remaining, reset] <- [
            oneof([0, 499, 500, 4_000]),
            oneof([now - 1_000, now + 10_000, now + 600_000])
          ] do
        %{remaining: remaining, limit: 5_000, reset: reset}
      end
    ])
  end

  # A limit met again as soon as a pause ends, so limits in a row reach the cap.
  defp again(%{pauses: pauses}) when pauses == %{}, do: []

  defp again(state) do
    [
      {4,
       let {{account, scope}, {_, until}} <- oneof(Map.to_list(state.pauses)) do
         {:call, __MODULE__, :limited_after, [account, scope, max(until, state.now)]}
       end}
    ]
  end

  defp reset(now), do: oneof([nil, nil, now - 1_000, now + 10_000, now + 600_000])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :limited, [account, scope, now, reset]}) do
    key = {lower(account), scope}
    {attempt, until} = state.pauses[key] || {0, 0}

    entry =
      cond do
        is_integer(reset) and reset > now -> {attempt, max(reset, until)}
        until > now -> {attempt, until}
        true -> {attempt + 1, now + min(30_000 * 2 ** attempt, 900_000)}
      end

    put_in(state.pauses[key], entry)
  end

  def next_state(state, result, {:call, m, :limited_after, [account, scope, at]}),
    do: next_state(%{state | now: at}, result, {:call, m, :limited, [account, scope, at, nil]})

  def next_state(state, _result, {:call, _, :answered, [account, bucket, now, quota]}) do
    account = lower(account)
    old = state.quotas[{account, bucket}]

    state =
      if quota && (old == nil or {quota.reset, -quota.remaining} >= {old.reset, -old.remaining}),
        do: put_in(state.quotas[{account, bucket}], quota),
        else: state

    pauses =
      Map.reject(state.pauses, fn {{a, scope}, {_, until}} ->
        a == account and scope in [bucket, :all] and until <= now
      end)

    %{state | pauses: pauses}
  end

  def next_state(state, _result, {:call, _, :pass, [ms]}), do: %{state | now: state.now + ms}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :check, [account, bucket, now]}, result) do
    account = lower(account)

    paused =
      for scope <- [bucket, :all],
          {_, until} <- [state.pauses[{account, scope}]],
          until > now,
          do: until

    reserve =
      case state.quotas[{account, bucket}] do
        %{remaining: left, limit: limit, reset: reset} when reset > now and left * 10 < limit ->
          [reset]

        _ ->
          []
      end

    case {paused, reserve} do
      {[], []} -> result == :ok
      {[], [reset]} -> result == {:reserved, reset}
      _ -> result == {:paused, Enum.max(paused ++ reserve)}
    end
  end

  def postcondition(state, {:call, _, :limited, [account, scope, now, _]} = call, until) do
    {_, before} = state.pauses[{lower(account), scope}] || {0, 0}
    {_, expected} = next_state(state, nil, call).pauses[{lower(account), scope}]
    until == expected and until > now and until >= before
  end

  def postcondition(state, {:call, m, :limited_after, [account, scope, at]}, until),
    do: postcondition(%{state | now: at}, {:call, m, :limited, [account, scope, at, nil]}, until)

  def postcondition(_state, {:call, _, :answered, _}, result), do: result == :ok
  def postcondition(_state, _call, _result), do: true

  defp lower({host, who}), do: {String.downcase(host), who}

  # --- commands -------------------------------------------------------------------

  def check(account, bucket, now), do: Limits.check(account, bucket, now)
  def limited(account, scope, now, reset), do: Limits.limited(account, scope, now, reset)
  def limited_after(account, scope, at), do: Limits.limited(account, scope, at)
  def answered(account, bucket, now, quota), do: Limits.answered(account, bucket, now, quota)
  def pass(_ms), do: :ok
end
