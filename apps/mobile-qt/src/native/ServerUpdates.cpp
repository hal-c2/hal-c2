#include "ServerUpdates.h"

#include <QCoreApplication>

#include "ConnectionHealthController.h"

namespace {

QString tr(const char* text) {
  return QCoreApplication::translate("ServerUpdates", text);
}

}  // namespace

QString ServerUpdates::path(const Machine& machine) {
  if (machine.selfUpdate.isEmpty()) return QStringLiteral("command");
  if (machine.selfUpdate != QLatin1String("desktop-managed")) return QStringLiteral("update");
  return machine.desktopAppUpdate ? QStringLiteral("desktop") : QStringLiteral("desktop-manual");
}

bool ServerUpdates::behind(const Machine& machine) const {
  return ConnectionHealthController::serverBehind(m_appVersion, machine.version);
}

std::optional<ServerUpdates::Machine> ServerUpdates::find(const QString& environmentId) const {
  for (const Machine& machine : m_machines) {
    if (machine.id == environmentId) return machine;
  }
  return std::nullopt;
}

QList<ServerUpdates::Machine> ServerUpdates::updatable() const {
  QList<Machine> result;
  for (const Machine& machine : m_machines) {
    const QString way = path(machine);
    if (machine.online && behind(machine) && !updating(machine.id) &&
        (way == QLatin1String("update") || way == QLatin1String("desktop"))) {
      result.append(machine);
    }
  }
  return result;
}

void ServerUpdates::update(const QString& environmentId) {
  const auto machine = find(environmentId);
  if (!machine || !machine->online || !behind(*machine) || updating(environmentId)) return;
  const QString way = path(*machine);
  if (way == QLatin1String("command")) {
    copyCommand(environmentId);
  } else if (way == QLatin1String("update")) {
    run(*machine, tr("Server update failed"));
  } else if (way == QLatin1String("desktop")) {
    // The only question in the flow: the machine that runs it installs without asking anyone there.
    m_effects.confirm(tr("Update the HAL-C2 desktop app that runs %1?").arg(machine->label),
                      tr("It will close and relaunch on that machine."), [this, environmentId] {
                        const auto now = find(environmentId);
                        if (now && !updating(environmentId)) run(*now, tr("Server update failed"));
                      });
  }
}

void ServerUpdates::updateAll() {
  const QList<Machine> eligible = updatable();
  if (eligible.isEmpty()) return;
  QStringList desktops;
  for (const Machine& machine : eligible) {
    if (path(machine) == QLatin1String("desktop")) desktops.append(machine.label);
  }
  QStringList ids;
  for (const Machine& machine : eligible) ids.append(machine.id);
  const auto start = [this, ids] {
    for (const QString& id : ids) {
      const auto machine = find(id);
      if (machine && !updating(id)) run(*machine, tr("%1 update failed").arg(machine->label));
    }
  };
  if (desktops.isEmpty()) {
    start();
    return;
  }
  m_effects.confirm(tr("Update the HAL-C2 desktop apps on %1?").arg(desktops.join(QStringLiteral(", "))),
                    tr("They will close and relaunch on those machines."), start);
}

void ServerUpdates::copyCommand(const QString& environmentId) {
  const auto machine = find(environmentId);
  if (!machine || m_appVersion.isEmpty()) return;
  const QString text = command(m_appVersion);
  if (m_effects.copy(text)) {
    m_effects.toast(QStringLiteral("success"), tr("Update command copied"),
                    tr("Run `%1` on %2 to update it.").arg(text, machine->label));
  } else {
    m_effects.toast(QStringLiteral("error"), tr("Could not copy update command"),
                    tr("The clipboard could not be written. Run `%1` on %2 to update it.").arg(text, machine->label));
  }
}

void ServerUpdates::run(const Machine& machine, const QString& failureTitle) {
  m_updating.insert(machine.id, true);
  const QString id = machine.id;
  const QString label = machine.label;
  const bool desktop = machine.selfUpdate == QLatin1String("desktop-managed");
  const QString target = m_appVersion;
  m_effects.call(id, target, [this, id, label, desktop, target, failureTitle](const Reply& reply) {
    m_updating.remove(id);
    if (!reply.ok) {
      m_effects.toast(QStringLiteral("error"), failureTitle, reply.error.isEmpty() ? tr("Server update failed.") : reply.error);
      return;
    }
    const QString version = reply.targetVersion.isEmpty() ? target : reply.targetVersion;
    m_effects.toast(QStringLiteral("success"), tr("%1 updated").arg(label),
                    desktop ? tr("Desktop app relaunched on %1.").arg(version) : tr("Reconnected on hal-c2@%1.").arg(version));
  });
}

QVariantMap ServerUpdates::state() const {
  QVariantList machines;
  for (const Machine& machine : m_machines) {
    machines.append(QVariantMap{
        {QStringLiteral("environmentId"), machine.id},
        {QStringLiteral("label"), machine.label},
        {QStringLiteral("version"), machine.version},
        {QStringLiteral("online"), machine.online},
        {QStringLiteral("behind"), behind(machine)},
        {QStringLiteral("path"), path(machine)},
        {QStringLiteral("command"), m_appVersion.isEmpty() ? QString() : command(m_appVersion)},
        {QStringLiteral("updating"), updating(machine.id)},
    });
  }
  return {{QStringLiteral("appVersion"), m_appVersion},
          {QStringLiteral("machines"), machines},
          {QStringLiteral("updatable"), int(updatable().size())}};
}
