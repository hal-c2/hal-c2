#pragma once

#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <functional>

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
// thread.undo) run here too (KeybindingController), and it registers two of
// its own the palette offers for the route thread: thread.copyReference
// ("Copy PR link" or "Copy thread ID", with what it copies) and
// projectSettings.open ("Project settings", with the project's name).
class ThreadMenuController : public QObject, public NativeController {
  Q_OBJECT

public:
  ThreadMenuController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  static inline const QString kCopyReference = QStringLiteral("thread.copyReference");
  static inline const QString kProjectSettingsCommand = QStringLiteral("projectSettings.open");
  // "Move thread to another machine…": the palette's way to the move the menu offers.
  static inline const QString kMoveCommand = QStringLiteral("thread.move");

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
  void remove(const QString& key);
  void pin(const QString& key);
  void unpin(const QString& key);
  void copy(const QString& value, const QString& successTitle, const QString& failureTitle);
  void fork(const QString& key);
  void chooseDestination(const QString& key, double x, double y);
  // Whether another machine of the thread's cluster could take it.
  bool movable(const QString& key) const;
  // Interrupts the thread's turn, then moves it once the turn has ended.
  void stopAndMove(const QString& key, const QString& machine, double x, double y);
  void move(const QString& key, const QString& machine, const QString& projectId, bool confirmed, double x,
            double y);
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
};
