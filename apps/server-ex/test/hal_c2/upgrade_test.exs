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

  test "a release with no bundle of its version packs one of its own applications, once",
       %{tmp_dir: dir} do
    root = Path.join(dir, "release")

    staged = %{
      @manifest
      | "version" => "2.1.0",
        "erts" => "17.1",
        "applications" => %{"hal_c2" => "2.1.0"}
    }

    for manifest <- [@manifest, staged] do
      rel = Path.join([root, "releases", manifest["version"]])
      File.mkdir_p!(rel)
      File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))
    end

    # 2.0.0 runs, and 2.1.0 is staged for the next start.
    File.write!(Path.join([root, "releases", "start_erl.data"]), "17.1 2.1.0\n")

    # The applications of 2.0.0, one an earlier version left behind, and 2.1.0's.
    for app <- ~w(hal_c2-2.0.0 kernel-11.0.3 exqlite-0.41.0 hal_c2-1.9.0 hal_c2-2.1.0),
        do: File.mkdir_p!(Path.join([root, "lib", app, "ebin"]))

    for erts <- ~w(17.0.5 17.1), do: File.mkdir_p!(Path.join([root, "erts-#{erts}", "bin"]))
    System.put_env("RELEASE_ROOT", root)
    :persistent_term.put({Upgrade, :version}, "2.0.0")

    on_exit(fn ->
      System.delete_env("RELEASE_ROOT")
      :persistent_term.erase({Upgrade, :version})
    end)

    # Two `cluster.update`s at once pack it once and agree on it.
    assert [:ok, :ok] =
             1..2
             |> Enum.map(fn _ -> Task.async(fn -> Source.ensure_own("2.0.0") end) end)
             |> Task.await_many()

    archive =
      Path.join([Source.cache_dir("2.0.0"), Source.file_name("2.0.0", Upgrade.platform())])

    sum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    assert File.read!(archive <> ".sha256") == sum

    assert File.ls!(Source.cache_dir("2.0.0")) |> Enum.sort() ==
             Enum.sort([Path.basename(archive), Path.basename(archive) <> ".sha256"])

    {:ok, entries} = :erl_tar.table(String.to_charlist(archive), [:compressed])

    dirs =
      entries
      |> Enum.map(&to_string/1)
      |> Enum.map(&(&1 |> Path.split() |> Enum.take(2) |> Path.join()))
      |> Enum.uniq()

    assert "lib/hal_c2-2.0.0" in dirs and "lib/kernel-11.0.3" in dirs and
             "erts-17.0.5/bin" in dirs

    assert "releases/2.0.0" in dirs
    refute "lib/hal_c2-1.9.0" in dirs
    refute "lib/hal_c2-2.1.0" in dirs or "releases/2.1.0" in dirs or "erts-17.1/bin" in dirs
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
    File.mkdir_p!(Path.join(old_lib, "priv/bin"))
    File.write!(Path.join(old_lib, "priv/bin/hal-c2-machine-files"), "this platform's helper")
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
    # Built on macOS, the bundle has no machine-files helper and no `priv/bin` for it.
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

    assert File.read!(Path.join([root, "lib", "hal_c2-2.0.0", "priv/bin/hal-c2-machine-files"])) ==
             "this platform's helper"

    assert %{
             "version" => "2.0.0",
             "erts" => "17.0.5",
             "platform" => "darwin-arm64",
             "applications" => %{"hal_c2" => "2.0.0", "kernel" => "11.0.3", "exqlite" => "0.41.0"}
           } = JSON.decode!(File.read!(Path.join(new_rel, "upgrade.json")))
  end

  test "a socket opened before an upgrade keeps its subscriptions" do
    # Its state as the previous version kept it: one id per watched config, one
    # per followed stream, and one id per followed terminal.
    old = %{
      session: nil,
      subs: %{
        1 => {:config, node()},
        2 => {:stream, node(), "th-old"},
        3 => {:terminal, node(), {"th-old", "term-1"}}
      },
      by_stream: %{"th-old" => 2},
      by_terminal: %{{:settings, node()} => 1, {"th-old", "term-1"} => 3},
      buffers: %{},
      item_types: %{},
      flush_scheduled: false
    }

    assert {:push, [{:text, frame}], state} =
             HalC2.Web.Socket.handle_info({:hal_c2_keybindings, node(), []}, old)

    assert %{"t" => "config.keybindings", "id" => 1} = JSON.decode!(IO.iodata_to_binary(frame))
    assert state.v == 8
    assert state.scopes == :all
    refute Map.has_key?(state, :item_types)
    assert state.by_terminal[{:settings, node()}] == %{1 => nil}
    # A terminal followed before has no snapshot sequence recorded, so it is
    # held per subscription with a nil floor and is told everything, as it was.
    assert state.by_terminal[{"th-old", "term-1"}] == %{3 => nil}
    assert state.subs[3] == {:terminal, node(), {"th-old", "term-1"}}
    assert state.monitors == %{}
    assert state.shell == %{}
    # A stream followed before sends no tag.
    assert state.by_stream == %{"th-old" => {2, nil}}

    # The migrated terminal subscription still receives its terminal's events
    # under its own id.
    assert {:push, [{:text, frame}], _state} =
             HalC2.Web.Socket.handle_info(
               {:hal_c2_terminal, {"th-old", "term-1"},
                %{"type" => "output", "data" => "hi", "sequence" => 1}},
               state
             )

    assert %{"t" => "terminal", "id" => 3} = JSON.decode!(IO.iodata_to_binary(frame))
  end

  test "a v6 socket's terminal subscription migrates to per-subscription state" do
    # The exact v6 shape: a terminal is held as a single subscription id, while
    # a watched config is already a list of ids. This socket followed the
    # terminal twice (2, then 3 recorded last in v6's single slot as 2 went
    # in — the overwrite v7 fixes), and rebuilding from `subs` revives both.
    state = %{
      v: 6,
      session: nil,
      scopes: :all,
      subs: %{
        1 => {:config, node()},
        2 => {:terminal, node(), {"th-6", "term-1"}},
        3 => {:terminal, node(), {"th-6", "term-1"}}
      },
      by_stream: %{},
      by_terminal: %{{"th-6", "term-1"} => 2, {:settings, node()} => [1]},
      monitors: %{},
      shell: %{},
      buffers: %{},
      flush_scheduled: false
    }

    assert {:push, [{:text, frame}], migrated} =
             HalC2.Web.Socket.handle_info({:hal_c2_keybindings, node(), []}, state)

    assert %{"t" => "config.keybindings", "id" => 1} = JSON.decode!(IO.iodata_to_binary(frame))
    assert migrated.v == 8
    assert migrated.subs == state.subs
    # The terminal entry holds both subscriptions `subs` held; the config entry
    # holds its one by id too, with no watch ref of its own (v8).
    assert migrated.by_terminal == %{
             {"th-6", "term-1"} => %{2 => nil, 3 => nil},
             {:settings, node()} => %{1 => nil}
           }

    # With a nil floor each migrated subscription is told everything that
    # follows, under its own id.
    assert {:push, frames, _} =
             HalC2.Web.Socket.handle_info(
               {:hal_c2_terminal, {"th-6", "term-1"},
                %{"type" => "output", "data" => "hi", "sequence" => 9}},
               migrated
             )

    ids =
      for {:text, frame} <- frames,
          do: frame |> IO.iodata_to_binary() |> JSON.decode!() |> Map.fetch!("id")

    assert Enum.sort(ids) == [2, 3]
  end

  test "config subscriptions an upgrade carried over keep their one watch until the last goes" do
    # Stands in for HalC2.Settings: says which unwatches reach it.
    test = self()

    settings =
      spawn_link(fn ->
        Process.register(self(), HalC2.Settings)
        send(test, :registered)

        Stream.repeatedly(fn ->
          receive do: ({:"$gen_cast", {:unwatch, _pid, ref}} -> send(test, {:unwatched, ref}))
        end)
        |> Stream.run()
      end)

    assert_receive :registered
    on_exit(fn -> Process.exit(settings, :kill) end)

    # Two pages showing settings on a socket from before refs, which shared one watch.
    old = %{
      v: 6,
      session: nil,
      scopes: :all,
      subs: %{1 => {:config, node()}, 2 => {:config, node()}},
      by_stream: %{},
      by_terminal: %{{:settings, node()} => [1, 2]},
      monitors: %{},
      shell: %{},
      buffers: %{},
      flush_scheduled: false
    }

    unsub = fn id, state ->
      {:ok, state} =
        HalC2.Web.Socket.handle_in({~s({"t":"unsub","id":#{id}}), [opcode: :text]}, state)

      state
    end

    state = unsub.(1, old)
    assert state.by_terminal[{:settings, node()}] == %{2 => nil}
    # Only how long the unwatch a bug would send is looked for.
    refute_receive {:unwatched, _}, 200

    state = unsub.(2, state)
    refute Map.has_key?(state.by_terminal, {:settings, node()})
    assert_receive {:unwatched, nil}
  end

  test "a message without a tag is only for a stream followed before an upgrade" do
    tag = {node(), make_ref()}

    state = %{
      v: 7,
      session: nil,
      scopes: :all,
      subs: %{2 => {:stream, node(), "th"}},
      by_stream: %{"th" => {2, tag}},
      by_terminal: %{},
      monitors: %{},
      shell: %{},
      buffers: %{2 => %{events: [], bytes: 0, replay: false}},
      flush_scheduled: false
    }

    # One still on its way from the subscription the upgrade carried over. The
    # v7 state is first migrated to v8, so the returned state is that migration.
    migrated = %{state | v: 8}
    assert {:ok, ^migrated} = HalC2.Web.Socket.handle_info({:hal_c2_stream, "th", :resync}, state)

    assert {:push, [{:text, frame}], _} =
             HalC2.Web.Socket.handle_info({:hal_c2_stream, {"th", tag}, :resync}, state)

    assert %{"t" => "resync", "id" => 2} = JSON.decode!(IO.iodata_to_binary(frame))

    # The subscription the upgrade carried over still hears it.
    old = %{state | by_stream: %{"th" => {2, nil}}}
    assert {:push, [_], _} = HalC2.Web.Socket.handle_info({:hal_c2_stream, "th", :resync}, old)
  end
end
