defmodule HalC2.Claude.McpConfig do
  @moduledoc """
  The MCP config files earlier MCs wrote for Claude, with HAL-C2's tool credential
  in them. Claude now gets HAL-C2's server over stdin (`HalC2.Claude.Session`);
  what is left here removes the files older MCs left behind. Durable processes kept
  theirs inside their durable directory, which goes with it.
  """

  @doc "Removes an ordinary launch's config directory, if it has one."
  # The directory comes only from an earlier MC's session state, never from a client
  # or provider.
  # sobelow_skip ["Traversal.FileModule"]
  def remove(dir) do
    if dir, do: {:ok, _} = File.rm_rf(dir)
    :ok
  end

  @doc "Removes ordinary-launch configs abandoned by an earlier MC."
  # sobelow_skip ["Traversal.FileModule"]
  def sweep do
    {:ok, _} = File.rm_rf(root())
    :ok
  end

  @doc false
  def root, do: Path.join(HalC2.Paths.state_dir(), "claude-mcp")
end
