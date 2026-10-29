defmodule HalC2.ProjectEnvironmentPropTest do
  @moduledoc """
  The laws of `HalC2.ProjectEnvironment`'s pure half: merging a project's variables
  under a launch keeps the launch whole and adds only names nothing above it owns,
  and a dotenv file renders and parses back to the variables it was made from.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.ProjectEnvironment

  property "merging keeps the launch and adds only names nothing above the project owns",
    numtests: HalC2.Prop.numtests(200) do
    forall {launch, project, unset} <- {env(), env(), list(name())} do
      merged = ProjectEnvironment.merge(launch, project, unset)
      {added, kept} = Enum.split(merged, length(merged) - length(launch))
      names = Enum.map(added, &elem(&1, 0))
      owned = MapSet.new(Enum.map(launch, &elem(&1, 0)) ++ unset)

      wanted =
        project
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&(MapSet.member?(owned, &1) or String.starts_with?(&1, "HAL_C2_")))
        |> Enum.uniq()

      kept == launch and names == wanted and Enum.all?(added, &(&1 in project))
    end
  end

  property "a rendered dotenv file parses back to its variables, the last of a name winning",
    numtests: HalC2.Prop.numtests(200) do
    forall vars <- list({name(), value()}) do
      text = Enum.map_join(vars, &render/1)
      expected = vars |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
      {parsed, bad} = ProjectEnvironment.parse_dotenv(text)

      (bad == [] and Enum.sort(parsed) == Enum.sort(expected))
      |> when_fail(IO.puts("text: #{inspect(text)}\nparsed: #{inspect(parsed)}"))
    end
  end

  defp env, do: list({name(), value()})

  # A small pool so launch, project and unset names collide.
  defp name, do: oneof(["PATH", "SOME_URL", "CODEX_HOME", "HAL_C2_MCP_URL", "A", "B_1"])

  defp value do
    let chars <- list(oneof([range(?a, ?z), ?\s, ?#, ?", ?', ?\\, ?\n, ?\r, ?\t, ?=, ?$, 0x00E9])) do
      List.to_string(chars)
    end
  end

  # The shapes a person writes: bare words unquoted, the rest double-quoted with escapes,
  # sometimes after `export` and with a comment.
  defp render({name, value}) do
    cond do
      value =~ ~r/\A[a-z=$]+\z/ -> "#{name}=#{value}\n"
      rem(:erlang.phash2(value), 2) == 0 -> "export #{name}=\"#{escape(value)}\" # set\n"
      true -> "#{name} = \"#{escape(value)}\"\n"
    end
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
