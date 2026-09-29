#pragma once

#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QVariant>

#include <functional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;
class ToastController;

// A thread's action menu, from its sidebar row (`thread.menu {key, x, y}`)
// and from the header's title (`workspace.titleMenu {x, y}`, the route's
// thread, or its draft's menu). Items follow the page's
// buildThreadActionMenuItems order, plus Fork and Move to another machine;
// the environment's capabilities leave items out and an offline environment
// turns the ones that need it off. Each action toasts its failure, and the
// ones that hide a thread (archive, unpin, settle, snooze) offer Undo.
//
// The route thread's keybinding commands (thread.pin, thread.settle,
// thread.copyReference, thread.undo) run here too (KeybindingController).
class ThreadMenuController : public QObject, public NativeController {
  Q_OBJECT

public:
  ThreadMenuController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override {}
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
  void command(const QString& key, QJsonObject command, const QString& failureTitle,
               std::function<void()> onSuccess = {});
  void archive(const QString& key);
  void remove(const QString& key);
  void pin(const QString& key);
  void unpin(const QString& key);
  void copy(const QString& value, const QString& successTitle, const QString& failureTitle);
  void fork(const QString& key);
  void chooseDestination(const QString& key, double x, double y);
  void move(const QString& key, const QString& machine, const QString& projectId, bool confirmed, double x,
            double y);
  void newThreadOnBranch(const QString& key);
  QString workspacePath(const QString& key) const;
  ToastController* toasts() const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<bool(const QString&)> m_writeClipboard;
};
