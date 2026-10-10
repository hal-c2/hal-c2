#include "LayoutController.h"

#include <QtMath>

#include <algorithm>
#include <limits>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<LayoutController> registrar(QStringLiteral("layout"), {QStringLiteral("layout")});

const QString kSidebarCollapsed = QStringLiteral("sidebarCollapsed");
const QString kZoomLevel = QStringLiteral("zoomLevel");
const QString kSidebarWidthKey = QStringLiteral("sidebarWidth");
// The zoom menu's step, and the range of 25% to 500%.
constexpr double kZoomStep = 0.5;
constexpr double kMinZoomLevel = -7.5;
constexpr double kMaxZoomLevel = 8.5;

bool g_systemReducedMotion = false;

}  // namespace

void LayoutController::setSystemReducedMotion(bool reduced) {
  g_systemReducedMotion = reduced;
}

int LayoutController::panelAnimationMs() const {
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings || g_systemReducedMotion || settings->setting(QStringLiteral("reduceMotion")).toBool()) return 0;
  return std::clamp(settings->setting(QStringLiteral("panelAnimationDurationMs")).toInt(), 0, 400);
}

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
    if (const int width = settings->deviceValue(kSidebarWidthKey).toInt(); width > 0) {
      m_sidebarWidth = std::max(width, kSidebarMinWidth);
    }
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

bool LayoutController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("sidebar.toggle")) {
    toggleSidebar();
  } else if (action == QLatin1String("sidebar.resize")) {
    if (map.contains(QStringLiteral("width"))) setSidebarWidth(map.value(QStringLiteral("width")).toInt());
    else resetSidebarWidth();
  } else if (action == QLatin1String("layout.window")) {
    setWindowWidth(map.value(QStringLiteral("width")).toInt());
  } else {
    return false;
  }
  return true;
}

int LayoutController::sidebarRoom() const {
  return m_windowWidth > 0 ? std::max(0, m_windowWidth - kContentMinWidth) : std::numeric_limits<int>::max();
}

int LayoutController::sidebarWidth() const {
  return std::min(m_sidebarWidth, sidebarRoom());
}

void LayoutController::setSidebarWidth(int width) {
  load();
  width = std::max(std::min(width, sidebarRoom()), kSidebarMinWidth);
  if (width == m_sidebarWidth) return;
  m_sidebarWidth = width;
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    settings->writeDevice(kSidebarWidthKey, width == kSidebarWidth ? QVariant() : QVariant(width));
  }
  publish();
}

void LayoutController::resetSidebarWidth() {
  setSidebarWidth(kSidebarWidth);
}

void LayoutController::setWindowWidth(int width) {
  load();
  if (width == m_windowWidth) return;
  const int before = sidebarWidth();
  m_windowWidth = width;
  if (sidebarWidth() != before) publish();
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
                    QVariantMap{{kSidebarCollapsed, m_sidebarCollapsed},
                                {kSidebarWidthKey, sidebarWidth()},
                                {QStringLiteral("zoom"), zoom()}});
}
