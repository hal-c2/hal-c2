defmodule HalC2.WebTokenTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  # The token lives in the MC home; without one this would read or create the
  # developer's real access token.
  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    :persistent_term.erase({HalC2.Web, :token})
    on_exit(fn -> :persistent_term.erase({HalC2.Web, :token}) end)
  end

  test "the MC's access token only authenticates from this machine" do
    token = HalC2.Web.token()

    for {ip, expected} <- [
          {{127, 0, 0, 1}, :ok},
          {{0, 0, 0, 0, 0, 0, 0, 1}, :ok},
          # IPv4-mapped loopback, as a dual-stack `::` listener reports it.
          {{0, 0, 0, 0, 0, 65_535, 32_512, 1}, :ok},
          {{192, 168, 1, 5}, :error},
          {{100, 64, 0, 2}, :error},
          {{0, 0, 0, 0, 0, 65_535, 49_152, 257}, :error}
        ] do
      conn =
        conn(:get, "/api/auth/session")
        |> Map.put(:remote_ip, ip)
        |> put_req_header("authorization", "Bearer " <> token)

      case expected do
        :ok -> assert {:ok, %{id: nil}} = HalC2.Auth.authenticate(conn)
        :error -> assert {:error, "invalid_credential", nil} = HalC2.Auth.authenticate(conn)
      end
    end
  end

  # Tailscale Serve proxies the tailnet to the loopback listener.
  test "a request a proxy on this machine forwarded is not local" do
    token = HalC2.Web.token()

    for header <- ["x-forwarded-for", "forwarded", "tailscale-user-login"] do
      conn =
        conn(:get, "/api/auth/session")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header(header, "100.64.0.2")

      assert {:error, "invalid_credential", nil} = HalC2.Auth.authenticate(conn), header
    end
  end

  # The listener cannot tell a raw TCP forward from a local process, so what HAL-C2
  # publishes itself is Serve's HTTPS reverse proxy, which marks what it forwards
  # (`tailscale serve --https`), never a `--tcp` forward. The stand-in fails on anything
  # but `--https`.
  test "HAL-C2 publishes over Tailscale as a proxy that marks what it forwards",
       %{tmp_dir: dir} do
    state = Path.join(dir, "tailscale.json")
    File.write!(state, JSON.encode!(%{"self" => %{"DNSName" => "box.tail.ts.net."}}))
    saved = Application.get_env(:hal_c2, :tailscale_command)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:hal_c2, :tailscale_command, saved),
        else: Application.delete_env(:hal_c2, :tailscale_command)
    end)

    Application.put_env(:hal_c2, :tailscale_command, [
      "env",
      "FAKE_TAILSCALE_STATE=#{state}",
      Path.expand("../support/fake_tailscale.py", __DIR__)
    ])

    assert {:ok, "https://box.tail.ts.net"} = HalC2.TailscaleServe.publish(3780)

    assert %{"serve" => %{"box.tail.ts.net:443" => "http://127.0.0.1:3780"}} =
             state |> File.read!() |> JSON.decode!()
  end

  test "a local tool gets the token for this home's MC, which proves it holds it" do
    previous = Application.get_env(:hal_c2, :port)
    Application.put_env(:hal_c2, :port, 0)
    on_exit(fn -> Application.put_env(:hal_c2, :port, previous) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    token = HalC2.Web.token()

    assert HalC2.Web.local_mc(port) == {"http://127.0.0.1:#{port}", token}
  end

  test "a program holding the MC's port is never sent the token" do
    token = HalC2.Web.token()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(test, {:request, request})
      body = ~s({"proof":"a guess"})

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

      :gen_tcp.close(socket)
    end)

    assert HalC2.Web.local_mc(port) == nil
    assert_receive {:request, request}
    refute request =~ token
    refute request =~ ~r/authorization/i
  end

  test "the MC answers a proof only for a challenge, and only from this machine" do
    challenge = String.duplicate("a", 32)
    path = "/.well-known/hal-c2/proof?challenge=#{challenge}"

    assert HalC2.Web.Router.call(conn(:get, "/.well-known/hal-c2/proof"), []).status == 400

    conn = HalC2.Web.Router.call(conn(:get, path), [])
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["proof"] == HalC2.Web.proof(HalC2.Web.token(), challenge)

    # A squatter on loopback relaying the challenge to an MC on a LAN address, or
    # through a proxy on this machine, gets no proof.
    lan = conn(:get, path) |> Map.put(:remote_ip, {192, 168, 1, 5})
    assert HalC2.Web.Router.call(lan, []).status == 403

    proxied = conn(:get, path) |> put_req_header("x-forwarded-for", "100.64.0.2")
    assert HalC2.Web.Router.call(proxied, []).status == 403
  end
end
