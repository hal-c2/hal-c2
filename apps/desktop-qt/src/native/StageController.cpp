// Which build the window is, said at a glance: a development shell, or one
// talking to a Nightly MC, marks the sidebar's brand band with its artwork or a
// version pill, as Settings → Appearance's Environment identification chooses.
//
// Publishes `stage`: {label ("Dev", "Nightly", or empty for a release), artwork
// ("dev", "nightly" or null), pill (the label or null)}. The Sidebar brick
// draws it; the window title carries the label.

#include "StageController.h"

#include <QObject>
#include <QRegularExpression>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

QString g_appStage;

class StageController : public QObject, public NativeController {
public:
  StageController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(m_store, &ShellStore::changed, this, &StageController::publish);
    if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
      connect(settings, &SettingsController::deviceChanged, this, &StageController::publish);
    }
    publish();
  }

  bool handle(const QString&, const QVariant&) override { return false; }

private:
  // The app's own stage, else "Nightly" for a nightly or preview build of the MC.
  QString label() const {
    if (!g_appStage.isEmpty()) return g_appStage;
    static const QRegularExpression nightly(QStringLiteral("^[^-+]+-(?:nightly|preview)\\.\\d{8}\\.\\d+$"));
    const QString version =
        m_store->environment(m_store->environmentOf(m_client->mc())).value(QLatin1String("serverVersion")).toString();
    return nightly.match(version).hasMatch() ? QStringLiteral("Nightly") : QString();
  }

  void publish() {
    const QString stage = label();
    const auto* settings = NativeShell::of(this)->controller<SettingsController>();
    const QString mode = settings ? settings->setting(QStringLiteral("environmentIdentificationMode")).toString() : QString();
    const bool marked = !stage.isEmpty();
    const QVariantMap state{
        {QStringLiteral("label"), stage},
        {QStringLiteral("artwork"), marked && mode == QLatin1String("artwork") ? QVariant(stage.toLower()) : QVariant::fromValue(nullptr)},
        {QStringLiteral("pill"), marked && mode == QLatin1String("pill") ? QVariant(stage) : QVariant::fromValue(nullptr)},
    };
    if (state == m_published) return;
    m_published = state;
    m_bridge->publish(QStringLiteral("stage"), state);
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QVariantMap m_published;
};

const NativeControllerRegistrar<StageController> registrar(QStringLiteral("stage"), {QStringLiteral("stage")});

}  // namespace

void stage::setAppStage(const QString& stage) {
  g_appStage = stage;
}
