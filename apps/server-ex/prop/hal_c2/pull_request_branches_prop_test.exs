defmodule HalC2.PullRequestBranchesPropTest do
  @moduledoc """
  A state machine over `HalC2.PullRequests.Branches`: two checkouts with two branches
  each, GitHub's answer for a branch changing between open, merged, none and failing,
  readers asking (some fresh, several at once), changes forgetting one checkout, one
  pull request or every one, and time passing. The model checks what every reader is promised:

  - GitHub is asked only when nothing is believed for the branch: an open pull request
    is believed for a minute, anything else found for five, and a fresh read asks
    past either;
  - a failure is answered again until its wait passes (20 seconds, doubling with each
    failure in a row up to 15 minutes), fresh or not, and one followed by a long quiet
    starts over;
  - readers asking at once share one read and one answer;
  - a forgotten checkout's branches are asked again, and no other's; a forgotten pull
    request's branches are asked again, and no other's.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.PullRequests.Branches

  @moduletag timeout: :infinity

  @cwds ["/a", "/b"]
  @branches ["x", "y"]
  @answers [
    {:ok, nil},
    {:ok, %{"number" => 1, "url" => "https://github.com/o/r/pull/1", "state" => "open"}},
    {:ok, %{"number" => 1, "url" => "https://github.com/o/r/pull/1", "state" => "merged"}},
    {:ok, %{"number" => 2, "url" => "https://github.com/O/R/pull/2", "state" => "open"}},
    {:error, {:failed, "offline"}}
  ]

  property "each branch's pull request is asked of GitHub once for every reader",
    numtests: HalC2.Prop.numtests(300),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        clock = :atomics.new(1, signed: true)
        answers = :ets.new(:answers, [:public])
        :persistent_term.put({__MODULE__, :world}, {clock, answers, self()})
        Application.put_env(:hal_c2, :github_clock, fn -> :atomics.get(clock, 1) end)
        HalC2.Prop.start_services([{Branches, fetch: &fetch/2}])
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        Application.delete_env(:hal_c2, :github_clock)
        :ets.delete(answers)

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # GitHub, as the service asks it: tells the test it was asked, then answers once let.
  def fetch(cwd, branch) do
    {_, answers, test} = :persistent_term.get({__MODULE__, :world})
    send(test, {:fetching, self()})

    receive do
      :answer -> :ok
    end

    case :ets.lookup(answers, {cwd, branch}) do
      [{_, answer}] -> answer
      [] -> {:ok, nil}
    end
  end

  # --- model ----------------------------------------------------------------------

  # held: `%{{cwd, branch} => {answer, failures, expires}}`; github: what it answers now.
  def initial_state, do: %{now: 0, held: %{}, github: %{}}

  def command(_state) do
    frequency([
      {5, {:call, __MODULE__, :lookup, [key(), boolean(), oneof([1, 1, 2, 3])]}},
      {2, {:call, __MODULE__, :answers, [key(), oneof(@answers)]}},
      {1, {:call, __MODULE__, :forget, [oneof([nil | @cwds])]}},
      {1, {:call, __MODULE__, :forget_pull_request, [oneof([1, 2, 3])]}},
      {3,
       {:call, __MODULE__, :pass,
        [oneof([1_000, 19_999, 20_000, 40_000, 59_999, 60_000, 300_000, 900_000, 1_800_000])]}}
    ])
  end

  defp key, do: {oneof(@cwds), oneof(@branches)}

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :lookup, [key, fresh?, _n]}) do
    if held?(state, key, fresh?) do
      state
    else
      answer = state.github[key] || {:ok, nil}
      put_in(state.held[key], entry(state, key, answer))
    end
  end

  def next_state(state, _result, {:call, _, :answers, [key, answer]}),
    do: put_in(state.github[key], answer)

  def next_state(state, _result, {:call, _, :forget, [cwd]}),
    do: %{state | held: Map.reject(state.held, fn {{c, _}, _} -> cwd in [nil, c] end)}

  def next_state(state, _result, {:call, _, :forget_pull_request, [number]}) do
    held =
      Map.reject(state.held, fn {_, {answer, _, _}} ->
        match?({:ok, %{"number" => ^number}}, answer)
      end)

    %{state | held: held}
  end

  def next_state(state, _result, {:call, _, :pass, [ms]}), do: %{state | now: state.now + ms}

  defp held?(state, key, fresh?) do
    case state.held[key] do
      {{:error, _}, _, expires} -> expires > state.now
      {_, _, expires} -> expires > state.now and not fresh?
      nil -> false
    end
  end

  defp entry(state, _key, {:ok, found} = answer) do
    ttl = if match?(%{"state" => "open"}, found), do: 60_000, else: 300_000
    {answer, 0, state.now + ttl}
  end

  defp entry(state, key, error) do
    failures =
      case state.held[key] do
        {{:error, _}, failures, expires} when expires + 900_000 > state.now -> failures
        _ -> 0
      end + 1

    {error, failures, state.now + min(20_000 * 2 ** (failures - 1), 900_000)}
  end

  def postcondition(state, {:call, _, :lookup, [key, fresh?, n]}, {answers, asked}) do
    if held?(state, key, fresh?) do
      {answer, _, _} = state.held[key]
      asked == 0 and answers == List.duplicate({answer, false}, n)
    else
      answer = state.github[key] || {:ok, nil}
      asked == 1 and answers == List.duplicate({answer, true}, n)
    end
  end

  def postcondition(_state, _call, _result), do: true

  # --- commands -------------------------------------------------------------------

  # `n` readers ask at once: every request is in before GitHub answers.
  def lookup({cwd, branch}, fresh?, n) do
    requests =
      for _ <- 1..n,
          do: :gen_server.send_request(Branches, {:lookup, {cwd, branch}, fresh?})

    # Every request above is handled once this sync call returns: a read under way for
    # the branch is the one they all wait on, and GitHub hears of it once.
    asked =
      if Map.has_key?(:sys.get_state(Branches).reading, {cwd, branch}) do
        receive do
          {:fetching, pid} -> send(pid, :answer)
        end

        1
      else
        0
      end

    answers = for r <- requests, do: elem(:gen_server.receive_response(r, 5_000), 1)

    # A second read for the same branch would be a second ask.
    asked =
      receive do
        {:fetching, pid} ->
          send(pid, :answer)
          asked + 1
      after
        0 -> asked
      end

    # The read's answer is held once its task's reply is handled.
    _ = :sys.get_state(Branches)
    {answers, asked}
  end

  def answers(key, answer) do
    {_, answers, _} = :persistent_term.get({__MODULE__, :world})
    :ets.insert(answers, {key, answer})
  end

  def forget(cwd), do: Branches.forget(cwd)

  def forget_pull_request(number), do: Branches.forget_pull_request("o/r", number)

  def pass(ms) do
    {clock, _, _} = :persistent_term.get({__MODULE__, :world})
    :atomics.add(clock, 1, ms)
  end
end
