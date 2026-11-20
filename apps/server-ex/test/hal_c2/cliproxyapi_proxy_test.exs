Code.require_file("../../../../plugins/cliproxyapi/mc/proxy.ex", __DIR__)

defmodule HalC2.CliProxyApiProxyTest do
  @moduledoc """
  Regressions in how the CLIProxyAPI plugin supervises its binary
  (`HalC2Plugins.CliProxyApi.Proxy`, in `plugins/cliproxyapi/mc`), run against
  `test/support/fake_cli_proxy_api.sh`. The rest of the supervisor is
  `prop/hal_c2/cliproxyapi_prop_test.exs`, the plugin process
  `features/plugins/cliproxyapi.feature`.
  """
  use ExUnit.Case, async: false

  alias HalC2Plugins.CliProxyApi.Proxy

  @binary Path.expand("../support/fake_cli_proxy_api.sh", __DIR__)

  setup %{tmp_dir: dir} do
    prior = Application.fetch_env(:hal_c2, :cliproxyapi)
    Application.put_env(:hal_c2, :cliproxyapi, backoff_ms: {10, 10})
    start()

    on_exit(fn ->
      if proxy = Process.whereis(Proxy), do: GenServer.stop(proxy)

      case prior do
        {:ok, value} -> Application.put_env(:hal_c2, :cliproxyapi, value)
        :error -> Application.delete_env(:hal_c2, :cliproxyapi)
      end
    end)

    %{spec: fn password -> spec(dir, password) end}
  end

  @tag :tmp_dir
  test "a proxy a dead MC left running is stopped before the next one starts", %{spec: spec} do
    %{"pid" => left} = Proxy.run(spec.("a"))
    kill_supervisor()
    assert alive?(left)

    start()
    %{"state" => "running", "pid" => pid} = Proxy.run(spec.("a"))

    # Gone by the time the new one runs: it held the port the new one listens on.
    refute alive?(left)
    assert alive?(pid)
    Proxy.halt()
  end

  @tag :tmp_dir
  test "a restart timer that fired as another run came in starts no second proxy", %{spec: spec} do
    %{"pid" => first} = Proxy.run(spec.("a"))
    System.cmd("kill", ["-USR1", to_string(first)])
    assert_receive {:cliproxyapi_proxy, %{"state" => "restarting"}}, 5_000

    %{"pid" => pid} = Proxy.run(spec.("b"))
    # What the timer left in the mailbox if it fired before `run/1` cancelled it.
    send(Proxy, :restart)

    assert %{"state" => "running", "pid" => ^pid, "restarts" => 0} = Proxy.status()
    Proxy.halt()
    refute alive?(pid)
  end

  defp start do
    {:ok, _} = GenServer.start(Proxy, nil, name: Proxy)
    :ok
  end

  defp kill_supervisor do
    proxy = Process.whereis(Proxy)
    ref = Process.monitor(proxy)
    Process.exit(proxy, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  defp spec(dir, password) do
    %{
      binary: @binary,
      args: ["-config", Path.join(dir, "config.yaml")],
      env: %{"MANAGEMENT_PASSWORD" => password, "WRITABLE_PATH" => dir},
      cd: dir,
      pidfile: Path.join(dir, "cli-proxy-api.pid")
    }
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
end
