defmodule HalC2.AuthRevokeProofTest do
  # Revoking a client while its tickets are being issued and its sockets are opening, with
  # messages in any order. prop/hal_c2/auth_prop_test.exs runs the code on sequences of
  # calls; this explores every interleaving of the Auth process and the callers' and
  # sockets' steps for two sessions, three tickets and two sockets.
  @outside "a store write or read that no socket or ticket race depends on"
  @socket_traffic "the socket's other messages, which neither read nor change its session's scopes"

  use HalC2.Proof,
    model: "auth_revoke.maude",
    module: "AUTH-REVOKE",
    check: "AUTH-REVOKE-PROPS",
    code: [
      {:exports, HalC2.Auth},
      {:messages, HalC2.Auth},
      {:messages, HalC2.Web.Socket}
    ],
    covers: %{
      "HalC2.Auth.issue_ticket/1" => ~w(issueInsert issueOk issueWithdraw issueWithdrawTaken),
      "HalC2.Auth.take_ticket/1" => "take",
      "HalC2.Auth.connected/1" => "connect",
      "HalC2.Auth.session_scopes/1" => ~w(readFull readNone),
      "HalC2.Auth.revoke_client/1" =>
        ~w(revokeStart revokeRows revokeRowsNone revokeTicket revokeTicketsDone revokeClose revokeDone),
      "HalC2.Auth.revoke_session/2" => "revokeRows",
      "HalC2.Auth handle_cast {:connected, _, _}" => ~w(registerLive registerGone),
      "HalC2.Auth handle_call {:revoke_client, _}" =>
        ~w(revokeStart revokeRows revokeRowsNone revokeTicket revokeTicketsDone revokeClose revokeDone),
      "HalC2.Web.Socket handle_info {:hal_c2_session_revoked, _}" => "socketCloses"
    },
    abstracts: %{
      "HalC2.Web.Socket handle_info _" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_stream, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_stream, {_, _}, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_shell, {:rows, _, _, _}}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_shell, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_terminal, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_server_update, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_relay_client_install, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_upgraded, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_git_action, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_settings, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_themes, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_usage_limit_sources, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_keybindings, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_providers_changed, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_usage_limits_command, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_auth_access, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_resource_telemetry, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_preview_automation, _, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_preview, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_local_servers, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_devices, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_project_clones, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_scheduled_tasks, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_background_policy, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_pull_request_refreshes, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_plugins, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_plugin_topic, _, _, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_worktree_setup, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_provider_install, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_provider_auth, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_vcs, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:hal_c2_terminals, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:rpc_reply, _, _}" => @socket_traffic,
      "HalC2.Web.Socket handle_info :flush" => @socket_traffic,
      "HalC2.Web.Socket handle_info {:DOWN, _, :process, _, _}" => @socket_traffic,
      "HalC2.Auth.create_pairing_token/2" => @outside,
      "HalC2.Auth.exchange/2" => @outside,
      "HalC2.Auth.session/1" => @outside,
      "HalC2.Auth.authenticate/1" => @outside,
      "HalC2.Auth.local_session/0" => @outside,
      "HalC2.Auth.request_session/1" => @outside,
      "HalC2.Auth.list_sessions/1" => @outside,
      "HalC2.Auth.ticket_scopes/1" => @outside,
      "HalC2.Auth.standard_scopes/0" => @outside,
      "HalC2.Auth.create_pairing_link/1" => @outside,
      "HalC2.Auth.pairing_links/0" => @outside,
      "HalC2.Auth.revoke_pairing_link/1" => @outside,
      "HalC2.Auth.clients/0" => @outside,
      "HalC2.Auth.revoke_other_clients/1" =>
        "the same revoke as revoke_client/1, for every other session",
      "HalC2.Auth.prune/0" => @outside,
      "HalC2.Auth.subscribe/1" => @outside,
      "HalC2.Auth.unsubscribe/1" => @outside,
      "HalC2.Auth.start_link/1" => @outside,
      "HalC2.Auth.now/0" => @outside,
      "HalC2.Auth.session_method/1" => @outside,
      "HalC2.Auth handle_call {:exchange, _, _}" => @outside,
      "HalC2.Auth handle_call {:create_link, _}" => @outside,
      "HalC2.Auth handle_call :prune" => @outside,
      "HalC2.Auth handle_call :links" => @outside,
      "HalC2.Auth handle_call {:revoke_link, _}" => @outside,
      "HalC2.Auth handle_call :clients" => @outside,
      "HalC2.Auth handle_call {:revoke_others, _}" => "as revoke_client/1",
      "HalC2.Auth handle_call {:subscribe, _}" => @outside,
      "HalC2.Auth handle_cast {:unsubscribe, _}" => @outside,
      "HalC2.Auth handle_info :prune" => @outside,
      "HalC2.Auth handle_info {:DOWN, _, :process, _, _}" => @outside,
      "HalC2.Auth handle_info {:\"ETS-TRANSFER\", _, _, _}" => @outside
    },
    environment: %{},
    scenarios: %{
      "mc/platform/auth-and-scopes.feature" => [
        "A session buys a single-use socket ticket",
        "A ticket request without a valid session is refused",
        "Revoking a client closes the sockets it has open"
      ]
    }

  test "no ticket is handed out for a revoked session", %{proof: proof} do
    refute_reachable(proof, "initial", "badTicket", [])
  end

  test "no socket of a revoked session is registered", %{proof: proof} do
    refute_reachable(proof, "initial", "badLive", [])
  end

  test "a socket of a revoked session never stays open with its scopes", %{proof: proof} do
    refute_reachable(proof, "initial", "badOpen", [])
  end

  test "a ticket opens at most one socket", %{proof: proof} do
    refute_reachable(proof, "initial", "badReuse", [])
  end

  test "@live only holds sockets of existing sessions between messages", %{proof: proof} do
    refute_reachable(proof, "initial", "badLiveGone", [])
  end
end
