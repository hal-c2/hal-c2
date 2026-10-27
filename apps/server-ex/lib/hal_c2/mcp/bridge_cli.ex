defmodule HalC2.Mcp.BridgeCli do
  @moduledoc """
  The argv runner for `acp-mcp-bridge` and `acp-mcp-call`
  (`bin/hal-c2-service acp-mcp-bridge`, `mix hal_c2.acp_mcp acp-mcp-call`).

  Both read the endpoint and credential from the environment the MC put in
  the agent's session (`HAL_C2_ACP_MCP_ENDPOINT`,
  `HAL_C2_ACP_MCP_AUTHORIZATION`) — never the command line, where any
  process could read them. Missing either ends with status 2 saying what
  is missing.
  """

  @doc """
  Runs one command: `{:ok, output}` to print, or `{:error, status, message}`
  for stderr. The bridge itself runs until its input ends (`run_bridge/3`).
  """
  def command(command, args, env \\ System.get_env()) do
    endpoint = env["HAL_C2_ACP_MCP_ENDPOINT"]
    authorization = env["HAL_C2_ACP_MCP_AUTHORIZATION"]

    cond do
      endpoint in [nil, ""] or authorization in [nil, ""] ->
        {:error, 2,
         "#{command} requires HAL_C2_ACP_MCP_ENDPOINT and HAL_C2_ACP_MCP_AUTHORIZATION."}

      command == "acp-mcp-call" ->
        call(args, endpoint, authorization)

      command == "acp-mcp-bridge" ->
        {:bridge, endpoint, authorization}

      true ->
        {:error, 2, "unknown command #{command}"}
    end
  end

  defp call([tool, arguments_json], endpoint, authorization) do
    case JSON.decode(arguments_json) do
      {:ok, %{} = arguments} ->
        case HalC2.Mcp.Bridge.call_tool(endpoint, authorization, tool, arguments) do
          {:ok, result} -> {:ok, JSON.encode!(result) <> "\n"}
          {:error, message} -> {:error, 1, message}
        end

      {:ok, _} ->
        {:error, 2, "acp-mcp-call arguments must be a JSON object."}

      {:error, _} ->
        {:error, 2, "acp-mcp-call arguments must be valid JSON."}
    end
  end

  defp call(_args, _endpoint, _authorization),
    do: {:error, 2, "acp-mcp-call requires <tool> and <arguments-json>."}

  @doc "Runs the stdio bridge until `input` (an enumerable of lines) ends."
  def run_bridge(endpoint, authorization, input, out \\ &IO.write/1) do
    {:ok, bridge} =
      HalC2.Mcp.Bridge.start_link(endpoint: endpoint, authorization: authorization, out: out)

    Enum.each(input, &HalC2.Mcp.Bridge.line(bridge, &1))
    HalC2.Mcp.Bridge.flush(bridge)
    GenServer.stop(bridge)
    :ok
  end

  @doc "The release/mix entry: prints, bridges over stdio, or halts with the status."
  def main([command | args]) do
    case command(command, args) do
      {:ok, output} ->
        IO.write(output)

      {:bridge, endpoint, authorization} ->
        run_bridge(endpoint, authorization, IO.stream(:stdio, :line))

      {:error, status, message} ->
        IO.puts(:stderr, message)
        System.halt(status)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: acp-mcp-bridge | acp-mcp-call <tool> <arguments-json>")
    System.halt(2)
  end
end
