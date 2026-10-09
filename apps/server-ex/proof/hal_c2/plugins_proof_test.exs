defmodule HalC2.PluginsProofTest do
  # The plugin host with two plugins and two watchers, their workers crashing, clients
  # enabling, restarting and saving settings, scans, and the host itself restarting, all
  # with messages in any order. prop/hal_c2/plugins_prop_test.exs runs the code one step
  # at a time; this explores every interleaving up to the bounds.
  #
  # The model abstracts the supervisor's restart window as a count of crashes: its
  # fourth crash ends the supervisor. Messages from one process reach the host in the
  # order they were sent, and a client's call is one step.
  @reads "answers a question from the plugin tables; changes nothing the model keeps"
  @topics "topics and what a plugin publishes: not part of a plugin's lifecycle"
  @consent "permissions and the settings a plugin declares: not part of its lifecycle"
  @dispatch "decodes a client's request into the calls the model lists"

  use HalC2.Proof,
    model: "plugins.maude",
    module: "PLUGINS",
    check: "PLUGINS-PROPS",
    code: [
      {:exports, HalC2.Plugins},
      {:messages, HalC2.Plugins},
      {:state, HalC2.Plugins}
    ],
    covers: %{
      "HalC2.Plugins.start_worker/3" => "worker",
      "HalC2.Plugins.subscribe/1" => "subscribe",
      "HalC2.Plugins.unsubscribe/1" => "unsubscribe",
      "HalC2.Plugins handle_call {:set_enabled, _, _, _}" => "set_enabled",
      "HalC2.Plugins handle_call {:restart, _}" => "restart",
      "HalC2.Plugins handle_call {:save_settings, _, _}" => "save_settings",
      "HalC2.Plugins handle_call :rescan" => "rescan",
      "HalC2.Plugins handle_call {:subscribe, _}" => "subscribe",
      "HalC2.Plugins handle_cast {:worker, _, _, _}" => "worker",
      # Queued across an update in place; it is the cast above, from the running supervisor.
      "HalC2.Plugins handle_cast {:worker, _, _}" => "worker",
      "HalC2.Plugins handle_cast {:unsubscribe, _}" => "unsubscribed",
      "HalC2.Plugins handle_info {:hal_c2_settings, _, _}" => "settings",
      "HalC2.Plugins handle_info {:DOWN, _, :process, _, _}" =>
        ~w(worker-down supervisor-down watcher-down),
      "HalC2.Plugins state :plugins" => "pl",
      "HalC2.Plugins state :refs" => ~w(smon mo)
    },
    abstracts: %{
      "HalC2.Plugins.start_link/1" => "starts the host; kill-host stands for its starting again",
      "HalC2.Plugins.handle/2" => @dispatch,
      "HalC2.Plugins.adapters/0" => @reads,
      "HalC2.Plugins.api_version/0" => @reads,
      "HalC2.Plugins.declared/1" => @consent,
      "HalC2.Plugins.denied/2" => @consent,
      "HalC2.Plugins.granted/1" => @consent,
      "HalC2.Plugins.git_host/1" => @reads,
      "HalC2.Plugins.provider/1" => @reads,
      "HalC2.Plugins.providers/0" => @reads,
      "HalC2.Plugins.running?/2" => @reads,
      "HalC2.Plugins.sessions/1" => @reads,
      "HalC2.Plugins.text_backend?/1" => @reads,
      "HalC2.Plugins.tools/1" => @reads,
      "HalC2.Plugins.call_tool/3" => "runs a plugin's tool in the caller's process",
      "HalC2.Plugins.generate/3" => "runs a plugin's text generation in the caller's process",
      "HalC2.Plugins.pull_requests/2" => "asks a plugin's git host in the caller's process",
      "HalC2.Plugins.turn_finished/2" => "tells the plugins of a finished turn, in a task",
      "HalC2.Plugins.publish/3" => @topics,
      "HalC2.Plugins.subscribe_topic/3" => @topics,
      "HalC2.Plugins.unsubscribe_topic/3" => @topics,
      "HalC2.Plugins handle_call :list" => @reads,
      "HalC2.Plugins handle_call {:running, _}" => @reads,
      "HalC2.Plugins handle_call {:running?, _}" => @reads,
      "HalC2.Plugins handle_call {:context, _}" => @reads,
      "HalC2.Plugins handle_call {:file, _, _}" => @reads,
      "HalC2.Plugins handle_call {:subscribe_topic, _, _, _}" => @topics,
      "HalC2.Plugins handle_cast {:unsubscribe_topic, _, _, _}" => @topics,
      "HalC2.Plugins handle_cast {:publish, _, _, _}" => @topics,
      "HalC2.Plugins handle_cast {:denied, _, _}" => @consent,
      "HalC2.Plugins handle_info _" => "ignores what it does not know",
      "HalC2.Plugins state :dir" =>
        "where plugins are scanned from; the model has two fixed plugins",
      "HalC2.Plugins state :supervisor" =>
        "the dynamic supervisor that starts each plugin's supervisor; the model starts sv itself"
    },
    environment: %{
      "crash" => "a plugin's worker is killed; its supervisor starts it again, or gives up",
      "ext-write" => "a client edits the settings document itself",
      "kill-host" => "the host stops and starts again under its supervisor",
      "watcher-dies" => "a client that follows the list goes away",
      "unsubscribe" => "a client stops following the list"
    },
    scenarios: %{
      "plugins/mc-plugins.feature" => [
        "Enabling a plugin starts it for that environment only",
        "Disabling a plugin stops it and removes what it contributed",
        "Re-enabling a plugin restores it with its saved settings",
        "The enabled set survives an MC restart",
        "A crashing plugin is restarted without touching the rest of the MC",
        "A plugin that keeps crashing is stopped and reported",
        "A failed plugin can be restarted by the user",
        "Plugin settings reach every client of the MC",
        "Removing a plugin from the directory stops it on the next scan"
      ],
      "plugins/plugin-packages.feature" => [
        "Clients see the plugin list change as it happens"
      ]
    }

  # Rules the environment may or may not take.
  @faults ~w(crash ext-write kill-host watcher-dies unsubscribe set_enabled restart
             save_settings rescan subscribe)
  @fair ~w(worker worker-down supervisor-down watcher-down unsubscribed settings)

  # two(a, b, c): the first plugin's worker crashes a times (four give its supervisor up),
  # the second's once; clients make b calls; c watcher events come.
  @bounds ["two(4, 1, 0)", "two(2, 2, 0)", "two(1, 1, 1)"]

  for init <- @bounds do
    test "a plugin runs exactly when it is on and not failed, once the host is idle, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "drift", [])
    end

    test "a stopped plugin's crash count never changes, nor a restarted one's from an earlier run, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "ghost", [])
    end

    test "the providers table has a row for each running plugin and no other, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "provbad", [])
    end

    test "a plugin's supervisor is monitored once, and only while it runs, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "monbad", [])
    end

    test "a following watcher has the current list once the host is idle, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "viewbad", [])
    end
  end

  test "the host never gets stuck with a message it cannot take", %{proof: proof} do
    refute_deadlock(proof, "two(1, 1, 1)", "idle", besides: @faults)
  end

  test "the check is not vacuous: a host that ignores which supervisor crashed is caught",
       %{proof: proof} do
    assert_raise ExUnit.AssertionError, fn ->
      refute_reachable(proof, "twou(1, 2, 0)", "ghost", [])
    end
  end

  # Assumes the host takes its messages (the weak fairness of @fair) and that no client
  # call or restart of the host stops the plugin first: that would cancel the DOWN.
  test "a supervisor that gives up leaves the plugin failed and every watcher told",
       %{proof: proof} do
    formula = "[] (dying(p1) -> <> (failed(p1) /\\ ~ unpushed(p1)))"
    assert_ltl(proof, "two(4, 0, 1)", formula, fair: @fair)
  end
end
