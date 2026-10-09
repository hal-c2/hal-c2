// The keymap. Laws of the pure functions (Keybindings.h): a key's text and its
// parse, a condition's text and its parse, the window shortcut a key registers
// and the key press that fires it. Then KeybindingController as a state
// machine against a fake MC that keeps keybindings.json as the real one does
// (apps/server-ex lib/hal_c2/keybindings.ex): rules pushed, saved, removed and
// reset from a row, the MC's answers held back, refused, or arriving late, the
// platform and the model picker switching. After every step the rows, the
// registered shortcuts and the command every key runs in every focus are the
// model's, and each change signal fired for a change.

#include "Prop.h"

#include "FakeMc.h"
#include "CommandPaletteController.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QKeySequence>
#include <QTemporaryDir>

#include <algorithm>
#include <optional>
#include <vector>

using keybindings::Shortcut;

namespace {

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

// --- the laws ---

const QStringList kKeys{
    QStringLiteral("a"),      QStringLiteral("k"),     QStringLiteral("0"),         QStringLiteral("9"),
    QStringLiteral("["),      QStringLiteral("]"),     QStringLiteral("="),         QStringLiteral("+"),
    QStringLiteral("-"),      QStringLiteral(","),     QStringLiteral("/"),         QStringLiteral(";"),
    QStringLiteral("'"),      QStringLiteral("`"),     QStringLiteral("\\"),        QStringLiteral(" "),
    QStringLiteral("escape"), QStringLiteral("enter"), QStringLiteral("arrowup"),   QStringLiteral("arrowleft"),
    QStringLiteral("f5"),     QStringLiteral("f12"),   QStringLiteral("tab"),       QStringLiteral("backspace"),
    QStringLiteral("delete"), QStringLiteral("home"),  QStringLiteral("pageup"),
};

Shortcut someShortcut() {
  Shortcut shortcut;
  shortcut.key = pick(kKeys);
  shortcut.meta = *rc::gen::arbitrary<bool>();
  shortcut.ctrl = *rc::gen::arbitrary<bool>();
  shortcut.shift = *rc::gen::arbitrary<bool>();
  shortcut.alt = *rc::gen::arbitrary<bool>();
  shortcut.mod = *rc::gen::arbitrary<bool>();
  return shortcut;
}

// A way a user may spell it in keybindings.json: modifiers in any order and
// under any of their names, any case, spaces around the parts.
QString spelling(const Shortcut& shortcut) {
  const auto cased = [](const QString& token) { return *rc::gen::arbitrary<bool>() ? token.toUpper() : token; };
  const auto padded = [](const QString& token) { return *rc::gen::arbitrary<bool>() ? QStringLiteral(" %1 ").arg(token) : token; };
  QStringList modifiers;
  if (shortcut.meta) modifiers.append(pick(QStringList{QStringLiteral("cmd"), QStringLiteral("meta")}));
  if (shortcut.ctrl) modifiers.append(pick(QStringList{QStringLiteral("ctrl"), QStringLiteral("control")}));
  if (shortcut.alt) modifiers.append(pick(QStringList{QStringLiteral("alt"), QStringLiteral("option")}));
  if (shortcut.shift) modifiers.append(QStringLiteral("shift"));
  if (shortcut.mod) modifiers.append(QStringLiteral("mod"));
  QStringList tokens;
  for (const QString& modifier : std::as_const(modifiers)) {
    tokens.insert(*rc::gen::inRange<qsizetype>(0, tokens.size() + 1), padded(cased(modifier)));
  }
  const QString key = shortcut.key == QLatin1String(" ")        ? QStringLiteral("space")
                      : shortcut.key == QLatin1String("escape") ? pick(QStringList{QStringLiteral("esc"), QStringLiteral("escape")})
                                                                : shortcut.key;
  // "+" as the key is only read last ("mod++").
  const qsizetype at = key == QLatin1String("+") ? tokens.size() : *rc::gen::inRange<qsizetype>(0, tokens.size() + 1);
  tokens.insert(at, padded(cased(key)));
  return tokens.join(QLatin1Char('+'));
}

// The modifiers a shortcut holds once `mod` is the platform's.
struct Pressed {
  QString key;
  bool meta, ctrl, shift, alt;
  bool operator==(const Pressed&) const = default;
};

Pressed pressed(const Shortcut& shortcut, bool mac) {
  return {shortcut.key, shortcut.meta || (shortcut.mod && mac), shortcut.ctrl || (shortcut.mod && !mac), shortcut.shift,
          shortcut.alt};
}

// A random condition over a, b, c and the constants.
keybindings::WhenPtr someWhen(int depth) {
  using keybindings::When;
  const int kind = depth <= 0 ? 0 : *rc::gen::inRange(0, 4);
  if (kind == 0) {
    return std::make_shared<When>(When{When::Kind::Identifier,
                                       pick(QStringList{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"),
                                                        QStringLiteral("true"), QStringLiteral("false")}),
                                       {}, {}});
  }
  if (kind == 1) return std::make_shared<When>(When{When::Kind::Not, {}, someWhen(depth - 1), {}});
  return std::make_shared<When>(
      When{kind == 2 ? When::Kind::And : When::Kind::Or, {}, someWhen(depth - 1), someWhen(depth - 1)});
}

bool sameMeaning(const keybindings::WhenPtr& left, const keybindings::WhenPtr& right) {
  for (int bits = 0; bits < 8; ++bits) {
    const keybindings::Context context{{QStringLiteral("a"), bool(bits & 1)},
                                       {QStringLiteral("b"), bool(bits & 2)},
                                       {QStringLiteral("c"), bool(bits & 4)}};
    if (keybindings::evaluate(left, context) != keybindings::evaluate(right, context)) return false;
  }
  return true;
}

// --- the controller ---

const QStringList kCommands{QStringLiteral("diff.toggle"),     QStringLiteral("chat.new"),
                            QStringLiteral("thread.pin"),      QStringLiteral("terminal.toggle"),
                            QStringLiteral("navigation.back"), QStringLiteral("script.test.run"),
                            QStringLiteral("bogus.command")};
// The same keys spelled several ways, and one that does not parse.
const QStringList kRuleKeys{QStringLiteral("mod+k"),       QStringLiteral("Mod+K"),        QStringLiteral(" mod+k "),
                            QStringLiteral("mod+shift+y"), QStringLiteral("shift+mod+y"),  QStringLiteral("ctrl+alt+x"),
                            QStringLiteral("control+alt+x"), QStringLiteral("mod+j"),      QStringLiteral("mod+d"),
                            QStringLiteral("mod+k+j")};
const QStringList kRuleWhens{QString(),
                             QStringLiteral("terminalFocus"),
                             QStringLiteral("!terminalFocus"),
                             QStringLiteral("composerFocus && turnRunning"),
                             QStringLiteral("composerFocus&&turnRunning"),
                             QStringLiteral("modelPickerOpen"),
                             QStringLiteral("(")};
const QList<std::pair<QString, QString>> kMenuKeys{
    {QStringLiteral("mod+,"), QStringLiteral("settings.open")}, {QStringLiteral("mod+0"), QStringLiteral("view.resetZoom")},
    {QStringLiteral("mod+="), QStringLiteral("view.zoomIn")},   {QStringLiteral("mod++"), QStringLiteral("view.zoomIn")},
    {QStringLiteral("mod+-"), QStringLiteral("view.zoomOut")},
};
const QList<QVariantMap> kFocuses{
    {},
    {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}},
    {{QStringLiteral("editable"), true}},
    {{QStringLiteral("terminal"), true}},
};

QJsonObject someRule() {
  QJsonObject rule{{QStringLiteral("key"), pick(kRuleKeys)}, {QStringLiteral("command"), pick(kCommands)}};
  if (const QString when = pick(kRuleWhens); !when.isEmpty()) rule.insert(QStringLiteral("when"), when);
  return rule;
}

// A binding in force, and the user's rule it came from (none for a default).
struct Bound {
  keybindings::Binding binding;
  std::optional<QJsonObject> rule;
  QString key() const { return keybindings::keyText(binding.shortcut); }
  QString when() const { return keybindings::whenText(binding.when); }
};

// The web's merge, as its settings logic reads: the user's rules that parse
// and name a command, over the defaults of every command they do not bind.
QList<Bound> effective(const QJsonArray& rules) {
  QList<Bound> custom;
  for (const QJsonValue& value : rules) {
    const auto rule = keybindings::Rule::fromJson(value);
    if (!rule || !keybindings::isCommand(rule->command)) continue;
    if (auto binding = keybindings::compile(*rule)) custom.append({*binding, value.toObject()});
  }
  QList<Bound> bound;
  for (const keybindings::Binding& binding : keybindings::defaultBindings()) {
    if (std::none_of(custom.cbegin(), custom.cend(), [&](const Bound& mine) { return mine.binding.command == binding.command; })) {
      bound.append({binding, std::nullopt});
    }
  }
  return bound + custom;
}

// The rule the MC stores for a row: the user's own, else the default's text.
QJsonObject stored(const Bound& bound) {
  if (bound.rule) return *bound.rule;
  QJsonObject rule{{QStringLiteral("command"), bound.binding.command}, {QStringLiteral("key"), bound.key()}};
  if (!bound.when().isEmpty()) rule.insert(QStringLiteral("when"), bound.when());
  return rule;
}

struct Op {
  QString method;
  QJsonObject payload;
  bool refused = false;
};

void showValue(const Op& op, std::ostream& os) {
  os << op.method.toStdString() << (op.refused ? " (refused) " : " ");
  showValue(op.payload, os);
}

// keybindings.ex's upsert and remove.
QJsonArray applied(const QJsonArray& rules, const Op& op) {
  if (op.refused) return rules;
  QJsonObject rule = op.payload;
  const QJsonObject replace = rule.take(QStringLiteral("replace")).toObject();
  QJsonArray next;
  for (const QJsonValue& value : rules) {
    if (value.toObject() != rule && (op.method == QLatin1String("hal-c2.removeKeybinding") || value.toObject() != replace)) {
      next.append(value);
    }
  }
  if (op.method == QLatin1String("hal-c2.upsertKeybinding")) next.append(rule);
  while (next.size() > 256) next.removeFirst();
  return next;
}

struct Model {
  // What the MC's keybindings.json holds, and the client was last pushed.
  QJsonArray rules;
  // Calls the MC has not answered yet, oldest first.
  QList<Op> pending;
  bool holding = false;
  bool mac = false;
  bool picker = false;
  bool palette = false;

  QList<Bound> bound() const { return effective(rules); }
  void call(const Op& op) {
    if (holding) {
      pending.append(op);
    } else {
      rules = applied(rules, op);
    }
  }
};

// Whether `target` is still in force: a shrunk run may have dropped what made it.
bool holds(const Model& model, const Bound& target) {
  const QList<Bound> bound = model.bound();
  return std::any_of(bound.cbegin(), bound.cend(), [&target](const Bound& entry) {
    return entry.binding.command == target.binding.command && entry.key() == target.key() &&
           entry.when() == target.when() && entry.rule == target.rule;
  });
}

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  QJsonArray rules;
  // Whether each call on its way is refused, in the order they reach the MC.
  QList<bool> refusals;
  ShellBridge bridge;
  NativeShell native{&bridge};
  KeybindingController* keys = nullptr;
  // What each change signal last showed, and how many fired for nothing.
  QVariantList rows;
  int count = 0;
  QVariantList shortcuts;
  bool saving = false;
  QStringList idleSignals;

  Shell() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")) != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("keybindingRules"), rules},
                                                      {QStringLiteral("settings"), QJsonObject()}}}});
      mc.send({{QStringLiteral("t"), QStringLiteral("config.themes")}, {QStringLiteral("id"), id}, {QStringLiteral("themes"), QJsonArray()}});
    });
    for (const QString& method : {QStringLiteral("hal-c2.upsertKeybinding"), QStringLiteral("hal-c2.removeKeybinding")}) {
      mc.onRpc(method, [this, method](const FakeMc::Rpc& rpc) {
        const bool refused = !refusals.isEmpty() && refusals.takeFirst();
        auto answer = [this, method, rpc, refused] {
          if (refused) {
            mc.refuse(rpc, QStringLiteral("Read-only file system"));
            return;
          }
          rules = applied(rules, {method, rpc.payload});
          mc.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
          push();
        };
        if (mc.holding(QStringLiteral("keys"))) {
          mc.defer(answer);
        } else {
          answer();
        }
      });
    }
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!halc2::prop::until([this] { return native.isActive(); })) qFatal("the shell did not start");
    keys = native.controller<KeybindingController>();
    rows = keys->bindings();
    count = keys->customCount();
    shortcuts = keys->shortcuts();
    QObject::connect(keys, &KeybindingController::bindingsChanged, keys, [this] {
      if (keys->bindings() == rows && keys->customCount() == count) idleSignals.append(QStringLiteral("bindingsChanged"));
      rows = keys->bindings();
      count = keys->customCount();
    });
    QObject::connect(keys, &KeybindingController::shortcutsChanged, keys, [this] {
      if (keys->shortcuts() == shortcuts) idleSignals.append(QStringLiteral("shortcutsChanged"));
      shortcuts = keys->shortcuts();
    });
    QObject::connect(keys, &KeybindingController::savingChanged, keys, [this] {
      if (keys->saving() == saving) idleSignals.append(QStringLiteral("savingChanged"));
      saving = keys->saving();
    });
  }

  void push() {
    for (const int id : mc.subscribers(QStringLiteral("config"))) {
      if (mc.shapeOf(id).value(QLatin1String("environment")) != mc.environmentId) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("config.keybindings")}, {QStringLiteral("id"), id}, {QStringLiteral("rules"), rules}});
    }
  }

  CommandPaletteController* palette() { return native.controller<CommandPaletteController>(); }

  // A round trip: every call made so far has reached the MC, and whatever it
  // answered has been read.
  void sync() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(halc2::prop::until([&done] { return done; }));
  }

  // Back to no rules of the user's, nothing on its way.
  void reset() {
    mc.answerHeld();
    refusals.clear();
    rules = {};
    push();
    keys->setMac(false);
    keys->setModelPickerOpen(false);
    if (palette()->isOpen()) palette()->toggle();
    sync();
    idleSignals.clear();
  }

  // The row of `bound` among the controller's.
  QVariantMap row(const Bound& bound) const {
    QVariantMap found;
    for (const QVariant& value : keys->bindings()) {
      const QVariantMap row = value.toMap();
      if (row.value(QStringLiteral("command")) != bound.binding.command || row.value(QStringLiteral("key")) != bound.key() ||
          row.value(QStringLiteral("when")) != bound.when()) {
        continue;
      }
      // Two rules may read alike; the row says which it stands for.
      if (bound.rule && QJsonObject::fromVariantMap(row.value(QStringLiteral("rule")).toMap()) != *bound.rule) continue;
      if (found.isEmpty()) found = row;
    }
    return found;
  }
};

keybindings::Context context(const Model& model, const QVariantMap& focus) {
  return {
      {QStringLiteral("modelPickerOpen"), model.picker},
      {QStringLiteral("terminalFocus"), focus.value(QStringLiteral("terminal")).toBool()},
      {QStringLiteral("composerFocus"), focus.value(QStringLiteral("composer")).toBool()},
      {QStringLiteral("editableFocus"), focus.value(QStringLiteral("editable")).toBool()},
      {QStringLiteral("isDesktop"), true},
  };
}

// The model's keymap, each binding's sequence worked out once.
struct Keymap {
  const Model& model;
  QList<Bound> bound = model.bound();
  QStringList sequences = [this] {
    QStringList list;
    for (const Bound& entry : bound) list.append(keybindings::sequence(entry.binding.shortcut, model.mac));
    return list;
  }();
  QList<std::pair<QString, QString>> menu = [this] {
    QList<std::pair<QString, QString>> list;
    for (const auto& [key, command] : kMenuKeys) {
      list.append({keybindings::sequence(*keybindings::parseShortcut(key), model.mac), command});
    }
    return list;
  }();

  // Every sequence bound, once, in the order first bound.
  QStringList all() const {
    QStringList list;
    for (const QString& sequence : sequences) {
      if (!sequence.isEmpty() && !list.contains(sequence)) list.append(sequence);
    }
    for (const auto& [sequence, command] : menu) {
      if (!sequence.isEmpty() && !list.contains(sequence)) list.append(sequence);
    }
    return list;
  }

  // The newest binding on `sequence` whose condition holds, then the menu's; an
  // open palette keeps every key but its own and the window's.
  QString resolved(const QString& sequence, const QVariantMap& focus) const {
    const QString command = pressed(sequence, focus);
    return model.palette && !KeybindingController::kOverPalette.contains(command) ? QString() : command;
  }
  QString pressed(const QString& sequence, const QVariantMap& focus) const {
    const keybindings::Context now = context(model, focus);
    for (qsizetype index = bound.size() - 1; index >= 0; --index) {
      if (sequences.at(index) == sequence && keybindings::evaluate(bound.at(index).binding.when, now)) {
        return bound.at(index).binding.command;
      }
    }
    for (const auto& [menuSequence, command] : menu) {
      if (menuSequence == sequence) return command;
    }
    return {};
  }
};

void check(const Model& model, Shell& shell) {
  shell.sync();
  const Keymap keymap{model};
  const QList<Bound>& bound = keymap.bound;
  RC_ASSERT(shell.keys->saving() == !model.pending.isEmpty());
  RC_ASSERT(shell.keys->customCount() == model.rules.size());

  QStringList expectedRows;
  for (const Bound& entry : bound) {
    expectedRows.append(entry.binding.command + QLatin1Char('|') + entry.key() + QLatin1Char('|') + entry.when());
  }
  QStringList rows;
  for (const QVariant& value : shell.keys->bindings()) {
    const QVariantMap row = value.toMap();
    rows.append(row.value(QStringLiteral("command")).toString() + QLatin1Char('|') + row.value(QStringLiteral("key")).toString() +
                QLatin1Char('|') + row.value(QStringLiteral("when")).toString());
  }
  expectedRows.sort();
  rows.sort();
  RC_ASSERT(rows == expectedRows);

  const auto native = [&shell](const QString& command) {
    return shell.keys->commands()->contains(command) ||
           (command.startsWith(QLatin1String("script.")) && command.endsWith(QLatin1String(".run")));
  };
  QVariantList shortcuts;
  const QStringList all = keymap.all();
  for (const QString& sequence : all) {
    shortcuts.append(QVariantMap{
        {QStringLiteral("sequence"), sequence},
        {QStringLiteral("autoRepeat"), keymap.resolved(sequence, kFocuses.at(0)) != KeybindingController::kAppearanceCycle},
        {QStringLiteral("chrome"), native(keymap.resolved(sequence, kFocuses.at(0)))},
        {QStringLiteral("composer"), native(keymap.resolved(sequence, kFocuses.at(1)))},
        {QStringLiteral("editable"), native(keymap.resolved(sequence, kFocuses.at(2)))},
        {QStringLiteral("terminal"), native(keymap.resolved(sequence, kFocuses.at(3)))},
    });
  }
  RC_ASSERT(shell.keys->shortcuts() == shortcuts);
  for (const QString& sequence : all + QStringList{QStringLiteral("Ctrl+Q"), QStringLiteral("Meta+K")}) {
    for (const QVariantMap& focus : kFocuses) {
      RC_ASSERT(shell.keys->resolve(sequence, focus) == keymap.resolved(sequence, focus));
    }
  }

  // Every signal fired for a change, and every change fired its signal.
  RC_ASSERT(shell.idleSignals == QStringList());
  RC_ASSERT(shell.rows == shell.keys->bindings());
  RC_ASSERT(shell.count == shell.keys->customCount());
  RC_ASSERT(shell.shortcuts == shell.keys->shortcuts());
  RC_ASSERT(shell.saving == shell.keys->saving());
}

using Command = rc::state::Command<Model, Shell>;

// The MC's file changes under the client (edited by hand, or by another one).
struct Push : Command {
  QJsonArray rules;
  explicit Push(const Model&) {
    for (int count = *rc::gen::inRange(0, 4); count > 0; --count) rules.append(someRule());
  }
  void apply(Model& model) const override { model.rules = rules; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.rules = rules;
    shell.push();
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "Push(";
    showValue(rules, os);
    os << ")";
  }
};

// A binding in force, by its place among the model's.
std::optional<Bound> someBound(const Model& model, bool userOnly) {
  QList<Bound> bound = model.bound();
  if (userOnly) bound.removeIf([](const Bound& entry) { return !entry.rule; });
  if (bound.isEmpty()) return std::nullopt;
  // The user's rows mostly, which are the ones edited.
  const QList<Bound> mine = [&bound] {
    QList<Bound> list = bound;
    list.removeIf([](const Bound& entry) { return !entry.rule; });
    return list;
  }();
  return pick(!mine.isEmpty() && *rc::gen::weightedElement<bool>({{3, true}, {1, false}}) ? mine : bound);
}

// Settings → Keybindings: a new binding, or a row's key and condition edited.
struct Save : Command {
  QString command = pick(kCommands);
  QString key = pick(kRuleKeys);
  QString when = pick(kRuleWhens);
  std::optional<Bound> replacing;
  bool refused = *rc::gen::weightedElement<bool>({{5, false}, {1, true}});

  explicit Save(const Model& model) {
    if (*rc::gen::arbitrary<bool>()) replacing = someBound(model, false);
  }
  void checkPreconditions(const Model& model) const override {
    const bool valid = !replacing || holds(model, *replacing);
    RC_PRE(valid); }
  Op op() const {
    QJsonObject payload{{QStringLiteral("command"), command}, {QStringLiteral("key"), key.trimmed()}};
    if (!when.trimmed().isEmpty()) payload.insert(QStringLiteral("when"), when.trimmed());
    if (replacing) payload.insert(QStringLiteral("replace"), stored(*replacing));
    return {QStringLiteral("hal-c2.upsertKeybinding"), payload, refused};
  }
  void apply(Model& model) const override { model.call(op()); }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    QVariantMap row;
    if (replacing) {
      row = shell.row(*replacing);
      RC_ASSERT(!row.isEmpty());
    }
    shell.refusals.append(refused);
    shell.keys->save(command, key, when, row);
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "Save(";
    showValue(op(), os);
    os << ")";
  }
};

// A row's remove or reset button.
struct RowAction : Command {
  std::optional<Bound> target;
  bool reset = *rc::gen::arbitrary<bool>();
  bool refused = *rc::gen::weightedElement<bool>({{5, false}, {1, true}});

  explicit RowAction(const Model& model) : target(someBound(model, false)) { RC_PRE(target.has_value()); }
  void checkPreconditions(const Model& model) const override {
    const bool valid = target && holds(model, *target);
    RC_PRE(valid);
  }

  // What the row asks of the MC, if anything: a reset puts back the command's
  // default with the same condition, else its first.
  std::optional<Op> op() const {
    if (!reset) return Op{QStringLiteral("hal-c2.removeKeybinding"), stored(*target), refused};
    const keybindings::Binding* standard = nullptr;
    const keybindings::Binding* sameWhen = nullptr;
    const keybindings::Binding* fallback = nullptr;
    for (const keybindings::Binding& entry : keybindings::defaultBindings()) {
      if (entry.command != target->binding.command) continue;
      if (!fallback) fallback = &entry;
      if (keybindings::whenText(entry.when) != target->when()) continue;
      if (!sameWhen) sameWhen = &entry;
      if (keybindings::keyText(entry.shortcut) == target->key()) {
        standard = &entry;
        break;
      }
    }
    if (!standard) standard = sameWhen ? sameWhen : fallback;
    if (!standard) return std::nullopt;
    QJsonObject payload{{QStringLiteral("command"), target->binding.command},
                        {QStringLiteral("key"), keybindings::keyText(standard->shortcut)},
                        {QStringLiteral("replace"), stored(*target)}};
    if (standard->when) payload.insert(QStringLiteral("when"), keybindings::whenText(standard->when));
    return Op{QStringLiteral("hal-c2.upsertKeybinding"), payload, refused};
  }
  void apply(Model& model) const override {
    if (const auto call = op()) model.call(*call);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    const QVariantMap row = shell.row(*target);
    RC_ASSERT(!row.isEmpty());
    if (op()) shell.refusals.append(refused);
    if (reset) {
      shell.keys->reset(row);
    } else {
      shell.keys->remove(row);
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << (reset ? "Reset(" : "Remove(") << target->binding.command.toStdString() << " " << target->key().toStdString()
       << " when " << target->when().toStdString() << ") -> ";
    if (const auto call = op()) {
      showValue(*call, os);
    } else {
      os << "nothing";
    }
  }
};

// The MC goes slow: calls wait for Answer.
struct Hold : Command {
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.hold(QStringLiteral("keys"));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

struct Answer : Command {
  void apply(Model& model) const override {
    for (const Op& op : std::as_const(model.pending)) model.rules = applied(model.rules, op);
    model.pending.clear();
    model.holding = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.answerHeld();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Answer"; }
};

struct SetMac : Command {
  bool mac = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.mac = mac; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.keys->setMac(mac);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetMac(" << mac << ")"; }
};

struct SetPicker : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.picker = open; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.keys->setModelPickerOpen(open);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetPicker(" << open << ")"; }
};

struct SetPalette : Command {
  bool open = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.palette = open; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (shell.palette()->isOpen() != open) shell.palette()->toggle();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "SetPalette(" << open << ")"; }
};

}  // namespace

class KeysKeybindingsProp : public QObject {
  Q_OBJECT

private slots:
  void keyTextRoundTrips() {
    QVERIFY(rc::check("a key's text parses back to the key", [] {
      const Shortcut shortcut = someShortcut();
      const auto parsed = keybindings::parseShortcut(keybindings::keyText(shortcut));
      RC_ASSERT(parsed.has_value());
      RC_ASSERT(*parsed == shortcut);
    }));
  }

  void spellingsParseAlike() {
    QVERIFY(rc::check("every spelling of a key parses to it, and prints the one way", [] {
      const Shortcut shortcut = someShortcut();
      const QString text = spelling(shortcut);
      const auto parsed = keybindings::parseShortcut(text);
      RC_ASSERT(parsed.has_value());
      RC_ASSERT(*parsed == shortcut);
      RC_ASSERT(keybindings::keyText(*keybindings::parseShortcut(keybindings::keyText(*parsed))) == keybindings::keyText(shortcut));
    }));
  }

  void conditionTextRoundTrips() {
    QVERIFY(rc::check("a condition's text parses back to the same condition", [] {
      const keybindings::WhenPtr when = someWhen(*rc::gen::inRange(0, 5));
      const QString text = keybindings::whenText(when);
      const keybindings::WhenPtr parsed = keybindings::parseWhen(text);
      RC_ASSERT(parsed != nullptr);
      RC_ASSERT(sameMeaning(parsed, when));
      RC_ASSERT(keybindings::whenText(parsed) == text);
    }));
  }

  void sequencesAreQtsAndDistinct() {
    QVERIFY(rc::check("a shortcut registers one Qt key, which no other shortcut shares", [] {
      const bool mac = *rc::gen::arbitrary<bool>();
      const Shortcut first = someShortcut();
      const Shortcut second = someShortcut();
      const QString sequence = keybindings::sequence(first, mac);
      if (!sequence.isEmpty()) {
        const Pressed keys = pressed(first, mac);
        RC_ASSERT(keys.meta || keys.ctrl || keys.alt);
        const QKeySequence parsed = QKeySequence::fromString(sequence, QKeySequence::PortableText);
        RC_ASSERT(parsed.count() == 1);
        RC_ASSERT(parsed[0].key() != Qt::Key_unknown);
        // Qt's portable Ctrl is Command on macOS, and its Meta is Control.
        Qt::KeyboardModifiers modifiers;
        if (mac ? keys.meta : keys.ctrl) modifiers |= Qt::ControlModifier;
        if (mac ? keys.ctrl : keys.meta) modifiers |= Qt::MetaModifier;
        if (keys.alt) modifiers |= Qt::AltModifier;
        if (keys.shift) modifiers |= Qt::ShiftModifier;
        RC_ASSERT(parsed[0].keyboardModifiers() == modifiers);
      }
      if (!sequence.isEmpty() && sequence == keybindings::sequence(second, mac)) {
        RC_ASSERT(pressed(first, mac) == pressed(second, mac));
      }
    }));
  }

  void recordedKeysFireTheirShortcut() {
    QVERIFY(rc::check("a recorded key is canonical, and its shortcut is the key pressed", [] {
      const bool mac = *rc::gen::arbitrary<bool>();
      const int key = pick(QList<int>{Qt::Key_A, Qt::Key_K, Qt::Key_Z, Qt::Key_0, Qt::Key_7, Qt::Key_BracketLeft,
                                      Qt::Key_Comma, Qt::Key_Minus, Qt::Key_Equal, Qt::Key_Slash, Qt::Key_Space,
                                      Qt::Key_Up, Qt::Key_Return, Qt::Key_Tab, Qt::Key_F5, Qt::Key_Delete,
                                      Qt::Key_Home, Qt::Key_PageUp, Qt::Key_Backspace});
      Qt::KeyboardModifiers modifiers;
      for (const Qt::KeyboardModifier modifier : {Qt::ControlModifier, Qt::AltModifier, Qt::ShiftModifier, Qt::MetaModifier}) {
        if (*rc::gen::arbitrary<bool>()) modifiers |= modifier;
      }
      // Shift turns a digit or a symbol into another key, which Qt reports.
      const bool printable = key > Qt::Key_Space && key <= Qt::Key_AsciiTilde;
      RC_PRE(!(modifiers & Qt::ShiftModifier) || !printable || (key >= Qt::Key_A && key <= Qt::Key_Z));
      const QString recorded = keybindings::recordedKey(key, int(modifiers), mac);
      RC_PRE(!recorded.isEmpty());
      const auto parsed = keybindings::parseShortcut(recorded);
      RC_ASSERT(parsed.has_value());
      RC_ASSERT(keybindings::keyText(*parsed) == recorded);
      const QString sequence = keybindings::sequence(*parsed, mac);
      if (modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) {
        RC_ASSERT(QKeySequence::fromString(sequence, QKeySequence::PortableText) ==
                  QKeySequence(QKeyCombination(modifiers, Qt::Key(key))));
      } else {
        RC_ASSERT(sequence.isEmpty());
      }
    }));
  }

  void controller() {
    Shell shell;
    QVERIFY(rc::check("the controller's rows, shortcuts and keys are the model's", [&shell] {
      shell.reset();
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<Push, Save, Save, RowAction, RowAction, Hold, Answer, SetMac,
                                                         SetPicker, SetPalette>());
      // Nothing is left waiting for the next case.
      shell.mc.answerHeld();
    }));
  }
};

HAL_C2_PROP_MAIN(KeysKeybindingsProp)
#include "tst_KeysKeybindingsProp.moc"
