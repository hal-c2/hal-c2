#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

#include <memory>
#include <optional>

// The web keymap, ported from @hal-c2/shared/keybindings and the web settings
// logic (apps/web/src/components/settings/KeybindingsSettings.logic.ts), so the
// shell resolves the same rules to the same commands: the defaults, the user's
// rules from the MC's keybindings.json merged over them, `when` conditions,
// and the last matching rule winning.
namespace keybindings {

// A parsed key: "mod+shift+[" is {key "[", shift, mod}. `mod` is Command on
// macOS and Ctrl elsewhere.
struct Shortcut {
  QString key;
  bool meta = false;
  bool ctrl = false;
  bool shift = false;
  bool alt = false;
  bool mod = false;

  bool operator==(const Shortcut&) const = default;
};

// A `when` condition: identifiers joined by !, && and ||.
struct When {
  enum class Kind { Identifier, Not, And, Or };
  Kind kind = Kind::Identifier;
  QString name;
  std::shared_ptr<const When> left;
  std::shared_ptr<const When> right;  // unset for Not
};
using WhenPtr = std::shared_ptr<const When>;

// One rule as keybindings.json holds it.
struct Rule {
  QString key;
  QString command;
  std::optional<QString> when;

  static std::optional<Rule> fromJson(const QJsonValue& value);
  QJsonObject toJson() const;
  bool operator==(const Rule&) const = default;
};

// A rule that parsed.
struct Binding {
  QString command;
  Shortcut shortcut;
  WhenPtr when;  // null: always
};

// The identifiers a condition is evaluated against; unknown ones are false.
using Context = QHash<QString, bool>;

std::optional<Shortcut> parseShortcut(const QString& value);
// Null when the condition is malformed or nested too deep.
WhenPtr parseWhen(const QString& expression);
bool evaluate(const WhenPtr& when, const Context& context);
std::optional<Binding> compile(const Rule& rule);

// STATIC_KEYBINDING_COMMANDS; `script.<id>.run` is a command too.
const QStringList& commands();
bool isCommand(const QString& command);

const QList<Rule>& defaults();
const QList<Binding>& defaultBindings();
// The user's rules over the defaults: a command the user binds loses all its
// default bindings; rules that do not parse or name no command are dropped.
QList<Binding> merge(const QJsonArray& userRules);
// The command the last binding for `sequence` whose condition holds runs, or
// empty.
QString resolve(const QList<Binding>& bindings, const QString& sequence, const Context& context, bool mac);

// The portable QKeySequence text the window registers for a shortcut, or empty
// when the window must leave the key alone: unmodified keys belong to the
// focused control, and a key Qt has no name for cannot be registered.
QString sequence(const Shortcut& shortcut, bool mac);
// "Ctrl+Shift+E", or "⇧⌘E" on macOS.
QString label(const Shortcut& shortcut, bool mac);
// The key as keybindings.json spells it: "mod+shift+e".
QString keyText(const Shortcut& shortcut);
// The condition as keybindings.json spells it; empty for none.
QString whenText(const WhenPtr& when);
// "Composer: Start in Background", "Run Script: Test", "Terminal: Toggle".
QString commandLabel(const QString& command);
// The key a recorder makes of a Qt key press (Qt::Key, Qt::KeyboardModifiers),
// or empty when the press needs a modifier or is a modifier itself.
QString recordedKey(int key, int modifiers, bool mac);

}  // namespace keybindings
