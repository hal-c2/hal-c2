#include "SavedEnvironmentsController.h"

#include <QDir>
#include <QNetworkAccessManager>
#include <QSysInfo>
#include <QVariantList>

#include "McClient.h"
#include "SecretStore.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<SavedEnvironmentsController> registrar(QStringLiteral("savedEnvironments"), {QStringLiteral("savedEnvironments")},
                                                                       nullptr, NativeControllerScope::Shared);

std::function<std::unique_ptr<SecretStore>(const QString&)>& secretStoreFactory() {
  static std::function<std::unique_ptr<SecretStore>(const QString&)> factory = [](const QString& dataDir) { return SecretStore::system(dataDir); };
  return factory;
}

QString state(McClient::Phase phase) {
  switch (phase) {
    case McClient::Phase::Ready:
      return QStringLiteral("connected");
    case McClient::Phase::Connecting:
      return QStringLiteral("connecting");
    case McClient::Phase::Retrying:
      return QStringLiteral("reconnecting");
    case McClient::Phase::Offline:
      return QStringLiteral("offline");
    case McClient::Phase::Refused:
      return QStringLiteral("refused");
    case McClient::Phase::Blocked:
      return QStringLiteral("blocked");
    case McClient::Phase::Closed:
      break;
  }
  return QStringLiteral("closed");
}

}  // namespace

SavedEnvironmentsController::SavedEnvironmentsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_device{QStringLiteral("HAL-C2 on %1").arg(QSysInfo::machineHostName()), QStringLiteral("desktop"), QSysInfo::prettyProductName()} {
  // What the shell asks of a saved environment goes to its connection.
  client->setRoute([this](const QString& environment, const QString& mc) -> McClient* {
    if (!mc.isEmpty()) return m_store->linkOf(mc);
    if (McClient* link = m_store->linkServing(environment)) return link;
    const auto it = m_links.find(environment);
    return it == m_links.end() ? nullptr : it->second.client.get();
  });
}

SavedEnvironmentsController::~SavedEnvironmentsController() {
  m_client->setRoute({});
  for (const auto& [id, link] : m_links) {
    if (link.client) m_store->removeLink(link.client.get(), false);
  }
}

void SavedEnvironmentsController::setSecretStoreFactory(std::function<std::unique_ptr<SecretStore>(const QString& dataDir)> factory) {
  secretStoreFactory() = std::move(factory);
}

void SavedEnvironmentsController::start(const QString& dataDir) {
  while (!m_links.empty()) disconnect(m_links.begin()->first, false);
  m_secrets = secretStoreFactory()(dataDir);
  m_catalog = std::make_unique<EnvironmentCatalog>(QDir(dataDir).filePath(QStringLiteral("saved-environments.json")), m_secrets.get());
  m_catalog->load();
  if (!m_catalog->damaged().isEmpty()) qWarning("[catalog] a damaged record of saved environments was set aside as %s", qPrintable(m_catalog->damaged()));
  for (const SavedEnvironment& environment : m_catalog->environments()) connectTo(environment.id);
  publish();
}

McClient* SavedEnvironmentsController::client(const QString& id) const {
  const auto it = m_links.find(id);
  return it == m_links.end() ? nullptr : it->second.client.get();
}

void SavedEnvironmentsController::connectTo(const QString& id) {
  if (!m_catalog) return;
  disconnect(id, false);
  const EnvironmentCatalog::Connection connection = m_catalog->connect(id);
  Link& link = m_links[id];
  if (!connection.blocked.isEmpty()) {
    // Nothing to connect with: no retry can mend that.
    link.blocked = connection.blocked;
    publish();
    return;
  }
  link.client = std::make_unique<McClient>();
  McClient* client = link.client.get();
  // Its timings are the shell's own (tests shorten them there).
  client->setRetryDelays(m_client->retryDelays());
  client->setSetupTimeout(m_client->setupTimeout());
  client->setProbeTimeout(m_client->probeTimeout());
  client->setPingInterval(m_client->pingInterval());
  client->setPongTimeout(m_client->pongTimeout());
  client->setSteadyAfter(m_client->steadyAfter());
  client->setRenewWithin(m_client->renewWithin());
  client->setEnvironmentNames([this](const QString& environment) {
    const QString label = m_store->environment(environment).value(QLatin1String("label")).toString();
    return label.isEmpty() ? environment : label;
  });
  client->setCredentialExpiry(connection.environment.expiresAt);
  connect(client, &McClient::phaseChanged, this, &SavedEnvironmentsController::publish);
  connect(client, &McClient::credentialRenewed, this, [this, id](const QDateTime& expiresAt) {
    if (m_catalog) m_catalog->setExpiry(id, expiresAt);
  });
  m_store->addLink(client, id);
  client->open(connection.environment.origin, connection.credential, id);
  publish();
}

void SavedEnvironmentsController::disconnect(const QString& id, bool forget) {
  const auto it = m_links.find(id);
  if (it == m_links.end()) return;
  std::unique_ptr<McClient> client = std::move(it->second.client);
  m_links.erase(it);
  if (!client) return;
  client->disconnect(this);
  m_store->removeLink(client.get(), forget);
  client->close();
  // Replies on their way still name it.
  client.release()->deleteLater();
}

void SavedEnvironmentsController::pair(const QString& link, std::function<void(const QString& error)> done) {
  const auto finish = [this, done](const QString& error) {
    m_pairing = false;
    m_error = error;
    publish();
    if (done) done(error);
  };
  const auto read = pairing::readLink(link);
  if (!read) return finish(QStringLiteral("That is not a pairing link. Paste the whole link the environment gave you."));
  if (!m_catalog) return finish(QStringLiteral("Saved environments are not available yet."));
  if (!m_http) m_http = new QNetworkAccessManager(this);
  const quint64 attempt = ++m_attempt;
  m_pairing = true;
  m_error.clear();
  publish();
  pairing::exchange(m_http, this, *read, m_device, [this, attempt, finish](const pairing::Result& result) {
    if (attempt != m_attempt) return;
    if (result.outcome != pairing::Outcome::Paired) return finish(pairing::explain(result));
    const QString id = result.descriptor.value(QLatin1String("environmentId")).toString();
    QString label = result.descriptor.value(QLatin1String("label")).toString();
    if (label.isEmpty()) label = result.origin.host();
    const SavedEnvironment environment{id, label, result.origin, result.expiresAt};
    if (const auto refused = m_catalog->save(environment, result.token)) return finish(*refused);
    connectTo(id);
    finish({});
  });
}

void SavedEnvironmentsController::remove(const QString& id) {
  disconnect(id, true);
  if (m_catalog) m_catalog->forget(id);
  publish();
}

bool SavedEnvironmentsController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("savedEnvironments.pair")) {
    pair(input.value(QStringLiteral("link")).toString());
    return true;
  }
  if (action == QLatin1String("savedEnvironments.remove")) {
    remove(input.value(QStringLiteral("id")).toString());
    return true;
  }
  if (action == QLatin1String("savedEnvironments.retry")) {
    const QString id = input.value(QStringLiteral("id")).toString();
    if (McClient* link = client(id)) {
      link->retryNow();
    } else {
      if (m_secrets) m_secrets->ask();
      connectTo(id);
    }
    return true;
  }
  return false;
}

QVariantMap SavedEnvironmentsController::status(const QString& id) const {
  const std::optional<SavedEnvironment> environment = m_catalog ? m_catalog->find(id) : std::nullopt;
  QVariantMap entry{{QStringLiteral("id"), id},
                    {QStringLiteral("label"), environment && !environment->label.isEmpty() ? environment->label : id},
                    {QStringLiteral("origin"), environment ? environment->origin.toString() : QString()}};
  const auto found = m_links.find(id);
  if (found == m_links.end()) {
    entry.insert(QStringLiteral("state"), QStringLiteral("closed"));
    entry.insert(QStringLiteral("message"), QString());
  } else if (const Link& link = found->second; !link.client) {
    entry.insert(QStringLiteral("state"), QStringLiteral("blocked"));
    entry.insert(QStringLiteral("message"), link.blocked);
  } else {
    entry.insert(QStringLiteral("state"), state(link.client->phase()));
    entry.insert(QStringLiteral("message"), link.client->isReady() ? QString() : link.client->failureMessage());
  }
  return entry;
}

void SavedEnvironmentsController::publish() {
  QVariantList environments;
  if (m_catalog) {
    for (const SavedEnvironment& environment : m_catalog->environments()) environments.append(status(environment.id));
  }
  m_bridge->publish(QStringLiteral("savedEnvironments"),
                    QVariantMap{{QStringLiteral("environments"), environments},
                                {QStringLiteral("pairing"), m_pairing},
                                {QStringLiteral("error"), m_error},
                                {QStringLiteral("damaged"), m_catalog ? m_catalog->damaged() : QString()}});
  emit changed();
}
