#pragma once

#include <QObject>
#include <QPointer>

#include <functional>

#include "NativeController.h"
#include "ServerUpdates.h"

class CommandRegistry;
class McClient;
class NativeWindow;
class ShellBridge;
class ShellStore;

// Updating the cluster's servers to this app's version (ServerUpdates holds
// the rules): the machines come from the shell store's descriptors, the app's
// version from ConnectionHealthController, and the effects are the MC call,
// the shell's one confirmation, its toasts and the clipboard. One per
// process.
//
// Publishes `serverUpdates` (ServerUpdates::state). Actions:
// `serverUpdates.update {environmentId}`, `serverUpdates.copyCommand
// {environmentId}`, `serverUpdates.updateAll`. The palette has "Update all
// servers" and "Update a server..." while one is behind.
class ServerUpdateController : public QObject, public NativeController {
  Q_OBJECT

public:
  ServerUpdateController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  void attach(NativeWindow* window) override;
  bool handle(const QString& action, const QVariant& payload) override;

  void setClipboardWriter(std::function<bool(const QString&)> write) { m_writeClipboard = std::move(write); }

private:
  void refresh();
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<bool(const QString&)> m_writeClipboard;
  ServerUpdates m_updates;
  // Each window's palette, to show the commands while a server is behind.
  QList<QPointer<CommandRegistry>> m_palettes;
};
