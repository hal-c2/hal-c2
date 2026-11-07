defmodule HalC2.MuseUsageLimitTest do
  # A Muse turn that fails on the subscription quota (hal-c2#1287) is a usage limit,
  # driven through the fake `muse serve`, whose turn ends `failed` with Muse's quota error.
  use ExUnit.Case, async: false

  alias HalC2.{Orchestration, StreamState}

  @moduletag :tmp_dir
  @tid "muse-limit-thread"
  @fake Path.expand("../support/fake_muse_msp.py", __DIR__)
  # A day on, whole seconds: a reset already past is no limit.
  @reset_ms div(System.os_time(:millisecond), 1000) * 1000 + 86_400_000
  @message "API error 429: Subscription quota exhausted. (rate_limit_error)"

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)

    on_exit(fn ->
      HalC2.Acp.forget("muse")
      if previous, do: Application.put_env(:hal_c2, :home, previous)
    end)

    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

    start_supervised!({HalC2.Store, path: Path.join(dir, "hal-c2.sqlite")})
    start_supervised!(HalC2.Streams)
    start_supervised!(HalC2.Shell)
    start_supervised!(HalC2.Orchestration.TurnWatch)
    start_supervised!({Registry, keys: :unique, name: HalC2.Muse.Registry})

    for {name, id} <- [
          {HalC2.Codex.Registry, :codex},
          {HalC2.Claude.Registry, :claude},
          {HalC2.Acp.Registry, :acp},
          {HalC2.Pi.Registry, :pi}
        ],
        do: start_supervised!({Registry, keys: :unique, name: name}, id: id)

    start_supervised!({DynamicSupervisor, name: HalC2.Codex.Supervisor, strategy: :one_for_one})
    start_supervised!(HalC2.Settings)
    HalC2.Acp.forget("muse")

    {:ok, %{work: work, dir: dir}}
  end

  defp muse(dir, error, extra \\ %{}) do
    fake = Path.join(dir, "fake-muse")
    File.mkdir_p!(Path.join(fake, "bin"))

    File.write!(
      Path.join(fake, "config.json"),
      JSON.encode!(
        Map.merge(
          %{"turns" => [%{"match" => "go", "steps" => [%{"fail" => error}]}]},
          extra
        )
      )
    )

    bin = Path.join([fake, "bin", "muse"])
    File.write!(bin, "#!/bin/sh\nexport FAKE_DIR='#{fake}'\nexec python3 -u '#{@fake}' \"$@\"\n")
    File.chmod!(bin, 0o755)

    {:ok, _} =
      HalC2.Settings.put(
        %{"providers" => %{"muse" => %{"enabled" => true, "binaryPath" => bin}}},
        0
      )
  end

  # Sends "go" and waits on the stream for the run to fail.
  defp fail_run(work) do
    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "thread.create",
        "threadId" => @tid,
        "projectId" => "project-1",
        "title" => "Muse",
        "modelSelection" => %{"instanceId" => "muse", "model" => "fake/one"},
        "runtimeMode" => "full-access",
        "interactionMode" => "default",
        "worktreePath" => work
      })

    :ok = HalC2.Streams.subscribe(@tid, self(), nil)

    {:ok, _} =
      Orchestration.dispatch(%{
        "type" => "message.dispatch",
        "threadId" => @tid,
        "messageId" => "m1",
        "text" => "go",
        "attachments" => [],
        "modelSelection" => %{"instanceId" => "muse", "model" => "fake/one"},
        "dispatchMode" => %{"type" => "queue_after_active"},
        "deliveryIntent" => "auto"
      })

    await_failed()
  end

  defp await_failed do
    state = HalC2.Streams.Server.state(HalC2.Streams.ensure(@tid))

    if Enum.any?(StreamState.list(state, "run"), &(&1["status"] == "failed")) do
      state
    else
      receive do
        {:hal_c2_stream, @tid, _} -> await_failed()
      after
        15_000 -> flunk("the run did not fail")
      end
    end
  end

  test "a quota error is a usage limit with its reset", %{dir: dir, work: work} do
    muse(dir, %{
      "kind" => "modelError",
      "message" => @message,
      "quota" => %{"limitKind" => "tierLimit", "resetsAtMs" => @reset_ms},
      "retryable" => false
    })

    state = fail_run(work)
    thread = HalC2.Projection.Shell.thread_shell(state)
    reset = @reset_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert thread["lastErrorClass"] == "usage_limit"
    assert thread["usageLimitResetAt"] == reset

    assert [%{"title" => "Usage limit reached", "failure" => failure}] =
             for(i <- StreamState.list(state, "turn-item"), i["type"] == "error", do: i)

    assert %{"class" => "usage_limit", "code" => "tierLimit", "message" => @message} = failure
  end

  test "any other failure is a provider error with its message", %{dir: dir, work: work} do
    muse(dir, %{"kind" => "modelError", "message" => "model fell over"})

    state = fail_run(work)
    thread = HalC2.Projection.Shell.thread_shell(state)

    assert thread["lastErrorClass"] == "provider_error"

    assert [%{"title" => "Provider error", "failure" => %{"message" => "model fell over"}}] =
             for(i <- StreamState.list(state, "turn-item"), i["type"] == "error", do: i)
  end

  test "a plain rate limit without a quota fails the turn and is not Limited", %{
    dir: dir,
    work: work
  } do
    muse(dir, %{"kind" => "modelError", "message" => @message, "retryable" => false})

    state = fail_run(work)
    thread = HalC2.Projection.Shell.thread_shell(state)

    assert thread["lastErrorClass"] == "provider_error"
    assert thread["usageLimitResetAt"] == nil
  end

  test "a quota refusal of turn/start is a usage limit with its reset", %{dir: dir, work: work} do
    muse(dir, %{}, %{
      "refuseStart" => %{
        "message" => @message,
        "data" => %{"quota" => %{"limitKind" => "tierLimit", "resetsAtMs" => @reset_ms}}
      }
    })

    state = fail_run(work)
    thread = HalC2.Projection.Shell.thread_shell(state)

    assert thread["lastErrorClass"] == "usage_limit"

    assert thread["usageLimitResetAt"] ==
             @reset_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end
end
