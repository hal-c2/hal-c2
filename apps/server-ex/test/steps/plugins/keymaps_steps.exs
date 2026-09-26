defmodule HalC2.Steps.Plugins.Keymaps do
  @moduledoc """
  Steps for the node's part of `features/plugins/keymaps.feature`: the node stores
  the user's keybinding rules in `<home>/keybindings.json` and pushes them to every
  config watcher. Defaults are not the node's; clients merge the stored rules over
  `@hal-c2/shared/keybindings`, so a key without a stored rule does its default.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node
  alias HalC2.Test.Node.World

  # The built-in keymap belongs to each client; the node starts with no rules of its
  # own, so what a client does with a key the user never bound is its built-in.
  step "the built-in keymap binds {string} to {string} and {string} to {string}",
       %{args: [key, command, other_key, other_command]} = context do
    assert HalC2.Keybindings.rules() == []
    Map.put(context, :built_ins, %{key => command, other_key => other_command})
  end

  step "the user binds {string} to {string} on the first client",
       %{args: [key, command]} = context do
    context = watch(context, "second")

    {_, context} =
      World.call!(context, "halc2.upsertKeybinding", %{"key" => key, "command" => command}, "first")

    Map.put(context, :rule, %{"key" => key, "command" => command})
  end

  step "the second client receives the new rule", context do
    {rules, context} = pushed(context, "second")
    assert context.rule in rules
    context
  end

  step "the user bound {string} to {string}", %{args: [key, command]} = context do
    rule = %{"key" => key, "command" => command}
    {%{"rules" => rules}, context} = World.call!(context, "halc2.upsertKeybinding", rule)
    assert rule in rules
    Map.put(context, :rule, rule)
  end

  step "the user removes that rule", context do
    context = watch(context, "watcher")
    {_, context} = World.call!(context, "halc2.removeKeybinding", context.rule)
    context
  end

  step "{string} does what it does by default", %{args: [key]} = context do
    # With no stored rule for the key, clients fall back to their default binding.
    {rules, context} = pushed(context, "watcher")
    refute Enum.any?(rules, &(&1["key"] == key))
    refute Enum.any?(HalC2.Keybindings.rules(), &(&1["key"] == key))
    context
  end

  step "the node's keybindings file contains one valid rule and one entry without a command",
       context do
    valid = %{"key" => "ctrl+shift+n", "command" => "thread.new"}
    file = Path.join(Application.fetch_env!(:hal_c2, :home), "keybindings.json")
    File.write!(file, JSON.encode!([valid, %{"key" => "ctrl+shift+k"}]))
    Map.put(context, :rule, valid)
  end

  step "a client reads the keybindings", context do
    Node.ensure(HalC2.Settings)
    client = Node.sub(World.client(context, "reader"), 1, config_shape())
    {%{"config" => config}, client} = Node.await(client, &(&1["t"] == "config"))

    context
    |> World.put_client("reader", client)
    |> Map.put(:rules, config["keybindingRules"])
  end

  step "only the valid rule is applied", context do
    assert context.rules == [context.rule]
    context
  end

  # A client subscribed to the node's config, past its snapshot.
  defp watch(context, name) do
    Node.ensure(HalC2.Settings)
    World.put_client(context, name, Node.config(World.client(context, name), 1))
  end

  defp pushed(context, name) do
    {%{"rules" => rules}, client} =
      Node.await(World.client(context, name), &(&1["t"] == "config.keybindings"))

    {rules, World.put_client(context, name, client)}
  end

  defp config_shape, do: %{"type" => "config", "node" => Atom.to_string(node())}
end
