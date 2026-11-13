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

    assert HalC2.Web.local_mc({nil, port}) == {:ok, "http://127.0.0.1:#{port}", token}
  end

  test "a program holding the MC's port is never sent the token" do
    token = HalC2.Web.token()
    port = squat(fn _path -> ok_json(~s({"proof":"a guess"})) end)

    assert {:error, message} = HalC2.Web.local_mc({nil, port})
    assert message =~ "answers at http://127.0.0.1:#{port}"
    assert_receive {:request, request}
    refute request =~ token
    refute request =~ ~r/authorization/i
  end

  # The MC proves the address and port it was reached at, so a program on another
  # loopback port gets a proof that is not for its own.
  test "a program passing the challenge on to the real MC is not taken for it" do
    mc = start_mc()

    relay = squat(fn path -> ok_json(relayed("127.0.0.1", mc, path)) end)
    assert {:error, _} = HalC2.Web.local_mc({nil, relay})
    assert_receive {:request, _}

    redirect =
      squat(fn path ->
        "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:#{mc}#{path}\r\n" <>
          "content-length: 0\r\nconnection: close\r\n\r\n"
      end)

    assert {:error, _} = HalC2.Web.local_mc({nil, redirect})
    assert_receive {:request, _}
  end

  # An MC bound to 127.0.0.2 leaves 127.0.0.1 on its port free: a tool configured with
  # the default host would dial whatever takes it, which passes the challenge on.
  test "a local tool reaches the MC where it binds, not where the tool is configured" do
    mc = start_mc("127.0.0.2")
    token = HalC2.Web.token()

    relay = squat(fn path -> ok_json(relayed("127.0.0.2", mc, path)) end, mc)
    assert {:error, _} = HalC2.Web.local_mc({nil, mc})
    assert_receive {:request, _}

    assert HalC2.Web.running_listener() == {"127.0.0.2", mc}
    assert HalC2.Web.local_mc() == {:ok, "http://127.0.0.2:#{mc}", token}
    assert relay == mc
  end

  test "an MC on every interface is reached on IPv4 loopback" do
    port = start_mc("::")

    assert HalC2.Web.local_mc({"::", port}) ==
             {:ok, "http://127.0.0.1:#{port}", HalC2.Web.token()}
  end

  # Only an address the MC itself holds: on a loopback port it leaves free, a squatter
  # could relay the challenge to it over a connection from loopback.
  test "a local tool reaches the MC only at an address the MC holds" do
    for {host, expected} <- [
          {nil, "127.0.0.1"},
          {"127.0.0.1", "127.0.0.1"},
          {"127.72.0.57", "127.72.0.57"},
          {"0.0.0.0", "127.0.0.1"},
          {"::", "127.0.0.1"},
          {"localhost", "127.0.0.1"},
          {"::1", nil},
          {"192.168.1.5", nil},
          {"fd7a:115c:a1e0::1", nil},
          {"mc.example", nil}
        ],
        do: assert(HalC2.Web.loopback_host(host) == expected, inspect(host))

    HalC2.Web.token()
    assert {:error, message} = HalC2.Web.local_mc({"192.168.1.5", 1})
    assert message =~ "listens on 192.168.1.5 only"
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

  # This home's MC on a port of its own, bound to `host`, stopped with the test. Its
  # runtime record says where, as a running MC's does.
  defp start_mc(host \\ "127.0.0.1") do
    for {key, value} <- [port: 0, host: host] do
      previous = Application.fetch_env(:hal_c2, key)
      Application.put_env(:hal_c2, key, value)

      on_exit(fn ->
        with {:ok, value} <- previous, do: Application.put_env(:hal_c2, key, value)
        if previous == :error, do: Application.delete_env(:hal_c2, key)
      end)
    end

    {:ok, {_ip, port}} = ThousandIsland.listener_info(start_supervised!(HalC2.Web))
    File.mkdir_p!(Path.dirname(HalC2.RuntimeRecord.path()))
    File.write!(HalC2.RuntimeRecord.path(), JSON.encode!(HalC2.RuntimeRecord.record()))
    port
  end

  # What the MC at `host:port` answers to `path`, as a program passing it on gets it.
  defp relayed(host, port, path) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {~c"http://#{host}:#{port}#{path}", []}, [], body_format: :binary)

    body
  end

  # A program on 127.0.0.1 (on `port`, else any) answering one request with
  # `answer.(path)`; the test is sent the request it read.
  defp squat(answer, port \\ 0) do
    {:ok, listen} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
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
