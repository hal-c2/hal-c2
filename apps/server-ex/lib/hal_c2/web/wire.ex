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

  @version 3
  @max_detail 32_768
  @cut_keys ~w(prompt progress result)
  @max_dynamic 16_384
  @dropped %{
    "command_execution" => ~w(output),
    "file_change" => ~w(diffStr oldStr newStr),
    "handoff" => ~w(summary)
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
  before the patch (or its `cut_basis/1`): how much of a subagent's text the client
  already holds is read from it. With `was` nil an append is taken to grow an empty
  field, which is right only where the text appended to is known to be within the
  limit or reset by the patch itself: `replay_patch/3` is the one place that passes
  it for a text whose current length it has checked, and the live path passes the
  item (or its basis) an append grows, nil only for an item not there before.
  """
  def patch(kind, patch, type, was)

  def patch("turn-item", patch, type, was),
    do: turn_item_patch(get_in(patch, ["s", "type"]) || type, patch, was) |> nonempty()

  def patch("context-handoff", patch, _type, _was),
    do: patch |> drop(~w(history delivery)) |> set("summaryText", "") |> nonempty()

  def patch(_kind, patch, _type, _was), do: patch

  # Whether `patch` appends to a subagent text that `entity`, the item as it is now,
  # holds past the limit. A client that has not followed the item's appends one by one
  # (a replay) cannot be handed them cut; it is sent the item whole instead. Only
  # `replay_patch/3` decides that, so the check stays in here with it. Deliberately
  # conservative: a key the patch itself resets (its `s`/`u`/`d`) still counts,
  # though `patch/4` could trim that append exactly from the reset — production
  # patches almost never carry reset and append for one field (`Patch.diff/2`
  # never emits it, `Patch.compose/2` folds it into a set), so the whole-item
  # replacement that costs stays the rare path, kept for simplicity.
  defp appends_past_limit?("turn-item", %{"a" => appended}, %{"type" => "subagent"} = entity)
       when is_map(appended),
       do:
         Enum.any?(@cut_keys, &(is_map_key(appended, &1) and text_size(entity[&1]) > @max_detail))

  defp appends_past_limit?(_kind, _patch, _entity), do: false

  @doc """
  Whether `patch` can change a subagent item's `cut_basis/1`: it sets, appends to
  or unsets one of the cut texts, or deletes (replaces) the item. A patch that
  cannot leaves the basis as it was, and its trimming does not read `was`, so a
  caller folding a commit's bases can skip the fold for it.
  """
  def changes_cut_text?(patch) do
    patch["d"] == true or
      Enum.any?(@cut_keys, fn key ->
        key in List.wrap(patch["u"]) or
          (is_map(patch["s"]) and is_map_key(patch["s"], key)) or
          (is_map(patch["a"]) and is_map_key(patch["a"], key))
      end)
  end

  @doc """
  What a replay sends for one merged event (`HalC2.Streams.View.replayed/3`): the
  events since a client's offset coalesced into `patch`, against `entity` as it is
  now. `:replacement` when the patch appends to a subagent text past the limit now:
  the text it grows at the client's offset is not known, so the caller sends the
  item whole, cut as `entity/2` has it. Else `{:patch, trimmed}` or nil when
  nothing is left. Text within the limit now was within it at the offset too,
  unless the patch resets it, which `patch/4` reads from the patch itself; that is
  the check under which this, the one caller that may, hands `patch/4` an empty
  `was`.
  """
  def replay_patch(kind, patch, entity) do
    if appends_past_limit?(kind, patch, entity) do
      :replacement
    else
      case patch(kind, patch, entity && entity["type"], nil) do
        nil -> nil
        trimmed -> {:patch, trimmed}
      end
    end
  end

  @doc """
  What `patch/4` reads of a subagent item as `was`: its texts, each kept to the bytes
  that decide how it is cut (the first `#{@max_detail}` and whether there are more),
  however long it has grown.
  """
  def cut_basis(nil), do: nil

  def cut_basis(item) do
    Map.new(Map.take(item, @cut_keys), fn
      {key, text} when is_binary(text) and byte_size(text) > @max_detail ->
        {key, binary_part(text, 0, @max_detail + 1)}

      field ->
        field
    end)
  end

  @doc """
  `patch` with its subagent texts kept to what `cut_basis/1` keeps, so that applied to
  an item's basis it gives the patched item's basis, without growing a long text.
  """
  def cut_basis_patch(patch) do
    Enum.reduce(~w(s a), patch, fn op, patch ->
      case patch do
        %{^op => %{} = fields} -> %{patch | op => cut_basis_fields(fields)}
        _ -> patch
      end
    end)
  end

  defp cut_basis_fields(fields) do
    Enum.reduce(@cut_keys, fields, fn key, fields ->
      case fields do
        %{^key => text} when is_binary(text) and byte_size(text) > @max_detail ->
          %{fields | key => binary_part(text, 0, @max_detail + 1)}

        _ ->
          fields
      end
    end)
  end

  # --- turn items ----------------------------------------------------------------

  defp turn_item(%{"type" => "command_execution"} = item) do
    item |> Map.delete("output") |> failed(item)
  end

  defp turn_item(%{"type" => "file_change"} = item), do: Map.drop(item, @dropped["file_change"])

  defp turn_item(%{"type" => "handoff"} = item), do: Map.drop(item, @dropped["handoff"])

  defp turn_item(%{"type" => "subagent"} = item) do
    Enum.reduce(@cut_keys, item, fn key, item ->
      if is_binary(item[key]), do: Map.put(item, key, cut(item[key])), else: item
    end)
  end

  # The raw output of a provider-defined tool stays stored; what crosses is the
  # ids its result named and whether it failed (`compact_dynamic/1`).
  defp turn_item(%{"type" => "dynamic_tool"} = item) do
    item =
      if Map.has_key?(item, "input"),
        do: Map.put(item, "input", summarize(item["input"])),
        else: item

    case Map.fetch(item, "output") do
      {:ok, output} ->
        case compact_dynamic(output) do
          nil -> Map.delete(item, "output")
          compact -> Map.put(item, "output", compact)
        end

      :error ->
        item
    end
  end

  defp turn_item(item), do: item

  defp turn_item_patch(type, patch, _was) when is_map_key(@dropped, type) do
    # A command's failure is read from the output being dropped, before it goes.
    failed? = type == "command_execution" and patch_failed?(patch)
    patch = drop(patch, @dropped[type])
    if failed?, do: set(patch, "outputIndicatesFailure", true), else: patch
  end

  # Sets are cut first: `cut_appends/2` measures an append against the set it follows
  # as the client holds it, so a set past the limit leaves nothing to append to.
  defp turn_item_patch("subagent", patch, was) do
    patch
    |> map_set(@cut_keys, &if(is_binary(&1), do: cut(&1), else: &1))
    |> cut_appends(was)
  end

  defp turn_item_patch("dynamic_tool", patch, _was) do
    patch = map_set(patch, ~w(input), &summarize/1)

    case patch do
      %{"s" => %{"output" => output}} ->
        case compact_dynamic(output) do
          nil -> patch |> drop(~w(output)) |> unset("output")
          compact -> set(patch, "output", compact)
        end

      _ ->
        drop(patch, ~w(output))
    end
  end

  defp turn_item_patch(_type, patch, _was), do: patch

  # The client holds a subagent's text cut, as a snapshot has it. An append that keeps
  # the text under the limit goes through; one that takes it past is the cut text,
  # sent as a set; one to text already past it adds nothing, as the cut text is the
  # same first bytes whatever follows. The text appended to is the one the rest of
  # the patch leaves, as `HalC2.Patch.apply/2` has it: a delete or an unset empties
  # it, a set (cut before this) replaces it.
  defp cut_appends(%{"a" => appended} = patch, was) when is_map(appended) do
    Enum.reduce(appended, patch, fn
      {key, suffix}, patch when key in @cut_keys and is_binary(suffix) ->
        held = held(patch, key, was)
        size = byte_size(held)

        cond do
          size + byte_size(suffix) <= @max_detail ->
            patch

          size > @max_detail ->
            unappend(patch, key)

          # Only the bytes that take the text one past the limit decide its cut.
          true ->
            suffix = binary_part(suffix, 0, @max_detail - size + 1)
            patch |> unappend(key) |> keep(key) |> set(key, cut(held <> suffix))
        end

      _other, patch ->
        patch
    end)
  end

  defp cut_appends(patch, _was), do: patch

  defp held(patch, key, was) do
    held =
      cond do
        key in Map.get(patch, "u", []) -> nil
        is_map_key(Map.get(patch, "s", %{}), key) -> patch["s"][key]
        patch["d"] == true or was == nil -> nil
        true -> was[key]
      end

    if is_binary(held), do: held, else: ""
  end

  # Unsets apply after sets, so an append turned into a set must not be unset too.
  defp keep(%{"u" => unset} = patch, key) do
    case List.delete(unset, key) do
      [] -> Map.delete(patch, "u")
      unset -> %{patch | "u" => unset}
    end
  end

  defp keep(patch, _key), do: patch

  defp unappend(patch, key) do
    patch = Map.update!(patch, "a", &Map.delete(&1, key))
    if patch["a"] == %{}, do: Map.delete(patch, "a"), else: patch
  end

  defp text_size(text) when is_binary(text), do: byte_size(text)
  defp text_size(_text), do: 0

  # A command that failed says so without its output. Some providers report
  # completion even when the output itself describes a failure, so the output
  # (its first `@max_detail` bytes) is read before it is left behind.
  defp failed(item, stored) do
    if stored["outputIndicatesFailure"] == true or
         (is_integer(stored["exitCode"]) and stored["exitCode"] != 0) or
         output_indicates_failure?(stored["output"]),
       do: Map.put(item, "outputIndicatesFailure", true),
       else: item
  end

  defp patch_failed?(patch) do
    set = if is_map(patch["s"]), do: patch["s"], else: %{}
    appended = if is_map(patch["a"]), do: patch["a"], else: %{}

    set["outputIndicatesFailure"] == true or
      (is_integer(set["exitCode"]) and set["exitCode"] != 0) or
      output_indicates_failure?(set["output"]) or
      output_indicates_failure?(appended["output"])
  end

  defp output_indicates_failure?(output) when is_binary(output) do
    text = binary_part(output, 0, min(byte_size(output), @max_detail))

    Regex.match?(
      ~r/file not found|no files found|enoent|no such file|commandnotfoundexception|command not found|is not recognized as the name of a cmdlet|a parameter cannot be found that matches parameter name/i,
      text
    ) or
      (Regex.match?(~r/cannot find path/i, text) and
         Regex.match?(~r/because it does not exist/i, text)) or
      (Regex.match?(~r/is not recognized/i, text) and Regex.match?(~r/the term '/i, text)) or
      Regex.match?(~r/<exited with exit code\s+[1-9]\d*\s*>/i, text) or
      Regex.match?(~r/exit(?:ed)? with exit code\s+[1-9]\d*/i, text) or
      Regex.match?(~r/exit code\s*[:\s]\s*[1-9]\d*\b/i, text)
  end

  defp output_indicates_failure?(_output), do: false

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

  # A value past the limit becomes its first non-blank line (whitespace runs
  # collapsed, at most 160 characters), marked as cut.
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
        |> String.split()
        |> Enum.join(" ")

      summary =
        cond do
          line == "" -> "Large tool output"
          String.length(line) <= 160 -> line
          true -> (line |> String.slice(0, 159) |> String.trim_trailing()) <> "…"
        end

      %{"summary" => summary, "truncated" => true}
    end
  end

  # --- dynamic tool results ----------------------------------------------------
  #
  # What a provider-defined tool's result keeps on the wire: the ids it named
  # (`threadId`, `messageId`, `taskId`, `scheduledTaskId`, a `thread`'s or
  # `threads`' ids, a rolled-back status) and whether it failed. Everything
  # else stays stored. The result may be wrapped (JSON text, content blocks,
  # `structuredContent`), so it is unwrapped within a small read budget; a
  # result too large or deep to read within it keeps only its failure.

  @max_parsed_bytes 16_384
  @max_metadata_bytes 8_192
  @max_id_length 256
  @max_threads 100
  @max_content_blocks 32
  @max_envelope_depth 4
  @max_envelope_nodes 128
  @dynamic_ids ~w(threadId messageId taskId scheduledTaskId)

  defp compact_dynamic(value) do
    budget = %{bytes: @max_parsed_bytes, nodes: @max_envelope_nodes, exceeded: false}
    {result, budget} = read_result(value, budget, 0)
    output = if result.failed, do: %{"isError" => true}, else: %{}
    output = if budget.exceeded, do: output, else: compact_ids(output, result[:data])

    output =
      if byte_size(JSON.encode!(output)) > @max_metadata_bytes,
        do: Map.drop(output, ~w(threads threadId status)),
        else: output

    if output == %{}, do: nil, else: output
  end

  defp compact_ids(output, nil), do: output

  defp compact_ids(output, data) do
    output =
      Enum.reduce(@dynamic_ids, output, fn key, output ->
        case bounded_id(data[key]) do
          nil -> output
          id -> Map.put(output, key, id)
        end
      end)

    output =
      if data["status"] == "rolled_back",
        do: Map.put(output, "status", "rolled_back"),
        else: output

    output =
      case data["thread"] do
        %{} = thread ->
          case bounded_id(thread["threadId"]) do
            nil -> output
            id -> Map.put(output, "thread", %{"threadId" => id})
          end

        _ ->
          output
      end

    case data["threads"] do
      threads when is_list(threads) ->
        case compact_threads(threads) do
          {:ok, kept} ->
            Map.put(output, "threads", kept)

          # A partial batch or a top-level id would turn an unknown creation
          # count into a confidently wrong one in a client's summary.
          :incomplete ->
            Map.drop(output, ~w(threadId status))
        end

      _ ->
        output
    end
  end

  defp compact_threads(threads) when length(threads) > @max_threads, do: :incomplete

  defp compact_threads(threads) do
    Enum.reduce_while(threads, {:ok, []}, fn
      %{} = entry, {:ok, kept} ->
        id = bounded_id(entry["threadId"])
        rolled_back? = entry["status"] == "rolled_back"

        if id == nil and not rolled_back? do
          {:halt, :incomplete}
        else
          kept_entry =
            %{}
            |> then(&if(id, do: Map.put(&1, "threadId", id), else: &1))
            |> then(&if(rolled_back?, do: Map.put(&1, "status", "rolled_back"), else: &1))

          {:cont, {:ok, kept ++ [kept_entry]}}
        end

      _entry, _acc ->
        {:halt, :incomplete}
    end)
  end

  defp bounded_id(value) when is_binary(value) do
    if String.length(value) <= @max_id_length and String.trim(value) != "", do: value
  end

  defp bounded_id(_value), do: nil

  # Unwraps a tool result to `{envelope, budget}`: the envelope is
  # `%{failed: boolean}` plus `data:` (the innermost result object) when one
  # was found within the budget.
  defp read_result(_value, budget, depth) when depth > @max_envelope_depth,
    do: {%{failed: false}, %{budget | exceeded: true}}

  defp read_result(value, %{nodes: nodes} = budget, depth) do
    budget = %{budget | nodes: nodes - 1}

    if nodes <= 0,
      do: {%{failed: false}, %{budget | exceeded: true}},
      else: read_value(value, budget, depth)
  end

  defp read_value(value, budget, depth) when is_binary(value) do
    cond do
      String.length(value) > budget.bytes or byte_size(value) > budget.bytes ->
        {%{failed: false}, %{budget | exceeded: true}}

      true ->
        case JSON.decode(value) do
          {:ok, parsed} ->
            read_result(parsed, %{budget | bytes: budget.bytes - byte_size(value)}, depth + 1)

          _ ->
            {%{failed: false}, budget}
        end
    end
  end

  defp read_value(blocks, budget, depth) when is_list(blocks) do
    if length(blocks) > @max_content_blocks do
      {%{failed: false}, %{budget | exceeded: true}}
    else
      Enum.reduce_while(blocks, {%{failed: false}, budget}, fn block, {envelope, budget} ->
        text = if is_map(block), do: block["text"]
        nested = if is_map(text), do: text["text"] || text, else: text
        {result, budget} = read_result(nested, budget, depth + 1)

        envelope =
          envelope
          |> Map.put(:failed, envelope.failed or result.failed)
          |> then(
            &if(Map.has_key?(&1, :data) or not Map.has_key?(result, :data),
              do: &1,
              else: Map.put(&1, :data, result.data)
            )
          )

        if budget.exceeded, do: {:halt, {envelope, budget}}, else: {:cont, {envelope, budget}}
      end)
    end
  end

  defp read_value(%{} = value, budget, depth) do
    failed =
      value["isError"] == true or value["is_error"] == true or
        value["_tag"] == "OrchestratorMcpFailure" or
        (Map.has_key?(value, "error") and value["error"] != nil)

    content = value["structuredContent"] || value["content"]

    if content != nil do
      {nested, budget} = read_result(content, budget, depth + 1)
      {%{nested | failed: failed or nested.failed}, budget}
    else
      {%{data: value, failed: failed}, budget}
    end
  end

  defp read_value(_value, budget, _depth), do: {%{failed: false}, budget}

  # --- patches -----------------------------------------------------------------------

  defp drop(patch, keys) do
    patch
    |> Map.update("s", nil, &Map.drop(&1, keys))
    |> Map.update("a", nil, &Map.drop(&1, keys))
    |> Map.reject(fn {key, value} -> key in ["s", "a"] and value in [nil, %{}] end)
  end

  defp set(patch, key, value),
    do: Map.update(patch, "s", %{key => value}, &Map.put(&1, key, value))

  defp unset(patch, key),
    do: Map.update(patch, "u", [key], &Enum.uniq([key | &1]))

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
