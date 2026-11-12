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
end
