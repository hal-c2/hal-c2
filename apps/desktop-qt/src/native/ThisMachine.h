#pragma once

#include <QJsonObject>
#include <QString>
#include <QUrl>

#include <optional>

class McClient;
class ShellStore;

// Which environments run on the machine the user sits at. Only there may the
// shell start an editor or a file manager, or read a folder by its path:
// anything else would start on, or point into, a computer nobody is looking at.
namespace thisMachine {

// The lowercase hex SHA-256 of QSysInfo::machineUniqueId(): what an MC on
// this machine serves as `platform.machineId`. Empty when this machine has none.
QString id();
// Pins id() (tests); nullopt goes back to this machine's own.
void setIdForTesting(const std::optional<QString>& id);

// Whether `host` names this machine's loopback: localhost, all of 127.0.0.0/8, ::1.
bool loopbackHost(const QString& host);

// Whether the environment `descriptor` describes runs here: its
// `platform.machineId` is id(). Without an id on both sides it is the MC the
// shell is connected to (`own`), reached on loopback at `origin`. A loopback
// origin alone is not enough when ids are known: an SSH port forward is
// loopback too.
bool hosts(const QJsonObject& descriptor, bool own, const QUrl& origin);
// The same for an environment of the cluster the shell is connected to.
bool hosts(const ShellStore& store, const McClient& client, const QString& environmentId);

}  // namespace thisMachine
