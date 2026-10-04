#include "SingleInstance.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>

namespace {

constexpr int kTimeoutMs = 1000;

}  // namespace

SingleInstance::SingleInstance(const QString& stateDir, QObject* parent) : QObject(parent), m_name(address(stateDir)) {}

QString SingleInstance::address(const QString& stateDir, const QProcessEnvironment& env, bool windows) {
  const QString name = serverName(stateDir);
  if (windows) return name;
  // Only an absolute XDG_RUNTIME_DIR counts, as for the other XDG variables.
  const QString runtime = env.value(QStringLiteral("XDG_RUNTIME_DIR")).trimmed();
  const QString dir = QDir::isAbsolutePath(runtime) ? QDir(runtime).filePath(QStringLiteral("hal-c2")) : QDir(stateDir).absolutePath();
  const QString path = QDir(dir).filePath(name);
  // sockaddr_un holds about a hundred bytes.
  return path.toUtf8().size() < 100 ? path : name;
}

QString SingleInstance::address(const QString& stateDir) {
#ifdef Q_OS_WIN
  const bool windows = true;
#else
  const bool windows = false;
#endif
  return address(stateDir, QProcessEnvironment::systemEnvironment(), windows);
}

// Short and unique per home: socket paths are length-limited.
QString SingleInstance::serverName(const QString& stateDir) {
  const QByteArray digest = QCryptographicHash::hash(QDir(stateDir).absolutePath().toUtf8(), QCryptographicHash::Sha1).toHex();
  return QStringLiteral("hal-c2-qt-") + QString::fromLatin1(digest.left(16));
}

bool SingleInstance::forward(const QString& stateDir, const QStringList& folders) {
  QLocalSocket socket;
  socket.connectToServer(address(stateDir));
  if (!socket.waitForConnected(kTimeoutMs)) return false;
  socket.write(QJsonDocument(QJsonObject{{QStringLiteral("open"), QJsonArray::fromStringList(folders)}}).toJson(QJsonDocument::Compact) + '\n');
  // The running app answers once it has the line.
  return socket.waitForBytesWritten(kTimeoutMs) && socket.waitForReadyRead(kTimeoutMs) && socket.readLine().trimmed() == "ok";
}

bool SingleInstance::listen(std::function<void(const QStringList&)> open) {
  // A socket left by a run that crashed is in the way; one that answers is
  // another app, and forward() would have reached it.
  QLocalServer::removeServer(m_name);
  if (QDir::isAbsolutePath(m_name)) QDir().mkpath(QFileInfo(m_name).absolutePath());
  connect(&m_server, &QLocalServer::newConnection, this, [this, open = std::move(open)] {
    while (QLocalSocket* socket = m_server.nextPendingConnection()) {
      connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
      connect(socket, &QLocalSocket::readyRead, socket, [socket, open] {
        if (!socket->canReadLine()) return;
        QStringList folders;
        for (const QJsonValue& folder : QJsonDocument::fromJson(socket->readLine()).object().value(QLatin1String("open")).toArray()) {
          folders.append(folder.toString());
        }
        socket->write("ok\n");
        socket->flush();
        open(folders);
      });
    }
  });
  return m_server.listen(m_name);
}
