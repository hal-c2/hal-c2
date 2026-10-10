#pragma once

#include <QDateTime>
#include <QList>
#include <QObject>
#include <QTimer>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;

// The shell's toasts. Controllers call show() directly; the Notifications
// brick renders `toasts`. Publishes `toasts`: {items, expanded}, items newest
// first, each {id, type, title, description, updateKey, actions}. Dismiss and action clicks come back by id. No toast
// is dropped for lack of room: the brick stacks them, and `expanded` (the
// pointer over the stack, or a tap on a phone) spreads them out and holds
// every toast's time.
class ToastController : public QObject, public NativeController {
  Q_OBJECT

public:
  // Clicking an action dismisses its toast first, unless it `keepsToast`
  // (a clone's Cancel and Retry, whose toast changes with what they start).
  struct Action {
    QString label;
    std::function<void()> run;
    bool keepsToast = false;
    // What kind of change it takes back ("Settled", "Snoozed"): consecutive
    // toasts of one group are undone together.
    QString group;
  };

  ToastController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

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
  // The notice of a change the user can take back ("Settled", "Snoozed",
  // "Archived", "Unpinned": `group`, which runAction("Undo") undoes together).
  // A change straight after another of its group joins that toast, which then
  // reads "Settled 2 threads" and undoes both; `title` is what one change
  // reads. The description names the undo shortcut.
  QString showUndo(const QString& group, const QString& title, std::function<void()> undo);
  // An error toast, with "An error occurred." for an empty reason.
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
  // "Undo"), as clicking it would; false when none does. The toasts next to
  // it offering the same action for the same group run with it.
  bool runAction(const QString& label);
  // Drops the toasts whose time is up; the timer calls it at the next deadline.
  void expire();
  // Spreads the stack out and holds every toast's remaining time until it
  // collapses again; `notification.expand` {expanded} from the brick. It
  // collapses by itself once the last toast goes.
  void setExpanded(bool expanded);
  bool expanded() const { return m_expanded; }

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
    // Set while its time runs; while the stack is expanded the time left
    // sits in `remainingMs` instead.
    std::optional<QDateTime> deadline;
    qint64 remainingMs = 0;
    int revision = 0;
    // The changes its Undo takes back (showUndo); one again once replace()
    // gives it other actions.
    int count = 1;
  };

  void startTime(Toast& toast, int timeoutMs);

  ShellBridge* m_bridge;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QList<Toast> m_toasts;
  QTimer m_timer;
  int m_nextId = 1;
  bool m_expanded = false;
};
