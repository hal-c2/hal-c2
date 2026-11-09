defmodule HalC2.Test.FakeOpenShell do
  @moduledoc """
  A stand-in OpenShell gateway: Bandit serving the `openshell.v1.OpenShell` methods
  the MC uses over HTTP/2 and TLS, asking for a client certificate the way the
  real one does (optional at the handshake, required by every method but
  `Health`). `start/2` issues a CA, the gateway's certificate and a client
  certificate into `dir`, laid out like `HalC2.OpenShell.pki_dir/0`.

  Sandboxes live in an Agent. `ExecSandboxInteractive` runs `opts[:exec]`, a
  `fn command, io -> ... end` given the start request's command and an `io` it
  reads stdin from (`read.(io)` gives `{:data, binary}` or `:eof`) and writes
  events to (`stdout.(data)`, `exit.(code)`). The default echoes stdin to stdout
  and exits 0. Every request is also sent to `opts[:notify]` as
  `{:openshell_request, method, request}`.

  The real gateway ends each response with `grpc-status` trailers; Bandit sends
  none, which the client takes as OK, and errors go in the response headers
  (gRPC's trailers-only form).
  """

  alias HalC2.OpenShell.Proto.Openshell.Datamodel.V1.ObjectMeta
  alias HalC2.OpenShell.Proto.Openshell.V1, as: Pb

  @doc """
  Starts the fake and returns `%{port, endpoint, credentials, server, store}`.
  Options: `:version` ("0.1.7"), `:roles` (["openshell-user"]), `:exec`,
  `:notify`, `:get_sandbox` (a function GetSandbox runs before it answers), and
  `:delete`: how DeleteSandbox answers, `:completed` (the default),
  `:unspecified`, `{:accepted, n}` (the sandbox goes after `n` more GetSandbox
  calls, or never for `:never`) or `:replaced` (another sandbox takes its name).
  """
  def start(dir, opts \\ []) do
    credentials = issue(dir)

    {:ok, store} =
      Agent.start_link(fn -> %{sandboxes: %{}, deleting: %{}, workspaces: MapSet.new()} end)

    config = Map.new(opts) |> Map.put(:store, store)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, config},
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [
          # DER rather than paths: ssl caches a PEM file by its path, and a test that
          # rotates the certificates in place needs the new ones.
          transport_options: [
            cert: der(Path.join([dir, "server", "tls.crt"])),
            key: der(Path.join([dir, "server", "tls.key"])),
            alpn_preferred_protocols: ["h2"],
            cacerts: [der(Path.join(dir, "client-ca.crt"))],
            verify: :verify_peer,
            fail_if_no_peer_cert: false
          ]
        ]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    %{
      port: port,
      endpoint: "https://127.0.0.1:#{port}",
      credentials: credentials,
      server: server,
      store: store
    }
  end

  @doc "Whether the certificate at `cert` was signed by the CA certificate at `ca`."
  def signed_by?(cert, ca) do
    match?({:ok, _}, :public_key.pkix_path_validation(der(ca), [der(cert)], []))
  end

  defp der(path) do
    case :public_key.pem_decode(File.read!(path)) do
      [{:Certificate, der, _}] -> der
      [{type, der, _}] -> {type, der}
    end
  end

  @doc """
  Sets `:hal_c2` app env keys for one test and puts the previous values back when
  it exits. Call it from `setup`.
  """
  def put_env(env) do
    previous = for {key, _} <- env, do: {key, Application.fetch_env(:hal_c2, key)}
    for {key, value} <- env, do: Application.put_env(:hal_c2, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  @doc """
  A gateway release `{release, archive}` for `HalC2.OpenShell.Install.install/1`'s
  `:release` and `:archive`, whose binary is a shell script. Each `generate-certs`
  copies the next certificate set queued in `control/sets` (`queue_certificates/1`;
  a CA's certificate, the gateway's and a client certificate from it) and adds a CA
  key and the token key, and fails when none is left; `config preflight` exits with the number in
  `control/preflight` (0 if there is none), after sleeping the seconds in
  `control/hang` if there is one, its pid in `control/hung`. Anything else prints its environment
  and arguments. Every call is appended to `control/calls`.
  """
  def release(control, archives, version) do
    script = """
    #!/bin/sh
    control="#{control}"
    echo "$*" >> "$control/calls"
    case "$1" in
      generate-certs)
        out="$3"
        set=$(ls "$control/sets" 2>/dev/null | sort | head -n 1)
        [ -n "$set" ] || { echo "no certificates queued" >&2; exit 1; }
        mkdir -p "$out/jwt"
        cp -R "$control/sets/$set/." "$out/"
        rm -rf "$control/sets/$set"
        echo key > "$out/ca.key"
        echo s > "$out/jwt/signing.pem"; echo p > "$out/jwt/public.pem"; echo k > "$out/jwt/kid"
        exit 0 ;;
      config)
        [ -f "$control/hang" ] && { echo $$ > "$control/hung"; exec sleep "$(cat "$control/hang")"; }
        echo "preflight checked $*"
        exit "$(cat "$control/preflight" 2>/dev/null || echo 0)" ;;
    esac
    env | sort
    echo "args: $*"
    """

    File.mkdir_p!(control)
    archive = tar(archives, "gateway-#{version}.tar.gz", [{~c"openshell-gateway", script}])

    {%{
       name: "openshell-gateway-#{version}.tar.gz",
       url: "unused",
       sha256: :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower),
       version: version
     }, archive}
  end

  @doc """
  Queues the certificate sets the next two `generate-certs` calls of a release in
  `control` copy: an install or a rotation makes two, one for the gateway and one
  for the CA of the MC's client certificate. Replaces what was queued; returns the
  CA certificates in order.
  """
  def queue_certificates(control) do
    sets = Path.join(control, "sets")
    File.rm_rf!(sets)

    for n <- 1..2 do
      dir = Path.join(sets, Integer.to_string(n))
      issue(dir, :one_ca)
      File.read!(Path.join(dir, "ca.crt"))
    end
  end

  @doc "A gzipped tar at `dir/name` holding `entries` (`{charlist name, contents}`)."
  def tar(dir, name, entries) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    :ok = :erl_tar.create(to_charlist(path), entries, [:compressed])
    path
  end

  @doc "Puts a sandbox in the fake's store as if someone had created it."
  def put_sandbox(%{store: store}, name, labels) do
    Agent.update(store, &put_in(&1, [:sandboxes, name], sandbox(name, labels)))
  end

  def sandboxes(%{store: store}), do: Agent.get(store, & &1.sandboxes)

  @doc "A certificate chain from a CA of its own, for a client the gateway must not trust."
  def stranger(dir) do
    issue(dir)

    [
      ca: Path.join(dir, "ca.crt"),
      cert: Path.join([dir, "client", "tls.crt"]),
      key: Path.join([dir, "client", "tls.key"])
    ]
  end

  # `:two_cas` (the default) signs the client certificate with a CA of its own and
  # keeps that CA as `client-ca.crt`, as the MC's installer arranges; `:one_ca` is
  # what the real gateway's `generate-certs` writes.
  defp issue(dir, cas \\ :two_cas) do
    root = fn name ->
      :public_key.pkix_test_root_cert(name, key: {:namedCurve, :secp256r1}, digest: :sha256)
    end

    server_root = root.(~c"fake openshell CA")
    client_root = if cas == :one_ca, do: server_root, else: root.(~c"fake openshell client CA")

    # `pkix_test_data` names the peers itself ("server Peer cert", "client Peer cert").
    peer = fn ->
      [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [
          {:Extension, {2, 5, 29, 17}, false,
           [{:iPAddress, <<127, 0, 0, 1>>}, {:dNSName, ~c"localhost"}]}
        ]
      ]
    end

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: server_root, intermediates: [], peer: peer.()},
        client_chain: %{root: client_root, intermediates: [], peer: peer.()}
      })

    for {sub, config} <- [{"server", server}, {"client", client}] do
      File.mkdir_p!(Path.join(dir, sub))
      write_pem(Path.join([dir, sub, "tls.crt"]), [{:Certificate, config[:cert], :not_encrypted}])
      {type, der} = config[:key]
      write_pem(Path.join([dir, sub, "tls.key"]), [{type, der, :not_encrypted}])
    end

    write_pem(Path.join(dir, "ca.crt"), [{:Certificate, server_root.cert, :not_encrypted}])

    if cas == :two_cas,
      do:
        write_pem(Path.join(dir, "client-ca.crt"), [
          {:Certificate, client_root.cert, :not_encrypted}
        ])

    [
      ca: Path.join(dir, "ca.crt"),
      cert: Path.join([dir, "client", "tls.crt"]),
      key: Path.join([dir, "client", "tls.key"])
    ]
  end

  defp write_pem(path, entries) do
    File.write!(path, :public_key.pem_encode(entries))
    File.chmod!(path, 0o600)
  end

  @doc false
  def sandbox(name, labels, phase \\ :SANDBOX_PHASE_READY) do
    %Pb.Sandbox{
      metadata: %ObjectMeta{
        id: "id-" <> name,
        name: name,
        labels: labels,
        workspace: "hal-c2"
      },
      status: %Pb.SandboxStatus{phase: phase}
    }
  end

  @doc """
  A container runtime's API on a Unix socket, for `HalC2.OpenShell.Platform`'s
  probe: one JSON document per path in `routes`, 404 otherwise. Returns the socket's
  path, which must fit in 108 bytes, so it is in a short directory relative to the
  working directory. Stops with the test.
  """
  def runtime_socket(routes) do
    short = Path.join("tmp", "os-#{System.unique_integer([:positive])}")
    File.mkdir_p!(short)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(short) end)
    path = Path.join(short, "r.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :http_bin])

    test = self()

    pid =
      spawn_link(fn ->
        send(test, :listening)
        accept(listen, routes)
      end)

    receive do
      :listening -> :ok
    end

    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    path
  end

  defp accept(listen, routes) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, :GET, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    skip_headers(socket)

    {status, body} =
      case routes[path] do
        nil -> {"404 Not Found", "not found"}
        doc -> {"200 OK", Jason.encode!(doc)}
      end

    :ok = :inet.setopts(socket, packet: :raw)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(socket)
    accept(listen, routes)
  end

  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, :http_eoh} -> :ok
      {:ok, _header} -> skip_headers(socket)
    end
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias HalC2.OpenShell.Proto.Openshell.V1, as: Pb
    alias HalC2.Test.FakeOpenShell

    @impl true
    def init(config), do: config

    @impl true
    def call(%{path_info: ["openshell.v1.OpenShell", method]} = conn, config) do
      cond do
        method != "Health" and get_peer_data(conn)[:ssl_cert] == nil ->
          error(conn, 16, "no client certificate")

        method == "ExecSandboxInteractive" ->
          exec(conn, config)

        true ->
          {:ok, body, conn} = read_body(conn)
          [message] = frames(body) |> elem(0)
          unary(conn, method, message, config)
      end
    end

    def call(conn, _config), do: send_resp(conn, 404, "")

    defp unary(conn, "Health", _body, config),
      do:
        reply(conn, %Pb.HealthResponse{
          status: :SERVICE_STATUS_HEALTHY,
          version: Map.get(config, :version, "0.1.7")
        })

    defp unary(conn, "GetCurrentUser", _body, config) do
      subject =
        case get_peer_data(conn)[:ssl_cert] do
          nil -> ""
          der -> common_name(der)
        end

      reply(conn, %Pb.GetCurrentUserResponse{
        subject: subject,
        roles: Map.get(config, :roles, ["openshell-user"]),
        identity_provider: "mtls"
      })
    end

    defp unary(conn, "GetGatewayInfo", _body, config) do
      reply(conn, %Pb.GetGatewayInfoResponse{
        gateway_version: Map.get(config, :version, "0.1.7"),
        compute_drivers: [%Pb.ComputeDriverInfo{name: "podman"}]
      })
    end

    defp unary(conn, "GetWorkspace", body, config) do
      %{name: name} = Pb.GetWorkspaceRequest.decode(body)
      notify(config, "GetWorkspace", name)

      if Agent.get(config.store, &MapSet.member?(&1.workspaces, name)),
        do: reply(conn, %Pb.GetWorkspaceResponse{}),
        else: error(conn, 5, "workspace not found")
    end

    defp unary(conn, "CreateWorkspace", body, config) do
      %{name: name} = Pb.CreateWorkspaceRequest.decode(body)
      notify(config, "CreateWorkspace", name)
      Agent.update(config.store, &Map.update!(&1, :workspaces, fn w -> MapSet.put(w, name) end))
      reply(conn, %Pb.CreateWorkspaceResponse{})
    end

    defp unary(conn, "CreateSandbox", body, config) do
      request = Pb.CreateSandboxRequest.decode(body)
      notify(config, "CreateSandbox", request)
      sandbox = FakeOpenShell.sandbox(request.name, request.labels)
      Agent.update(config.store, &put_in(&1, [:sandboxes, request.name], sandbox))
      reply(conn, %Pb.SandboxResponse{sandbox: sandbox})
    end

    defp unary(conn, "GetSandbox", body, config) do
      %{name: name} = Pb.GetSandboxRequest.decode(body)
      notify(config, "GetSandbox", %{name: name})
      if hold = config[:get_sandbox], do: hold.()
      settle_deletion(config.store, name)

      case Agent.get(config.store, & &1.sandboxes[name]) do
        nil -> error(conn, 5, "sandbox not found")
        sandbox -> reply(conn, %Pb.SandboxResponse{sandbox: sandbox})
      end
    end

    defp unary(conn, "ListSandboxes", body, config) do
      request = Pb.ListSandboxesRequest.decode(body)
      notify(config, "ListSandboxes", request)

      wanted =
        for pair <- String.split(request.label_selector, ",", trim: true), into: %{} do
          [k, v] = String.split(pair, "=", parts: 2)
          {k, v}
        end

      # The fake ignores the selector's owner label when asked to, to show the MC
      # filters what it is given.
      wanted = if Map.get(config, :ignore_selector), do: %{}, else: wanted

      sandboxes =
        Agent.get(config.store, & &1.sandboxes)
        |> Map.values()
        |> Enum.filter(fn s -> Enum.all?(wanted, fn {k, v} -> s.metadata.labels[k] == v end) end)
        |> Enum.sort_by(& &1.metadata.name)

      reply(conn, %Pb.ListSandboxesResponse{sandboxes: sandboxes})
    end

    defp unary(conn, "DeleteSandbox", body, config) do
      request = Pb.DeleteSandboxRequest.decode(body)
      notify(config, "DeleteSandbox", request)

      case Map.get(config, :delete, :completed) do
        :completed ->
          Agent.update(
            config.store,
            &update_in(&1.sandboxes, fn s -> Map.delete(s, request.name) end)
          )

          reply(conn, %Pb.DeleteSandboxResponse{outcome: :DELETION_OUTCOME_COMPLETED})

        :unspecified ->
          reply(conn, %Pb.DeleteSandboxResponse{})

        # The gateway took the request; the sandbox goes after `n` more GetSandbox
        # calls (never, for `:never`).
        {:accepted, n} ->
          id = Agent.get(config.store, & &1.sandboxes[request.name].metadata.id)
          Agent.update(config.store, &put_in(&1, [:deleting, request.name], n))

          reply(conn, %Pb.DeleteSandboxResponse{
            outcome: :DELETION_OUTCOME_ACCEPTED,
            sandbox_id: id
          })

        # The old sandbox went at once and another one took its name.
        :replaced ->
          id = Agent.get(config.store, & &1.sandboxes[request.name].metadata.id)
          new = FakeOpenShell.sandbox(request.name, %{})
          new = put_in(new.metadata.id, "id-new-" <> request.name)
          Agent.update(config.store, &put_in(&1, [:sandboxes, request.name], new))

          reply(conn, %Pb.DeleteSandboxResponse{
            outcome: :DELETION_OUTCOME_ACCEPTED,
            sandbox_id: id
          })
      end
    end

    defp unary(conn, _method, _body, _config), do: error(conn, 12, "unimplemented")

    defp settle_deletion(store, name) do
      Agent.update(store, fn state ->
        case state.deleting[name] do
          nil ->
            state

          :never ->
            state

          n when n <= 1 ->
            %{
              update_in(state.sandboxes, &Map.delete(&1, name))
              | deleting: Map.delete(state.deleting, name)
            }

          n ->
            put_in(state, [:deleting, name], n - 1)
        end
      end)
    end

    # --- exec -----------------------------------------------------------------------

    defp exec(conn, config) do
      {conn, buffer, [first | rest]} = read_frames(conn, <<>>)
      %Pb.ExecSandboxInput{payload: {:start, start}} = Pb.ExecSandboxInput.decode(first)
      notify(config, "ExecSandboxInteractive", start)

      case Agent.get(config.store, & &1.sandboxes[start.sandbox]) do
        nil ->
          error(conn, 5, "sandbox not found")

        _ ->
          conn =
            conn
            |> put_resp_header("content-type", "application/grpc")
            |> send_chunked(200)

          io = %{conn: conn, buffer: buffer, pending: rest, eof: false}
          Process.put(:fake_io, io)
          run = Map.get(config, :exec, &echo/2)
          run.(start.command, io_funs())
          Process.get(:fake_io).conn
      end
    end

    # The handler's view of the stream, kept in the process dictionary so the
    # `fn command, io` contract stays a plain function of its arguments.
    defp io_funs do
      %{
        read: fn -> read_input() end,
        stdout: fn data ->
          event(%Pb.ExecSandboxEvent{payload: {:stdout, %Pb.ExecSandboxStdout{data: data}}})
        end,
        stderr: fn data ->
          event(%Pb.ExecSandboxEvent{payload: {:stderr, %Pb.ExecSandboxStderr{data: data}}})
        end,
        exit: fn code ->
          event(%Pb.ExecSandboxEvent{payload: {:exit, %Pb.ExecSandboxExit{exit_code: code}}})
        end
      }
    end

    defp echo(_command, io) do
      case io.read.() do
        {:stdin, data} ->
          io.stdout.(data)
          echo(nil, io)

        :eof ->
          io.exit.(0)

        _other ->
          echo(nil, io)
      end
    end

    defp read_input do
      io = Process.get(:fake_io)

      case io do
        %{pending: [next | rest]} ->
          Process.put(:fake_io, %{io | pending: rest})
          %Pb.ExecSandboxInput{payload: payload} = Pb.ExecSandboxInput.decode(next)
          payload

        %{eof: true} ->
          :eof

        _ ->
          case read_frames(io.conn, io.buffer) do
            {conn, buffer, frames, :eof} ->
              Process.put(:fake_io, %{io | conn: conn, buffer: buffer, pending: frames, eof: true})

              if frames == [], do: :eof, else: read_input()

            {conn, buffer, frames} ->
              Process.put(:fake_io, %{io | conn: conn, buffer: buffer, pending: frames})
              read_input()
          end
      end
    end

    defp event(event) do
      io = Process.get(:fake_io)
      # A stream the client already reset is an error, as a write to a closed pipe.
      case chunk(io.conn, frame(Pb.ExecSandboxEvent.encode(event))) do
        {:ok, conn} ->
          Process.put(:fake_io, %{io | conn: conn})
          :ok

        error ->
          error
      end
    end

    # Reads until at least one whole gRPC message is buffered, or the request ends.
    # A command waits for its stdin as long as the stream lasts, however slow the
    # client is to send it; the stream's end stops this process.
    defp read_frames(conn, buffer) do
      case read_body(conn, length: 5, read_timeout: :infinity) do
        {:more, data, conn} ->
          case frames(buffer <> data) do
            {[], rest} -> read_frames(conn, rest)
            {frames, rest} -> {conn, rest, frames}
          end

        {:ok, data, conn} ->
          {frames, rest} = frames(buffer <> data)
          {conn, rest, frames, :eof}
      end
    end

    defp frames(<<0, size::32, message::binary-size(size), rest::binary>>) do
      {more, rest} = frames(rest)
      {[message | more], rest}
    end

    defp frames(rest), do: {[], rest}

    defp frame(message), do: [0, <<IO.iodata_length(message)::32>>, message]

    # --- responses ------------------------------------------------------------------

    defp reply(conn, %module{} = message) do
      conn
      |> put_resp_header("content-type", "application/grpc")
      |> send_resp(200, frame(module.encode(message)))
    end

    defp error(conn, status, message) do
      conn
      |> put_resp_header("content-type", "application/grpc")
      |> put_resp_header("grpc-status", Integer.to_string(status))
      |> put_resp_header("grpc-message", message)
      |> send_resp(200, "")
    end

    defp notify(config, method, request) do
      if pid = Map.get(config, :notify), do: send(pid, {:openshell_request, method, request})
    end

    defp common_name(der) do
      {:OTPCertificate, {:OTPTBSCertificate, _, _, _, _, _, {:rdnSequence, rdns}, _, _, _, _}, _,
       _} =
        :public_key.pkix_decode_cert(der, :otp)

      Enum.find_value(List.flatten(rdns), "", fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, name}} -> to_string(name)
        {:AttributeTypeAndValue, {2, 5, 4, 3}, name} when is_list(name) -> to_string(name)
        _ -> nil
      end)
    end
  end
end
