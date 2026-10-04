#include "FoldersController.h"

#include "KeybindingController.h"
#include "NativeShell.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<FoldersController> registrar(QStringLiteral("folders"), {QStringLiteral("folders")});

}  // namespace

FoldersController::FoldersController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

void FoldersController::activate() {
  if (m_active) return;
  m_active = true;
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(kToggle, tr("Manage folders"), [this] { setOpen(!m_open); });
    keys->commands()->setTerms(kToggle, {QStringLiteral("folder explorer"), QStringLiteral("rename"), QStringLiteral("move"),
                                         QStringLiteral("trash"), QStringLiteral("directory")});
  }
  publish();
}

bool FoldersController::handle(const QString& action, const QVariant& payload) {
  if (action != kToggle) return false;
  const QVariantMap map = payload.toMap();
  setOpen(map.contains(QStringLiteral("open")) ? map.value(QStringLiteral("open")).toBool() : !m_open);
  return true;
}

void FoldersController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  publish();
}

void FoldersController::publish() {
  m_bridge->publish(QStringLiteral("folders"), QVariantMap{{QStringLiteral("open"), m_open}});
}
