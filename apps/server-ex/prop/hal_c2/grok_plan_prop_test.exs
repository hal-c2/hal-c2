defmodule HalC2.GrokPlanPropTest do
  @moduledoc """
  The pure parts of Grok's plan file and answers (`HalC2.Acp.GrokPlan`,
  `HalC2.Acp.Ordered`):

    * a path is Grok's plan file only when it is a `plan.md` below a sessions
      folder with a folder between them, and never when it climbs out with `..`;
    * a `plan.md` outside every sessions folder is never one;
    * an ordered JSON object keeps the order its keys were given in, whatever
      their sort order.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Acp.{GrokPlan, Ordered}

  @moduletag capture_log: true

  @prefixes ["/home/me/.grok/sessions/", "/srv/grok/sessions/"]

  defp segment, do: let(s <- non_empty(list(oneof(Enum.to_list(?a..?z)))), do: to_string(s))

  property "a plan.md two levels under a sessions folder is the plan file",
    numtests: HalC2.Prop.numtests(200) do
    forall {prefix, cwd, session} <- {oneof(@prefixes), segment(), segment()} do
      GrokPlan.plan_file?(prefix <> cwd <> "/" <> session <> "/plan.md", @prefixes)
    end
  end

  property "a path that climbs out with .. is never the plan file",
    numtests: HalC2.Prop.numtests(200) do
    forall {prefix, a, b} <- {oneof(@prefixes), segment(), segment()} do
      not GrokPlan.plan_file?(prefix <> a <> "/../" <> b <> "/plan.md", @prefixes)
    end
  end

  property "a plan.md outside the sessions folders is never the plan file",
    numtests: HalC2.Prop.numtests(200) do
    forall {a, b} <- {segment(), segment()} do
      not GrokPlan.plan_file?("/work/" <> a <> "/" <> b <> "/plan.md", @prefixes)
    end
  end

  property "an ordered object lists its keys in the order given",
    numtests: HalC2.Prop.numtests(200) do
    forall keys <- shuffle_keys() do
      pairs = Enum.map(keys, &{&1, [&1]})
      decoded = pairs |> Ordered.new() |> JSON.encode!() |> IO.iodata_to_binary()

      order =
        Regex.scan(~r/"([a-z]+)":/, decoded, capture: :all_but_first) |> List.flatten()

      order == keys
    end
  end

  defp shuffle_keys do
    let keys <- list_of_unique() do
      keys
    end
  end

  defp list_of_unique do
    let list <- non_empty(list(segment())) do
      Enum.uniq(list)
    end
  end
end
