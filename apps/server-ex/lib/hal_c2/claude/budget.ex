defmodule HalC2.Claude.Budget do
  @moduledoc """
  What a sandboxed review's Claude CLI spent (#1412), as the counts its budget in
  `HalC2.OpenShell.Review` adds up: each update returns the budget and the
  `{key, tokens}` counts to report, a key's latest count replacing its earlier one.

  A main conversation's message is counted with its final counts (its usage merged
  with its `message_delta`, `message/3`). A subagent's messages come only complete,
  with the counts their request started with, none of what it wrote; its task's
  progress then carries its latest message's whole count (`observe/2`). The CLI's own
  count in each result, over every model and request of the process, covers the rest
  (what a subagent wrote after its last progress, the CLI's side requests): what it
  counted beyond every count reported in this process. A resumed session's CLI counts
  on from what it restored, so its first result only says where it began.
  """

  defstruct counted: %{}, base: 0, key: nil, last: %{}

  @type t :: %__MODULE__{
          counted: %{optional(String.t()) => non_neg_integer()},
          base: non_neg_integer() | nil,
          key: reference(),
          last: %{optional(String.t()) => String.t()}
        }
  @type counts :: [{String.t() | reference(), non_neg_integer()}]

  @usage ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens)
  @model_usage ~w(inputTokens outputTokens cacheReadInputTokens cacheCreationInputTokens)

  @doc "The budget of a CLI just started, `resumed` when it resumed a session."
  @spec new(boolean()) :: t()
  def new(resumed), do: %__MODULE__{base: if(resumed, do: nil, else: 0), key: make_ref()}

  @doc """
  Counts message `id` at `usage`, a Claude message's usage. A cached prompt is still
  read, so cache reads count like any other input.
  """
  @spec message(t(), String.t(), map()) :: {t(), counts()}
  def message(budget, id, usage), do: count(budget, id, sum(usage, @usage))

  @doc "Counts what CLI message `message` says was spent beyond the main conversation's messages."
  @spec observe(t(), map()) :: {t(), counts()}
  def observe(budget, %{"type" => "assistant", "parent_tool_use_id" => parent} = message)
      when is_binary(parent) do
    with %{"id" => id, "usage" => %{} = usage} when is_binary(id) <- message["message"] do
      {budget, counts} = message(budget, id, usage)
      {put_in(budget.last[parent], id), counts}
    else
      _ -> {budget, []}
    end
  end

  def observe(
        %{last: last} = budget,
        %{"type" => "system", "subtype" => "task_progress", "tool_use_id" => parent} = task
      )
      when is_map_key(last, parent) do
    id = last[parent]

    case task["usage"] do
      %{"total_tokens" => total} when is_integer(total) ->
        if total > Map.get(budget.counted, id, 0),
          do: count(budget, id, total),
          else: {budget, []}

      _ ->
        {budget, []}
    end
  end

  def observe(budget, %{"type" => "result", "modelUsage" => %{} = models}) do
    total = Enum.sum(for {_model, %{} = usage} <- models, do: sum(usage, @model_usage))

    case budget.base do
      nil ->
        {%{budget | base: total, counted: %{}}, []}

      base ->
        unreported = total - base - Enum.sum(Map.values(budget.counted))
        {budget, [{budget.key, max(unreported, 0)}]}
    end
  end

  def observe(budget, _message), do: {budget, []}

  defp count(budget, key, tokens),
    do: {put_in(budget.counted[key], tokens), [{key, tokens}]}

  defp sum(usage, keys),
    do: Enum.sum(for key <- keys, is_integer(usage[key]), do: usage[key])
end
