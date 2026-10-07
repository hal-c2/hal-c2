defmodule HalC2.AuthLifetimeTest do
  use ExUnit.Case, async: false

  alias HalC2.Auth

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(Auth)
    start = System.os_time(:millisecond)
    Application.put_env(:hal_c2, :auth_now, start)
    on_exit(fn -> Application.delete_env(:hal_c2, :auth_now) end)
    %{path: Path.join(dir, "hal-c2.sqlite")}
  end

  defp session(path) do
    {:ok, access, _, _} = Auth.exchange(Auth.create_pairing_token(path))
    {:ok, session} = Auth.session(access)
    {access, session}
  end

  defp advance(ms), do: Application.put_env(:hal_c2, :auth_now, Auth.now() + ms)

  test "a ticket bought before its session was revoked opens nothing", %{path: path} do
    {access, %{id: id}} = session(path)
    {:ok, ticket, _} = Auth.issue_ticket(access)

    assert Auth.revoke_client(id)
    assert Auth.take_ticket(ticket) == :error
    assert Auth.ticket_scopes(ticket) == :error
  end

  test "a ticket does not outlive its session", %{path: path} do
    {:ok, access, _, _} = Auth.exchange(Auth.create_pairing_token(path), %{proof_jkt: "key"})
    {:ok, %{expires_at: expires} = session} = Auth.session(access)

    # Fifty-eight minutes into the session's hour, a ticket would last past it.
    advance(58 * 60_000)
    assert {:ok, ticket, ticket_expires} = Auth.issue_ticket(session)
    assert ticket_expires == expires

    advance(3 * 60_000)
    assert Auth.take_ticket(ticket) == :error
  end

  test "prune drops what expired and nothing else", %{path: path} do
    {access, _} = session(path)
    {:ok, ticket, _} = Auth.issue_ticket(access)
    _unused = Auth.create_pairing_token(path)

    assert %{pairing: 0, sessions: 0, tickets: 0} = Auth.prune()

    advance(6 * 60_000)
    assert %{pairing: 1, sessions: 0, tickets: 1} = Auth.prune()
    assert Auth.take_ticket(ticket) == :error
    assert {:ok, _} = Auth.session(access)

    advance(31 * 24 * 3_600_000)
    assert %{sessions: 1} = Auth.prune()
    assert Auth.session(access) == :error
  end

  test "restarting the process keeps pairing tokens and sessions", %{path: path} do
    {access, _} = session(path)
    pairing = Auth.create_pairing_token(path)

    :ok = stop_supervised(Auth)
    start_supervised!(Auth)

    assert {:ok, _} = Auth.session(access)
    assert {:ok, _, _, _} = Auth.exchange(pairing)
  end

  test "a crash of the server keeps tickets, accepted proofs, open sockets and watchers",
       %{path: path} do
    {access, %{id: id}} = session(path)
    {:ok, ticket, _} = Auth.issue_ticket(access)
    proofs = :ets.whereis(Auth.Dpop.table())
    test = self()

    socket =
      spawn_link(fn ->
        Auth.connected(id)
        send(test, :connected)
        receive do: (message -> send(test, {:socket, message}))
      end)

    assert_receive :connected
    {:ok, revision, _} = Auth.subscribe(self())
    assert [%{"connected" => true}] = Auth.clients()

    crash_server()

    # The replay table is the one that recorded the proofs it accepted.
    assert :ets.whereis(Auth.Dpop.table()) == proofs
    assert [%{"connected" => true}] = Auth.clients()
    assert {:ok, ^id} = Auth.take_ticket(ticket)

    # The watcher is still told, in the same run of revisions, and the socket closes.
    assert Auth.revoke_client(id)
    assert_receive {:hal_c2_auth_access, %{"revision" => next, "type" => "clientRemoved"}}
    assert next > revision
    assert_receive {:socket, {:hal_c2_session_revoked, ^id}}
    refute Process.alive?(socket)
  end

  defp crash_server do
    server = Process.whereis(Auth)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    # The supervisor has started it again once it answers.
    :sys.get_state(HalC2.Auth.Supervisor)
  end
end
