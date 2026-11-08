defmodule HalC2.CodexHomePropTest do
  @moduledoc """
  `HalC2.Codex.Home.env/1` over generated shadow-home layouts: whatever a
  shadow home already holds, preparation either refuses it (a linked login) or
  leaves every shared entry a link to the shared home's, with the exceptions
  that are the account's own (its login, its login lock, and writer locks a
  thread still holds). Preparing twice changes nothing the second time.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Codex.Home
  alias HalC2.Settings

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  property "a shadow home joins the shared home's entries and keeps its own",
    numtests: HalC2.Prop.numtests(100) do
    forall layout <- layout() do
      trap_exit do
        home = HalC2.Prop.scratch_home("codex-home")
        HalC2.Prop.start_services([Settings])
        shared = Path.join(home, "shared")
        shadow = Path.join(home, "shadow")

        {:ok, _} =
          Settings.update(fn settings ->
            put_in(settings, [Access.key("providers", %{}), "codex"], %{
              "homePath" => shared,
              "shadowHomePath" => shadow
            })
          end)

        build(shared, shadow, layout)

        first = Home.env("codex")
        second = Home.env("codex")

        result = check(shared, shadow, layout, first, second)

        HalC2.Prop.stop_services()
        File.rm_rf!(home)

        result
        |> when_fail(IO.inspect({layout, first, second}, label: "codex home layout"))
      end
    end
  end

  # --- generators --------------------------------------------------------------

  defp layout do
    let {locks, auth_lock, sqlite, ds_store, auth} <-
          {oneof([:absent, :empty, :locked, :linked]), oneof([:absent, :file, :linked]),
           oneof([:absent, :shadow_only, :both]), boolean(), oneof([:absent, :file, :linked])} do
      %{locks: locks, auth_lock: auth_lock, sqlite: sqlite, ds_store: ds_store, auth: auth}
    end
  end

  # --- the layout on disk --------------------------------------------------------

  defp build(shared, shadow, layout) do
    File.mkdir_p!(Path.join(shared, "sessions"))
    File.mkdir_p!(shadow)
    File.write!(Path.join(shared, "config.toml"), "shared config")
    File.write!(Path.join(shared, "auth.json"), "{}")

    case layout.locks do
      :absent ->
        :ok

      :empty ->
        File.mkdir_p!(Path.join(shadow, "thread-writer-locks"))

      :locked ->
        File.mkdir_p!(Path.join(shadow, "thread-writer-locks"))
        File.write!(Path.join([shadow, "thread-writer-locks", "native-1.lock"]), "")

      :linked ->
        File.mkdir_p!(Path.join(shared, "thread-writer-locks"))

        File.ln_s!(
          Path.join(shared, "thread-writer-locks"),
          Path.join(shadow, "thread-writer-locks")
        )
    end

    case layout.auth_lock do
      :absent ->
        :ok

      :file ->
        File.write!(Path.join(shadow, "auth.lock"), "")

      :linked ->
        File.write!(Path.join(shared, "auth.lock"), "")
        File.ln_s!(Path.join(shared, "auth.lock"), Path.join(shadow, "auth.lock"))
    end

    case layout.sqlite do
      :absent ->
        :ok

      :shadow_only ->
        File.write!(Path.join(shadow, ".sqlite-maintenance.lock"), "mine")

      :both ->
        File.write!(Path.join(shared, ".sqlite-maintenance.lock"), "shared")
        File.write!(Path.join(shadow, ".sqlite-maintenance.lock"), "mine")
    end

    if layout.ds_store, do: File.write!(Path.join(shadow, ".DS_Store"), "finder")

    case layout.auth do
      :absent -> :ok
      :file -> File.write!(Path.join(shadow, "auth.json"), "{}")
      :linked -> File.ln_s!(Path.join(shared, "auth.json"), Path.join(shadow, "auth.json"))
    end
  end

  # --- the promise -----------------------------------------------------------------

  defp check(_shared, _shadow, %{auth: :linked}, first, second) do
    match?({:error, _}, first) and match?({:error, _}, second)
  end

  defp check(shared, shadow, layout, first, second) do
    link = fn name -> File.read_link(Path.join(shadow, name)) end
    linked = fn name -> link.(name) == {:ok, Path.join(shared, name)} end
    symlink? = fn name -> match?({:ok, _}, link.(name)) end

    locks =
      if layout.locks == :locked do
        File.exists?(Path.join([shadow, "thread-writer-locks", "native-1.lock"])) and
          not symlink?.("thread-writer-locks")
      else
        linked.("thread-writer-locks")
      end

    sqlite =
      case layout.sqlite do
        :both -> linked.(".sqlite-maintenance.lock")
        :shadow_only -> not symlink?.(".sqlite-maintenance.lock")
        :absent -> true
      end

    match?({:ok, [{"CODEX_HOME", ^shadow}]}, first) and
      match?({:ok, [{"CODEX_HOME", ^shadow}]}, second) and
      linked.("config.toml") and linked.("sessions") and locks and sqlite and
      not symlink?.("auth.lock") and not symlink?.("auth.json")
  end
end
