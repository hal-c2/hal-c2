#include "SingleInstance.h"

#include <QCryptographicHash>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>

namespace {

constexpr int kTimeoutMs = 1000;

}  // namespace

SingleInstance::SingleInstance(const QString& stateDir, QObject* parent) : QObject(parent), m_name(serverName(stateDir)) {}

// Short and unique per home: socket paths are length-limited.
QString SingleInstance::serverName(const QString& stateDir) {
  const QByteArray digest = QCryptographicHash::hash(QDir(stateDir).absolutePath().toUtf8(), QCryptographicHash::Sha1).toHex();
  return QStringLiteral("hal-c2-qt-") + QString::fromLatin1(digest.left(16));
}

bool SingleInstance::forward(const QString& stateDir, const QStringList& folders) {
  QLocalSocket socket;
  socket.connectToServer(serverName(stateDir));
  if (!socket.waitForConnected(kTimeoutMs)) return false;
  socket.write(QJsonDocument(QJsonObject{{QStringLiteral("open"), QJsonArray::fromStringList(folders)}}).toJson(QJsonDocument::Compact) + '\n');
  // The running app answers once it has the line.
  return socket.waitForBytesWritten(kTimeoutMs) && socket.waitForReadyRead(kTimeoutMs) && socket.readLine().trimmed() == "ok";
}

bool SingleInstance::listen(std::function<void(const QStringList&)> open) {
  // A socket left by a run that crashed is in the way; one that answers is
  // another app, and forward() would have reached it.
  QLocalServer::removeServer(m_name);
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
