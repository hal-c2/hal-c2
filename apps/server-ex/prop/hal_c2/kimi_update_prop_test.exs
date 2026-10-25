defmodule HalC2.KimiUpdatePropTest do
  @moduledoc """
  `HalC2.Acp.Kimi.update/1` over Kimi Code's tool calls as `packages/acp-server/src/
  events-map.ts` sends them: created from the first streamed fragment of the arguments,
  then their text so far, then the whole input under the call's description, then the
  result. However the arguments are split, no running update shows their text, a diff
  stays, the result passes untouched, and a read or write names its file from its input
  while a search never names its directory as a file. The module holds no state, so this
  is a plain `forall`.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Acp.Kimi

  @kinds %{
    "Bash" => "execute",
    "Read" => "read",
    "Grep" => "read",
    "Write" => "edit",
    "Agent" => "other"
  }

  defp path, do: oneof(["src/app.ts", "/repo/src/app.ts", "notes ü.md"])

  defp input("Bash"),
    do:
      let([c <- utf8(), d <- oneof([nil, utf8()])],
        do: compact(%{"command" => c, "description" => d})
      )

  defp input("Read"), do: let(p <- path(), do: %{"path" => p})
  defp input("Grep"), do: let([q <- utf8(), p <- path()], do: %{"pattern" => q, "path" => p})
  defp input("Write"), do: let([p <- path(), t <- utf8()], do: %{"path" => p, "content" => t})
  defp input("Agent"), do: let(t <- utf8(), do: %{"prompt" => t, "subagent_type" => "coder"})

  defp compact(map), do: Map.reject(map, fn {_, v} -> is_nil(v) end)

  defp call do
    let tool <- oneof(Map.keys(@kinds)) do
      let [
        input <- input(tool),
        cuts <- list(nat()),
        diff <- boolean(),
        end_ <- oneof(["completed", "failed"])
      ] do
        {tool, input, cuts, diff, end_}
      end
    end
  end

  defp text(t), do: %{"type" => "content", "content" => %{"type" => "text", "text" => t}}
  @diff %{"type" => "diff", "path" => "/repo/src/app.ts", "oldText" => "a", "newText" => "b"}

  # Kimi Code names a file tool's path as a location only when it is absolute.
  defp locations(tool, input) do
    if tool in ["Read", "Write", "Grep"] and Path.type(input["path"]) == :absolute,
      do: [%{"path" => input["path"]}]
  end

  # The updates in the order Kimi Code sends them for one call.
  defp updates({tool, input, cuts, diff, end_}) do
    args = JSON.encode!(input)
    size = byte_size(args)
    cuts = cuts |> Enum.map(&min(&1 + 1, size)) |> Enum.sort() |> Enum.uniq()
    [first | rest] = if cuts == [], do: [size], else: cuts
    base = %{"toolCallId" => "1:call-1"}
    locations = locations(tool, input)

    [
      Map.merge(base, %{
        "sessionUpdate" => "tool_call",
        "title" => tool,
        "kind" => @kinds[tool],
        "status" => "pending",
        "content" => [text(binary_part(args, 0, first))]
      })
    ] ++
      for cut <- rest do
        Map.merge(base, %{
          "sessionUpdate" => "tool_call_update",
          "status" => "in_progress",
          "content" => [text(binary_part(args, 0, cut))]
        })
      end ++
      [
        Map.merge(base, %{
          "sessionUpdate" => "tool_call_update",
          "title" => input["description"] || tool,
          "kind" => @kinds[tool],
          "status" => "in_progress",
          "rawInput" => input,
          "content" => if(diff, do: [@diff, text(args)], else: [text(args)])
        })
        |> then(&if(locations, do: Map.put(&1, "locations", locations), else: &1)),
        Map.merge(base, %{
          "sessionUpdate" => "tool_call_update",
          "status" => end_,
          "content" => [text("result")],
          "rawOutput" => "result"
        })
      ]
  end

  property "running calls never show their arguments, and a file is named from its input",
    numtests: HalC2.Prop.numtests(300) do
    forall {tool, input, _, diff, _} = call <- call() do
      updates = updates(call)
      {running, [final]} = Enum.split(updates, -1)
      shaped = Enum.map(running, &Kimi.update/1)
      upgrade = List.last(shaped)

      no_arguments =
        Enum.all?(
          shaped,
          &(not Enum.any?(&1["content"] || [], fn c -> c["type"] == "content" end))
        )

      diff_kept = upgrade["content"] == [@diff] == diff
      final_kept = Kimi.update(final) == final

      named =
        case tool do
          t when t in ["Read", "Write"] -> upgrade["locations"] == [%{"path" => input["path"]}]
          # Only Kimi Code's own location, for an absolute path.
          "Grep" -> upgrade["locations"] == locations(tool, input)
          _ -> not Map.has_key?(upgrade, "locations")
        end

      (no_arguments and diff_kept and final_kept and named)
      |> when_fail(IO.inspect(%{updates: updates, shaped: shaped}, label: "kimi"))
      |> aggregate([tool])
    end
  end

  property "updates other than tool calls are left as they are" do
    forall text <- utf8() do
      update = %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }

      Kimi.update(update) == update
    end
  end
end
