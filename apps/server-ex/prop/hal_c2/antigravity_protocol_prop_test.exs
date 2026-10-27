defmodule HalC2.AntigravityProtocolPropTest do
  @moduledoc """
  The laws of `HalC2.Acp.Antigravity.Protocol`: a sanitized tool payload keeps
  at most 512 nodes and 64,000 characters of text, no text longer than 8,000
  characters under the marker (and no inline image data), an answer names an
  option only when it matches exactly one, and approval choices come only
  from options Antigravity gave. Pure functions, plain `forall`s.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Acp.Antigravity.Protocol

  # Bounded JSON-ish data (`HalC2.Prop.Generators.json_value/0`), with image
  # payloads planted in it.
  defp value do
    frequency([
      {4, HalC2.Prop.Generators.json_value()},
      {1, oneof([:none, "data:image/png;base64,SECRET"])},
      {1, imageish()},
      {1, resize(4, list(oneof([HalC2.Prop.Generators.json_value(), imageish()])))}
    ])
  end

  defp imageish do
    let {data, extra} <- {utf8(), HalC2.Prop.Generators.json_value()} do
      %{"type" => "image", "data" => "SECRET" <> data, "keep" => extra}
    end
  end

  defp measure(term), do: measure(term, {0, 0})

  defp measure(term, {nodes, chars}) when is_binary(term),
    do: {nodes + 1, chars + String.length(term)}

  defp measure(term, acc) when is_list(term),
    do: Enum.reduce(term, bump(acc), fn v, a -> measure(v, a) end)

  defp measure(term, acc) when is_map(term),
    do: Enum.reduce(Map.values(term), bump(acc), fn v, a -> measure(v, a) end)

  defp measure(_term, acc), do: bump(acc)

  defp bump({n, c}), do: {n + 1, c}

  defp depth(term) when is_list(term),
    do: 1 + Enum.max([0 | Enum.map(term, &depth/1)])

  defp depth(term) when is_map(term),
    do: 1 + Enum.max([0 | Enum.map(Map.values(term), &depth/1)])

  defp depth(_term), do: 0

  defp texts(term, acc \\ [])
  defp texts(term, acc) when is_binary(term), do: [term | acc]
  defp texts(term, acc) when is_list(term), do: Enum.reduce(term, acc, &texts/2)
  defp texts(term, acc) when is_map(term), do: Enum.reduce(Map.values(term), acc, &texts/2)
  defp texts(_term, acc), do: acc

  property "sanitized data stays inside the storage bounds and keeps no image data",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall payload <- value() do
      clean = Protocol.sanitize(payload)
      {nodes, chars} = measure(clean)

      nodes <= 513 and chars <= 64_000 and depth(clean) <= 14 and
        Enum.all?(texts(clean), fn text ->
          String.length(text) <= 8_000 + String.length("[Earlier output truncated]\n\n") and
            not String.contains?(text, "SECRET")
        end)
    end
  end

  property "bound text keeps its end", numtests: HalC2.Prop.numtests(100) do
    forall text <- utf8() do
      bound = Protocol.bound(text)
      String.ends_with?(bound, String.slice(text, -8_000..-1//1) |> then(& &1)) or bound == text
    end
  end

  defp options(labels) do
    labels
    |> Enum.with_index(1)
    |> Enum.map(fn {label, n} ->
      %{"optionId" => "opt-#{n}", "name" => label, "kind" => "allow_once"}
    end)
  end

  defp params(labels) do
    %{
      "toolCall" => %{"toolCallId" => "interaction_p", "title" => "Which?"},
      "options" => options(labels)
    }
  end

  property "an answer selects the option it names, by id or by its only label",
    numtests: HalC2.Prop.numtests(100) do
    forall labels <- resize(5, list(utf8(5))) do
      labels = Enum.map(labels, &String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

      implies(labels != []) do
        answer = Protocol.answer(params(labels), %{"interaction_p" => hd(labels)})
        answer == %{"outcome" => %{"outcome" => "selected", "optionId" => "opt-1"}}
      end
    end
  end

  property "an answer matching no option, or two, selects nothing",
    numtests: HalC2.Prop.numtests(100) do
    forall {label, other} <- {utf8(5), utf8(5)} do
      label = String.trim(label)

      implies(label != "" and String.trim(other) != label) do
        Protocol.answer(params([label, label]), %{"interaction_p" => label}) == nil and
          Protocol.answer(params([label]), %{"interaction_p" => other}) == nil
      end
    end
  end

  property "approval choices come only from the options given",
    numtests: HalC2.Prop.numtests(100) do
    forall kinds <- resize(6, list(oneof(~w(allow_once allow_always reject_once other)))) do
      given =
        kinds
        |> Enum.with_index(1)
        |> Enum.map(fn {kind, n} -> %{"optionId" => "o#{n}", "kind" => kind} end)

      choices = Protocol.approval_options(%{"options" => given})
      labels = Enum.map(choices, & &1["label"])

      List.last(labels) == "Cancel" and
        "Allow once" in labels == "allow_once" in kinds and
        "Allow for this thread" in labels == "allow_always" in kinds and
        "Deny" in labels == "reject_once" in kinds
    end
  end
end
