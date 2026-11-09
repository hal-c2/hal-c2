defmodule HalC2.CodexProviderEntryTest do
  # Each Codex instance is on its own account, so its entry lists its own models.
  use ExUnit.Case, async: false

  alias HalC2.Codex.Provider
  alias HalC2.Settings

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(Settings)

    on_exit(fn ->
      Provider.record_models("codex", nil)
      Provider.record_models("codex-work", nil)

      if previous == nil,
        do: Application.delete_env(:hal_c2, :home),
        else: Application.put_env(:hal_c2, :home, previous)
    end)

    codex = Path.join(dir, "codex")
    File.write!(codex, "#!/bin/sh\necho 'codex-cli 0.130.0'\n")
    File.chmod!(codex, 0o755)

    {_, version} = Settings.get()

    {:ok, _} =
      Settings.put(
        %{
          "providers" => %{"codex" => %{"binaryPath" => codex}},
          "providerInstances" => %{
            "codex-work" => %{"driver" => "codex", "config" => %{"binaryPath" => codex}}
          }
        },
        version
      )

    :ok
  end

  defp list(slug), do: [%{"slug" => slug, "name" => slug, "isDefault" => true}]
  defp slugs(id), do: for(m <- Provider.entry(id)["models"], do: m["slug"])

  # Regression: every instance's entry listed the built-in instance's models, so an
  # account's own tiers never reached the clients.
  test "an instance's entry lists the models its own check read" do
    Provider.record_models("codex", list("gpt-builtin"))
    Provider.record_models("codex-work", list("gpt-work"))

    assert slugs("codex") == ["gpt-builtin"]
    assert slugs("codex-work") == ["gpt-work"]
  end

  test "an instance not checked yet lists the built-in instance's models" do
    Provider.record_models("codex", list("gpt-builtin"))
    assert slugs("codex-work") == ["gpt-builtin"]
  end
end
