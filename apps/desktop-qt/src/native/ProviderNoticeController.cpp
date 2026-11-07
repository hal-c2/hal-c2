// What the open thread's provider says when it cannot run a turn, as the
// web's ProviderStatusBanner showed it over the timeline
// (features/timeline/runs-and-queue.feature): not installed, signed out,
// unavailable, or a version known to fail mid-turn even when ready. The
// thread's provider is its row's `modelSelection.instanceId`, read from the
// providers of the environment it runs on (WorkspaceController). Dismissing
// hides that problem of that provider until the app restarts; when the
// problem changes (another status, sign-in state or message) it shows again.
//
// Publishes `providerNotice`: null, or {threadKey, instanceId, title, message,
// warning, setup}; setup when provider setup can install or sign it in.
//
// Actions: `providerNotice.dismiss` hides the open thread's notice;
// `providerNotice.setup` opens Settings › Providers.

#include "ProviderNoticeController.h"

#include <QJsonArray>
#include <QVariantMap>

#include "NativeShell.h"
#include "NavigationController.h"
#include "ProviderUpdates.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<ProviderNoticeController> registrar(QStringLiteral("providerNotice"), {QStringLiteral("providerNotice")});

QString text(const QJsonObject& object, const QString& name) {
  return object.value(name).toString().trimmed();
}

}  // namespace

ProviderNoticeController::Notice ProviderNoticeController::noticeOf(const QJsonObject& provider) {
  const QString status = text(provider, QStringLiteral("status"));
  if (provider.isEmpty() || status.isEmpty() || status == QLatin1String("disabled")) return {};
  const QString driver = text(provider, QStringLiteral("driver"));
  const QString instanceId = text(provider, QStringLiteral("instanceId"));
  const QString version = text(provider, QStringLiteral("version"));
  const QString message = text(provider, QStringLiteral("message"));
  const QString auth = provider.value(QLatin1String("auth")).toObject().value(QLatin1String("status")).toString();
  const bool installed = provider.value(QLatin1String("installed")).toBool();
  const QString displayName = text(provider, QStringLiteral("displayName"));
  const QString driverLabel = providerUpdates::driverName(driver);
  const QString name = displayName.isEmpty() ? driverLabel : displayName;
  // Unsupported and broken versions fail mid-turn, so they warn even when ready.
  const QJsonObject compatibility = provider.value(QLatin1String("compatibilityAdvisory")).toObject();
  const QString incompatible = compatibility.value(QLatin1String("status")).toString();
  const bool incompatibleVersion = incompatible == QLatin1String("unsupported") || incompatible == QLatin1String("broken");
  const QChar nul(0);
  const QJsonObject setup = provider.value(QLatin1String("setup")).toObject();
  const bool canSetUp = driver == QLatin1String("antigravity") || setup.value(QLatin1String("canAuthenticate")).toBool() ||
                        setup.value(QLatin1String("canInstall")).toBool();
  if (status == QLatin1String("ready")) {
    if (!incompatibleVersion) return {};
    const QString advice = text(compatibility, QStringLiteral("message"));
    return {instanceId + nul + incompatible + nul + version,
            QStringLiteral("%1 %2 is %3").arg(name, version, incompatible == QLatin1String("broken") ? QStringLiteral("known to be broken") : QStringLiteral("unsupported")),
            !advice.isEmpty() ? advice : !message.isEmpty() ? message : QStringLiteral("No models are available for this provider."), true,
            canSetUp};
  }
  // Antigravity checks saved credentials when a session starts. Its local
  // health check leaves auth unknown after a restart, which is not a failure.
  if (driver == QLatin1String("antigravity") && installed && status == QLatin1String("warning") && auth == QLatin1String("unknown")) return {};
  QString said = message;
  if (said.isEmpty()) {
    if (!installed && canSetUp) {
      said = QStringLiteral("Open provider setup to install %1 on this environment.").arg(driverLabel);
    } else if (auth == QLatin1String("unauthenticated")) {
      said = !canSetUp ? QStringLiteral("Sign in via the CLI to authenticate again.")
             : driver == QLatin1String("antigravity") ? QStringLiteral("Open provider setup to sign in with Google.")
                                                       : QStringLiteral("Open provider setup to sign in.");
    } else if (status == QLatin1String("error")) {
      said = QStringLiteral("%1 provider is unavailable.").arg(name);
    } else {
      said = QStringLiteral("%1 provider has limited availability.").arg(name);
    }
  }
  const bool unauthenticated = status == QLatin1String("error") && auth == QLatin1String("unauthenticated");
  return {instanceId + nul + status + nul + auth + nul + message,
          unauthenticated ? QStringLiteral("%1 is unauthenticated").arg(name) : QStringLiteral("%1 provider status").arg(name), said,
          status == QLatin1String("warning"), canSetUp};
}

ProviderNoticeController::ProviderNoticeController(ShellBridge* bridge, McClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store) {}

void ProviderNoticeController::activate() {
  if (m_active) return;
  m_active = true;
  NativeWindow* shell = NativeShell::of(this);
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, &ProviderNoticeController::publish);
  connect(shell->controller<WorkspaceController>(), &WorkspaceController::configChanged, this, &ProviderNoticeController::publish);
  connect(m_store, &ShellStore::changed, this, &ProviderNoticeController::publish);
  publish();
}

bool ProviderNoticeController::handle(const QString& action, const QVariant&) {
  if (!m_active) return false;
  if (action == QLatin1String("providerNotice.dismiss")) {
    const Notice notice = noticeOf(provider(openKey()));
    if (!notice.key.isEmpty()) m_dismissed.insert(notice.key);
    publish();
    return true;
  }
  if (action == QLatin1String("providerNotice.setup")) {
    NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::settings(NavigationController::kProvidersSection));
    return true;
  }
  return false;
}

QString ProviderNoticeController::openKey() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

QJsonObject ProviderNoticeController::provider(const QString& key) const {
  if (key.isEmpty()) return {};
  const QString instanceId =
      m_store->threadRow(key).value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")).toString();
  if (instanceId.isEmpty()) return {};
  const QJsonArray providers =
      NativeShell::of(this)->controller<WorkspaceController>()->environmentConfig().value(QLatin1String("providers")).toArray();
  for (const QJsonValue& entry : providers) {
    if (entry.toObject().value(QLatin1String("instanceId")).toString() == instanceId) return entry.toObject();
  }
  return {};
}

void ProviderNoticeController::publish() {
  if (!m_active) return;
  const QString key = openKey();
  const QJsonObject entry = provider(key);
  const Notice notice = noticeOf(entry);
  if (notice.key.isEmpty() || m_dismissed.contains(notice.key)) {
    m_bridge->publish(QStringLiteral("providerNotice"), QVariant::fromValue(nullptr));
    return;
  }
  m_bridge->publish(QStringLiteral("providerNotice"), QVariantMap{{QStringLiteral("threadKey"), key},
                                                                    {QStringLiteral("instanceId"), entry.value(QLatin1String("instanceId")).toString()},
                                                                    {QStringLiteral("title"), notice.title},
                                                                    {QStringLiteral("message"), notice.message},
                                                                    {QStringLiteral("warning"), notice.warning},
                                                                    {QStringLiteral("setup"), notice.setup}});
}
