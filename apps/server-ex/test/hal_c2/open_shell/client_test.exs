defmodule HalC2.OpenShell.ClientTest do
  # The environment id (the owner label) comes from the app env's `:home`.
  use ExUnit.Case, async: false

  alias HalC2.OpenShell
  alias HalC2.OpenShell.Client
  alias HalC2.OpenShell.Exec
  alias HalC2.Test.FakeOpenShell

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = context do
    FakeOpenShell.put_env(home: Path.join(dir, "mc"))
    opts = Map.get(context, :gateway, [])
    opts = if run = context[:exec], do: [exec: handler(run, self())] ++ opts, else: opts
    gateway = FakeOpenShell.start(Path.join(dir, "pki"), [notify: self()] ++ opts)
    {:ok, conn} = Client.connect(gateway.endpoint, gateway.credentials)
    on_exit(fn -> Client.disconnect(conn) end)
    %{gateway: gateway, conn: conn}
  end

  describe "connecting" do
    test "a plaintext or malformed endpoint is refused before anything is sent", %{gateway: g} do
      for url <- ["http://127.0.0.1:#{g.port}", "grpc://127.0.0.1:#{g.port}", "h2c://localhost:1"],
          do: assert({:error, :plaintext_refused} = Client.connect(url, g.credentials))

      for url <- ["127.0.0.1:#{g.port}", "https://", "https://127.0.0.1:#{g.port}/x"],
          do: assert({:error, :bad_endpoint} = Client.connect(url, g.credentials))

      assert {:error, :credentials_missing} =
               Client.connect(g.endpoint, Keyword.put(g.credentials, :key, "/nonexistent"))
    end

    test "the MC is who its certificate says, and not an operator", %{conn: conn} do
      assert {:ok, %{status: :healthy, version: "0.1.7"}} = Client.health(conn)

      # The fake answers with the subject of the certificate it was shown.
      assert {:ok,
              %{subject: "client Peer cert", roles: ["openshell-user"], identity_provider: "mtls"}} =
               Client.current_user(conn)

      assert {:ok, %{version: "0.1.7", drivers: ["podman"]}} = Client.gateway_info(conn)
    end

    test "certificates replaced in place are read again, as after a rotation", %{
      gateway: g,
      tmp_dir: dir
    } do
      assert {:ok, _} =
               Client.connect(g.endpoint, g.credentials) |> elem(1) |> Client.current_user()

      # A new CA and identities at the same paths, and a gateway that trusts only them.
      File.rm_rf!(Path.join(dir, "pki"))
      rotated = FakeOpenShell.start(Path.join(dir, "pki"))
      assert rotated.credentials == g.credentials

      {:ok, conn} = Client.connect(rotated.endpoint, rotated.credentials)
      assert {:ok, %{subject: "client Peer cert"}} = Client.current_user(conn)
      Client.disconnect(conn)
    end

    test "without a certificate only Health answers", %{gateway: g} do
      {:ok, anon} = Client.connect(g.endpoint, ca: g.credentials[:ca], anonymous: true)
      assert {:ok, %{status: :healthy}} = Client.health(anon)
      assert {:error, %{status: :unauthenticated}} = Client.current_user(anon)
      Client.disconnect(anon)
    end

    test "a gateway the MC's CA did not sign is not trusted", %{gateway: g, tmp_dir: dir} do
      other = FakeOpenShell.stranger(Path.join(dir, "other"))

      refused =
        case Client.connect(g.endpoint, Keyword.put(g.credentials, :ca, other[:ca])) do
          {:error, _} -> true
          {:ok, conn} -> match?({:error, _}, Client.health(conn))
        end

      assert refused
    end

    test "a certificate the gateway's CA did not sign gets nothing", %{gateway: g, tmp_dir: dir} do
      other = FakeOpenShell.stranger(Path.join(dir, "other"))

      refused =
        case Client.connect(g.endpoint, Keyword.put(other, :ca, g.credentials[:ca])) do
          {:error, _} -> true
          {:ok, conn} -> match?({:error, _}, Client.current_user(conn))
        end

      assert refused
    end
  end

  describe "connecting to the gateway's own certificate" do
    test "the gateway's certificate does not authenticate as a client", %{gateway: g} do
      pki = Path.dirname(g.credentials[:ca])

      as_server = [
        ca: g.credentials[:ca],
        cert: Path.join([pki, "server", "tls.crt"]),
        key: Path.join([pki, "server", "tls.key"])
      ]

      refused =
        case Client.connect(g.endpoint, as_server) do
          {:error, _} -> true
          {:ok, conn} -> match?({:error, _}, Client.current_user(conn))
        end

      assert refused
      assert {:ok, _} = Client.connect(g.endpoint, g.credentials)
    end
  end

  describe "other environments" do
    test "are the owner labels on the gateway that are not this MC's, in any workspace",
         %{conn: conn, gateway: g} do
      assert {:ok, []} = Client.other_environments(conn)

      FakeOpenShell.put_sandbox(g, "mine", %{OpenShell.owner_label() => OpenShell.owner()})
      FakeOpenShell.put_sandbox(g, "not-halc2", %{"team" => "x"})
      assert {:ok, []} = Client.other_environments(conn)

      FakeOpenShell.put_sandbox(g, "theirs-1", %{OpenShell.owner_label() => "env-b"})
      FakeOpenShell.put_sandbox(g, "theirs-2", %{OpenShell.owner_label() => "env-b"})
      FakeOpenShell.put_sandbox(g, "theirs-3", %{OpenShell.owner_label() => "env-a"})
      assert {:ok, ["env-a", "env-b"]} = Client.other_environments(conn)

      # Looking leaves theirs alone, and the MC still lists and owns only its own.
      assert Map.keys(FakeOpenShell.sandboxes(g)) |> length() == 5
      assert {:ok, [%{name: "mine"}]} = Client.list_sandboxes(conn)
    end

    test "connecting to the installed gateway is refused once another environment is on it",
         _context do
      theirs = FakeOpenShell.start(OpenShell.pki_dir())
      OpenShell.put_state(%{"mode" => "external", "endpoint" => theirs.endpoint})

      assert {:ok, conn} = Client.connect()
      Client.disconnect(conn)

      FakeOpenShell.put_sandbox(theirs, "theirs", %{OpenShell.owner_label() => "env-b"})
      assert {:error, {:shared_gateway, ["env-b"]}} = Client.connect()
      # Managing it (status, draining, uninstalling) still connects.
      assert {:ok, conn} = Client.connect_unchecked()
      Client.disconnect(conn)
      assert Map.keys(FakeOpenShell.sandboxes(theirs)) == ["theirs"]
    end
  end

  describe "sandboxes" do
    # A connection outlives `connect/0`'s check: another environment may arrive after it.
    test "a connection made before another environment arrived makes no sandbox there", %{
      conn: conn,
      gateway: g
    } do
      FakeOpenShell.put_sandbox(g, "theirs", %{OpenShell.owner_label() => "env-b"})

      assert {:error, {:shared_gateway, ["env-b"]}} = Client.create_sandbox(conn, "mine")
      refute_received {:openshell_request, "CreateSandbox", _}
      assert Map.keys(FakeOpenShell.sandboxes(g)) == ["theirs"]
    end

    test "the workspace is created once", %{conn: conn} do
      assert :ok = Client.ensure_workspace(conn)
      assert_received {:openshell_request, "CreateWorkspace", "hal-c2"}
      assert :ok = Client.ensure_workspace(conn)
      refute_received {:openshell_request, "CreateWorkspace", _}
    end

    test "a created sandbox carries the owner label, its limits and no restarts", %{conn: conn} do
      assert {:ok, %{name: "review-42", phase: :ready, labels: labels}} =
               Client.create_sandbox(conn, "review-42",
                 labels: %{"halc2.github.io/review" => "42"},
                 limits: %{cpu: "2", memory: "4Gi", disk: "ignored"}
               )

      assert labels == %{
               "halc2.github.io/review" => "42",
               OpenShell.owner_label() => OpenShell.owner()
             }

      assert_received {:openshell_request, "CreateSandbox", request}
      assert request.spec.restart_policy == :SANDBOX_RESTART_POLICY_NEVER
      assert {:workspace, "hal-c2"} = request.workspace_scope.selection

      assert request.request_id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      limits = Google.Protobuf.to_map(request.spec.template.resources)

      assert limits == %{
               "limits" => %{"cpu" => "2", "memory" => "4Gi"},
               "requests" => %{"cpu" => "2", "memory" => "4Gi"}
             }
    end

    test "the owner label cannot be taken over, and bad labels fail with their name", %{
      conn: conn
    } do
      assert {:error, :owner_label_reserved} =
               Client.create_sandbox(conn, "x",
                 labels: %{OpenShell.owner_label() => "someone-else"}
               )

      assert {:error, {:bad_label, "bad key!"}} =
               Client.create_sandbox(conn, "x", labels: %{"bad key!" => "1"})

      assert {:error, {:bad_label, "k"}} =
               Client.create_sandbox(conn, "x", labels: %{"k" => "has space"})

      refute_received {:openshell_request, "CreateSandbox", _}
    end

    @tag gateway: [ignore_selector: true]
    test "listing returns only this MC's sandboxes, even when the gateway returns more",
         %{conn: conn, gateway: g} do
      {:ok, _} = Client.create_sandbox(conn, "mine-1", labels: %{"halc2.github.io/review" => "1"})
      {:ok, _} = Client.create_sandbox(conn, "mine-2", labels: %{"halc2.github.io/review" => "2"})
      # Each create first looked for other environments' sandboxes, in every workspace.
      assert_received {:openshell_request, "ListSandboxes", %{label_selector: ""}}
      assert_received {:openshell_request, "ListSandboxes", %{label_selector: ""}}
      FakeOpenShell.put_sandbox(g, "theirs", %{OpenShell.owner_label() => "another-mc"})
      FakeOpenShell.put_sandbox(g, "unlabelled", %{})

      assert {:ok, all} = Client.list_sandboxes(conn)
      assert Enum.map(all, & &1.name) == ["mine-1", "mine-2"]

      assert_received {:openshell_request, "ListSandboxes", request}
      assert request.label_selector == "#{OpenShell.owner_label()}=#{OpenShell.owner()}"

      Client.list_sandboxes(conn, %{"halc2.github.io/review" => "1"})
      assert_received {:openshell_request, "ListSandboxes", request}

      assert request.label_selector ==
               "#{OpenShell.owner_label()}=#{OpenShell.owner()},halc2.github.io/review=1"
    end

    test "a sandbox the MC did not create is neither read nor deleted", %{conn: conn, gateway: g} do
      FakeOpenShell.put_sandbox(g, "theirs", %{OpenShell.owner_label() => "another-mc"})
      assert {:error, :not_owned} = Client.get_sandbox(conn, "theirs")
      assert {:error, :not_owned} = Client.delete_sandbox(conn, "theirs")
      refute_received {:openshell_request, "DeleteSandbox", _}
      assert Map.has_key?(FakeOpenShell.sandboxes(g), "theirs")
    end

    test "deleting its own sandbox, or one already gone, is :ok", %{conn: conn, gateway: g} do
      {:ok, _} = Client.create_sandbox(conn, "mine")
      assert :ok = Client.delete_sandbox(conn, "mine")
      assert_received {:openshell_request, "DeleteSandbox", %{name: "mine", allow_missing: true}}
      refute Map.has_key?(FakeOpenShell.sandboxes(g), "mine")

      assert :ok = Client.delete_sandbox(conn, "mine")
      assert {:error, %{status: :not_found}} = Client.get_sandbox(conn, "mine")
    end

    # OpenShell's ACCEPTED means the record still exists: `:ok` waits until it is gone.
    @tag gateway: [delete: {:accepted, 2}]
    test "an accepted deletion is :ok only once the sandbox is gone", %{conn: conn, gateway: g} do
      {:ok, _} = Client.create_sandbox(conn, "mine")
      assert :ok = Client.delete_sandbox(conn, "mine")
      assert_received {:openshell_request, "DeleteSandbox", _}
      assert_received {:openshell_request, "GetSandbox", %{name: "mine"}}
      assert_received {:openshell_request, "GetSandbox", %{name: "mine"}}
      refute Map.has_key?(FakeOpenShell.sandboxes(g), "mine")
    end

    @tag gateway: [delete: {:accepted, :never}]
    test "an accepted deletion that never finishes is still pending at the deadline", %{
      conn: conn,
      gateway: g
    } do
      {:ok, _} = Client.create_sandbox(conn, "mine")

      assert {:error, {:delete_pending, "id-mine"}} =
               Client.delete_sandbox(conn, "mine", delete_timeout: 300)

      assert Map.has_key?(FakeOpenShell.sandboxes(g), "mine")
    end

    @tag gateway: [delete: :replaced]
    test "an accepted deletion is done once the name holds another sandbox", %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "mine")
      assert :ok = Client.delete_sandbox(conn, "mine")
    end

    @tag gateway: [delete: :unspecified]
    test "an unspecified deletion outcome is not taken for done", %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "mine")

      assert {:error, {:deletion_outcome, :DELETION_OUTCOME_UNSPECIFIED}} =
               Client.delete_sandbox(conn, "mine")
    end
  end

  describe "exec" do
    setup %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "box")
      :ok
    end

    test "stdin comes back on stdout and the exit status ends the stream", %{conn: conn} do
      {:ok, exec} =
        Client.exec(conn, "box", ["cat"], workdir: "/sandbox", environment: %{"A" => "1"})

      assert_receive {:openshell_request, "ExecSandboxInteractive", start}
      assert start.command == ["cat"]
      assert start.environment == %{"A" => "1"}
      refute start.tty

      ref = Process.monitor(exec)
      assert :ok = Exec.send_stdin(exec, "hello ")
      assert :ok = Exec.send_stdin(exec, ["wor", "ld"])
      assert :ok = Exec.close_stdin(exec)

      assert collect(exec) == {"hello world", {:exit, 0}}
      assert_receive {:DOWN, ^ref, :process, ^exec, :normal}
      assert {:error, :closed} = Exec.send_stdin(exec, "late")
    end

    test "a megabyte of binary stdin arrives whole and in order before the half-close", %{
      conn: conn
    } do
      data = :crypto.strong_rand_bytes(1_048_576 + 17)
      {:ok, exec} = Client.exec(conn, "box", ["cat"])
      assert :ok = Exec.send_stdin(exec, data)
      assert :ok = Exec.close_stdin(exec)
      assert {:error, :stdin_closed} = Exec.send_stdin(exec, "more")
      assert {^data, {:exit, 0}} = collect(exec)
    end

    @tag exec: :fails
    test "stderr and a non-zero exit come through", %{conn: conn} do
      {:ok, exec} = Client.exec(conn, "box", ["false"])
      assert_receive {:openshell_exec, ^exec, {:stderr, "warning\n"}}
      assert_receive {:openshell_exec, ^exec, {:stdout, "out\n"}}
      assert_receive {:openshell_exec, ^exec, {:exit, 3}}
    end

    @tag exec: :hangs
    test "cancelling ends the stream with :cancelled, once", %{conn: conn} do
      {:ok, exec} = Client.exec(conn, "box", ["sleep", "infinity"])
      assert_receive {:openshell_exec, ^exec, {:stdout, "started"}}
      ref = Process.monitor(exec)
      assert :ok = Exec.cancel(exec)
      assert_receive {:openshell_exec, ^exec, {:error, :cancelled}}
      assert_receive {:DOWN, ^ref, :process, ^exec, :normal}
      assert :ok = Exec.cancel(exec)
      refute_received {:openshell_exec, ^exec, _}
    end

    # Found by prop/hal_c2/openshell_exec_prop_test.exs: the reader, killed
    # asynchronously, could still send output after the cancel's ending. That takes a
    # cancel while the reader is busy with a backlog, here of two commands' output at
    # once, and only some cancels land there, so this cancels several times.
    @tag exec: :spews
    test "nothing follows a cancel's ending while output pours in", %{conn: conn} do
      for _ <- 1..30 do
        execs =
          for _ <- 1..2 do
            {:ok, exec} = Client.exec(conn, "box", ["spew"])
            assert_receive {:openshell_exec, ^exec, {:stdout, _}}
            {exec, Process.monitor(exec)}
          end

        for {exec, ref} <- Enum.reverse(execs) do
          assert :ok = Exec.cancel(exec)
          assert {_, {:error, :cancelled}} = collect(exec)
          assert_receive {:DOWN, ^ref, :process, ^exec, :normal}
        end

        for {exec, _} <- execs, do: refute_received({:openshell_exec, ^exec, _})
      end
    end

    @tag exec: :waits
    test "the stream stops when its owner exits", %{conn: conn} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, exec} = Client.exec(conn, "box", ["sleep", "infinity"])
          send(test, {:exec, exec})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:exec, exec}
      ref = Process.monitor(exec)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^exec, :normal}
    end

    test "a sandbox that does not exist is the gateway's error, with no stream", %{conn: conn} do
      assert {:error, %{status: :not_found}} = Client.exec(conn, "missing", ["true"])
      refute_received {:openshell_request, "ExecSandboxInteractive", _}
    end

    test "a sandbox this MC does not own runs nothing, and takes no upload", %{
      gateway: g,
      conn: conn
    } do
      FakeOpenShell.put_sandbox(g, "theirs", %{OpenShell.owner_label() => "env-b"})
      FakeOpenShell.put_sandbox(g, "unlabelled", %{"team" => "x"})

      for name <- ["theirs", "unlabelled"] do
        assert {:error, :not_owned} = Client.exec(conn, name, ["true"])
        assert {:error, :not_owned} = Client.upload(conn, name, "/sandbox", "archive")
      end

      refute_received {:openshell_request, "ExecSandboxInteractive", _}
    end
  end

  describe "upload" do
    @tag exec: :untar
    test "streams the archive into tar in the sandbox", %{conn: conn, tmp_dir: dir} do
      {:ok, _} = Client.create_sandbox(conn, "box")
      tar = :crypto.strong_rand_bytes(200_000)
      path = Path.join(dir, "src.tar")
      File.write!(path, tar)

      assert :ok = Client.upload(conn, "box", "/sandbox/src", {:file, path})

      assert_receive {:command, ["tar", "-x", "--no-same-owner", "-C", "/sandbox/src", "-f", "-"],
                      ^tar}
    end

    @tag exec: :bad_tar
    test "tar's failure is the upload's", %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "box")

      assert {:error, {:upload_failed, 2, "tar: not a tar archive\n"}} =
               Client.upload(conn, "box", "/sandbox", "garbage")
    end

    @tag exec: :stalls, timeout: 10_000
    test "a sandbox that stops reading times the upload out, and leaves the connection working",
         %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "box")
      # More than the flow-control windows hold, so the archive's writer is left waiting.
      tar = :binary.copy(<<0>>, 4_000_000)

      assert {:error, :timeout} =
               Client.upload(conn, "box", "/sandbox", tar, upload_timeout: 200)

      # The gateway stopped the command, and nothing of it is left to the caller.
      assert_receive {:handler, handler}
      ref = Process.monitor(handler)
      assert_receive {:DOWN, ^ref, :process, ^handler, _}
      refute_received {:openshell_exec, _, _}

      # A later command on the same connection still gets its stdin through.
      {:ok, exec} = Client.exec(conn, "box", ["cat"])
      assert :ok = Exec.send_stdin(exec, "still here")
      assert :ok = Exec.close_stdin(exec)
      assert {"still here", {:exit, 0}} = collect(exec)
    end

    @tag exec: :chatters, timeout: 10_000
    test "the upload's deadline holds while the sandbox keeps talking", %{conn: conn} do
      {:ok, _} = Client.create_sandbox(conn, "box")

      assert {:error, :timeout} =
               Client.upload(conn, "box", "/sandbox", "archive", upload_timeout: 300)

      assert_receive {:handler, handler}
      ref = Process.monitor(handler)
      assert_receive {:DOWN, ^ref, :process, ^handler, _}
    end

    # The gateway never answers whether the sandbox is there.
    @tag gateway: [get_sandbox: &__MODULE__.never/0], timeout: 5_000
    test "the upload's deadline covers starting its command", %{conn: conn} do
      assert {:error, :timeout} =
               Client.upload(conn, "box", "/sandbox", "archive", upload_timeout: 200)

      refute_received {:openshell_request, "ExecSandboxInteractive", _}
    end

    @tag exec: :untar
    test "an archive that cannot be read is the upload's error, and its command is stopped", %{
      conn: conn,
      tmp_dir: dir
    } do
      {:ok, _} = Client.create_sandbox(conn, "box")

      assert {:error, {:read, :enoent}} =
               Client.upload(conn, "box", "/sandbox", {:file, Path.join(dir, "missing.tar")})

      # Cancelled, so tar never saw the end of an archive.
      refute_received {:command, _, _}
      refute_received {:openshell_exec, _, _}
    end
  end

  @doc false
  def never, do: receive(do: (:never -> :ok))

  # What the fake gateway runs for a test's `@tag exec:`.
  defp handler(:fails, _test) do
    fn _command, io ->
      io.stderr.("warning\n")
      io.stdout.("out\n")
      io.exit.(3)
    end
  end

  defp handler(:hangs, _test) do
    fn _command, io ->
      io.stdout.("started")
      # Waits for input that never comes.
      io.read.()
    end
  end

  defp handler(:waits, _test), do: fn _command, io -> io.read.() end

  # Small chunks as fast as the stream takes them, until it is gone.
  defp handler(:spews, _test) do
    fn _command, io ->
      Enum.reduce_while(1..2_000, :ok, fn _, :ok ->
        if io.stdout.("spew\n") == :ok, do: {:cont, :ok}, else: {:halt, :closed}
      end)

      io.read.()
    end
  end

  defp handler(:untar, test) do
    fn command, io ->
      send(test, {:command, command, read_all(io, [])})
      io.exit.(0)
    end
  end

  defp handler(:bad_tar, _test) do
    fn _command, io ->
      read_all(io, [])
      io.stderr.("tar: not a tar archive\n")
      io.exit.(2)
    end
  end

  # Takes the first command's stdin no further; any later command is `cat`.
  defp handler(:stalls, test) do
    fn
      ["tar" | _], _io ->
        send(test, {:handler, self()})

        # Until the stream is gone, which stops this process.
        receive do: (:never -> :ok)

      _command, io ->
        io.stdout.(read_all(io, []))
        io.exit.(0)
    end
  end

  # Takes the archive, then writes output for longer than the upload may take.
  defp handler(:chatters, test) do
    fn _command, io ->
      read_all(io, [])
      send(test, {:handler, self()})

      # Until the stream is gone, however long the upload's deadline takes to come:
      # an exit of its own would end the upload before its deadline.
      chatter(io)
    end
  end

  defp chatter(io) do
    Process.sleep(10)
    if io.stdout.(".") == :ok, do: chatter(io)
  end

  defp read_all(io, acc) do
    case io.read.() do
      {:stdin, data} -> read_all(io, [acc, data])
      :eof -> IO.iodata_to_binary(acc)
      _ -> read_all(io, acc)
    end
  end

  defp collect(exec, acc \\ []) do
    receive do
      {:openshell_exec, ^exec, {:stdout, data}} -> collect(exec, [acc, data])
      {:openshell_exec, ^exec, ending} -> {IO.iodata_to_binary(acc), ending}
    after
      10_000 -> {IO.iodata_to_binary(acc), :timeout}
    end
  end
end
