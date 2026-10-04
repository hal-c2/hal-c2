// Resetting the keymap (features/plugins/keymaps.feature): Settings →
// Keybindings takes every rule of the user's away at once, leaving the
// built-in bindings.

#include <QJsonArray>
#include <QJsonObject>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "World.h"

namespace {

KeybindingController* keymap(World& world) {
  return world.native().controller<KeybindingController>();
}

QJsonArray storedRules(World& world) {
  return fakeConfig(world.mc).config.value(QLatin1String("keybindingRules")).toArray();
}

// The built-in key of `command`, as keybindings.json spells it.
QStringList builtInKeys(const QString& command) {
  QStringList keys;
  for (const keybindings::Rule& rule : keybindings::defaults()) {
    if (rule.command == command) keys.append(rule.key);
  }
  return keys;
}

const Steps steps([] {
  Brick::registerSingletons();

  // The terminal client's names for them are "palette.open" and "thread.new";
  // on the desktop the palette is commandPalette.toggle and a new thread
  // chat.new, both on the platform's primary modifier.
  step(QStringLiteral("the built-in keymap binds \"ctrl\\+k\" to \"palette.open\" and \"ctrl\\+n\" to \"thread.new\""), [](World&, const Captures&, const Table&) {
    expect(builtInKeys(QStringLiteral("commandPalette.toggle")).contains(QStringLiteral("mod+k")),
           QStringLiteral("the palette is on %1").arg(builtInKeys(QStringLiteral("commandPalette.toggle")).join(QStringLiteral(", "))));
    expect(builtInKeys(QStringLiteral("chat.new")).contains(QStringLiteral("mod+n")),
           QStringLiteral("a new thread is on %1").arg(builtInKeys(QStringLiteral("chat.new")).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user has several keybinding overrides"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.waitFor([&] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
    world.sync();
    const QList<std::pair<QString, QString>> overrides{{QStringLiteral("chat.new"), QStringLiteral("mod+alt+n")},
                                                       {QStringLiteral("diff.toggle"), QStringLiteral("mod+alt+d")},
                                                       {QStringLiteral("commandPalette.toggle"), QStringLiteral("mod+alt+k")}};
    for (const auto& [command, key] : overrides) {
      keymap(world)->save(command, key, QString());
      world.waitFor([&] { return !keymap(world)->saving(); }, QStringLiteral("the keybinding to be saved"));
      world.sync();
    }
    world.waitFor([&] { return keymap(world)->customCount() == 3 && storedRules(world).size() == 3; },
                  [&] { return QStringLiteral("three overrides; the shell has %1, the MC %2").arg(keymap(world)->customCount()).arg(storedRules(world).size()); });
  });
  step(QStringLiteral("the user resets keybindings to the defaults"), [](World& world, const Captures&, const Table&) {
    Brick page(world, "import QtQuick\nimport HalC2.Bricks\nKeybindingsSettings { anchors.fill: parent }\n", QSize(900, 700));
    page.click(QStringLiteral("keybindingResetAll"));
    // It asks first, saying how many go.
    const QVariant question = world.state(QStringLiteral("confirmation"));
    expect(at(question, QStringLiteral("title")) == QLatin1String("Reset every keybinding to its default?") &&
               at(question, QStringLiteral("description")) == QLatin1String("This removes your 3 custom keybindings."),
           QStringLiteral("the shell asks %1").arg(show(question)));
    expect(storedRules(world).size() == 3, QStringLiteral("rules went before the answer"));
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), true}});
    world.waitFor([&] { return !keymap(world)->saving(); }, QStringLiteral("the reset to finish"));
    world.sync();
  });
  step(QStringLiteral("only the built-in bindings apply"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return storedRules(world).isEmpty() && keymap(world)->customCount() == 0; },
                  [&] { return QStringLiteral("no overrides; the shell has %1, the MC %2").arg(keymap(world)->customCount()).arg(storedRules(world).size()); });
    for (const QVariant& row : keymap(world)->bindings()) {
      expect(row.toMap().value(QStringLiteral("source")) != QLatin1String("Custom"), QStringLiteral("a custom binding is left: %1").arg(show(row)));
    }
    expect(keymap(world)->bindings().size() == keybindings::defaults().size(),
           QStringLiteral("%1 bindings, %2 built in").arg(keymap(world)->bindings().size()).arg(keybindings::defaults().size()));
    for (const QString& command : {QStringLiteral("chat.new"), QStringLiteral("diff.toggle"), QStringLiteral("commandPalette.toggle")}) {
      QStringList labels;
      for (const QString& key : builtInKeys(command)) labels.append(keymap(world)->keyLabel(key));
      expect(labels.contains(keymap(world)->shortcutLabel(command)), QStringLiteral("%1 is on %2").arg(command, keymap(world)->shortcutLabel(command)));
    }
  });
});

}  // namespace
