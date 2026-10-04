#include "ProjectFile.h"

#include <QJsonArray>
#include <QJsonDocument>

namespace projectfile {

namespace {

constexpr int kMaxScripts = 50;
constexpr int kMaxPath = 512;

// The text without `//` and `/* */` comments and without commas that end an
// object or array, leaving strings as they are.
QString strict(const QString& text) {
  QString out;
  out.reserve(text.size());
  bool inString = false;
  for (qsizetype i = 0; i < text.size(); ++i) {
    const QChar c = text.at(i);
    if (inString) {
      out += c;
      if (c == u'\\' && i + 1 < text.size()) {
        out += text.at(++i);
      } else if (c == u'"') {
        inString = false;
      }
      continue;
    }
    if (c == u'"') {
      inString = true;
      out += c;
    } else if (c == u'/' && i + 1 < text.size() && text.at(i + 1) == u'/') {
      while (i < text.size() && text.at(i) != u'\n') ++i;
      out += u'\n';
    } else if (c == u'/' && i + 1 < text.size() && text.at(i + 1) == u'*') {
      const qsizetype end = text.indexOf(QLatin1String("*/"), i + 2);
      i = end < 0 ? text.size() : end + 1;
      out += u' ';
    } else if (c == u',') {
      qsizetype next = i + 1;
      while (next < text.size()) {
        if (text.at(next).isSpace()) {
          ++next;
        } else if (text.mid(next, 2) == QLatin1String("//")) {
          while (next < text.size() && text.at(next) != u'\n') ++next;
        } else if (text.mid(next, 2) == QLatin1String("/*")) {
          const qsizetype end = text.indexOf(QLatin1String("*/"), next + 2);
          next = end < 0 ? text.size() : end + 2;
        } else {
          break;
        }
      }
      if (next >= text.size() || (text.at(next) != u'}' && text.at(next) != u']')) out += c;
    } else {
      out += c;
    }
  }
  return out;
}

// A string field trimmed: nothing when it is there and not a non-empty string.
std::optional<QString> trimmed(const QJsonObject& object, const QString& key, bool required, int maxLength = 0) {
  if (!object.contains(key)) return required ? std::nullopt : std::optional<QString>(QString());
  if (!object.value(key).isString()) return std::nullopt;
  const QString raw = object.value(key).toString();
  if (raw.isEmpty() || (maxLength > 0 && raw.size() > maxLength)) return std::nullopt;
  const QString value = raw.trimmed();
  if (value.isEmpty()) return std::nullopt;
  return value;
}

bool optionalBool(const QJsonObject& object, const QString& key) {
  return !object.contains(key) || object.value(key).isBool();
}

}  // namespace

const QStringList& icons() {
  static const QStringList list{QStringLiteral("play"), QStringLiteral("test"), QStringLiteral("lint"),
                                QStringLiteral("configure"), QStringLiteral("build"), QStringLiteral("debug")};
  return list;
}

std::optional<File> parse(const QString& contents) {
  QJsonParseError error;
  const QJsonDocument document = QJsonDocument::fromJson(strict(contents).toUtf8(), &error);
  if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
  const QJsonObject root = document.object();
  File file;
  if (root.contains(QLatin1String("$schema")) && !root.value(QLatin1String("$schema")).isString()) return std::nullopt;
  if (!trimmed(root, QStringLiteral("iconPath"), false, kMaxPath)) return std::nullopt;
  if (root.contains(QLatin1String("defaultThreadEnvMode"))) {
    file.defaultThreadEnvMode = root.value(QLatin1String("defaultThreadEnvMode")).toString();
    if (file.defaultThreadEnvMode != QLatin1String("local") && file.defaultThreadEnvMode != QLatin1String("worktree")) return std::nullopt;
  }
  if (root.contains(QLatin1String("worktreeSubmodules"))) {
    static const QStringList modes{QStringLiteral("recursive"), QStringLiteral("top-level"), QStringLiteral("none")};
    if (!modes.contains(root.value(QLatin1String("worktreeSubmodules")).toString())) return std::nullopt;
  }
  if (root.contains(QLatin1String("scripts"))) {
    if (!root.value(QLatin1String("scripts")).isArray()) return std::nullopt;
    const QJsonArray scripts = root.value(QLatin1String("scripts")).toArray();
    if (scripts.size() > kMaxScripts) return std::nullopt;
    for (const QJsonValue& value : scripts) {
      if (!value.isObject()) return std::nullopt;
      const QJsonObject entry = value.toObject();
      const std::optional<QString> name = trimmed(entry, QStringLiteral("name"), true);
      const std::optional<QString> command = trimmed(entry, QStringLiteral("command"), true);
      const std::optional<QString> previewUrl = trimmed(entry, QStringLiteral("previewUrl"), false);
      if (!name || !command || !previewUrl) return std::nullopt;
      Script script{*name, *command};
      if (entry.contains(QLatin1String("icon"))) {
        script.icon = entry.value(QLatin1String("icon")).toString();
        if (!icons().contains(script.icon)) return std::nullopt;
      }
      for (const QString& flag : {QStringLiteral("runOnWorktreeCreate"), QStringLiteral("async"), QStringLiteral("autoOpenPreview")}) {
        if (!optionalBool(entry, flag)) return std::nullopt;
      }
      script.runOnWorktreeCreate = entry.value(QLatin1String("runOnWorktreeCreate")).toBool();
      if (entry.contains(QLatin1String("async"))) script.async = entry.value(QLatin1String("async")).toBool();
      script.previewUrl = *previewUrl;
      script.autoOpenPreview = entry.value(QLatin1String("autoOpenPreview")).toBool();
      file.scripts.append(script);
    }
  }
  return file;
}

}  // namespace projectfile
