#include "KeybindingController.h"

#include <QJsonObject>
#include <QSet>

#include <algorithm>

#include "../ShellBridge.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsController.h"
#include "SidebarController.h"
#include "TerminalController.h"
#include "ThreadMenuController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<KeybindingController> registrar(QStringLiteral("keybindings"), {}, "Keybindings");

bool isScriptRun(const QString& command) {
  return command.startsWith(QLatin1String("script.")) && command.endsWith(QLatin1String(".run"));
}

bool flag(const QVariantMap& focus, const char* key) {
  return focus.value(QLatin1String(key)).toBool();
}

// The identifiers the settings page knows (KeybindingsSettings.logic.ts): the
// core ones and every one a default condition uses.
QSet<QString> knownVariables() {
  QSet<QString> known{QStringLiteral("terminalFocus"), QStringLiteral("terminalOpen"), QStringLiteral("isWeb"),
                      QStringLiteral("isDesktop"), QStringLiteral("true"), QStringLiteral("false")};
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

KeybindingController::KeybindingController(ShellBridge* bridge, NodeClient* client, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client) {
  connect(&m_commands, &CommandRegistry::countChanged, this, &KeybindingController::refreshShortcuts);
  setRules({});
}

void KeybindingController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  auto* settings = shell->controller<SettingsController>();
  const auto followRules = [this, settings] {
    setRules(settings->config().value(QLatin1String("keybindingRules")).toArray());
  };
  connect(settings, &SettingsController::configChanged, this, followRules);
  auto* terminals = shell->controller<TerminalController>();
  connect(terminals, &TerminalController::changed, this, [this, terminals] {
    if (terminals->isOpen() == m_terminalOpen) return;
    m_terminalOpen = terminals->isOpen();
    refreshShortcuts();
  });
  m_terminalOpen = terminals->isOpen();
  registerCommands();
  followRules();
}

// The commands the shell has natively. Everything else in the keymap is still
// the page's.
void KeybindingController::registerCommands() {
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  const auto add = [this](const QString& command, std::function<void()> run) {
    m_commands.add(command, keybindings::commandLabel(command), std::move(run));
  };
  add(QStringLiteral("navigation.back"), [navigation] { navigation->back(); });
  // DraftController starts it in the project the window shows.
  add(QStringLiteral("chat.new"), [this] { m_bridge->dispatch(QStringLiteral("thread.new")); });
  add(QStringLiteral("thread.previous"), [this] { traverse(false); });
  add(QStringLiteral("thread.next"), [this] { traverse(true); });
  for (int n = 1; n <= 9; ++n) {
    add(QStringLiteral("thread.jump.%1").arg(n), [shell, this, index = n - 1] {
      const QStringList& keys = shell->sidebar()->orderedKeys();
      if (shell->sidebar()->isActive() && index < keys.size()) jumpTo(keys.at(index));
    });
  }
  // The native terminals', through the bridge like the drawer's buttons; split
  // and close act on the focused terminal.
  for (const QString& action : {QStringLiteral("terminal.toggle"), QStringLiteral("terminal.new"),
                                QStringLiteral("terminal.close"), QStringLiteral("terminal.split"),
                                QStringLiteral("terminal.splitVertical")}) {
    add(action, [this, action] { m_bridge->dispatch(action); });
  }
  // The page still owns collapsing; this is the native toggle's action.
  add(QStringLiteral("sidebar.toggle"), [this] { m_bridge->dispatch(QStringLiteral("sidebar.toggle")); });
  // The route thread's running turn stops, as the composer's stop button does.
  add(QStringLiteral("thread.stop"), [this] { m_bridge->dispatch(QStringLiteral("composer.interrupt")); });
  // The composer brick opens its own pickers.
  add(QStringLiteral("modelPicker.toggle"), [this] { m_bridge->sendToPage(QStringLiteral("composer.modelPicker.toggle")); });
  for (const QString& command : {QStringLiteral("composer.effort"), QStringLiteral("composer.mode"),
                                 QStringLiteral("composer.host"), QStringLiteral("composer.workspace"),
                                 QStringLiteral("composer.branch")}) {
    add(command, [this, command] {
      m_bridge->sendToPage(QStringLiteral("composer.control.open"), QVariantMap{{QStringLiteral("command"), command}});
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
  add(QStringLiteral("thread.copyReference"), [menu, navigation] {
    if (!navigation->threadKey().isEmpty()) menu->copyReference(navigation->threadKey());
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
  return {
      {QStringLiteral("terminalFocus"), flag(focus, "terminal")},
      {QStringLiteral("composerFocus"), flag(focus, "composer")},
      {QStringLiteral("editableFocus"), flag(focus, "editable")},
      {QStringLiteral("terminalOpen"), m_terminalOpen},
      {QStringLiteral("draftThreadRoute"),
       routeKind == QLatin1String("draft") || routeKind == QLatin1String("newThread")},
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
  // The page's command: with the chrome focused it has not seen the key, so
  // it gets it to resolve in its own context.
  if (flag(focus, "page") || flag(focus, "terminal")) return false;
  const qsizetype index = m_sequences.indexOf(sequence);
  if (index < 0) return false;
  const keybindings::Shortcut& shortcut = m_bindings.at(index).shortcut;
  m_bridge->sendToPage(QStringLiteral("keybinding.press"),
                       QVariantMap{
                           {QStringLiteral("key"), shortcut.key},
                           {QStringLiteral("ctrlKey"), shortcut.ctrl || (shortcut.mod && !m_mac)},
                           {QStringLiteral("metaKey"), shortcut.meta || (shortcut.mod && m_mac)},
                           {QStringLiteral("shiftKey"), shortcut.shift},
                           {QStringLiteral("altKey"), shortcut.alt},
                       });
  return true;
}

bool KeybindingController::handle(const QString& action, const QVariant& payload) {
  if (action != QLatin1String("keybinding.press")) return false;
  const QVariantMap press = payload.toMap();
  const bool ctrl = press.value(QStringLiteral("ctrlKey")).toBool();
  const bool meta = press.value(QStringLiteral("metaKey")).toBool();
  keybindings::Shortcut shortcut;
  shortcut.key = press.value(QStringLiteral("key")).toString().toLower();
  shortcut.mod = m_mac ? meta : ctrl;
  shortcut.ctrl = m_mac && ctrl;
  shortcut.meta = !m_mac && meta;
  shortcut.shift = press.value(QStringLiteral("shiftKey")).toBool();
  shortcut.alt = press.value(QStringLiteral("altKey")).toBool();
  // The embed checked the command is the same without its focus.
  const QString command = resolve(keybindings::sequence(shortcut, m_mac));
  return m_commands.run(command);
}

// One entry per sequence; the page and terminal flags say whether the key is
// the shell's even with that focus.
void KeybindingController::refreshShortcuts() {
  const QVariantMap page{{QStringLiteral("page"), true}};
  const QVariantMap terminal{{QStringLiteral("terminal"), true}};
  const auto native = [this](const QString& command) { return m_commands.contains(command) || isScriptRun(command); };
  QVariantList shortcuts;
  QSet<QString> seen;
  for (const QString& sequence : std::as_const(m_sequences)) {
    if (sequence.isEmpty() || seen.contains(sequence)) continue;
    seen.insert(sequence);
    shortcuts.append(QVariantMap{
        {QStringLiteral("sequence"), sequence},
        {QStringLiteral("page"), native(resolve(sequence, page))},
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

// The rule a row stands for, as the node stores it.
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

void KeybindingController::call(const QString& method, const QJsonObject& input, const QString& failureTitle,
                                const QString& failure) {
  ++m_saving;
  emit savingChanged();
  m_client->call(m_client->environment(), method, input,
                 // The new rules come back as the config's `config.keybindings`.
                 [this, failureTitle, failure](const QJsonValue&, const std::optional<QString>& error) {
                   --m_saving;
                   emit savingChanged();
                   if (error) {
                     NativeShell::of(this)->controller<ToastController>()->error(
                         failureTitle, error->isEmpty() ? failure : *error);
                   }
                 });
}
