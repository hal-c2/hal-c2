defmodule HalC2.SettingsSharedProofTest do
  # Shared settings between two or three MCs: records cast in any order, lost when the
  # receiving process is down, connections dropping and coming back, processes crashing
  # with their records saved, documents edited or broken while their MC is down, and
  # clocks that disagree. prop/hal_c2/settings_shared_prop_test.exs checks the merge and
  # convergence over many members and writes; this explores every interleaving up to
  # the bounds.
  @members "the member table; cluster.maude models it, and the model's MCs are all members"
  @watch "tells watchers of something else; no part of the shared records"
  @reads "reads; changes nothing"
  @names "names an MC or where it keeps its files; the model names MCs by id"

  use HalC2.Proof,
    model: "settings_shared.maude",
    module: "SETTINGS-SHARED",
    check: "SETTINGS-SHARED-PROPS",
    timeout: 600_000,
    code: [
      {:exports, HalC2.Settings.Shared},
      {:messages, HalC2.Settings},
      {:state, HalC2.Settings},
      {:messages, HalC2.Cluster}
    ],
    covers: %{
      "HalC2.Settings.Shared.local/5" => ~w(local put restart),
      "HalC2.Settings.Shared.merge/2" => ~w(merge),
      "HalC2.Settings.Shared.stamp/2" => "stamp",
      "HalC2.Settings.Shared.newest/1" => "stamp",
      "HalC2.Settings.Shared.apply/2" => "merge",
      "HalC2.Settings handle_call {:put, _, _}" => "put",
      "HalC2.Settings handle_call {:update, _}" => "put",
      "HalC2.Settings handle_cast {:keybindings_changed, _}" => "put",
      "HalC2.Settings handle_cast {:merge_shared, _}" => ~w(put merge),
      "HalC2.Settings handle_info :check" => "put",
      "HalC2.Settings state :settings" => "mc",
      "HalC2.Settings state :shared" => "mc",
      "HalC2.Settings state :held" => "mc",
      "HalC2.Cluster handle_cast :share_settings" => "share",
      "HalC2.Cluster handle_cast {:settings, _, _}" => "merge",
      "HalC2.Cluster handle_info {:nodeup, _}" => "nodeup",
      "HalC2.Cluster handle_info :gossip" => "gossip",
      "HalC2.Cluster handle_call :peers" => "connect"
    },
    abstracts: %{
      "HalC2.Settings.Shared.units/0" =>
        "names the shared keys; the model has one, as keys merge one by one",
      "HalC2.Settings.Shared.document_keys/0" =>
        "names the shared keys; the model has one, as keys merge one by one",
      "HalC2.Settings.Shared.sealed_keys/0" =>
        "names the keys never shared, which a compile-time check keeps out of the list",
      "HalC2.Settings.Shared.sanitize/1" =>
        "drops what a member sends that this MC does not share or cannot hold; the model's records are all well formed",
      "HalC2.Settings handle_call {:watch, _, _}" => @watch,
      "HalC2.Settings handle_cast {:unwatch, _, _}" => @watch,
      "HalC2.Settings handle_cast :providers_changed" => @watch,
      "HalC2.Settings handle_cast {:usage_limit_sources_changed, _}" => @watch,
      "HalC2.Settings handle_cast {:upgraded, _}" => @watch,
      "HalC2.Settings handle_cast {:themes_changed, _}" => @watch,
      "HalC2.Settings handle_info {:DOWN, _, :process, _, _}" => @watch,
      "HalC2.Settings state :path" => @names,
      "HalC2.Settings state :id" => @names,
      "HalC2.Settings state :watchers" => @watch,
      "HalC2.Settings state :version" =>
        "advances on every save, a merged one included; the stale check is settings_prop_test's",
      "HalC2.Settings state :stamp" =>
        "the file's hash, which the check compares; put stands for the check adopting an edit",
      "HalC2.Cluster handle_call :status" => @reads,
      "HalC2.Cluster handle_call :fingerprint" => @reads,
      "HalC2.Cluster handle_call :entry" => @members,
      "HalC2.Cluster handle_call {:admit, _}" => @members,
      "HalC2.Cluster handle_call {:joined, _, _, _}" => @members,
      "HalC2.Cluster handle_call {:remove, _}" => @members,
      "HalC2.Cluster handle_call _" => @members,
      "HalC2.Cluster handle_cast {:merge, _}" => @members,
      "HalC2.Cluster handle_cast :version_changed" => @members,
      "HalC2.Cluster handle_cast _" =>
        "drops what this version does not know, as an older MC drops {:settings, _, _}",
      "HalC2.Cluster handle_info {:nodedown, _}" =>
        "does nothing; the connection dropping is disconnect"
    },
    environment: %{
      "crash" => "an MC's processes die, and their mailboxes with them; connections stay",
      "disconnect" => "a connection drops, and the casts in flight on it",
      "edit" => "settings.json is edited or broken while its MC is down",
      "clock" => "time passes",
      "pick" => "draws records for the laws of merge/2"
    },
    scenarios: %{
      "connections/cluster.feature" => [
        "A shared setting changed on one member reaches the others",
        "A shared setting reset on one member is reset on the others",
        "A setting changed while a member was offline reaches it when it is back",
        "Changes made apart converge on the newer one"
      ]
    }

  @fair ~w(merge share nodeup gossip connect restart)

  test "merging records does not depend on their order, grouping or repetition",
       %{proof: proof} do
    refute_reachable(proof, "laws", "broken", [])
  end

  # One search per start refutes all three: no MC takes back a change it held, a
  # running MC's document says what its record does, and every write outranks what its
  # MC had held.
  for init <- ["two(2, 2, 1, 1, 1)", "three(1, 1, 1, 0, 0)"] do
    test "no change is taken back, torn from its document or misordered, from #{init}",
         %{proof: proof} do
      refute_reachable(proof, unquote(init), "unsafe", [])
    end
  end

  # A document broken for good is held, and takes nothing until a write mends it, so
  # the starts break none.
  for init <- ["two(2, 1, 1, 0, 1)", "three(1, 1, 1, 0, 0)"] do
    test "every member ends up with the newest change, from #{init}", %{proof: proof} do
      assert_ltl(proof, unquote(init), "<> [] agreed", fair: @fair)
    end
  end
end
