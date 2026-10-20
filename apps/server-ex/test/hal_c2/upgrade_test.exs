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

  test "putting a bundle again replaces the one unpacked for its version", %{tmp_dir: dir} do
    first = tarball(dir, "first", %{"version" => "2.0.0", "marker" => "first"})
    :ok = Source.put("2.0.0", "darwin-arm64", first)
    assert {:ok, unpacked} = Source.fetch("2.0.0", "darwin-arm64")
    assert Upgrade.manifest(unpacked)["marker"] == "first"

    # The same version built again: its unpacked bundle is stale now.
    second = tarball(dir, "second", %{"version" => "2.0.0", "marker" => "second"})
    :ok = Source.put("2.0.0", "darwin-arm64", second)
    assert {:ok, ^unpacked} = Source.fetch("2.0.0", "darwin-arm64")
    assert Upgrade.manifest(unpacked)["marker"] == "second"
  end

  test "a release reload names the installed MC by --root, else by the checkout's own home" do
    home = &Mix.Tasks.HalC2.Upgrade.installed_home(&1, &2, "/home/u")

    # A checkout's dev profile is not the installed MC's; a HAL_C2_MC_HOME is.
    assert home.(nil, :dev) == {:ok, nil}
    assert home.(nil, {:mc, "/srv/mc"}) == {:ok, {:mc, "/srv/mc"}}
    assert home.("/srv/hal-c2", {:mc, "/srv/mc"}) == {:ok, {:root, "/srv/hal-c2"}}

    # Roots `HalC2.Paths` would quietly trade for the user's profile.
    for root <- ["/home/u/.t3", "/home/u/.hal-c2", "/home/u/.t3/sub", "relative/dir", ""] do
      assert {:error, reason} = home.(root, :dev)
      assert reason =~ inspect(root)
    end
  end

  test "--root is refused, before any build, unless it comes with --release alone" do
    for args <- [
          ["--root", "/srv/hal-c2"],
          ["--root", "/srv/hal-c2", "--dev"],
          ["--root", "/srv/hal-c2", "hal_c2@host"],
          ["--root", "/srv/hal-c2", "--release", "hal_c2@host"]
        ] do
      assert_raise Mix.Error, ~r/use it with --release alone/, fn ->
        Mix.Tasks.HalC2.Upgrade.run(args)
      end
    end
  end

  test "a bundle replaced in the cache by any writer is unpacked again", %{tmp_dir: dir} do
    :ok =
      Source.put(
        "2.0.0",
        "darwin-arm64",
        tarball(dir, "first", %{"version" => "2.0.0", "marker" => "first"})
      )

    assert {:ok, unpacked} = Source.fetch("2.0.0", "darwin-arm64")

    # As a download from a peer or the release URL leaves it, or a put that stopped
    # after writing: the new archive and its checksum, the old unpack still beside them.
    second = tarball(dir, "second", %{"version" => "2.0.0", "marker" => "second"})
    archive = Path.join(Source.cache_dir("2.0.0"), Source.file_name("2.0.0", "darwin-arm64"))
    File.cp!(second, archive)
    sum = Base.encode16(:crypto.hash(:sha256, File.read!(second)), case: :lower)
    File.write!(archive <> ".sha256", sum)

    assert {:ok, ^unpacked} = Source.fetch("2.0.0", "darwin-arm64")
    assert Upgrade.manifest(unpacked)["marker"] == "second"
  end

  # A bundle archive whose manifest is `manifest`, packed as `mix hal_c2.bundle` does.
  defp tarball(dir, name, manifest) do
    archive = Path.join(dir, name <> ".tar.gz")
    entry = {~c"releases/#{manifest["version"]}/upgrade.json", JSON.encode!(manifest)}
    :ok = :erl_tar.create(String.to_charlist(archive), [entry], [:compressed])
    archive
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

  test "the step after a hot update is called by name, so the code that loads runs it" do
    # A local call stays in the module version making it, the one being replaced; a
    # call by name reaches the version the update just loaded.
    {:beam_file, HalC2.Upgrade, _, _, _, functions} =
      :beam_disasm.file(:code.which(HalC2.Upgrade))

    calls = fn kinds ->
      for {:function, name, arity, _, code} <- functions,
          Enum.any?(code, &hot_step?(&1, kinds)),
          do: {name, arity}
    end

    # The one path to the step, by name; none of them locally.
    assert Enum.sort(calls.([:call_ext, :call_ext_only, :call_ext_last])) ==
             [run_after_hot_update: 2]

    assert calls.([:call, :call_only, :call_last]) == []
    # `function_exported?/3` does not load the module, and no other test may have yet.
    Code.ensure_loaded!(HalC2.Upgrade)
    assert function_exported?(HalC2.Upgrade, :after_hot_update, 2)
  end

  test "a hot update to a version without the public hot step asks for a restart" do
    # The loaded copy predates the public step (a rollback): running the step must
    # not raise after the code swap, it asks for a restart instead.
    {HalC2.Upgrade, original, file} = :code.get_object_code(HalC2.Upgrade)

    try do
      load_beam(file, without_export(original, :after_hot_update, 2))
      refute function_exported?(HalC2.Upgrade, :after_hot_update, 2)
      assert HalC2.Upgrade.run_after_hot_update([], []) == [HalC2.Upgrade]
    after
      load_beam(file, original)
    end

    assert function_exported?(HalC2.Upgrade, :after_hot_update, 2)
  end

  test "the installed MC's record is found under a named root, and named when absent",
       %{tmp_dir: dir} do
    home = {:root, dir}

    assert {:error, reason} =
             Mix.Tasks.HalC2.Upgrade.installed_record(home, %{}, dir)

    assert reason =~ "No installed MC has run from"

    dirs = HalC2.Paths.mc_dirs(home, %{}, dir)
    File.mkdir_p!(dirs.state)
    File.mkdir_p!(dirs.data)
    File.write!(Path.join(dirs.state, "server-runtime.json"), ~s({"origin":"http://127.0.0.1:9"}))
    File.write!(Path.join(dirs.data, "access-token"), "tok\n")

    assert {:ok, "http://127.0.0.1:9", "tok"} =
             Mix.Tasks.HalC2.Upgrade.installed_record(home, %{}, dir)
  end

  # A copy of a beam with one function no longer exported, as a version built
  # before it went public would load.
  defp without_export(bin, name, arity) do
    {:ok, {mod, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bin, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, mod, data, [])

    forms =
      Enum.map(forms, fn
        {:attribute, line, :export, exports} ->
          {:attribute, line, :export, List.delete(exports, {name, arity})}

        form ->
          form
      end)

    {:ok, ^mod, beam} = :compile.forms(forms, [:binary, :debug_info])
    beam
  end

  defp load_beam(file, beam) do
    :code.purge(HalC2.Upgrade)
    {:module, HalC2.Upgrade} = :code.load_binary(HalC2.Upgrade, file, beam)
    :ok
  end

  # A call instruction of one of `kinds` to `after_hot_update/2`, by name or locally.
  defp hot_step?(instruction, kinds) when is_tuple(instruction) do
    steps = [
      {:extfunc, HalC2.Upgrade, :after_hot_update, 2},
      {HalC2.Upgrade, :after_hot_update, 2}
    ]

    elem(instruction, 0) in kinds and Enum.any?(Tuple.to_list(instruction), &(&1 in steps))
  end

  defp hot_step?(_instruction, _kinds), do: false

  test "a socket opened before an upgrade keeps its subscriptions" do
    # Its state as the previous version kept it: one id per watched config, and one
    # per followed stream.
    old = %{
      session: nil,
      subs: %{1 => {:config, node()}, 2 => {:stream, node(), "th-old"}},
      by_stream: %{"th-old" => 2},
      by_terminal: %{{:settings, node()} => 1},
      buffers: %{},
      item_types: %{},
      flush_scheduled: false
    }

    assert {:push, [{:text, frame}], state} =
             HalC2.Web.Socket.handle_info({:hal_c2_keybindings, node(), []}, old)

    assert %{"t" => "config.keybindings", "id" => 1} = JSON.decode!(IO.iodata_to_binary(frame))
    assert state.v == 6
    assert state.scopes == :all
    refute Map.has_key?(state, :item_types)
    assert state.by_terminal[{:settings, node()}] == [1]
    assert state.monitors == %{}
    assert state.shell == %{}
    # A stream followed before sends no tag.
    assert state.by_stream == %{"th-old" => {2, nil}}
  end

  test "a message without a tag is only for a stream followed before an upgrade" do
    tag = {node(), make_ref()}

    state = %{
      v: 6,
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

    # One still on its way from the subscription the upgrade carried over.
    assert {:ok, ^state} = HalC2.Web.Socket.handle_info({:hal_c2_stream, "th", :resync}, state)

    assert {:push, [{:text, frame}], _} =
             HalC2.Web.Socket.handle_info({:hal_c2_stream, {"th", tag}, :resync}, state)

    assert %{"t" => "resync", "id" => 2} = JSON.decode!(IO.iodata_to_binary(frame))

    # The subscription the upgrade carried over still hears it.
    old = %{state | by_stream: %{"th" => {2, nil}}}
    assert {:push, [_], _} = HalC2.Web.Socket.handle_info({:hal_c2_stream, "th", :resync}, old)
  end
end
