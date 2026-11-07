defmodule HalC2.CodexContextPropTest do
  @moduledoc """
  `HalC2.Mcp.Instructions.codex_context/1`, the instructions a Codex turn carries as
  `additionalContext`: for any tools a credential may reach, any runtime and any
  workers-only note, no entry is longer than Codex keeps whole, the orchestration
  entries in Codex's (sorted) order are the orchestration instructions exactly, the
  tools entry is there only with something to say, and the runtime entry only with a
  runtime.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Mcp.Instructions

  property "Codex gets every instruction whole, in order",
    numtests: HalC2.Prop.numtests(200) do
    forall {capabilities, runtime, extra} <- {capabilities(), runtime(), extra()} do
      opts =
        [capabilities: MapSet.new(capabilities), extra: extra] ++
          if(runtime, do: [runtime: runtime], else: [])

      entries = Instructions.codex_context(opts)

      values =
        for {key, %{"kind" => "application", "value" => value}} <- entries, do: {key, value}

      orchestration =
        for {"hal_c2_orchestration_" <> _, value} <- Enum.sort(values), do: value

      tools? = "preview" in capabilities or String.trim(extra) != ""

      (length(values) == map_size(entries) and
         Enum.all?(values, fn {_, value} ->
           byte_size(value) <= Instructions.codex_entry_bytes()
         end) and
         Enum.join(orchestration) == Instructions.orchestration() and
         Map.has_key?(entries, "hal_c2_tools") == tools? and
         Map.has_key?(entries, "hal_c2_runtime") == (runtime != nil))
      |> when_fail(IO.inspect(Map.new(values, fn {k, v} -> {k, byte_size(v)} end)))
    end
  end

  defp capabilities, do: list(oneof(["preview", "device", "threads"]))

  defp extra, do: oneof(["", HalC2.Mcp.workers_only_note()])

  # Model names and slugs as Codex's model list has them: short.
  defp runtime do
    oneof([
      nil,
      let {model, name, effort} <- {word(), oneof([nil, word()]), oneof([nil, word()])} do
        %{harness: "Codex", model: model, model_name: name, effort: effort}
      end
    ])
  end

  defp word do
    let chars <- non_empty(list(oneof([range(?a, ?z), range(?0, ?9), ?-, ?., ?\s]))) do
      chars |> Enum.take(40) |> to_string()
    end
  end
end
