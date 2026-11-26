defmodule HalC2.FakeAcpConfigureTest do
  @moduledoc """
  A live fake re-reads its `config.json` on every command (the scripted turn of
  a prompt it has not processed yet included) and treats a torn read as no
  config, so `HalC2.Test.FakeAcp.configure/3` must replace the file atomically:
  a reader racing a rewrite always sees a complete old or new config.
  """
  use ExUnit.Case, async: true

  alias HalC2.Test.FakeAcp

  @moduletag :tmp_dir

  # Large enough that an in-place rewrite's window is wide; the replace is
  # atomic at any size, so the readers below can never observe a torn file.
  @a String.duplicate("a", 200_000)
  @b String.duplicate("b", 200_000)

  test "a config read racing configure is never torn", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(%{"padding" => @a}))
    context = %{fakes: %{"pi" => %{dir: dir}}, provider: "pi"}

    writer =
      Task.async(fn ->
        for i <- 1..40 do
          value = if rem(i, 2) == 0, do: @a, else: @b
          FakeAcp.configure(context, &Map.put(&1, "padding", value))
        end
      end)

    reads = read_while(writer, path, 0)

    assert reads > 0
    assert JSON.decode!(File.read!(path)) == %{"padding" => @a}
    assert File.ls!(dir) == ["config.json"]
  end

  defp read_while(writer, path, reads) do
    assert JSON.decode!(File.read!(path))["padding"] in [@a, @b]

    case Task.yield(writer, 0) do
      nil -> read_while(writer, path, reads + 1)
      {:ok, _} -> reads + 1
      {:exit, reason} -> flunk("configure crashed: #{inspect(reason)}")
    end
  end
end
