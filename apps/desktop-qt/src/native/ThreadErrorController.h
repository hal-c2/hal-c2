#pragma once

#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The open thread's error banner (`threadError`; ThreadErrorController.cpp).
class ThreadErrorController : public QObject, public NativeController {
  Q_OBJECT

public:
  ThreadErrorController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Something this client could not do on the thread `threadKey`: it is the
  // thread's error until dismissed.
  void report(const QString& threadKey, const QString& message);

private:
  struct Shown {
    QString message;
    bool warning = false;
  };
  QString openKey() const;
  // What a dismissal of `message` on the thread `key` hides: that message
  // while the thread's latest run is the one now.
  QString dismissal(const QString& key, const QString& message) const;
  Shown shown(const QString& key) const;
  void publish();

  ShellBridge* m_bridge;
  ShellStore* m_store;
  bool m_active = false;
  // This client's own errors, by thread key.
  QHash<QString, QString> m_local;
  // Errors the user dismissed: thread key, NUL, latest run, NUL, message.
  QSet<QString> m_dismissed;
};
