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
  // Clicking an action dismisses its toast first, unless it `keepsToast`
  // (a clone's Cancel and Retry, whose toast changes with what they start).
  struct Action {
    QString label;
    std::function<void()> run;
    bool keepsToast = false;
  };

  ToastController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Shows a toast of `type` (error, warning, success, info, loading) for
  // `timeoutMs` (0 keeps it until dismissed); returns its id. Clicking the
  // action runs it and dismisses the toast.
  QString show(const QString& type, const QString& title, const QString& description = {},
               std::optional<Action> action = {}, int timeoutMs = 5000);
  // A toast with a primary action and, second, a lesser one ("Retry" and
  // "Remove project").
  QString showActions(const QString& type, const QString& title, const QString& description, QList<Action> actions,
                      int timeoutMs);
  // An error toast, with the page's "An error occurred." for an empty reason.
  QString error(const QString& title, const QString& description = {});
  void dismiss(const QString& id);
  // Changes a shown toast's text in place (a running action's stage); false
  // once it is gone.
  bool update(const QString& id, const QString& title, const QString& description = {});
  // Turns a shown toast into another in place (a clone's running toast into
  // its success or failure), its time starting afresh; false once it is gone.
  bool replace(const QString& id, const QString& type, const QString& title, const QString& description,
               QList<Action> actions, int timeoutMs);
  // Runs the action of the newest toast offering `label` (the undo shortcut's
  // "Undo"), as clicking it would; false when none does.
  bool runAction(const QString& label);
  // Drops the toasts whose time is up; the timer calls it at the next deadline.
  void expire();

  QDateTime now() const { return m_now(); }
  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

signals:
  // The user closed the toast `id`, rather than it timing out or an action
  // being chosen.
  void closedByUser(const QString& id);

private:
  void publish();
  void schedule();

  struct Toast {
    QString id;
    QString type;
    QString title;
    QString description;
    QList<Action> actions;
    std::optional<QDateTime> deadline;
    int revision = 0;
  };

  ShellBridge* m_bridge;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QList<Toast> m_toasts;
  QTimer m_timer;
  int m_nextId = 1;
};
