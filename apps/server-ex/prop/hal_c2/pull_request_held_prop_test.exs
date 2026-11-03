defmodule HalC2.PullRequestHeldPropTest do
  @moduledoc """
  A state machine over `HalC2.PullRequests.Held`: previews and details put for a few
  pull requests of two repositories on two hosts, some by a read that something was
  forgotten during, pull requests, repositories and everything forgotten, hosts rate
  limited, and time passing, with lookups between any of them. The model checks what
  `pullRequests.preview` is promised:

  - a lookup answers the newest preview or details put for that pull request in the
    last 15 seconds, and nothing older;
  - nothing forgotten is answered again, and a read started before a forget never
    puts back what it read;
  - forgetting one pull request or repository leaves every other one held;
  - with nothing held, a rate limited host is paused until its backoff ends, 30
    seconds doubling with each limit in a row up to 15 minutes, and an answer from the
    host starts the backoff over.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PullRequests.Held

  @moduletag timeout: :infinity

  @hosts ["github.com", "ghe.test"]
  @repositories ["acme/web", "acme/docs"]
  @numbers [1, 2]
  @ttl 15_000

  property "previews are held for a moment and forgotten when asked",
    numtests: HalC2.Prop.numtests(300),
    max_size: 50 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.start_services([Held])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # held: `%{{table, key} => {at, value}}`; limits: `%{host => {attempt, until}}`.
  def initial_state, do: %{now: 0, held: %{}, limits: %{}, puts: 0}

  def command(state) do
    frequency([
      {4, {:call, __MODULE__, :lookup, [key(), state.now]}},
      {3, {:call, __MODULE__, :put, [table(), key(), state.now, state.puts]}},
      {1, {:call, __MODULE__, :put_after_forget, [table(), key(), state.now, state.puts]}},
      {1, {:call, __MODULE__, :forget, [oneof(@hosts), oneof(@repositories), maybe_number()]}},
      {1, {:call, __MODULE__, :forget_all, []}},
      {1, {:call, __MODULE__, :rate_limited, [oneof(@hosts), state.now]}},
      {2, {:call, __MODULE__, :pass, [oneof([1_000, 5_000, 14_000, 16_000, 60_000])]}}
    ])
  end

  defp table, do: oneof([:previews, :details])
  defp key, do: {oneof(@hosts), oneof(@repositories), oneof(@numbers), "p"}
  defp maybe_number, do: oneof([nil | @numbers])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put, [table, {host, _, _, _} = key, now, n]}) do
    %{
      state
      | held: Map.put(state.held, {table, key}, {now, n}),
        limits: Map.delete(state.limits, host),
        puts: n + 1
    }
  end

  def next_state(state, _result, {:call, _, :put_after_forget, [_, {h, r, n, _} = key, _, p]}) do
    %{forget_in(state, h, r, n) | limits: Map.delete(state.limits, elem(key, 0)), puts: p + 1}
  end

  def next_state(state, _result, {:call, _, :forget, [host, repository, number]}),
    do: forget_in(state, host, repository, number)

  def next_state(state, _result, {:call, _, :forget_all, []}), do: %{state | held: %{}}

  def next_state(state, _result, {:call, _, :rate_limited, [host, now]}) do
    attempt = elem(state.limits[host] || {0, 0}, 0) + 1
    until = now + min(30_000 * 2 ** (attempt - 1), 900_000)
    put_in(state.limits[host], {attempt, until})
  end

  def next_state(state, _result, {:call, _, :pass, [ms]}), do: %{state | now: state.now + ms}
  def next_state(state, _result, _call), do: state

  defp forget_in(state, host, repository, number) do
    held =
      Map.reject(state.held, fn {{_, {h, r, n, _}}, _} ->
        h == host and r == repository and number in [nil, n]
      end)

    %{state | held: held}
  end

  def postcondition(state, {:call, _, :lookup, [{host, _, _, _} = key, now]}, result) do
    fresh =
      for table <- [:previews, :details],
          {at, value} <- [state.held[{table, key}]],
          now - at <= @ttl,
          do: {at, value}

    case {Enum.max_by(fresh, &elem(&1, 0), fn -> nil end), state.limits[host], result} do
      {{at, _}, _, {:ok, value}} -> Enum.any?(fresh, &(&1 == {at, value}))
      {nil, {_, until}, {:paused, paused}} when until > now -> paused == until
      {nil, {_, until}, {:miss, _}} -> until <= now
      {nil, nil, {:miss, _}} -> true
      _ -> false
    end
  end

  def postcondition(state, {:call, _, :rate_limited, [host, now]}, until) do
    attempt = elem(state.limits[host] || {0, 0}, 0) + 1
    until == now + min(30_000 * 2 ** (attempt - 1), 900_000)
  end

  def postcondition(_state, _call, _result), do: true

  # --- commands -------------------------------------------------------------------

  def lookup(key, now), do: Held.lookup(key, now)

  # A read that nothing interrupted: its value is `n`, the count of puts before it.
  def put(table, key, now, n), do: do_put(table, key, now, n, Held.token())

  # A read during which its own pull request was forgotten (a change, a refresh).
  def put_after_forget(table, {host, repository, number, _} = key, now, n) do
    token = Held.token()
    Held.forget(host, repository, number)
    do_put(table, key, now, n, token)
  end

  defp do_put(:previews, key, now, n, token), do: Held.put_preview(key, n, now, token)
  defp do_put(:details, key, now, n, token), do: Held.put_detail(key, n, now, token)

  def forget(host, repository, number), do: Held.forget(host, repository, number)
  def forget_all, do: Held.forget_all()
  def rate_limited(host, now), do: Held.rate_limited(host, now)
  def pass(_ms), do: :ok
end
