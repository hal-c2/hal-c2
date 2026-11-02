defmodule Mix.Tasks.HalC2.AcpMcp do
  @shortdoc "Runs the ACP MCP bridge or one terminal tool call"
  @moduledoc """
  `mix hal_c2.acp_mcp acp-mcp-bridge` runs the stdio MCP bridge an ACP
  agent spawns; `mix hal_c2.acp_mcp acp-mcp-call <tool> <arguments-json>`
  calls one tool from a terminal. Both read `HAL_C2_ACP_MCP_ENDPOINT` and
  `HAL_C2_ACP_MCP_AUTHORIZATION` from the environment
  (`HalC2.Mcp.BridgeCli`). A release reaches the same code as
  `bin/hal-c2-service acp-mcp-bridge`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Application.ensure_all_started(:req)
    HalC2.Mcp.BridgeCli.main(args)
  end
end
