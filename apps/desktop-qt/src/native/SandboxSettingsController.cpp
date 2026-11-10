// Settings → Review sandboxes: whether this environment can run code reviews
// in an OpenShell sandbox, and when it can't, why and what to do, from the
// MC's `server.getOpenShellStatus` (apps/server-ex HalC2.OpenShell.Command).
// Read when the page opens and on refresh; never pushed or polled.
//
// Publishes `sandboxSettings`: {
//   loading,
//   state: loading | error | unsupported | attention | ready,
//   summary, detail, error (string | null),
//   problems: [{code, message}]}
// where state is what the last answer said (loading until one lands) and
// `loading` is whether a read is out. Only the latest read lands.
//
// Actions: `sandboxSettings.refresh`.

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"

namespace {

const QString kSection = QStringLiteral("/settings/sandboxes");

QString modeName(const QString& mode) {
  if (mode == QLatin1String("managed")) return QStringLiteral("run by this MC");
  if (mode == QLatin1String("external")) return QStringLiteral("a gateway you run");
  if (mode == QLatin1String("foreground")) return QStringLiteral("the dev run");
  return mode;
}

}  // namespace

class SandboxSettingsController : public QObject, public NativeController {
public:
  SandboxSettingsController(ShellBridge* bridge, McClient* client, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    auto opened = [navigation] { return navigation->route() == NavigationController::Route::settings(kSection); };
    connect(navigation, &NavigationController::changed, this, [this, opened] {
      const bool open = opened();
      if (open == m_open) return;
      m_open = open;
      if (open) read();
    });
    m_open = opened();
    if (m_open) read();
    publish();
  }

  bool handle(const QString& action, const QVariant&) override {
    if (!m_active || action != QLatin1String("sandboxSettings.refresh")) return false;
    read();
    return true;
  }

private:
  void read() {
    m_loading = true;
    const quint64 generation = ++m_generation;
    m_client->call(this, m_client->environment(), QStringLiteral("server.getOpenShellStatus"), QJsonObject(),
                   [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation) return;
                     m_loading = false;
                     m_landed = true;
                     m_error = error ? (error->isEmpty() ? QStringLiteral("The MC did not say why.") : *error) : QString();
                     m_status = error ? QJsonObject() : result.toObject();
                     publish();
                   });
    publish();
  }

  void publish() {
    if (!m_active) return;
    QVariantList problems;
    for (const QJsonValue& value : m_status.value(QLatin1String("problems")).toArray()) {
      const QJsonObject problem = value.toObject();
      problems.append(QVariantMap{{QStringLiteral("code"), problem.value(QLatin1String("code")).toString()},
                                  {QStringLiteral("message"), problem.value(QLatin1String("message")).toString()}});
    }
    QString state;
    QString summary;
    QString detail;
    if (!m_landed) {
      state = QStringLiteral("loading");
      summary = QStringLiteral("Asking the MC whether review sandboxes can run here…");
    } else if (!m_error.isEmpty()) {
      state = QStringLiteral("error");
      summary = QStringLiteral("Could not read whether review sandboxes can run here.");
    } else if (!m_status.value(QLatin1String("supported")).toBool()) {
      state = QStringLiteral("unsupported");
      summary = QStringLiteral("Review sandboxes can't run on this machine.");
      detail = QStringLiteral("Code reviews run without a sandbox here.");
    } else if (!m_status.value(QLatin1String("ready")).toBool()) {
      state = QStringLiteral("attention");
      summary = QStringLiteral("Review sandboxes can't run here yet.");
      detail = QStringLiteral("OpenShell %1 is the version this MC pins.").arg(m_status.value(QLatin1String("pinnedVersion")).toString());
    } else {
      state = QStringLiteral("ready");
      summary = QStringLiteral("Review sandboxes can run here.");
      const QString version = m_status.value(QLatin1String("version")).toString();
      detail = (version.isEmpty() ? QStringLiteral("OpenShell, %1.") : QStringLiteral("OpenShell %2, %1."))
                   .arg(modeName(m_status.value(QLatin1String("mode")).toString()), version);
    }
    m_bridge->publish(QStringLiteral("sandboxSettings"),
                      QVariantMap{{QStringLiteral("loading"), m_loading},
                                  {QStringLiteral("state"), state},
                                  {QStringLiteral("summary"), summary},
                                  {QStringLiteral("detail"), detail},
                                  {QStringLiteral("error"), m_error.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(m_error)},
                                  {QStringLiteral("problems"), problems}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  bool m_active = false;
  bool m_open = false;
  bool m_loading = false;
  // An answer, or an error, has landed.
  bool m_landed = false;
  quint64 m_generation = 0;
  QString m_error;
  QJsonObject m_status;
};

namespace {
const NativeControllerRegistrar<SandboxSettingsController> registrar(QStringLiteral("sandboxSettings"), {QStringLiteral("sandboxSettings")});
}  // namespace
