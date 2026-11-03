defmodule HalC2.GitHubLimitsPropTest do
  @moduledoc """
  A state machine over `HalC2.GitHub.Limits`: two hosts (one named in mixed case),
  their buckets limited with and without a reset GitHub gave, secondary limits on the
  whole host, answers, and time passing, with checks between any of them. The model
  checks what `HalC2.GitHub.gh/3` is promised:

  - a check is paused exactly while its bucket's pause or its host's secondary pause
    holds, until the later of the two, and a pause on one host or bucket holds back no
    other;
  - a limit with a reset still ahead pauses until that reset, and never shortens a
    longer pause;
  - a limit with no reset pauses for 30 seconds, doubling with each limit in a row up
    to 15 minutes, and one reported while its pause holds changes nothing;
  - an answer ends the backoff of its bucket and of its host's secondary pause once
    they are over, and ends no pause that still holds.

  Beside them, repositories GitHub gave up on (one named in mixed case), read, released
  by a hand refresh, with their own checks. The model checks what the listing is
  promised:

  - a repository is held back exactly while its hold lasts, with the detail of the
    failure that set it, and a hold belongs to one repository of one host, apart from
    every rate limit pause;
  - a failure holds it back for 30 seconds, doubling with each failure in a row up to
    15 minutes, and a failure while it is held back changes nothing;
  - a release lets the next read through and keeps the doubling; a read that got
    through ends it and leaves the page size it read with as the one to start at,
    for 15 minutes, after which a read keeps it afresh.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.GitHub.Limits

  @moduletag timeout: :infinity

  @hosts ["github.com", "GHE.test"]
  @buckets ["core", "graphql", "search"]
  @repositories ["acme/api", "Acme/Shop"]

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

  # pauses: `%{{lowercase host, bucket | :all} => {attempt, until}}`; repos:
  # `%{{lowercase host, lowercase repository} => %{attempt, until, page, page_at, detail}}`.
  def initial_state, do: %{now: 0, pauses: %{}, repos: %{}}

  def command(state) do
    frequency(
      again(state) ++
        [
          {4, {:call, __MODULE__, :check, [host(), bucket(), state.now]}},
          {3, {:call, __MODULE__, :limited, [host(), scope(), state.now, reset(state.now)]}},
          {2, {:call, __MODULE__, :answered, [host(), bucket(), state.now]}},
          {4, {:call, __MODULE__, :repository, [host(), repository(), state.now]}},
          {3,
           {:call, __MODULE__, :repository_failed,
            [host(), repository(), state.now, oneof(["HTTP 502", "HTTP 504"])]}},
          {2,
           {:call, __MODULE__, :repository_read,
            [host(), repository(), oneof([nil, 10, 25]), state.now]}},
          {1,
           {:call, __MODULE__, :release, [oneof([nil | @hosts]), oneof([nil | @repositories])]}},
          {2, {:call, __MODULE__, :pass, [oneof([1_000, 29_000, 30_000, 60_000, 900_000])]}}
        ]
    )
  end

  defp host, do: oneof(@hosts)
  defp bucket, do: oneof(@buckets)
  defp scope, do: oneof([:all | @buckets])
  # A limit met again as soon as a pause ends, so limits in a row reach the cap.
  defp repository, do: oneof(@repositories)

  # A limit met again as soon as a pause ends, so limits in a row reach the cap; the
  # same for a repository GitHub gives up on again.
  defp again(state) do
    pauses =
      if state.pauses == %{},
        do: [],
        else: [
          {4,
           let {{host, scope}, {_, until}} <- oneof(Map.to_list(state.pauses)) do
             {:call, __MODULE__, :limited_after, [host, scope, max(until, state.now)]}
           end}
        ]

    repos =
      if state.repos == %{},
        do: [],
        else: [
          {4,
           let {{host, repository}, entry} <- oneof(Map.to_list(state.repos)) do
             {:call, __MODULE__, :repository_failed_after,
              [host, repository, max(entry.until, state.now)]}
           end}
        ]

    pauses ++ repos
  end

  defp reset(now), do: oneof([nil, nil, now - 1_000, now + 10_000, now + 600_000])

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :limited, [host, scope, now, reset]}) do
    key = {String.downcase(host), scope}
    {attempt, until} = state.pauses[key] || {0, 0}

    entry =
      cond do
        is_integer(reset) and reset > now -> {attempt, max(reset, until)}
        until > now -> {attempt, until}
        true -> {attempt + 1, now + min(30_000 * 2 ** attempt, 900_000)}
      end

    put_in(state.pauses[key], entry)
  end

  def next_state(state, result, {:call, m, :limited_after, [host, scope, at]}),
    do: next_state(%{state | now: at}, result, {:call, m, :limited, [host, scope, at, nil]})

  def next_state(state, _result, {:call, _, :answered, [host, bucket, now]}) do
    host = String.downcase(host)

    pauses =
      Map.reject(state.pauses, fn {{h, scope}, {_, until}} ->
        h == host and scope in [bucket, :all] and until <= now
      end)

    %{state | pauses: pauses}
  end

  def next_state(state, _result, {:call, _, :repository_failed, [host, repository, now, detail]}) do
    key = repo_key(host, repository)
    entry = state.repos[key] || %{attempt: 0, until: 0, page: nil, page_at: 0, detail: nil}

    entry =
      if entry.until > now,
        do: entry,
        else: %{
          entry
          | attempt: entry.attempt + 1,
            until: now + min(30_000 * 2 ** entry.attempt, 900_000),
            detail: detail
        }

    put_in(state.repos[key], entry)
  end

  def next_state(state, result, {:call, m, :repository_failed_after, [host, repository, at]}),
    do:
      next_state(
        %{state | now: at},
        result,
        {:call, m, :repository_failed, [host, repository, at, "HTTP 504"]}
      )

  def next_state(state, _result, {:call, _, :repository_read, [host, repository, page, now]}) do
    key = repo_key(host, repository)
    kept = state.repos[key]

    page_at =
      if kept && kept.page == page && now < kept.page_at + 900_000,
        do: kept.page_at,
        else: now

    repos =
      if page,
        do:
          Map.put(state.repos, key, %{
            attempt: 0,
            until: 0,
            page: page,
            page_at: page_at,
            detail: nil
          }),
        else: Map.delete(state.repos, key)

    %{state | repos: repos}
  end

  def next_state(state, _result, {:call, _, :release, [host, repository]}) do
    repos =
      Map.new(state.repos, fn {{h, r} = key, entry} ->
        if (host == nil or String.downcase(host) == h) and
             (repository == nil or String.downcase(repository) == r),
           do: {key, %{entry | until: 0}},
           else: {key, entry}
      end)

    %{state | repos: repos}
  end

  def next_state(state, _result, {:call, _, :pass, [ms]}), do: %{state | now: state.now + ms}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :check, [host, bucket, now]}, result) do
    host = String.downcase(host)

    holding =
      for scope <- [bucket, :all],
          {_, until} <- [state.pauses[{host, scope}]],
          until > now,
          do: until

    case holding do
      [] -> result == :ok
      untils -> result == {:paused, Enum.max(untils)}
    end
  end

  def postcondition(state, {:call, _, :limited, [host, scope, now, _]} = call, until) do
    {_, before} = state.pauses[{String.downcase(host), scope}] || {0, 0}
    {_, expected} = next_state(state, nil, call).pauses[{String.downcase(host), scope}]
    until == expected and until > now and until >= before
  end

  def postcondition(state, {:call, m, :limited_after, [host, scope, at]}, until),
    do: postcondition(%{state | now: at}, {:call, m, :limited, [host, scope, at, nil]}, until)

  def postcondition(_state, {:call, _, :answered, _}, result), do: result == :ok

  def postcondition(state, {:call, _, :repository, [host, repository, now]}, result) do
    case state.repos[repo_key(host, repository)] do
      %{until: until} = e when until > now -> result == {:held, until, kept(e, now), e.detail}
      %{} = e -> result == {:ok, kept(e, now)}
      nil -> result == {:ok, nil}
    end
  end

  def postcondition(
        state,
        {:call, _, :repository_failed, [host, repository, now, _]} = call,
        result
      ) do
    key = repo_key(host, repository)
    before = (state.repos[key] || %{until: 0}).until
    expected = next_state(state, nil, call).repos[key].until
    result == {expected, before <= now} and expected > now and expected >= before
  end

  def postcondition(state, {:call, m, :repository_failed_after, [host, repository, at]}, result),
    do:
      postcondition(
        %{state | now: at},
        {:call, m, :repository_failed, [host, repository, at, "HTTP 504"]},
        result
      )

  def postcondition(_state, _call, _result), do: true

  # --- commands -------------------------------------------------------------------

  def check(host, bucket, now), do: Limits.check(host, bucket, now)
  def limited(host, scope, now, reset), do: Limits.limited(host, scope, now, reset)
  def limited_after(host, scope, at), do: Limits.limited(host, scope, at)
  def answered(host, bucket, now), do: Limits.answered(host, bucket, now)
  def repository(host, repository, now), do: Limits.repository(host, repository, now)

  def repository_failed(host, repository, now, detail),
    do: Limits.repository_failed(host, repository, now, detail)

  def repository_failed_after(host, repository, at),
    do: Limits.repository_failed(host, repository, at, "HTTP 504")

  def repository_read(host, repository, page, now),
    do: Limits.repository_read(host, repository, page, now)

  def release(host, repository), do: Limits.release(host, repository)
  def pass(_ms), do: :ok

  # The page size a read starts at: the kept one, for 15 minutes after it was kept.
  defp kept(%{page: page, page_at: at}, now) when page != nil and now < at + 900_000, do: page
  defp kept(_entry, _now), do: nil

  defp repo_key(host, repository), do: {String.downcase(host), String.downcase(repository)}
end
