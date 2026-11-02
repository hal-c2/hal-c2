#include "CommandLabel.h"

#include <QHash>
#include <QList>
#include <QRegularExpression>
#include <QSet>
#include <QStringList>

#include <optional>

// A port of client-runtime's work-log/commandLabel.ts. It reads the command as
// a shell would only as far as naming its program needs: quotes, escapes,
// substitutions, comments, heredocs and top-level separators. Anything it
// cannot read with confidence names no program.
namespace timeline {
namespace {

enum class Context { Exec, Shell };
enum class Wrapper { None, Env, Sudo };

constexpr int maxCommandSegments = 64;

using Names = QSet<QString>;

const Names& shellPrograms() {
  static const Names names{"sh", "bash", "zsh", "dash", "ash", "ksh", "fish"};
  return names;
}
const Names& windowsShellPrograms() {
  static const Names names{"cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe"};
  return names;
}
const Names& shellOptionsWithValue() {
  static const Names names{"-o", "-O", "--rcfile", "--init-file"};
  return names;
}
const Names& shellCommandWrappers() {
  static const Names names{"builtin", "command", "exec"};
  return names;
}
const Names& shellPrecommandModifiers() {
  static const Names names{"nocorrect", "noglob", "time"};
  return names;
}
const Names& powerShellSetupPrograms() {
  static const Names names{"pop-location", "push-location", "set-location"};
  return names;
}
const Names& powerShellFlags() {
  static const Names names{"-mta", "-nologo", "-noninteractive", "-noprofile", "-sta"};
  return names;
}
const Names& powerShellOptionsWithValue() {
  static const Names names{"-configurationname", "-executionpolicy", "-inputformat", "-outputformat",
                           "-version", "-windowstyle", "-workingdirectory"};
  return names;
}
const Names& startProcessFlags() {
  static const Names names{"-confirm", "-debug", "-loaduserprofile", "-nonewwindow", "-passthru",
                           "-usenewenvironment", "-verbose", "-wait", "-whatif"};
  return names;
}
const Names& startProcessOptionsWithValue() {
  static const Names names{"-argumentlist", "-credential", "-environment", "-erroraction", "-errorvariable",
                           "-informationaction", "-informationvariable", "-outbuffer", "-outvariable",
                           "-pipelinevariable", "-progressaction", "-redirectstandarderror",
                           "-redirectstandardinput", "-redirectstandardoutput", "-verb", "-warningaction",
                           "-warningvariable", "-windowstyle", "-workingdirectory"};
  return names;
}
const Names& skippableSudoProbes() {
  static const Names names{"[", "[[", "test", "true"};
  return names;
}
const QString nonProgramPrefix = QStringLiteral("<>(){}[];|&$`#!%@:");
const QString nonProgramSuffix = QStringLiteral("){]}`");

// Shell syntax or shell-local control flow, not a useful program name:
// "command" is less misleading than "Ran if", "Ran [" or "Ran function".
const Names& nonDescriptivePrograms() {
  static const Names names{
      "!",       "#",        ".",        ":",       "[",       "[[",      "alias",    "and",     "autoload",
      "begin",   "bg",       "bind",     "bindkey", "break",   "builtin", "caller",   "case",    "catch",
      "cd",      "command",  "compgen",  "complete", "compopt", "continue", "coproc",  "declare", "dirs",
      "disown",  "do",       "done",     "elif",    "else",    "enable",  "end",      "esac",    "eval",
      "exec",    "exit",     "export",   "false",   "fc",      "fg",      "fi",       "finally", "for",
      "foreach", "function", "getopts",  "history", "if",      "in",      "jobs",     "let",     "local",
      "logout",  "mapfile",  "nocorrect", "noglob", "not",     "or",      "popd",     "pushd",   "read",
      "readarray", "readonly", "repeat", "return",  "select",  "set",     "setopt",   "shift",   "shopt",
      "source",  "switch",   "suspend",  "test",    "then",    "time",    "times",    "trap",    "try",
      "true",    "type",     "typeset",  "ulimit",  "umask",   "unalias", "until",    "unset",   "unsetopt",
      "wait",    "while"};
  return names;
}

// Unlike setup builtins, these make later segments control flow or
// unreachable, so a later program does not name the command.
const Names& terminalPrograms() {
  static const Names names{"and",   "begin",  "break",   "case",   "catch", "continue", "coproc", "do",
                           "done",  "elif",   "else",    "end",    "esac",  "eval",     "exec",   "exit",
                           "false", "fi",     "finally", "for",    "foreach", "function", "if",   "in",
                           "not",   "or",     "repeat",  "return", "select", "switch",  "then",   "try",
                           "until", "while"};
  return names;
}

const Names& wrapperOptionsWithValue(Wrapper wrapper) {
  static const Names env{"-C", "--chdir", "-S", "--split-string", "-u", "--unset"};
  static const Names sudo{"-C", "--close-from", "-D", "--chdir", "-g", "--group", "-u", "--user"};
  return wrapper == Wrapper::Env ? env : sudo;
}
const Names& wrapperFlags(Wrapper wrapper) {
  static const Names env{"-0", "--null", "-i", "--ignore-environment", "--debug", "-v"};
  static const Names sudo{"-A", "--askpass", "-b", "--background", "-E", "-H", "-i", "-n", "-S"};
  return wrapper == Wrapper::Env ? env : sudo;
}

QChar at(const QString& text, qsizetype index) {
  return index >= 0 && index < text.size() ? text.at(index) : QChar();
}

bool matches(const QString& text, const QRegularExpression& pattern) {
  return pattern.match(text).hasMatch();
}

QRegularExpression re(const char* pattern,
                      QRegularExpression::PatternOptions options = QRegularExpression::NoPatternOption) {
  return QRegularExpression(QString::fromUtf8(pattern), options);
}

// The last path segment, `/` or `\`.
QString baseName(const QString& token) {
  return token.mid(std::max(token.lastIndexOf(QLatin1Char('/')), token.lastIndexOf(QLatin1Char('\\'))) + 1);
}

std::optional<QStringList> tokenize(const QString& command) {
  static const QRegularExpression windowsPath = re(R"(^(?:[A-Za-z]:|\.{1,2})(?:\\[^\s]*)?$)");
  const QString input = command.trimmed();
  QStringList tokens;
  QString current;
  QChar quote;
  bool escaping = false;
  bool inBackticks = false;
  int substitutionDepth = 0;
  int parameterDepth = 0;
  bool started = false;

  for (qsizetype index = 0; index < input.size(); ++index) {
    const QChar character = input.at(index);
    if (escaping) {
      current += character;
      escaping = false;
      started = true;
      continue;
    }
    if (character == u'\\' && quote != u'\'') {
      const QChar next = at(input, index + 1);
      const bool isWindowsPath = quote.isNull() && matches(current, windowsPath);
      if ((quote == u'"' || isWindowsPath) && !next.isNull() && next != u'"' && next != u'\\' && next != u'$' &&
          next != u'`' && next != u'\n') {
        current += character;
        started = true;
        continue;
      }
      escaping = true;
      started = true;
      continue;
    }
    if (inBackticks) {
      current += character;
      if (character == u'`') inBackticks = false;
      started = true;
      continue;
    }
    if (!quote.isNull()) {
      if (character == quote) {
        quote = QChar();
      } else {
        current += character;
      }
      started = true;
      continue;
    }
    if (character == u'`') {
      current += character;
      inBackticks = true;
      started = true;
      continue;
    }
    if (character == u'$' && at(input, index + 1) == u'{') {
      current += QStringLiteral("${");
      ++parameterDepth;
      started = true;
      ++index;
      continue;
    }
    if (character == u'{' && parameterDepth > 0) {
      current += character;
      ++parameterDepth;
      started = true;
      continue;
    }
    if (character == u'}' && parameterDepth > 0) {
      current += character;
      --parameterDepth;
      started = true;
      continue;
    }
    if (character == u'$' && at(input, index + 1) == u'(') {
      current += QStringLiteral("$(");
      ++substitutionDepth;
      started = true;
      ++index;
      continue;
    }
    if (character == u'(') {
      current += character;
      ++substitutionDepth;
      started = true;
      continue;
    }
    if (character == u')' && substitutionDepth > 0) {
      current += character;
      --substitutionDepth;
      started = true;
      continue;
    }
    if (character == u'"' || character == u'\'') {
      quote = character;
      started = true;
      continue;
    }
    if (character.isSpace()) {
      if (substitutionDepth > 0 || parameterDepth > 0) {
        current += character;
        started = true;
        continue;
      }
      if (started) {
        tokens.append(current);
        current.clear();
        started = false;
      }
      continue;
    }
    current += character;
    started = true;
  }

  if (!quote.isNull() || escaping || inBackticks || substitutionDepth > 0 || parameterDepth > 0) return std::nullopt;
  if (started) tokens.append(current);
  return tokens;
}

struct Split {
  QString first;
  // Empty when the command is one segment.
  QString rest;
  QString separator;
};

struct Heredoc {
  QString delimiter;
  bool stripTabs = false;
};

struct Range {
  qsizetype start = 0;
  qsizetype end = 0;
};

QString withoutComments(const QString& command, qsizetype end, const QList<Range>& comments) {
  QString result;
  qsizetype cursor = 0;
  for (const Range& comment : comments) {
    if (comment.start >= end) break;
    result += command.mid(cursor, comment.start - cursor);
    cursor = std::min(comment.end, end);
  }
  return result + command.mid(cursor, end - cursor);
}

std::optional<std::pair<Heredoc, qsizetype>> readHeredocDelimiter(const QString& command, qsizetype start,
                                                                  bool stripTabs) {
  qsizetype index = start;
  while (at(command, index) == u' ' || at(command, index) == u'\t') ++index;
  QString delimiter;
  QChar quote;
  bool escaping = false;
  for (; index < command.size(); ++index) {
    const QChar character = command.at(index);
    if (escaping) {
      delimiter += character;
      escaping = false;
      continue;
    }
    if (character == u'\\' && quote != u'\'') {
      escaping = true;
      continue;
    }
    if (!quote.isNull()) {
      if (character == quote) {
        quote = QChar();
      } else {
        delimiter += character;
      }
      continue;
    }
    if (character == u'"' || character == u'\'') {
      quote = character;
      continue;
    }
    if (character.isSpace() || QStringLiteral(";&|<>()").contains(character)) break;
    delimiter += character;
  }
  if (delimiter.isEmpty() || !quote.isNull() || escaping) return std::nullopt;
  return std::pair{Heredoc{delimiter, stripTabs}, index};
}

// What follows the heredoc bodies starting at `start`; empty when nothing
// does, nullopt when a body is not closed.
std::optional<QString> afterHeredocs(const QString& command, qsizetype start, const QList<Heredoc>& heredocs) {
  static const QRegularExpression leadingTabs = re("^\\t+");
  qsizetype cursor = start;
  for (const Heredoc& heredoc : heredocs) {
    bool found = false;
    while (cursor <= command.size()) {
      const qsizetype newline = command.indexOf(QLatin1Char('\n'), cursor);
      const qsizetype lineEnd = newline == -1 ? command.size() : newline;
      QString line = command.mid(cursor, lineEnd - cursor);
      if (line.endsWith(QLatin1Char('\r'))) line.chop(1);
      if (heredoc.stripTabs) line.remove(leadingTabs);
      cursor = newline == -1 ? command.size() : newline + 1;
      if (line == heredoc.delimiter) {
        found = true;
        break;
      }
      if (newline == -1) break;
    }
    if (!found) return std::nullopt;
  }
  return command.mid(cursor).trimmed();
}

QString trimStart(const QString& text) {
  qsizetype start = 0;
  while (start < text.size() && text.at(start).isSpace()) ++start;
  return text.mid(start);
}

Split splitFirst(const QString& command) {
  QChar quote;
  QChar hereStringQuote;
  bool escaping = false;
  bool inBackticks = false;
  bool inComment = false;
  int substitutionDepth = 0;
  int parameterDepth = 0;
  QList<Heredoc> heredocs;
  QList<Range> comments;
  qsizetype commentStart = 0;
  std::optional<Range> separatorBeforeHeredocs;

  for (qsizetype index = 0; index < command.size(); ++index) {
    const QChar character = command.at(index);
    if (!hereStringQuote.isNull()) {
      if (character == hereStringQuote && at(command, index + 1) == u'@' &&
          (index == 0 || command.at(index - 1) == u'\n')) {
        hereStringQuote = QChar();
        ++index;
      }
      continue;
    }
    if (inComment) {
      if (character != u'\n') continue;
      inComment = false;
      comments.append({commentStart, index});
    }
    if (escaping) {
      escaping = false;
      continue;
    }
    if (character == u'\\' && quote != u'\'') {
      escaping = true;
      continue;
    }
    if (inBackticks) {
      if (character == u'`') inBackticks = false;
      continue;
    }
    if (!quote.isNull()) {
      if (character == quote) quote = QChar();
      continue;
    }
    if (character == u'@' && (at(command, index + 1) == u'"' || at(command, index + 1) == u'\'') &&
        (at(command, index + 2) == u'\n' || (at(command, index + 2) == u'\r' && at(command, index + 3) == u'\n'))) {
      hereStringQuote = command.at(index + 1);
      ++index;
      continue;
    }
    if (character == u'"' || character == u'\'') {
      quote = character;
      continue;
    }
    if (character == u'`') {
      inBackticks = true;
      continue;
    }
    if (character == u'#' &&
        (index == 0 || command.at(index - 1).isSpace() || QStringLiteral(";&|(").contains(command.at(index - 1)))) {
      inComment = true;
      commentStart = index;
      continue;
    }
    if (character == u'$' && at(command, index + 1) == u'{') {
      ++parameterDepth;
      ++index;
      continue;
    }
    if (character == u'{' && parameterDepth > 0) {
      ++parameterDepth;
      continue;
    }
    if (character == u'}' && parameterDepth > 0) {
      --parameterDepth;
      continue;
    }
    if (character == u'(') {
      ++substitutionDepth;
      continue;
    }
    if (character == u')' && substitutionDepth > 0) {
      --substitutionDepth;
      continue;
    }
    if (substitutionDepth > 0 || parameterDepth > 0) continue;

    if (character == u'<' && at(command, index + 1) == u'<' && at(command, index + 2) != u'<') {
      const bool stripTabs = at(command, index + 2) == u'-';
      const auto delimiter = readHeredocDelimiter(command, index + (stripTabs ? 3 : 2), stripTabs);
      if (!delimiter) return {command.trimmed(), {}, {}};
      heredocs.append(delimiter->first);
      index = delimiter->second - 1;
      continue;
    }

    const QChar next = at(command, index + 1);
    const bool isDouble =
        (character == u'&' && next == u'&') || (character == u'|' && (next == u'|' || next == u'&'));
    const bool isRedirection =
        character == u'&' && (at(command, index - 1) == u'>' || at(command, index - 1) == u'<' || next == u'>');
    if ((!isDouble && !QStringLiteral(";&|\n").contains(character)) || isRedirection) continue;

    if (character == u'\n' && !heredocs.isEmpty()) {
      const std::optional<Range> separator = separatorBeforeHeredocs;
      const QString first = trimStart(withoutComments(command, separator ? separator->start : index, comments));
      const QString before =
          separator ? command.mid(separator->end, index - separator->end).trimmed() : QString();
      const std::optional<QString> following = afterHeredocs(command, index + 1, heredocs);
      QStringList parts;
      if (!before.isEmpty()) parts.append(before);
      if (following && !following->isEmpty()) parts.append(*following);
      return {first, parts.join(QLatin1Char('\n')),
              separator ? command.mid(separator->start, separator->end - separator->start) : QStringLiteral("\n")};
    }
    if (!heredocs.isEmpty()) {
      if (!separatorBeforeHeredocs) separatorBeforeHeredocs = Range{index, index + (isDouble ? 2 : 1)};
      if (isDouble) ++index;
      continue;
    }

    const QString first = trimStart(withoutComments(command, index, comments));
    qsizetype nextIndex = index + (isDouble ? 2 : 1);
    while (at(command, nextIndex).isSpace()) ++nextIndex;
    return {first, command.mid(nextIndex).trimmed(), isDouble ? command.mid(index, 2) : QString(character)};
  }

  if (inComment) comments.append({commentStart, command.size()});
  return {withoutComments(command, command.size(), comments).trimmed(), {}, {}};
}

std::optional<QString> withoutLeadingComments(const QString& command) {
  QString remaining = trimStart(command);
  while (remaining.startsWith(QLatin1Char('#'))) {
    const qsizetype newline = remaining.indexOf(QLatin1Char('\n'));
    if (newline == -1) return std::nullopt;
    remaining = trimStart(remaining.mid(newline + 1));
  }
  if (remaining.isEmpty()) return std::nullopt;
  return remaining;
}

QString withoutLineContinuations(const QString& command) {
  QString normalized;
  QChar quote;
  bool escaping = false;
  for (qsizetype index = 0; index < command.size(); ++index) {
    const QChar character = command.at(index);
    if (escaping) {
      normalized += character;
      escaping = false;
      continue;
    }
    if (character == u'\\' && quote != u'\'') {
      if (at(command, index + 1) == u'\n') {
        ++index;
        continue;
      }
      if (at(command, index + 1) == u'\r' && at(command, index + 2) == u'\n') {
        index += 2;
        continue;
      }
      normalized += character;
      escaping = true;
      continue;
    }
    if (!quote.isNull()) {
      if (character == quote) quote = QChar();
    } else if (character == u'"' || character == u'\'') {
      quote = character;
    }
    normalized += character;
  }
  return normalized;
}

// The index after a redirection at `index` and its target; past the end when
// the target is missing.
std::optional<qsizetype> afterRedirection(const QStringList& tokens, qsizetype index) {
  static const QRegularExpression processSubstitution = re("^[<>]\\(");
  static const QRegularExpression redirection =
      re(R"(^(?:(?:(?:\d+|\*|\{[A-Za-z_][A-Za-z0-9_]*\})?(?:<<<|<<-|<<|<>|>>|>\||<&|>&|<|>))|&>>|&>)(.*)$)",
         QRegularExpression::DotMatchesEverythingOption);
  if (index >= tokens.size()) return std::nullopt;
  const QString& token = tokens.at(index);
  if (token.isEmpty() || matches(token, processSubstitution)) return std::nullopt;
  const auto match = redirection.match(token);
  if (!match.hasMatch()) return std::nullopt;
  if (!match.captured(1).isEmpty()) return index + 1;
  return index + 1 >= tokens.size() ? tokens.size() + 1 : index + 2;
}

QString serialize(const QStringList& tokens) {
  QStringList quoted;
  for (QString token : tokens) {
    quoted.append(QLatin1Char('\'') + token.replace(QLatin1String("'"), QLatin1String("'\\''")) + QLatin1Char('\''));
  }
  return quoted.join(QLatin1Char(' '));
}

bool isAssignment(const QString& token) {
  static const QRegularExpression assignment = re("^[A-Za-z_][A-Za-z0-9_]*\\+?=");
  return matches(token, assignment);
}

std::optional<qsizetype> transparentWrapperIndex(const QString& wrapper, const QStringList& tokens,
                                                 qsizetype index) {
  const auto token = [&](qsizetype i) { return i < tokens.size() ? tokens.at(i) : QString(); };
  const auto exists = [&](qsizetype i) { return i < tokens.size(); };
  if (wrapper == u"bundle") {
    if (token(index + 1) == u"exec" && exists(index + 2)) return index + 2;
    return std::nullopt;
  }
  if (wrapper == u"nohup") {
    qsizetype target = index + 1;
    if (token(target) == u"--") ++target;
    if (exists(target) && !tokens.at(target).isEmpty() && !tokens.at(target).startsWith(QLatin1Char('-'))) {
      return target;
    }
    return std::nullopt;
  }
  if (wrapper == u"script") {
    // BSD `script` takes an output file before the optional command.
    static const QRegularExpression option = re("^-[adkpqr]+$");
    if (matches(token(index + 1), option) && exists(index + 3)) return index + 3;
    return std::nullopt;
  }
  if (wrapper == u"arch") {
    static const QRegularExpression architecture = re("^-(?:arm64|arm64e|i386|x86_64)$");
    if (matches(token(index + 1), architecture)) {
      if (exists(index + 2)) return index + 2;
      return std::nullopt;
    }
    if (token(index + 1) == u"-arch" && exists(index + 3)) return index + 3;
    return std::nullopt;
  }
  if (wrapper == u"timeout" || wrapper == u"gtimeout") {
    static const QRegularExpression duration = re(R"(^(?:\d+(?:\.\d*)?|\.\d+)[smhd]?$)");
    if (matches(token(index + 1), duration) && exists(index + 2)) return index + 2;
  }
  return std::nullopt;
}

QString staticProgramName(const QString& value) {
  static const QRegularExpression scheme = re(R"(^[A-Za-z][A-Za-z0-9+.-]*:(?![\\/]))");
  static const QRegularExpression whitespace = re("\\s");
  static const QRegularExpression separator = re("[\\\\/]");
  const QString trimmed = value.trimmed();
  if (trimmed.isEmpty() || matches(trimmed, scheme)) return {};
  const QString program = baseName(trimmed);
  if (program.isEmpty() || (matches(program, whitespace) && !matches(trimmed, separator)) ||
      nonProgramPrefix.contains(program.front()) || nonProgramSuffix.contains(program.back())) {
    return {};
  }
  return program;
}

QString leadingPowerShellLiteral(const QString& command) {
  static const QRegularExpression word = re("^\\S+");
  const QString input = trimStart(command);
  const QChar quote = at(input, 0);
  if (quote != u'"' && quote != u'\'') return staticProgramName(word.match(input).captured(0));
  QString value;
  for (qsizetype index = 1; index < input.size(); ++index) {
    const QChar character = input.at(index);
    if (character == u'`' && index + 1 < input.size()) {
      value += input.at(++index);
      continue;
    }
    if (character == quote) {
      if (quote == u'\'' && at(input, index + 1) == u'\'') {
        value += QLatin1Char('\'');
        ++index;
        continue;
      }
      return staticProgramName(value);
    }
    value += character;
  }
  return {};
}

// `& 'tool.exe' args`: nullopt when the command is not a call.
std::optional<QString> callOperatorProgram(const QString& command) {
  static const QRegularExpression call = re(R"(^\s*&\s+([\s\S]*)$)");
  const auto match = call.match(command);
  if (!match.hasMatch()) return std::nullopt;
  return leadingPowerShellLiteral(match.captured(1));
}

struct Matched {
  bool matched = false;
  QString program;
};

QString programName(const QString& command, int depth, Context context, int segmentsRemaining);

Matched powerShellAssignmentProgram(const QString& command, int depth, const QString& rest, int segmentsRemaining) {
  static const QRegularExpression assignment =
      re(R"(^\s*\$(?:(env|global|local|script):)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*([\s\S]*)$)",
         QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression collection =
      re(R"(^(?:\[ordered\]\s*)?@\s*[{(])", QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression direct = re(R"(^(?:@?\(\s*)?([A-Za-z][A-Za-z0-9_.-]*)\b)");
  const auto match = assignment.match(command);
  if (!match.hasMatch()) return {};
  const auto next = [&] {
    return rest.isEmpty() ? QString() : programName(rest, depth, Context::Shell, segmentsRemaining - 1);
  };
  // Environment assignments are setup; their value is not a command.
  if (match.captured(1).toLower() == u"env") return {true, next()};
  const QString value = match.captured(2).trimmed();
  // The splitter does not balance PowerShell arrays or hashtables.
  if (matches(value, collection)) return {true, {}};
  if (const auto called = callOperatorProgram(value)) return {true, *called};
  const QString directCommand = direct.match(value).captured(1);
  if (!directCommand.isEmpty() && !nonDescriptivePrograms().contains(directCommand.toLower())) {
    const QString parsed = programName(value, depth + 1, Context::Shell, segmentsRemaining);
    return {true, parsed.isEmpty() ? directCommand : parsed};
  }
  return {true, next()};
}

Matched windowsShellPayload(const QString& shell, const QStringList& tokens, qsizetype start, int depth,
                            const Split& split, int segmentsRemaining) {
  const auto payload = [&](qsizetype index) {
    if (index >= tokens.size() || tokens.at(index).isEmpty()) return QString();
    const QString command = !split.rest.isEmpty() && !split.separator.isEmpty()
                                ? tokens.at(index) + QLatin1Char(' ') + split.separator + QLatin1Char(' ') + split.rest
                                : tokens.at(index);
    return programName(command, depth + 1, Context::Shell, segmentsRemaining);
  };
  if (shell == u"cmd" || shell == u"cmd.exe") {
    for (qsizetype index = start; index < tokens.size(); ++index) {
      const QString option = tokens.at(index).toLower();
      if (option == u"/c" || option == u"/k") return {true, payload(index + 1)};
    }
    return {};
  }
  for (qsizetype index = start; index < tokens.size(); ++index) {
    const QString option = tokens.at(index).toLower();
    if (option == u"-command" || option == u"-c") return {true, payload(index + 1)};
    if (option == u"-file" || option == u"-f") {
      return {true, staticProgramName(index + 1 < tokens.size() ? tokens.at(index + 1) : QString())};
    }
    if (option == u"-encodedcommand" || option == u"-enc" || option == u"-e") return {true, {}};
    if (powerShellOptionsWithValue().contains(option)) {
      ++index;
      continue;
    }
    if (powerShellFlags().contains(option)) continue;
    if (!option.startsWith(QLatin1Char('-'))) return {true, staticProgramName(tokens.at(index))};
  }
  return {};
}

QString startProcessProgram(const QStringList& tokens, qsizetype start) {
  for (qsizetype index = start; index < tokens.size(); ++index) {
    const QString& token = tokens.at(index);
    const QString option = token.toLower();
    if (option == u"-filepath") return staticProgramName(index + 1 < tokens.size() ? tokens.at(index + 1) : QString());
    if (startProcessFlags().contains(option)) continue;
    if (startProcessOptionsWithValue().contains(option)) {
      if (index + 1 >= tokens.size()) return {};
      ++index;
      continue;
    }
    if (token.startsWith(QLatin1Char('-'))) return {};
    return staticProgramName(token);
  }
  return {};
}

// `NAME=value`: the program a literal value names (empty when it names none),
// nullopt when the token is not an assignment.
std::optional<std::pair<QString, QString>> literalAssignment(const QString& token) {
  static const QRegularExpression assignment =
      re("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", QRegularExpression::DotMatchesEverythingOption);
  static const QRegularExpression expansion = re("[$`]");
  static const QRegularExpression whitespace = re("\\s");
  static const QRegularExpression separator = re("[\\\\/]");
  const auto match = assignment.match(token);
  if (!match.hasMatch()) return std::nullopt;
  const QString name = match.captured(1);
  QString value = match.captured(2).trimmed();
  if (value.isEmpty() || matches(value, expansion)) return std::pair{name, QString()};
  if (value.startsWith(QLatin1Char('(')) && value.endsWith(QLatin1Char(')'))) {
    const auto array = tokenize(value.mid(1, value.size() - 2));
    value = array && !array->isEmpty() ? array->first() : QString();
  } else if (matches(value, whitespace) && !matches(value, separator)) {
    return std::pair{name, QString()};
  }
  return std::pair{name, staticProgramName(value)};
}

QString referencedAlias(const QString& token) {
  static const QRegularExpression reference =
      re(R"(^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?:\[@\])?\})$)");
  const auto match = reference.match(token);
  if (!match.hasMatch()) return {};
  return match.captured(1).isEmpty() ? match.captured(2) : match.captured(1);
}

// Only literal aliases an earlier top-level segment declared, such as
// `SSH=(ssh ...)` or `TOOL=/path/to/tool`; no expansion, no general state.
QString literalAliasProgram(const QString& command) {
  QHash<QString, QString> aliases;
  QString remaining = command;
  int controlFlowDepth = 0;
  for (int segment = 0; !remaining.isEmpty() && segment < 64; ++segment) {
    const auto uncommented = withoutLeadingComments(remaining);
    if (!uncommented) return {};
    const Split split = splitFirst(*uncommented);
    const auto tokens = tokenize(withoutLineContinuations(split.first));
    if (!tokens) return {};
    const QString leading = tokens->value(0);
    qsizetype commandIndex = leading == u"do" || leading == u"then" ? 1 : 0;
    while (commandIndex < tokens->size()) {
      const auto after = afterRedirection(*tokens, commandIndex);
      if (after && *after <= tokens->size()) {
        commandIndex = *after;
        continue;
      }
      if (isAssignment(tokens->value(commandIndex))) {
        ++commandIndex;
        continue;
      }
      break;
    }
    const QString alias = referencedAlias(tokens->value(commandIndex));
    if (!alias.isEmpty() && !aliases.value(alias).isEmpty()) return aliases.value(alias);

    if (leading == u"fi" || leading == u"done" || leading == u"esac") controlFlowDepth = std::max(0, controlFlowDepth - 1);
    if (leading == u"if" || leading == u"for" || leading == u"while" || leading == u"until" || leading == u"select" ||
        leading == u"case") {
      ++controlFlowDepth;
    }
    if (controlFlowDepth == 0 && leading == u"unset") {
      for (const QString& name : tokens->mid(1)) aliases.remove(name);
    }
    const qsizetype assignmentStart = leading == u"export" ? 1 : 0;
    QList<std::pair<QString, QString>> assignments;
    bool all = tokens->size() > assignmentStart;
    for (qsizetype i = assignmentStart; all && i < tokens->size(); ++i) {
      const auto assignment = literalAssignment(tokens->at(i));
      if (!assignment) all = false;
      else assignments.append(*assignment);
    }
    if (controlFlowDepth == 0 && all) {
      for (const auto& [name, program] : assignments) {
        if (program.isEmpty()) aliases.remove(name);
        else aliases.insert(name, program);
      }
    }
    remaining = split.rest;
  }
  return {};
}

QString wrappedShellProgram(const QString& wrapper, const QStringList& tokens, qsizetype start, int depth,
                            const QString& rest, int segmentsRemaining) {
  static const QRegularExpression execName = re("^-a.+");
  static const QRegularExpression execFlags = re("^-[cl]+$");
  qsizetype index = start;
  if (wrapper == u"command") {
    while (index < tokens.size()) {
      const QString& option = tokens.at(index);
      if (option == u"--") {
        ++index;
        break;
      }
      if (!option.startsWith(QLatin1Char('-')) || option == u"-") break;
      if (option != u"-p") return {};
      ++index;
    }
  } else if (wrapper == u"builtin") {
    if (tokens.value(index) == u"--") {
      ++index;
    } else if (tokens.value(index).startsWith(QLatin1Char('-'))) {
      return {};
    }
  } else if (wrapper == u"exec") {
    while (index < tokens.size()) {
      const QString& option = tokens.at(index);
      if (option == u"--") {
        ++index;
        break;
      }
      if (option == u"-a") {
        if (index + 1 >= tokens.size()) return {};
        index += 2;
        continue;
      }
      if (matches(option, execName) || matches(option, execFlags)) {
        ++index;
        continue;
      }
      if (option.startsWith(QLatin1Char('-')) && option != u"-") return {};
      break;
    }
  }

  const QStringList wrapped = tokens.mid(index);
  if (wrapped.isEmpty()) return {};
  qsizetype targetIndex = 0;
  while (targetIndex < wrapped.size()) {
    const auto after = afterRedirection(wrapped, targetIndex);
    if (!after || *after > wrapped.size()) break;
    targetIndex = *after;
  }
  const QString target = wrapped.value(targetIndex);
  if (!target.isEmpty() && isAssignment(target)) return {};
  const QString program = programName(serialize(wrapped), depth + 1,
                                      wrapper == u"exec" ? Context::Exec : Context::Shell, segmentsRemaining);
  if (!program.isEmpty()) return program;
  if (wrapper != u"exec" && !target.isEmpty() && target == target.toLower() &&
      nonDescriptivePrograms().contains(target) && !terminalPrograms().contains(target) && !rest.isEmpty()) {
    return programName(rest, depth, Context::Shell, segmentsRemaining - 1);
  }
  return {};
}

// The index of a shell's `-c` script among `tokens` after the shell.
std::optional<qsizetype> shellScriptIndex(const QStringList& tokens, qsizetype start) {
  static const QRegularExpression commandFlag = re("^-[a-zA-Z]*c[a-zA-Z]*$");
  for (qsizetype index = start; index < tokens.size(); ++index) {
    const QString& option = tokens.at(index);
    if (option == u"--" || !option.startsWith(QLatin1Char('-'))) return std::nullopt;
    if (shellOptionsWithValue().contains(option)) {
      ++index;
      continue;
    }
    if (option == u"--command" || matches(option, commandFlag)) return index + 1;
  }
  return std::nullopt;
}

QString parseProgramName(const QString& command, int depth, Context context, int segmentsRemaining) {
  static const QRegularExpression block =
      re(R"(^(?:catch|finally|for|foreach|function|if|param|switch|try|while)\s*[{(])",
         QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression function = re(R"(^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)\s*\{)");
  static const QRegularExpression hereString = re(R"(^@["'](?:\r?\n))");
  static const QRegularExpression windowsPath =
      re(R"(^\s*((?:\.{1,2}|%[A-Za-z_][A-Za-z0-9_]*%|\$env:[A-Za-z_][A-Za-z0-9_]*)\\\S+))",
         QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression quotedSyntax = re(R"([\s()=])");
  static const QRegularExpression separator = re("[\\\\/]");
  static const QRegularExpression shortOptions = re("^-[A-Za-z].+");
  static const QRegularExpression exeSuffix = re("\\.exe$", QRegularExpression::CaseInsensitiveOption);
  static const QRegularExpression functionToken = re(R"(^[A-Za-z_][A-Za-z0-9_]*\(\)\{$)");

  if (depth >= 8 || segmentsRemaining <= 0) return {};
  const auto uncommented = withoutLeadingComments(command);
  if (!uncommented) return {};
  if (matches(*uncommented, block) || matches(*uncommented, function)) return {};
  // `&&` and `||` inside `[[ ... ]]` are not separators; stay conservative.
  if (uncommented->startsWith(QLatin1String("[["))) return {};
  const Split split = splitFirst(*uncommented);
  const auto next = [&](Context nextContext) {
    return split.rest.isEmpty() ? QString() : programName(split.rest, depth, nextContext, segmentsRemaining - 1);
  };
  if (matches(trimStart(split.first), hereString)) return next(Context::Shell);
  if (const Matched assignment = powerShellAssignmentProgram(split.first, depth, split.rest, segmentsRemaining);
      assignment.matched) {
    return assignment.program;
  }
  if (const QString path = windowsPath.match(split.first).captured(1); !path.isEmpty()) return staticProgramName(path);
  const auto parsed = tokenize(withoutLineContinuations(split.first));
  if (!parsed) return {};
  const QStringList& tokens = *parsed;
  const QChar firstCharacter = at(trimStart(split.first), 0);
  if (tokens.size() == 1 && (firstCharacter == u'"' || firstCharacter == u'\'') &&
      matches(tokens.first(), quotedSyntax) && !matches(tokens.first(), separator)) {
    return next(context);
  }

  qsizetype index = 0;
  Wrapper wrapper = Wrapper::None;
  Context execution = context;
  bool sawAssignment = false;
  bool sawRedirection = false;

  while (index < tokens.size()) {
    const QString& token = tokens.at(index);
    if (token.isEmpty()) return {};
    if (const auto after = afterRedirection(tokens, index)) {
      if (*after > tokens.size()) return {};
      sawRedirection = true;
      index = *after;
      continue;
    }
    if (isAssignment(token)) {
      sawAssignment = true;
      ++index;
      continue;
    }
    if (execution == Context::Shell && token == u":") return next(execution);
    if (nonProgramPrefix.contains(token.front()) &&
        !(token.startsWith(QLatin1Char('$')) && token.contains(QLatin1Char('/')))) {
      return execution == Context::Shell && token.startsWith(QLatin1Char('[')) ? next(execution) : QString();
    }
    const QString program = baseName(token);
    const bool unqualified = token == program;
    if (program == u"env" || program == u"sudo") {
      wrapper = program == u"env" ? Wrapper::Env : Wrapper::Sudo;
      execution = Context::Exec;
      ++index;
      continue;
    }
    if (wrapper != Wrapper::None && token == u"--") {
      wrapper = Wrapper::None;
      ++index;
      continue;
    }
    if (wrapper != Wrapper::None && token.startsWith(QLatin1Char('-'))) {
      if (wrapper == Wrapper::Env && (token == u"-S" || token == u"--split-string")) {
        return index + 1 < tokens.size() && !tokens.at(index + 1).isEmpty()
                   ? programName(tokens.at(index + 1), depth + 1, execution, segmentsRemaining)
                   : QString();
      }
      if (wrapper == Wrapper::Env && token.startsWith(QLatin1String("--split-string="))) {
        return programName(token.mid(15), depth + 1, execution, segmentsRemaining);
      }
      if (wrapperOptionsWithValue(wrapper).contains(token)) {
        if (index + 1 >= tokens.size()) return {};
        index += 2;
        continue;
      }
      if (wrapperFlags(wrapper).contains(token)) {
        ++index;
        continue;
      }
      const qsizetype equals = token.indexOf(QLatin1Char('='));
      if (token.startsWith(QLatin1String("--")) && equals > 2) {
        if (!wrapperOptionsWithValue(wrapper).contains(token.left(equals))) return {};
        ++index;
        continue;
      }
      if (matches(token, shortOptions) && !token.startsWith(QLatin1String("--"))) {
        bool consumesNext = false;
        for (qsizetype i = 1; i < token.size(); ++i) {
          const QString option = QLatin1Char('-') + token.at(i);
          if (wrapperOptionsWithValue(wrapper).contains(option)) {
            consumesNext = i == token.size() - 1;
            break;
          }
          if (!wrapperFlags(wrapper).contains(option)) return {};
        }
        if (consumesNext && index + 1 >= tokens.size()) return {};
        index += consumesNext ? 2 : 1;
        continue;
      }
      return {};
    }
    if (shellPrograms().contains(QString(program).remove(exeSuffix).toLower())) {
      if (const auto script = shellScriptIndex(tokens, index + 1)) {
        return *script < tokens.size() && !tokens.at(*script).isEmpty()
                   ? programName(tokens.at(*script), depth + 1, Context::Shell, segmentsRemaining)
                   : QString();
      }
    }
    const QString lower = program.toLower();
    if (windowsShellPrograms().contains(lower)) {
      const Matched payload = windowsShellPayload(lower, tokens, index + 1, depth, split, segmentsRemaining);
      if (payload.matched) return payload.program;
    }
    if (lower == u"start-process") {
      if (const QString started = startProcessProgram(tokens, index + 1); !started.isEmpty()) return started;
    }
    if (execution == Context::Shell && unqualified && shellPrecommandModifiers().contains(program)) {
      ++index;
      if (program == u"time" && tokens.value(index) == u"-p") ++index;
      if (tokens.value(index).startsWith(QLatin1Char('-'))) return {};
      continue;
    }
    if (unqualified) {
      if (const auto target = transparentWrapperIndex(program, tokens, index)) {
        const QString wrapped = programName(serialize(tokens.mid(*target)), depth + 1, Context::Exec, segmentsRemaining);
        if (!wrapped.isEmpty()) return wrapped;
      }
    }
    if (unqualified && shellCommandWrappers().contains(program)) {
      return wrappedShellProgram(program, tokens, index + 1, depth, split.rest, segmentsRemaining);
    }
    if ((execution == Context::Shell || (wrapper == Wrapper::Sudo && skippableSudoProbes().contains(program))) &&
        unqualified && nonDescriptivePrograms().contains(program) &&
        (!terminalPrograms().contains(program) || (program == u"false" && split.separator != u"&&")) &&
        !split.rest.isEmpty()) {
      return next(Context::Shell);
    }
    if (execution == Context::Shell && unqualified && powerShellSetupPrograms().contains(lower) &&
        !split.rest.isEmpty()) {
      return next(Context::Shell);
    }
    if (program.isEmpty() || (unqualified && nonDescriptivePrograms().contains(program)) ||
        nonProgramPrefix.contains(program.front()) || nonProgramSuffix.contains(program.back()) ||
        program.endsWith(QLatin1String("()")) || matches(program, functionToken)) {
      return {};
    }
    return program;
  }

  if ((sawAssignment || sawRedirection) && wrapper == Wrapper::None) return next(execution);
  return {};
}

QString programName(const QString& command, int depth, Context context, int segmentsRemaining) {
  if (segmentsRemaining <= 0) return {};
  if (const auto called = callOperatorProgram(command)) return *called;
  const QString parsed = parseProgramName(command, depth, context, segmentsRemaining);
  if (!parsed.isEmpty() || context != Context::Shell) return parsed;
  return literalAliasProgram(command);
}

}  // namespace

QString commandProgramName(const QString& command) {
  return programName(command, 0, Context::Shell, maxCommandSegments);
}

}  // namespace timeline
