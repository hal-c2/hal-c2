#pragma once

#include <QCoreApplication>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QPointer>
#include <QString>

#include <functional>
#include <memory>
#include <optional>

#include "push/PushInbox.h"
#include "push/PushSystem.h"

// The phone's system as far as notifications go (src/push/PushSystem.h), for
// the scenarios (features/mobile/notifications.feature): the permission and
// what the user answers when asked, the UnifiedPush distributors installed
// and what reaches this phone through them, and the notifications on screen.
// What PushReceiver.java and DismissReceiver.java do on a phone, it does with
// the inbox itself. It outlives the app, as the system does: one a scenario.
class FakePushSystem : public PushSystem, public std::enable_shared_from_this<FakePushSystem> {
public:
  // A notification the system shows: an alert, or the activity card.
  struct Posted {
    QJsonObject effect;
    qint64 at = 0;
  };

  explicit FakePushSystem(QString dataDir) : m_dataDir(std::move(dataDir)) {}

  bool installed = true;  // false: a build that cannot receive pushes
  int androidSdk = 35;
  Permission granted = Permission::Ask;
  QList<Distributor> installedDistributors{{QStringLiteral("io.heckel.ntfy"), QStringLiteral("ntfy")}};
  qint64 clock = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate).toMSecsSinceEpoch();
  // The user force-stopped the app: Android sends it no broadcasts until it is opened.
  bool forceStopped = false;
  // The lock screen shows notifications' public versions alone.
  bool hideSensitive = false;
  int settingsOpened = 0;
  int liveUpdateSettingsOpened = 0;
  // The distributor the phone is registered with, and how often it asked.
  QString subscribed;
  int subscriptions = 0;
  QJsonArray channels;
  // Every alert posted, in order, and the ones still on screen.
  QList<Posted> alertsPosted;
  QList<Posted> alertsShown;
  QList<Posted> cardsPosted;
  // Messages on their way through the distributor: (endpoint, body).
  QList<std::pair<QString, QByteArray>> inFlight;

  // The address `distributor` gives this phone.
  static QString endpointOf(const QString& distributor) {
    return distributor == QLatin1String("io.heckel.ntfy") ? QStringLiteral("https://ntfy.sh/upPhoneA1") : QStringLiteral("https://push.example.org/%1/phone").arg(distributor);
  }

  bool supported() override { return installed; }
  int sdk() override { return installed ? androidSdk : 0; }
  Permission permission() override { return installed ? granted : Permission::Denied; }
  void requestPermission(QObject* context, std::function<void(Permission)> answered) override {
    m_asked = QPointer<QObject>(context);
    m_answer = std::move(answered);
  }
  bool asking() const { return bool(m_answer); }
  // The user answers the system's prompt.
  void answer(bool allow) {
    granted = allow ? Permission::Granted : Permission::Denied;
    auto answered = std::exchange(m_answer, {});
    if (answered && m_asked) answered(granted);
  }
  void openSettings() override { ++settingsOpened; }
  void openLiveUpdateSettings() override { ++liveUpdateSettingsOpened; }
  QList<Distributor> distributors() override { return installed ? installedDistributors : QList<Distributor>{}; }
  void subscribe(const QString& distributor) override {
    subscribed = distributor;
    ++subscriptions;
    // The distributor answers with NEW_ENDPOINT, which PushReceiver writes.
    QMetaObject::invokeMethod(
        qApp,
        [weak = weak_from_this(), distributor] {
          const auto self = weak.lock();
          if (!self || self->subscribed != distributor) return;
          push::Inbox(self->m_dataDir).setValue(QStringLiteral("endpoint"), endpointOf(distributor));
          if (self->changed) self->changed();
        },
        Qt::QueuedConnection);
  }
  void unsubscribe() override { subscribed.clear(); }
  void show(const QJsonObject& effects) override {
    if (effects.contains(QLatin1String("channels"))) channels = effects.value(QLatin1String("channels")).toArray();
    if (effects.value(QLatin1String("cancelCard")).toBool()) m_card.reset();
    const QJsonObject alert = effects.value(QLatin1String("alert")).toObject();
    if (!alert.isEmpty()) {
      alertsPosted.append({alert, clock});
      alertsShown.removeIf([&](const Posted& shown) { return shown.effect.value(QLatin1String("id")) == alert.value(QLatin1String("id")); });
      alertsShown.append({alert, clock});
    }
    const QJsonObject card = effects.value(QLatin1String("card")).toObject();
    if (!card.isEmpty()) {
      cardsPosted.append({card, clock});
      m_card = Posted{card, clock};
    }
  }
  qint64 now() override { return clock; }

  // The activity card on screen, until it times out.
  std::optional<QJsonObject> card() const {
    if (!m_card) return std::nullopt;
    const qint64 timeout = qint64(m_card->effect.value(QLatin1String("timeoutMs")).toDouble());
    if (timeout > 0 && clock >= m_card->at + timeout) return std::nullopt;
    return m_card->effect;
  }
  // The user swipes the card away, or taps its dismiss action.
  void dismissCard() {
    m_card.reset();
    show(push::Inbox(m_dataDir).dismiss());
  }
  // The user taps an alert: it goes, and its link (if any) is what opens.
  QString tapAlert(qsizetype index) {
    const QString link = alertsShown.at(index).effect.value(QLatin1String("link")).toString();
    if (!link.isEmpty()) alertsShown.removeAt(index);
    return link;
  }

  // What a distributor hands the phone reaches PushReceiver when it is
  // registered with that distributor and Android lets it run.
  void deliver() {
    const QList<std::pair<QString, QByteArray>> pending = std::exchange(inFlight, {});
    for (const auto& [endpoint, body] : pending) {
      if (forceStopped || subscribed.isEmpty() || endpoint != endpointOf(subscribed)) continue;
      show(push::Inbox(m_dataDir).receive(body, {clock, push::foreground(), permission() == Permission::Granted, sdk()}));
    }
  }
  // The user opens the app, which Android lets run again.
  void opened() { forceStopped = false; }
  // The user force-stops it: Android forgets what the distributor had of it.
  void forceStop() {
    forceStopped = true;
    subscribed.clear();
  }

private:
  QString m_dataDir;
  QPointer<QObject> m_asked;
  std::function<void(Permission)> m_answer;
  std::optional<Posted> m_card;
};
