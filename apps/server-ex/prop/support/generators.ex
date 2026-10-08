defmodule HalC2.Prop.Generators do
  @moduledoc """
  Generators for the values the MC's core passes around: JSON-shaped entities, the
  `HalC2.Patch`es between them, and ids drawn from small pools so commands collide on
  the same streams and entities often enough to matter.
  """

  use PropCheck

  @doc "One of a few stream ids, so generated commands keep hitting the same streams."
  def stream_id, do: oneof(["s-a", "s-b", "s-c", "s-d"])

  @doc "An entity kind as the store accepts it (`[a-z][a-z-]*`)."
  def entity_kind, do: oneof(["thread", "project", "run", "message", "turn-item"])

  @doc "One of a few entity ids."
  def entity_id, do: oneof(["e1", "e2", "e3"])

  @doc "A field name from a small set, so patches touch the same fields."
  def field, do: oneof(["a", "b", "c", "text", "status"])

  @doc "A JSON scalar."
  def json_scalar do
    oneof([nil, boolean(), integer(), resize(12, utf8()), oneof(["", "x", "running", "idle"])])
  end

  @doc """
  A JSON value: scalars, lists and maps, at most two levels deep and a few wide.
  PropEr grows sizes with every case, and nested collections at full size make
  cases large enough to stall generation, so collections here stay small.
  """
  def json_value, do: json_value(2)

  defp json_value(0), do: json_scalar()

  defp json_value(depth) do
    frequency([
      {4, json_scalar()},
      {1, lazy(resize(4, list(json_value(depth - 1))))},
      {1, lazy(resize(4, map(utf8(), json_value(depth - 1))))}
    ])
  end

  @doc "A JSON-shaped entity over the small field set."
  def entity, do: resize(5, map(field(), json_value()))

  @doc """
  A `HalC2.Patch` as the log stores one: a set, append, unset, delete, or delete with a
  replacement, any of them possibly quiet. Appends carry strings, which is all they
  ever extend.
  """
  def patch do
    let {kind, set, append, unset, quiet} <-
          {oneof([:update, :delete, :replace]), entity(), resize(3, map(field(), utf8())),
           resize(3, list(field())), boolean()} do
      base =
        case kind do
          :delete -> %{"d" => true}
          :replace -> %{"d" => true, "s" => set}
          :update -> %{"s" => set, "a" => append, "u" => Enum.uniq(unset)}
        end

      base
      |> Map.reject(fn {_, v} -> v == %{} or v == [] end)
      |> then(&if(quiet, do: Map.put(&1, "q", true), else: &1))
      |> then(&if(&1 == %{}, do: %{"s" => %{}}, else: &1))
    end
  end
end
