#include "MobileApp.h"

#include <QDir>
#include <QQmlPropertyMap>
#include <QQuickStyle>
#include <QtQml/qqml.h>

#include "DraftController.h"
#include "LayoutController.h"
#include "LocalFolderModel.h"
#include "NativeShell.h"
#include "PlatformWindow.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "ThemeStore.h"

void MobileApp::prepare() {
  useSoftwareRenderingWithoutDisplay();
  // The bricks import Basic and the phone's own chrome imports Material, each
  // by name. Whichever style a QML file names first would otherwise become
  // the run-time style, whose fonts and palette every control starts from and
  // which the two bricks that import plain QtQuick.Controls get: Basic, as on
  // the desktop, whatever the phone's root happens to import first.
  QQuickStyle::setStyle(QStringLiteral("Basic"));
  qmlRegisterType<LocalFolderModel>("HalC2.Shell", 1, 0, "LocalFolderModel");
}

MobileApp::MobileApp(const Options& options) : m_storage(resolveStoragePaths(options.home)) {
  const QString configDir = QDir(m_storage.config).absoluteFilePath(QStringLiteral("shell"));
  QDir().mkpath(configDir);

  m_bridge = std::make_unique<ShellBridge>();
  // The MC's folders are never this device's.
  m_bridge->setLocalFolderImportEnabled(false);
  m_native = std::make_unique<NativeShell>(m_bridge.get());
  m_native->registerQmlSingletons();
  m_native->setStoreDirs(m_storage.state, m_storage.data);
  LayoutController::setSystemReducedMotion(systemReducedMotion());
  m_native->controller<SettingsController>()->setDevicePath(QDir(configDir).filePath(QStringLiteral("preferences.json")));
  m_native->controller<PluginController>()->setConfigDir(configDir);
  // The phone's home is the thread list, not a draft to land on.
  m_native->controller<DraftController>()->setLandsOnDraft(false);
  m_theme = std::make_unique<ThemeStore>(configDir);
  // ThemeController's resolved theme is the palette under theme.json.
  m_theme->applyBaseTheme(m_bridge->state()->value(QStringLiteral("theme")));
  QObject::connect(m_bridge.get(), &ShellBridge::stateEntryChanged, m_theme.get(), [theme = m_theme.get()](const QString& key, const QVariant& value) {
    if (key == QLatin1String("theme")) theme->applyBaseTheme(value);
  });

  // One window, the phone's layout of the bricks.
  m_runtime = std::make_unique<ShellRuntime>(
      ShellRuntime::Options{configDir, options.bricksQmlDir, QStringLiteral("HalC2/Mobile/MobileShell.qml"), options.mobileQmlDir}, m_bridge.get(),
      m_theme.get());
  // The one environment the phone is paired with.
  m_pairing = std::make_unique<Pairing>(m_bridge.get(), m_native.get(), m_storage.data, options.device);
}

MobileApp::~MobileApp() = default;

void MobileApp::start() {
  m_pairing->start();
  m_runtime->start();
}
