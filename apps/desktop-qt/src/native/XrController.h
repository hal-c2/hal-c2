#pragma once

#include <QObject>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// The window's XR workspace: what the window shows, on panels in XR glasses
// an OpenXR runtime drives (XrHost makes XrWorkspace while it is open). It
// redraws every frame the glasses show, so it is only open while asked for.
// What it shows is QML (ShellWindow.xrWorkspace, DefaultXrWorkspace).
//
// Publishes `xr`: {open}. Action and command `xr.toggle` opens or closes it;
// `xr.failed` {message} is XrHost saying it could not start (no Qt Quick 3D
// XR, no OpenXR runtime), which closes it and tells the user why.
class XrController : public QObject, public NativeController {
  Q_OBJECT

public:
  XrController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool isOpen() const { return m_open; }
  void setOpen(bool open);

private:
  void publish();

  ShellBridge* m_bridge;
  bool m_open = false;
  bool m_active = false;
};
