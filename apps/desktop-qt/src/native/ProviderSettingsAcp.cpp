// An ACP Registry agent's own sessions, model providers and sign-out on its
// Providers card (ProviderSettingsController): the agent is asked from one of
// the shown environment's projects (HalC2.Acp.Sessions), one request at a time.
//
// Actions: `providerSettings.acpProject {instanceId, projectId}`,
// `.acpSessions {instanceId, more}` (lists them again, or the next page),
// `.acpImport {instanceId, sessionId}`, `.acpDelete {instanceId, sessionId}`
// (asks first), `.acpProviders {instanceId}`, `.acpSetProvider {instanceId,
// providerId, apiType, baseUrl, headers}` (headers: JSON text, empty for
// none), `.acpDisableProvider {instanceId, providerId}` (asks first),
// `.acpLogout {instanceId}`.
//
// Each registry entry's `acp`: null when the agent offers none of it, else
// {canList, canImport, canDelete, canLogout, canConfigure, projects [{id,
// title}], projectId, sessions: null | [{sessionId, title, updatedAt, cwd,
// imported}], more, providers: null | [{providerId, supported, required,
// configured, apiType, baseUrl}], busy ("" or what runs: sessions, import,
// delete, providers, provider, logout)}.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>

#include "MenuController.h"
#include "NativeShell.h"
#include "McClient.h"
#include "ProviderSettingsController.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

void toast(QObject* context, const QString& type, const QString& title, const QString& description = {}) {
  if (auto* toasts = NativeShell::of(context)->controller<ToastController>()) toasts->show(type, title, description);
}

// Why `text` is not a JSON object of strings, or empty (with `headers` set).
QString headerProblem(const QString& text, QJsonObject& headers) {
  if (text.trimmed().isEmpty()) return {};
  QJsonParseError error;
  const QJsonDocument document = QJsonDocument::fromJson(text.toUtf8(), &error);
  if (error.error != QJsonParseError::NoError) return QStringLiteral("Headers must be valid JSON.");
  if (!document.isObject()) return QStringLiteral("Headers must be a JSON object with string values.");
  for (const QJsonValue& value : document.object()) {
    if (!value.isString()) return QStringLiteral("Headers must be a JSON object with string values.");
  }
  headers = document.object();
  return {};
}

}  // namespace

QString ProviderSettingsController::acpProject(const QString& instanceId) const {
  const QList<QJsonObject> rows = m_store->projectRows(m_followed);
  const QString chosen = m_acp.value(instanceId).projectId;
  for (const QJsonObject& row : rows) {
    if (row.value(QLatin1String("id")).toString() == chosen) return chosen;
  }
  return rows.isEmpty() ? QString() : rows.first().value(QLatin1String("id")).toString();
}

void ProviderSettingsController::acpCall(const QString& instanceId, const QString& busy, const QString& method, QJsonObject payload,
                                         const QString& failure, const std::function<void(const QJsonObject&)>& done) {
  Acp& acp = m_acp[instanceId];
  if (!acp.busy.isEmpty() || m_followed.isEmpty()) return;
  payload.insert(QStringLiteral("instanceId"), instanceId);
  acp.busy = busy;
  publish();
  const QString environmentId = m_followed;
  const quint64 following = m_following;
  m_client->call(this, environmentId, method, payload,
                 [this, instanceId, following, failure, done](const QJsonValue& result, const std::optional<QString>& error) {
                   // The answer may come after the user moved on, and back.
                   if (m_following != following) return;
                   m_acp[instanceId].busy.clear();
                   if (error) toast(this, QStringLiteral("error"), failure, *error);
                   else done(result.toObject());
                   publish();
                 });
}

bool ProviderSettingsController::handleAcp(const QString& action, const QVariantMap& input) {
  if (!action.startsWith(QLatin1String("providerSettings.acp"))) return false;
  const QString instanceId = input.value(QStringLiteral("instanceId")).toString();
  if (driverOf(instanceId) != QLatin1String("acpRegistry")) return true;
  const QString projectId = acpProject(instanceId);
  const auto confirm = [this](const QString& title, const QString& text, const QString& button, std::function<void()> yes) {
    if (auto* menu = NativeShell::of(this)->controller<MenuController>()) menu->confirm(title, text, button, true, std::move(yes));
  };
  if (action == QLatin1String("providerSettings.acpProject")) {
    Acp& acp = m_acp[instanceId];
    if (!acp.busy.isEmpty()) return true;
    acp = Acp{};
    acp.projectId = input.value(QStringLiteral("projectId")).toString();
  } else if (projectId.isEmpty() && action != QLatin1String("providerSettings.acpLogout")) {
    return true;
  } else if (action == QLatin1String("providerSettings.acpSessions")) {
    const bool more = input.value(QStringLiteral("more")).toBool() && !m_acp.value(instanceId).nextCursor.isEmpty();
    QJsonObject payload{{QStringLiteral("projectId"), projectId}};
    if (more) payload.insert(QStringLiteral("cursor"), m_acp.value(instanceId).nextCursor);
    acpCall(instanceId, QStringLiteral("sessions"), QStringLiteral("server.listAcpRegistrySessions"), payload,
            QStringLiteral("Could not list ACP sessions"), [this, instanceId, projectId, more](const QJsonObject& result) {
      Acp& acp = m_acp[instanceId];
      acp.projectId = projectId;
      QJsonArray sessions = more ? acp.sessions.value_or(QJsonArray{}) : QJsonArray{};
      for (const QJsonValue& session : result.value(QLatin1String("sessions")).toArray()) sessions.append(session);
      acp.sessions = sessions;
      acp.nextCursor = result.value(QLatin1String("nextCursor")).toString();
    });
  } else if (action == QLatin1String("providerSettings.acpImport")) {
    const QString sessionId = input.value(QStringLiteral("sessionId")).toString();
    QJsonObject session;
    for (const QJsonValue& value : m_acp.value(instanceId).sessions.value_or(QJsonArray{})) {
      if (value.toObject().value(QLatin1String("sessionId")).toString() == sessionId) session = value.toObject();
    }
    if (session.isEmpty()) return true;
    QJsonObject payload{{QStringLiteral("projectId"), projectId}, {QStringLiteral("sessionId"), sessionId}};
    for (const QLatin1String key : {QLatin1String("title"), QLatin1String("updatedAt")}) {
      if (session.value(key).isString()) payload.insert(key, session.value(key));
    }
    acpCall(instanceId, QStringLiteral("import"), QStringLiteral("server.importAcpRegistrySession"), payload,
            QStringLiteral("Could not import ACP session"), [this, instanceId, sessionId](const QJsonObject& result) {
      Acp& acp = m_acp[instanceId];
      QJsonArray sessions = acp.sessions.value_or(QJsonArray{});
      for (qsizetype index = 0; index < sessions.size(); ++index) {
        QJsonObject row = sessions.at(index).toObject();
        if (row.value(QLatin1String("sessionId")).toString() != sessionId) continue;
        row.insert(QStringLiteral("importedThreadId"), result.value(QLatin1String("threadId")));
        sessions.replace(index, row);
      }
      acp.sessions = sessions;
      toast(this, QStringLiteral("success"),
            result.value(QLatin1String("imported")).toBool() ? QStringLiteral("ACP session imported") : QStringLiteral("ACP session already imported"));
    });
  } else if (action == QLatin1String("providerSettings.acpDelete")) {
    const QString sessionId = input.value(QStringLiteral("sessionId")).toString();
    QJsonObject session;
    for (const QJsonValue& value : m_acp.value(instanceId).sessions.value_or(QJsonArray{})) {
      if (value.toObject().value(QLatin1String("sessionId")).toString() == sessionId) session = value.toObject();
    }
    if (session.isEmpty()) return true;
    // An imported session goes with its thread first (the MC refuses it too).
    if (session.value(QLatin1String("importedThreadId")).isString()) {
      toast(this, QStringLiteral("error"), QStringLiteral("Could not delete ACP session"),
            QStringLiteral("Delete the imported HAL-C2 thread before deleting its native ACP session."));
      return true;
    }
    const QString title = session.value(QLatin1String("title")).toString(sessionId);
    const QString environmentId = m_followed;
    confirm(QStringLiteral("Delete native session?"), QStringLiteral("Permanently delete native ACP session \"%1\"?").arg(title),
            QStringLiteral("Delete"), [this, instanceId, projectId, sessionId, environmentId] {
      if (m_followed != environmentId) return;
      acpCall(instanceId, QStringLiteral("delete"), QStringLiteral("server.deleteAcpRegistrySession"),
              {{QStringLiteral("projectId"), projectId}, {QStringLiteral("sessionId"), sessionId}}, QStringLiteral("Could not delete ACP session"),
              [this, instanceId, sessionId](const QJsonObject&) {
        Acp& acp = m_acp[instanceId];
        QJsonArray kept;
        for (const QJsonValue& value : acp.sessions.value_or(QJsonArray{})) {
          if (value.toObject().value(QLatin1String("sessionId")).toString() != sessionId) kept.append(value);
        }
        acp.sessions = kept;
        toast(this, QStringLiteral("success"), QStringLiteral("ACP session deleted"));
      });
    });
  } else if (action == QLatin1String("providerSettings.acpProviders")) {
    listAcpProviders(instanceId, projectId);
  } else if (action == QLatin1String("providerSettings.acpSetProvider")) {
    const QString apiType = input.value(QStringLiteral("apiType")).toString().trimmed();
    const QString baseUrl = input.value(QStringLiteral("baseUrl")).toString().trimmed();
    if (apiType.isEmpty() || baseUrl.isEmpty()) return true;
    QJsonObject headers;
    const QString problem = headerProblem(input.value(QStringLiteral("headers")).toString(), headers);
    if (!problem.isEmpty()) {
      toast(this, QStringLiteral("error"), QStringLiteral("Invalid provider headers"), problem);
      return true;
    }
    QJsonObject payload{{QStringLiteral("projectId"), projectId},
                        {QStringLiteral("providerId"), input.value(QStringLiteral("providerId")).toString()},
                        {QStringLiteral("apiType"), apiType},
                        {QStringLiteral("baseUrl"), baseUrl}};
    if (!headers.isEmpty()) payload.insert(QStringLiteral("headers"), headers);
    acpCall(instanceId, QStringLiteral("provider"), QStringLiteral("server.setAcpRegistryProvider"), payload,
            QStringLiteral("Could not configure ACP provider"), [this, instanceId, projectId](const QJsonObject&) {
      toast(this, QStringLiteral("success"), QStringLiteral("ACP provider configured"));
      QMetaObject::invokeMethod(this, [this, instanceId, projectId] { listAcpProviders(instanceId, projectId); }, Qt::QueuedConnection);
    });
  } else if (action == QLatin1String("providerSettings.acpDisableProvider")) {
    const QString providerId = input.value(QStringLiteral("providerId")).toString();
    const QString environmentId = m_followed;
    confirm(QStringLiteral("Disable ACP provider?"), QStringLiteral("Disable ACP provider \"%1\"?").arg(providerId), QStringLiteral("Disable"),
            [this, instanceId, projectId, providerId, environmentId] {
      if (m_followed != environmentId) return;
      acpCall(instanceId, QStringLiteral("provider"), QStringLiteral("server.disableAcpRegistryProvider"),
              {{QStringLiteral("projectId"), projectId}, {QStringLiteral("providerId"), providerId}}, QStringLiteral("Could not disable ACP provider"),
              [this, instanceId, projectId](const QJsonObject&) {
        toast(this, QStringLiteral("success"), QStringLiteral("ACP provider disabled"));
        QMetaObject::invokeMethod(this, [this, instanceId, projectId] { listAcpProviders(instanceId, projectId); }, Qt::QueuedConnection);
      });
    });
  } else if (action == QLatin1String("providerSettings.acpLogout")) {
    acpCall(instanceId, QStringLiteral("logout"), QStringLiteral("server.logoutAcpRegistry"), {}, QStringLiteral("Could not log out of ACP agent"),
            [this, instanceId](const QJsonObject&) {
      Acp& acp = m_acp[instanceId];
      acp.sessions.reset();
      acp.nextCursor.clear();
      toast(this, QStringLiteral("success"), QStringLiteral("Logged out of ACP agent"));
    });
  }
  publish();
  return true;
}

void ProviderSettingsController::listAcpProviders(const QString& instanceId, const QString& projectId) {
  acpCall(instanceId, QStringLiteral("providers"), QStringLiteral("server.listAcpRegistryProviders"), {{QStringLiteral("projectId"), projectId}},
          QStringLiteral("Could not list ACP providers"), [this, instanceId](const QJsonObject& result) {
    m_acp[instanceId].providers = result.value(QLatin1String("providers")).toArray();
  });
}

QVariant ProviderSettingsController::acp(const QJsonObject& provider) const {
  const QString instanceId = provider.value(QLatin1String("instanceId")).toString();
  const QJsonObject sessions = provider.value(QLatin1String("nativeSessions")).toObject();
  const bool canList = sessions.value(QLatin1String("canList")).toBool();
  const bool canLogout = provider.value(QLatin1String("auth")).toObject().value(QLatin1String("canLogout")).toBool() &&
                         !provider.value(QLatin1String("setup")).toObject().value(QLatin1String("canAuthenticate")).toBool();
  const bool canConfigure = provider.value(QLatin1String("configurableProviders")).toBool();
  if (provider.value(QLatin1String("driver")) != QLatin1String("acpRegistry") || (!canList && !canLogout && !canConfigure)) {
    return QVariant::fromValue(nullptr);
  }
  const Acp state = m_acp.value(instanceId);
  QVariantList projects;
  for (const QJsonObject& row : m_store->projectRows(m_followed)) {
    projects.append(QVariantMap{{QStringLiteral("id"), row.value(QLatin1String("id")).toString()},
                                {QStringLiteral("title"), row.value(QLatin1String("title")).toString()}});
  }
  QVariant sessionRows = QVariant::fromValue(nullptr);
  if (state.sessions) {
    QVariantList rows;
    for (const QJsonValue& value : std::as_const(*state.sessions)) {
      const QJsonObject session = value.toObject();
      const QString id = session.value(QLatin1String("sessionId")).toString();
      rows.append(QVariantMap{{QStringLiteral("sessionId"), id},
                              {QStringLiteral("title"), session.value(QLatin1String("title")).toString(id)},
                              {QStringLiteral("updatedAt"), session.value(QLatin1String("updatedAt")).toString()},
                              {QStringLiteral("cwd"), session.value(QLatin1String("cwd")).toString()},
                              {QStringLiteral("imported"), session.value(QLatin1String("importedThreadId")).isString()}});
    }
    sessionRows = rows;
  }
  QVariant providerRows = QVariant::fromValue(nullptr);
  if (state.providers) {
    QVariantList rows;
    for (const QJsonValue& value : std::as_const(*state.providers)) {
      const QJsonObject entry = value.toObject();
      const QJsonObject current = entry.value(QLatin1String("current")).toObject();
      const QVariantList supported = entry.value(QLatin1String("supported")).toArray().toVariantList();
      rows.append(QVariantMap{
          {QStringLiteral("providerId"), entry.value(QLatin1String("providerId")).toString()},
          {QStringLiteral("supported"), supported},
          {QStringLiteral("required"), entry.value(QLatin1String("required")).toBool()},
          {QStringLiteral("configured"), !current.isEmpty()},
          {QStringLiteral("apiType"), current.isEmpty() ? (supported.isEmpty() ? QString() : supported.first().toString())
                                                        : current.value(QLatin1String("apiType")).toString()},
          {QStringLiteral("baseUrl"), current.value(QLatin1String("baseUrl")).toString()},
      });
    }
    providerRows = rows;
  }
  return QVariantMap{
      {QStringLiteral("canList"), canList},
      {QStringLiteral("canImport"), sessions.value(QLatin1String("canLoad")).toBool() || sessions.value(QLatin1String("canResume")).toBool()},
      {QStringLiteral("canDelete"), sessions.value(QLatin1String("canDelete")).toBool()},
      {QStringLiteral("canLogout"), canLogout},
      {QStringLiteral("canConfigure"), canConfigure},
      {QStringLiteral("projects"), projects},
      {QStringLiteral("projectId"), acpProject(instanceId)},
      {QStringLiteral("sessions"), sessionRows},
      {QStringLiteral("more"), !state.nextCursor.isEmpty()},
      {QStringLiteral("providers"), providerRows},
      {QStringLiteral("busy"), state.busy},
  };
}
