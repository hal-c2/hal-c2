defmodule HalC2.Codex.HomeTest do
  # Where a managed Codex instance runs: its own shadow home, over the home its
  # settings name, never the folder an instance `CODEX_HOME` points at.
  use ExUnit.Case, async: false

  alias HalC2.Codex.{ChatGpt, Home}
  alias HalC2.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, Path.join(dir, "mc"))
    on_exit(fn -> Application.delete_env(:hal_c2, :home) end)
    start_supervised!(Settings)
    :ok
  end

  defp put_instance(config, cli_home) do
    {:ok, _} =
      Settings.put(
        %{
          "providerInstances" => %{
            "codex-work" => %{
              "driver" => "codex",
              "config" => config,
              "environment" => [%{"name" => "CODEX_HOME", "value" => cli_home}]
            }
          }
        },
        0
      )
  end

  test "a managed instance with its own CODEX_HOME signs in in its shadow, over that home",
       %{tmp_dir: dir} do
    cli_home = Path.join(dir, "cli-codex")
    File.mkdir_p!(Path.join(cli_home, "sessions"))
    File.write!(Path.join(cli_home, "auth.json"), "{\"cli\":true}")
    put_instance(%{"setupMode" => "managed"}, cli_home)

    shadow = ChatGpt.home("codex-work")
    assert {:ok, [{"CODEX_HOME", ^shadow}]} = Home.env("codex-work")
    # The shadow shares the CLI home's sessions, but not its login.
    assert {:ok, target} = :file.read_link_all(Path.join(shadow, "sessions"))
    assert to_string(target) == Path.join(cli_home, "sessions")
    refute File.exists?(Path.join(shadow, "auth.json"))
    # Codex gets no CODEX_HOME of the instance's to put over the shadow's.
    refute List.keymember?(Home.instance_env("codex-work"), "CODEX_HOME", 0)
  end

  test "a managed instance signs in in the MC's home even with a shadowHomePath set",
       %{tmp_dir: dir} do
    cli_home = Path.join(dir, "cli-codex")

    put_instance(
      %{"setupMode" => "managed", "shadowHomePath" => Path.join(dir, "old-shadow")},
      cli_home
    )

    # The home `ChatGpt.adopt/3` and `move/1` read and write.
    managed = ChatGpt.home("codex-work")
    assert {:ok, [{"CODEX_HOME", ^managed}]} = Home.env("codex-work")
    refute File.exists?(Path.join(dir, "old-shadow"))
    refute List.keymember?(Home.instance_env("codex-work"), "CODEX_HOME", 0)
  end

  test "an instance on the CLI's login keeps its CODEX_HOME", %{tmp_dir: dir} do
    cli_home = Path.join(dir, "cli-codex")
    put_instance(%{}, cli_home)

    assert {:ok, []} = Home.env("codex-work")
    assert [{"CODEX_HOME", ^cli_home}] = Home.instance_env("codex-work")
  end

  # Regression: `ChatGpt.home/1` raised from `env/1` when the secrets directory could
  # not be made, instead of answering the error a start refuses with.
  test "a managed instance whose secrets directory cannot be made is an error, not a raise",
       %{tmp_dir: dir} do
    put_instance(%{"setupMode" => "managed"}, Path.join(dir, "cli-codex"))
    File.mkdir_p!(HalC2.Paths.data_dir())
    File.write!(Path.join(HalC2.Paths.data_dir(), "secrets"), "not a directory")

    assert {:error, "Codex shadow home could not be prepared: " <> _} = Home.env("codex-work")
  end
end
