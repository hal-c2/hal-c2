#include "ShellBridge.h"

#include <QDesktopServices>
#include <QFile>
#include <QFileInfo>
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
