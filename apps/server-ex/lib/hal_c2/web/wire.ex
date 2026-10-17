defmodule HalC2.Web.Wire do
  @moduledoc """
  Thread entities as they go to clients. The MC keeps the whole of a command's
  output, a file change's diff, and a handoff's history, but clients never show
  them, so they stay off the socket. A failed command keeps the fact that it failed.
  Subagent text and dynamic tool values past their limits are cut or summarized.
  Subagent text that grows by appends is cut to the same text, so what a client folds
  from patches is what a snapshot of the same stream shows it.

  Events carry patches, not entities, so a patch is trimmed by the type of the turn
  item it changes, which the stream that owns the item knows.

  Trimming happens on the MC that owns the thread (`HalC2.Streams.Server`), once for
  all of a stream's clients and before anything crosses to another MC. `version/0`
  is part of a stream's handle, so a client that kept a thread trimmed by other
  rules starts over.
  """

  @version 2
  @max_detail 32_768
  @cut_keys ~w(prompt progress result)
  @max_dynamic 16_384
  @dropped %{
    "command_execution" => ~w(output),
    "file_change" => ~w(diffStr oldStr newStr)
  }

  @doc "Changes whenever what `entity/2` or `patch/4` leave out does."
  def version, do: @version

  @doc "A snapshot row's entity, trimmed."
  def entity("turn-item", item), do: turn_item(item)
  def entity("context-handoff", handoff), do: handoff(handoff)
  def entity(_kind, entity), do: entity

  @doc """
  An event's patch, trimmed, or nil when nothing the client would use is left.
  `type` is the turn item's type when the patch is to one, and `was` the entity just
  before the patch: how much of a subagent's text the client already holds is read
  from it. Without `was`, an append is taken to grow an empty field.
  """
  def patch(kind, patch, type, was \\ nil)

  def patch("turn-item", patch, type, was),
    do: turn_item_patch(get_in(patch, ["s", "type"]) || type, patch, was) |> nonempty()

  def patch("context-handoff", patch, _type, _was),
    do: patch |> drop(~w(history delivery)) |> set("summaryText", "") |> nonempty()

  def patch(_kind, patch, _type, _was), do: patch

  @doc """
  Whether `patch` appends to a subagent text that `entity`, the item as it is now,
  holds past the limit. A client that has not followed the item's appends one by one
  (a replay) cannot be handed them cut; it is sent the item whole instead.
  """
  def appends_past_limit?("turn-item", %{"a" => appended}, %{"type" => "subagent"} = entity),
    do: Enum.any?(@cut_keys, &(is_map_key(appended, &1) and size(entity[&1]) > @max_detail))

  def appends_past_limit?(_kind, _patch, _entity), do: false

  # --- turn items ----------------------------------------------------------------

  defp turn_item(%{"type" => "command_execution"} = item) do
    item |> Map.delete("output") |> failed(item["exitCode"], item["outputIndicatesFailure"])
  end

  defp turn_item(%{"type" => "file_change"} = item), do: Map.drop(item, @dropped["file_change"])

  defp turn_item(%{"type" => "subagent"} = item) do
    Enum.reduce(@cut_keys, item, fn key, item ->
      if is_binary(item[key]), do: Map.put(item, key, cut(item[key])), else: item
    end)
  end

  defp turn_item(%{"type" => "dynamic_tool"} = item) do
    Enum.reduce(~w(input output), item, fn key, item ->
      if Map.has_key?(item, key), do: Map.put(item, key, summarize(item[key])), else: item
    end)
  end

  defp turn_item(item), do: item

  defp turn_item_patch(type, patch, _was) when is_map_key(@dropped, type) do
    patch = drop(patch, @dropped[type])

    if type == "command_execution",
      do: failed_patch(patch),
      else: patch
  end

  defp turn_item_patch("subagent", patch, was) do
    patch
    |> map_set(@cut_keys, &if(is_binary(&1), do: cut(&1), else: &1))
    |> cut_appends(was)
  end

  defp turn_item_patch("dynamic_tool", patch, _was),
    do: map_set(patch, ~w(input output), &summarize/1)

  defp turn_item_patch(_type, patch, _was), do: patch

  # The client holds a subagent's text cut, as a snapshot has it. An append that keeps
  # the text under the limit goes through; one that takes it past is the cut text,
  # sent as a set; one to text already past it adds nothing, as the cut text is the
  # same first bytes whatever follows. Sets are cut before this, so a set in the
  # patch is what the appends are applied to.
  defp cut_appends(%{"a" => appended} = patch, was) do
    Enum.reduce(appended, patch, fn
      {key, suffix}, patch when key in @cut_keys ->
        held = held(patch, key, was)
        size = byte_size(held)

        cond do
          size + byte_size(suffix) <= @max_detail -> patch
          size > @max_detail -> unappend(patch, key)
          true -> patch |> unappend(key) |> set(key, cut(held <> suffix))
        end

      _other, patch ->
        patch
    end)
  end

  defp cut_appends(patch, _was), do: patch

  defp held(patch, key, was) do
    case get_in(patch, ["s", key]) || (was && was[key]) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp unappend(patch, key) do
    patch = Map.update!(patch, "a", &Map.delete(&1, key))
    if patch["a"] == %{}, do: Map.delete(patch, "a"), else: patch
  end

  defp size(text) when is_binary(text), do: byte_size(text)
  defp size(_text), do: 0

  # A command that failed says so without its output.
  defp failed(item, exit_code, flagged) do
    if flagged == true or (is_integer(exit_code) and exit_code != 0),
      do: Map.put(item, "outputIndicatesFailure", true),
      else: item
  end

  defp failed_patch(%{"s" => %{"exitCode" => code}} = patch) when is_integer(code) and code != 0,
    do: set(patch, "outputIndicatesFailure", true)

  defp failed_patch(patch), do: patch

  defp handoff(handoff),
    do: handoff |> Map.drop(~w(history delivery)) |> Map.put("summaryText", "")

  # --- values ----------------------------------------------------------------------

  defp cut(text) when byte_size(text) <= @max_detail, do: text

  defp cut(text) do
    prefix = binary_part(text, 0, @max_detail)
    # Never end mid-character.
    prefix = String.replace_invalid(prefix, "") |> String.trim_trailing(<<0xFFFD::utf8>>)
    prefix <> "\n… output truncated for transport"
  end

  # A value past the limit becomes the first line of it, marked as cut.
  defp summarize(value) do
    json = if is_binary(value), do: value, else: JSON.encode!(value)

    if byte_size(json) <= @max_dynamic do
      value
    else
      line =
        json
        |> String.trim_leading()
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.slice(0, 160)

      %{"summary" => if(line == "", do: "Large tool output", else: line), "truncated" => true}
    end
  end

  # --- patches -----------------------------------------------------------------------

  defp drop(patch, keys) do
    patch
    |> Map.update("s", nil, &Map.drop(&1, keys))
    |> Map.update("a", nil, &Map.drop(&1, keys))
    |> Map.reject(fn {key, value} -> key in ["s", "a"] and value in [nil, %{}] end)
  end

  defp set(patch, key, value),
    do: Map.update(patch, "s", %{key => value}, &Map.put(&1, key, value))

  defp map_set(%{"s" => set} = patch, keys, fun) do
    %{
      patch
      | "s" =>
          Map.new(set, fn {key, value} -> {key, if(key in keys, do: fun.(value), else: value)} end)
    }
  end

  defp map_set(patch, _keys, _fun), do: patch

  defp nonempty(patch) when map_size(patch) == 0, do: nil
  defp nonempty(patch), do: patch
end
