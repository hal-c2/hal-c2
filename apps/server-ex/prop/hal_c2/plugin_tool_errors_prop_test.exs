defmodule HalC2.PluginToolErrorsPropTest do
  @moduledoc """
  A plugin tool's error keeps its own code, message and details exactly when it
  describes itself with a short word for a code and a text for a message, whether it
  is a map with string or atom keys or a JSON object. Anything else gives nil, so
  the agent sees `plugin_failed` (#1857).
  """
  use ExUnit.Case, async: true
  use PropCheck

  property "a structured error keeps its code, message and details, and nothing else counts as one" do
    forall {{code, code_ok}, {message, message_ok}, {details, details_ok}, keys, form} <-
             {code(), message(), details(), oneof([:string, :atom]), oneof([:map, :json])} do
      error =
        %{code: code, message: message}
        |> then(&if(details == :absent, do: &1, else: Map.put(&1, :details, details)))
        |> keyed(keys)

      # A tuple has no JSON, so only the map form can carry one.
      reason = if form == :json and details_ok, do: JSON.encode!(error), else: error

      expected =
        if code_ok and message_ok and details_ok,
          do: {code, message, extra(details)}

      HalC2.Plugins.structured_error(reason) == expected
    end
  end

  property "a text that is not a JSON object, or a term that is not a map, is not structured" do
    forall reason <-
             oneof([
               utf8(),
               exactly("{not json"),
               exactly(~s(["invalid_input", "Invalid request."])),
               integer(),
               exactly(nil),
               exactly({:error, :timeout})
             ]) do
      HalC2.Plugins.structured_error(reason) == nil
    end
  end

  defp code do
    oneof([
      let(
        {first, rest} <- {letter(), resize(20, list(oneof([letter(), digit(), punctuation()])))},
        do: {List.to_string([first | rest]), true}
      ),
      exactly({"", false}),
      exactly({"has space", false}),
      exactly({"9lives", false}),
      exactly({"_private", false}),
      exactly({String.duplicate("a", 65), false}),
      exactly({42, false}),
      exactly({nil, false})
    ])
  end

  defp message do
    oneof([
      let(text <- non_empty(resize(20, list(letter()))), do: {List.to_string(text) <> ".", true}),
      exactly({"", false}),
      exactly({"   ", false}),
      exactly({nil, false}),
      exactly({7, false})
    ])
  end

  defp details do
    oneof([
      exactly({:absent, true}),
      exactly({nil, true}),
      exactly({%{"field" => "query"}, true}),
      exactly({%{retryAfter: 60}, true}),
      exactly({["first", 2, true], true}),
      exactly({{:not, :json}, false})
    ])
  end

  defp letter, do: oneof([range(?a, ?z), range(?A, ?Z)])
  defp digit, do: range(?0, ?9)
  defp punctuation, do: elements([?_, ?., ?:, ?-])

  defp keyed(error, :atom), do: error
  defp keyed(error, :string), do: Map.new(error, fn {key, value} -> {to_string(key), value} end)

  defp extra(details) when details in [:absent, nil], do: %{}
  defp extra(details), do: %{"details" => details |> JSON.encode!() |> JSON.decode!()}
end
