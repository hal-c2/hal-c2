defmodule HalC2.TracesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    previous = for key <- [:home, :trace], do: {key, Application.fetch_env(:hal_c2, key)}
    Application.put_env(:hal_c2, :home, home)
    Application.put_env(:hal_c2, :trace, true)

    start_supervised!(
      Supervisor.child_spec({Registry, keys: :duplicate, name: HalC2.Traces.Registry},
        id: :registry
      )
    )

    on_exit(fn ->
      for {key, previous} <- previous do
        case previous do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  test "a span's receipt arrives once the span is in the trace file" do
    :ok = HalC2.Traces.subscribe("provider.turn")
    HalC2.Traces.finished("other", %{}, System.system_time(:millisecond))
    HalC2.Traces.finished("provider.turn", %{"run.id" => "r1"}, System.system_time(:millisecond))

    assert_receive {:hal_c2_span, "provider.turn", %{"run.id" => "r1"}}
    refute_received {:hal_c2_span, "other", _}
    assert File.read!(HalC2.Traces.path()) =~ ~s("name":"provider.turn")
  end

  test "a span that could not be written sends no receipt", %{tmp_dir: home} do
    # The home is a file, so the logs directory cannot be made.
    blocked = Path.join(home, "blocked")
    File.write!(blocked, "")
    Application.put_env(:hal_c2, :home, blocked)

    :ok = HalC2.Traces.subscribe("provider.turn")

    ExUnit.CaptureLog.capture_log(fn ->
      HalC2.Traces.finished("provider.turn", %{}, System.system_time(:millisecond))
    end)

    refute_received {:hal_c2_span, "provider.turn", _}
  end

  test "subscribing where the registry is not running is a no-op" do
    stop_supervised!(:registry)
    assert HalC2.Traces.subscribe("provider.turn") == :ok
    HalC2.Traces.finished("provider.turn", %{}, System.system_time(:millisecond))
    refute_received {:hal_c2_span, _, _}
  end
end
