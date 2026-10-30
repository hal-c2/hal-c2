#include "Notifications.h"

#include <QDateTime>
#include <QGuiApplication>
#include <QJsonArray>
#include <QPointer>

#include "AlertController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Pairing.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"

namespace {

const QString kKey = QStringLiteral("notifications");
constexpr qint64 kFinished = 15 * 60 * 1000;

QString permissionName(PushSystem::Permission permission) {
  switch (permission) {
    case PushSystem::Permission::Granted:
      return QStringLiteral("granted");
    case PushSystem::Permission::Denied:
      return QStringLiteral("denied");
    case PushSystem::Permission::Ask:
      break;
  }
  return QStringLiteral("ask");
}

QString base64Url(const QByteArray& bytes) {
  return QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

qint64 epoch(const std::optional<QString>& iso) { return sidebar::parseIso(iso).value_or(0); }

// The phase of a thread as the MC's activity rows have it, or "" when it has
// none to show.
QString phaseOf(const sidebar::Thread& thread, qint64 now, qint64* at) {
  *at = epoch(thread.updatedAt);
  if (thread.hasPendingUserInput) return QStringLiteral("waiting_for_input");
  if (thread.hasPendingApprovals) return QStringLiteral("waiting_for_approval");
  if (!thread.latestRun) return {};
  const QString status = thread.latestRun->status;
  if (status == QLatin1String("preparing") || status == QLatin1String("starting") || status == QLatin1String("queued") ||
      status == QLatin1String("requested")) {
    return QStringLiteral("starting");
  }
  if (status == QLatin1String("running") || status == QLatin1String("waiting")) return QStringLiteral("running");
  const bool completed = status == QLatin1String("completed");
  if (!completed && status != QLatin1String("failed")) return {};
  *at = epoch(thread.latestRun->completedAt);
  if (*at == 0 || *at < now - kFinished) return {};
  return completed ? QStringLiteral("completed") : QStringLiteral("failed");
}

}  // namespace

Notifications::Notifications(ShellBridge* bridge, NativeShell* shell, Pairing* pairing, std::shared_ptr<PushSystem> system,
                             const QString& dataDir, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_shell(shell), m_pairing(pairing), m_system(std::move(system)), m_inbox(dataDir) {
  bridge->declareKey(kKey);
  bridge->addInterceptor([self = QPointer<Notifications>(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  m_permission = m_system->permission();
  m_system->changed = [self = QPointer<Notifications>(this)] {
    if (!self) return;
    // A distributor that let go of the phone: the MC stops pushing to it.
    if (self->m_inbox.value(QStringLiteral("endpoint")).toString().isEmpty() && self->m_shell->client()->isReady()) {
      self->m_registered = {};
      McClient* client = self->m_shell->client();
      client->call(self, client->environment(), QStringLiteral("hal-c2.unregisterPush"), QJsonObject{},
                   [](const QJsonValue&, const std::optional<QString>&) {});
    }
    self->registerPush();
    self->publish();
  };
  connect(shell->client(), &McClient::readyChanged, this, [this](bool ready) {
    m_registered = {};
    if (ready) registerPush();
  });
  connect(shell->store(), &ShellStore::changed, this, [this] {
    updateActivity(false);
    openPending();
  });
  if (auto* settings = shell->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, [this] {
      registerPush();
      publish();
    });
  }
  connect(qGuiApp, &QGuiApplication::applicationStateChanged, this,
          [this](Qt::ApplicationState state) { activeChanged(state == Qt::ApplicationActive); });
  publish();
}

void Notifications::start() {
  // The channels exist before anything is posted, so the system settings list them.
  if (m_system->supported()) show(push::channels());
  // A distributor's endpoint can change while the app is away, and one that
  // was force-stopped forgets it: asking again on each start keeps it current.
  const QString distributor = m_inbox.value(QStringLiteral("distributor")).toString();
  if (m_system->supported() && !distributor.isEmpty() && m_permission == PushSystem::Permission::Granted) m_system->subscribe(distributor);
  activeChanged(qGuiApp->applicationState() == Qt::ApplicationActive);
}

void Notifications::openLink(const QUrl& url) {
  if (url.host() != QLatin1String("threads")) {
    m_pairing->openLink(url);
    return;
  }
  QMetaObject::invokeMethod(
      this,
      [this, url] {
        const auto [environment, thread] = push::parseThreadLink(url.toString(QUrl::FullyEncoded));
        if (environment.isEmpty()) return;
        m_pending = environment + QLatin1Char(':') + thread;
        openPending();
      },
      Qt::QueuedConnection);
}

bool Notifications::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("notifications.enable")) {
    enable();
  } else if (action == QLatin1String("notifications.disable") || action == QLatin1String("notifications.openSettings")) {
    // Android has no way back from "allowed" but its own settings.
    m_system->openSettings();
  } else if (action == QLatin1String("notifications.openLiveUpdateSettings")) {
    m_system->openLiveUpdateSettings();
  } else if (action == QLatin1String("notifications.pickDistributor")) {
    const QString id = map.value(QStringLiteral("id")).toString();
    const QList<PushSystem::Distributor> installed = m_system->distributors();
    if (std::none_of(installed.begin(), installed.end(), [&](const PushSystem::Distributor& d) { return d.id == id; })) return true;
    const QString previous = m_inbox.value(QStringLiteral("distributor")).toString();
    if (previous != id && !previous.isEmpty()) {
      m_system->unsubscribe();
      m_inbox.setValue(QStringLiteral("endpoint"), QString());
    }
    m_inbox.setValue(QStringLiteral("distributor"), id);
    m_choosing = false;
    subscribe();
  } else if (action == QLatin1String("notifications.cancelPick")) {
    m_choosing = false;
    publish();
  } else if (action == QLatin1String("notifications.setLiveActivity")) {
    setLiveActivity(map.value(QStringLiteral("on")).toBool());
  } else if (action == QLatin1String("notifications.setQuietHours")) {
    const QVariant value = map.value(QStringLiteral("quietHours"));
    m_inbox.setValue(QStringLiteral("quietHours"), value.isNull() ? QJsonValue() : QJsonValue(QJsonObject::fromVariantMap(value.toMap())));
    registerPush();
    publish();
  } else if (action == QLatin1String("alerts.setMuted")) {
    // Mutes are the desktop's (AlertController), which the registration
    // follows (deviceChanged).
    if (auto* alerts = m_shell->controller<AlertController>()) {
      alerts->setMuted(map.value(QStringLiteral("key")).toString(), map.value(QStringLiteral("muted")).toBool());
    }
  } else {
    return false;
  }
  return true;
}

void Notifications::enable() {
  if (!m_system->supported()) return;
  m_message.clear();
  m_permission = m_system->permission();
  if (m_permission == PushSystem::Permission::Granted) {
    subscribe();
    return;
  }
  const auto refused = [this] {
    m_message = tr("HAL-C2 is not allowed to notify. Allow it in the system settings.");
    publish();
  };
  if (m_permission == PushSystem::Permission::Denied) {
    refused();
    return;
  }
  m_system->requestPermission(this, [this, refused](PushSystem::Permission permission) {
    m_permission = permission;
    if (permission == PushSystem::Permission::Granted) {
      subscribe();
    } else {
      refused();
    }
  });
}

void Notifications::subscribe() {
  const QList<PushSystem::Distributor> installed = m_system->distributors();
  QString chosen = m_inbox.value(QStringLiteral("distributor")).toString();
  if (std::none_of(installed.begin(), installed.end(), [&](const PushSystem::Distributor& d) { return d.id == chosen; })) {
    chosen = installed.size() == 1 ? installed.first().id : QString();
  }
  if (!chosen.isEmpty()) {
    m_inbox.setValue(QStringLiteral("distributor"), chosen);
    m_message.clear();
    m_system->subscribe(chosen);
  } else if (installed.isEmpty()) {
    m_message = tr("Install a UnifiedPush distributor, such as ntfy, to receive notifications.");
  } else {
    m_choosing = true;
  }
  publish();
}

void Notifications::setLiveActivity(bool on) {
  m_permission = m_system->permission();
  if (on && m_permission != PushSystem::Permission::Granted) {
    m_message = tr("Ongoing activity needs notification permission. Allow notifications for HAL-C2 in the system settings.");
    publish();
    return;
  }
  m_message.clear();
  show(m_inbox.setLiveActivity(on));
  m_activity = {};
  if (on) updateActivity(true);
  registerPush();
  publish();
}

void Notifications::activeChanged(bool active) {
  m_active = active;
  push::setForeground(active);
  if (!active) return;
  // Allowed or blocked in the system's settings while the app was away.
  m_permission = m_system->permission();
  registerPush();
  updateActivity(true);
  publish();
}

QJsonObject Notifications::quietHours() {
  const QJsonValue value = m_inbox.value(QStringLiteral("quietHours"));
  return value.isObject() ? value.toObject() : QJsonObject();
}

void Notifications::registerPush() {
  McClient* client = m_shell->client();
  const QString endpoint = m_inbox.value(QStringLiteral("endpoint")).toString();
  if (!client->isReady() || !m_system->supported() || m_permission != PushSystem::Permission::Granted || endpoint.isEmpty()) return;
  const push::Keys keys = m_inbox.keys();
  if (!keys.valid()) return;
  QJsonArray muted;
  if (const auto* settings = m_shell->controller<SettingsController>()) {
    muted = settings->deviceSettings().value(AlertController::kMutedKey).toArray();
  }
  QJsonValue quiet = QJsonValue::Null;
  if (QJsonObject hours = quietHours(); !hours.isEmpty()) {
    // The MC keeps quiet hours by this phone's clock, so it is sent again
    // when that moves (activeChanged).
    hours.insert(QStringLiteral("utcOffsetMinutes"), QDateTime::currentDateTime().offsetFromUtc() / 60);
    quiet = hours;
  }
  const QJsonObject registration{
      {QStringLiteral("endpoint"), endpoint},
      {QStringLiteral("keys"), QJsonObject{{QStringLiteral("p256dh"), base64Url(keys.publicKey)}, {QStringLiteral("auth"), base64Url(keys.auth)}}},
      {QStringLiteral("distributor"), m_inbox.value(QStringLiteral("distributor")).toString()},
      {QStringLiteral("liveActivity"), m_inbox.liveActivity()},
      {QStringLiteral("mutedThreads"), muted},
      {QStringLiteral("quietHours"), quiet},
  };
  if (registration == m_registered) return;
  m_registered = registration;
  client->call(this, client->environment(), QStringLiteral("hal-c2.registerPush"), registration,
               [this, registration](const QJsonValue&, const std::optional<QString>& error) {
                 if (!error) return;
                 if (m_registered == registration) m_registered = {};
                 m_message = tr("The phone could not be registered for notifications: %1").arg(*error);
                 publish();
               });
}

void Notifications::updateActivity(bool force) {
  ShellStore* store = m_shell->store();
  // Before the rows are in, the shell knows of no work: no reason to end a card.
  if (!m_active || !m_system->supported() || !m_inbox.liveActivity() || !store->synchronized()) return;
  const qint64 now = m_system->now();
  QList<push::ActivityRow> rows;
  for (const sidebar::Thread& thread : store->threads()) {
    if (thread.subagent || thread.archivedAt || !thread.listed) continue;
    qint64 at = 0;
    const QString phase = phaseOf(thread, now, &at);
    if (phase.isEmpty()) continue;
    const auto project = store->project(thread.environmentId + QLatin1Char(':') + thread.projectId);
    rows.append({phase, thread.title, project ? project->title : QString(), thread.environmentId, thread.id, at});
  }
  const QJsonObject activity = push::activity(rows, now);
  QJsonObject compared = activity;
  compared.remove(QStringLiteral("expiresAt"));
  if (!force && compared == m_activity) return;
  m_activity = compared;
  show(m_inbox.deliver({{QStringLiteral("v"), 1}, {QStringLiteral("sentAt"), double(now)}, {QStringLiteral("activity"), activity}}, device()));
}

void Notifications::show(const QJsonObject& effects) { m_system->show(effects); }

void Notifications::openPending() {
  if (m_pending.isEmpty()) return;
  ShellStore* store = m_shell->store();
  // A notification from before the thread moved opens it where it lives now.
  const QString key = store->located(m_pending);
  if (!store->thread(key)) return;
  m_pending.clear();
  auto* navigation = m_shell->controller<NavigationController>();
  if (!navigation || navigation->route() == NavigationController::Route::thread(key)) return;
  navigation->open(NavigationController::Route::thread(key));
}

push::Device Notifications::device() const {
  return {m_system->now(), m_active, m_permission == PushSystem::Permission::Granted, m_system->sdk()};
}

void Notifications::publish() {
  QVariantList distributors;
  for (const PushSystem::Distributor& distributor : m_system->distributors()) {
    distributors.append(QVariantMap{{QStringLiteral("id"), distributor.id}, {QStringLiteral("label"), distributor.label}});
  }
  const QJsonObject quiet = quietHours();
  QStringList muted;
  if (const auto* settings = m_shell->controller<SettingsController>()) {
    muted = settings->deviceSettings().value(AlertController::kMutedKey).toVariant().toStringList();
  }
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("supported"), m_system->supported()},
                              {QStringLiteral("permission"), permissionName(m_permission)},
                              {QStringLiteral("enabled"), m_system->supported() && m_permission == PushSystem::Permission::Granted &&
                                                              !m_inbox.value(QStringLiteral("endpoint")).toString().isEmpty()},
                              {QStringLiteral("distributors"), distributors},
                              {QStringLiteral("distributor"), m_inbox.value(QStringLiteral("distributor")).toString()},
                              {QStringLiteral("choosing"), m_choosing},
                              {QStringLiteral("liveActivity"), m_inbox.liveActivity() && m_permission == PushSystem::Permission::Granted},
                              {QStringLiteral("liveUpdates"), m_system->sdk() >= 36},
                              {QStringLiteral("quietHours"), quiet.isEmpty() ? QVariant() : QVariant(quiet.toVariantMap())},
                              {QStringLiteral("muted"), muted},
                              {QStringLiteral("message"), m_message},
                          });
}
