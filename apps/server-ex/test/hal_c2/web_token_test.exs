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
    port = start_mc()
    token = HalC2.Web.token()

    assert HalC2.Web.local_mc(port) == {"http://127.0.0.1:#{port}", token}
  end

  test "a program holding the MC's port is never sent the token" do
    token = HalC2.Web.token()
    port = squat(fn _path -> ok_json(~s({"proof":"a guess"})) end)

    assert HalC2.Web.local_mc(port) == nil
    assert_receive {:request, request}
    refute request =~ token
    refute request =~ ~r/authorization/i
  end

  # The MC proves the address and port it was reached at, so a program on another
  # loopback port gets a proof that is not for its own.
  test "a program passing the challenge on to the real MC is not taken for it" do
    mc = start_mc()

    relay =
      squat(fn path ->
        {:ok, {{_, 200, _}, _, body}} =
          :httpc.request(:get, {~c"http://127.0.0.1:#{mc}#{path}", []}, [], body_format: :binary)

        ok_json(body)
      end)

    assert HalC2.Web.local_mc(relay) == nil
    assert_receive {:request, _}

    redirect =
      squat(fn path ->
        "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:#{mc}#{path}\r\n" <>
          "content-length: 0\r\nconnection: close\r\n\r\n"
      end)

    assert HalC2.Web.local_mc(redirect) == nil
    assert_receive {:request, _}
  end

  # Only an address the MC itself holds: on a loopback port it leaves free, a squatter
  # could relay the challenge to it over a connection from loopback.
  test "a local tool reaches the MC only at an address the MC holds" do
    for {host, expected} <- [
          {"127.0.0.1", "127.0.0.1"},
          {"127.72.0.57", "127.72.0.57"},
          {"::1", "[::1]"},
          {"0.0.0.0", "127.0.0.1"},
          {"::", "127.0.0.1"},
          {"localhost", "127.0.0.1"},
          {"192.168.1.5", nil},
          {"fd7a:115c:a1e0::1", nil},
          {"mc.example", nil}
        ],
        do: assert(HalC2.Web.loopback_host(host) == expected, host)

    HalC2.Web.token()
    previous = Application.fetch_env(:hal_c2, :host)
    Application.put_env(:hal_c2, :host, "192.168.1.5")

    on_exit(fn ->
      with {:ok, host} <- previous, do: Application.put_env(:hal_c2, :host, host)
      if previous == :error, do: Application.delete_env(:hal_c2, :host)
    end)

    assert HalC2.Web.local_mc(1) == nil
  end

  test "the MC answers a proof only for a challenge, and only from this machine" do
    challenge = String.duplicate("a", 32)
    path = "/.well-known/hal-c2/proof?challenge=#{challenge}"

    assert HalC2.Web.Router.call(conn(:get, "/.well-known/hal-c2/proof"), []).status == 400

    conn = HalC2.Web.Router.call(conn(:get, path), [])
    assert conn.status == 200
    # Plug.Test's connection ends at 127.0.0.1:111318.
    expected = HalC2.Web.proof(HalC2.Web.token(), challenge, {{127, 0, 0, 1}, 111_318})
    assert JSON.decode!(conn.resp_body)["proof"] == expected
    assert expected != HalC2.Web.proof(HalC2.Web.token(), challenge, {{127, 0, 0, 1}, 111_319})

    # A squatter on loopback relaying the challenge to an MC on a LAN address, or
    # through a proxy on this machine, gets no proof.
    lan = conn(:get, path) |> Map.put(:remote_ip, {192, 168, 1, 5})
    assert HalC2.Web.Router.call(lan, []).status == 403

    proxied = conn(:get, path) |> put_req_header("x-forwarded-for", "100.64.0.2")
    assert HalC2.Web.Router.call(proxied, []).status == 403
  end

  # This home's MC on a port of its own, stopped with the test.
  defp start_mc do
    previous = Application.fetch_env(:hal_c2, :port)
    Application.put_env(:hal_c2, :port, 0)

    on_exit(fn ->
      with {:ok, port} <- previous, do: Application.put_env(:hal_c2, :port, port)
      if previous == :error, do: Application.delete_env(:hal_c2, :port)
    end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    port
  end

  # A program on a loopback port answering one request with `answer.(path)`; the test
  # is sent the request it read.
  defp squat(answer) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(test, {:request, request})
      [_, path | _] = String.split(request, " ", parts: 3)
      :gen_tcp.send(socket, answer.(path))
      :gen_tcp.close(socket)
    end)

    port
  end

  defp ok_json(body) do
    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end
end
