defmodule HalC2.Steps.Platform.HostIntegration do
  @moduledoc "Steps for features/node/platform/host-integration.feature."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  @editors %{
    "VS Code" => {"code", "vscode"},
    "Cursor" => {"cursor", "cursor"},
    "Zed" => {"zed", "zed"},
    "IntelliJ" => {"idea", "idea"}
  }

  # --- fake host programs --------------------------------------------------------------

  # A directory at the front of PATH for this scenario's fake programs.
  defp bin(context) do
    case context[:bin] do
      nil ->
        dir = Node.tmp_dir(context.node, "bin")
        World.put_os_env("PATH", dir <> ":" <> System.get_env("PATH"))
        Map.put(context, :bin, dir)

      _ ->
        context
    end
  end

  # Installs `name` as a program that reports its arguments to this test over TCP and
  # then stays running until the test hangs up.
  defp install(context, name) do
    context = bin(context) |> listen()
    path = Path.join(context.bin, name)

    File.write!(path, """
    #!/usr/bin/env bash
    exec 3<>/dev/tcp/127.0.0.1/$HALC2_TEST_LAUNCH_PORT
    printf '%s\\x1f' "#{name}" "$@" >&3
    printf '\\n' >&3
    read -r -u 3 _
    """)

    File.chmod!(path, 0o755)
    context
  end

  defp listen(%{launches: _} = context), do: context

  defp listen(context) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    World.put_os_env("HALC2_TEST_LAUNCH_PORT", Integer.to_string(port))
    Map.put(context, :launches, socket)
  end

  # The next launched program: `{connection, [name | args]}`.
  defp launched(context) do
    {:ok, conn} = :gen_tcp.accept(context.launches, 5_000)
    {:ok, line} = :gen_tcp.recv(conn, 0, 5_000)
    argv = line |> String.trim_trailing("\n") |> String.split("\x1f", trim: true)
    {conn, argv}
  end

  defp with_display(context) do
    World.put_app_env(:os_type, {:unix, :linux})
    World.put_os_env("DISPLAY", ":0")
    install(context, "xdg-open")
  end

  defp headless(context) do
    World.put_app_env(:os_type, {:unix, :linux})
    World.put_os_env("DISPLAY", nil)
    World.put_os_env("WAYLAND_DISPLAY", nil)
    context
  end

  defp open(context, input) do
    {reply, context} = World.call(context, "shell.openInEditor", input)
    Map.put(context, :reply, reply)
  end

  defp refused(context, tag) do
    assert {:error, error, detail} = context.reply
    assert inspect({error, detail}) =~ tag
    context
  end

  defp server_config(context) do
    Node.ensure(HalC2.Settings)

    client =
      World.client(context)
      |> Node.sub(9, %{"type" => "config", "environment" => context.node.environment})

    {frame, client} = Node.await(client, &(&1["t"] == "config" and &1["id"] == 9))
    context |> World.put_client(client) |> Map.put(:server_config, frame["config"])
  end

  # --- editors -------------------------------------------------------------------------

  step "Cursor and Zed are installed on the host", context do
    context |> install("cursor") |> install("zed") |> with_display()
  end

  step "the available editors include Cursor and Zed", context do
    editors = context.server_config["availableEditors"]
    assert "cursor" in editors and "zed" in editors
    context
  end

  step "the file manager is listed last", context do
    assert List.last(context.server_config["availableEditors"]) == "file-manager"
    context
  end

  step ~r/^a client opens "(?<file>[^"]+)" at line (?<line>\d+) column (?<column>\d+) in (?<editor>.+)$/,
       %{args: [file, line, column, editor]} = context do
    {command, id} = Map.fetch!(@editors, editor)
    context = install(context, command)
    target = Path.join(Node.tmp_dir(context.node, "project"), file) <> ":#{line}:#{column}"
    context |> Map.put(:target, target) |> open(%{"cwd" => target, "editor" => id})
  end

  step ~r/^the node launches (?<editor>.+) the way it takes a line and column$/,
       %{args: [editor]} = context do
    {command, _id} = Map.fetch!(@editors, editor)
    [path, _line, _column] = String.split(context.target, ":")

    expected =
      case editor do
        "VS Code" -> ["--goto", context.target]
        "Cursor" -> ["--classic", "--goto", context.target]
        "Zed" -> [context.target]
        "IntelliJ" -> ["--line", "12", "--column", "4", path]
      end

    {conn, argv} = launched(context)
    assert argv == [command | expected]
    Map.put(context, :editor_conn, conn)
  end

  step "it does not wait for the editor to exit", context do
    # The reply came back while the editor is still running, waiting on this socket.
    assert {:ok, nil} = context.reply
    assert :ok = :gen_tcp.send(context.editor_conn, "exit\n")
    :gen_tcp.close(context.editor_conn)
    context
  end

  step "a client opens a project folder in the file manager", context do
    context = with_display(context)
    folder = Node.tmp_dir(context.node, "project")
    context |> Map.put(:target, folder) |> open(%{"cwd" => folder, "editor" => "file-manager"})
  end

  step "the host's file manager shows that folder", context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["xdg-open", context.target]
    :gen_tcp.close(conn)
    context
  end

  step "a Linux host with no display", context do
    headless(context)
  end

  step "a client opens a folder in the file manager", context do
    open(context, %{"cwd" => Node.tmp_dir(context.node, "project"), "editor" => "file-manager"})
  end

  step "the node fails saying the file manager is unsupported", context do
    refused(context, "ExternalLauncherUnsupportedEditorError")
  end

  step "the node runs on macOS", context do
    World.put_app_env(:os_type, {:unix, :darwin})
    install(context, "open")
  end

  step "a client reveals a file in the file manager", context do
    file = Path.join(Node.tmp_dir(context.node, "project"), "README.md")
    File.write!(file, "# hi\n")

    context
    |> Map.put(:target, file)
    |> open(%{"cwd" => file, "editor" => "file-manager", "reveal" => true})
  end

  step "Finder shows the file selected in its folder", context do
    assert {:ok, nil} = context.reply
    {conn, argv} = launched(context)
    assert argv == ["open", "-R", context.target]
    :gen_tcp.close(conn)
    context
  end

  step "a client opens a folder in an editor id the node does not know", context do
    open(context, %{"cwd" => Node.tmp_dir(context.node, "project"), "editor" => "notepad"})
  end

  step "the node fails saying the editor is unknown", context do
    refused(context, "ExternalLauncherUnknownEditorError")
  end

  step "Zed is not installed on the host", context do
    World.put_os_env("PATH", Node.tmp_dir(context.node, "empty-bin"))
    context
  end

  step "a client opens a folder in Zed", context do
    open(context, %{"cwd" => Node.tmp_dir(context.node, "project"), "editor" => "zed"})
  end

  step "the node fails naming the command it could not find", context do
    context = refused(context, "ExternalLauncherCommandNotFoundError")
    assert inspect(context.reply) =~ ~s("command" => "zed")
    context
  end

  step "a client reads the available editors", context do
    server_config(context)
  end

  step "the file manager is not offered", context do
    refute "file-manager" in context.server_config["availableEditors"]
    context
  end

  # --- browsing folders --------------------------------------------------------------

  defp browse(context, partial) do
    {reply, context} = World.call(context, "filesystem.browse", %{"partialPath" => partial})
    Map.put(context, :reply, reply)
  end

  defp entries(context) do
    assert {:ok, %{"entries" => entries, "parentPath" => parent}} = context.reply
    assert parent == Path.join(context.user_home, "dev")
    for entry <- entries, do: assert(entry["fullPath"] == Path.join(parent, entry["name"]))
    Enum.map(entries, & &1["name"])
  end

  # Under the scenario's `$HOME` (`HalC2.Test.Node.Host`); `context.user_home` names it.
  step "the home folder has a dev folder holding api, tests, tools, .tmp, .trash and a file todo.txt",
       context do
    dev = HalC2.Test.Node.Host.path(context, "~/dev")

    for dir <- ~w(tools tests api .tmp .trash), do: File.mkdir_p!(Path.join(dev, dir))
    File.write!(Path.join(dev, "todo.txt"), "")
    Map.put(context, :user_home, HalC2.Test.Node.Host.home(context))
  end

  step "the node lists folders in {string} whose names start with {string}",
       %{args: ["~/dev", "t"]} = context do
    assert entries(context) == ["tests", "tools"]
    context
  end

  step "hidden folders are left out", context do
    assert File.dir?(Path.join(context.user_home, "dev/.tmp"))
    refute Enum.any?(entries(context), &String.starts_with?(&1, "."))
    context
  end

  step "the node lists every folder in {string}, hidden ones included",
       %{args: ["~/dev"]} = context do
    # Every folder, and only folders: `todo.txt` is not one.
    assert entries(context) == [".tmp", ".trash", "api", "tests", "tools"]
    context
  end

  step "a client browses a path whose parent does not exist", context do
    browse(context, Path.join(Node.tmp_dir(context.node, "user-home"), "missing/t"))
  end

  step "the node fails without listing anything", context do
    assert {:error, error, _} = context.reply
    assert error =~ "missing"
    context
  end

  # --- local servers -----------------------------------------------------------------

  defmodule Page do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts),
      do: conn |> put_resp_content_type("text/html") |> send_resp(200, "<h1>dev</h1>")
  end

  # Servers listen on a free port; the scenario's port number names that one.
  step "a development server is serving HTML on port {int}", %{args: [named]} = context do
    {:ok, server} =
      Bandit.start_link(plug: Page, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    context |> put_in([Access.key(:ports, %{}), named], port) |> Map.put(:dev_server, server)
  end

  step "a database is listening on port {int}", %{args: [named]} = context do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    put_in(context, [Access.key(:ports, %{}), named], port)
  end

  defp follow_local_servers(context) do
    Node.ensure(HalC2.LocalServers)
    shape = %{"type" => "localServers", "node" => Atom.to_string(node())}
    client = World.client(context) |> Node.sub(11, shape)
    {frame, client} = Node.await(client, &(&1["t"] == "localServers" and &1["id"] == 11), 10_000)
    context |> World.put_client(client) |> Map.put(:servers, ports(frame))
  end

  defp ports(frame), do: Enum.map(frame["list"]["servers"], & &1["port"])

  step "a client follows the host's local servers", context do
    follow_local_servers(context)
  end

  step "port {int} is listed", %{args: [named]} = context do
    assert context.ports[named] in context.servers
    context
  end

  step "port {int} is not listed", %{args: [named]} = context do
    refute context.ports[named] in context.servers
    context
  end

  step "a client follows the host's local servers with port {int} listed",
       %{args: [named]} = context do
    {:ok, server} = Bandit.start_link(plug: Page, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    context = context |> Map.put(:ports, %{named => port}) |> Map.put(:dev_server, server)
    context = follow_local_servers(context)
    assert port in context.servers
    Map.put(context, :stopped, named)
  end

  step "port {int} is removed from the list", %{args: [named]} = context do
    port = context.ports[named]

    # The next scan (every three seconds while someone watches) pushes the new list.
    {frame, client} =
      Node.await(
        World.client(context),
        &(&1["t"] == "localServers" and &1["id"] == 11 and port not in ports(&1)),
        10_000
      )

    refute port in ports(frame)
    World.put_client(context, client)
  end

  step "nobody follows the host's local servers", context do
    Node.ensure(HalC2.LocalServers)
    context
  end

  step "the node does not scan the host's ports", context do
    state = :sys.get_state(HalC2.LocalServers)
    assert state.watchers == %{}
    assert state.timer == nil
    assert state.list == nil
    context
  end

  # --- paths and pipes ---------------------------------------------------------------

  step "a project path that loops through symlinks", context do
    dir = Node.tmp_dir(context.node, "loop")
    File.ln_s!(Path.join(dir, "b"), Path.join(dir, "a"))
    File.ln_s!(Path.join(dir, "a"), Path.join(dir, "b"))
    Map.put(context, :path, Path.join(dir, "a/project"))
  end

  step "the node resolves it", context do
    Map.put(context, :resolved, HalC2.Paths.real(context.path))
  end

  step "it fails as a symlink loop", context do
    assert context.resolved == {:error, :eloop}
    context
  end

  step "a provider process writing output faster than the node reads it", context do
    {:ok, sub} = HalC2.Subprocess.start(["yes", "a line of provider output"])
    assert_receive {:subprocess_lines, reader, lines}, 5_000
    Map.merge(context, %{sub: sub, reader: reader, first: lines})
  end

  step "the node applies backpressure through the process's pipe", context do
    # Until the owner acknowledges a batch, the reader does not read again ...
    refute_receive {:subprocess_lines, _, _}, 300
    # ... so the writer blocks on the full pipe.
    wchan = File.read!("/proc/#{HalC2.Subprocess.os_pid(context.sub)}/wchan")
    assert wchan =~ "pipe", "the writer is in #{inspect(wchan)}"
    context
  end

  step "its memory stays bounded", context do
    assert IO.iodata_length(context.first) <= 65_535
    {:memory, memory} = Process.info(context.reader, :memory)
    assert memory < 1_000_000
    # Acknowledging lets exactly the next batch through.
    HalC2.Subprocess.ack(context.sub)
    assert_receive {:subprocess_lines, _, _}, 5_000
    refute_receive {:subprocess_lines, _, _}, 100
    HalC2.Subprocess.ack(context.sub)
    HalC2.Subprocess.stop(context.sub, 1_000)
    context
  end
end
