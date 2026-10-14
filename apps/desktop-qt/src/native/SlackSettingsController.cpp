// Settings → Integrations → Slack: the Slack connection of the settings
// scope's first environment (HalC2.Slack on the MC serving it), followed
// through the MC's `slack` shape. Slack is changed one environment at a time:
// two MCs on one Slack app would split its Socket Mode events between them, so
// with several environments selected the section only shows the first and
// says so. The tokens go to the MC in `slack.connect` and never come back;
// the page learns only whether they are set.
//
// Publishes `slackSettings`: {open, loaded, editable, statusNote ("" unless
// several environments are selected), state (off | connecting | connected |
// reconnecting | failed), team, bot, error ("" or why the last change or the
// connection failed, whichever came last), tokensSet, pending (connect | disconnect | manifest, ""
// when idle)}.
//
// Actions (`slackSettings.`): `connect {botToken, appToken}`, `disconnect`,
// `copyManifest` (the Slack app manifest onto the clipboard).

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonObject>
#include <QPointer>
#include <QVariantMap>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("slackSettings");
const QString kSection = QStringLiteral("/settings/integrations");

}  // namespace

class SlackSettingsController : public QObject, public NativeController {
public:
  SlackSettingsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    connect(navigation, &NavigationController::changed, this, [this, navigation] { route(navigation); });
    connect(scope(), &SettingsScopeController::changed, this, &SlackSettingsController::follow);
    // A window restored on Integrations has its route before this activates.
    route(navigation);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(kKey + QLatin1Char('.'))) return false;
    const QString name = action.mid(kKey.size() + 1);
    if (!m_open || m_environmentId.isEmpty() || !m_pending.isEmpty()) return true;
    if (name == QLatin1String("connect")) {
      if (!editable()) return true;
      const QVariantMap input = payload.toMap();
      const QString bot = input.value(QStringLiteral("botToken")).toString().trimmed();
      const QString app = input.value(QStringLiteral("appToken")).toString().trimmed();
      if (bot.isEmpty() || app.isEmpty()) {
        m_error = QStringLiteral("Enter both the bot token and the app token.");
        publish();
        return true;
      }
      change(QStringLiteral("connect"), {{QStringLiteral("botToken"), bot}, {QStringLiteral("appToken"), app}});
    } else if (name == QLatin1String("disconnect")) {
      if (editable()) change(QStringLiteral("disconnect"), {});
    } else if (name == QLatin1String("copyManifest")) {
      copyManifest();
    }
    return true;
  }

private:
  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The environment whose connection shows: the scope's first connected one.
  QString inspected() const { return m_open ? scope()->targets().value(0) : QString(); }

  void route(const NavigationController* navigation) {
    const bool open = navigation->route().kind == QLatin1String("settings") && navigation->route().section == kSection;
    if (open == m_open) return;
    m_open = open;
    follow();
  }

  bool editable() const { return !scope()->projectScope() && scope()->editable() && scope()->targets().size() == 1; }

  void follow() {
    const QString environmentId = inspected();
    if (environmentId != m_environmentId) {
      if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
      m_subscription = -1;
      m_environmentId = environmentId;
      m_status = {};
      m_loaded = false;
      m_error.clear();
      // A call in flight answers for the old environment: the buttons are free again.
      m_pending.clear();
      ++m_generation;
      if (!environmentId.isEmpty()) {
        m_subscription = m_client->subscribe(
            this, {{QStringLiteral("type"), QStringLiteral("slack")}, {QStringLiteral("mc"), m_store->mcServing(environmentId)}},
            [this](const QJsonObject& frame) {
              if (frame.value(QLatin1String("t")) == QLatin1String("slack")) take(frame.value(QLatin1String("status")).toObject());
            });
      }
    }
    publish();
  }

  // A status from the MC is newer than the page's own error (a refusal, blank
  // tokens), so it replaces it; the status carries its own error.
  void take(const QJsonObject& status) {
    ++m_statuses;
    m_status = status;
    m_loaded = true;
    m_error.clear();
    publish();
  }

  // `slack.connect` or `slack.disconnect` on the inspected environment; each
  // answers with the connection as it now is, and Slack's refusal is its error.
  // The MC answers and pushes its status along different paths, so a status
  // that arrived while the call was out may be newer than the answer, which
  // then only frees the buttons.
  void change(const QString& pending, const QJsonObject& input) {
    m_pending = pending;
    m_error.clear();
    const QPointer<SlackSettingsController> self(this);
    const int generation = m_generation;
    const int statuses = m_statuses;
    m_client->call(this, m_environmentId, QStringLiteral("slack.") + pending, input,
                   [self, generation, statuses](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!self || self->m_generation != generation) return;
                     self->m_pending.clear();
                     if (self->m_statuses == statuses) {
                       if (error) self->m_error = *error;
                       else self->take(result.toObject());
                     }
                     self->publish();
                   });
    publish();
  }

  void copyManifest() {
    m_pending = QStringLiteral("manifest");
    const QPointer<SlackSettingsController> self(this);
    const int generation = m_generation;
    m_client->call(this, m_environmentId, QStringLiteral("slack.manifest"), QJsonObject{},
                   [self, generation](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!self || self->m_generation != generation) return;
                     self->m_pending.clear();
                     auto* toasts = NativeShell::of(self)->controller<ToastController>();
                     const QString manifest = result.toObject().value(QLatin1String("manifest")).toString();
                     if (error || manifest.isEmpty()) {
                       toasts->error(QStringLiteral("Could not copy the Slack app manifest"), error.value_or(QString()));
                     } else {
                       QGuiApplication::clipboard()->setText(manifest);
                       toasts->show(QStringLiteral("success"), QStringLiteral("Slack app manifest copied"),
                                    QStringLiteral("Paste it into a new app at api.slack.com/apps."));
                     }
                     self->publish();
                   });
    publish();
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    const QStringList targets = scope()->targets();
    const QString error = m_error.isEmpty() ? m_status.value(QLatin1String("error")).toString() : m_error;
    m_bridge->publish(
        kKey, QVariantMap{
                  {QStringLiteral("open"), true},
                  {QStringLiteral("loaded"), m_loaded},
                  {QStringLiteral("editable"), m_loaded && editable()},
                  {QStringLiteral("statusNote"),
                   targets.size() > 1 ? QStringLiteral("Slack for %1. Select one environment to connect or disconnect it.").arg(scope()->label(m_environmentId))
                                      : QString()},
                  {QStringLiteral("state"), m_status.value(QLatin1String("state")).toString(QStringLiteral("off"))},
                  {QStringLiteral("team"), m_status.value(QLatin1String("team")).toString()},
                  {QStringLiteral("bot"), m_status.value(QLatin1String("bot")).toString()},
                  {QStringLiteral("error"), error},
                  {QStringLiteral("tokensSet"), m_status.value(QLatin1String("tokensSet")).toBool()},
                  {QStringLiteral("pending"), m_pending},
              });
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QString m_environmentId;
  int m_subscription = -1;
  // Bumped when the inspected environment changes, so older answers are dropped.
  int m_generation = 0;
  QJsonObject m_status;
  // Counts the statuses taken, so a call's answer can tell whether one came since it was made.
  int m_statuses = 0;
  bool m_loaded = false;
  QString m_error;
  QString m_pending;
};

namespace {
const NativeControllerRegistrar<SlackSettingsController> registrar(QStringLiteral("slackSettings"), {kKey});
}  // namespace
