#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Which of the open thread's notices above the composer is in front
// (`noticeStack`; NoticeStackController.cpp).
class NoticeStackController : public QObject, public NativeController {
  Q_OBJECT

public:
  NoticeStackController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // The notices now offered, most pressing first: "error", "limit",
  // "provider", "usageLimits", "activity", "settled".
  QStringList order() const;

private:
  void publish();

  ShellBridge* m_bridge;
  bool m_active = false;
  bool m_expanded = false;
  // The thread the expansion belongs to; another thread starts collapsed.
  QString m_threadKey;
};
