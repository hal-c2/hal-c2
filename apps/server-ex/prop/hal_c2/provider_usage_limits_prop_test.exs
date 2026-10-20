defmodule HalC2.ProviderUsageLimitsPropTest do
  @moduledoc """
  `HalC2.ProviderUsageLimits` against a model of the windows it publishes per
  instance. Probes read the fake provider CLIs, whose windows are the
  constants the unit test asserts; the promise modelled here is the routing
  between probes: a turn's sparse update or Claude event merges by window id
  into its own instance only (keeping a known reset or duration the update
  omits), a probe redraws exactly its instance, an `unsupported` instance is
  frozen against turn updates while its neighbours are not, the overage
  bucket takes each instance's own probed name, and a hot upgrade from the
  single-name state keeps that name for the built-in instance only.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.ProviderUsageLimits, as: Limits
  alias HalC2.Settings

  @moduletag timeout: :infinity

  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../../test/support/fake_claude.py", __DIR__)

  @codex ~w(codex codex-work)
  @claude ~w(claudeAgent claude-work)
  @instances @codex ++ @claude

  @epoch "2026-09-21T14:13:20.000Z"

  # What the fakes' probes publish, as {usedPercent, resetsAt, windowDurationMins}
  # by window id (the unit test pins the full shaping). The second account of
  # each driver is in settings (see `setup/0`), so every instance is probed and
  # no entry is swept as a missing provider's.
  @baseline %{
    "codex" => %{
      "primary" => {42.0, "2026-09-21T14:13:20.000Z", 300},
      "secondary" => {10.5, "2026-09-27T09:06:40.000Z", 10_080}
    },
    "claudeAgent" => %{
      "five_hour" => {30.0, "2026-09-24T15:00:00.123Z", 300},
      "seven_day" => {55.5, nil, 10_080},
      "seven_day_fable_1" => {12.0, "2026-09-30T00:00:00.000Z", 10_080}
    }
  }
  @driver %{
    "codex" => "codex",
    "codex-work" => "codex",
    "claudeAgent" => "claudeAgent",
    "claude-work" => "claudeAgent"
  }

  property "each instance keeps its own windows across updates, probes and upgrades",
    numtests: HalC2.Prop.numtests(50),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        teardown()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp setup do
    HalC2.Prop.scratch_home("provider-usage-limits")
    Application.put_env(:hal_c2, :codex_command, ["python3", @fake_codex])
    Application.put_env(:hal_c2, :claude_command, ["python3", @fake_claude])
    HalC2.Prop.start_services([Settings, Limits])

    {:ok, _} =
      Settings.put(
        %{
          "providerInstances" => %{
            "codex-work" => %{"driver" => "codex", "enabled" => true, "displayName" => "Work"},
            "claude-work" => %{
              "driver" => "claudeAgent",
              "enabled" => true,
              "displayName" => "Work"
            }
          }
        },
        0
      )

    # Waits for the probes of every instance.
    :ok = Limits.refresh(nil)

    # As a second Claude account's probe would leave its bucket name.
    :sys.replace_state(Limits, fn state ->
      %{state | claude_names: %{"claudeAgent" => "Fable 1", "claude-work" => "Opus 2"}}
    end)
  end

  defp teardown do
    HalC2.Prop.stop_services()
    Application.delete_env(:hal_c2, :codex_command)
    Application.delete_env(:hal_c2, :claude_command)
    System.delete_env("FAKE_CODEX_ACCOUNT")
  end

  # --- model ------------------------------------------------------------------

  # windows: instance => window id => {usedPercent, resetsAt, mins}; names: the
  # overage bucket name each Claude instance's probe saw; frozen: instances a
  # probe found unsupported, whose turn updates are ignored.
  def initial_state do
    %{
      windows: Map.new(@instances, fn instance -> {instance, @baseline[@driver[instance]]} end),
      names: %{"claudeAgent" => "Fable 1", "claude-work" => "Opus 2"},
      frozen: MapSet.new()
    }
  end

  def command(_state) do
    frequency([
      {5,
       {:call, __MODULE__, :update,
        [oneof(@codex), oneof(~w(primary secondary)), integer(0, 120), boolean(), boolean()]}},
      {5,
       {:call, __MODULE__, :claude_event,
        [
          oneof(@claude),
          oneof(~w(five_hour seven_day seven_day_overage_included)),
          integer(0, 100)
        ]}},
      {2, {:call, __MODULE__, :probe, [oneof(@instances)]}},
      {1, {:call, __MODULE__, :unsupported_probe, []}},
      {1, {:call, __MODULE__, :code_change_old, []}},
      {4, {:call, __MODULE__, :read, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :update, [instance, id, percent, resets?, mins?]}) do
    window = {norm(min(max(percent, 0), 100)), if(resets?, do: @epoch), if(mins?, do: 300)}
    merge_window(state, instance, id, window)
  end

  def next_state(state, _result, {:call, _, :claude_event, [instance, type, percent]}) do
    used = norm(percent / 100 * 100)

    case type do
      "five_hour" ->
        merge_window(state, instance, "five_hour", {used, @epoch, 300})

      "seven_day" ->
        merge_window(state, instance, "seven_day", {used, @epoch, 10_080})

      "seven_day_overage_included" ->
        case state.names[instance] do
          nil ->
            state

          name ->
            merge_window(state, instance, "seven_day_" <> slug(name), {used, @epoch, 10_080})
        end
    end
  end

  def next_state(state, _result, {:call, _, :probe, [instance]}) do
    state
    |> put_in([:windows, instance], @baseline[@driver[instance]])
    |> Map.update!(:frozen, &MapSet.delete(&1, instance))
    |> then(fn state ->
      # A probe names its overage bucket again: the fake always sees Fable 1.
      if instance in @claude,
        do: put_in(state.names[instance], "Fable 1"),
        else: state
    end)
  end

  def next_state(state, _result, {:call, _, :unsupported_probe, []}) do
    state
    |> put_in([:windows, "codex"], %{})
    |> Map.update!(:frozen, &MapSet.put(&1, "codex"))
  end

  def next_state(state, _result, {:call, _, :code_change_old, []}),
    do: %{state | names: %{"claudeAgent" => "Fable 1"}}

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :read, _}, view), do: view == state.windows
  def postcondition(_state, _call, result), do: result == :ok

  # A sparse update upserts by id and keeps a known reset or duration it omits;
  # a frozen (unsupported) instance's windows do not move.
  defp merge_window(state, instance, id, {used, resets, mins}) do
    if instance in state.frozen do
      state
    else
      existing = state.windows[instance][id]
      {_used, old_resets, old_mins} = existing || {nil, nil, nil}
      window = {used, resets || old_resets, mins || old_mins}
      put_in(state.windows[instance][id], window)
    end
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
  defp norm(number), do: Float.round(number * 1.0, 6)

  # --- calls --------------------------------------------------------------------

  def update(instance, id, percent, resets?, mins?) do
    window =
      %{
        "id" => id,
        "kind" => if(id == "primary", do: "session", else: "weekly"),
        "label" => if(id == "primary", do: "Session", else: "Weekly"),
        "usedPercent" => percent
      }
      |> Limits.put_present("resetsAt", if(resets?, do: @epoch))
      |> Limits.put_present("windowDurationMins", if(mins?, do: 300))

    Limits.update(instance, [window])
    settle()
  end

  def claude_event(instance, type, percent) do
    Limits.claude_event(instance, %{
      "rateLimitType" => type,
      "utilization" => percent / 100,
      "resetsAt" => 1_790_000_000
    })

    settle()
  end

  def probe(instance), do: Limits.refresh([instance])

  def unsupported_probe do
    System.put_env("FAKE_CODEX_ACCOUNT", "apiKey")
    result = Limits.refresh(["codex"])
    System.delete_env("FAKE_CODEX_ACCOUNT")
    result
  end

  # What a hot upgrade meets from before bucket names were per instance: one
  # name, which `code_change/3` keeps for the built-in instance only.
  def code_change_old do
    pid = Process.whereis(Limits)
    :sys.replace_state(pid, fn state -> %{state | claude_names: "Fable 1"} end)
    :ok = :sys.suspend(pid)
    :ok = :sys.change_code(pid, Limits, nil, :hot)
    :ok = :sys.resume(pid)
    settle()
  end

  def read, do: Map.new(@instances, fn instance -> {instance, view(Limits.get(instance))} end)

  # Casts are handled before this call returns.
  defp settle do
    _ = :sys.get_state(Limits)
    :ok
  end

  defp view(nil), do: %{}

  defp view(limits) do
    Map.new(limits["windows"] || [], fn window ->
      {window["id"],
       {norm(window["usedPercent"]), window["resetsAt"], window["windowDurationMins"]}}
    end)
  end
end
