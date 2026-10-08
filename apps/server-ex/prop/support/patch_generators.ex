defmodule HalC2.Prop.PatchGenerators do
  @moduledoc """
  Patches that are valid against the entity they apply to. A raw patch says what to
  do (set, append, unset, delete, replace, or void an event) and `valid_patch/2`
  makes it a patch the log could hold: appends only extend string fields, and unsets
  never overlap sets. Raw patches are plain data, so they shrink well, and validity
  is a pure function of the entity they are applied to.
  """

  use PropCheck

  alias HalC2.Patch
  alias HalC2.Prop.Generators

  @doc "A raw patch that changes an entity or deletes it: no voids."
  def patch_raw, do: raw(frequency([{6, :update}, {2, :delete}, {2, :replace}]))

  @doc "A raw patch that only changes an entity, so it always leaves one behind."
  def update_raw, do: raw(exactly(:update))

  @doc "A raw event: `{kind, id, raw}` over the small pools, voids included."
  def event_raw do
    {Generators.entity_kind(), Generators.entity_id(),
     raw(frequency([{6, :update}, {2, :delete}, {2, :replace}, {1, :void}]))}
  end

  defp raw(ops) do
    let {op, sets, appends, unsets, quiet} <-
          {ops, Generators.entity(), resize(3, map(Generators.field(), utf8())),
           resize(3, list(Generators.field())), boolean()} do
      {op, sets, appends, unsets, quiet}
    end
  end

  @doc """
  The patch a raw patch stands for against `entity` (`nil` when absent). A void is the
  `"s": null` the log holds for a question answered after its item went away.
  """
  def valid_patch(entity, {op, sets, appends, unsets, quiet}) do
    base =
      case op do
        :delete -> %{"d" => true}
        :replace -> %{"d" => true, "s" => sets}
        :void -> %{"s" => nil}
        :update -> update(entity || %{}, sets, appends, unsets)
      end

    if quiet and op != :void, do: Map.put(base, "q", true), else: base
  end

  defp update(entity, sets, appends, unsets) do
    unset = Enum.uniq(unsets) -- Map.keys(sets)
    current = entity |> Map.merge(sets) |> Map.drop(unset)

    appends =
      for {field, suffix} <- appends, is_binary(Map.get(current, field)), into: %{} do
        {field, suffix}
      end

    %{"s" => sets, "a" => appends, "u" => unset}
  end

  @doc """
  The `HalC2.Store`-shaped events that raw events make, numbered from seq 1 with `at` a
  millisecond per seq. Each is valid against the entity its key holds when it is
  folded, so appends always land on strings.
  """
  def events(raw_events) do
    {_models, events} =
      raw_events
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, []}, fn {{kind, id, {op, _, _, _, _} = raw}, seq}, {models, acc} ->
        key = {kind, id}
        patch = valid_patch(Map.get(models, key), raw)
        models = if op == :void, do: models, else: track(models, key, patch)
        event = %{seq: seq, kind: kind, entity: id, patch: patch, at: 1_000 + seq}
        {models, [event | acc]}
      end)

    Enum.reverse(events)
  end

  defp track(models, key, patch) do
    case Patch.apply(Map.get(models, key), patch) do
      nil -> Map.delete(models, key)
      entity -> Map.put(models, key, entity)
    end
  end
end
