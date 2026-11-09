defmodule HalC2.Steps.Providers.CodexManaged do
  @moduledoc """
  Steps for the managed Codex installation in `features/providers/codex.feature`
  (`HalC2.Codex.Installation`). A Codex package is a tree of shell wrappers around
  `fake_codex.py` laid out as OpenAI's are, placed in the scratch home's cache or
  served as a `.tar.gz` by `HalC2.Test.FakeHttp`. Each wrapper appends its version
  to `starts.log` when it starts an app-server, so a scenario sees which Codex a
  thread runs. Nothing reaches the network.
  """
  use Cucumber.StepDefinition

  import ExUnit.Assertions

  alias HalC2.Codex.Installation
  alias HalC2.Test.{FakeHttp, Mc}
  alias HalC2.Test.Mc.World

  @pinned "0.166.0"
  @old "0.165.0"
  @target "x86_64-unknown-linux-musl"

  # --- Code Mode host on the path ------------------------------------------------------

  step ~s(the codex command on the MC's path has no "codex-code-mode-host" beside it),
       context do
    context |> World.fake_providers() |> bare_codex() |> place(@old)
  end

  step "the MC picks the Codex to run", context do
    {providers, context} = World.provider_list(context)
    Map.merge(context, %{picked: Installation.command("codex"), providers: providers})
  end

  step "it runs the managed Codex installation instead", context do
    managed = Path.join([Installation.managed_dir(), @old, "bin", "codex"])
    assert context.picked == [managed, "app-server"]
    assert Enum.find(context.providers, &(&1["instanceId"] == "codex"))["version"] == @old

    # With its host beside it, the same command runs as it is.
    File.write!(Path.join(Path.dirname(context.bare), "codex-code-mode-host"), "host")
    File.chmod!(Path.join(Path.dirname(context.bare), "codex-code-mode-host"), 0o755)
    assert Installation.command("codex") == ["codex", "app-server"]
    context
  end

  # --- a download that fails over the network -----------------------------------------

  step "the MC is installing its managed Codex", context do
    context |> World.fake_providers() |> bare_codex() |> serve()
  end

  step ~r/^the download (?<failure>is cut off part way|is answered with HTTP 404|is still running at 45 minutes)$/,
       %{args: [failure]} = context do
    mode =
      case failure do
        "is cut off part way" ->
          :cut

        "is answered with HTTP 404" ->
          :not_found

        "is still running at 45 minutes" ->
          # The 45-minute bound, reached at once.
          World.put_app_env(:codex_download_timeout_ms, 0)
          :hang
      end

    Agent.update(context.mode, fn _ -> mode end)
    Mc.ensure(Installation)
    context = watch(context)
    {_, context} = World.call!(context, "provider.install.start", %{"instanceId" => "codex"})
    {states, context} = collect(context, &(&1["phase"] in ["failed", "succeeded"]))
    Map.put(context, :install_states, states)
  end

  step "the installation fails asking the user to check their internet connection", context do
    final = List.last(context.install_states)
    assert final["phase"] == "failed"
    assert final["message"] =~ "Check your internet connection"
    assert Installation.active() == :none
    context
  end

  step "the user is not told to check disk space", context do
    refute List.last(context.install_states)["message"] =~ ~r/disk/i
    context
  end

  # --- a pin raised over an installed Codex -------------------------------------------
  # "the MC starts" (common_steps.exs) restarts the MC, whose installer comes back with
  # the services a step started.

  step "the managed Codex installed is older than the version the MC pins", context do
    # `agents/1` first: a message sent later would otherwise put the plain fake back.
    context = context |> World.fake_providers() |> World.agents() |> bare_codex() |> serve()
    Agent.update(context.mode, fn _ -> :gate end)
    # Running before the older Codex is placed, so nothing updates until the MC starts.
    Mc.ensure(Installation)
    place(context, @old)
  end

  step "the pinned version is installed in the background", context do
    # Nobody asked: the download has started on its own.
    assert_receive {:codex_download, server}, 15_000
    assert %{"phase" => "downloading", "version" => @pinned} = Installation.state()
    context |> watch() |> Map.put(:server, server)
  end

  step "threads keep running on the installed Codex until the new one is verified and takes over",
       context do
    old = Path.join([Installation.managed_dir(), @old, "bin", "codex"])
    new = Path.join([Installation.managed_dir(), @pinned, "bin", "codex"])
    assert hd(Installation.command("codex")) == old

    # A thread works on the installed Codex while the new one downloads.
    context = World.launch_on(context, "During the update", "codex", "hello")
    World.await_runs(context, "During the update", ["completed"])
    assert List.last(starts(context)) == @old
    {pid, %{conn: conn}} = World.codex_runtime(context, "During the update")

    send(context.server, :go)
    {states, context} = collect(context, &(&1["phase"] in ["failed", "succeeded"]))
    assert %{"phase" => "succeeded", "installedVersion" => @pinned} = List.last(states)
    assert "verifying" in Enum.map(states, & &1["phase"])
    assert hd(Installation.command("codex")) == new
    assert File.dir?(Path.dirname(old))

    # The running thread keeps its app-server; a new thread starts the pinned Codex.
    {{:ok, _}, context} = World.send_message(context, "During the update", "again")
    World.await_runs(context, "During the update", ["completed", "completed"])
    assert {^pid, %{conn: ^conn}} = World.codex_runtime(context, "During the update")

    started = length(starts(context))
    context = World.launch_on(context, "After the update", "codex", "hello")
    World.await_runs(context, "After the update", ["completed"])
    assert [_ | _] = new_starts = Enum.drop(starts(context), started)
    assert Enum.all?(new_starts, &(&1 == @pinned))
    context
  end

  step "a failed update leaves the installed Codex in place", context do
    # The older Codex again, and the pinned release's server now failing.
    Agent.update(context.mode, fn _ -> :gate_not_found end)

    mc =
      Mc.restart(context.mc, fn ->
        File.rm_rf!(Path.join(Installation.managed_dir(), @pinned))
        activate(@old)
      end)

    context = %{context | mc: mc, clients: %{}} |> Map.delete(:install_sub)
    assert_receive {:codex_download, server}, 15_000
    context = watch(context)
    send(server, :go)
    {states, context} = collect(context, &(&1["phase"] in ["failed", "succeeded"]))
    assert %{"phase" => "failed", "installedVersion" => @old} = List.last(states)
    assert List.last(states)["message"] =~ "HTTP 404"
    assert {:ok, %{version: @old}} = Installation.active()
    assert hd(Installation.command("codex")) =~ "/#{@old}/bin/codex"
    context
  end

  # --- fixtures ------------------------------------------------------------------------

  # A native-looking `codex` first on the PATH, with nothing beside it.
  defp bare_codex(context) do
    dir = Mc.tmp_dir(context.mc, "bare-codex")
    bare = Path.join(dir, "codex")
    File.write!(bare, <<0x7F, "ELF", 0::64>>)
    File.chmod!(bare, 0o755)
    World.put_os_env("PATH", "#{dir}:#{System.get_env("PATH")}")
    World.put_app_env(:codex_command, ["codex", "app-server"])
    World.reset_provider_caches()
    Map.merge(context, %{bare: bare, starts: Path.join(context.mc.home, "codex-starts.log")})
  end

  # A Codex package's tree at `dir` for `version`, as OpenAI lays it out.
  defp package(context, dir, version) do
    fake = Path.join(File.cwd!(), "test/support/fake_codex.py")

    files = %{
      "bin/codex" =>
        "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"codex-cli #{version}\"; exit 0; fi\n" <>
          "echo #{version} >> #{context.starts}\nexec python3 -u #{fake} \"$@\"\n",
      "bin/codex-code-mode-host" => "#!/bin/sh\nexit 0\n",
      "codex-path/rg" => "#!/bin/sh\nexit 0\n"
    }

    for {name, body} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
      File.chmod!(path, 0o755)
    end

    File.write!(
      Path.join(dir, "codex-package.json"),
      JSON.encode!(%{
        "layoutVersion" => 1,
        "version" => version,
        "target" => @target,
        "entrypoint" => "bin/codex"
      })
    )

    dir
  end

  # `version` installed and active, as a finished install leaves it.
  defp place(context, version) do
    dir = package(context, Path.join(Installation.managed_dir(), version), version)

    File.write!(
      Path.join(dir, ".install-complete.json"),
      JSON.encode!(%{"version" => version, "target" => @target, "sha256" => "earlier"})
    )

    activate(version)
    World.reset_provider_caches()
    context
  end

  defp activate(version),
    do:
      File.write!(
        Path.join(Installation.managed_dir(), "active.json"),
        ~s({"version":"#{version}"})
      )

  # The pinned release, served from a loopback server whose answer `context.mode` picks.
  defp serve(context) do
    tree = package(context, Mc.tmp_dir(context.mc, "codex-package"), @pinned)
    archive = Path.join(Mc.tmp_dir(context.mc, "codex-archive"), "codex.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        for(
          name <- ["codex-package.json", "bin", "codex-path"],
          do: {String.to_charlist(name), String.to_charlist(Path.join(tree, name))}
        ),
        [:compressed]
      )

    {:ok, mode} = Agent.start_link(fn -> :send end)
    test = self()
    bytes = File.read!(archive)
    path = "/codex-package-#{@target}.tar.gz"
    route = fn conn -> answer(conn, Agent.get(mode, fn mode -> mode end), bytes, test) end
    {base, _log} = FakeHttp.start(%{path => route})

    World.put_app_env(:codex_release, %{
      version: @pinned,
      target: @target,
      url: base <> path,
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      archive_bytes: byte_size(bytes)
    })

    Map.put(context, :mode, mode)
  end

  defp answer(conn, :send, bytes, _test), do: Plug.Conn.send_resp(conn, 200, bytes)
  defp answer(_conn, :not_found, _bytes, _test), do: {404, %{"error" => "not found"}}

  # Held until the scenario says `:go`, then answered as `:send` or `:not_found` would.
  defp answer(conn, gated, bytes, test) when gated in [:gate, :gate_not_found] do
    send(test, {:codex_download, self()})

    receive do
      :go -> answer(conn, if(gated == :gate, do: :send, else: :not_found), bytes, test)
    end
  end

  # The first chunk of the body, then the connection drops.
  defp answer(conn, :cut, bytes, _test) do
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, _} = Plug.Conn.chunk(conn, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    Process.exit(self(), :kill)
  end

  defp answer(_conn, :hang, _bytes, _test) do
    receive do
      :never -> {200, %{}}
    end
  end

  # The versions of the managed Codex app-servers started, in order.
  defp starts(context), do: context.starts |> File.read!() |> String.split("\n", trim: true)

  # --- the install state over the socket ----------------------------------------------

  defp watch(%{install_sub: _} = context), do: context

  defp watch(context) do
    id = System.unique_integer([:positive])

    client =
      World.client(context)
      |> Mc.sub(id, %{
        "type" => "providerInstall",
        "mc" => Atom.to_string(node()),
        "instanceId" => "codex"
      })

    {_frame, client} = Mc.await(client, &(&1["t"] == "providerInstall" and &1["id"] == id))
    context |> World.put_client(client) |> Map.put(:install_sub, id)
  end

  # Install states pushed until one satisfies `done?`; returns `{states, context}`.
  defp collect(context, done?, acc \\ []) do
    id = context.install_sub

    {frame, client} =
      Mc.await(World.client(context), &(&1["t"] == "providerInstall" and &1["id"] == id), 15_000)

    context = World.put_client(context, client)
    acc = [frame["state"] | acc]

    if done?.(frame["state"]),
      do: {Enum.reverse(acc), context},
      else: collect(context, done?, acc)
  end
end
