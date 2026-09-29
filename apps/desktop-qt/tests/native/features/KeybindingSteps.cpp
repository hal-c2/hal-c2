// The shell's keymap (KeybindingController): pressing keys the way
// ShellWindow's window shortcuts hand them over, the rules the node keeps in
// keybindings.json, and Settings → Keybindings over them
// (features/navigation/keybinding*.feature, desktop/native-keybindings.feature for
// who takes a key under focus).
//
// A press goes where ShellWindow sends it: with no window shortcut for the
// sequence, or one standing down for the focused page or terminal, the key
// reaches whatever has focus; otherwise Keybindings.press runs it. An open
// model picker takes its own chords first (ModelPicker's ShortcutOverride). A
// command "runs" when the shell ran it, or when the page was handed the key
// (forwarded as `keybinding.press`, or focused and handling its own keydown)
// and the page's keymap resolves it to that command.

#include <QCoreApplication>
#include <QJsonArray>
#include <QKeyEvent>
#include <QKeySequence>
#include <QWindow>
#include <QJsonObject>
#include <QRegularExpression>

#include <algorithm>

#include "CommandPaletteController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Keymap.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NavigationController.h"
#include "TerminalController.h"
#include "World.h"

namespace {

struct KeyState {
  // Where the keyboard is: {page, terminal, composer, editable}; empty for
  // the native chrome.
  QVariantMap focus;
  bool mac = false;
  bool pickerOpen = false;
  bool hooked = false;
  // Something the user did: a later "is bound to" checks instead of sets up.
  bool acted = false;
  bool threadShown = false;
  // The last press: its sequence, the commands the shell ran, the picker's
  // command, what received the key when the window did not take it, and the
  // page actions before it.
  QString sequence;
  QStringList ran;
  QString picker;
  QString delivered;
  qsizetype actionsBefore = 0;
  // Settings → Keybindings.
  QString query;
  QString condition;
  QString lastCommand;
  QString lastKey;
};

KeyState& keys(World& world) {
  return world.node.part<KeyState>();
}

KeybindingController* keymap(World& world) {
  return world.native().controller<KeybindingController>();
}

const QJsonArray& noRules() {
  static const QJsonArray empty;
  return empty;
}

QJsonArray storedRules(FakeNode& node) {
  return fakeConfig(node).config.value(QLatin1String("keybindingRules")).toArray();
}

void sendRules(FakeNode& node) {
  const QJsonArray rules = storedRules(node);
  for (const int id : node.subscribers(QStringLiteral("config"))) {
    if (node.shapeOf(id).value(QLatin1String("environment")) != node.environmentId) continue;
    node.send({{QStringLiteral("t"), QStringLiteral("config.keybindings")},
               {QStringLiteral("id"), id},
               {QStringLiteral("rules"), rules}});
  }
}

// hal-c2.upsertKeybinding and removeKeybinding as the node does them
// (apps/server-ex lib/hal_c2/keybindings.ex): the rules back, pushed to every
// client as `config.keybindings`.
const FakeNode::Extension extension([](FakeNode& node) {
  const auto refused = [&node](const FakeNode::Rpc& rpc) {
    if (!node.refusals.contains(rpc.method)) return false;
    node.refuse(rpc, node.refusals.value(rpc.method));
    return true;
  };
  node.onRpc(QStringLiteral("hal-c2.upsertKeybinding"), [&node, refused](const FakeNode::Rpc& rpc) {
    if (refused(rpc)) return;
    QJsonObject rule = rpc.payload;
    const QJsonObject replace = rule.take(QStringLiteral("replace")).toObject();
    QJsonArray rules;
    for (const QJsonValue& value : storedRules(node)) {
      if (value.toObject() != rule && value.toObject() != replace) rules.append(value);
    }
    rules.append(rule);
    while (rules.size() > 256) rules.removeFirst();
    fakeConfig(node).config.insert(QStringLiteral("keybindingRules"), rules);
    node.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
    sendRules(node);
  });
  node.onRpc(QStringLiteral("hal-c2.removeKeybinding"), [&node, refused](const FakeNode::Rpc& rpc) {
    if (refused(rpc)) return;
    QJsonArray rules;
    for (const QJsonValue& value : storedRules(node)) {
      if (value.toObject() != rpc.payload) rules.append(value);
    }
    fakeConfig(node).config.insert(QStringLiteral("keybindingRules"), rules);
    node.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
    sendRules(node);
  });
});

bool connected(World& world) {
  return world.shellSubscriptions() > 0;
}

void ensureShell(World& world) {
  if (!connected(world)) {
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); },
                  QStringLiteral("the shell to take over"));
  }
  world.sync();
  KeyState& state = keys(world);
  if (!state.hooked) {
    state.hooked = true;
    QObject::connect(keymap(world)->commands(), &CommandRegistry::ran, keymap(world),
                     [&state](const QString& command) { state.ran.append(command); });
  }
}

// The node's keybindings.json becomes `rules`, pushed when the shell is
// connected and in the snapshot when it connects.
void setRules(World& world, const QJsonArray& rules) {
  fakeConfig(world.node).config.insert(QStringLiteral("keybindingRules"), rules);
  if (!connected(world)) return;
  sendRules(world.node);
  world.sync();
}

void addRule(World& world, const QString& key, const QString& command, const QString& when = {}) {
  QJsonObject rule{{QStringLiteral("key"), key}, {QStringLiteral("command"), command}};
  if (!when.isEmpty()) rule.insert(QStringLiteral("when"), when);
  QJsonArray rules = storedRules(world.node);
  rules.append(rule);
  setRules(world, rules);
}

// Waits for a save or removal to come back from the node.
void settle(World& world) {
  world.waitFor([&world] { return !keymap(world)->saving(); }, QStringLiteral("the keybinding change to settle"));
  world.sync();
}

QString focusName(const QVariantMap& focus) {
  if (focus.value(QStringLiteral("terminal")).toBool()) return QStringLiteral("terminal");
  if (focus.value(QStringLiteral("page")).toBool()) return QStringLiteral("page");
  if (focus.value(QStringLiteral("composer")).toBool()) return QStringLiteral("composer");
  return QStringLiteral("window");
}

// The window key events go to; it notes the ones that reach it.
class KeyWindow : public QWindow {
public:
  bool reached = false;

protected:
  void keyPressEvent(QKeyEvent*) override { reached = true; }
  void keyReleaseEvent(QKeyEvent*) override { reached = true; }
};

struct KeyTarget {
  std::unique_ptr<KeyWindow> window = std::make_unique<KeyWindow>();
};

void pressSequence(World& world, const QString& sequence) {
  ensureShell(world);
  KeyState& state = keys(world);
  state.acted = true;
  state.sequence = sequence;
  state.ran.clear();
  state.picker.clear();
  state.delivered.clear();
  state.actionsBefore = world.pageActions.size();
  KeybindingController* controller = keymap(world);
  if (sequence.isEmpty()) {
    state.delivered = focusName(state.focus);
    return;
  }
  // The application sees the key before any shortcut does.
  const QKeyCombination combination = QKeySequence(sequence)[0];
  const bool reached = sendKey(world, QEvent::KeyPress, combination.key(), combination.keyboardModifiers());
  sendKey(world, QEvent::KeyRelease, combination.key(), combination.keyboardModifiers());
  if (!reached) {
    state.delivered = QStringLiteral("application");
    return;
  }
  if (state.pickerOpen) {
    const QString command = keybindings::resolve(
        controller->resolved(), sequence,
        {{QStringLiteral("modelPickerOpen"), true}, {QStringLiteral("isDesktop"), true}}, state.mac);
    if (command.startsWith(QLatin1String("modelPicker.")) && command != QLatin1String("modelPicker.toggle")) {
      state.picker = command;
      return;
    }
  }
  const QVariantList shortcuts = controller->shortcuts();
  const auto entry = std::find_if(shortcuts.cbegin(), shortcuts.cend(), [&](const QVariant& value) {
    return value.toMap().value(QStringLiteral("sequence")).toString() == sequence;
  });
  if (entry == shortcuts.cend()) {
    state.delivered = focusName(state.focus);
    return;
  }
  const QVariantMap shortcut = entry->toMap();
  const bool terminal = state.focus.value(QStringLiteral("terminal")).toBool();
  const bool page = state.focus.value(QStringLiteral("page")).toBool();
  const bool enabled = terminal ? shortcut.value(QStringLiteral("terminal")).toBool()
                       : page   ? shortcut.value(QStringLiteral("page")).toBool()
                                : true;
  if (!enabled) {
    state.delivered = focusName(state.focus);
    return;
  }
  // A project script runs through the terminal drawer (workspace.runScript).
  const QString command = controller->resolve(sequence, state.focus);
  if (controller->press(sequence, state.focus) && command.startsWith(QLatin1String("script."))) state.ran.append(command);
  world.sync();
}

}  // namespace

bool sendKey(World& world, QEvent::Type type, int key, Qt::KeyboardModifiers modifiers, bool autoRepeat) {
  KeyWindow* window = world.node.part<KeyTarget>().window.get();
  window->reached = false;
  QKeyEvent event(type, key, modifiers, QString(), autoRepeat);
  QCoreApplication::sendEvent(window, &event);
  return window->reached;
}

namespace {

void press(World& world, const QString& key) {
  // An open command palette's search field takes mod+1..9 (CommandPalette.qml).
  static const QRegularExpression nth(QStringLiteral("^mod\\+([1-9])$"));
  auto* palette = world.native().controller<CommandPaletteController>();
  if (const auto match = nth.match(key.toLower()); match.hasMatch() && palette && palette->isOpen()) {
    palette->run(match.captured(1).toInt() - 1);
    world.sync();
    return;
  }
  // Its field takes Escape (a step back) and Backspace on an empty query (out
  // of a submenu) too.
  if (palette && palette->isOpen() && key == QLatin1String("Escape")) {
    palette->back();
    world.sync();
    return;
  }
  if (palette && palette->isOpen() && key == QLatin1String("Backspace") && palette->query().isEmpty()) {
    palette->leaveSubmenu();
    world.sync();
    return;
  }
  const auto shortcut = keybindings::parseShortcut(key.toLower());
  if (!shortcut) fail(QStringLiteral("%1 is not a key").arg(key));
  pressSequence(world, keybindings::sequence(*shortcut, keys(world).mac));
}

QList<PageAction> forwarded(World& world) {
  QList<PageAction> presses;
  for (qsizetype index = keys(world).actionsBefore; index < world.pageActions.size(); ++index) {
    if (world.pageActions.at(index).type == QLatin1String("keybinding.press")) presses.append(world.pageActions.at(index));
  }
  return presses;
}

// What the page's keymap makes of the key, focused on its body.
QString pageCommand(World& world) {
  return keybindings::resolve(keymap(world)->resolved(), keys(world).sequence,
                              {{QStringLiteral("isDesktop"), true}}, keys(world).mac);
}

bool ran(World& world, const QString& command) {
  const KeyState& state = keys(world);
  if (state.ran.contains(command) || state.picker == command) return true;
  const bool toPage = !forwarded(world).isEmpty() || state.delivered == QLatin1String("page");
  return toPage && pageCommand(world) == command;
}

QString describePress(World& world) {
  const KeyState& state = keys(world);
  return QStringLiteral("%1 with %2: the shell ran %3, the picker %4, the key went to %5, the page got %6 (%7)")
      .arg(state.sequence, focusName(state.focus), show(state.ran), state.picker.isEmpty() ? u"nothing"_qs : state.picker,
           state.delivered.isEmpty() ? u"the window"_qs : state.delivered)
      .arg(forwarded(world).size())
      .arg(pageCommand(world));
}

// A thread of a project with a `test` script, shown in the window.
void showThread(World& world) {
  KeyState& state = keys(world);
  if (state.threadShown) return;
  state.threadShown = true;
  world.node.projects.insert(
      QStringLiteral("p1"),
      {{QStringLiteral("id"), QStringLiteral("p1")},
       {QStringLiteral("title"), QStringLiteral("p1")},
       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")},
       {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
       {QStringLiteral("scripts"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("test")},
                                                          {QStringLiteral("name"), QStringLiteral("Test")},
                                                          {QStringLiteral("command"), QStringLiteral("bun test")}}}}});
  world.node.threads.insert(QStringLiteral("t1"), {{QStringLiteral("id"), QStringLiteral("t1")},
                                                   {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                   {QStringLiteral("title"), QStringLiteral("One")},
                                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  ensureShell(world);
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), QStringLiteral("env-a:t1")}});
  auto* terminals = world.native().controller<TerminalController>();
  world.waitFor([terminals] { return terminals->available(); }, QStringLiteral("the thread's terminal drawer"));
}

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

QVariantList rows(World& world) {
  return keymap(world)->bindings();
}

std::optional<QVariantMap> rowFor(World& world, const QString& command, const QString& key = {}) {
  for (const QVariant& value : rows(world)) {
    const QVariantMap row = value.toMap();
    if (row.value(QStringLiteral("command")) == command && (key.isEmpty() || row.value(QStringLiteral("key")) == key)) {
      return row;
    }
  }
  return std::nullopt;
}

QString describeRows(World& world, const QString& command) {
  QStringList lines;
  for (const QVariant& value : rows(world)) {
    const QVariantMap row = value.toMap();
    if (row.value(QStringLiteral("command")) != command) continue;
    lines.append(QStringLiteral("%1 when %2 (%3)")
                     .arg(row.value(QStringLiteral("key")).toString(), row.value(QStringLiteral("when")).toString(),
                          row.value(QStringLiteral("source")).toString()));
  }
  return lines.isEmpty() ? QStringLiteral("no binding") : lines.join(QStringLiteral(", "));
}

void setMac(World& world, bool mac) {
  ensureShell(world);
  keys(world).mac = mac;
  keymap(world)->setMac(mac);
}

// The keyboard's modifier as keybindings.json spells it on the platform.
QString modifierToken(bool mac, const QString& physical) {
  if (physical == QLatin1String("Command")) return QStringLiteral("mod");
  if (physical == QLatin1String("Control")) return QStringLiteral("ctrl");
  if (physical == QLatin1String("Super")) return QStringLiteral("meta");
  return mac ? QStringLiteral("ctrl") : QStringLiteral("mod");  // Ctrl
}

int qtModifier(bool mac, const QString& physical) {
  // Qt's Control is Command on macOS, and its Meta is Control there.
  if (physical == QLatin1String("Command")) return Qt::ControlModifier;
  if (physical == QLatin1String("Control")) return mac ? Qt::MetaModifier : Qt::ControlModifier;
  if (physical == QLatin1String("Super")) return Qt::MetaModifier;
  return mac ? Qt::MetaModifier : Qt::ControlModifier;  // Ctrl
}

void setFocus(World& world, const QVariantMap& focus, bool pickerOpen = false) {
  ensureShell(world);
  keys(world).focus = focus;
  keys(world).pickerOpen = pickerOpen;
}

const QVariantMap kComposer{{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}};

const Steps steps([] {
  const QString q = kQuoted;

  // Where the keyboard is.
  step(QStringLiteral("the user is (anywhere|outside a terminal|in a terminal|with the model picker open)"),
       [](World& world, const Captures& c, const Table&) {
         setFocus(world, c[0] == QLatin1String("in a terminal") ? QVariantMap{{QStringLiteral("terminal"), true}} : QVariantMap{},
                  c[0] == QLatin1String("with the model picker open"));
       });
  step(QStringLiteral("(?:the native chrome has keyboard focus|the user is in the desktop app|anything|the terminal is closed)"),
       [](World& world, const Captures&, const Table&) { setFocus(world, {}); });
  step(QStringLiteral("the page has keyboard focus"), [](World& world, const Captures&, const Table&) {
    setFocus(world, {{QStringLiteral("page"), true}});
  });
  step(QStringLiteral("the composer has (?:keyboard )?focus"), [](World& world, const Captures&, const Table&) {
    // As an outcome: the shell handed the composer the keyboard.
    if (world.checking) {
      expect(!world.actionsOf(QStringLiteral("composer.focus")).isEmpty(), world.describePage());
      return;
    }
    setFocus(world, kComposer);
  });
  step(QStringLiteral("a terminal in the thread has keyboard focus"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&world] { return terminals(world)->isOpen() && terminals(world)->tabs()->rowCount() == 1; },
                  QStringLiteral("the thread's first terminal"));
    setFocus(world, {{QStringLiteral("terminal"), true}});
  });
  step(QStringLiteral("the user is on (macOS|Linux|Windows)"), [](World& world, const Captures& c, const Table&) {
    setMac(world, c[0] == QLatin1String("macOS"));
  });

  // Pressing keys.
  step(QStringLiteral("the user presses ([^ ]+)(?: again)?"), [](World& world, const Captures& c, const Table&) {
    press(world, c[0]);
  });
  step(QStringLiteral("the user presses (Command|Ctrl|Control|Super) and ([A-Z])"), [](World& world, const Captures& c, const Table&) {
    press(world, modifierToken(keys(world).mac, c[0]) + QLatin1Char('+') + c[1].toLower());
  });

  // What the key did.
  step(QStringLiteral("the command %1 runs").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(ran(world, c[0]), describePress(world));
  });
  step(QStringLiteral("%1 behaves as it does in the web app").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(ran(world, c[0]), describePress(world));
  });
  step(QStringLiteral("%1 (runs|does not run)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(ran(world, c[0]) == (c[1] == QLatin1String("runs")), describePress(world));
  });
  step(QStringLiteral("the command palette (opens|does not open)"), [](World& world, const Captures& c, const Table&) {
    expect(ran(world, QStringLiteral("commandPalette.toggle")) == (c[0] == QLatin1String("opens")), describePress(world));
  });
  step(QStringLiteral("no new thread starts"), [](World& world, const Captures&, const Table&) {
    expect(!ran(world, QStringLiteral("chat.new")) && world.actionsOf(QStringLiteral("thread.new")).isEmpty(),
           describePress(world));
  });
  step(QStringLiteral("the (terminal|composer) receives the key"), [](World& world, const Captures& c, const Table&) {
    expect(keys(world).delivered == c[0], describePress(world));
  });
  step(QStringLiteral("the page handles the key itself"), [](World& world, const Captures&, const Table&) {
    expect(keys(world).delivered == QLatin1String("page") && keys(world).ran.isEmpty(), describePress(world));
  });
  step(QStringLiteral("the desktop shell does not forward it a second time"), [](World& world, const Captures&, const Table&) {
    expect(forwarded(world).isEmpty(), describePress(world));
  });

  // The thread's terminal.
  step(QStringLiteral("the thread's terminal is (shown|hidden)"), [](World& world, const Captures& c, const Table&) {
    showThread(world);
    const bool open = c[0] == QLatin1String("shown");
    world.waitFor([&world, open] { return terminals(world)->isOpen() == open; },
                  QStringLiteral("the terminal drawer to be %1").arg(c[0]));
  });
  step(QStringLiteral("a new terminal opens instead of a new thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return terminals(world)->tabs()->rowCount() == 2; }, [&world] { return describePress(world); });
    expect(!ran(world, QStringLiteral("chat.new")), describePress(world));
  });
  step(QStringLiteral("a second terminal opens (side by side|stacked below)"), [](World& world, const Captures& c, const Table&) {
    const bool stacked = c[0] == QLatin1String("stacked below");
    world.waitFor([&world, stacked] {
      const QList<TerminalTabs::Row> rows = terminals(world)->tabs()->rows();
      return rows.size() == 2 && rows.at(0).group == rows.at(1).group && rows.at(1).slot == 1 && rows.at(1).vertical == stacked;
    }, [&world] { return describePress(world); });
  });
  step(QStringLiteral("the terminal splits"), [](World& world, const Captures&, const Table&) {
    expect(ran(world, QStringLiteral("terminal.split")), describePress(world));
  });
  step(QStringLiteral("the diff panel does not toggle"), [](World& world, const Captures&, const Table&) {
    expect(!ran(world, QStringLiteral("diff.toggle")), describePress(world));
  });
  step(QStringLiteral("the focused terminal closes"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return terminals(world)->tabs()->rowCount() == 0 || !terminals(world)->isOpen(); },
                  [&world] { return describePress(world); });
  });
  step(QStringLiteral("the project has a script %1").arg(q), [](World& world, const Captures&, const Table&) {
    showThread(world);
  });
  step(QStringLiteral("the %1 script runs").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return terminals(world)->isOpen() && terminals(world)->tabs()->rowCount() == 1; },
                  [&world] { return QStringLiteral("the script's terminal; ") + describePress(world); });
  });

  step(QStringLiteral("the page forwards ([^ ]+)"), [](World& world, const Captures& c, const Table&) {
    // As an embed hands the shell a keydown it did not take (ShellBridge.ts).
    ensureShell(world);
    const auto shortcut = keybindings::parseShortcut(c[0]);
    if (!shortcut) fail(QStringLiteral("%1 is not a key").arg(c[0]));
    KeyState& state = keys(world);
    state.acted = true;
    state.ran.clear();
    state.sequence = keybindings::sequence(*shortcut, state.mac);
    state.actionsBefore = world.pageActions.size();
    world.bridge().dispatch(QStringLiteral("keybinding.press"),
                            QVariantMap{{QStringLiteral("key"), shortcut->key},
                                        {QStringLiteral("ctrlKey"), shortcut->ctrl || (shortcut->mod && !state.mac)},
                                        {QStringLiteral("metaKey"), shortcut->meta || (shortcut->mod && state.mac)},
                                        {QStringLiteral("shiftKey"), shortcut->shift},
                                        {QStringLiteral("altKey"), shortcut->alt}});
    world.sync();
  });
  step(QStringLiteral("the page is handed the key once"), [](World& world, const Captures&, const Table&) {
    expect(forwarded(world).size() == 1 && keys(world).ran.isEmpty(), describePress(world));
  });

  // keybindings.json.
  step(QStringLiteral("no custom keybindings"), [](World& world, const Captures&, const Table&) {
    setRules(world, noRules());
    ensureShell(world);
  });
  step(QStringLiteral("the node adds the rule ([^ ]+) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).acted = true;
    addRule(world, c[0], c[1]);
  });
  step(QStringLiteral("the node removes every custom rule"), [](World& world, const Captures&, const Table&) {
    keys(world).acted = true;
    setRules(world, {});
  });
  step(QStringLiteral("keybindings.json only rebinds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).lastCommand = c[0];
    setRules(world, {});
    addRule(world, QStringLiteral("mod+alt+n"), c[0]);
  });
  step(QStringLiteral("two rules bind ([^ ]+), first to %1 and then to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addRule(world, c[0], c[1]);
    addRule(world, c[0], c[2]);
  });
  step(QStringLiteral("keybindings.json has one valid rule and one with an unknown command"), [](World& world, const Captures&, const Table&) {
    addRule(world, QStringLiteral("mod+alt+g"), QStringLiteral("diff.toggle"));
    addRule(world, QStringLiteral("mod+alt+u"), QStringLiteral("nothing.known"));
  });
  step(QStringLiteral("keybindings.json binds ([^ ]+) to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addRule(world, c[0], c[1]);
  });
  step(QStringLiteral("%1 is bound to ([^ ]+) when %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addRule(world, c[1], c[0], c[2]);
  });
  step(QStringLiteral("a custom binding ([^ ]+) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addRule(world, c[0], c[1]);
    keys(world).lastCommand = c[1];
    keys(world).lastKey = c[0];
  });
  step(QStringLiteral("%1 was rebound to ([^ ]+)").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto standard = std::find_if(keybindings::defaults().cbegin(), keybindings::defaults().cend(),
                                       [&](const keybindings::Rule& rule) { return rule.command == c[0]; });
    addRule(world, c[1], c[0], standard != keybindings::defaults().cend() ? standard->when.value_or(QString()) : QString());
  });
  step(QStringLiteral("the client (?:starts|loads keybindings)"), [](World& world, const Captures&, const Table&) {
    ensureShell(world);
  });
  // Given before the user acts, a rule in keybindings.json; after, what the
  // settings list shows.
  step(QStringLiteral("%1 is bound to ([^ ]+?)(?: again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!keys(world).acted) {
      addRule(world, c[1], c[0]);
      return;
    }
    settle(world);
    expect(rowFor(world, c[0], c[1]).has_value(), describeRows(world, c[0]));
  });
  step(QStringLiteral("every other command keeps its default shortcut"), [](World& world, const Captures&, const Table&) {
    const QString rebound = keys(world).lastCommand;
    for (const keybindings::Rule& rule : keybindings::defaults()) {
      if (rule.command == rebound) continue;
      const auto row = rowFor(world, rule.command, rule.key);
      expect(row && row->value(QStringLiteral("source")) == QLatin1String("Default"),
             QStringLiteral("%1: %2").arg(rule.command, describeRows(world, rule.command)));
    }
    expect(!rowFor(world, rebound, QStringLiteral("mod+n")), describeRows(world, rebound));
  });
  step(QStringLiteral("the valid rule applies"), [](World& world, const Captures&, const Table&) {
    expect(keymap(world)->resolve(QStringLiteral("Ctrl+Alt+G")) == QLatin1String("diff.toggle"), describeRows(world, u"diff.toggle"_qs));
  });
  step(QStringLiteral("the unknown one is ignored"), [](World& world, const Captures&, const Table&) {
    expect(!rowFor(world, QStringLiteral("nothing.known")) && keymap(world)->resolve(QStringLiteral("Ctrl+Alt+U")).isEmpty(),
           QStringLiteral("the unknown rule is bound"));
  });
  step(QStringLiteral("%1 has no shortcut").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureShell(world);
    settle(world);
    expect(keymap(world)->shortcutLabel(c[0]).isEmpty() && !rowFor(world, c[0]), describeRows(world, c[0]));
  });
  step(QStringLiteral("the user binds %1 to ([^ ]+)").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureShell(world);
    keymap(world)->save(c[0], c[1], QString());
    settle(world);
  });

  // Settings → Keybindings.
  step(QStringLiteral("the user is in Settings → Keybindings"), [](World& world, const Captures&, const Table&) {
    ensureShell(world);
    world.bridge().dispatch(QStringLiteral("keybindings.open"));
    const auto* navigation = world.native().controller<NavigationController>();
    expect(navigation->route() == NavigationController::Route::settings(NavigationController::kKeybindingsSection),
           QStringLiteral("the window shows %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("each command is listed in order with its shortcut and condition"), [](World& world, const Captures&, const Table&) {
    const QVariantList listed = rows(world);
    for (const keybindings::Rule& rule : keybindings::defaults()) {
      const bool shown = std::any_of(listed.cbegin(), listed.cend(), [&](const QVariant& value) {
        const QVariantMap row = value.toMap();
        return row.value(QStringLiteral("command")) == rule.command && row.value(QStringLiteral("key")) == rule.key &&
               row.value(QStringLiteral("when")) == rule.when.value_or(QString()) &&
               !row.value(QStringLiteral("keyLabel")).toString().isEmpty();
      });
      expect(shown, QStringLiteral("%1: %2").arg(rule.command, describeRows(world, rule.command)));
    }
    for (qsizetype index = 1; index < listed.size(); ++index) {
      const QString previous = listed.at(index - 1).toMap().value(QStringLiteral("command")).toString();
      const QString next = listed.at(index).toMap().value(QStringLiteral("command")).toString();
      expect(QString::localeAwareCompare(previous, next) <= 0, QStringLiteral("%1 is listed before %2").arg(previous, next));
    }
  });
  step(QStringLiteral("each binding is marked Default, Custom or Project"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& value : rows(world)) {
      const QString source = value.toMap().value(QStringLiteral("source")).toString();
      expect(QStringList{u"Default"_qs, u"Custom"_qs, u"Project"_qs}.contains(source), show(value));
    }
  });
  step(QStringLiteral("the user searches keybindings for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).query = c[0];
  });
  step(QStringLiteral("only bindings whose (command|label|key|condition|source) matches are listed"),
       [](World& world, const Captures& c, const Table&) {
         const QString query = keys(world).query.toLower();
         const QString field = c[0] == QLatin1String("condition") ? QStringLiteral("when") : c[0];
         // KeybindingsSettings lists the rows whose `search` holds the query.
         for (const QVariant& value : rows(world)) {
           const QVariantMap row = value.toMap();
           const bool listed = row.value(QStringLiteral("search")).toString().contains(query);
           const bool matches = row.value(field).toString().toLower().contains(query);
           expect(listed == matches, QStringLiteral("%1 %2 listed").arg(show(row), listed ? u"is"_qs : u"is not"_qs));
         }
       });
  step(QStringLiteral("%1 is labelled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(keymap(world)->commandLabel(c[0]) == c[1], keymap(world)->commandLabel(c[0]));
  });
  step(QStringLiteral("the user records ([^ ]+) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowFor(world, c[1]);
    expect(row.has_value(), describeRows(world, c[1]));
    keys(world).acted = true;
    keys(world).lastCommand = c[1];
    keys(world).lastKey = c[0];
    keymap(world)->save(c[1], c[0], row->value(QStringLiteral("when")).toString(), *row);
    settle(world);
  });
  step(QStringLiteral("the binding is marked (Default|Custom)"), [](World& world, const Captures& c, const Table&) {
    const QString command = keys(world).lastCommand;
    const auto row = rowFor(world, command);
    expect(row && row->value(QStringLiteral("source")) == c[0], describeRows(world, command));
  });
  step(QStringLiteral("the user is recording a shortcut for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).lastCommand = c[0];
  });
  step(QStringLiteral("the user presses Y alone"), [](World& world, const Captures&, const Table&) {
    keys(world).lastKey = keymap(world)->recordKey(Qt::Key_Y, Qt::NoModifier);
  });
  step(QStringLiteral("nothing is recorded"), [](World& world, const Captures&, const Table&) {
    expect(keys(world).lastKey.isEmpty(), keys(world).lastKey);
  });
  step(QStringLiteral("the user records (Command|Control|Ctrl|Super) plus Y"), [](World& world, const Captures& c, const Table&) {
    keys(world).lastKey = keymap(world)->recordKey(Qt::Key_Y, qtModifier(keys(world).mac, c[0]));
  });
  step(QStringLiteral("the recorded shortcut is ([^ ]+)"), [](World& world, const Captures& c, const Table&) {
    expect(keys(world).lastKey == c[0], keys(world).lastKey);
  });
  step(QStringLiteral("the user types the condition %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).condition = c[0];
  });
  step(QStringLiteral("%1 is flagged as unknown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList unknown = keymap(world)->unknownVariables(keys(world).condition);
    expect(unknown.contains(c[0]), show(unknown));
  });
  step(QStringLiteral("the binding says it conflicts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowFor(world, keys(world).lastCommand, keys(world).lastKey);
    expect(row && row->value(QStringLiteral("conflicts")).toStringList().contains(keymap(world)->commandLabel(c[0])),
           row ? show(*row) : describeRows(world, keys(world).lastCommand));
  });
  step(QStringLiteral("the user is told the most recent matching binding wins when both conditions can apply"),
       [](World& world, const Captures&, const Table&) {
         const auto key = keybindings::parseShortcut(keys(world).lastKey);
         expect(key && keymap(world)->resolve(keybindings::sequence(*key, keys(world).mac)) == keys(world).lastCommand,
                describeRows(world, keys(world).lastCommand));
       });
  step(QStringLiteral("the user resets %1 to its default").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).acted = true;
    keys(world).lastCommand = c[0];
    const auto row = rowFor(world, c[0]);
    expect(row && row->value(QStringLiteral("canReset")).toBool(), describeRows(world, c[0]));
    keymap(world)->reset(*row);
    settle(world);
  });
  step(QStringLiteral("no default binding offers to be removed"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& value : rows(world)) {
      const QVariantMap row = value.toMap();
      if (row.value(QStringLiteral("source")) == QLatin1String("Default")) {
        expect(!row.value(QStringLiteral("canRemove")).toBool(), show(row));
      }
    }
  });
  step(QStringLiteral("the user removes that binding"), [](World& world, const Captures&, const Table&) {
    keys(world).acted = true;
    const auto row = rowFor(world, keys(world).lastCommand, keys(world).lastKey);
    expect(row && row->value(QStringLiteral("canRemove")).toBool(), describeRows(world, keys(world).lastCommand));
    keymap(world)->remove(*row);
    settle(world);
  });
  step(QStringLiteral("the user adds a keybinding for %1 with ([^ ]+)").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).acted = true;
    keymap(world)->save(c[0], c[1], QString());
    settle(world);
  });
  step(QStringLiteral("the environment will reject keybinding changes"), [](World& world, const Captures&, const Table&) {
    world.node.refusals.insert(QStringLiteral("hal-c2.upsertKeybinding"), QStringLiteral("Read-only file system"));
    world.node.refusals.insert(QStringLiteral("hal-c2.removeKeybinding"), QStringLiteral("Read-only file system"));
  });
  step(QStringLiteral("the user (saves|removes) a binding"), [](World& world, const Captures& c, const Table&) {
    keys(world).acted = true;
    if (c[0] == QLatin1String("saves")) {
      keymap(world)->save(QStringLiteral("diff.toggle"), QStringLiteral("mod+shift+y"), QStringLiteral("!terminalFocus"));
    } else {
      keymap(world)->remove({{QStringLiteral("command"), QStringLiteral("diff.toggle")}, {QStringLiteral("key"), QStringLiteral("mod+shift+y")}});
    }
    settle(world);
  });
});

}  // namespace

QString conditionProblem(World& world) {
  const QString typed = keys(world).condition;
  return typed.isEmpty() ? QString() : keymap(world)->whenError(typed);
}
