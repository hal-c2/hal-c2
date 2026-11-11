defmodule HalC2.Orchestration.AppliedModel do
  @moduledoc """
  The model a provider says it runs a turn on, kept on the run as `appliedModel`.

  A runtime calls `record/2` with what its provider reported (Claude's init and
  assistant messages, the native thread Codex opened or rerouted to, the model an ACP
  agent's session reports, Pi's state, Muse's session). When that is not the model the
  run was started on, the thread also gets a notice, so a provider running something
  other than the composer's choice is never silent.
  """

  alias HalC2.Orchestration
  alias HalC2.Orchestration.TurnWriter

  # Names that pick a model by the provider's own rule: what they resolve to is not
  # known here, so no report differs from them.
  @open ~w(default auto best opusplan)

  @doc """
  Records `reported` as the running turn's applied model, once per model, with a
  notice when it is not the run's. Anything but a non-empty name is no report.
  """
  def record(%{turn: %{ids: %{run: run}} = turn} = state, reported)
      when is_binary(reported) and reported != "" do
    if Map.get(turn, :applied_model) == reported do
      state
    else
      TurnWriter.commit(state, fn stream ->
        [
          Orchestration.upsert(stream, "run", run, fn
            nil -> nil
            row -> Map.put(row, "appliedModel", reported)
          end)
        ]
      end)

      state = %{state | turn: Map.put(turn, :applied_model, reported)}
      selected = Map.get(turn, :model)
      # Claude launches a picked model under its CLI name (`Claude.Provider.launch/3`).
      launched = get_in(turn, [Access.key(:launch, %{}), Access.key(:model)])

      if same?(selected, reported) or (is_binary(launched) and same?(launched, reported)),
        do: state,
        else: notice(state, selected, reported)
    end
  end

  def record(state, _reported), do: state

  @doc """
  Whether `reported` is the model `selected` names. A dated or suffixed name
  (`claude-opus-4-5-20251101`, `opus[1m]`) is its model's, a family alias (`opus`)
  is any model of that family, and a name that leaves the choice to the provider
  (`default`, `auto`) or no name at all is any model.
  """
  def same?(selected, reported) when is_binary(selected) and is_binary(reported) do
    selected = plain(selected)
    reported = plain(reported)

    cond do
      selected in ["" | @open] -> true
      selected == reported -> true
      # A family alias, such as Claude's `opus`.
      not String.match?(selected, ~r/\d/) -> String.contains?(reported, selected)
      true -> false
    end
  end

  def same?(_selected, _reported), do: true

  # The name without its case, its `[...]` suffix or its release date.
  defp plain(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\[[^\]]*\]$/, "")
    |> String.replace(~r/[-@]\d{8}$/, "")
    |> String.trim()
  end

  defp notice(state, selected, reported) do
    text = "This turn runs on #{reported}, not the selected #{selected}."
    native = "applied-model:#{state.turn.ids.run}:#{reported}"

    state
    |> TurnWriter.flush()
    |> TurnWriter.ensure_item(native, :notice, %{"title" => text, "message" => text},
      confirms: false
    )
    |> TurnWriter.finish_item(native, "completed", & &1)
  end
end
