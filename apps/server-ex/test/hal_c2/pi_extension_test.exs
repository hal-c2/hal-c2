defmodule HalC2.PiExtensionTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "the Pi extension carries the same orchestration instructions every provider gets", %{
    tmp_dir: dir
  } do
    Application.put_env(:hal_c2, :home, dir)

    source = HalC2.Pi.extension_path() |> File.read!()

    assert source =~ JSON.encode!(HalC2.Mcp.instructions())
    refute source =~ "__HAL_C2_INSTRUCTIONS__"
  end

  # An unsandboxed code review's server (`HalC2.Mcp.kept_to/1`) has its plugin's tools
  # alone, so the extension adds no orchestration instructions for it.
  test "a Pi kept to its plugin's tools is told so, and an ordinary one is not", %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    server = %{url: "http://127.0.0.1:1/mcp", authorization: "Bearer t"}

    flag = fn mcp ->
      {:ok, _argv, env} = HalC2.Pi.launch("pi", mcp: mcp)
      Map.new(env)["HAL_C2_MCP_PLUGIN_TOOLS"]
    end

    assert flag.(Map.put(server, :report, true)) == "1"
    assert flag.(server) == ""
    assert flag.(nil) == ""
    assert File.read!(HalC2.Pi.extension_path()) =~ ~s(HAL_C2_MCP_PLUGIN_TOOLS === "1")
  end
end
