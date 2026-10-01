// The add-provider wizard's ACP Registry (ProviderSettingsController), as the
// web's AcpRegistrySearchStep: the registry's compatible agents, searched on the
// shown environment, and choosing one, which the environment installs before
// the wizard names the instance after it. An agent can also be entered by hand.
//
// Actions (while the wizard shows):
//   `providerSettings.registrySearch {query}` (the wizard searches with an
//   empty query as it opens), `.registryAdd {agentId}` (prepares the agent,
//   then moves on to Identity), `.registryManual {manual}` (the registry
//   driver's own fields instead of a search).
//
// `wizard.registry`: {query, searching, error, agents [{id, name, description,
// iconUrl, website, added, preparing, progress ("Preparing" | "Downloading")}]
// (null before the first answer), manual, selected (null | {id, name,
// version}), selectionError ("" until moving on was tried)}.

#include <QJsonArray>
#include <QJsonObject>
#include <QUrl>

#include "McClient.h"
#include "ProviderDrivers.h"
#include "ProviderInstances.h"
#include "ProviderSettingsController.h"

namespace {

const QString kRegistry = QStringLiteral("acpRegistry");

// resolveOfficialAcpRegistryIconUrl: only the registry's own CDN.
QString officialIcon(const QString& icon) {
  const QUrl url(icon);
  if (icon.isEmpty() || url.scheme() != QLatin1String("https") || url.host() != QLatin1String("cdn.agentclientprotocol.com") ||
      url.port() != -1 || !url.userInfo().isEmpty()) {
    return {};
  }
  return icon;
}

// isConfiguredAcpRegistryAgent: an instance already runs the agent.
bool configured(const QJsonObject& settings, const QString& agentId) {
  const QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
  for (auto it = instances.begin(); it != instances.end(); ++it) {
    const QJsonObject instance = it.value().toObject();
    if (instance.value(QLatin1String("driver")) == kRegistry &&
        instance.value(QLatin1String("config")).toObject().value(QLatin1String("agentId")).toString() == agentId) {
      return true;
    }
  }
  return false;
}

}  // namespace

QString ProviderSettingsController::registrySelectionError() const {
  if (!m_wizard || m_wizard->driver != kRegistry) return {};
  return !m_wizard->selected.isEmpty() || m_wizard->manual ? QString() : QStringLiteral("Select an ACP or configure one manually.");
}

void ProviderSettingsController::searchRegistry(const QString& query) {
  if (!m_wizard || m_followed.isEmpty()) return;
  m_wizard->query = query.trimmed();
  m_wizard->searching = true;
  m_wizard->registryError.clear();
  const int generation = ++m_wizard->generation;
  const int wizard = m_wizard->id;
  m_client->call(this, m_followed, QStringLiteral("server.searchAcpRegistry"), QJsonObject{{QStringLiteral("query"), m_wizard->query}},
                 [this, generation, wizard](const QJsonValue& result, const std::optional<QString>& error) {
                   // A later search, or a wizard since closed, owns the answer.
                   if (!m_wizard || m_wizard->id != wizard || m_wizard->generation != generation) return;
                   m_wizard->searching = false;
                   if (error) {
                     m_wizard->registryError = error->isEmpty() ? QStringLiteral("The ACP Registry could not be searched.") : *error;
                   } else {
                     m_wizard->agents = result.toObject().value(QLatin1String("agents")).toArray();
                   }
                   publish();
                 });
}

bool ProviderSettingsController::handleRegistry(const QString& action, const QVariantMap& input) {
  if (!action.startsWith(QLatin1String("providerSettings.registry"))) return false;
  if (!m_wizard || m_wizard->saving || !m_wizard->preparing.isEmpty()) return true;
  if (action == QLatin1String("providerSettings.registrySearch")) {
    searchRegistry(input.value(QStringLiteral("query")).toString());
  } else if (action == QLatin1String("providerSettings.registryManual")) {
    m_wizard->manual = input.value(QStringLiteral("manual")).toBool();
    m_wizard->attempted = false;
    if (m_wizard->manual) {
      m_wizard->driver = kRegistry;
      m_wizard->selected = {};
      m_wizard->config.remove(kRegistry);
      m_wizard->identity.insert(kRegistry, QJsonObject{{QStringLiteral("label"), QString()}});
    }
  } else if (action == QLatin1String("providerSettings.registryAdd")) {
    const QString agentId = input.value(QStringLiteral("agentId")).toString();
    QJsonObject agent;
    for (const QJsonValue& value : m_wizard->agents.value_or(QJsonArray{})) {
      if (value.toObject().value(QLatin1String("id")).toString() == agentId) agent = value.toObject();
    }
    if (agent.isEmpty() || m_followed.isEmpty() || configured(shownSettings().value_or(QJsonObject{}), agentId)) return true;
    m_wizard->preparing = agentId;
    m_wizard->registryError.clear();
    const int wizard = m_wizard->id;
    m_client->call(this, m_followed, QStringLiteral("server.prepareAcpRegistryAgent"), QJsonObject{{QStringLiteral("agentId"), agentId}},
                   [this, agent, wizard](const QJsonValue& result, const std::optional<QString>& error) {
                     // A wizard closed (or reopened) since has moved on.
                     if (!m_wizard || m_wizard->id != wizard) return;
                     m_wizard->preparing.clear();
                     if (error) {
                       m_wizard->registryError = error->isEmpty() ? QStringLiteral("The ACP could not be prepared.") : *error;
                       publish();
                       return;
                     }
                     const QJsonObject prepared = result.toObject();
                     const QString id = prepared.value(QLatin1String("agentId")).toString(agent.value(QLatin1String("id")).toString());
                     const QString name = agent.value(QLatin1String("name")).toString();
                     m_wizard->driver = kRegistry;
                     m_wizard->manual = false;
                     m_wizard->attempted = false;
                     m_wizard->selected = QJsonObject{{QStringLiteral("id"), id},
                                                      {QStringLiteral("name"), name},
                                                      {QStringLiteral("version"), prepared.value(QLatin1String("version"))}};
                     const QSet<QString> taken =
                         ProviderInstances::taken(shownSettings().value_or(QJsonObject{}), m_providers.value_or(QJsonArray{}));
                     m_wizard->identity.insert(kRegistry, QJsonObject{{QStringLiteral("label"), name},
                                                                      {QStringLiteral("instanceId"), ProviderDrivers::deriveId(kRegistry, name, taken)}});
                     QJsonObject config{{QStringLiteral("agentId"), id}, {QStringLiteral("distribution"), QStringLiteral("auto")}};
                     const QString icon = officialIcon(agent.value(QLatin1String("icon")).toString());
                     if (!icon.isEmpty()) config.insert(QStringLiteral("registryIconUrl"), icon);
                     m_wizard->config.insert(kRegistry, config);
                     m_wizard->step = 1;
                     publish();
                   });
  }
  publish();
  return true;
}

QVariantMap ProviderSettingsController::registry() const {
  const QJsonObject settings = shownSettings().value_or(QJsonObject{});
  QVariant agents = QVariant::fromValue(nullptr);
  if (m_wizard->agents) {
    QVariantList list;
    for (const QJsonValue& value : std::as_const(*m_wizard->agents)) {
      const QJsonObject agent = value.toObject();
      const QString id = agent.value(QLatin1String("id")).toString();
      const QString website = agent.value(QLatin1String("website")).toString();
      list.append(QVariantMap{
          {QStringLiteral("id"), id},
          {QStringLiteral("name"), agent.value(QLatin1String("name")).toString()},
          {QStringLiteral("description"), agent.value(QLatin1String("description")).toString()},
          {QStringLiteral("iconUrl"), officialIcon(agent.value(QLatin1String("icon")).toString())},
          {QStringLiteral("website"), website.isEmpty() ? agent.value(QLatin1String("repository")).toString() : website},
          {QStringLiteral("added"), configured(settings, id)},
          {QStringLiteral("preparing"), m_wizard->preparing == id},
          {QStringLiteral("progress"), agent.value(QLatin1String("distribution")) == QLatin1String("binary") ? QStringLiteral("Downloading")
                                                                                                          : QStringLiteral("Preparing")},
      });
    }
    agents = list;
  }
  return {
      {QStringLiteral("query"), m_wizard->query},
      {QStringLiteral("searching"), m_wizard->searching},
      {QStringLiteral("error"), m_wizard->registryError},
      {QStringLiteral("agents"), agents},
      {QStringLiteral("busy"), !m_wizard->preparing.isEmpty()},
      {QStringLiteral("manual"), m_wizard->manual},
      {QStringLiteral("selected"), m_wizard->selected.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(m_wizard->selected.toVariantMap())},
      {QStringLiteral("selectionError"), m_wizard->attempted ? registrySelectionError() : QString()},
  };
}
