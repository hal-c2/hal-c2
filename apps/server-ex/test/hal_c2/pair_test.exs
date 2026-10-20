defmodule HalC2.PairTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :home, previous),
        else: Application.delete_env(:hal_c2, :home)
    end)

    %{home: home}
  end

  test "minting ahead of a first start makes the store's directory", %{home: home} do
    refute File.exists?(home)

    assert {:ok, [link]} = HalC2.Pair.command(["http://127.0.0.1:3780"])
    assert String.starts_with?(link, "http://127.0.0.1:3780/?token=")
    assert File.exists?(Path.join(home, "hal-c2.sqlite"))
  end

  test "a refused address is echoed without its credentials" do
    assert {:error, message} = HalC2.Pair.command(["http://user:pass@127.0.0.1:3780"])
    assert message =~ "BASE_URL must be an http or https address"
    refute message =~ "user:pass"
    assert message =~ "redacted@127.0.0.1"
  end
end
