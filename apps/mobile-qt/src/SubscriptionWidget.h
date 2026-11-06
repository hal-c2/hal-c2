#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include <functional>
#include <memory>

class NativeShell;
class ShellBridge;

// The home screen as far as the Subscription usage widget goes: how many of
// it the user placed, and what it draws. The widget itself (Android's
// UsageWidget.java) only draws the last snapshot it was given, the app not
// running. The scenarios put one of their own here (FakeWidgetSystem.h).
class WidgetSystem {
public:
  virtual ~WidgetSystem() = default;
  // How many of the widget are on the home screen; 0 where there is none.
  virtual int placed() = 0;
  // What every placed widget draws from now on: usage_widget::snapshot().
  virtual void show(const QJsonObject& snapshot) = 0;
};

// This device's: Android's home screen, or one without widgets.
std::shared_ptr<WidgetSystem> deviceWidgetSystem();

namespace usage_widget {

// What the widget shows of `limits` (UsageController's pooled `limits`) at
// `now`, each provider's windows as `shows` chooses them by driver: session,
// weekly, or both (also what an unchosen one shows):
// {url, checkedAt, providers [{driver, label, detail, expiresAt, windows
// [{kind, label, remainingPercent, resetsAt}]}]}. A provider's `expiresAt` is
// when the first of its shown windows resets, after which the widget says to
// open the app.
QJsonObject snapshot(const QVariantMap& limits, const QDateTime& now, const QHash<QString, QString>& shows);
// What `show` keeps of a pool's windows.
bool shows(const QString& show, const QString& kind);

}  // namespace usage_widget

// The Subscription usage widget's side in the app. While a widget is placed
// and the app is in front, every environment's limits are followed
// (UsageController::setFollowAll) and checked as Limits checks them, and the
// widget is given what they say whenever that changes. Tapping the widget
// opens the app on Limits (`hal-c2://usage/limits`).
//
// Publishes `usageWidget` {placed, providers [{driver, label, show}]}; the
// action `usageWidget.show {driver, show: session | weekly | both}` chooses a
// provider's windows, kept on this device.
class SubscriptionWidget : public QObject {
  Q_OBJECT

public:
  static inline const QString kLink = QStringLiteral("hal-c2://usage/limits");

  SubscriptionWidget(ShellBridge* bridge, NativeShell* shell, std::shared_ptr<WidgetSystem> system, QObject* parent = nullptr);

  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // The home screen may have changed while the app was away.
  void recheck();
  // A `hal-c2:` link the system opened the app with, from any thread: a
  // `usage` one opens Limits, others go to `next`.
  Q_INVOKABLE void openLink(const QUrl& url);
  void setNext(std::function<void(const QUrl&)> next) { m_next = std::move(next); }

private:
  bool handle(const QString& action, const QVariant& payload);
  void follow();
  void refresh();
  void openPending();
  void publish();

  ShellBridge* m_bridge;
  NativeShell* m_shell;
  std::shared_ptr<WidgetSystem> m_system;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  std::function<void(const QUrl&)> m_next;
  bool m_placed = false;
  bool m_active = false;
  bool m_followed = false;
  bool m_pending = false;
  QVariantMap m_limits;
  QHash<QString, QString> m_shows;
  // What the widget was last given, without its time.
  QJsonObject m_shown;
  QTimer m_checks;
};
