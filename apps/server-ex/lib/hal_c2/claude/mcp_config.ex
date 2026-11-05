defmodule HalC2.Claude.McpConfig do
  @moduledoc """
  Owner-only MCP configuration for one Claude process. Durable processes keep
  their config inside their durable directory; ordinary ones use a launch
  directory below the MC's state directory.
  """

  @doc "A fresh directory for an ordinary Claude launch."
  def new_dir do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Path.join(root(), unique)
  end

  @doc "Writes Claude's MCP config in `dir` and returns its path."
  # Only the fixed config name below an MC-owned private launch directory is written.
  # sobelow_skip ["Traversal.FileModule"]
  def write!(%{url: url, authorization: authorization}, dir) do
    HalC2.Paths.mkdir_private!(dir)
    path = Path.join(dir, "mcp.json")

    config = %{
      "mcpServers" => %{
        "hal-c2" => %{
          "type" => "http",
          "url" => url,
          "headers" => %{"Authorization" => authorization}
        }
      }
    }

    File.open!(path, [:write, :exclusive], fn file ->
      File.chmod!(path, 0o600)
      IO.write(file, JSON.encode!(config))
    end)

    path
  end

  @doc "Removes an ordinary launch's config directory, if it has one."
  # The directory comes only from `new_dir/0`, never from a client or provider.
  # sobelow_skip ["Traversal.FileModule"]
  def remove(dir) do
    if dir, do: {:ok, _} = File.rm_rf(dir)
    :ok
  end

  @doc "Removes ordinary-launch configs abandoned by an earlier MC."
  # Durable configs live elsewhere and must survive this boot-time sweep.
  # sobelow_skip ["Traversal.FileModule"]
  def sweep do
    {:ok, _} = File.rm_rf(root())
    :ok
  end

  defp root, do: Path.join(HalC2.Paths.state_dir(), "claude-mcp")
end
