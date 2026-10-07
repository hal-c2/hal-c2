#include "MobileApp.h"

#include <QDesktopServices>
#include <QDir>
#include <QPointer>
#include <QQmlPropertyMap>
#include <QQuickStyle>
#include <QtQml/qqml.h>

#include "DraftController.h"
#include "LayoutController.h"
#include "LicensesController.h"
#include "LocalFolderModel.h"
#include "NativeShell.h"
#include "PlatformWindow.h"
#include "PluginController.h"
#include "Scanner.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "TerminalController.h"
#include "ThemeStore.h"

void MobileApp::prepare() {
  useSoftwareRenderingWithoutDisplay();
  // The bricks import Basic and the phone's own chrome imports Material, each
  // by name. Whichever style a QML file names first would otherwise become
  // the run-time style, whose fonts and palette every control starts from and
  // which the two bricks that import plain QtQuick.Controls get: Basic, as on
  // the desktop, whatever the phone's root happens to import first.
  QQuickStyle::setStyle(QStringLiteral("Basic"));
#ifndef HAL_C2_HAS_TERMINAL
  // The terminal bricks draw with the Ghostty QML module, which this build
  // was made without: nothing offers, opens or draws a terminal.
  TerminalController::setSupported(false);
#endif
  qmlRegisterType<LocalFolderModel>("HalC2.Shell", 1, 0, "LocalFolderModel");
  // The open source notices are compiled into a package (cmake/Licenses.cmake).
  // A build for this machine has none, and the page says it could not load.
  LicensesController::setManifestPath(QStringLiteral(":/hal-c2/licenses/third-party-licenses.json"));
}

MobileApp::MobileApp(const Options& options) : m_storage(resolveStoragePaths(options.home)) {
  const QString configDir = QDir(m_storage.config).absoluteFilePath(QStringLiteral("shell"));
  QDir().mkpath(configDir);

  m_bridge = std::make_unique<ShellBridge>();
  // The MC's folders are never this device's.
  m_bridge->setLocalFolderImportEnabled(false);
  m_native = std::make_unique<NativeShell>(m_bridge.get());
  m_native->registerQmlSingletons();
  // The cache is what the phone paints from before its MC answers.
  m_native->setStoreDirs(m_storage.state, m_storage.data, m_storage.cache);
  LayoutController::setSystemReducedMotion(systemReducedMotion());
  m_native->controller<SettingsController>()->setDevicePath(QDir(configDir).filePath(QStringLiteral("preferences.json")));
  m_native->controller<PluginController>()->setConfigDir(configDir);
  // The root says which layout it shows (`layout.desktop {shown}`), at start
  // and as the window changes size, for the two things about it that live
  // here. The phone layout's home is the thread list, not a draft to land on,
  // and the desktop layout's is one. And only the desktop layout draws a
  // terminal, so in the phone's a thread has no place for one.
  m_native->controller<DraftController>()->setLandsOnDraft(false);
  m_native->controller<TerminalController>()->setDrawn(false);
  m_bridge->addInterceptor([drafts = QPointer<DraftController>(m_native->controller<DraftController>()),
                            terminals = QPointer<TerminalController>(m_native->controller<TerminalController>())](const QString& action, const QVariant& payload) {
    if (action != QLatin1String("layout.desktop")) return false;
    if (!drafts || !terminals) return true;
    const bool desktop = payload.toMap().value(QStringLiteral("shown")).toBool();
    drafts->setLandsOnDraft(desktop);
    if (desktop) drafts->land();
    terminals->setDrawn(desktop);
    return true;
  });
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
  m_scanner = std::make_unique<Scanner>(m_bridge.get(), options.camera ? options.camera : deviceCamera());
  // A `hal-c2:` link the system opens the app with (the manifest's
  // `hal-c2://pair`). Qt for Android hands a running app's link, and the one
  // a stopped app was started with, to QDesktopServices::openUrl, which
  // calls the scheme's handler. The second comes with the event loop's first
  // turn, so the handler has to be here before that.
  QDesktopServices::setUrlHandler(QStringLiteral("hal-c2"), m_pairing.get(), "openLink");
}

MobileApp::~MobileApp() {
  // Before the pairing goes: a link may be on its way from another thread.
  QDesktopServices::unsetUrlHandler(QStringLiteral("hal-c2"));
}

void MobileApp::start() {
  m_pairing->start();
  m_runtime->start();
}
