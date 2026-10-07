#include "ShellBridge.h"

#include <algorithm>

#include <QBuffer>
#include <QClipboard>
#include <QGuiApplication>
#include <QDesktopServices>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QMimeData>
#include <QMimeDatabase>
#include <QtLogging>

namespace {

// The keys the bricks read that a bridge without NativeShell's controllers
// (which declare their own, NativeControllerRegistrar) may still publish:
// main.cpp's `backendError`, SidebarController's `sidebar`, and the ones the
// default layout binds.
constexpr const char* kStateKeys[] = {
    "backendError", "composer", "git", "layout", "modelPicker", "sidebar", "theme", "workspace",
};

// Qt 6.11 deprecates the public constructor in favour of create(); the
// minimum supported Qt (6.9) only has the constructor.
QQmlPropertyMap* createStateMap(QObject* parent) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 11, 0)
  return QQmlPropertyMap::create(parent);
#else
  return new QQmlPropertyMap(parent);
#endif
}

}  // namespace

ShellBridge::ShellBridge(QObject* parent)
    : QObject(parent), m_state(createStateMap(this)) {
  for (const char* key : kStateKeys) {
    m_state->insert(QString::fromLatin1(key), QVariant());
  }
}

void ShellBridge::declareKey(const QString& key) {
  if (!m_state->contains(key)) m_state->insert(key, QVariant());
}

void ShellBridge::publish(const QString& key, const QVariant& value) {
  // An unchanged republish would re-evaluate every binding on the key for
  // nothing.
  if (m_state->contains(key) && m_state->value(key) == value) {
    return;
  }
  m_state->insert(key, value);
  emit stateEntryChanged(key, value);
}

void ShellBridge::openExternal(const QUrl& url) {
  const auto scheme = url.scheme();
  // The app's own links open in the app.
  if (scheme == QLatin1String("hal-c2")) {
    dispatch(QStringLiteral("link.open"), QVariantMap{{QStringLiteral("url"), url.toString()}});
    return;
  }
  if (scheme != QStringLiteral("http") && scheme != QStringLiteral("https") &&
      scheme != QStringLiteral("mailto")) {
    return;
  }
  if (m_openUrl) {
    m_openUrl(url);
  } else {
    QDesktopServices::openUrl(url);
  }
}

void ShellBridge::windowCommand(const QString& command) {
  emit windowCommandRequested(command);
}

void ShellBridge::dispatch(const QString& action, const QVariant& payload) {
  for (const Interceptor& interceptor : std::as_const(m_interceptors)) {
    if (interceptor(action, payload)) return;
  }
  emit actionRequested(action, payload);
}

bool ShellBridge::localFolders() const {
  const auto host = m_mcOrigin.host().toLower();
  return m_localFolderImportEnabled && (host == QStringLiteral("localhost") || host == QStringLiteral("127.0.0.1") ||
                                        host == QStringLiteral("::1"));
}

QString ShellBridge::localDirectoryPath(const QUrl& url) const {
  if (!localFolders() || !url.isLocalFile() || !url.host().isEmpty()) {
    return {};
  }
  const QFileInfo directory(url.toLocalFile());
  return directory.isDir() ? directory.canonicalFilePath() : QString();
}

QVariantList ShellBridge::readAttachmentFiles(const QList<QUrl>& urls) const {
  constexpr qint64 kMaxFileBytes = 50 * 1024 * 1024;
  QMimeDatabase mimeDatabase;
  QVariantList result;
  for (const QUrl& url : urls) {
    const QFileInfo info(url.toLocalFile());
    if (!url.isLocalFile() || !info.isFile()) continue;
    const QMimeType mime = mimeDatabase.mimeTypeForFile(info.filePath());
    if (mime.name().startsWith(QStringLiteral("image/"))) {
      result.append(readImageFiles({url}));
      continue;
    }
    if (info.size() < 1 || info.size() > kMaxFileBytes) {
      qInfo().noquote() << "[shell] skipping attachment (empty or too large)" << info.filePath();
      continue;
    }
    result.append(QVariantMap{
        {QStringLiteral("name"), info.fileName()},
        {QStringLiteral("mimeType"), mime.name()},
        {QStringLiteral("path"), info.absoluteFilePath()},
    });
  }
  return result;
}

QStringList ShellBridge::directoryPaths(const QList<QUrl>& urls) const {
  QStringList paths;
  for (const QUrl& url : urls) {
    const QFileInfo info(url.toLocalFile());
    if (url.isLocalFile() && info.isDir()) paths.append(info.absoluteFilePath());
  }
  return paths;
}

QString ShellBridge::clipboardText() const {
  return QGuiApplication::clipboard()->text();
}

QVariantList ShellBridge::clipboardFiles() const {
  constexpr qsizetype kMaxBytes = 10 * 1024 * 1024;
  const QMimeData* data = QGuiApplication::clipboard()->mimeData();
  if (!data) return {};
  if (const QVariantList files = readAttachmentFiles(data->urls()); !files.isEmpty()) {
    const bool picture = std::any_of(files.cbegin(), files.cend(), [](const QVariant& file) {
      return file.toMap().value(QStringLiteral("mimeType")).toString().startsWith(QStringLiteral("image/"));
    });
    // File managers put the copied files' addresses or paths on the clipboard
    // as text too; that is no text to paste instead.
    QStringList names;
    for (const QUrl& url : data->urls()) names << url.toString() << url.toString(QUrl::FullyEncoded) << url.toLocalFile();
    const QStringList lines = data->text().split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    const bool onlyNames = std::all_of(lines.cbegin(), lines.cend(), [&](const QString& line) {
      return line.trimmed().isEmpty() || names.contains(line.trimmed());
    });
    return picture || onlyNames ? files : QVariantList{};
  }
  if (!data->hasImage()) return {};
  QByteArray png;
  QBuffer buffer(&png);
  buffer.open(QIODevice::WriteOnly);
  if (!qvariant_cast<QImage>(data->imageData()).save(&buffer, "PNG") || png.size() > kMaxBytes) {
    qInfo().noquote() << "[shell] skipping pasted image (too large or unreadable)";
    return {};
  }
  return {QVariantMap{
      {QStringLiteral("name"), QStringLiteral("image.png")},
      {QStringLiteral("mimeType"), QStringLiteral("image/png")},
      {QStringLiteral("base64"), QString::fromLatin1(png.toBase64())},
  }};
}

bool ShellBridge::pasteAttaches(const QString& text, int promptLength) const {
  constexpr qsizetype kThresholdBytes = 32 * 1024;
  constexpr qsizetype kMaxPromptChars = 120000;
  return !text.isEmpty() && (text.toUtf8().size() >= kThresholdBytes || promptLength + text.size() > kMaxPromptChars);
}

QVariantList ShellBridge::readImageFiles(const QList<QUrl>& urls) const {
  constexpr qint64 kMaxBytes = 10 * 1024 * 1024;
  QMimeDatabase mimeDatabase;
  QVariantList result;
  for (const QUrl& url : urls) {
    if (!url.isLocalFile()) {
      continue;
    }
    const QString path = url.toLocalFile();
    const QMimeType mime = mimeDatabase.mimeTypeForFile(path);
    if (!mime.name().startsWith(QStringLiteral("image/"))) {
      qInfo().noquote() << "[shell] skipping non-image attachment" << path;
      continue;
    }
    QFile file(path);
    if (file.size() > kMaxBytes || !file.open(QIODevice::ReadOnly)) {
      qInfo().noquote() << "[shell] skipping attachment (too large or unreadable)" << path;
      continue;
    }
    result.append(QVariantMap{
        {QStringLiteral("name"), QFileInfo(path).fileName()},
        {QStringLiteral("mimeType"), mime.name()},
        {QStringLiteral("base64"), QString::fromLatin1(file.readAll().toBase64())},
    });
  }
  return result;
}
