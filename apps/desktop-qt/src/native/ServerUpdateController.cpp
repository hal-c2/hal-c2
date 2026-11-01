#include "ServerUpdateController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QJsonObject>

#include "CommandRegistry.h"
#include "ConnectionHealthController.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ServerUpdateController> registrar(QStringLiteral("serverUpdates"),
                                                                  {QStringLiteral("serverUpdates")}, nullptr,
                                                                  NativeControllerScope::Shared);

const QString kKey = QStringLiteral("serverUpdates");
const QString kUpdateAll = QStringLiteral("serverUpdates.updateAll");
const QString kUpdateOne = QStringLiteral("serverUpdates.update");

}  // namespace

ServerUpdateController::ServerUpdateController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_writeClipboard([](const QString& text) {
        QGuiApplication::clipboard()->setText(text);
        return true;
      }),
      m_updates(ServerUpdates::Effects{
          .call =
              [this](const QString& environmentId, const QString& targetVersion, ServerUpdates::Done done) {
                m_client->call(this, environmentId, QStringLiteral("server.updateServer"),
                               QJsonObject{{QStringLiteral("targetVersion"), targetVersion}},
                               [this, done](const QJsonValue& result, const std::optional<QString>& error) {
                                 ServerUpdates::Reply reply;
                                 reply.ok = !error;
                                 reply.error = error.value_or(QString());
                                 reply.targetVersion = result.toObject().value(QLatin1String("targetVersion")).toString();
                                 done(reply);
                                 publish();
                               });
              },
          .confirm =
              [this](const QString& title, const QString& description, std::function<void()> accepted) {
                auto* menus = NativeShell::of(this)->controller<MenuController>();
                if (!menus) return;
                menus->confirm(title, description, tr("Update"), false, [this, accepted] {
                  accepted();
                  publish();
                });
              },
          .toast =
              [this](const QString& type, const QString& title, const QString& description) {
                if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->show(type, title, description);
              },
          .copy = [this](const QString& text) { return m_writeClipboard(text); },
      }) {
  connect(store, &ShellStore::changed, this, &ServerUpdateController::refresh);
}

void ServerUpdateController::activate() {
  // The app's version is the health controller's, which tests may set.
  const NativeWindow* window = NativeShell::of(this);
  if (auto* health = window ? window->controller<ConnectionHealthController>() : nullptr) {
    connect(health, &ConnectionHealthController::clientVersionChanged, this, &ServerUpdateController::refresh,
            Qt::UniqueConnection);
  }
  refresh();
}

void ServerUpdateController::attach(NativeWindow* window) {
  auto* keys = window->controller<KeybindingController>();
  if (!keys) return;
  CommandRegistry* commands = keys->commands();
  commands->add(kUpdateAll, tr("Update all servers"), [this] {
    m_updates.updateAll();
    publish();
  });
  commands->addMenu(kUpdateOne, tr("Update a server..."), [this] {
    QList<CommandRegistry::Choice> choices;
    for (const ServerUpdates::Machine& machine : m_updates.machines()) {
      const QString path = ServerUpdates::path(machine);
      if (!machine.online || !m_updates.behind(machine) || path == QLatin1String("desktop-manual")) continue;
      CommandRegistry::Choice choice;
      choice.id = machine.id;
      choice.title = machine.label;
      choice.description = path == QLatin1String("command") ? tr("Copy the update command (on %1)").arg(machine.version)
                                                            : tr("On %1").arg(machine.version);
      choice.enabled = !m_updates.updating(machine.id);
      const QString id = machine.id;
      choice.run = [this, id] {
        m_updates.update(id);
        publish();
      };
      choices.append(choice);
    }
    return choices;
  });
  m_palettes.append(commands);
  publish();
}

bool ServerUpdateController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("serverUpdates."))) return false;
  const QString environmentId = payload.toMap().value(QStringLiteral("environmentId")).toString();
  if (action == kUpdateOne) {
    m_updates.update(environmentId);
  } else if (action == QLatin1String("serverUpdates.copyCommand")) {
    m_updates.copyCommand(environmentId);
  } else if (action == kUpdateAll) {
    m_updates.updateAll();
  } else {
    return false;
  }
  publish();
  return true;
}

// The machines as the store describes them, this shell's own first.
void ServerUpdateController::refresh() {
  QString version = QCoreApplication::applicationVersion();
  const NativeWindow* window = NativeShell::of(this);
  if (auto* health = window ? window->controller<ConnectionHealthController>() : nullptr) version = health->clientVersion();
  m_updates.setAppVersion(version);

  QStringList ids = m_store->environments();
  const QString own = m_store->environmentOf(m_client->mc());
  if (!own.isEmpty()) {
    ids.removeAll(own);
    ids.prepend(own);
  }
  QList<ServerUpdates::Machine> machines;
  for (const QString& id : ids) {
    const QJsonObject descriptor = m_store->environment(id);
    const QJsonObject capabilities = descriptor.value(QLatin1String("capabilities")).toObject();
    ServerUpdates::Machine machine;
    machine.id = id;
    machine.label = descriptor.value(QLatin1String("label")).toString();
    if (machine.label.isEmpty()) machine.label = id;
    machine.version = descriptor.value(QLatin1String("serverVersion")).toString();
    machine.selfUpdate = capabilities.value(QLatin1String("serverSelfUpdate")).toString();
    machine.desktopAppUpdate = capabilities.value(QLatin1String("desktopAppUpdate")).toBool();
    machine.online = m_store->environmentOnline(id);
    machines.append(machine);
  }
  m_updates.setMachines(machines);
  publish();
}

void ServerUpdateController::publish() {
  const QVariantMap state = m_updates.state();
  m_bridge->publish(kKey, state);
  bool behind = false;
  for (const ServerUpdates::Machine& machine : m_updates.machines()) {
    if (machine.online && m_updates.behind(machine) && ServerUpdates::path(machine) != QLatin1String("desktop-manual")) behind = true;
  }
  const bool updatable = !m_updates.updatable().isEmpty();
  m_palettes.removeAll(nullptr);
  for (CommandRegistry* commands : std::as_const(m_palettes)) {
    commands->setEnabled(kUpdateAll, updatable);
    commands->setListed(kUpdateAll, updatable);
    commands->setEnabled(kUpdateOne, behind);
    commands->setListed(kUpdateOne, behind);
  }
}
