defmodule HalC2.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :home, previous),
        else: Application.delete_env(:hal_c2, :home)
    end)
  end

  test "a home once linked to HAL-C2 Connect loses its credentials and relay client at start",
       %{tmp_dir: dir} do
    connect =
      ~w(cloud-relay-environment-credential cloud-cli-oauth-token cloud-link-ed25519-key-pair
         cloud-mint-jti-0f1e cloud-health-nonce-2a3b)

    Enum.each(connect, &HalC2.Secrets.put(&1, "s3cret"))
    :ok = HalC2.Secrets.put("slack", "kept")
    cloudflared = Path.join([dir, "tools", "cloudflared", "2026.5.2", "linux-x64"])
    File.mkdir_p!(cloudflared)
    File.write!(Path.join(cloudflared, "cloudflared"), "")

    :ok = HalC2.Application.prepare_files()

    assert Enum.map(connect, &HalC2.Secrets.get/1) == List.duplicate(nil, length(connect))
    assert HalC2.Secrets.get("slack") == "kept"
    refute File.exists?(Path.join([dir, "tools", "cloudflared"]))
  end
end
