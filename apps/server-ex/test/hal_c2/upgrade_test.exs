defmodule HalC2.UpgradeTest do
  use ExUnit.Case, async: false

  alias HalC2.Upgrade
  alias HalC2.Upgrade.Source

  @moduletag :tmp_dir

  @manifest %{
    "version" => "2.0.0",
    "otpRelease" => "29",
    "erts" => "17.0.5",
    "platform" => "darwin-arm64",
    "applications" => %{"hal_c2" => "2.0.0", "kernel" => "11.0.3", "exqlite" => "0.41.0"},
    "code" => ["hal_c2"],
    "dependencies" => %{"exqlite" => "0.41.0"},
    "packages" => "p",
    "config" => "c"
  }

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    # The tests load several versions of the same module.
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, false) end)
    :ok
  end

  # A bundle holding `modules` ({new source, running source}) compiled into
  # lib/hal_c2-2.0.0/ebin; the running version stays loaded.
  defp bundle(dir, manifest, modules) do
    root = Path.join(dir, "bundle")
    ebin = Path.join([root, "lib", "hal_c2-2.0.0", "ebin"])
    rel = Path.join([root, "releases", manifest["version"]])
    File.mkdir_p!(ebin)
    File.mkdir_p!(rel)
    File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))

    for {source, running} <- modules do
      for {mod, bin} <- Code.compile_string(source),
          do: File.write!(Path.join(ebin, "#{mod}.beam"), bin)

      Code.compile_string(running)
    end

    root
  end

  test "a change to plain modules loads in place; a supervisor or runtime change restarts",
       %{tmp_dir: dir} do
    running_plain = "defmodule HalC2.UpgradeTest.Plain do def v, do: 1 end"

    running_tree =
      "defmodule HalC2.UpgradeTest.Tree do use Supervisor; def init(_), do: Supervisor.init([], strategy: :one_for_one) end"

    Code.compile_string(running_plain)
    Code.compile_string(running_tree)

    plain = {"defmodule HalC2.UpgradeTest.Plain do def v, do: 2 end", running_plain}

    assert {:hot, [HalC2.UpgradeTest.Plain]} =
             Upgrade.plan(bundle(dir, @manifest, [plain]), @manifest)

    File.rm_rf!(Path.join(dir, "bundle"))

    tree =
      {"defmodule HalC2.UpgradeTest.Tree do use Supervisor; def init(_), do: Supervisor.init([{Task, fn -> :ok end}], strategy: :one_for_one) end",
       running_tree}

    assert {:restart, [reason]} = Upgrade.plan(bundle(dir, @manifest, [plain, tree]), @manifest)
    assert reason =~ "HalC2.UpgradeTest.Tree supervises processes"

    File.rm_rf!(Path.join(dir, "bundle"))
    # Another patch of Erlang, or another platform, built it: its code loads all the same.
    elsewhere = Map.merge(@manifest, %{"erts" => "17.0.6", "platform" => "linux-x64"})

    assert {:hot, [HalC2.UpgradeTest.Plain]} =
             Upgrade.plan(bundle(dir, elsewhere, [plain]), @manifest)

    File.rm_rf!(Path.join(dir, "bundle"))
    dependency = Map.put(@manifest, "dependencies", %{"exqlite" => "0.42.0"})
    assert {:restart, [reason]} = Upgrade.plan(bundle(dir, dependency, [plain]), @manifest)
    assert reason =~ "exqlite"

    assert {:restart, ["the running release has no upgrade manifest"]} =
             Upgrade.plan(Path.join(dir, "bundle"), nil)
  end

  test "an MC run from a checkout does not install versions" do
    start_supervised!(Upgrade)

    assert {:error, %{"_tag" => "ServerSelfUpdateError", "reason" => reason}} =
             Upgrade.update(%{"targetVersion" => "9.9.9"})

    assert reason =~ "mix hal_c2.upgrade"
    assert Upgrade.capability() == nil
  end

  test "a bundle arrives in pieces, is checked, and is offered to peers once", %{tmp_dir: dir} do
    archive = Path.join(dir, "b.tar.gz")
    File.write!(archive, :crypto.strong_rand_bytes(600_000))
    sum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    :ok = Source.receive_part("2.0.0", "darwin-arm64", :begin)

    archive
    |> File.stream!(256 * 1024)
    |> Enum.each(&(:ok = Source.receive_part("2.0.0", "darwin-arm64", {:chunk, &1})))

    assert :ok = Source.receive_part("2.0.0", "darwin-arm64", {:finish, sum})

    assert %{"sha256" => ^sum, "path" => "/api/upgrade/" <> token} =
             Source.offer("2.0.0", "darwin-arm64")

    assert {:ok, path} = Source.take(token)
    assert File.read!(path) == File.read!(archive)
    # A link works once.
    assert Source.take(token) == :error

    :ok = Source.receive_part("2.0.0", "darwin-arm64", :begin)
    :ok = Source.receive_part("2.0.0", "darwin-arm64", {:chunk, "damaged"})
    assert {:error, _} = Source.receive_part("2.0.0", "darwin-arm64", {:finish, sum})
  end

  test "a code-only version's release is the running one with the bundle's own code", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "release")
    bundle = Path.join(dir, "bundle")

    running =
      Map.put(@manifest, "version", "1.0.0") |> put_in(["applications", "hal_c2"], "1.0.0")

    # Built elsewhere: none of its runtime, platform or dependencies is taken.
    target =
      Map.merge(@manifest, %{
        "erts" => "17.0.6",
        "platform" => "linux-x64",
        "applications" => %{"hal_c2" => "2.0.0", "kernel" => "11.0.4"}
      })

    app = fn vsn, modules ->
      {:application, :hal_c2, [vsn: String.to_charlist(vsn), modules: modules]}
    end

    script =
      {:script, {~c"hal_c2", ~c"1.0.0"},
       [
         {:path, [~c"$ROOT/lib/kernel-11.0.3/ebin"]},
         {:primLoad, [:kernel]},
         {:path,
          [~c"$RELEASE_LIB/../releases/1.0.0/consolidated", ~c"$RELEASE_LIB/hal_c2-1.0.0/ebin"]},
         {:primLoad, [:"Elixir.HalC2.Old"]},
         {:apply, {:application, :load, [{:application, :kernel, [vsn: ~c"11.0.3"]}]}},
         {:apply, {:application, :load, [app.("1.0.0", [:"Elixir.HalC2.Old"])]}}
       ]}

    old_lib = Path.join([root, "lib", "hal_c2-1.0.0"])
    File.mkdir_p!(Path.join(old_lib, "priv/cursor-acp/node_modules"))
    File.write!(Path.join(old_lib, "priv/cursor-acp/node_modules/native"), "this platform's")
    old_rel = Path.join([root, "releases", "1.0.0"])
    File.mkdir_p!(Path.join(old_rel, "consolidated"))
    File.write!(Path.join(old_rel, "start.boot"), :erlang.term_to_binary(script))
    File.write!(Path.join(old_rel, "sys.config"), ~s([{a, "/releases/1.0.0/runtime.exs"}].\n))

    File.write!(
      Path.join(old_rel, "hal_c2.rel"),
      :io_lib.format("~p.~n", [
        {:release, {~c"hal_c2", ~c"1.0.0"}, {:erts, ~c"17.0.5"},
         [{:kernel, ~c"11.0.3"}, {:hal_c2, ~c"1.0.0", :permanent}]}
      ])
    )

    new_lib = Path.join([bundle, "lib", "hal_c2-2.0.0"])
    File.mkdir_p!(Path.join(new_lib, "ebin"))
    File.mkdir_p!(Path.join(new_lib, "priv/cursor-acp/node_modules"))
    File.write!(Path.join(new_lib, "priv/cursor-acp/node_modules/native"), "another platform's")
    modules = [:"Elixir.HalC2.Old", :"Elixir.HalC2.New"]

    File.write!(
      Path.join(new_lib, "ebin/hal_c2.app"),
      :io_lib.format("~p.~n", [app.("2.0.0", modules)])
    )

    File.mkdir_p!(Path.join([bundle, "releases", "2.0.0", "consolidated"]))
    File.write!(Path.join([bundle, "releases", "2.0.0", "consolidated", "P.beam"]), "new")

    assert :ok = Upgrade.Code.install(bundle, root, running, target)

    new_rel = Path.join([root, "releases", "2.0.0"])

    assert {:script, {~c"hal_c2", ~c"2.0.0"},
            [
              {:path, [~c"$ROOT/lib/kernel-11.0.3/ebin"]},
              {:primLoad, [:kernel]},
              {:path,
               [
                 ~c"$RELEASE_LIB/../releases/2.0.0/consolidated",
                 ~c"$RELEASE_LIB/hal_c2-2.0.0/ebin"
               ]},
              {:primLoad, ^modules},
              {:apply, {:application, :load, [{:application, :kernel, [vsn: ~c"11.0.3"]}]}},
              {:apply, {:application, :load, [loaded]}}
            ]} = Path.join(new_rel, "start.boot") |> File.read!() |> :erlang.binary_to_term()

    assert loaded == app.("2.0.0", modules)

    assert {:ok, [{:script, {_, ~c"2.0.0"}, _}]} =
             :file.consult(Path.join(new_rel, "start.script"))

    assert {:ok,
            [
              {:release, {~c"hal_c2", ~c"2.0.0"}, {:erts, ~c"17.0.5"},
               [{:kernel, ~c"11.0.3"}, {:hal_c2, ~c"2.0.0", :permanent}]}
            ]} = :file.consult(Path.join(new_rel, "hal_c2.rel"))

    assert File.read!(Path.join(new_rel, "sys.config")) =~ "/releases/2.0.0/runtime.exs"
    assert File.read!(Path.join(new_rel, "consolidated/P.beam")) == "new"

    assert File.read!(
             Path.join([root, "lib", "hal_c2-2.0.0", "priv/cursor-acp/node_modules/native"])
           ) ==
             "this platform's"

    assert %{
             "version" => "2.0.0",
             "erts" => "17.0.5",
             "platform" => "darwin-arm64",
             "applications" => %{"hal_c2" => "2.0.0", "kernel" => "11.0.3", "exqlite" => "0.41.0"}
           } = JSON.decode!(File.read!(Path.join(new_rel, "upgrade.json")))
  end

  test "a socket opened before an upgrade keeps its subscriptions" do
    # Its state as the previous version kept it: one id per watched config.
    old = %{
      session: nil,
      subs: %{1 => {:config, node()}},
      by_stream: %{},
      by_terminal: %{{:settings, node()} => 1},
      buffers: %{},
      item_types: %{},
      flush_scheduled: false
    }

    assert {:push, [{:text, frame}], state} =
             HalC2.Web.Socket.handle_info({:hal_c2_keybindings, node(), []}, old)

    assert %{"t" => "config.keybindings", "id" => 1} = JSON.decode!(IO.iodata_to_binary(frame))
    assert state.v == 5
    assert state.scopes == :all
    refute Map.has_key?(state, :item_types)
    assert state.by_terminal[{:settings, node()}] == [1]
    assert state.monitors == %{}
    assert state.shell == %{}
  end
end
