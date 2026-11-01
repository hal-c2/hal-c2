#pragma once

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <functional>
#include <optional>

// Bringing the cluster's servers up to this app's version, without the shell
// around it: ServerUpdateController feeds it the machines and carries out its
// effects. A server behind the app is updated by the path its descriptor
// offers (`capabilities.serverSelfUpdate`):
//
//   update          it updates itself (`server.updateServer`)
//   desktop         a desktop app runs it and this client can have that app
//                   update (`desktopAppUpdate`); the app closes and relaunches
//                   on its machine, so the user confirms first
//   desktop-manual  a desktop app runs it and only that machine can update it
//   command         it was started by hand: the user runs a command there
//
// One update per server runs at a time; Update all starts every server that
// can update from here at once, each reporting for itself, and asks once
// before any desktop app relaunches.
class ServerUpdates {
public:
  struct Machine {
    QString id;
    QString label;
    QString version;
    // `serverSelfUpdate`, empty when the server cannot update itself.
    QString selfUpdate;
    bool desktopAppUpdate = false;
    bool online = true;
  };

  // How a call ended: the version the server answered with, or why it failed.
  struct Reply {
    bool ok = false;
    QString targetVersion;
    QString error;
  };
  using Done = std::function<void(const Reply& reply)>;

  struct Effects {
    // `server.updateServer {targetVersion}` on the environment; `done` once it answers.
    std::function<void(const QString& environmentId, const QString& targetVersion, Done done)> call;
    // Asks; `accepted` runs on yes only.
    std::function<void(const QString& title, const QString& description, std::function<void()> accepted)> confirm;
    std::function<void(const QString& type, const QString& title, const QString& description)> toast;
    // False when the clipboard could not be written.
    std::function<bool(const QString& text)> copy;
  };

  explicit ServerUpdates(Effects effects) : m_effects(std::move(effects)) {}

  void setAppVersion(const QString& version) { m_appVersion = version.trimmed(); }
  QString appVersion() const { return m_appVersion; }
  void setMachines(const QList<Machine>& machines) { m_machines = machines; }
  QList<Machine> machines() const { return m_machines; }

  // update, desktop, desktop-manual or command.
  static QString path(const Machine& machine);
  // The command that updates a server started by hand.
  static QString command(const QString& targetVersion) { return QStringLiteral("npx hal-c2@") + targetVersion; }

  bool behind(const Machine& machine) const;
  bool updating(const QString& environmentId) const { return m_updating.contains(environmentId); }
  // The servers Update all reaches now: online, behind, updatable from here
  // and not already updating.
  QList<Machine> updatable() const;

  // The user chose the offer for `environmentId`: updates it, asks first for a
  // desktop app, or copies the command. Nothing for a server not behind, one
  // already updating, or one only its own machine can update.
  void update(const QString& environmentId);
  void updateAll();
  void copyCommand(const QString& environmentId);

  // `serverUpdates`: {appVersion, machines: [{environmentId, label, version,
  // online, behind, path, command, updating}], updatable}.
  QVariantMap state() const;

private:
  std::optional<Machine> find(const QString& environmentId) const;
  void run(const Machine& machine, const QString& failureTitle);

  Effects m_effects;
  QString m_appVersion;
  QList<Machine> m_machines;
  QHash<QString, bool> m_updating;
};
