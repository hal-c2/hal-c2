#pragma once

#include <QHash>
#include <QObject>
#ifdef HAL_C2_HAS_DBUS
#include <QDBusMessage>
#endif

// The desktop's notification service (org.freedesktop.Notifications), where
// AlertController's system notifications go; off until enabled. One
// notification per key: a newer one replaces it, and clicking an older one
// still reports its own key, even after newer ones were delivered.
class NativeNotifications : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
  Q_PROPERTY(bool supported READ supported NOTIFY supportedChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
  explicit NativeNotifications(QObject* parent = nullptr);
  ~NativeNotifications() override;
  bool enabled() const { return m_enabled; }
  void setEnabled(bool enabled);
  bool supported() const { return m_supported; }
  QString lastError() const { return m_lastError; }
  Q_INVOKABLE bool show(const QString& key, const QString& title, const QString& body,
                        bool silent = false, int timeoutMs = -1);
  // Closes every notification shown.
  Q_INVOKABLE void closeAll();

signals:
  void enabledChanged();
  void supportedChanged();
  void lastErrorChanged();
  void activated(const QString& key);

private slots:
#ifdef HAL_C2_HAS_DBUS
  void notificationAction(uint id, const QString& action, const QDBusMessage& message);
  void notificationClosed(uint id, uint reason, const QDBusMessage& message);
#endif
  void refreshSupport();

private:
  void setError(const QString& error);
  bool m_enabled = false;
  bool m_supported = false;
  uint m_generation = 0;
  QString m_lastError;
  QString m_serviceOwner;
  QHash<uint, QString> m_notifications;
};
