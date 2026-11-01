defmodule HalC2.Steps.Platform.TemporaryFiles do
  @moduledoc "Steps for features/mc/platform/temporary-files.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Paths, ProjectEnvironment, Scratch}
  alias HalC2.Test.Mc.World

  @names ~w(TMPDIR TMP TEMP CLAUDE_CODE_TMPDIR)

  # Stands for the thread of a launch: what every adapter hands `for_turn/3`.
  defp launch(context, title, env \\ []) do
    id = World.thread_id(context, title)
    ProjectEnvironment.for_turn(%{ids: %{thread: id}}, env, [])
  end

  defp folder(context, title), do: Scratch.thread_dir(World.thread_id(context, title))

  defp set_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.to_iso8601()
  end

  defp backdate(context, title, days) do
    at = ago(days)

    World.patch_thread(context, title, %{
      "createdAt" => at,
      "latestUserMessageAt" => at,
      "latestRunRequestedAt" => at,
      "latestRunStartedAt" => at,
      "latestRunCompletedAt" => at
    })
  end

  step "a thread {string}", %{args: [title]} = context do
    World.create_thread(context, title)
  end

  step "a thread {string} with a temp folder holding a file", %{args: [title]} = context do
    context = World.create_thread(context, title)
    launch(context, title)
    File.write!(Path.join(folder(context, title), "kept"), "x")
    context
  end

  step "an agent session of {string} is launched", %{args: [title]} = context do
    Map.put(context, :launch, launch(context, title))
  end

  step "its temporary file variables all name the folder of {string}",
       %{args: [title]} = context do
    dir = folder(context, title)
    for name <- @names, do: assert(List.keyfind(context.launch, name, 0) == {name, dir})
    context
  end

  step "that folder exists and only the user can read it", context do
    {_, dir} = List.keyfind(context.launch, "TMPDIR", 0)
    assert %File.Stat{type: :directory, mode: mode} = File.stat!(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    context
  end

  step "an agent session of {string} is launched with TMPDIR set by its provider instance",
       %{args: [title]} = context do
    Map.put(context, :launch, launch(context, title, [{"TMPDIR", "/instance/tmp"}]))
  end

  step "its TMPDIR is the one the provider instance set", context do
    assert List.keyfind(context.launch, "TMPDIR", 0) == {"TMPDIR", "/instance/tmp"}
    context
  end

  step "the MC cannot write to its temporary files location", context do
    file = Path.join(Paths.data_dir(), "not-a-folder")
    File.write!(file, "")
    set_env("HAL_C2_TMPDIR", file)
    context
  end

  step "its temporary file variables are inside the MC's cache directory", context do
    {_, dir} = List.keyfind(context.launch, "TMPDIR", 0)
    assert String.starts_with?(dir, Paths.cache_dir() <> "/")
    context
  end

  step "the MC makes a temporary folder of its own", context do
    Map.put(context, :made, Scratch.dir("hal-c2-step"))
  end

  step "the folder is inside the MC's cache directory", context do
    assert String.starts_with?(context.made, Paths.cache_dir() <> "/")
    context
  end

  step "HAL_C2_TMPDIR names a folder on another disk", context do
    dir = Path.join(Paths.data_dir(), "other-disk")
    set_env("HAL_C2_TMPDIR", dir)
    Map.put(context, :other_disk, dir)
  end

  step "the folder is inside the one HAL_C2_TMPDIR names", context do
    assert String.starts_with?(context.made, context.other_disk <> "/")
    context
  end

  step "two MCs with different homes keep their temporary files apart", context do
    one = Paths.scratch_dir()
    home = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, Path.join(context.other_disk, "another-home"))

    try do
      assert one != Paths.scratch_dir()
    after
      Application.put_env(:hal_c2, :home, home)
    end

    context
  end

  step "HAL_C2_TMPDIR is {string}", %{args: [value]} = context do
    set_env("HAL_C2_TMPDIR", value)
    context
  end

  step "{string} has been idle for 8 days", %{args: [title]} = context do
    backdate(context, title, 8)
    context
  end

  step "{string} was active yesterday", %{args: [title]} = context do
    backdate(context, title, 1)
    context
  end

  step "{string} has been idle for 8 days but has a run", %{args: [title]} = context do
    backdate(context, title, 8)
    World.add_run(context, title, "running", ago(8))
    context
  end

  step "the temp folder of {string} is gone", %{args: [title]} = context do
    refute File.exists?(folder(context, title))
    context
  end

  step "the temp folder of {string} still holds its file", %{args: [title]} = context do
    assert File.exists?(Path.join(folder(context, title), "kept"))
    context
  end

  step "a folder the MC did not name sits beside it", context do
    dir = Path.join([Paths.scratch_dir(), "t", "not-a-key"])
    File.mkdir_p!(dir)
    Map.put(context, :foreign, dir)
  end

  step "that folder is still there", context do
    assert File.dir?(context.foreign)
    context
  end

  step "a temporary file an earlier MC left is still there", context do
    mine = Scratch.dir("hal-c2-using")
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    earlier = Path.join(Path.dirname(mine), "hal-c2-crash-#{String.trim(out)}-1")
    File.mkdir_p!(earlier)
    Map.put(context, :earlier, earlier)
  end

  step "a temporary file this MC is using", context do
    Map.put(context, :using, Scratch.dir("hal-c2-using"))
  end

  step "the earlier MC's file is gone", context do
    refute File.exists?(context.earlier)
    context
  end

  step "the file this MC is using is still there", context do
    assert File.dir?(context.using)
    context
  end

  step "the user chose a folder for temporary files", context do
    dir = Path.join(Paths.data_dir(), "chosen")
    World.merge_settings(%{"storageCleanup" => %{"temporaryFilesFolder" => dir}})
    Map.put(context, :chosen, dir)
  end

  step "the folder is inside the one the user chose", context do
    assert String.starts_with?(context.made, context.chosen <> "/")
    context
  end

  step "the user chooses a relative path for temporary files", context do
    Map.put(context, :refused, choose("relative/path"))
  end

  step "the user chooses a path under a file for temporary files", context do
    file = Path.join(Paths.data_dir(), "a-file")
    File.write!(file, "")
    Map.put(context, :refused, choose(Path.join(file, "below")))
  end

  step "the settings change is refused saying temporary files cannot go there", context do
    assert {:error, %{"_tag" => "ServerSettingsError", "message" => message}} = context.refused
    assert message =~ "Temporary files cannot go in"
    context
  end

  step "that folder can no longer be made", context do
    File.rm_rf!(context.chosen)
    File.write!(context.chosen, "")
    context
  end

  step "the user changes another setting", context do
    {settings, _} = HalC2.Settings.get()
    Map.put(context, :outcome, HalC2.Settings.validate(Map.put(settings, "theme", "dark")))
  end

  step "the settings change is accepted", context do
    assert context.outcome == :ok
    context
  end

  step "{string} has been idle for 31 days with the rule at 30", %{args: [title]} = context do
    backdate(context, title, 31)
    World.merge_settings(%{"storageCleanup" => %{"threadTempAfterDays" => 30}})
    context
  end

  step "the user turned off deleting idle threads' temporary files", context do
    World.merge_settings(%{"storageCleanup" => %{"threadTempAfterDays" => nil}})
    context
  end

  defp choose(folder) do
    {settings, _} = HalC2.Settings.get()

    settings
    |> Map.put("storageCleanup", %{"temporaryFilesFolder" => folder})
    |> HalC2.Settings.validate()
  end
end
