defmodule HalC2.AcpSessionOptionsPropTest do
  @moduledoc """
  `HalC2.Acp.session_options/1` and `check_option/3`: whatever `configOptions` a
  registry agent reports, what is offered stays within its bounds, offers neither the
  model nor a planning mode, and every value offered is accepted while a value not
  offered, or of the wrong kind, is refused.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Acp

  defp value, do: oneof(["", "a", "b", "c", "plan", "low", "high", "x1"])

  defp choice, do: let(v <- value(), do: %{"value" => v, "name" => v})

  defp choices do
    oneof([
      list(choice()),
      # Grouped choices.
      let(groups <- list(list(choice())), do: for(g <- groups, do: %{"options" => g}))
    ])
  end

  defp option do
    oneof([
      let(
        {id, category, current, listed} <-
          {oneof(["model", "mode", "thinking", "agent", "o1", "o2", "o3", ""]),
           oneof([nil, "mode", "model", "thought_level"]), value(), choices()},
        do:
          %{"id" => id, "type" => "select", "currentValue" => current, "options" => listed}
          |> then(&if(category, do: Map.put(&1, "category", category), else: &1))
      ),
      let(
        {id, current} <- {oneof(["web", "fast"]), oneof([true, false, nil])},
        do: %{"id" => id, "type" => "boolean", "currentValue" => current}
      )
    ])
  end

  # Ids repeat: an agent may name an option twice, and the first naming decides.
  defp config, do: list(option())

  property "offered options stay within bounds and leave out the model and planning" do
    forall config <- config() do
      offered = Acp.session_options(config)
      ids = Enum.map(offered, & &1["id"])

      length(offered) <= 16 and ids == Enum.uniq(ids) and "model" not in ids and
        "" not in ids and
        Enum.all?(offered, fn
          %{"type" => "boolean"} ->
            true

          %{"options" => listed} ->
            values = Enum.map(listed, & &1["id"])
            values != [] and length(values) <= 64 and values == Enum.uniq(values)
        end) and
        not Enum.any?(offered, fn option ->
          source = Enum.find(config, &(&1["id"] == option["id"]))

          source["category"] in ["mode", "collaboration_mode"] and
            Enum.any?(option["options"] || [], &(&1["id"] == "plan"))
        end)
    end
  end

  property "every offered value is accepted, any other is refused" do
    forall {config, picked} <- {config(), oneof([value(), boolean(), integer()])} do
      offered = Acp.session_options(config)

      Enum.all?(offered, fn
        %{"id" => id, "type" => "boolean"} ->
          Acp.check_option(offered, id, true) == :ok and
            Acp.check_option(offered, id, false) == :ok and
            (is_boolean(picked) or match?({:error, _}, Acp.check_option(offered, id, picked)))

        %{"id" => id, "options" => listed} ->
          values = Enum.map(listed, & &1["id"])

          Enum.all?(values, &(Acp.check_option(offered, id, &1) == :ok)) and
            (picked in values or match?({:error, _}, Acp.check_option(offered, id, picked)))
      end) and Acp.check_option(offered, "not-offered", picked) == :skip
    end
  end
end
