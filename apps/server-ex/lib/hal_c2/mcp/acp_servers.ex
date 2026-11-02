defmodule HalC2.Mcp.AcpServers do
  @moduledoc """
  The `hal-c2` MCP server as an ACP session is given it, and the way back
  to it from the agent's terminal.

  An agent that takes servers over HTTP gets the server by address with
  its credential in an authorization header. One that does not gets it as
  a local command speaking over standard input and output — ACP's
  required baseline transport — with the address and credential in that
  command's environment, never on its command line, where any process
  could read them. An agent that can carry MCP over the ACP connection
  itself is also offered the server there, under the id `"hal-c2"`
  (`HalC2.Mcp.OverAcp` answers for it).

  Either way the agent's own environment names the address, the
  credential and the command to run one call with (`acp-mcp-call`), the
  supported fallback for an agent that accepted the server but failed to
  expose its tools: `HAL_C2_ACP_MCP_NODE` is this install's command, and
  `HAL_C2_ACP_MCP_ENTRYPOINT` — a checkout's mix task — is unset in a
  release.
  """

  @doc """
  This install's own command lines: `{command, leading_args}` to run
  `subcommand` with, and the entrypoint argument when there is one.
  """
  def self_invocation(subcommand) do
    case HalC2.Upgrade.release_root() do
      nil -> {"mix", ["hal_c2.acp_mcp", subcommand], "hal_c2.acp_mcp"}
      root -> {Path.join([root, "bin", "hal-c2-service"]), [subcommand], nil}
    end
  end

  @doc """
  The servers for one ACP session and the environment for its agent:
  `%{servers: [...], env: [{name, value}]}`. `server` is
  `HalC2.Mcp.for_agent/2`'s answer (nil keeps the tools from the agent).
  """
  def build(_capabilities, nil), do: %{servers: [], env: []}

  def build(capabilities, %{url: url, authorization: authorization}) do
    http? = get_in(capabilities || %{}, ["mcpCapabilities", "http"]) == true
    acp? = get_in(capabilities || %{}, ["mcpCapabilities", "acp"]) == true

    primary =
      if http? do
        %{
          "type" => "http",
          "name" => "hal-c2",
          "url" => url,
          "headers" => [%{"name" => "Authorization", "value" => authorization}]
        }
      else
        {command, args, _entrypoint} = self_invocation("acp-mcp-bridge")

        %{
          "name" => "hal-c2",
          "command" => command,
          "args" => args,
          "env" => [
            %{"name" => "HAL_C2_ACP_MCP_ENDPOINT", "value" => url},
            %{"name" => "HAL_C2_ACP_MCP_AUTHORIZATION", "value" => authorization}
          ]
        }
      end

    servers =
      [primary] ++
        if(acp?, do: [%{"type" => "acp", "name" => "hal-c2", "serverId" => "hal-c2"}], else: [])

    {node, _args, entrypoint} = self_invocation("acp-mcp-call")

    env =
      [
        {"HAL_C2_ACP_MCP_ENDPOINT", url},
        {"HAL_C2_ACP_MCP_AUTHORIZATION", authorization},
        {"HAL_C2_ACP_MCP_NODE", node}
      ] ++ if(entrypoint, do: [{"HAL_C2_ACP_MCP_ENTRYPOINT", entrypoint}], else: [])

    %{servers: servers, env: env}
  end
end
