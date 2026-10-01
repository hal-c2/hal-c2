// The runtime the MC installs itself (Antigravity) on its Providers card
// (ProviderSettingsController), as the web's ProviderSetupSection: each such
// instance follows its MC-addressed `providerInstall` shape, so every
// client shows the same download.
//
// Actions: `providerSettings.runtimeInstall {instanceId}`, `.runtimeCancel
// {instanceId}`, `.runtimeRemove {instanceId}` (asks first).
//
// Each such entry's `runtime`: null until the MC reports it, else {status,
// message, progress (0..1, or -1 without a known size), installLabel ("" when
// it cannot install), canCancel, canRemove, busy, error}.

#include <QJsonObject>

#include "MenuController.h"
#include "NativeShell.h"
#include "McClient.h"
#include "ProviderSettingsController.h"
#include "ShellStore.h"

namespace {

bool manages(const QJsonObject& provider) {
  return provider.value(QLatin1String("driver")).toString() == QLatin1String("antigravity");
}

bool running(const QJsonObject& state) {
  const QString phase = state.value(QLatin1String("phase")).toString();
  return phase == QLatin1String("downloading") || phase == QLatin1String("extracting") || phase == QLatin1String("verifying");
}

QString megabytes(double bytes) {
  return QString::number(bytes / 1'000'000, 'f', 1);
}

}  // namespace

void ProviderSettingsController::followRuntime() {
  const QString mc = m_store->mcServing(m_followed);
  QSet<QString> wanted;
  if (!mc.isEmpty() && m_providers) {
    for (const QJsonValue& value : *m_providers) {
      if (manages(value.toObject())) wanted.insert(value.toObject().value(QLatin1String("instanceId")).toString());
    }
  }
  for (auto it = m_install.begin(); it != m_install.end();) {
    if (wanted.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    m_installState.remove(it.key());
    it = m_install.erase(it);
  }
  for (const QString& instanceId : std::as_const(wanted)) {
    if (m_install.contains(instanceId)) continue;
    m_install.insert(instanceId, m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("providerInstall")},
                                                      {QStringLiteral("mc"), mc},
                                                      {QStringLiteral("instanceId"), instanceId}},
                                                     [this, instanceId](const QJsonObject& frame) {
                                                       if (frame.value(QLatin1String("t")) != QLatin1String("providerInstall")) return;
                                                       m_installState.insert(instanceId, frame.value(QLatin1String("state")).toObject());
                                                       publish();
                                                     }));
  }
}

void ProviderSettingsController::unfollowRuntime() {
  for (const int id : std::as_const(m_install)) m_client->unsubscribe(id);
  m_install.clear();
  m_installState.clear();
  m_installError.clear();
}

bool ProviderSettingsController::handleRuntime(const QString& action, const QVariantMap& input) {
  if (action != QLatin1String("providerSettings.runtimeInstall") && action != QLatin1String("providerSettings.runtimeCancel") &&
      action != QLatin1String("providerSettings.runtimeRemove")) {
    return false;
  }
  const QString instanceId = input.value(QStringLiteral("instanceId")).toString();
  if (!m_installState.contains(instanceId) || m_busy.contains(instanceId)) return true;
  const QJsonObject state = m_installState.value(instanceId);
  if (action == QLatin1String("providerSettings.runtimeInstall")) {
    runtimeCall(instanceId, QStringLiteral("provider.install.start"), {{QStringLiteral("instanceId"), instanceId}});
  } else if (action == QLatin1String("providerSettings.runtimeCancel")) {
    const QString operationId = state.value(QLatin1String("operationId")).toString();
    if (!running(state) || operationId.isEmpty()) return true;
    runtimeCall(instanceId, QStringLiteral("provider.install.cancel"),
                {{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("operationId"), operationId}});
  } else {
    auto* menu = NativeShell::of(this)->controller<MenuController>();
    if (!menu || running(state) || !state.value(QLatin1String("canRemove")).toBool()) return true;
    const QString environmentId = m_followed;
    menu->confirm(QStringLiteral("Remove runtime?"),
                  QStringLiteral("Remove the downloaded Antigravity runtime from %1? Google sign-in and thread history are kept.")
                      .arg(label(environmentId)),
                  QStringLiteral("Remove"), true, [this, instanceId, environmentId] {
                    // The answer may come after the user moved on.
                    if (m_followed != environmentId) return;
                    runtimeCall(instanceId, QStringLiteral("provider.install.remove"), {{QStringLiteral("instanceId"), instanceId}});
                  });
  }
  return true;
}

void ProviderSettingsController::runtimeCall(const QString& instanceId, const QString& method, const QJsonObject& payload) {
  if (m_busy.contains(instanceId) || m_followed.isEmpty()) return;
  m_busy.insert(instanceId);
  m_installError.remove(instanceId);
  publish();
  const quint64 following = m_following;
  m_client->call(this, m_followed, method, payload, [this, instanceId, following](const QJsonValue&, const std::optional<QString>& error) {
    if (m_following != following) return;
    m_busy.remove(instanceId);
    if (error) m_installError.insert(instanceId, error->isEmpty() ? QStringLiteral("Provider setup failed. Try again.") : *error);
    publish();
  });
}

QVariant ProviderSettingsController::runtime(const QJsonObject& provider) const {
  const QString instanceId = provider.value(QLatin1String("instanceId")).toString();
  if (!manages(provider) || !m_installState.contains(instanceId)) return QVariant::fromValue(nullptr);
  const QJsonObject state = m_installState.value(instanceId);
  const QString phase = state.value(QLatin1String("phase")).toString();
  const bool active = running(state);
  const double downloaded = state.value(QLatin1String("downloadedBytes")).toDouble();
  const double total = state.value(QLatin1String("totalBytes")).toDouble();
  const QString installedVersion = state.value(QLatin1String("installedVersion")).toString();
  const QString version = state.value(QLatin1String("version")).toString();
  const bool installed = provider.value(QLatin1String("installed")).toBool() || !installedVersion.isEmpty();
  const bool busy = m_busy.contains(instanceId);
  // ProviderSetupSection's status line.
  QString status;
  if (phase == QLatin1String("downloading")) {
    status = total > 0 ? QStringLiteral("Downloading %1 MB of %2 MB.").arg(megabytes(downloaded), megabytes(total))
                       : QStringLiteral("Downloading %1 MB.").arg(megabytes(downloaded));
  } else if (phase == QLatin1String("extracting")) {
    status = QStringLiteral("Extracting Antigravity.");
  } else if (phase == QLatin1String("verifying")) {
    status = QStringLiteral("Checking the downloaded runtime.");
  } else if (installed) {
    status = QStringLiteral("Installed.");
  } else if (total > 0) {
    status = QStringLiteral("%1 MB download.").arg(int(std::ceil(total / 1'000'000)));
  } else {
    status = QStringLiteral("Not installed.");
  }
  const QString message = state.value(QLatin1String("message")).toString();
  QString installLabel;
  if (!active && provider.value(QLatin1String("setup")).toObject().value(QLatin1String("canInstall")).toBool()) {
    installLabel = !installedVersion.isEmpty()
                       ? (!version.isEmpty() && version != installedVersion ? QStringLiteral("Update Antigravity")
                                                                            : QStringLiteral("Reinstall Antigravity"))
                   : phase == QLatin1String("failed") || phase == QLatin1String("cancelled") ? QStringLiteral("Retry installation")
                   : installed                                                                 ? QStringLiteral("Install managed runtime")
                                                                                               : QStringLiteral("Install Antigravity");
  }
  return QVariantMap{
      {QStringLiteral("status"), status},
      {QStringLiteral("message"), !active && message != status ? message : QString()},
      {QStringLiteral("progress"), phase == QLatin1String("downloading") && total > 0 ? std::min(1.0, downloaded / total) : -1.0},
      {QStringLiteral("installLabel"), installLabel},
      {QStringLiteral("canCancel"), active && !state.value(QLatin1String("operationId")).toString().isEmpty()},
      {QStringLiteral("canRemove"), !active && state.value(QLatin1String("canRemove")).toBool()},
      {QStringLiteral("busy"), busy},
      {QStringLiteral("error"), m_installError.value(instanceId)},
  };
}
