// The shell's keymap (KeybindingController): pressing keys the way
// ShellWindow's window shortcuts hand them over, the rules the MC keeps in
// keybindings.json, and Settings → Keybindings over them
// (features/navigation/keybinding*.feature, desktop/native-keybindings.feature for
// who takes a key under focus).
//
// A press goes where ShellWindow sends it: with no window shortcut for the
// sequence, or one standing down for the focused terminal, the key reaches
// whatever has focus; otherwise Keybindings.press runs it. An open model
// picker takes its own chords first (ModelPicker's ShortcutOverride). A
// command "runs" when the shell or the picker ran it.

#include <QCoreApplication>
#include <QJsonArray>
#include <QKeyEvent>
#include <QKeySequence>
#include <QWindow>
#include <QJsonObject>
#include <QRegularExpression>

#include <algorithm>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "ComposerBrick.h"
#include "DraftController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Keymap.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "World.h"

namespace {

struct KeyState {
  // Where the keyboard is: {terminal, composer, editable}; empty for
  // the native chrome.
  QVariantMap focus;
  bool mac = false;
  bool pickerOpen = false;
  bool hooked = false;
  // Something the user did: a later "is bound to" checks instead of sets up.
  bool acted = false;
  bool threadShown = false;
  // The last press: its sequence, the commands the shell ran, the picker's
  // command, and what received the key when the window did not take it.
  QString sequence;
  QStringList ran;
  QString picker;
  QString delivered;
  // Settings → Keybindings.
  QString query;
  QString condition;
  QString lastCommand;
  QString lastKey;
  // The rules other environments were asked to store, by environment.
  QHash<QString, QJsonArray> elsewhere;
};

KeyState& keys(World& world) {
  return world.mc.part<KeyState>();
}

KeybindingController* keymap(World& world) {
  return world.native().controller<KeybindingController>();
}

const QJsonArray& noRules() {
  static const QJsonArray empty;
  return empty;
}

QJsonArray storedRules(FakeMc& mc) {
  return fakeConfig(mc).config.value(QLatin1String("keybindingRules")).toArray();
}

void sendRules(FakeMc& mc) {
  const QJsonArray rules = storedRules(mc);
  for (const int id : mc.subscribers(QStringLiteral("config"))) {
    if (mc.shapeOf(id).value(QLatin1String("environment")) != mc.environmentId) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("config.keybindings")},
               {QStringLiteral("id"), id},
               {QStringLiteral("rules"), rules}});
  }
}

// hal-c2.upsertKeybinding and removeKeybinding as the MC does them
// (apps/server-ex lib/hal_c2/keybindings.ex): the rules back, pushed to every
// client as `config.keybindings`.
const FakeMc::Extension extension([](FakeMc& mc) {
  const auto refused = [&mc](const FakeMc::Rpc& rpc) {
    if (!mc.refusals.contains(rpc.method)) return false;
    mc.refuse(rpc, mc.refusals.value(rpc.method));
    return true;
  };
  mc.onRpc(QStringLiteral("hal-c2.upsertKeybinding"), [&mc, refused](const FakeMc::Rpc& rpc) {
    if (refused(rpc)) return;
    QJsonObject rule = rpc.payload;
    const QJsonObject replace = rule.take(QStringLiteral("replace")).toObject();
    if (!rpc.environment.isEmpty() && rpc.environment != mc.environmentId) {
      // Another environment's keybindings.json.
      QJsonArray& rules = mc.part<KeyState>().elsewhere[rpc.environment];
      rules.append(rule);
      mc.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
      return;
    }
    QJsonArray rules;
    for (const QJsonValue& value : storedRules(mc)) {
      if (value.toObject() != rule && value.toObject() != replace) rules.append(value);
    }
    rules.append(rule);
    while (rules.size() > 256) rules.removeFirst();
    fakeConfig(mc).config.insert(QStringLiteral("keybindingRules"), rules);
    mc.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
    sendRules(mc);
  });
  mc.onRpc(QStringLiteral("hal-c2.removeKeybinding"), [&mc, refused](const FakeMc::Rpc& rpc) {
    if (refused(rpc)) return;
    QJsonArray rules;
    for (const QJsonValue& value : storedRules(mc)) {
      if (value.toObject() != rpc.payload) rules.append(value);
    }
    fakeConfig(mc).config.insert(QStringLiteral("keybindingRules"), rules);
    mc.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
    sendRules(mc);
  });
});

bool connected(World& world) {
  return world.shellSubscriptions() > 0;
}

void ensureShell(World& world) {
  if (!connected(world)) {
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); },
                  QStringLiteral("the shell to start"));
  }
  world.sync();
  KeyState& state = keys(world);
  if (!state.hooked) {
    state.hooked = true;
    QObject::connect(keymap(world)->commands(), &CommandRegistry::ran, keymap(world),
                     [&state](const QString& command) { state.ran.append(command); });
  }
}

// The MC's keybindings.json becomes `rules`, pushed when the shell is
// connected and in the snapshot when it connects.
void setRules(World& world, const QJsonArray& rules) {
  fakeConfig(world.mc).config.insert(QStringLiteral("keybindingRules"), rules);
  if (!connected(world)) return;
  sendRules(world.mc);
  world.sync();
}

void addRule(World& world, const QString& key, const QString& command, const QString& when = {}) {
  QJsonObject rule{{QStringLiteral("key"), key}, {QStringLiteral("command"), command}};
  if (!when.isEmpty()) rule.insert(QStringLiteral("when"), when);
  QJsonArray rules = storedRules(world.mc);
  rules.append(rule);
  setRules(world, rules);
}

// Waits for a save or removal to come back from the MC.
void settle(World& world) {
  world.waitFor([&world] { return !keymap(world)->saving(); }, QStringLiteral("the keybinding change to settle"));
  world.sync();
}

QString focusName(const QVariantMap& focus) {
  if (focus.value(QStringLiteral("terminal")).toBool()) return QStringLiteral("terminal");
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
  // As ShellWindow enables its shortcuts.
  const auto focused = [&state](const char* what) { return state.focus.value(QLatin1String(what)).toBool(); };
  const bool enabled = shortcut.value(focused("terminal")   ? QStringLiteral("terminal")
                                      : focused("composer") ? QStringLiteral("composer")
                                      : focused("editable") ? QStringLiteral("editable")
                                                            : QStringLiteral("chrome")).toBool();
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
  KeyWindow* window = world.mc.part<KeyTarget>().window.get();
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
  // And mod+Enter, which adds the folder being browsed.
  if (palette && palette->isOpen() && key.toLower() == QLatin1String("mod+enter") && palette->mode() == QLatin1String("browse")) {
    palette->addBrowsedFolder();
    world.sync();
    return;
  }
  if (palette && palette->isOpen() && key == QLatin1String("Backspace") && palette->query().isEmpty()) {
    palette->leaveSubmenu();
    world.sync();
    return;
  }
  // Settings, SnapShots' recorder takes every key while it records (SnapShotSettings.qml).
  if (at(world.state(QStringLiteral("snapShot")), QStringLiteral("shortcut.recording")).toBool()) {
    const QKeyCombination combination = QKeySequence(key)[0];
    world.bridge().dispatch(QStringLiteral("snapShot.record.key"),
                            QVariantMap{{QStringLiteral("key"), int(combination.key())},
                                        {QStringLiteral("modifiers"), int(combination.keyboardModifiers().toInt())}});
    return;
  }
  if (pressInComposer(world, key)) return;
  // A brick on screen that takes the scenario's keys gets them as its window does.
  if (world.brick && world.brick->takesKeys) {
    keys(world).acted = true;
    world.brick->press(key);
    world.sync();
    return;
  }
  const auto shortcut = keybindings::parseShortcut(key.toLower());
  if (!shortcut) fail(QStringLiteral("%1 is not a key").arg(key));
  pressSequence(world, keybindings::sequence(*shortcut, keys(world).mac));
}

bool ran(World& world, const QString& command) {
  const KeyState& state = keys(world);
  return state.ran.contains(command) || state.picker == command;
}

QString describePress(World& world) {
  const KeyState& state = keys(world);
  return QStringLiteral("%1 with %2: the shell ran %3, the picker %4, the key went to %5")
      .arg(state.sequence, focusName(state.focus), show(state.ran), state.picker.isEmpty() ? u"nothing"_qs : state.picker,
           state.delivered.isEmpty() ? u"the window"_qs : state.delivered);
}

// A thread of a project with a `test` script, shown in the window.
void showThread(World& world) {
  KeyState& state = keys(world);
  if (state.threadShown) return;
  state.threadShown = true;
  world.mc.projects.insert(
      QStringLiteral("p1"),
      {{QStringLiteral("id"), QStringLiteral("p1")},
       {QStringLiteral("title"), QStringLiteral("p1")},
       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")},
       {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
       {QStringLiteral("scripts"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("test")},
                                                          {QStringLiteral("name"), QStringLiteral("Test")},
                                                          {QStringLiteral("command"), QStringLiteral("bun test")}}}}});
  world.mc.threads.insert(QStringLiteral("t1"), {{QStringLiteral("id"), QStringLiteral("t1")},
                                                   {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                   {QStringLiteral("title"), QStringLiteral("One")},
                                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  ensureShell(world);
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), QStringLiteral("env-a:t1")}});
  auto* terminals = world.native().controller<TerminalController>();
  world.waitFor([terminals] { return terminals->available(); }, QStringLiteral("the thread's terminal drawer"));
}

// Threads titled as given (ids "t" + title) in projects named by id, as the
// MC's snapshot has them when the shell connects.
void addThreads(World& world, const QList<std::pair<QString, QString>>& threads) {
  for (const auto& [title, project] : threads) {
    world.mc.projects.insert(project, {{QStringLiteral("id"), project},
                                         {QStringLiteral("title"), project},
                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                         {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.threads.insert(QStringLiteral("t") + title, {{QStringLiteral("id"), QStringLiteral("t") + title},
                                                           {QStringLiteral("projectId"), project},
                                                           {QStringLiteral("title"), title},
                                                           {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                           {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  }
  ensureShell(world);
}

void openThread(World& world, const QString& title) {
  const QString key = world.mc.environmentId + QStringLiteral(":t") + title;
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
  world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; },
                QStringLiteral("the window to show ") + key);
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
  step(QStringLiteral("the composer has (?:keyboard )?focus"), [](World& world, const Captures&, const Table&) {
    // As an outcome: the shell handed the composer the keyboard.
    if (world.checking) {
      expect(!world.actionsOf(QStringLiteral("composer.focus")).isEmpty(), world.describeBrickActions());
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
  // The desktop's preview is the right panel's Previews tab (preview.toggle).
  step(QStringLiteral("the user is looking at a thread in the desktop app"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    setFocus(world, {});
  });
  const auto previewShown = [](World& world) {
    auto* panel = world.native().controller<RightPanelController>();
    return panel->isOpen() && panel->activeTab() == QLatin1String("previews");
  };
  step(QStringLiteral("the preview is shown"), [previewShown](World& world, const Captures&, const Table&) {
    expect(previewShown(world), QStringLiteral("%1; the panel is %2").arg(describePress(world), show(world.state(QStringLiteral("panel")))));
  });
  step(QStringLiteral("the preview is hidden"), [previewShown](World& world, const Captures&, const Table&) {
    expect(!previewShown(world), QStringLiteral("%1; the panel is %2").arg(describePress(world), show(world.state(QStringLiteral("panel")))));
  });
  step(QStringLiteral("the user is on (macOS|Linux|Windows)"), [](World& world, const Captures& c, const Table&) {
    setMac(world, c[0] == QLatin1String("macOS"));
  });

  // Threads of their own for the scenarios with no Background.
  step(QStringLiteral("the user opened thread %1 and then thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addThreads(world, {{c[0], QStringLiteral("p1")}, {c[1], QStringLiteral("p1")}});
    openThread(world, c[0]);
    openThread(world, c[1]);
  });
  step(QStringLiteral("the user has several projects"), [](World& world, const Captures&, const Table&) {
    addThreads(world, {{QStringLiteral("One"), QStringLiteral("p1")}, {QStringLiteral("Two"), QStringLiteral("p2")}});
    openThread(world, QStringLiteral("Two"));
  });
  step(QStringLiteral("the thread list shows at least three threads"), [](World& world, const Captures&, const Table&) {
    addThreads(world, {{QStringLiteral("One"), QStringLiteral("p1")},
                       {QStringLiteral("Two"), QStringLiteral("p1")},
                       {QStringLiteral("Three"), QStringLiteral("p1")}});
    world.waitFor([&] { return world.native().sidebar()->orderedKeys().size() >= 3; }, QStringLiteral("three threads in the list"));
  });
  step(QStringLiteral("the third thread opens"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().sidebar()->orderedKeys().value(2);
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; },
                  [&] { return QStringLiteral("%1; the window shows %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the user goes forward"), [](World& world, const Captures&, const Table&) {
    keymap(world)->commands()->run(QStringLiteral("navigation.forward"));
    world.sync();
  });
  step(QStringLiteral("thread %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.mc.environmentId + QStringLiteral(":t") + c[0];
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; },
                  [&] { return QStringLiteral("%1; the window shows %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the user starts a new local thread"), [](World& world, const Captures&, const Table&) {
    keymap(world)->commands()->run(QStringLiteral("chat.newLocal"));
    world.sync();
  });
  step(QStringLiteral("a new thread starts in the current project without asking"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    const auto draft = world.native().controller<DraftController>()->draft(at(route, QStringLiteral("draftId")).toString());
    expect(draft && draft->projectId == QLatin1String("p2"), QStringLiteral("the window shows %1").arg(show(route)));
    expect(!world.native().controller<CommandPaletteController>()->isOpen(), QStringLiteral("the command palette asked"));
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

  // keybindings.json.
  step(QStringLiteral("no custom keybindings"), [](World& world, const Captures&, const Table&) {
    setRules(world, noRules());
    ensureShell(world);
  });
  step(QStringLiteral("the MC adds the rule ([^ ]+) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    keys(world).acted = true;
    addRule(world, c[0], c[1]);
  });
  step(QStringLiteral("the MC removes every custom rule"), [](World& world, const Captures&, const Table&) {
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
    world.mc.refusals.insert(QStringLiteral("hal-c2.upsertKeybinding"), QStringLiteral("Read-only file system"));
    world.mc.refusals.insert(QStringLiteral("hal-c2.removeKeybinding"), QStringLiteral("Read-only file system"));
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

// Settings → Keybindings: the file, conditions typed in full, and saving to
// every environment (navigation/keybinding-settings.feature,
// keybinding-customisation.feature).
const Steps fileSteps([] {
  const QString q = kQuoted;
  const QString path = QStringLiteral("/home/sam/.config/hal-c2/keybindings.json");

  // The MC's config as it reports the file (apps/server-ex environment.ex:
  // keybindingsConfigPath, issues).
  const auto report = [path](World& world, const QJsonArray& issues, const QJsonArray& editors) {
    FakeConfig& fake = fakeConfig(world.mc);
    fake.config.insert(QStringLiteral("keybindingsConfigPath"), path);
    fake.config.insert(QStringLiteral("issues"), issues);
    fake.config.insert(QStringLiteral("availableEditors"), editors);
    if (world.shellSubscriptions() == 0) return;
    // Connected already: the MC sends its config again.
    QJsonObject config = fake.config;
    config.insert(QStringLiteral("settings"), fake.settings);
    for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
    }
    world.sync();
  };
  step(QStringLiteral("keybindings.json is not valid JSON"), [report, path](World& world, const Captures&, const Table&) {
    // The MC keeps no rule of a file it cannot parse, and says why.
    fakeConfig(world.mc).config.insert(QStringLiteral("keybindingRules"), QJsonArray());
    report(world,
           {QJsonObject{{QStringLiteral("kind"), QStringLiteral("keybindings.malformed-config")},
                        {QStringLiteral("message"),
                         QStringLiteral("Unable to parse keybindings config at %1: expected JSON array").arg(path)}}},
           {QStringLiteral("zed")});
  });
  step(QStringLiteral("the default shortcuts apply"), [](World& world, const Captures&, const Table&) {
    for (const keybindings::Rule& rule : keybindings::defaults()) {
      const auto row = rowFor(world, rule.command, rule.key);
      expect(row && row->value(QStringLiteral("source")) == QLatin1String("Default"),
             QStringLiteral("%1: %2").arg(rule.command, describeRows(world, rule.command)));
    }
    expect(keymap(world)->resolve(keybindings::sequence(*keybindings::parseShortcut(QStringLiteral("mod+k")), keys(world).mac)) ==
               QLatin1String("commandPalette.toggle"),
           describeRows(world, QStringLiteral("commandPalette.toggle")));
  });
  step(QStringLiteral("the user is told %1 with the file path").arg(q), [path](World& world, const Captures& c, const Table&) {
    const auto told = [&] {
      for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        const QString description = item.toMap().value(QStringLiteral("description")).toString();
        if (description.startsWith(c[0]) && description.contains(path)) return true;
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("\"%1\" with %2; the toasts are %3").arg(c[0], path, show(world.state(QStringLiteral("toasts")))); });
  });

  step(QStringLiteral("no editor is available"), [report](World& world, const Captures&, const Table&) {
    report(world, {}, {});
    keys(world).condition = QStringLiteral("no editors");
  });
  step(QStringLiteral("the user opens keybindings.json from settings"), [report](World& world, const Captures&, const Table&) {
    ensureShell(world);
    if (keys(world).condition != QLatin1String("no editors")) report(world, {}, {QStringLiteral("cursor"), QStringLiteral("zed")});
    keys(world).condition.clear();
    world.waitFor([&] { return !keymap(world)->filePath().isEmpty(); }, QStringLiteral("the MC to say where keybindings.json is"));
    // The editor the user opened last.
    world.native().controller<SettingsController>()->writeDevice(QStringLiteral("lastEditor"), QStringLiteral("zed"));
    world.bridge().dispatch(QStringLiteral("keybindings.open"));
    keymap(world)->openFile();
    world.sync();
  });
  step(QStringLiteral("keybindings.json opens in the user's preferred editor"), [path](World& world, const Captures&, const Table&) {
    QList<QJsonObject> opened;
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      if (rpc.method == QLatin1String("shell.openInEditor")) opened.append(rpc.payload);
    }
    expect(opened.size() == 1 && opened.first().value(QLatin1String("cwd")) == path &&
               opened.first().value(QLatin1String("editor")) == QLatin1String("zed"),
           QStringLiteral("the MC was asked to open %1").arg(show(QVariant::fromValue(opened))));
  });

  step(QStringLiteral("the user adds the condition %1, negates it, and groups it with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureShell(world);
    // The desktop's condition is one field: what the web's builder assembles, typed.
    const QString condition = QStringLiteral("!%1 && %2").arg(c[0], c[1]);
    expect(keymap(world)->whenError(condition).isEmpty() && keymap(world)->unknownVariables(condition).isEmpty(),
           QStringLiteral("%1: %2 %3").arg(condition, keymap(world)->whenError(condition), show(keymap(world)->unknownVariables(condition))));
    keys(world).acted = true;
    keys(world).lastCommand = QStringLiteral("diff.toggle");
    keys(world).lastKey = QStringLiteral("mod+shift+y");
    keymap(world)->save(keys(world).lastCommand, keys(world).lastKey, condition);
    settle(world);
  });
  step(QStringLiteral("the binding's condition is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowFor(world, keys(world).lastCommand, keys(world).lastKey);
    expect(row && row->value(QStringLiteral("when")) == c[0], describeRows(world, keys(world).lastCommand));
    // And the keymap honours it: the key runs the command only where it holds.
    const QString sequence = keybindings::sequence(*keybindings::parseShortcut(keys(world).lastKey), keys(world).mac);
    expect(keymap(world)->resolve(sequence, {{QStringLiteral("terminal"), true}}).isEmpty() && keymap(world)->resolve(sequence).isEmpty(),
           QStringLiteral("the key runs %1 without the condition").arg(keymap(world)->resolve(sequence)));
  });

  step(QStringLiteral("two environments are connected"), [](World& world, const Captures&, const Table&) {
    ensureShell(world);
    world.mc.link(QStringLiteral("env-b"));
    world.sync();
    world.waitFor([&] { return world.native().store()->environmentOnline(QStringLiteral("env-b")); }, QStringLiteral("the second environment"));
  });
  step(QStringLiteral("the user rebinds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowFor(world, c[0]);
    expect(row.has_value(), describeRows(world, c[0]));
    keys(world).acted = true;
    keys(world).lastCommand = c[0];
    keys(world).lastKey = QStringLiteral("mod+shift+y");
    keymap(world)->save(c[0], keys(world).lastKey, row->value(QStringLiteral("when")).toString(), *row);
    settle(world);
  });
  step(QStringLiteral("both environments store the new binding"), [](World& world, const Captures&, const Table&) {
    const auto stores = [&](const QJsonArray& rules) {
      for (const QJsonValue& value : rules) {
        const QJsonObject rule = value.toObject();
        if (rule.value(QLatin1String("command")) == keys(world).lastCommand && rule.value(QLatin1String("key")) == keys(world).lastKey) return true;
      }
      return false;
    };
    expect(stores(storedRules(world.mc)) && stores(keys(world).elsewhere.value(QStringLiteral("env-b"))),
           QStringLiteral("this environment stores %1, the other %2")
               .arg(show(storedRules(world.mc).toVariantList()), show(keys(world).elsewhere.value(QStringLiteral("env-b")).toVariantList())));
  });
});

}  // namespace

QString conditionProblem(World& world) {
  const QString typed = keys(world).condition;
  return typed.isEmpty() ? QString() : keymap(world)->whenError(typed);
}

void setKeyFocus(World& world, const QVariantMap& focus) {
  setFocus(world, focus);
}

void pressKey(World& world, const QString& key) {
  press(world, key);
}

bool keyRan(World& world, const QString& command) {
  return ran(world, command);
}

QString describeKeyPress(World& world) {
  return describePress(world);
}

QString keyDeliveredTo(World& world) {
  return keys(world).delivered;
}
