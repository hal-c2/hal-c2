#pragma once

#include <QObject>

#include "NativeController.h"

class McClient;
class ShellBridge;

// Whether the window shows the folder explorer (the FolderExplorer brick)
// beside the thread list. Publishes `folders` {open}; action and palette
// command `folders.toggle` ("Manage folders").
class FoldersController : public QObject, public NativeController {
  Q_OBJECT

public:
  FoldersController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  static inline const QString kToggle = QStringLiteral("folders.toggle");

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool isOpen() const { return m_open; }
  void setOpen(bool open);

private:
  void publish();

  ShellBridge* m_bridge;
  bool m_active = false;
  bool m_open = false;
};
