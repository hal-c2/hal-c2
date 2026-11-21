Code.require_file("../../../../plugins/cliproxyapi/mc/api.ex", __DIR__)

defmodule HalC2.CliProxyApiApiTest do
  @moduledoc """
  Regressions in the CLIProxyAPI plugin's management client
  (`HalC2Plugins.CliProxyApi.Api`, in `plugins/cliproxyapi/mc`). The rest of it runs
  through `features/plugins/cliproxyapi.feature`.
  """
  use ExUnit.Case, async: true

  alias HalC2Plugins.CliProxyApi.Api

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # `{:redirect, url}` answers every request with a redirect there; `{:record, pid}`
    # sends the test the Authorization header of each request it is sent.
    def call(conn, {:redirect, url}) do
      conn |> put_resp_header("location", url) |> send_resp(302, "")
    end

    def call(conn, {:record, pid}) do
      send(pid, {:authorization, get_req_header(conn, "authorization")})
      conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
    end
  end

  test "a redirect from the proxy is not followed with the management key" do
    elsewhere = serve({:record, self()})
    proxy = serve({:redirect, "http://127.0.0.1:#{elsewhere}/stolen"})

    assert {:error, :http, _} =
             Api.get(%{base: "http://127.0.0.1:#{proxy}", key: "management-key"}, "/config")

    refute_received {:authorization, _}
  end

  defp serve(plug) do
    pid = start_supervised!({Bandit, plug: {Server, plug}, port: 0, ip: :loopback}, id: plug)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
