#include "KeybindingController.h"

#include <QGuiApplication>
#include <QKeyEvent>

#include <QJsonArray>
#include <QJsonObject>
#include <QQmlPropertyMap>
#include <QSet>

#include <algorithm>

#include "../ShellBridge.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "TerminalController.h"
#include "ThreadMenuController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<KeybindingController> registrar(QStringLiteral("keybindings"), {}, "Keybindings");

bool isScriptRun(const QString& command) {
  return command.startsWith(QLatin1String("script.")) && command.endsWith(QLatin1String(".run"));
}

// The desktop application menu's accelerators (DesktopApplicationMenu.ts).
// They are not keymap bindings: Settings → Keybindings neither lists nor
// rebinds them, and a keymap binding on the same key wins (the preview's
// zoom while it has focus).
const QList<std::pair<QString, QString>>& menuKeys() {
  static const QList<std::pair<QString, QString>> keys{
      {QStringLiteral("mod+,"), QStringLiteral("settings.open")},
      {QStringLiteral("mod+0"), QStringLiteral("view.resetZoom")},
      {QStringLiteral("mod+="), QStringLiteral("view.zoomIn")},
      {QStringLiteral("mod++"), QStringLiteral("view.zoomIn")},
      {QStringLiteral("mod+-"), QStringLiteral("view.zoomOut")},
  };
  return keys;
}

bool flag(const QVariantMap& focus, const char* key) {
  return focus.value(QLatin1String(key)).toBool();
}

// The identifiers the settings page knows (KeybindingsSettings.logic.ts): the
// core ones and every one a default condition uses.
QSet<QString> knownVariables() {
  QSet<QString> known{QStringLiteral("terminalFocus"), QStringLiteral("terminalOpen"), QStringLiteral("previewOpen"),
                      QStringLiteral("composerDraft"),
                      QStringLiteral("isWeb"), QStringLiteral("isDesktop"), QStringLiteral("true"),
                      QStringLiteral("false")};
  std::function<void(const keybindings::WhenPtr&)> collect = [&](const keybindings::WhenPtr& when) {
    if (!when) return;
    if (when->kind == keybindings::When::Kind::Identifier) known.insert(when->name);
    collect(when->left);
    collect(when->right);
  };
  for (const keybindings::Binding& binding : keybindings::defaultBindings()) collect(binding.when);
  return known;
}

}  // namespace

KeybindingController::KeybindingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  connect(&m_commands, &CommandRegistry::countChanged, this, &KeybindingController::refreshShortcuts);
  setRules({});
}

// As the web app's THREAD_JUMP_HINT_SHOW_DELAY_MS: a quick shortcut shows no hints.
void KeybindingController::setJumpModifierHeld(bool held) {
  auto* sidebar = NativeShell::of(this)->sidebar();
  if (held) {
    if (!m_jumpHintDelay.isActive()) m_jumpHintDelay.start();
    return;
  }
  m_jumpHintDelay.stop();
  sidebar->setJumpHints({}, false);
}

bool KeybindingController::eventFilter(QObject* watched, QEvent* event) {
  if (event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease) {
    const auto* key = static_cast<QKeyEvent*>(event);
    // Qt calls the Command key Control on macOS.
    const bool modifier = key->key() == Qt::Key_Control || (!m_mac && key->key() == Qt::Key_Meta);
    setJumpModifierHeld(event->type() == QEvent::KeyPress && modifier);
  } else if (event->type() == QEvent::ApplicationDeactivate) {
    setJumpModifierHeld(false);
  }
  return QObject::eventFilter(watched, event);
}

void KeybindingController::activate() {
  if (m_active) return;
  m_active = true;
  m_jumpHintDelay.setSingleShot(true);
  m_jumpHintDelay.setInterval(200);
  connect(&m_jumpHintDelay, &QTimer::timeout, this, [this] {
    QStringList labels;
    for (int n = 1; n <= 9; ++n) labels.append(shortcutLabel(QStringLiteral("thread.jump.%1").arg(n)));
    NativeShell::of(this)->sidebar()->setJumpHints(labels, true);
  });
  if (qGuiApp) qGuiApp->installEventFilter(this);
  auto* shell = NativeShell::of(this);
  auto* settings = shell->controller<SettingsController>();
  const auto followRules = [this, settings] {
    setRules(settings->config().value(QLatin1String("keybindingRules")).toArray());
    followFile(settings->config());
  };
  connect(settings, &SettingsController::configChanged, this, followRules);
  // The web's EventRouter: a reload of keybindings.json is confirmed, at most
  // once every two seconds.
  connect(settings, &SettingsController::keybindingsPushed, this, [this] {
    auto* toasts = NativeShell::of(this)->controller<ToastController>();
    if (!toasts) return;
    const QDateTime now = toasts->now();
    if (m_reloadToastAt.isValid() && m_reloadToastAt.msecsTo(now) < 2000) return;
    m_reloadToastAt = now;
    toasts->show(QStringLiteral("success"), QStringLiteral("Keybindings updated"),
                 QStringLiteral("Keybindings configuration reloaded successfully."));
  });
  auto* terminals = shell->controller<TerminalController>();
  connect(terminals, &TerminalController::changed, this, [this, terminals] {
    if (terminals->isOpen() == m_terminalOpen) return;
    m_terminalOpen = terminals->isOpen();
    refreshShortcuts();
  });
  m_terminalOpen = terminals->isOpen();
  // Conditions on the route and the running turn (draftThreadRoute, turnRunning).
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    if (key == QLatin1String("turn") || key == QLatin1String("route") || key == QLatin1String("panel") ||
        key == QLatin1String("composer")) {
      refreshShortcuts();
    }
  });
  registerCommands();
  followRules();
}

void KeybindingController::setModelPickerOpen(bool open) {
  if (open == m_modelPickerOpen) return;
  m_modelPickerOpen = open;
  emit modelPickerOpenChanged();
  refreshShortcuts();
}

bool KeybindingController::handle(const QString& action, const QVariant&) {
  if (action == QLatin1String("keybindings.resetAll")) {
    resetAll();
    return true;
  }
  if (action != QLatin1String("keybindings.openFile")) return false;
  openFile();
  return true;
}

// The web's root route: an unreadable keybindings.json is a warning naming
// the file, with the file one click away.
void KeybindingController::followFile(const QJsonObject& config) {
  const QString path = config.value(QLatin1String("keybindingsConfigPath")).toString();
  if (path != m_filePath) {
    m_filePath = path;
    emit filePathChanged();
  }
  QString issue;
  for (const QJsonValue& value : config.value(QLatin1String("issues")).toArray()) {
    const QJsonObject entry = value.toObject();
    if (entry.value(QLatin1String("kind")).toString() == QLatin1String("keybindings.malformed-config")) {
      issue = entry.value(QLatin1String("message")).toString();
    }
  }
  if (issue == m_fileIssue) return;
  m_fileIssue = issue;
  if (issue.isEmpty()) return;
  NativeShell::of(this)->controller<ToastController>()->show(
      QStringLiteral("warning"), tr("Invalid keybindings configuration"), issue,
      ToastController::Action{tr("Open keybindings.json"), [this] { openFile(); }}, 0);
}

void KeybindingController::openFile() {
  auto* shell = NativeShell::of(this);
  auto* settings = shell->controller<SettingsController>();
  auto* toasts = shell->controller<ToastController>();
  if (m_filePath.isEmpty()) return;
  const QJsonArray available = settings->config().value(QLatin1String("availableEditors")).toArray();
  const QString last = settings->deviceValue(QStringLiteral("lastEditor")).toString();
  const QString editor = available.contains(last) ? last : available.isEmpty() ? QString() : available.first().toString();
  if (editor.isEmpty()) {
    toasts->error(tr("Unable to open keybindings file"), tr("No available editors found."));
    return;
  }
  settings->writeDevice(QStringLiteral("lastEditor"), editor);
  m_client->call(this, m_client->environment(), QStringLiteral("shell.openInEditor"),
                 QJsonObject{{QStringLiteral("cwd"), m_filePath}, {QStringLiteral("editor"), editor}},
                 [toasts](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) {
                     toasts->error(tr("Unable to open keybindings file"),
                                   error->isEmpty() ? tr("The keybindings file was not opened.") : *error);
                   }
                 });
}

// The commands the shell has natively. A command no one registers (the
// in-app browser's preview keys) does nothing.
void KeybindingController::registerCommands() {
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  const auto add = [this](const QString& command, std::function<void()> run) {
    m_commands.add(command, keybindings::commandLabel(command), std::move(run));
  };
  add(QStringLiteral("navigation.back"), [navigation] { navigation->back(); });
  add(QStringLiteral("navigation.forward"), [navigation] { navigation->forward(); });
  add(QStringLiteral("thread.previous"), [this] { traverse(false); });
  add(QStringLiteral("thread.next"), [this] { traverse(true); });
  for (int n = 1; n <= 9; ++n) {
    add(QStringLiteral("thread.jump.%1").arg(n), [shell, this, index = n - 1] {
      const QStringList& keys = shell->sidebar()->orderedKeys();
      if (shell->sidebar()->isActive() && index < keys.size()) jumpTo(keys.at(index));
    });
  }
  // The native terminals', through the bridge like the drawer's buttons; split
  // and close act on the focused terminal. A build without a terminal has
  // none of them, in the palette or under a key.
  if (TerminalController::supported()) {
    for (const QString& action : {QStringLiteral("terminal.toggle"), QStringLiteral("terminal.new"),
                                  QStringLiteral("terminal.close"), QStringLiteral("terminal.split"),
                                  QStringLiteral("terminal.splitVertical")}) {
      add(action, [this, action] { m_bridge->dispatch(action); });
    }
  }
  // The route thread's running turn stops, as the composer's stop button does.
  add(QStringLiteral("thread.stop"), [this] { m_bridge->dispatch(QStringLiteral("composer.interrupt")); });
  // The route thread's first queued message steers the running turn.
  add(QStringLiteral("thread.steerQueuedMessage"), [this] { m_bridge->dispatch(QStringLiteral("composer.queue.steer")); });
  // The composer brick edits the last queued message when its caret is at
  // the start, and moves the caret there otherwise.
  add(QStringLiteral("thread.editQueuedMessage"), [this] { m_bridge->sendToBricks(QStringLiteral("composer.queue.editLast")); });
  // The composer brick sends its draft the other way, or in the background
  // (its own Enter chords do the same while it has the keyboard).
  for (const auto& [command, intent] : {std::pair{QStringLiteral("composer.sendAlternate"), QStringLiteral("alternate")},
                                        std::pair{QStringLiteral("composer.sendBackground"), QStringLiteral("background")}}) {
    add(command, [this, intent] {
      m_bridge->sendToBricks(QStringLiteral("composer.submit.key"), QVariantMap{{QStringLiteral("intent"), intent}});
    });
  }
  // The composer brick hands the stash its latest text first.
  add(QStringLiteral("composer.stash"), [this] { m_bridge->sendToBricks(QStringLiteral("composer.stash.key")); });
  // The composer brick opens its own pickers.
  add(QStringLiteral("modelPicker.toggle"), [this] { m_bridge->sendToBricks(QStringLiteral("composer.modelPicker.toggle")); });
  for (const QString& command : {QStringLiteral("composer.effort"), QStringLiteral("composer.mode"),
                                 QStringLiteral("composer.host"), QStringLiteral("composer.workspace"),
                                 QStringLiteral("composer.branch")}) {
    add(command, [this, command] {
      m_bridge->sendToBricks(QStringLiteral("composer.control.open"), QVariantMap{{QStringLiteral("command"), command}});
    });
  }
  // The route thread's, as its menu has them; Undo is the newest toast's.
  auto* menu = shell->controller<ThreadMenuController>();
  add(QStringLiteral("thread.pin"), [menu, navigation] {
    if (!navigation->threadKey().isEmpty()) menu->togglePin(navigation->threadKey());
  });
  add(QStringLiteral("thread.settle"), [menu, navigation] {
    if (!navigation->threadKey().isEmpty()) menu->toggleSettle(navigation->threadKey());
  });
  add(QStringLiteral("thread.undo"), [menu] { menu->undo(); });
}

void KeybindingController::jumpTo(const QString& threadKey) {
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (navigation->threadKey() != threadKey) navigation->open(NavigationController::Route::thread(threadKey));
}

// The sidebar's next or previous row (resolveAdjacentThreadId): from nothing
// open, the first or last; nothing past either end.
void KeybindingController::traverse(bool next) {
  auto* sidebar = NativeShell::of(this)->sidebar();
  if (!sidebar->isActive()) return;
  const QStringList& keys = sidebar->orderedKeys();
  if (keys.isEmpty()) return;
  const QString current = NativeShell::of(this)->controller<NavigationController>()->threadKey();
  if (current.isEmpty()) {
    jumpTo(next ? keys.constFirst() : keys.constLast());
    return;
  }
  const qsizetype index = keys.indexOf(current);
  if (index < 0) return;
  const qsizetype target = index + (next ? 1 : -1);
  if (target >= 0 && target < keys.size()) jumpTo(keys.at(target));
}

void KeybindingController::setMac(bool mac) {
  m_mac = mac;
  m_sequences.clear();
  setRules(m_rules);
}

void KeybindingController::setRules(const QJsonArray& rules) {
  if (rules == m_rules && !m_sequences.isEmpty()) return;
  m_rules = rules;
  m_bindings = keybindings::merge(rules);
  m_sequences.clear();
  for (const keybindings::Binding& binding : std::as_const(m_bindings)) {
    m_sequences.append(keybindings::sequence(binding.shortcut, m_mac));
  }
  m_menuSequences.clear();
  for (const auto& [key, command] : menuKeys()) {
    m_menuSequences.append(keybindings::sequence(*keybindings::parseShortcut(key), m_mac));
  }
  m_commands.setShortcuts([this](const QString& command) { return shortcutLabel(command); });
  refreshShortcuts();
  refreshRows();
}

keybindings::Context KeybindingController::context(const QVariantMap& focus) const {
  QString routeKind;
  if (auto* shell = NativeShell::of(this)) {
    // Controllers are built in name order; navigation comes after this one.
    if (auto* navigation = shell->controller<NavigationController>()) routeKind = navigation->route().kind;
  }
  // The desktop's preview is the right panel's Previews tab.
  bool previewOpen = false;
  if (auto* shell = NativeShell::of(this)) {
    if (auto* panel = shell->controller<RightPanelController>()) {
      previewOpen = panel->isOpen() && panel->activeTab() == QLatin1String("previews");
    }
  }
  return {
      {QStringLiteral("previewOpen"), previewOpen},
      {QStringLiteral("modelPickerOpen"), m_modelPickerOpen},
      // The composer holds text the user has not sent.
      {QStringLiteral("composerDraft"),
       !m_bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("text")).toString().trimmed().isEmpty()},
      {QStringLiteral("terminalFocus"), flag(focus, "terminal")},
      {QStringLiteral("composerFocus"), flag(focus, "composer")},
      {QStringLiteral("editableFocus"), flag(focus, "editable")},
      {QStringLiteral("terminalOpen"), m_terminalOpen},
      {QStringLiteral("draftThreadRoute"), routeKind == QLatin1String("draft")},
      {QStringLiteral("turnRunning"), m_bridge->state()->value(QStringLiteral("turn")).toMap().value(QStringLiteral("running")).toBool()},
      {QStringLiteral("isDesktop"), true},
      {QStringLiteral("isWeb"), false},
  };
}

QString KeybindingController::resolve(const QString& sequence, const QVariantMap& focus) const {
  const keybindings::Context now = context(focus);
  for (qsizetype index = m_bindings.size() - 1; index >= 0; --index) {
    if (m_sequences.at(index) == sequence && keybindings::evaluate(m_bindings.at(index).when, now)) {
      return m_bindings.at(index).command;
    }
  }
  if (const qsizetype menu = m_menuSequences.indexOf(sequence); menu >= 0) return menuKeys().at(menu).second;
  return {};
}

bool KeybindingController::press(const QString& sequence, const QVariantMap& focus) {
  const QString command = resolve(sequence, focus);
  if (m_commands.run(command)) return true;
  if (isScriptRun(command)) {
    m_bridge->dispatch(QStringLiteral("workspace.runScript"),
                       QVariantMap{{QStringLiteral("scriptId"), command.mid(7, command.size() - 11)}});
    return true;
  }
  return false;
}

// One entry per sequence; each flag says whether the key is the shell's with
// that focus: the chrome, a terminal, the composer's field, or any other text
// field (`editable`).
void KeybindingController::refreshShortcuts() {
  const QVariantMap chrome;
  const QVariantMap composer{{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}};
  const QVariantMap editable{{QStringLiteral("editable"), true}};
  const QVariantMap terminal{{QStringLiteral("terminal"), true}};
  const auto native = [this](const QString& command) { return m_commands.contains(command) || isScriptRun(command); };
  QVariantList shortcuts;
  QSet<QString> seen;
  for (const QString& sequence : m_sequences + m_menuSequences) {
    if (sequence.isEmpty() || seen.contains(sequence)) continue;
    seen.insert(sequence);
    shortcuts.append(QVariantMap{
        {QStringLiteral("sequence"), sequence},
        // Held down, a toggle that cycles must not spin through its states.
        {QStringLiteral("autoRepeat"), resolve(sequence, chrome) != kAppearanceCycle},
        {QStringLiteral("chrome"), native(resolve(sequence, chrome))},
        {QStringLiteral("composer"), native(resolve(sequence, composer))},
        {QStringLiteral("editable"), native(resolve(sequence, editable))},
        {QStringLiteral("terminal"), native(resolve(sequence, terminal))},
    });
  }
  if (shortcuts == m_shortcuts) return;
  m_shortcuts = shortcuts;
  emit shortcutsChanged();
}

// findEffectiveShortcutForCommand: the newest binding for the command whose
// key no newer binding has taken.
QString KeybindingController::shortcutLabel(const QString& command) const {
  const keybindings::Context now = context({});
  QSet<QString> claimed;
  for (qsizetype index = m_bindings.size() - 1; index >= 0; --index) {
    const keybindings::Binding& binding = m_bindings.at(index);
    if (!keybindings::evaluate(binding.when, now)) continue;
    const QString label = keybindings::label(binding.shortcut, m_mac);
    if (claimed.contains(label)) continue;
    claimed.insert(label);
    if (binding.command == command) return label;
  }
  for (const auto& [key, menuCommand] : menuKeys()) {
    const QString label = keybindings::label(*keybindings::parseShortcut(key), m_mac);
    if (menuCommand == command && !claimed.contains(label)) return label;
  }
  return {};
}

// buildKeybindingRows in KeybindingsSettings.logic.ts.
void KeybindingController::refreshRows() {
  const QList<keybindings::Binding>& defaults = keybindings::defaultBindings();
  QVariantList rows;
  for (qsizetype index = 0; index < m_bindings.size(); ++index) {
    const keybindings::Binding& binding = m_bindings.at(index);
    const QString key = keybindings::keyText(binding.shortcut);
    const QString when = keybindings::whenText(binding.when);
    const keybindings::Binding* fallback = nullptr;
    const keybindings::Binding* sameWhen = nullptr;
    const keybindings::Binding* same = nullptr;
    for (const keybindings::Binding& entry : defaults) {
      if (entry.command != binding.command) continue;
      if (!fallback) fallback = &entry;
      if (keybindings::whenText(entry.when) != when) continue;
      if (!sameWhen) sameWhen = &entry;
      if (keybindings::keyText(entry.shortcut) == key) {
        same = &entry;
        break;
      }
    }
    const keybindings::Binding* standard = same ? same : sameWhen ? sameWhen : fallback;
    const QString source = isScriptRun(binding.command) ? QStringLiteral("Project")
                           : same                       ? QStringLiteral("Default")
                                                        : QStringLiteral("Custom");
    const QString label = keybindings::commandLabel(binding.command);
    const QString defaultKey = standard ? keybindings::keyText(standard->shortcut) : QString();
    rows.append(QVariantMap{
        {QStringLiteral("id"), QStringLiteral("%1\n%2\n%3\n%4").arg(binding.command, key, when).arg(index)},
        {QStringLiteral("command"), binding.command},
        {QStringLiteral("label"), label},
        {QStringLiteral("key"), key},
        {QStringLiteral("keyLabel"), keybindings::label(binding.shortcut, m_mac)},
        {QStringLiteral("when"), when},
        {QStringLiteral("source"), source},
        {QStringLiteral("defaultKey"), defaultKey},
        {QStringLiteral("defaultWhen"), standard ? keybindings::whenText(standard->when) : QString()},
        {QStringLiteral("canReset"), source == QLatin1String("Custom") && !defaultKey.isEmpty()},
        {QStringLiteral("canRemove"), source != QLatin1String("Default")},
        {QStringLiteral("search"),
         QStringList{binding.command, label, key, when, source}.join(QLatin1Char('\n')).toLower()},
    });
  }
  std::stable_sort(rows.begin(), rows.end(), [](const QVariant& left, const QVariant& right) {
    const QVariantMap a = left.toMap();
    const QVariantMap b = right.toMap();
    const int command = QString::localeAwareCompare(a.value(QStringLiteral("command")).toString(),
                                                    b.value(QStringLiteral("command")).toString());
    if (command != 0) return command < 0;
    return QString::localeAwareCompare(a.value(QStringLiteral("key")).toString(),
                                       b.value(QStringLiteral("key")).toString()) < 0;
  });
  m_rows = rows;
  for (QVariant& row : m_rows) {
    QVariantMap map = row.toMap();
    map.insert(QStringLiteral("conflicts"),
               conflicts(map.value(QStringLiteral("id")).toString(), map.value(QStringLiteral("key")).toString(),
                         map.value(QStringLiteral("when")).toString()));
    row = map;
  }
  emit bindingsChanged();
}

QStringList KeybindingController::conflicts(const QString& rowId, const QString& key, const QString& when) const {
  if (key.trimmed().isEmpty()) return {};
  QStringList labels;
  for (const QVariant& value : m_rows) {
    const QVariantMap row = value.toMap();
    const QString rowWhen = row.value(QStringLiteral("when")).toString();
    if (row.value(QStringLiteral("id")).toString() == rowId || row.value(QStringLiteral("key")).toString() != key) {
      continue;
    }
    if (!rowWhen.isEmpty() && !when.isEmpty() && rowWhen != when) continue;
    const QString label = row.value(QStringLiteral("label")).toString();
    if (!labels.contains(label)) labels.append(label);
  }
  labels.sort();
  return labels;
}

QString KeybindingController::keyLabel(const QString& key) const {
  const std::optional<keybindings::Shortcut> shortcut = keybindings::parseShortcut(key);
  return shortcut ? keybindings::label(*shortcut, m_mac) : key;
}

QString KeybindingController::whenError(const QString& expression) const {
  const QString trimmed = expression.trimmed();
  if (trimmed.isEmpty() || keybindings::parseWhen(trimmed)) return {};
  return tr("Use variables with !, &&, ||, and parentheses.");
}

QStringList KeybindingController::unknownVariables(const QString& expression) const {
  static const QSet<QString> known = knownVariables();
  QSet<QString> unknown;
  std::function<void(const keybindings::WhenPtr&)> collect = [&](const keybindings::WhenPtr& when) {
    if (!when) return;
    if (when->kind == keybindings::When::Kind::Identifier && !known.contains(when->name)) unknown.insert(when->name);
    collect(when->left);
    collect(when->right);
  };
  collect(keybindings::parseWhen(expression.trimmed()));
  QStringList list(unknown.cbegin(), unknown.cend());
  list.sort();
  return list;
}

QStringList KeybindingController::commandOptions() const {
  QStringList commands = keybindings::commands();
  for (const keybindings::Binding& binding : m_bindings) {
    if (!commands.contains(binding.command)) commands.append(binding.command);
  }
  std::sort(commands.begin(), commands.end(), [](const QString& left, const QString& right) {
    return QString::localeAwareCompare(keybindings::commandLabel(left), keybindings::commandLabel(right)) < 0;
  });
  return commands;
}

namespace {

// The rule a row stands for, as the MC stores it.
QJsonObject target(const QVariantMap& row) {
  QJsonObject rule{{QStringLiteral("command"), row.value(QStringLiteral("command")).toString()},
                   {QStringLiteral("key"), row.value(QStringLiteral("key")).toString()}};
  if (const QString when = row.value(QStringLiteral("when")).toString().trimmed(); !when.isEmpty()) {
    rule.insert(QStringLiteral("when"), when);
  }
  return rule;
}

}  // namespace

void KeybindingController::save(const QString& command, const QString& key, const QString& when,
                                const QVariantMap& replacing) {
  QJsonObject input{{QStringLiteral("command"), command}, {QStringLiteral("key"), key.trimmed()}};
  if (!when.trimmed().isEmpty()) input.insert(QStringLiteral("when"), when.trimmed());
  if (!replacing.isEmpty()) input.insert(QStringLiteral("replace"), target(replacing));
  call(QStringLiteral("hal-c2.upsertKeybinding"), input, tr("Unable to save keybinding"),
       tr("The keybinding was not saved."));
}

void KeybindingController::remove(const QVariantMap& row) {
  call(QStringLiteral("hal-c2.removeKeybinding"), target(row), tr("Unable to remove keybinding"),
       tr("The keybinding was not removed."));
}

void KeybindingController::reset(const QVariantMap& row) {
  const QString defaultKey = row.value(QStringLiteral("defaultKey")).toString();
  if (defaultKey.isEmpty()) return;
  save(row.value(QStringLiteral("command")).toString(), defaultKey, row.value(QStringLiteral("defaultWhen")).toString(),
       row);
}

void KeybindingController::resetAll() {
  if (m_rules.isEmpty()) return;
  auto* menu = NativeShell::of(this)->controller<MenuController>();
  if (!menu) return;
  const QJsonArray rules = m_rules;
  menu->confirm(tr("Reset every keybinding to its default?"),
                rules.size() == 1 ? tr("This removes your 1 custom keybinding.") : tr("This removes your %1 custom keybindings.").arg(rules.size()),
                tr("Reset keybindings"), true, [this, rules] {
                  for (const QJsonValue& rule : rules) {
                    call(QStringLiteral("hal-c2.removeKeybinding"), rule.toObject(), tr("Unable to reset keybindings"),
                         tr("A keybinding was not removed."));
                  }
                });
}

void KeybindingController::call(const QString& method, const QJsonObject& input, const QString& failureTitle,
                                const QString& failure) {
  // The keymap is the user's on every environment they reach, as the web
  // saves it: the shell's own, and each other one that is online and theirs
  // to change. The shell's own answers as `config.keybindings`.
  ShellStore* store = m_store;
  QStringList environments{m_client->environment()};
  for (const QString& environmentId : store->environments()) {
    if (!environments.contains(environmentId) && store->environmentOnline(environmentId)) {
      environments.append(environmentId);
    }
  }
  for (const QString& environmentId : std::as_const(environments)) {
    ++m_saving;
    m_client->call(this, environmentId, method, input,
                   [this, failureTitle, failure](const QJsonValue&, const std::optional<QString>& error) {
                     --m_saving;
                     emit savingChanged();
                     if (error) {
                       NativeShell::of(this)->controller<ToastController>()->error(
                           failureTitle, error->isEmpty() ? failure : *error);
                     }
                   });
  }
  emit savingChanged();
}
