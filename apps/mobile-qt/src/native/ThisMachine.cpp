#include "ThisMachine.h"

#include <QCryptographicHash>
#include <QHostAddress>
#include <QSysInfo>

#include "McClient.h"
#include "ShellStore.h"

namespace thisMachine {

namespace {

std::optional<QString>& pinned() {
  static std::optional<QString> id;
  return id;
}

}  // namespace

QString id() {
  if (pinned()) return *pinned();
  // As the MC hashes it (apps/server-ex lib/hal_c2/environment/machine.ex).
  static const QString hashed = [] {
    const QByteArray raw = QSysInfo::machineUniqueId();
    return raw.isEmpty() ? QString() : QString::fromLatin1(QCryptographicHash::hash(raw, QCryptographicHash::Sha256).toHex());
  }();
  return hashed;
}

void setIdForTesting(const std::optional<QString>& id) {
  pinned() = id;
}

bool loopbackHost(const QString& host) {
  return host.compare(QLatin1String("localhost"), Qt::CaseInsensitive) == 0 || QHostAddress(host).isLoopback();
}

bool hosts(const QJsonObject& descriptor, bool own, const QUrl& origin) {
  // Not described yet (the shell snapshot is on its way): nothing says it is here.
  if (descriptor.isEmpty()) return false;
  const QString theirs = descriptor.value(QLatin1String("platform")).toObject().value(QLatin1String("machineId")).toString();
  const QString ours = id();
  if (!theirs.isEmpty() && !ours.isEmpty()) return theirs == ours;
  return own && loopbackHost(origin.host());
}

bool hosts(const ShellStore& store, const McClient& client, const QString& environmentId) {
  return hosts(store.environment(environmentId), environmentId == client.environment(), client.origin());
}

}  // namespace thisMachine
