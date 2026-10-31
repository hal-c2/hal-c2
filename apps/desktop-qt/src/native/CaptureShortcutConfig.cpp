#include "CaptureShortcutConfig.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QStringDecoder>
#include <QUuid>

#ifdef Q_OS_UNIX
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {

constexpr qint64 kMaxBytes = 1024 * 1024;
constexpr int kMaxFiles = 64;

// --- KDL: just enough of it to find nodes and where they sit (captureConfigKdl) -----

struct Token {
  QString value;
  qsizetype start = 0;
  qsizetype end = 0;
  bool quoted = false;
};

struct Node {
  QString name;
  QList<Token> header;
  QList<Node> children;
  qsizetype start = 0;
  qsizetype end = 0;
  std::optional<qsizetype> close;
};

const QString kUnreadableKdl = QStringLiteral("Couldn't read this Niri config. Use Advanced to configure it manually.");

bool kdlSpace(QChar c) {
  const char16_t u = c.unicode();
  return u == u'\t' || u == u' ' || u == u'\r' || u == 0xFEFF || u == 0x00A0 || u == 0x1680 || (u >= 0x2000 && u <= 0x200A) ||
         u == 0x202F || u == 0x205F || u == 0x3000;
}

std::optional<QList<Token>> tokenize(const QString& source) {
  QList<Token> tokens;
  qsizetype offset = 0;
  const qsizetype size = source.size();
  static const QRegularExpression continuation(QStringLiteral("^\\\\[\\t \\r\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{3000}]*\\n"));
  static const QRegularExpression raw(QStringLiteral("^r(#{0,32})\""));
  while (offset < size) {
    const qsizetype start = offset;
    const QStringView rest = QStringView(source).mid(offset);
    if (kdlSpace(source[offset])) {
      ++offset;
      continue;
    }
    if (rest.startsWith(u"//")) {
      const qsizetype end = source.indexOf(u'\n', offset);
      offset = end < 0 ? size : end;
      continue;
    }
    if (rest.startsWith(u"/*")) {
      offset += 2;
      int depth = 1;
      while (depth && offset < size) {
        if (QStringView(source).mid(offset).startsWith(u"/*")) {
          ++depth;
          offset += 2;
        } else if (QStringView(source).mid(offset).startsWith(u"*/")) {
          --depth;
          offset += 2;
        } else {
          ++offset;
        }
      }
      if (depth) return std::nullopt;
      continue;
    }
    if (const auto match = continuation.matchView(rest); match.hasMatch()) {
      offset += match.capturedLength();
      continue;
    }
    if (const auto match = raw.matchView(rest); match.hasMatch()) {
      const QString terminator = u'"' + match.captured(1);
      const qsizetype end = source.indexOf(terminator, offset + match.capturedLength());
      if (end < 0) return std::nullopt;
      offset = end + terminator.size();
      tokens.append({source.mid(start + match.capturedLength(), end - start - match.capturedLength()), start, offset, true});
      continue;
    }
    if (source[offset] == u'"') {
      ++offset;
      while (offset < size && source[offset] != u'"') {
        if (source[offset] == u'\\') ++offset;
        ++offset;
      }
      if (offset >= size) return std::nullopt;
      ++offset;
      // KDL's unicode escapes differ from JSON's; names needing those stay on the manual path.
      QJsonParseError parsed;
      const QJsonDocument document =
          QJsonDocument::fromJson((u'[' + source.mid(start, offset - start) + u']').toUtf8(), &parsed);
      if (parsed.error != QJsonParseError::NoError || !document.array().at(0).isString()) return std::nullopt;
      tokens.append({document.array().at(0).toString(), start, offset, true});
      continue;
    }
    if (rest.startsWith(u"/-")) {
      offset += 2;
    } else if (QStringView(u"{};\n=()").contains(source[offset])) {
      ++offset;
    } else {
      while (offset < size) {
        const QChar c = source[offset];
        if (c.isSpace() || kdlSpace(c) || QStringView(u"{};=\"()").contains(c)) break;
        const QStringView here = QStringView(source).mid(offset);
        if (here.startsWith(u"//") || here.startsWith(u"/*") || here.startsWith(u"/-")) break;
        ++offset;
      }
    }
    if (offset == start) return std::nullopt;
    tokens.append({source.mid(start, offset - start), start, offset, false});
  }
  return tokens;
}

struct Parser {
  const QList<Token>& tokens;
  qsizetype cursor = 0;
  bool failed = false;

  bool is(qsizetype index, QStringView value) const {
    return index < tokens.size() && !tokens[index].quoted && tokens[index].value == value;
  }

  QList<Node> nodes(bool nested) {
    QList<Node> result;
    while (cursor < tokens.size() && !failed) {
      if (is(cursor, u"\n") || is(cursor, u";")) {
        ++cursor;
        continue;
      }
      if (is(cursor, u"}")) {
        if (!nested) failed = true;
        return result;
      }
      const bool disabled = is(cursor, u"/-");
      if (disabled) ++cursor;
      if (cursor >= tokens.size()) {
        failed = true;
        return result;
      }
      const Token name = tokens[cursor++];
      if (!name.quoted && QStringList{QStringLiteral("{"), QStringLiteral("}"), QStringLiteral("="), QStringLiteral(";"),
                                      QStringLiteral("\n"), QStringLiteral("(")}
                              .contains(name.value)) {
        failed = true;
        return result;
      }
      Node node{name.value, {name}, {}, name.start, name.end, std::nullopt};
      while (cursor < tokens.size() && !is(cursor, u"\n") && !is(cursor, u";") && !is(cursor, u"}")) {
        const Token token = tokens[cursor++];
        if (!token.quoted && token.value == u"{") {
          node.children = nodes(true);
          if (failed) return result;
          if (!is(cursor, u"}")) {
            failed = true;
            return result;
          }
          node.close = tokens[cursor].start;
          node.end = tokens[cursor].end;
          ++cursor;
          break;
        }
        node.header.append(token);
        node.end = token.end;
      }
      if (!disabled) result.append(node);
    }
    if (nested) failed = true;
    return result;
  }
};

std::optional<QList<Node>> readKdl(const QString& source, QString* error) {
  const auto tokens = tokenize(source);
  if (!tokens) {
    *error = kUnreadableKdl;
    return std::nullopt;
  }
  Parser parser{*tokens};
  QList<Node> nodes = parser.nodes(false);
  if (parser.failed) {
    *error = kUnreadableKdl;
    return std::nullopt;
  }
  return nodes;
}

// --- Edits (captureConfigEdit) ----------------------------------------------------

bool sameKeys(const QString& left, const QString& right) {
  QString ignored;
  const auto a = CaptureShortcutConfig::keys(left, &ignored);
  const auto b = CaptureShortcutConfig::keys(right, &ignored);
  return a && b && a->label == b->label;
}

// The one binds block, absent when there is none; an error when there are
// two or one never closes.
bool niriBinds(const QString& source, std::optional<Node>* block, QString* error) {
  const auto nodes = readKdl(source, error);
  if (!nodes) return false;
  block->reset();
  int count = 0;
  for (const Node& node : *nodes) {
    if (node.name != u"binds") continue;
    if (++count > 1 || !node.close) {
      *error = QStringLiteral("This Niri config has an unexpected binds section. Check it in Advanced.");
      return false;
    }
    *block = node;
  }
  return true;
}

QStringList values(const QList<Token>& header) {
  QStringList result;
  for (const Token& token : header) result.append(token.value);
  return result;
}

bool niriCaptureNode(const Node& node, const QString& appId) {
  QString ignored;
  const auto parsed = readKdl(CaptureShortcutConfig::binding(CaptureShortcutConfig::Format::Niri, appId, QStringLiteral("Ctrl+Shift+2")), &ignored);
  if (!parsed || parsed->isEmpty() || parsed->first().children.isEmpty()) return false;
  const Node& expected = parsed->first().children.first();
  return node.children.size() == 1 && node.children.first().children.isEmpty() &&
         values(node.children.first().header) == values(expected.header);
}

struct Range {
  qsizetype start = 0;
  qsizetype end = 0;
  QString keys;
  QString action;
};

QList<Range> hyprlandBinds(const QString& source, bool lua) {
  static const QRegularExpression legacy(QStringLiteral("^\\s*bind[a-z]*\\s*=\\s*([^,]*),\\s*([^,]*),\\s*([^,]*),\\s*(.*?)\\s*(?:#.*)?$"));
  static const QRegularExpression modern(
      QStringLiteral("^\\s*hl\\.bind\\(\\s*([\"'])(.*?)\\1\\s*,\\s*hl\\.dsp\\.global\\(\\s*([\"'])(.*?)\\3\\s*\\)\\s*\\)\\s*;?\\s*(?:--.*)?$"));
  static const QRegularExpression spaces(QStringLiteral("\\s+"));
  QList<Range> bindings;
  qsizetype start = 0;
  while (start < source.size()) {
    const qsizetype newline = source.indexOf(u'\n', start);
    const qsizetype end = newline < 0 ? source.size() : newline + 1;
    const QString line = source.mid(start, end - start);
    // trimEnd
    qsizetype last = line.size();
    while (last > 0 && line[last - 1].isSpace()) --last;
    const QString trimmed = line.left(last);
    if (!lua) {
      if (const auto match = legacy.match(trimmed); match.hasMatch()) {
        bindings.append({start, end, match.captured(1).trimmed().replace(spaces, QStringLiteral("+")) + u'+' + match.captured(2).trimmed(),
                         match.captured(3).trimmed() == u"global" ? match.captured(4).trimmed() : QString()});
      }
    } else if (const auto match = modern.match(trimmed); match.hasMatch()) {
      bindings.append({start, end, match.captured(2), match.captured(4)});
    }
    start = end;
  }
  return bindings;
}

struct Include {
  QString path;
  bool optional = false;
};

std::optional<QList<Include>> niriIncludes(const QString& source, QString* error) {
  const auto nodes = readKdl(source, error);
  if (!nodes) return std::nullopt;
  QList<Include> includes;
  for (const Node& node : *nodes) {
    if (node.name != u"include") continue;
    QString path;
    for (qsizetype i = 1; i < node.header.size(); ++i) {
      if (node.header[i].quoted && node.header[i - 1].value != u"=") {
        path = node.header[i].value;
        break;
      }
    }
    if (path.isEmpty()) {
      *error = QStringLiteral("Couldn't resolve a Niri include. Choose the config in Advanced.");
      return std::nullopt;
    }
    bool optional = false;
    for (qsizetype i = 0; i + 2 < node.header.size(); ++i) {
      if (node.header[i].value == u"optional" && node.header[i + 1].value == u"=" && node.header[i + 2].value == u"true") optional = true;
    }
    includes.append({path, optional});
  }
  return includes;
}

// Whether `keys` is bound to something else in `source`'s binds; nullopt with
// `error` when the config cannot be read.
std::optional<bool> niriConflict(const QString& source, const QString& appId, const QString& keys, QString* error) {
  std::optional<Node> block;
  if (!niriBinds(source, &block, error)) return std::nullopt;
  if (!block) return false;
  for (const Node& node : block->children) {
    if (sameKeys(node.name, keys) && !niriCaptureNode(node, appId)) return true;
  }
  return false;
}

QString removeRanges(const QString& source, QList<Range> ranges) {
  std::sort(ranges.begin(), ranges.end(), [](const Range& a, const Range& b) { return a.start > b.start; });
  QString result = source;
  for (const Range& range : ranges) {
    const qsizetype lineStart = range.start > 0 ? source.lastIndexOf(u'\n', range.start - 1) + 1 : 0;
    const qsizetype nextLine = source.indexOf(u'\n', range.end);
    const qsizetype lineEnd = nextLine < 0 ? source.size() : nextLine;
    const bool wholeLine =
        source.mid(lineStart, range.start - lineStart).trimmed().isEmpty() && source.mid(range.end, lineEnd - range.end).trimmed().isEmpty();
    const qsizetype from = wholeLine ? lineStart : range.start;
    const qsizetype to = wholeLine ? std::min(lineEnd + 1, source.size()) : range.end;
    result = result.left(from) + result.mid(to);
  }
  return result;
}

// --- Files ------------------------------------------------------------------------

#ifdef Q_OS_UNIX
QByteArray native(const QString& path) {
  return QFile::encodeName(path);
}
#endif

}  // namespace

struct CaptureShortcutConfig::File {
  QString path;
  QString resolvedPath;
  QString text;
  QByteArray bytes;
  quint64 inode = 0;
  uint mode = 0;
  uint uid = 0;
};

struct CaptureShortcutConfig::Pending {
  Preview preview;
  Target target;
  QList<File> files;
  QStringList missing;
  bool checkHyprlandKeys = false;
};

namespace {

// The file at `path`, read without following a link at its end (realpath
// first) or blocking on a FIFO. `missing` says it does not exist; `error`
// is set only for a file that is too big or not text.
std::optional<CaptureShortcutConfig::File> readFile(const QString& path, bool* missing, QString* error) {
  *missing = false;
#ifdef Q_OS_UNIX
  char resolved[PATH_MAX];
  if (!::realpath(native(path).constData(), resolved)) {
    *missing = errno == ENOENT;
    return std::nullopt;
  }
  const int fd = ::open(resolved, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return std::nullopt;
  struct stat info {};
  QByteArray bytes;
  bool ok = ::fstat(fd, &info) == 0;
  if (ok && (!S_ISREG(info.st_mode) || info.st_size > kMaxBytes)) {
    *error = QStringLiteral("Choose a config file smaller than 1 MB.");
    ok = false;
  }
  while (ok) {
    char buffer[65536];
    const ssize_t read = ::read(fd, buffer, sizeof buffer);
    if (read < 0 && errno == EINTR) continue;
    if (read < 0) ok = false;
    if (read <= 0) break;
    bytes.append(buffer, read);
    if (bytes.size() > kMaxBytes) {
      *error = QStringLiteral("Choose a config file smaller than 1 MB.");
      ok = false;
    }
  }
  ::close(fd);
  if (!ok) return std::nullopt;
  QStringDecoder decoder(QStringDecoder::Utf8, QStringDecoder::Flag::ConvertInitialBom | QStringDecoder::Flag::Stateless);
  const QString text = decoder.decode(bytes);
  if (decoder.hasError() || text.contains(QChar(u'\0'))) {
    *error = QStringLiteral("Choose a text config file.");
    return std::nullopt;
  }
  return CaptureShortcutConfig::File{path, QFile::decodeName(resolved), text, bytes, quint64(info.st_ino), uint(info.st_mode), uint(info.st_uid)};
#else
  Q_UNUSED(path);
  Q_UNUSED(error);
  return std::nullopt;
#endif
}

bool exists(const QString& path) {
#ifdef Q_OS_UNIX
  struct stat info {};
  return ::lstat(native(path).constData(), &info) == 0 || errno != ENOENT;
#else
  return QFileInfo::exists(path);
#endif
}

#ifdef Q_OS_UNIX
// Writes `bytes` to a new file at `path` with `mode`; false if it exists.
bool writeNew(const QString& path, const QByteArray& bytes, mode_t mode) {
  const int fd = ::open(native(path).constData(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode);
  if (fd < 0) return false;
  qsizetype written = 0;
  bool ok = true;
  while (ok && written < bytes.size()) {
    const ssize_t n = ::write(fd, bytes.constData() + written, size_t(bytes.size() - written));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) ok = false;
    else written += n;
  }
  // The umask narrowed the mode it was created with.
  if (ok) ok = ::fchmod(fd, mode) == 0;
  if (::close(fd) != 0) ok = false;
  if (!ok) ::unlink(native(path).constData());
  return ok;
}
#endif

QString uuid() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

// A tool's run, bounded: true when it exited 0; `output` is its stdout.
bool run(const QString& program, const QStringList& arguments, QByteArray* output = nullptr) {
  QProcess process;
  process.setProcessChannelMode(QProcess::SeparateChannels);
  process.start(program, arguments);
  if (!process.waitForStarted(5000)) return false;
  if (!process.waitForFinished(5000)) {
    process.kill();
    process.waitForFinished(1000);
    return false;
  }
  const QByteArray out = process.readAllStandardOutput();
  if (out.size() > kMaxBytes) return false;
  if (output) *output = out;
  return process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
}

}  // namespace

// --- Keys and bindings ------------------------------------------------------------

std::optional<CaptureShortcutConfig::Keys> CaptureShortcutConfig::keys(const QString& input, QString* error) {
  static const QRegularExpression key(QStringLiteral("^(?:[a-z0-9]|f(?:[1-9]|1[0-9]|2[0-4]))$"));
  const QString refused = QStringLiteral("Choose a letter, number, or function key with Ctrl, Alt, or Super.");
  const QStringList parts = (input.isEmpty() ? QStringLiteral("Ctrl+Shift+2") : input).trimmed().split(u'+');
  bool ctrl = false, alt = false, shift = false, meta = false, bad = false;
  for (qsizetype i = 0; i + 1 < parts.size(); ++i) {
    const QString part = parts[i].trimmed().toLower();
    if (part == u"ctrl" || part == u"control") ctrl = true;
    else if (part == u"alt" || part == u"option") alt = true;
    else if (part == u"shift") shift = true;
    else if (part == u"super" || part == u"meta" || part == u"cmd" || part == u"win") meta = true;
    else bad = true;  // mod, or a word no compositor takes
  }
  const QString name = parts.last().trimmed().toLower();
  if (bad || !key.match(name).hasMatch() || !(ctrl || alt || meta)) {
    *error = refused;
    return std::nullopt;
  }
  QStringList modifiers;
  if (ctrl) modifiers.append(QStringLiteral("Ctrl"));
  if (alt) modifiers.append(QStringLiteral("Alt"));
  if (shift) modifiers.append(QStringLiteral("Shift"));
  if (meta) modifiers.append(QStringLiteral("Super"));
  return Keys{(modifiers + QStringList{name.toUpper()}).join(u'+'), modifiers.join(u' ').toUpper(), name.toUpper(),
              (shift ? 1 : 0) | (ctrl ? 4 : 0) | (alt ? 8 : 0) | (meta ? 64 : 0)};
}

QString CaptureShortcutConfig::niriBinding(const QString& appId) {
  return QStringLiteral(
             "Ctrl+Shift+2 repeat=false { spawn \"gdbus\" \"call\" \"--session\" \"--dest\" \"%1.SnapShot\" \"--object-path\" \"%2\" "
             "\"--method\" \"%3.Capture\"; }")
      .arg(appId, kNiriPath, kNiriInterface);
}

QString CaptureShortcutConfig::binding(Format format, const QString& appId, const QString& keys) {
  QString ignored;
  const auto chord = CaptureShortcutConfig::keys(keys, &ignored);
  if (!chord) return {};
  if (format == Format::Niri) return niriBinding(appId).replace(QStringLiteral("Ctrl+Shift+2"), chord->label);
  const QString action = appId + QStringLiteral(":capture-window");
  if (format == Format::HyprlandLua) {
    return QStringLiteral("hl.bind(\"%1\", hl.dsp.global(\"%2\"))").arg(chord->label.toUpper().replace(u'+', QStringLiteral(" + ")), action);
  }
  return QStringLiteral("bind = %1, %2, global, %3").arg(chord->modifiers, chord->key, action);
}

QString CaptureShortcutConfig::home(const QProcessEnvironment& env) {
  const QString home = env.value(QStringLiteral("HOME"));
  return home.isEmpty() ? QDir::homePath() : home;
}

static QString configHome(const QProcessEnvironment& env) {
  const QString xdg = env.value(QStringLiteral("XDG_CONFIG_HOME"));
  return xdg.isEmpty() ? CaptureShortcutConfig::home(env) + QStringLiteral("/.config") : xdg;
}

QString CaptureShortcutConfig::niriConfigPath(const QProcessEnvironment& env) {
  const QString configured = env.value(QStringLiteral("NIRI_CONFIG"));
  return configured.isEmpty() ? configHome(env) + QStringLiteral("/niri/config.kdl") : configured;
}

QString CaptureShortcutConfig::hyprlandConfigPath(const QProcessEnvironment& env) {
  const QString directory = configHome(env) + QStringLiteral("/hypr/");
  const auto choose = [&](const QString& bindings, const QString& main) {
    return QFileInfo::exists(directory + bindings) ? directory + bindings : directory + main;
  };
  if (QFileInfo::exists(directory + QStringLiteral("hyprland.lua"))) return choose(QStringLiteral("bindings.lua"), QStringLiteral("hyprland.lua"));
  return choose(QStringLiteral("bindings.conf"), QStringLiteral("hyprland.conf"));
}

std::optional<CaptureShortcutConfig::Edit> CaptureShortcutConfig::edit(const QString& source, Format format, const QString& appId,
                                                                        bool install, const QString& requested, QString* error) {
  static const QRegularExpression returns(QStringLiteral("^\\s*return\\b"), QRegularExpression::MultilineOption);
  static const QRegularExpression longString(QStringLiteral("\\[=*\\["));
  static const QRegularExpression validId(QStringLiteral("^[A-Za-z0-9_.-]+$"));
  if (!validId.match(appId).hasMatch()) {
    *error = QStringLiteral("Invalid capture application ID.");
    return std::nullopt;
  }
  if (format == Format::HyprlandLua && (returns.match(source).hasMatch() || longString.match(source).hasMatch())) {
    *error = QStringLiteral("This Lua config needs a manual edit. Choose your bindings file or use manual setup in Advanced.");
    return std::nullopt;
  }
  const bool niri = format == Format::Niri;
  QList<Range> existing;
  if (niri) {
    std::optional<Node> block;
    if (!niriBinds(source, &block, error)) return std::nullopt;
    if (block) {
      for (const Node& node : block->children) {
        if (niriCaptureNode(node, appId)) existing.append({node.start, node.end, node.name, {}});
      }
    }
  } else {
    for (const Range& bind : hyprlandBinds(source, format == Format::HyprlandLua)) {
      if (bind.action == appId + QStringLiteral(":capture-window")) existing.append(bind);
    }
  }
  const auto chord = keys(!requested.isEmpty() ? requested : existing.isEmpty() ? QString() : existing.first().keys, error);
  if (!chord) return std::nullopt;
  const QString label = chord->label;
  if (install && existing.size() == 1 && sameKeys(existing.first().keys, label)) return Edit{source, label};
  QString after = removeRanges(source, existing);
  if (!install) return Edit{after, label};
  bool conflict = false;
  if (niri) {
    const auto found = niriConflict(after, appId, label, error);
    if (!found) return std::nullopt;
    conflict = *found;
  } else {
    for (const Range& bind : hyprlandBinds(after, false)) conflict = conflict || sameKeys(bind.keys, label);
  }
  if (conflict) {
    *error = QStringLiteral("%1 is already used in this config. Choose another shortcut.").arg(label);
    return std::nullopt;
  }
  const QString newline = source.contains(QStringLiteral("\r\n")) ? QStringLiteral("\r\n") : QStringLiteral("\n");
  const QString line = binding(format, appId, label);
  const QString separator = !after.isEmpty() && !after.endsWith(u'\n') ? newline : QString();
  if (niri) {
    std::optional<Node> block;
    if (!niriBinds(after, &block, error)) return std::nullopt;
    if (block && block->close) {
      const qsizetype close = *block->close;
      const qsizetype lineStart = close > 0 ? after.lastIndexOf(u'\n', close - 1) + 1 : 0;
      const QString indent = after.mid(lineStart, close - lineStart);
      if (indent.trimmed().isEmpty()) {
        after = after.left(lineStart) + indent + QStringLiteral("    ") + line + newline + after.mid(lineStart);
      } else {
        after = after.left(close) + newline + QStringLiteral("    ") + line + newline + after.mid(close);
      }
    } else {
      after += separator + newline + QStringLiteral("binds {") + newline + QStringLiteral("    ") + line + newline + u'}' + newline;
    }
    if (!readKdl(after, error)) return std::nullopt;
  } else {
    // Never inside a Lua block or string, nor after an early return: at the end.
    after += separator + newline + line + newline;
  }
  return Edit{after, label};
}

// --- Review and save --------------------------------------------------------------

CaptureShortcutConfig::Tools CaptureShortcutConfig::systemTools() {
  Tools tools;
  tools.validateNiri = [](const QString& path) { return run(QStringLiteral("niri"), {QStringLiteral("validate"), QStringLiteral("--config"), path}); };
  tools.hyprlandBindings = []() -> std::optional<QList<HyprlandBind>> {
    QByteArray output;
    if (!run(QStringLiteral("hyprctl"), {QStringLiteral("-j"), QStringLiteral("binds")}, &output)) return std::nullopt;
    QJsonParseError parsed;
    const QJsonDocument document = QJsonDocument::fromJson(output, &parsed);
    if (parsed.error != QJsonParseError::NoError || !document.isArray()) return std::nullopt;
    QList<HyprlandBind> binds;
    for (const QJsonValue& value : document.array()) {
      const QJsonObject bind = value.toObject();
      if (!bind.value(QLatin1String("modmask")).isDouble() || !bind.value(QLatin1String("key")).isString() ||
          !bind.value(QLatin1String("dispatcher")).isString() || !bind.value(QLatin1String("arg")).isString()) {
        return std::nullopt;
      }
      binds.append({bind.value(QLatin1String("modmask")).toInt(), bind.value(QLatin1String("key")).toString(),
                    bind.value(QLatin1String("dispatcher")).toString(), bind.value(QLatin1String("arg")).toString()});
    }
    return binds;
  };
  tools.reloadHyprland = []() -> QString {
    QByteArray errors;
    if (!run(QStringLiteral("hyprctl"), {QStringLiteral("reload")})) {
      return QStringLiteral("Config saved, but Hyprland couldn't reload it. Run hyprctl reload.");
    }
    if (!run(QStringLiteral("hyprctl"), {QStringLiteral("configerrors")}, &errors) || !errors.trimmed().isEmpty()) {
      return QStringLiteral("Config saved, but Hyprland reported config errors. Check hyprctl configerrors, then run hyprctl reload.");
    }
    return {};
  };
  return tools;
}

CaptureShortcutConfig::CaptureShortcutConfig(QString home, Tools tools) : m_home(std::move(home)), m_tools(std::move(tools)) {}

CaptureShortcutConfig::~CaptureShortcutConfig() = default;

bool CaptureShortcutConfig::checkHyprlandKeys(const QString& appId, const QString& shortcut, QString* error) const {
  const auto chord = keys(shortcut, error);
  if (!chord) return false;
  const auto bindings = m_tools.hyprlandBindings ? m_tools.hyprlandBindings() : std::nullopt;
  if (!bindings) {
    *error = QStringLiteral("Couldn't check Hyprland's current shortcuts. Try again from your Hyprland session.");
    return false;
  }
  for (const HyprlandBind& bind : *bindings) {
    if (bind.modmask == chord->mask && bind.key.toUpper() == chord->key &&
        !(bind.dispatcher == u"global" && bind.arg == appId + QStringLiteral(":capture-window"))) {
      *error = QStringLiteral("%1 is already used by Hyprland. Choose another shortcut.").arg(chord->label);
      return false;
    }
  }
  return true;
}

std::optional<CaptureShortcutConfig::Preview> CaptureShortcutConfig::preview(const Target& target, bool install, const QString& requested,
                                                                              QString* error) {
  if (m_applying) {
    *error = QStringLiteral("Wait for the current config change to finish.");
    return std::nullopt;
  }
  m_pending.reset();
  bool missing = false;
  QString problem;
  auto root = readFile(target.path, &missing, &problem);
  if (!root) {
    // Too big or not text says so; anything else is the file that can't be read.
    *error = problem.isEmpty() ? QStringLiteral("Couldn't read your settings file. Choose a different file in Advanced.") : problem;
    return std::nullopt;
  }
#ifdef Q_OS_UNIX
  const bool ours = root->uid == uint(::getuid());
#else
  const bool ours = false;
#endif
  if (!ours || root->resolvedPath.contains(QStringLiteral("/omarchy/default/"))) {
    *error = QStringLiteral("Choose your own config, not system or Omarchy defaults.");
    return std::nullopt;
  }
  const bool niri = target.desktop == u"niri";
  const Format format = niri ? Format::Niri : target.path.endsWith(QStringLiteral(".lua")) ? Format::HyprlandLua : Format::Hyprland;
  const QString extension = niri ? QStringLiteral(".kdl") : format == Format::HyprlandLua ? QStringLiteral(".lua") : QStringLiteral(".conf");
  if (!target.path.endsWith(extension)) {
    *error = QStringLiteral("Choose a .kdl Niri config or a .conf/.lua Hyprland config.");
    return std::nullopt;
  }
  const auto edited = edit(root->text, format, target.appId, install, requested, error);
  if (!edited) return std::nullopt;
  // Lua binds show up in Hyprland as opaque callbacks, our own unchanged one too.
  const bool hyprlandKeys = install && (format == Format::Hyprland || (format == Format::HyprlandLua && edited->after != root->text));
  QList<File> files{*root};
  QStringList absent;
  if (niri) {
    // By value: the walk appends to `files`, which moves what they hold.
    const std::function<bool(File, int)> visit = [&](File file, int depth) {
      qint64 total = 0;
      for (const File& item : files) total += item.bytes.size();
      if (depth > 10 || files.size() > kMaxFiles || total > kMaxBytes) {
        *error = QStringLiteral("This config has too many included files. Use manual setup in Advanced.");
        return false;
      }
      const auto includes = niriIncludes(file.text, error);
      if (!includes) return false;
      static const QRegularExpression glob(QStringLiteral("[*?[\\]]"));
      for (const Include& include : *includes) {
        if (include.path.contains(u'$') || glob.match(include.path).hasMatch()) {
          *error = QStringLiteral("This config uses a dynamic include. Use manual setup in Advanced.");
          return false;
        }
        const QString path = include.path.startsWith(QStringLiteral("~/"))
                                 ? QDir::cleanPath(m_home + u'/' + include.path.mid(2))
                                 : QDir::cleanPath(QFileInfo(file.path).absoluteDir().absoluteFilePath(include.path));
        bool gone = false;
        QString ignored;
        const auto child = readFile(path, &gone, &ignored);
        if (!child) {
          if (include.optional && gone) {
            absent.append(path);
            continue;
          }
          *error = QStringLiteral("Couldn't read an included Niri config. Check its location in Advanced.");
          return false;
        }
        if (std::any_of(files.cbegin(), files.cend(), [&](const File& item) { return item.resolvedPath == child->resolvedPath; })) continue;
        files.append(*child);
        if (install) {
          const auto conflict = niriConflict(child->text, target.appId, edited->shortcut, error);
          if (!conflict) return false;
          if (*conflict) {
            *error = QStringLiteral("%1 is already used in %2. Choose another shortcut.").arg(edited->shortcut, child->path);
            return false;
          }
        }
        if (!visit(files.last(), depth + 1)) return false;
      }
      return true;
    };
    if (!visit(files.first(), 0)) return std::nullopt;
  } else if (hyprlandKeys && !checkHyprlandKeys(target.appId, edited->shortcut, error)) {
    return std::nullopt;
  }
  Preview preview{uuid(), root->path, root->resolvedPath, root->text, edited->after, edited->shortcut, install};
  m_pending = std::make_unique<Pending>(Pending{preview, target, files, absent, hyprlandKeys});
  return preview;
}

bool CaptureShortcutConfig::unchanged(const Pending& pending, QString* error) const {
  for (const QString& path : pending.missing) {
    if (exists(path)) {
      *error = QStringLiteral("Your config changed since this preview. Review changes again before saving.");
      return false;
    }
  }
  for (const File& original : pending.files) {
    bool missing = false;
    QString ignored;
    const auto current = readFile(original.path, &missing, &ignored);
    if (!current || current->resolvedPath != original.resolvedPath || current->inode != original.inode || current->mode != original.mode ||
        current->bytes != original.bytes) {
      *error = QStringLiteral("Your config changed since this preview. Nothing was saved. Review changes again before saving.");
      return false;
    }
  }
  return true;
}

std::optional<CaptureShortcutConfig::Applied> CaptureShortcutConfig::apply(const QString& id, const QString& desktop, QString* error) {
  if (m_applying || !m_pending || m_pending->preview.id != id || m_pending->target.desktop != desktop) {
    *error = QStringLiteral("This preview expired. Review changes again before saving.");
    return std::nullopt;
  }
  const Pending pending = *std::exchange(m_pending, nullptr);
  m_applying = true;
  const struct Done {
    bool& applying;
    ~Done() { applying = false; }
  } done{m_applying};
  const Preview& preview = pending.preview;
  const File& root = pending.files.first();
  if (!unchanged(pending, error)) return std::nullopt;
  if (pending.checkHyprlandKeys && !checkHyprlandKeys(pending.target.appId, preview.shortcut, error)) return std::nullopt;
  if (preview.before == preview.after) return Applied{};
#ifdef Q_OS_UNIX
  const QString directory = QFileInfo(root.resolvedPath).absolutePath();
  const QString name = QStringLiteral(".hal-c2-capture-%1.tmp").arg(uuid());
  const QString temporary = directory + u'/' + name;
  const mode_t mode = root.mode & 0777;
  const QString failedWrite = QStringLiteral("Couldn't write your config. Nothing was changed.");
  if (!writeNew(temporary, preview.after.toUtf8(), mode)) {
    *error = failedWrite;
    return std::nullopt;
  }
  bool staged = true;
  const struct Unstage {
    const QString& path;
    bool& staged;
    ~Unstage() {
      if (staged) ::unlink(native(path).constData());
    }
  } unstage{temporary, staged};
  if (desktop == u"niri") {
    // Niri resolves includes against the selected path, not a dotfile link's target.
    const QString validation = QFileInfo(root.path).absolutePath() + u'/' + name;
    bool valid = false;
    if (QDir::cleanPath(validation) == QDir::cleanPath(temporary)) {
      valid = m_tools.validateNiri && m_tools.validateNiri(temporary);
    } else if (::symlink(native(temporary).constData(), native(validation).constData()) == 0) {
      valid = m_tools.validateNiri && m_tools.validateNiri(validation);
      ::unlink(native(validation).constData());
    }
    if (!valid) {
      *error = QStringLiteral("Niri couldn't validate the proposed config. Nothing was changed. Check your config in Advanced.");
      return std::nullopt;
    }
  }
  if (!unchanged(pending, error)) return std::nullopt;
  const QString backup = QStringLiteral("%1.hal-c2-capture-backup-%2").arg(root.resolvedPath, uuid());
  if (!writeNew(backup, root.bytes, 0600) || ::rename(native(temporary).constData(), native(root.resolvedPath).constData()) != 0) {
    *error = failedWrite;
    return std::nullopt;
  }
  staged = false;
  Applied applied{backup, {}};
  if (desktop == u"hyprland" && m_tools.reloadHyprland) applied.warning = m_tools.reloadHyprland();
  return applied;
#else
  *error = QStringLiteral("Config setup requires a Niri or Hyprland session.");
  return std::nullopt;
#endif
}
