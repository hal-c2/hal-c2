#include "LayoutController.h"

#include <QtMath>

#include <algorithm>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<LayoutController> registrar(QStringLiteral("layout"), {QStringLiteral("layout")});

const QString kSidebarCollapsed = QStringLiteral("sidebarCollapsed");
const QString kZoomLevel = QStringLiteral("zoomLevel");
// The Electron zoom menu's step, and Chromium's 25% to 500%.
constexpr double kZoomStep = 0.5;
constexpr double kMinZoomLevel = -7.5;
constexpr double kMaxZoomLevel = 8.5;

}  // namespace

// The layout needs no MC, so it shows before the first snapshot: as soon
// as main.cpp has given the settings their file.
LayoutController::LayoutController(ShellBridge* bridge, McClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {
  QMetaObject::invokeMethod(this, &LayoutController::load, Qt::QueuedConnection);
}

void LayoutController::load() {
  if (m_loaded) return;
  m_loaded = true;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    m_sidebarCollapsed = settings->deviceValue(kSidebarCollapsed).toBool();
    m_zoomLevel = settings->deviceValue(kZoomLevel).toDouble();
    // Another window zoomed.
    connect(settings, &SettingsController::deviceChanged, this, [this, settings] {
      const double level = settings->deviceValue(kZoomLevel).toDouble();
      if (level == m_zoomLevel) return;
      m_zoomLevel = level;
      publish();
    });
  }
  publish();
}

void LayoutController::activate() {
  load();
  if (m_active) return;
  m_active = true;
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("sidebar.toggle"), keybindings::commandLabel(QStringLiteral("sidebar.toggle")),
                          [this] { toggleSidebar(); });
    keys->commands()->add(QStringLiteral("view.zoomIn"), tr("Zoom in"), [this] { setZoomLevel(m_zoomLevel + kZoomStep); });
    keys->commands()->add(QStringLiteral("view.zoomOut"), tr("Zoom out"), [this] { setZoomLevel(m_zoomLevel - kZoomStep); });
    keys->commands()->add(QStringLiteral("view.resetZoom"), tr("Actual size"), [this] { setZoomLevel(0); });
  }
}

bool LayoutController::handle(const QString& action, const QVariant&) {
  if (action != QLatin1String("sidebar.toggle")) return false;
  toggleSidebar();
  return true;
}

void LayoutController::setSidebarCollapsed(bool collapsed) {
  load();
  if (collapsed == m_sidebarCollapsed) return;
  m_sidebarCollapsed = collapsed;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kSidebarCollapsed, collapsed);
  }
  publish();
}

double LayoutController::zoom() const {
  return qPow(1.2, m_zoomLevel);
}

void LayoutController::setZoomLevel(double level) {
  load();
  level = std::clamp(level, kMinZoomLevel, kMaxZoomLevel);
  if (level == m_zoomLevel) return;
  m_zoomLevel = level;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kZoomLevel, level == 0 ? QVariant() : QVariant(level));
  }
  publish();
}

void LayoutController::publish() {
  m_bridge->publish(QStringLiteral("layout"),
                    QVariantMap{{kSidebarCollapsed, m_sidebarCollapsed}, {QStringLiteral("zoom"), zoom()}});
}
