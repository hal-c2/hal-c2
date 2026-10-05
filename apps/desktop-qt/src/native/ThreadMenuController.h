#pragma once

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <functional>

#include "CommandRegistry.h"
#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;
class ToastController;

// A thread's action menu, from its sidebar row (`thread.menu {key, x, y}`)
// and from the header's title (`workspace.titleMenu {x, y}`, the route's
// thread, or its draft's menu). Items follow the web app's
// buildThreadActionMenuItems order, plus Fork and Move to another machine;
// the environment's capabilities leave items out and an offline environment
// turns the ones that need it off. Each action toasts its failure, and the
// ones that hide a thread (archive, unpin, settle, snooze) offer Undo.
//
// With several threads selected (SidebarController::selection), the menu of
// one of them is the selection's: each action names how many threads it
// touches, as the web app's sidebar ("Unpin (1)", "Settle (3)", "Delete (3)"),
// and applies to all of them. Deleting keeps the threads that could not be
// deleted selected.
//
// The route thread's keybinding commands (thread.pin, thread.settle,
// thread.undo) run here too (KeybindingController), and it registers its own
// the palette offers for the route thread: thread.copyReference ("Copy PR
// link" or "Copy thread ID", with what it copies), projectSettings.open
// ("Project settings", with the project's name) and thread.move ("Move to
// another machine", a menu of the cluster's other machines, listed while
// there is one).
//
// A move asks what `hal-c2.moveThread` asks (what stays behind, which
// project) where it was started: the menu's point, or the palette. A thread
// whose agent is working is not moved by the MC, so the user is offered to
// stop the turn first; the move is sent once the thread's row shows it idle.
class ThreadMenuController : public QObject, public NativeController {
  Q_OBJECT

public:
  ThreadMenuController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  static inline const QString kCopyReference = QStringLiteral("thread.copyReference");
  static inline const QString kProjectSettingsCommand = QStringLiteral("projectSettings.open");
  static inline const QString kMove = QStringLiteral("thread.move");

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Opens the menu of the thread `key` at window coordinates; false when the
  // shell does not know the thread. `header` leaves out the project filter.
  bool open(const QString& key, double x, double y, bool header);

  // The route thread's commands.
  void togglePin(const QString& key);
  void toggleSettle(const QString& key);
  void copyReference(const QString& key);
  // Runs the newest Undo on offer.
  void undo();

  // Writes the clipboard, false when it could not; tests make it fail.
  void setClipboardWriter(std::function<bool(const QString& text)> write) { m_writeClipboard = std::move(write); }
  // Puts `value` on the clipboard and says so, or why not.
  void copy(const QString& value, const QString& successTitle, const QString& failureTitle);

private:
  void choose(const QString& key, const QString& id, double x, double y);
  void openSelection(const QStringList& keys, double x, double y);
  void chooseForSelection(const QStringList& keys, const QString& id);
  // Sends each thread's command; `done` gets the keys that failed and the
  // first failure's reason once every answer is in.
  void commandEach(const QStringList& keys, const std::function<QJsonObject(const QString& threadId)>& make,
                   std::function<void(const QStringList& failed, const QString& reason)> done);
  void command(const QString& key, QJsonObject command, const QString& failureTitle,
               std::function<void()> onSuccess = {});
  void archive(const QString& key);
  // Deleting the last thread of a worktree offers to remove the worktree too
  // (`vcs.removeWorktree`), or removes it unasked when the environment's
  // cleanup rules say so (storageCleanup.worktreeOnDelete, or the project's own).
  void remove(const QString& key);
  void removeWith(const QString& key, const QString& worktree);
  // The thread's worktree when no other thread uses it, else empty.
  QString orphanedWorktree(const QString& key) const;
  void pin(const QString& key);
  void unpin(const QString& key);
  void fork(const QString& key);
  // Where a move's questions are asked: a menu at the point, or the palette.
  struct Asking {
    double x = 0;
    double y = 0;
    bool palette = false;
  };
  // Where a thread moves to. Labels are the user's own and may repeat, so the
  // environment id is what is sent and the label what is shown.
  struct Machine {
    QString id;
    QString label;
  };
  void chooseDestination(const QString& key, double x, double y);
  // The move the user chose: sent as it is, or after stopping the thread's turn.
  void startMove(const QString& key, const Machine& machine, const Asking& asking);
  void move(const QString& key, const Machine& machine, const QString& projectId, bool confirmed,
            const Asking& asking);
  // Sends the moves that waited for their thread's turn to stop.
  void moveStopped();
  void newThreadOnBranch(const QString& key);
  QString workspacePath(const QString& key) const;
  ToastController* toasts() const;
  // The thread's PR link, else empty (its id is the reference).
  QString pullRequestUrl(const QString& key) const;
  void openProjectSettings(const QString& key);
  // What the palette shows of the route thread's commands.
  void present();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<bool(const QString&)> m_writeClipboard;
  // Moves waiting for their thread's turn to stop, by thread key.
  struct Stopping {
    Machine machine;
    Asking asking;
    QString toast;
  };
  QHash<QString, Stopping> m_stopping;
  // The projects a move from the palette may go into, and the move.
  QList<CommandRegistry::Choice> m_projectChoices;
};
