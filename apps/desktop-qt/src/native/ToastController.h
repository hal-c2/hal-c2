#pragma once

#include <QDateTime>
#include <QList>
#include <QObject>
#include <QTimer>

#include <functional>
#include <optional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// The shell's own toasts. Controllers call show() directly; the Notifications
// brick renders `toasts` next to the page's `notifications` (git progress and
// whatever else the page still produces). Publishes `toasts`: {items}, newest
// first, each {id, type, title, description, updateKey, actions} as the page's
// ShellNotification. Ids start with "native:", which is how dismiss and action
// clicks find their way here instead of to the page.
class ToastController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Action {
    QString label;
    std::function<void()> run;
  };

  ToastController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Shows a toast of `type` (error, warning, success, info, loading) for
  // `timeoutMs` (0 keeps it until dismissed); returns its id. Clicking the
  // action runs it and dismisses the toast.
  QString show(const QString& type, const QString& title, const QString& description = {},
               std::optional<Action> action = {}, int timeoutMs = 5000);
  // An error toast, with the page's "An error occurred." for an empty reason.
  QString error(const QString& title, const QString& description = {});
  void dismiss(const QString& id);
  // Drops the toasts whose time is up; the timer calls it at the next deadline.
  void expire();

  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

private:
  void publish();
  void schedule();

  struct Toast {
    QString id;
    QString type;
    QString title;
    QString description;
    std::optional<Action> action;
    std::optional<QDateTime> deadline;
  };

  ShellBridge* m_bridge;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QList<Toast> m_toasts;
  QTimer m_timer;
  int m_nextId = 1;
};
