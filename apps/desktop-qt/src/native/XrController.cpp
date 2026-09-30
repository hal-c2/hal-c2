#include "XrController.h"

#include "KeybindingController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<XrController> registrar(QStringLiteral("xr"), {QStringLiteral("xr")});

const QString kToggle = QStringLiteral("xr.toggle");
const QString kFailed = QStringLiteral("xr.failed");

}  // namespace

XrController::XrController(ShellBridge* bridge, NodeClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {
  publish();
}

void XrController::activate() {
  if (m_active) return;
  m_active = true;
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(kToggle, tr("Toggle XR workspace"), [this] { setOpen(!m_open); });
  }
}

bool XrController::handle(const QString& action, const QVariant& payload) {
  if (action == kToggle) {
    setOpen(!m_open);
    return true;
  }
  if (action == kFailed) {
    setOpen(false);
    if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
      toasts->error(tr("XR workspace unavailable"), payload.toMap().value(QStringLiteral("message")).toString());
    }
    return true;
  }
  return false;
}

void XrController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  publish();
}

void XrController::publish() {
  m_bridge->publish(QStringLiteral("xr"), QVariantMap{{QStringLiteral("open"), m_open}});
}
