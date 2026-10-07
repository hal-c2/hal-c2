#include "Keybindings.h"

#include <QRegularExpression>
#include <QSet>

namespace keybindings {

namespace {

// packages/contracts MAX_KEYBINDINGS_COUNT and MAX_WHEN_EXPRESSION_DEPTH.
constexpr int kMaxBindings = 256;
constexpr int kMaxWhenDepth = 64;

Rule rule(const QString& key, const QString& command, const QString& when = {}) {
  return {key, command, when.isEmpty() ? std::nullopt : std::optional<QString>(when)};
}

// DEFAULT_KEYBINDINGS in packages/shared/src/keybindings.ts, in its order.
QList<Rule> buildDefaults() {
  const QString notTerminal = QStringLiteral("!terminalFocus");
  const QString terminal = QStringLiteral("terminalFocus");
  const QString preview = QStringLiteral("previewFocus");
  QList<Rule> rules{
      rule(QStringLiteral("mod+b"), QStringLiteral("sidebar.toggle")),
      rule(QStringLiteral("mod+["), QStringLiteral("navigation.back"), notTerminal),
      rule(QStringLiteral("mod+]"), QStringLiteral("navigation.forward"), notTerminal),
      rule(QStringLiteral("mod+alt+]"), QStringLiteral("tabs.next"), notTerminal),
      rule(QStringLiteral("mod+alt+["), QStringLiteral("tabs.previous"), notTerminal),
      rule(QStringLiteral("mod+j"), QStringLiteral("terminal.toggle")),
      rule(QStringLiteral("mod+alt+b"), QStringLiteral("rightPanel.toggle")),
      rule(QStringLiteral("mod+d"), QStringLiteral("terminal.split"), terminal),
      rule(QStringLiteral("mod+shift+d"), QStringLiteral("terminal.splitVertical"), terminal),
      rule(QStringLiteral("mod+n"), QStringLiteral("terminal.new"), terminal),
      rule(QStringLiteral("mod+w"), QStringLiteral("terminal.close"), terminal),
      rule(QStringLiteral("mod+w"), QStringLiteral("rightPanel.close"), notTerminal),
      rule(QStringLiteral("mod+d"), QStringLiteral("diff.toggle"), notTerminal),
      rule(QStringLiteral("mod+shift+j"), QStringLiteral("preview.toggle")),
      rule(QStringLiteral("mod+r"), QStringLiteral("preview.refresh"), preview),
      rule(QStringLiteral("mod+l"), QStringLiteral("preview.focusUrl"), preview),
      rule(QStringLiteral("mod+="), QStringLiteral("preview.zoomIn"), preview),
      rule(QStringLiteral("mod++"), QStringLiteral("preview.zoomIn"), preview),
      rule(QStringLiteral("mod+-"), QStringLiteral("preview.zoomOut"), preview),
      rule(QStringLiteral("mod+0"), QStringLiteral("preview.resetZoom"), preview),
      rule(QStringLiteral("mod+k"), QStringLiteral("commandPalette.toggle"), notTerminal),
      rule(QStringLiteral("mod+p"), QStringLiteral("filePicker.toggle"), notTerminal),
      rule(QStringLiteral("mod+shift+f"), QStringLiteral("projectSearch.toggle"), notTerminal),
      rule(QStringLiteral("mod+alt+a"), QStringLiteral("theme.select"), notTerminal),
      rule(QStringLiteral("mod+alt+shift+a"), QStringLiteral("appearance.cycle"), notTerminal),
      rule(QStringLiteral("mod+alt+shift+t"), QStringLiteral("themeEditor.toggle")),
      rule(QStringLiteral("mod+s"), QStringLiteral("composer.stash"), notTerminal),
      rule(QStringLiteral("mod+shift+enter"), QStringLiteral("thread.steerQueuedMessage"), notTerminal),
      rule(QStringLiteral("alt+arrowup"), QStringLiteral("thread.editQueuedMessage"), QStringLiteral("composerFocus")),
      rule(QStringLiteral("mod+enter"), QStringLiteral("composer.sendAlternate"),
           QStringLiteral("composerFocus && turnRunning")),
      rule(QStringLiteral("mod+alt+enter"), QStringLiteral("composer.sendBackground"),
           QStringLiteral("composerFocus && draftThreadRoute")),
      rule(QStringLiteral("mod+n"), QStringLiteral("chat.new"), notTerminal),
      rule(QStringLiteral("mod+shift+o"), QStringLiteral("chat.new"), notTerminal),
      rule(QStringLiteral("mod+shift+n"), QStringLiteral("chat.newLocal"), notTerminal),
      rule(QStringLiteral("mod+shift+m"), QStringLiteral("modelPicker.toggle"), notTerminal),
      rule(QStringLiteral("mod+shift+h"), QStringLiteral("composer.host"), notTerminal),
      rule(QStringLiteral("mod+shift+e"), QStringLiteral("composer.effort"), notTerminal),
      rule(QStringLiteral("mod+shift+a"), QStringLiteral("composer.mode"), notTerminal),
      rule(QStringLiteral("mod+shift+x"), QStringLiteral("composer.workspace"), notTerminal),
      rule(QStringLiteral("mod+shift+g"), QStringLiteral("composer.branch"), notTerminal),
      rule(QStringLiteral("mod+shift+l"), QStringLiteral("composer.previousWorktree"), notTerminal),
      rule(QStringLiteral("mod+shift+k"), QStringLiteral("pullRequest.copyNumber"), notTerminal),
      rule(QStringLiteral("mod+shift+arrowup"), QStringLiteral("modelPicker.previousProvider"),
           QStringLiteral("modelPickerOpen")),
      rule(QStringLiteral("mod+shift+arrowdown"), QStringLiteral("modelPicker.nextProvider"),
           QStringLiteral("modelPickerOpen")),
      rule(QStringLiteral("mod+o"), QStringLiteral("editor.openFavorite")),
      rule(QStringLiteral("mod+shift+["), QStringLiteral("thread.previous")),
      rule(QStringLiteral("mod+shift+]"), QStringLiteral("thread.next")),
      rule(QStringLiteral("mod+shift+c"), QStringLiteral("thread.copyReference"), notTerminal),
      rule(QStringLiteral("mod+shift+s"), QStringLiteral("thread.settle"), notTerminal),
      rule(QStringLiteral("mod+shift+p"), QStringLiteral("thread.pin"), notTerminal),
      rule(QStringLiteral("mod+z"), QStringLiteral("thread.undo"), QStringLiteral("!terminalFocus && !editableFocus")),
  };
  for (int n = 1; n <= 9; ++n) {
    rules.append(rule(QStringLiteral("mod+%1").arg(n), QStringLiteral("thread.jump.%1").arg(n),
                      QStringLiteral("isDesktop")));
  }
  for (int n = 1; n <= 9; ++n) {
    rules.append(rule(QStringLiteral("mod+%1").arg(n), QStringLiteral("modelPicker.jump.%1").arg(n),
                      QStringLiteral("modelPickerOpen && isDesktop")));
  }
  return rules;
}

QList<Binding> compileAll(const QList<Rule>& rules) {
  QList<Binding> bindings;
  for (const Rule& rule : rules) {
    if (auto binding = compile(rule)) bindings.append(std::move(*binding));
  }
  if (bindings.size() > kMaxBindings) bindings = bindings.mid(bindings.size() - kMaxBindings);
  return bindings;
}

// The `when` grammar: or := and ("||" and)*, and := unary ("&&" unary)*,
// unary := "!"* primary, primary := identifier | "(" or ")".
class WhenParser {
public:
  explicit WhenParser(const QString& expression) { m_ok = tokenize(expression); }

  WhenPtr parse() {
    if (!m_ok || m_tokens.isEmpty()) return nullptr;
    WhenPtr ast = parseOr(0);
    return ast && m_index == m_tokens.size() ? ast : nullptr;
  }

private:
  enum class Token { Identifier, Not, And, Or, Open, Close };

  bool tokenize(const QString& expression) {
    static const QRegularExpression identifier(QStringLiteral("^[A-Za-z_][A-Za-z0-9_.-]*"));
    qsizetype index = 0;
    while (index < expression.size()) {
      const QChar current = expression.at(index);
      if (current.isSpace()) {
        ++index;
      } else if (expression.mid(index, 2) == QLatin1String("&&")) {
        m_tokens.append({Token::And, {}});
        index += 2;
      } else if (expression.mid(index, 2) == QLatin1String("||")) {
        m_tokens.append({Token::Or, {}});
        index += 2;
      } else if (current == QLatin1Char('!')) {
        m_tokens.append({Token::Not, {}});
        ++index;
      } else if (current == QLatin1Char('(')) {
        m_tokens.append({Token::Open, {}});
        ++index;
      } else if (current == QLatin1Char(')')) {
        m_tokens.append({Token::Close, {}});
        ++index;
      } else {
        const QRegularExpressionMatch match = identifier.matchView(QStringView(expression).mid(index));
        if (!match.hasMatch()) return false;
        m_tokens.append({Token::Identifier, match.captured(0)});
        index += match.capturedLength(0);
      }
    }
    return true;
  }

  bool at(Token type) const { return m_index < m_tokens.size() && m_tokens.at(m_index).first == type; }

  WhenPtr parsePrimary(int depth) {
    if (depth > kMaxWhenDepth || m_index >= m_tokens.size()) return nullptr;
    if (at(Token::Identifier)) {
      return std::make_shared<When>(When{When::Kind::Identifier, m_tokens.at(m_index++).second, {}, {}});
    }
    if (!at(Token::Open)) return nullptr;
    ++m_index;
    WhenPtr inner = parseOr(depth + 1);
    if (!inner || !at(Token::Close)) return nullptr;
    ++m_index;
    return inner;
  }

  WhenPtr parseUnary(int depth) {
    int nots = 0;
    while (at(Token::Not)) {
      ++m_index;
      if (++nots > kMaxWhenDepth) return nullptr;
    }
    WhenPtr node = parsePrimary(depth);
    for (; node && nots > 0; --nots) node = std::make_shared<When>(When{When::Kind::Not, {}, node, {}});
    return node;
  }

  WhenPtr parseBinary(int depth, Token op, When::Kind kind) {
    WhenPtr left = kind == When::Kind::Or ? parseBinary(depth, Token::And, When::Kind::And) : parseUnary(depth);
    while (left && at(op)) {
      ++m_index;
      WhenPtr right = kind == When::Kind::Or ? parseBinary(depth, Token::And, When::Kind::And) : parseUnary(depth);
      if (!right) return nullptr;
      left = std::make_shared<When>(When{kind, {}, left, right});
    }
    return left;
  }

  WhenPtr parseOr(int depth) { return parseBinary(depth, Token::Or, When::Kind::Or); }

  bool m_ok = false;
  QList<std::pair<Token, QString>> m_tokens;
  qsizetype m_index = 0;
};

QString wrapped(const WhenPtr& when) {
  if (when->kind == When::Kind::Identifier || when->kind == When::Kind::Not) return whenText(when);
  return QLatin1Char('(') + whenText(when) + QLatin1Char(')');
}

// Web `event.key` names → portable QKeySequence names (shellKeybindings.ts).
QString qtKeyName(const QString& key) {
  static const QHash<QString, QString> names{
      {QStringLiteral(" "), QStringLiteral("Space")},     {QStringLiteral("arrowdown"), QStringLiteral("Down")},
      {QStringLiteral("arrowleft"), QStringLiteral("Left")}, {QStringLiteral("arrowright"), QStringLiteral("Right")},
      {QStringLiteral("arrowup"), QStringLiteral("Up")},     {QStringLiteral("backspace"), QStringLiteral("Backspace")},
      {QStringLiteral("delete"), QStringLiteral("Del")},     {QStringLiteral("end"), QStringLiteral("End")},
      {QStringLiteral("enter"), QStringLiteral("Return")},   {QStringLiteral("escape"), QStringLiteral("Esc")},
      {QStringLiteral("home"), QStringLiteral("Home")},      {QStringLiteral("insert"), QStringLiteral("Ins")},
      {QStringLiteral("pagedown"), QStringLiteral("PgDown")}, {QStringLiteral("pageup"), QStringLiteral("PgUp")},
      {QStringLiteral("tab"), QStringLiteral("Tab")},
  };
  if (const auto named = names.constFind(key); named != names.cend()) return *named;
  static const QRegularExpression function(QStringLiteral("^f([1-9]|1\\d|2[0-4])$"));
  if (function.match(key).hasMatch() || key.size() == 1) return key.toUpper();
  return {};
}

QString titleCase(const QString& segment) {
  static const QRegularExpression camel(QStringLiteral("([a-z0-9])([A-Z])"));
  static const QRegularExpression separators(QStringLiteral("[-_\\s]+"));
  QString spaced = segment;
  spaced.replace(camel, QStringLiteral("\\1 \\2"));
  QStringList words;
  for (const QString& part : spaced.split(separators, Qt::SkipEmptyParts)) {
    words.append(part.left(1).toUpper() + part.mid(1));
  }
  return words.join(QLatin1Char(' '));
}

}  // namespace

std::optional<Rule> Rule::fromJson(const QJsonValue& value) {
  const QJsonObject object = value.toObject();
  const QJsonValue key = object.value(QLatin1String("key"));
  const QJsonValue command = object.value(QLatin1String("command"));
  const QJsonValue when = object.value(QLatin1String("when"));
  if (!key.isString() || !command.isString() || !(when.isUndefined() || when.isNull() || when.isString())) {
    return std::nullopt;
  }
  return Rule{key.toString(), command.toString(), when.isString() ? std::optional(when.toString()) : std::nullopt};
}

QJsonObject Rule::toJson() const {
  QJsonObject object{{QStringLiteral("key"), key}, {QStringLiteral("command"), command}};
  if (when) object.insert(QStringLiteral("when"), *when);
  return object;
}

std::optional<Shortcut> parseShortcut(const QString& value) {
  QStringList tokens;
  for (const QString& token : value.toLower().split(QLatin1Char('+'))) tokens.append(token.trimmed());
  bool trailing = false;
  while (!tokens.isEmpty() && tokens.constLast().isEmpty()) {
    tokens.removeLast();
    trailing = true;
  }
  if (trailing) tokens.append(QStringLiteral("+"));
  if (tokens.isEmpty() || tokens.contains(QString())) return std::nullopt;

  Shortcut shortcut;
  bool haveKey = false;
  for (const QString& token : std::as_const(tokens)) {
    if (token == QLatin1String("cmd") || token == QLatin1String("meta")) {
      shortcut.meta = true;
    } else if (token == QLatin1String("ctrl") || token == QLatin1String("control")) {
      shortcut.ctrl = true;
    } else if (token == QLatin1String("shift")) {
      shortcut.shift = true;
    } else if (token == QLatin1String("alt") || token == QLatin1String("option")) {
      shortcut.alt = true;
    } else if (token == QLatin1String("mod")) {
      shortcut.mod = true;
    } else {
      if (haveKey) return std::nullopt;
      haveKey = true;
      shortcut.key = token == QLatin1String("space") ? QStringLiteral(" ")
                     : token == QLatin1String("esc") ? QStringLiteral("escape")
                                                     : token;
    }
  }
  if (!haveKey) return std::nullopt;
  return shortcut;
}

WhenPtr parseWhen(const QString& expression) {
  return WhenParser(expression).parse();
}

bool evaluate(const WhenPtr& when, const Context& context) {
  if (!when) return true;
  switch (when->kind) {
    case When::Kind::Identifier:
      if (when->name == QLatin1String("true")) return true;
      if (when->name == QLatin1String("false")) return false;
      return context.value(when->name, false);
    case When::Kind::Not:
      return !evaluate(when->left, context);
    case When::Kind::And:
      return evaluate(when->left, context) && evaluate(when->right, context);
    case When::Kind::Or:
      return evaluate(when->left, context) || evaluate(when->right, context);
  }
  return false;
}

std::optional<Binding> compile(const Rule& rule) {
  const auto shortcut = parseShortcut(rule.key);
  if (!shortcut) return std::nullopt;
  WhenPtr when;
  if (rule.when) {
    when = parseWhen(*rule.when);
    if (!when) return std::nullopt;
  }
  return Binding{rule.command, *shortcut, when};
}

const QStringList& commands() {
  static const QStringList list = [] {
    QStringList list{
        QStringLiteral("sidebar.toggle"), QStringLiteral("navigation.back"), QStringLiteral("navigation.forward"),
        QStringLiteral("tabs.next"), QStringLiteral("tabs.previous"),
        QStringLiteral("terminal.toggle"), QStringLiteral("terminal.split"), QStringLiteral("terminal.splitVertical"),
        QStringLiteral("terminal.new"), QStringLiteral("terminal.close"), QStringLiteral("rightPanel.toggle"),
        QStringLiteral("threadPanel.toggle"), QStringLiteral("rightPanel.toggleMaximized"),
        QStringLiteral("rightPanel.close"), QStringLiteral("pullRequest.copyNumber"), QStringLiteral("diff.toggle"),
        QStringLiteral("preview.toggle"), QStringLiteral("preview.refresh"), QStringLiteral("preview.focusUrl"),
        QStringLiteral("preview.zoomIn"), QStringLiteral("preview.zoomOut"), QStringLiteral("preview.resetZoom"),
        QStringLiteral("commandPalette.toggle"), QStringLiteral("filePicker.toggle"),
        QStringLiteral("projectSearch.toggle"), QStringLiteral("theme.select"), QStringLiteral("appearance.cycle"),
        QStringLiteral("themeEditor.toggle"), QStringLiteral("composer.stash"), QStringLiteral("composer.sendAlternate"),
        QStringLiteral("composer.sendBackground"), QStringLiteral("composer.host"), QStringLiteral("composer.effort"),
        QStringLiteral("composer.mode"), QStringLiteral("composer.workspace"),
        QStringLiteral("composer.previousWorktree"), QStringLiteral("composer.branch"), QStringLiteral("chat.new"),
        QStringLiteral("chat.newLocal"), QStringLiteral("editor.openFavorite"), QStringLiteral("modelPicker.toggle"),
        QStringLiteral("modelPicker.previousProvider"), QStringLiteral("modelPicker.nextProvider"),
    };
    for (int n = 1; n <= 9; ++n) list.append(QStringLiteral("modelPicker.jump.%1").arg(n));
    list.append({QStringLiteral("thread.stop"), QStringLiteral("thread.steerQueuedMessage"),
                 QStringLiteral("thread.editQueuedMessage"), QStringLiteral("thread.previous"),
                 QStringLiteral("thread.next"), QStringLiteral("thread.copyReference"), QStringLiteral("thread.settle"),
                 QStringLiteral("thread.pin"), QStringLiteral("thread.undo")});
    for (int n = 1; n <= 9; ++n) list.append(QStringLiteral("thread.jump.%1").arg(n));
    return list;
  }();
  return list;
}

bool isCommand(const QString& command) {
  static const QSet<QString> known(commands().cbegin(), commands().cend());
  // SCRIPT_RUN_COMMAND_PATTERN, with MAX_SCRIPT_ID_LENGTH.
  static const QRegularExpression script(QStringLiteral("^script\\.[a-z0-9][a-z0-9-]{0,23}\\.run$"));
  return known.contains(command) || script.match(command).hasMatch();
}

const QList<Rule>& defaults() {
  static const QList<Rule> rules = buildDefaults();
  return rules;
}

const QList<Binding>& defaultBindings() {
  static const QList<Binding> bindings = compileAll(defaults());
  return bindings;
}

QList<Binding> merge(const QJsonArray& userRules) {
  QList<Rule> rules;
  for (const QJsonValue& value : userRules) {
    if (auto rule = Rule::fromJson(value); rule && isCommand(rule->command)) rules.append(std::move(*rule));
  }
  const QList<Binding> custom = compileAll(rules);
  if (custom.isEmpty()) return defaultBindings();
  QSet<QString> overridden;
  for (const Binding& binding : custom) overridden.insert(binding.command);
  QList<Binding> merged;
  for (const Binding& binding : defaultBindings()) {
    if (!overridden.contains(binding.command)) merged.append(binding);
  }
  merged.append(custom);
  if (merged.size() > kMaxBindings) merged = merged.mid(merged.size() - kMaxBindings);
  return merged;
}

QString resolve(const QList<Binding>& bindings, const QString& keySequence, const Context& context, bool mac) {
  for (qsizetype index = bindings.size() - 1; index >= 0; --index) {
    const Binding& binding = bindings.at(index);
    if (evaluate(binding.when, context) && sequence(binding.shortcut, mac) == keySequence) return binding.command;
  }
  return {};
}

QString sequence(const Shortcut& shortcut, bool mac) {
  const bool meta = shortcut.meta || (shortcut.mod && mac);
  const bool ctrl = shortcut.ctrl || (shortcut.mod && !mac);
  if (!meta && !ctrl && !shortcut.alt) return {};
  const QString key = qtKeyName(shortcut.key);
  if (key.isEmpty()) return {};
  // Qt's portable names are swapped on macOS: "Ctrl" is Command, "Meta" is Control.
  QStringList parts;
  if (mac ? meta : ctrl) parts.append(QStringLiteral("Ctrl"));
  if (mac ? ctrl : meta) parts.append(QStringLiteral("Meta"));
  if (shortcut.alt) parts.append(QStringLiteral("Alt"));
  if (shortcut.shift) parts.append(QStringLiteral("Shift"));
  parts.append(key);
  return parts.join(QLatin1Char('+'));
}

QString label(const Shortcut& shortcut, bool mac) {
  QString key;
  if (shortcut.key == QLatin1String(" ")) key = QStringLiteral("Space");
  else if (shortcut.key.size() == 1) key = shortcut.key.toUpper();
  else if (shortcut.key == QLatin1String("escape")) key = QStringLiteral("Esc");
  else if (shortcut.key.startsWith(QLatin1String("arrow"))) key = titleCase(shortcut.key.mid(5));
  else key = shortcut.key.left(1).toUpper() + shortcut.key.mid(1);
  const bool meta = shortcut.meta || (shortcut.mod && mac);
  const bool ctrl = shortcut.ctrl || (shortcut.mod && !mac);
  if (mac) {
    return (ctrl ? QStringLiteral("⌃") : QString()) + (shortcut.alt ? QStringLiteral("⌥") : QString()) +
           (shortcut.shift ? QStringLiteral("⇧") : QString()) + (meta ? QStringLiteral("⌘") : QString()) +
           key;
  }
  QStringList parts;
  if (ctrl) parts.append(QStringLiteral("Ctrl"));
  if (shortcut.alt) parts.append(QStringLiteral("Alt"));
  if (shortcut.shift) parts.append(QStringLiteral("Shift"));
  if (meta) parts.append(QStringLiteral("Meta"));
  parts.append(key);
  return parts.join(QLatin1Char('+'));
}

QString keyText(const Shortcut& shortcut) {
  QStringList parts;
  if (shortcut.mod) parts.append(QStringLiteral("mod"));
  if (shortcut.meta) parts.append(QStringLiteral("meta"));
  if (shortcut.ctrl) parts.append(QStringLiteral("ctrl"));
  if (shortcut.alt) parts.append(QStringLiteral("alt"));
  if (shortcut.shift) parts.append(QStringLiteral("shift"));
  parts.append(shortcut.key == QLatin1String(" ")        ? QStringLiteral("space")
               : shortcut.key == QLatin1String("escape") ? QStringLiteral("esc")
                                                         : shortcut.key);
  return parts.join(QLatin1Char('+'));
}

QString whenText(const WhenPtr& when) {
  if (!when) return {};
  switch (when->kind) {
    case When::Kind::Identifier:
      return when->name;
    case When::Kind::Not:
      return QLatin1Char('!') + wrapped(when->left);
    case When::Kind::And:
      return wrapped(when->left) + QStringLiteral(" && ") + wrapped(when->right);
    case When::Kind::Or:
      return wrapped(when->left) + QStringLiteral(" || ") + wrapped(when->right);
  }
  return {};
}

QString commandLabel(const QString& command) {
  static const QHash<QString, QString> special{
      {QStringLiteral("composer.sendAlternate"), QStringLiteral("Composer: Opposite Queue or Steer Action")},
      {QStringLiteral("composer.sendBackground"), QStringLiteral("Composer: Start in Background")},
      {QStringLiteral("thread.steerQueuedMessage"), QStringLiteral("Queue: Send First Queued Message as Steer")},
      {QStringLiteral("thread.editQueuedMessage"), QStringLiteral("Queue: Edit Last Queued Message")},
      {QStringLiteral("thread.copyReference"), QStringLiteral("Pull Request: Copy Link or Thread ID")},
  };
  if (const auto label = special.constFind(command); label != special.cend()) return *label;
  if (command.startsWith(QLatin1String("script.")) && command.endsWith(QLatin1String(".run"))) {
    return QStringLiteral("Run Script: ") + titleCase(command.mid(7, command.size() - 11));
  }
  QStringList segments;
  for (const QString& segment : command.split(QLatin1Char('.'))) segments.append(titleCase(segment));
  return segments.join(QStringLiteral(": "));
}

QString recordedKey(int key, int modifiers, bool mac) {
  // Qt reports the shifted character; the web records the physical key.
  static const QHash<QChar, QChar> unshifted{
      {u'{', u'['}, {u'}', u']'}, {u'<', u','}, {u'>', u'.'}, {u'?', u'/'}, {u':', u';'}, {u'"', u'\''},
      {u'|', u'\\'}, {u'~', u'`'}, {u'!', u'1'}, {u'@', u'2'}, {u'#', u'3'}, {u'$', u'4'}, {u'%', u'5'},
      {u'^', u'6'}, {u'&', u'7'}, {u'*', u'8'}, {u'(', u'9'}, {u')', u'0'}, {u'_', u'-'}, {u'+', u'='},
  };
  static const QHash<int, QString> named{
      {Qt::Key_Space, QStringLiteral("space")},       {Qt::Key_Up, QStringLiteral("arrowup")},
      {Qt::Key_Down, QStringLiteral("arrowdown")},    {Qt::Key_Left, QStringLiteral("arrowleft")},
      {Qt::Key_Right, QStringLiteral("arrowright")},  {Qt::Key_Return, QStringLiteral("enter")},
      {Qt::Key_Enter, QStringLiteral("enter")},       {Qt::Key_Tab, QStringLiteral("tab")},
      {Qt::Key_Backtab, QStringLiteral("tab")},       {Qt::Key_Backspace, QStringLiteral("backspace")},
      {Qt::Key_Delete, QStringLiteral("delete")},     {Qt::Key_Home, QStringLiteral("home")},
      {Qt::Key_End, QStringLiteral("end")},           {Qt::Key_PageUp, QStringLiteral("pageup")},
      {Qt::Key_PageDown, QStringLiteral("pagedown")},
  };
  QString token;
  if (const auto name = named.constFind(key); name != named.cend()) {
    token = *name;
  } else if (key >= Qt::Key_F1 && key <= Qt::Key_F24) {
    token = QStringLiteral("f%1").arg(key - Qt::Key_F1 + 1);
  } else if (key > Qt::Key_Space && key <= Qt::Key_AsciiTilde) {
    const QChar character = QChar(key).toLower();
    token = unshifted.value(character, character);
  } else {
    return {};
  }
  // Qt's Control is Command on macOS, and its Meta is Control.
  QStringList parts;
  if (modifiers & Qt::ControlModifier) parts.append(QStringLiteral("mod"));
  if (modifiers & Qt::MetaModifier) parts.append(mac ? QStringLiteral("ctrl") : QStringLiteral("meta"));
  if (modifiers & Qt::AltModifier) parts.append(QStringLiteral("alt"));
  if (modifiers & Qt::ShiftModifier) parts.append(QStringLiteral("shift"));
  if (parts.isEmpty()) return {};
  parts.append(token);
  return parts.join(QLatin1Char('+'));
}

}  // namespace keybindings
