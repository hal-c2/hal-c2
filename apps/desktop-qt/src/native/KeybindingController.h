#pragma once

#include <QDateTime>
#include <QJsonArray>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QVariant>

#include "CommandRegistry.h"
#include "Keybindings.h"
#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The shell's keymap, as the `Keybindings` QML singleton: the web defaults
// with the user's rules from the MC's keybindings.json merged over them
// (the `keybindingRules` of the MC's config), resolved the way the web
// resolves them, and run natively where the shell has the command.
//
// ShellWindow registers one window shortcut per sequence in `shortcuts` and
// hands every activation to press(). Who gets a key:
//   - A command in `commands` (CommandRegistry) or a project script runs
//     here, whatever has focus.
//   - A key the shell has no command for is not a window shortcut; it stays
//     with the focused control.
//   - In a terminal, only a sequence that resolves to a native command with
//     terminalFocus set is taken (mod+j, mod+d, mod+shift+d, mod+n, mod+w by
//     default, as the web's); every other chord, Ctrl+K included, reaches the
//     terminal. Where mod is Ctrl, the web's split takes Ctrl+D from the shell.
//   - Unmodified keys are never registered.
//   - The application menu's accelerators (mod+, for settings, the app zoom)
//     come after every keymap binding, and are not rows in Settings.
//
// Settings → Keybindings edits the rules through the MC (`bindings`,
// save/remove/reset) on every environment the user reaches and may change;
// the shell's own MC pushes the new rules back to every client. A
// keybindings.json the MC cannot parse (its config's `issues`) leaves the
// defaults in force and is told once, with a way to open the file.
class KeybindingController : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(CommandRegistry* commands READ commands CONSTANT)
  // [{sequence, chrome, composer, editable, terminal, autoRepeat}]: every
  // sequence the keymap binds, whether its shortcut is enabled while the
  // chrome, the composer's field, another text field or a terminal has focus,
  // and whether holding it down repeats it.
  Q_PROPERTY(QVariantList shortcuts READ shortcuts NOTIFY shortcutsChanged)
  // The settings page's rows, sorted by command and key: {id, command, label,
  // key, keyLabel, when, source (Default, Custom or Project), defaultKey,
  // defaultWhen, conflicts (command labels), canReset, canRemove, search}.
  Q_PROPERTY(QVariantList bindings READ bindings NOTIFY bindingsChanged)
  // A save or removal is on its way to the MC.
  Q_PROPERTY(bool saving READ saving NOTIFY savingChanged)
  // Where the MC keeps keybindings.json, or empty before it says.
  Q_PROPERTY(QString filePath READ filePath NOTIFY filePathChanged)

public:
  // The appearance toggle's command, which ThemeController registers.
  static inline const QString kAppearanceCycle = QStringLiteral("appearance.cycle");

  KeybindingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  // Registers the native commands and follows the MC's rules.
  void activate() override;
  // Keys reach it through press(), never as actions.
  bool handle(const QString& action, const QVariant&) override;

  CommandRegistry* commands() { return &m_commands; }
  QVariantList shortcuts() const { return m_shortcuts; }
  QVariantList bindings() const { return m_rows; }
  bool saving() const { return m_saving > 0; }
  const QList<keybindings::Binding>& resolved() const { return m_bindings; }
  // Whether chords read as macOS ones (mod is Command).
  bool mac() const { return m_mac; }

  // A window shortcut fired. `focus` says where the keyboard is:
  // {terminal, composer, editable}. True when the key ran a command here.
  Q_INVOKABLE bool press(const QString& sequence, const QVariantMap& focus = {});
  // The command `sequence` runs with that focus, or empty.
  QString resolve(const QString& sequence, const QVariantMap& focus = {}) const;
  // The label of the shortcut that runs `command` outside any focus, or empty.
  Q_INVOKABLE QString shortcutLabel(const QString& command) const;

  // Settings → Keybindings.
  Q_INVOKABLE QString recordKey(int key, int modifiers) const { return keybindings::recordedKey(key, modifiers, m_mac); }
  // "mod+shift+y" as the rows show it: "Ctrl+Shift+Y", or "⇧⌘Y" on macOS.
  Q_INVOKABLE QString keyLabel(const QString& key) const;
  Q_INVOKABLE QString commandLabel(const QString& command) const { return keybindings::commandLabel(command); }
  // Why a condition cannot be used, or empty (an empty condition is "always").
  Q_INVOKABLE QString whenError(const QString& expression) const;
  // The identifiers in a condition no context sets.
  Q_INVOKABLE QStringList unknownVariables(const QString& expression) const;
  // The command labels another binding on `key` (whose condition can also
  // apply) runs, other than the row `rowId`.
  Q_INVOKABLE QStringList conflicts(const QString& rowId, const QString& key, const QString& when) const;
  // Every command a binding can be added for, sorted by label.
  Q_INVOKABLE QStringList commandOptions() const;
  // Binds `command` to `key` when `when` (empty: always), replacing the row
  // `replacing` when it is one of `bindings`.
  Q_INVOKABLE void save(const QString& command, const QString& key, const QString& when,
                        const QVariantMap& replacing = {});
  Q_INVOKABLE void remove(const QVariantMap& row);
  // Puts a custom row back to its command's default.
  Q_INVOKABLE void reset(const QVariantMap& row);
  // Opens keybindings.json on the MC in the editor last used there, else the
  // first it has; says so when it cannot (`keybindings.openFile` as an action).
  Q_INVOKABLE void openFile();
  QString filePath() const { return m_filePath; }

  void setMac(bool mac);

  // The thread jump modifier (the one thread.jump.1 is bound with) went down
  // or up: held for a moment, the sidebar's first rows show their jump keys.
  void setJumpModifierHeld(bool held);

signals:
  void shortcutsChanged();
  void bindingsChanged();
  void savingChanged();
  void filePathChanged();

protected:
  bool eventFilter(QObject* watched, QEvent* event) override;

private:
  QTimer m_jumpHintDelay;
  void setRules(const QJsonArray& rules);
  void refreshShortcuts();
  void refreshRows();
  keybindings::Context context(const QVariantMap& focus) const;
  bool isNative(const QString& command) const { return m_commands.contains(command); }
  void registerCommands();
  void jumpTo(const QString& threadKey);
  void traverse(bool next);
  void call(const QString& method, const QJsonObject& input, const QString& failureTitle, const QString& failure);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
#ifdef Q_OS_MACOS
  bool m_mac = true;
#else
  bool m_mac = false;
#endif
  bool m_terminalOpen = false;
  QJsonArray m_rules;
  QList<keybindings::Binding> m_bindings = keybindings::defaultBindings();
  // Each binding's sequence, as m_bindings.
  QStringList m_sequences;
  // Each application menu accelerator's, as menuKeys().
  QStringList m_menuSequences;
  CommandRegistry m_commands;
  QVariantList m_shortcuts;
  QVariantList m_rows;
  int m_saving = 0;
  QString m_filePath;
  // The file's problem last told, so each is told once.
  QString m_fileIssue;
  void followFile(const QJsonObject& config);
  // When "Keybindings updated" last showed; pushes closer than the cooldown
  // stay quiet, as the web's do.
  QDateTime m_reloadToastAt;
};
