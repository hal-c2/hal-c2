#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

#include <optional>

// A checkout's hal-c2.json (packages/contracts halC2ProjectFile.ts), read as
// JSON that may carry comments and trailing commas, and that either matches
// the format or is no file at all.
namespace projectfile {

inline const QString kName = QStringLiteral("hal-c2.json");

struct Script {
  QString name;
  QString command;
  QString icon = QStringLiteral("play");
  bool runOnWorktreeCreate = false;
  std::optional<bool> async;
  QString previewUrl;
  bool autoOpenPreview = false;
};

struct File {
  QList<Script> scripts;
  // "local" or "worktree"; empty when the file does not say.
  QString defaultThreadEnvMode;
};

// The file, or nothing when it is not valid JSON or does not match the format.
std::optional<File> parse(const QString& contents);

// ProjectScriptIcon.
const QStringList& icons();

}  // namespace projectfile
