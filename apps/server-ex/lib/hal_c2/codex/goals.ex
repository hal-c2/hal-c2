defmodule HalC2.Codex.Goals do
  @moduledoc """
  Codex's own goals (`thread/goal/*` in the app-server protocol), as `/goal` drives
  them from a HAL-C2 thread: what a message asks of the goal, the limit Codex puts
  on an objective, and the goal as the thread's provider thread shows it.

  `HalC2.Codex.ThreadRuntime` runs the commands and keeps a goal's run open across
  the follow-up turns Codex starts for it.
  """

  # Codex's MAX_THREAD_GOAL_OBJECTIVE_CHARS, counted in Unicode scalar values.
  @max_objective 4_000

  @statuses %{
    "active" => "active",
    "paused" => "paused",
    "blocked" => "blocked",
    "usageLimited" => "usage_limited",
    "budgetLimited" => "budget_limited",
    "complete" => "complete"
  }

  @doc """
  What a turn's message asks of the goal, or nil when it is not a `/goal` command:
  `:show` (a bare `/goal`, or `/goal edit`), `:clear`, `:pause`, `:resume`, or
  `{:set, objective}`. Only the user's own words count: a message with
  attachments is an ordinary turn.
  """
  def command(turn) do
    text = Map.get(turn, :user_text)

    if is_binary(text) and Map.get(turn, :attachments, []) == [],
      do: parse(text)
  end

  @doc false
  def parse(text) do
    case Regex.run(~r/\A\/goal(?:\s+(.*))?\z/su, String.trim(text)) do
      nil ->
        nil

      match ->
        rest = match |> Enum.at(1, "") |> String.trim()

        case String.downcase(rest) do
          "" -> :show
          "edit" -> :show
          "clear" -> :clear
          "pause" -> :pause
          "resume" -> :resume
          _ -> {:set, rest}
        end
    end
  end

  @doc """
  `:ok`, or why Codex would refuse `objective`, said before Codex is asked: the goal
  it already has stays as it is.
  """
  def check(objective) do
    count = objective |> String.to_charlist() |> length()

    if count > @max_objective do
      {:error,
       "The goal objective has #{grouped(count)} characters; Codex takes at most " <>
         "#{grouped(@max_objective)}. Shorten it and send /goal again. " <>
         "The current goal was not changed."}
    else
      :ok
    end
  end

  @doc "What a goal's first turn asks of Codex."
  def first_prompt(objective), do: "Start working toward this goal: #{objective}"

  @doc """
  The turn that opens a goal: its text is the goal's first prompt in place of the
  user's `/goal` message, after what the turn put ahead of it, a new conversation's
  context from the plugins (`HalC2.Orchestration.RunShape`) and a handed-off history.
  A resumed conversation has nothing ahead, so nothing is put there again. The turn
  starting confirms the handoff, so history left out here would never be sent: a text
  that does not end with the message still keeps the history the turn carries
  (`HalC2.Orchestration.Handoff.ahead/2`).
  """
  def first_turn(%{text: text} = turn, objective) do
    message = Map.get(turn, :message)

    ahead =
      cond do
        is_binary(text) and is_binary(message) and String.ends_with?(text, message) ->
          binary_part(text, 0, byte_size(text) - byte_size(message))

        history = turn[:history] ->
          history <> "\n\n"

        true ->
          ""
      end

    %{turn | text: ahead <> first_prompt(objective)}
  end

  @doc """
  The goal as the provider thread keeps it (`goal`), from Codex's `ThreadGoal`: nil
  for none, or one whose objective is blank.
  """
  def from_codex(%{"objective" => objective} = goal) when is_binary(objective) do
    case String.trim(objective) do
      "" ->
        nil

      objective ->
        %{
          "objective" => objective,
          "status" => Map.get(@statuses, goal["status"], "paused"),
          "tokensUsed" => max(goal["tokensUsed"] || 0, 0),
          "tokenBudget" => goal["tokenBudget"],
          "timeUsedSeconds" => max(goal["timeUsedSeconds"] || 0, 0)
        }
    end
  end

  def from_codex(_goal), do: nil

  @doc "Whether Codex is working toward `goal` (as `from_codex/1` keeps it)."
  def active?(%{"status" => "active"}), do: true
  def active?(_goal), do: false

  @doc "The reply to a bare `/goal`."
  def describe(nil), do: "No goal is set."

  def describe(%{"status" => status, "objective" => objective}),
    do: "Goal #{String.replace(status, "_", " ")}: #{objective}"

  defp grouped(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
