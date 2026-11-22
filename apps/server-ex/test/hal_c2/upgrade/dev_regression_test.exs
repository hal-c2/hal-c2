defmodule HalC2.Upgrade.DevRegressionTest do
  @moduledoc """
  `mise run mc:reload` whose relup failed past the point of no return had the release
  handler restart the node (`init:restart/0`) on the dev release's boot script, not
  on the one the MC started with. That script starts `logger` from a stub `.app` with
  no default environment, so the node died at boot: `:handle_otp_reports` was not set.
  """

  use ExUnit.Case, async: false

  alias HalC2.Upgrade.Dev

  @moduletag :tmp_dir

  setup do
    before =
      case :init.get_argument(:boot) do
        {:ok, [[boot | _] | _]} -> boot
        _ -> String.to_charlist(Path.join([to_string(:code.root_dir()), "bin", "start"]))
      end

    on_exit(fn -> :ok = :init.make_permanent(before, false) end)
    %{before: before}
  end

  test "a dev release made permanent leaves the node restarting on the boot it started with",
       %{tmp_dir: rel_dir, before: before} do
    # What `release_handler:make_permanent/1` does to `init` before `keep_boot/1` runs.
    release_boot = String.to_charlist(Path.join([rel_dir, "0.0.1-dev.1", "start"]))
    :ok = :init.make_permanent(release_boot, false)

    Dev.keep_boot(rel_dir)

    assert {:ok, [[boot | _] | _]} = :init.get_argument(:boot)
    refute boot == release_boot

    # The test VM, like `mix hal_c2.server`, started on OTP's own boot script.
    assert boot == before
  end
end
