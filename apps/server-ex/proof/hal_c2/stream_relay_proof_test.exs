defmodule HalC2.StreamRelayProofTest do
  # A thread's stream and two sockets following it, one on another MC behind a relay,
  # through follows, unfollows, commits, relay crashes, a socket dying and the MCs
  # parting. Each check runs with only the order Erlang promises (`pairs`) and with
  # the order the runtime gives (`nodes`).
  @other "not a thread's stream"
  @plain "the MC's own subscribers, untagged; no socket follows a thread so"
  @more "pages a subscriber's window; what it sends goes the way commit's events go"
  @shell "the sidebar row, which no subscription is sent"

  use HalC2.Proof,
    model: "stream_relay.maude",
    module: "STREAM-RELAY",
    check: "STREAM-RELAY-PROPS",
    code: [
      {:exports, HalC2.Streams.Relay},
      {:exports, HalC2.Streams.Server},
      {:messages, HalC2.Streams.Server},
      {:state, HalC2.Streams.Server},
      {:messages, HalC2.Web.Socket}
    ],
    covers: %{
      "HalC2.Streams.Relay.start/2" => ~w(relay-start start),
      "HalC2.Streams.Relay.loop/1" => "relay-loop",
      "HalC2.Streams.Server.follow/4" => ~w(call answer followed follow-failed),
      "HalC2.Streams.Server.subscribe/4" => ~w(call answer),
      "HalC2.Streams.Server.unsubscribe/3" => "cast",
      "HalC2.Streams.Server.commit/3" => "commit",
      "HalC2.Streams.Server.transact/3" => "commit",
      "HalC2.Streams.Server handle_call {:subscribe, _, _, _}" =>
        ~w(subscribe replaced drop start watch killed),
      "HalC2.Streams.Server handle_call {:commit, _, _}" => ~w(commit subscribers),
      "HalC2.Streams.Server handle_call {:transact, _, _}" => ~w(commit subscribers),
      "HalC2.Streams.Server handle_cast {:unsubscribe, _}" => ~w(unsubscribe drop killed),
      "HalC2.Streams.Server handle_cast {:unsubscribe, _, _}" => ~w(unsubscribe dropping),
      "HalC2.Streams.Server handle_info {:DOWN, _, :process, _, _}" => ~w(down drop),
      "HalC2.Streams.Server handle_info {:EXIT, _, :normal}" => "relay-exit",
      "HalC2.Streams.Server handle_info {:EXIT, _, _}" => ~w(relay-failed stop),
      "HalC2.Web.Socket handle_info {:hal_c2_stream, {_, _}, _}" =>
        ~w(stream-message stream-resync stale),
      "HalC2.Web.Socket handle_info {:DOWN, _, :process, _, _}" => "stream-down",
      "HalC2.Web.Socket handle_info _" => "stale-reply",
      "HalC2.Streams.Server state :stream" => "st",
      "HalC2.Streams.Server state :subscribers" => "of",
      "HalC2.Streams.Server state :relays" => "rly"
    },
    abstracts: %{
      "HalC2.Streams.Server state :v" => "the version of the state, which no step changes",
      "HalC2.Streams.Server state :id" => "names the stream; the model has one",
      "HalC2.Streams.Server state :path" => "where the stream is stored; the model has its seq",
      "HalC2.Streams.Server state :snapshot_seq" =>
        "when the next snapshot is due; a snapshot changes no subscription",
      "HalC2.Streams.Server state :shell_scheduled" => @shell,
      "HalC2.Streams.Server.start_link/1" => "starts the stream, which the model has running",
      "HalC2.Streams.Server.subscribe/3" => @plain,
      "HalC2.Streams.Server.watch/2" => @plain,
      "HalC2.Streams.Server.more/3" => @more,
      "HalC2.Streams.Server.handle/1" => "names a log; sends nothing",
      "HalC2.Streams.Server.idle_stop/0" => "a constant; the idle stop is another model's",
      "HalC2.Streams.Server.state/1" => "reads the state; changes nothing",
      "HalC2.Streams.Server.flush_shell/1" => @shell,
      "HalC2.Streams.Server handle_call {:commit, _, []}" => "commits nothing, sends nothing",
      "HalC2.Streams.Server handle_call {:more, _, _}" => @more,
      "HalC2.Streams.Server handle_cast {:more, _, _}" => @more,
      "HalC2.Streams.Server handle_call :state" => "reads the state; changes nothing",
      "HalC2.Streams.Server handle_call :flush_shell" => @shell,
      "HalC2.Streams.Server handle_info :shell" => @shell,
      "HalC2.Streams.Server handle_info :timeout" =>
        "the idle stop, of a stream with no subscribers; another model's",
      "HalC2.Web.Socket handle_info {:hal_c2_stream, _, _}" =>
        "untagged, for a subscription followed before an upgrade in place; the model's follows are tagged",
      "HalC2.Web.Socket handle_info :flush" =>
        "pushes frames already in order to the client; changes no subscription",
      "HalC2.Web.Socket handle_info {:rpc_reply, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_shell, {:rows, _, _, _}}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_shell, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_terminal, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_server_update, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_relay_client_install, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_upgraded, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_git_action, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_settings, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_themes, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_usage_limit_sources, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_keybindings, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_providers_changed, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_usage_limits_command, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_auth_access, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_resource_telemetry, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_preview_automation, _, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_preview, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_local_servers, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_devices, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_project_clones, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_scheduled_tasks, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_background_policy, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_pull_request_refreshes, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_plugins, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_plugin_topic, _, _, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_worktree_setup, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_provider_install, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_provider_auth, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_vcs, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_terminals, _, _}" => @other,
      "HalC2.Web.Socket handle_info {:hal_c2_session_revoked, _}" => @other
    },
    environment: %{
      "deliver" => "the runtime moves a message along its lane into a mailbox",
      "follow" => "a client asks its socket to follow the thread",
      "unfollow" => "a client stops following the thread",
      "relay-crash" => "`initial` raises in a relay",
      "subscriber-down" => "a socket goes",
      "nodedown" => "the MCs lose each other",
      "heal" => "they reach each other again",
      "time-out" => "an :erpc call to follow/4 gives up"
    },
    scenarios: %{
      "connections/cluster.feature" => [
        "A thread on another member streams through the connected MC",
        "A client whose relay on another member fails follows the thread again",
        "A client follows a thread on another member by its environment"
      ],
      "mc/platform/websocket-protocol.feature" => [
        "A subscription starts with a snapshot and then goes live",
        "A client resumes a thread from the offset it last saw",
        "A client stops following one thread and keeps the other"
      ],
      "connections/connection-health.feature" => [
        "A cluster connection resumes each stream from where it stopped"
      ]
    }

  # What clients and faults may or may not do; the code's own steps may not stop.
  @besides ~w(follow unfollow commit relay-crash subscriber-down nodedown heal time-out)

  for mode <- ~w(pairs nodes) do
    test "a subscription is sent what it starts from, live, then each commit once, " <>
           "and no relay takes the stream down, in #{mode} order",
         %{proof: proof} do
      refute_reachable(proof, "relay(#{unquote(mode)}, 1, 2, 1)", "broken", [])
    end
  end

  # The socket behind a relay alone: with sa as well the quiescence search is too big.
  for {mode, commits, follows} <- [{"nodes", 1, 2}, {"pairs", 0, 2}, {"pairs", 1, 1}] do
    test "a socket behind a relay ends up with every commit or told to follow again, " <>
           "and no relay or subscription is left over, in #{mode} order, " <>
           "#{commits} commits, #{follows} follows",
         %{proof: proof} do
      init = "alone(sb, #{unquote(mode)}, #{unquote(commits)}, #{unquote(follows)}, 1)"
      refute_deadlock(proof, init, "settled", besides: @besides)
    end
  end
end
