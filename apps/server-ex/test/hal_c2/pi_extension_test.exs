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
end
