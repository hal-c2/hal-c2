defmodule HalC2.Steps.Navigation.KeybindingCustomisation do
  @moduledoc """
  Steps for `features/navigation/keybinding-customisation.feature`. Clients add and
  remove rules with `server.upsertKeybinding` and `server.removeKeybinding`; the
  node's rules are `HalC2.Keybindings.rules/0` and `<home>/keybindings.json`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # --- the node stores custom rules --------------------------------------------------

  step "the node has no custom keybindings", context do
    assert HalC2.Keybindings.rules() == []
    refute File.exists?(file(context))
    context
  end

  step "a client adds the rule {string} for {string}", %{args: [key, command]} = context do
    add(context, rule(key, command))
  end

  step "a client adds the rule {string} for {string} again", %{args: [key, command]} = context do
    add(context, rule(key, command))
  end

  step "a client adds the rule {string} for {string} replacing the old rule",
       %{args: [key, command]} = context do
    add(context, rule(key, command), %{"replace" => context.rule})
  end

  step "the node's keybindings include that rule", context do
    assert {:ok, %{"rules" => rules}} = context.reply
    assert context.rule in rules
    assert context.rule in HalC2.Keybindings.rules()
    context
  end

  step "keybindings.json contains that rule", context do
    assert context.rule in JSON.decode!(File.read!(file(context)))
    context
  end

  step "the node has the rule {string} for {string}", %{args: [key, command]} = context do
    rule = rule(key, command)
    assert {:ok, _} = HalC2.Keybindings.upsert(rule)
    Map.put(context, :rule, rule)
  end

  step "the node has exactly one such rule", context do
    assert Enum.count(HalC2.Keybindings.rules(), &(&1 == context.rule)) == 1
    context
  end

  step "the node's keybindings include {string} for {string}",
       %{args: [key, command]} = context do
    assert rule(key, command) in HalC2.Keybindings.rules()
    context
  end

  step "they no longer include {string} for {string}", %{args: [key, command]} = context do
    refute rule(key, command) in HalC2.Keybindings.rules()
    context
  end

  step "a client removes that rule", context do
    {reply, context} = World.call(context, "server.removeKeybinding", context.rule)
    assert {:ok, _} = reply
    Map.put(context, :reply, reply)
  end

  step "the node's keybindings no longer include it", context do
    refute context.rule in HalC2.Keybindings.rules()
    refute context.rule in JSON.decode!(File.read!(file(context)))
    context
  end

  step "the node has {int} custom rules", %{args: [count]} = context do
    rules = for i <- 1..count, do: rule("mod+shift+#{i}", "terminal.new")
    File.write!(file(context), JSON.encode!(rules))
    assert length(HalC2.Keybindings.rules()) == count
    Map.merge(context, %{oldest: hd(rules), rule_count: count})
  end

  step "a client adds one more rule", context do
    add(context, rule("mod+alt+n", "chat.new"))
  end

  step "the node keeps {int} rules", %{args: [count]} = context do
    rules = HalC2.Keybindings.rules()
    assert length(rules) == count
    assert List.last(rules) == context.rule
    context
  end

  step "the oldest rule is gone", context do
    refute context.oldest in HalC2.Keybindings.rules()
    context
  end

  step "one client adds a keybinding rule", context do
    Node.ensure(HalC2.Settings)
    context = World.put_client(context, "second", Node.config(World.client(context, "second")))
    add(context, rule("mod+shift+t", "terminal.new"), %{}, "first")
  end

  step "the other client receives the updated keybindings", context do
    {frame, client} =
      Node.await(
        World.client(context, "second"),
        &(&1["t"] == "config.keybindings" and context.rule in &1["rules"])
      )

    assert frame["rules"] == HalC2.Keybindings.rules()
    World.put_client(context, "second", client)
  end

  step "a client adds a keybinding rule", context do
    add(context, rule("mod+shift+t", "terminal.new"))
  end

  # Replaced in one step: a new file is renamed over the old one, so the path
  # names a new inode after every write and no partial file is left beside it.
  step "keybindings.json is replaced in one step", context do
    %{inode: before} = File.stat!(file(context))
    context = add(context, rule("mod+shift+y", "terminal.new"))
    %{inode: after_write} = File.stat!(file(context))

    assert after_write != before
    assert context.rule in JSON.decode!(File.read!(file(context)))

    assert File.ls!(Path.dirname(file(context))) |> Enum.filter(&(&1 =~ "keybindings")) == [
             "keybindings.json"
           ]

    context
  end

  step "keybindings.json contains a rule and a bare string", context do
    rule = rule("mod+j", "terminal.toggle")
    File.write!(file(context), JSON.encode!([rule, "mod+k"]))
    Map.put(context, :rule, rule)
  end

  step "the node reads the keybindings", context do
    client =
      Node.sub(World.client(context), 1, %{"type" => "config", "node" => Atom.to_string(node())})

    {frame, client} = Node.await(client, &(&1["t"] == "config"))

    context
    |> World.put_client(client)
    |> Map.put(:read_rules, frame["config"]["keybindingRules"])
  end

  step "only the rule is returned", context do
    assert context.read_rules == [context.rule]
    context
  end

  # --- limits ----------------------------------------------------------------------------

  step ~r/^a client adds a rule whose (?<part>key|condition|script id) is (?<size>.+)$/,
       %{args: [part, size]} = context do
    rule =
      case {part, size} do
        {"key", "longer than 64 characters"} ->
          rule("mod+" <> String.duplicate("k", 61), "terminal.new")

        {"condition", "longer than 256 characters"} ->
          Map.put(
            rule("mod+g", "diff.toggle"),
            "when",
            Enum.join(List.duplicate("terminalFocus", 20), " && ")
          )

        {"condition", "nested deeper than 64 levels"} ->
          condition = String.duplicate("(", 65) <> "terminalFocus" <> String.duplicate(")", 65)
          Map.put(rule("mod+g", "diff.toggle"), "when", condition)

        {"script id", "longer than 24 characters"} ->
          rule("mod+alt+r", "script.#{String.duplicate("a", 25)}.run")

        {"script id", "starting with a dash"} ->
          rule("mod+alt+r", "script.-test.run")
      end

    {reply, context} = World.call(context, "server.upsertKeybinding", rule)
    Map.merge(context, %{rule: rule, reply: reply})
  end

  step "the rule is rejected", context do
    assert {:error, error, _detail} = context.reply
    assert error =~ "Invalid keybinding rule"
    refute context.rule in HalC2.Keybindings.rules()
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp file(context), do: Path.join(context.node.home, "keybindings.json")

  defp rule(key, command), do: %{"key" => key, "command" => command}

  defp add(context, rule, extra \\ %{}, client \\ "default") do
    {reply, context} =
      World.call(context, "server.upsertKeybinding", Map.merge(rule, extra), client)

    assert {:ok, _} = reply
    Map.merge(context, %{rule: rule, reply: reply})
  end
end
