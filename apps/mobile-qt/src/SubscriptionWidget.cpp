#include "SubscriptionWidget.h"

#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "UsageController.h"

#ifdef Q_OS_ANDROID
#include <QJniObject>
#endif

namespace {

const QString kKey = QStringLiteral("usageWidget");
const QStringList kShows{QStringLiteral("session"), QStringLiteral("weekly"), QStringLiteral("both")};
// Limits are checked as often as the page checks them.
constexpr int kCheckMs = 5 * 60 * 1000;

#ifdef Q_OS_ANDROID
constexpr char kWidget[] = "io/github/halc2/mobile/UsageWidget";

class AndroidWidgetSystem : public WidgetSystem {
public:
  int placed() override {
    return QJniObject::callStaticMethod<jint>(kWidget, "placed", "(Landroid/content/Context;)I",
                                              QNativeInterface::QAndroidApplication::context().object());
  }
  void show(const QJsonObject& snapshot) override {
    const QString json = QString::fromUtf8(QJsonDocument(snapshot).toJson(QJsonDocument::Compact));
    QJniObject::callStaticMethod<void>(kWidget, "show", "(Landroid/content/Context;Ljava/lang/String;)V",
                                       QNativeInterface::QAndroidApplication::context().object(),
                                       QJniObject::fromString(json).object<jstring>());
  }
};
#endif

class NoWidgets : public WidgetSystem {
public:
  int placed() override { return 0; }
  void show(const QJsonObject&) override {}
};

}  // namespace

std::shared_ptr<WidgetSystem> deviceWidgetSystem() {
#ifdef Q_OS_ANDROID
  return std::make_shared<AndroidWidgetSystem>();
#else
  return std::make_shared<NoWidgets>();
#endif
}

namespace usage_widget {

bool shows(const QString& show, const QString& kind) {
  if (show == QLatin1String("session")) return kind == QLatin1String("session");
  if (show == QLatin1String("weekly")) return kind == QLatin1String("weekly");
  return true;
}

QJsonObject snapshot(const QVariantMap& limits, const QDateTime& now, const QHash<QString, QString>& choices) {
  QJsonArray providers;
  for (const QVariant& value : limits.value(QStringLiteral("pools")).toList()) {
    const QVariantMap pool = value.toMap();
    const QString driver = pool.value(QStringLiteral("driver")).toString();
    const QString show = choices.value(driver, QStringLiteral("both"));
    QJsonArray windows;
    qsizetype accounts = 0;
    QDateTime expires;
    for (const QVariant& entry : pool.value(QStringLiteral("windows")).toList()) {
      const QVariantMap window = entry.toMap();
      const QString kind = window.value(QStringLiteral("kind")).toString();
      accounts = std::max(accounts, window.value(QStringLiteral("accounts")).toList().size());
      if (!shows(show, kind)) continue;
      const QString resetsAt = window.value(QStringLiteral("resetsAt")).toString();
      const QDateTime at = QDateTime::fromString(resetsAt, Qt::ISODateWithMs);
      if (at.isValid() && (!expires.isValid() || at < expires)) expires = at;
      windows.append(QJsonObject{{QStringLiteral("kind"), kind},
                                 {QStringLiteral("label"), window.value(QStringLiteral("label")).toString()},
                                 {QStringLiteral("remainingPercent"), window.value(QStringLiteral("remainingPercent")).toInt()},
                                 {QStringLiteral("resetsAt"), resetsAt}});
    }
    if (windows.isEmpty()) continue;
    const QString detail = accounts > 1 ? QStringLiteral("%1 accounts · pooled").arg(accounts) : QStringLiteral("Subscription remaining");
    providers.append(QJsonObject{{QStringLiteral("driver"), driver},
                                 {QStringLiteral("label"), pool.value(QStringLiteral("label")).toString()},
                                 {QStringLiteral("detail"), detail},
                                 {QStringLiteral("expiresAt"), expires.isValid() ? expires.toUTC().toString(Qt::ISODateWithMs) : QString()},
                                 {QStringLiteral("windows"), windows}});
  }
  return {{QStringLiteral("url"), SubscriptionWidget::kLink},
          {QStringLiteral("checkedAt"), now.toUTC().toString(Qt::ISODateWithMs)},
          {QStringLiteral("providers"), providers}};
}

}  // namespace usage_widget

SubscriptionWidget::SubscriptionWidget(ShellBridge* bridge, NativeShell* shell, std::shared_ptr<WidgetSystem> system, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_shell(shell), m_system(std::move(system)) {
  m_bridge->declareKey(kKey);
  m_bridge->addInterceptor([self = QPointer<SubscriptionWidget>(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  if (auto* settings = m_shell->controller<SettingsController>()) {
    const QVariantMap kept = settings->deviceValue(kKey).toMap();
    for (auto it = kept.begin(); it != kept.end(); ++it) {
      if (kShows.contains(it.value().toString())) m_shows.insert(it.key(), it.value().toString());
    }
  }
  if (auto* usage = m_shell->controller<UsageController>()) {
    connect(usage, &UsageController::allLimitsChanged, this, [this](const QVariantMap& limits) {
      m_limits = limits;
      refresh();
      publish();
    });
  }
  // A link may wait for the environments to be known.
  connect(m_shell->store(), &ShellStore::changed, this, &SubscriptionWidget::openPending);
  m_checks.setInterval(kCheckMs);
  connect(&m_checks, &QTimer::timeout, this, [this] {
    if (auto* usage = m_shell->controller<UsageController>()) usage->checkLimits();
  });
  connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
    m_active = state == Qt::ApplicationActive;
    recheck();
  });
  m_active = QGuiApplication::applicationState() == Qt::ApplicationActive;
  recheck();
}

void SubscriptionWidget::recheck() {
  m_placed = m_system->placed() > 0;
  follow();
  // A widget placed while the app was away gets what is known at once.
  refresh();
  publish();
}

// Every environment's limits are followed while a widget shows them and the
// app is in front to read them.
void SubscriptionWidget::follow() {
  const bool followed = m_placed && m_active;
  if (followed == m_followed) return;
  m_followed = followed;
  if (followed) {
    m_checks.start();
  } else {
    m_checks.stop();
  }
  if (auto* usage = m_shell->controller<UsageController>()) usage->setFollowAll(followed);
}

// The widget is given what it shows, when that changed.
void SubscriptionWidget::refresh() {
  if (!m_placed || m_limits.isEmpty()) return;
  QJsonObject next = usage_widget::snapshot(m_limits, m_now(), m_shows);
  QJsonObject shown = next;
  shown.remove(QStringLiteral("checkedAt"));
  if (shown == m_shown) return;
  m_shown = shown;
  m_system->show(next);
}

bool SubscriptionWidget::handle(const QString& action, const QVariant& payload) {
  if (action != QLatin1String("usageWidget.show")) return false;
  const QVariantMap input = payload.toMap();
  const QString driver = input.value(QStringLiteral("driver")).toString();
  const QString show = input.value(QStringLiteral("show")).toString();
  if (driver.isEmpty() || !kShows.contains(show) || m_shows.value(driver, QStringLiteral("both")) == show) return true;
  m_shows.insert(driver, show);
  if (auto* settings = m_shell->controller<SettingsController>()) {
    QVariantMap kept;
    for (auto it = m_shows.begin(); it != m_shows.end(); ++it) kept.insert(it.key(), it.value());
    settings->writeDevice(kKey, kept);
  }
  refresh();
  publish();
  return true;
}

void SubscriptionWidget::openLink(const QUrl& url) {
  if (url.host() != QLatin1String("usage")) {
    if (m_next) m_next(url);
    return;
  }
  QMetaObject::invokeMethod(
      this,
      [this] {
        m_pending = true;
        openPending();
      },
      Qt::QueuedConnection);
}

void SubscriptionWidget::openPending() {
  if (!m_pending || m_shell->store()->environments().isEmpty()) return;
  m_pending = false;
  m_bridge->dispatch(QStringLiteral("usage.open"));
  m_bridge->dispatch(QStringLiteral("usage.metric"), QVariantMap{{QStringLiteral("metric"), QStringLiteral("limits")}});
}

void SubscriptionWidget::publish() {
  QVariantList providers;
  for (const QVariant& value : m_limits.value(QStringLiteral("pools")).toList()) {
    const QVariantMap pool = value.toMap();
    const QString driver = pool.value(QStringLiteral("driver")).toString();
    providers.append(QVariantMap{{QStringLiteral("driver"), driver},
                                 {QStringLiteral("label"), pool.value(QStringLiteral("label"))},
                                 {QStringLiteral("show"), m_shows.value(driver, QStringLiteral("both"))}});
  }
  m_bridge->publish(kKey, QVariantMap{{QStringLiteral("placed"), m_placed}, {QStringLiteral("providers"), providers}});
}
