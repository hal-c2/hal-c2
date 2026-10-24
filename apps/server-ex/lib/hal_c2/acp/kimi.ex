defmodule HalC2.Acp.Kimi do
  @moduledoc """
  Kimi CLI's tool calls in the shape the other ACP agents send.

  Kimi (an `acpRegistry` instance of the registry agent "kimi") sends no `kind` and
  no `rawInput`: its title is the tool's name, with the key argument once one has
  streamed in ("Shell: ls -la"), and while the call runs its content is the
  arguments' JSON text so far. Its final update's content is the tool's result.
  See `src/kimi_cli/acp/session.py` in MoonshotAI/kimi-cli.
  """

  @kinds %{
    "Shell" => "execute",
    "ReadFile" => "read",
    "ReadMediaFile" => "read",
    "Glob" => "search",
    "Grep" => "search"
  }

  @doc """
  An update from `instance`: a Kimi `tool_call` or `tool_call_update` with its
  tool's name as its title, a `kind` for the tools that have one, and its arguments
  as `rawInput` once they are whole JSON. Any other update is returned as it is.
  """
  def update(%{"sessionUpdate" => s} = call, instance)
      when s in ["tool_call", "tool_call_update"] do
    if agent?(instance), do: call |> name() |> arguments(), else: call
  end

  def update(update, _instance), do: update

  defp agent?(instance) do
    HalC2.Acp.driver(instance) == "acpRegistry" and
      HalC2.Acp.setting(instance, "agentId") == "kimi"
  end

  defp name(%{"title" => title} = call) when is_binary(title) do
    [name | _] = String.split(title, ": ", parts: 2)

    case @kinds[name] do
      nil -> %{call | "title" => name}
      kind -> Map.merge(call, %{"title" => name, "kind" => kind})
    end
  end

  defp name(call), do: call

  defp arguments(%{"status" => status} = call) when status in ["completed", "failed"],
    do: call

  defp arguments(%{"content" => [%{"content" => %{"text" => text}}]} = call) do
    call = Map.delete(call, "content")

    case JSON.decode(text) do
      {:ok, %{} = input} -> call |> Map.put("rawInput", input) |> located(input)
      _ -> call
    end
  end

  defp arguments(call), do: call

  # A read names its file in its arguments, where the others name it in `locations`.
  defp located(%{"kind" => "read"} = call, %{"path" => path}) when is_binary(path),
    do: Map.put(call, "locations", [%{"path" => path}])

  defp located(call, _input), do: call
end
