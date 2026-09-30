#include <QCommandLineParser>
#include <QDir>
#include <QJsonDocument>
#include <QGuiApplication>
#include <QIcon>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlEngine>
#include <QQuickWebEngineProfile>
#include <QStandardPaths>
#include <QTimer>
#include <QWindow>
#include <QtLogging>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include "AlertController.h"
#include "BackendProcess.h"
#include "LocalFolderModel.h"
#include "LocalTranscriber.h"
#include "NativeNotifications.h"
#include "NativeShell.h"
#include "QuitController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "ShellWindows.h"
#include "StoragePaths.h"
#include "ThemeStore.h"
#include "WebProfile.h"

namespace {

// The user's shell (shell.qml, theme.json, qml/) lives in `<config>/shell`;
// `--config-dir` moves just that directory.
QString resolveConfigDir(const QString& override, const StoragePaths& storage) {
  if (!override.isEmpty()) {
    return QDir(override).absolutePath();
  }
  return QDir(storage.config).absoluteFilePath(QStringLiteral("shell"));
}

QString resolveQmlSourceDir(const QString& override) {
  if (!override.isNull()) {
    return override;
  }
  const QString fromEnv =
      QProcessEnvironment::systemEnvironment().value(QStringLiteral("HAL_C2_QML_DIR"));
  if (!fromEnv.isEmpty()) {
    return fromEnv;
  }
  return QStringLiteral(HAL_C2_QML_SOURCE_DIR);
}

QString resolveDefaultHostEntry() {
  const QString configured = QStringLiteral(HAL_C2_HOST_ENTRY);
  return QDir::isAbsolutePath(configured)
             ? configured
             : QDir(QCoreApplication::applicationDirPath()).absoluteFilePath(configured);
}

QString resolveDefaultNodeExecutable() {
  const QString fromEnv =
      QProcessEnvironment::systemEnvironment().value(QStringLiteral("HAL_C2_NODE_BIN"));
  if (!fromEnv.isEmpty()) {
    return fromEnv;
  }
  const QString configured = QStringLiteral(HAL_C2_NODE_ENTRY);
  if (QDir::isAbsolutePath(configured)) {
    return configured;
  }
  if (configured.contains(QLatin1Char('/')) || configured.contains(QLatin1Char('\\'))) {
    return QDir(QCoreApplication::applicationDirPath()).absoluteFilePath(configured);
  }
  return configured;
}

}  // namespace

int main(int argc, char* argv[]) {
  QCoreApplication::setOrganizationName(QStringLiteral("HAL-C2"));
  QCoreApplication::setOrganizationDomain(QStringLiteral("hal-c2.example"));
  QCoreApplication::setApplicationName(QStringLiteral("hal-c2"));
  QCoreApplication::setApplicationVersion(QStringLiteral(HAL_C2_APP_VERSION));
  // Stable app id so compositor rules (blur, opacity, workspace) can target it.
  QGuiApplication::setDesktopFileName(QStringLiteral("hal-c2"));

  // Chromium's classic scrollbars paint a thumb in the page's scrollbar
  // gutters; overlay scrollbars match what the app expects from browsers.
  if (!qEnvironmentVariableIsSet("QTWEBENGINE_CHROMIUM_FLAGS")) {
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", "--enable-features=OverlayScrollbar");
  }
  QtWebEngineQuick::initialize();
  QGuiApplication app(argc, argv);
  // Closing a window closes only it; the last one quits (NativeShell::lastWindowClosed).
  QGuiApplication::setQuitOnLastWindowClosed(false);
  QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/hal-c2/app-icon.png")));
  useSoftwareRenderingWithoutDisplay();

  QCommandLineParser parser;
  parser.setApplicationDescription(QStringLiteral("HAL-C2 Qt shell"));
  parser.addHelpOption();
  parser.addVersionOption();
  const QCommandLineOption urlOption(
      QStringLiteral("url"),
      QStringLiteral("Attach to the node this pairing link names instead of starting one; any other "
                     "URL is loaded as it is."),
      QStringLiteral("url"));
  const QCommandLineOption configDirOption(
      QStringLiteral("config-dir"),
      QStringLiteral("Directory holding shell.qml, theme.json and qml/ (default <config>/shell, i.e. ~/.config/hal-c2/shell)."),
      QStringLiteral("dir"));
  const QCommandLineOption appIdOption(
      QStringLiteral("app-id"),
      QStringLiteral("Desktop application identity for this launch profile (default: hal-c2)."),
      QStringLiteral("id"));
  const QCommandLineOption localFolderImportOption(
      QStringLiteral("allow-local-folder-import"),
      QStringLiteral("Allow local folder import for an attached URL known to use this machine's filesystem."));
  const QCommandLineOption homeDirOption(
      QStringLiteral("home-dir"),
      QStringLiteral("One root for the shell's and its node's files (<dir>/config, data, state, cache)."),
      QStringLiteral("dir"));
  const QCommandLineOption qmlDirOption(
      QStringLiteral("qml-dir"),
      QStringLiteral("Load the built-in bricks from this directory instead of the binary."),
      QStringLiteral("dir"));
  const QCommandLineOption hostEntryOption(
      QStringLiteral("host-entry"), QStringLiteral("Path to the Node desktop host entry."),
      QStringLiteral("file"), resolveDefaultHostEntry());
  const QCommandLineOption nodeOption(
      QStringLiteral("node"), QStringLiteral("Node executable used to run the desktop host."),
      QStringLiteral("path"), resolveDefaultNodeExecutable());
  const QCommandLineOption screenshotOption(
      QStringLiteral("screenshot"),
      QStringLiteral("Write a PNG of the window once the page has loaded, then quit."),
      QStringLiteral("file"));
  const QCommandLineOption actionOption(
      QStringLiteral("action"),
      QStringLiteral("Dispatch a shell action after the page loads, e.g. rightPanel.toggle. "
                     "Repeatable; runs in order."),
      QStringLiteral("name[=json]"));
  const QCommandLineOption keyOption(
      QStringLiteral("key"),
      QStringLiteral("Press a key chord after the page loads, e.g. Ctrl+1 (portable QKeySequence "
                     "names). Repeatable; runs in command-line order together with --action."),
      QStringLiteral("chord"));
  parser.addOptions({urlOption, configDirOption, homeDirOption, qmlDirOption, hostEntryOption,
                     nodeOption, screenshotOption, actionOption, keyOption, localFolderImportOption,
                     appIdOption});
  parser.process(app);
  if (parser.isSet(appIdOption) && !parser.value(appIdOption).trimmed().isEmpty()) {
    QGuiApplication::setDesktopFileName(parser.value(appIdOption).trimmed());
  }

  const StoragePaths storage = resolveStoragePaths(parser.value(homeDirOption));
  const QString configDir = resolveConfigDir(parser.value(configDirOption), storage);
  // Created up front so the shell and theme watchers are live from the start: when
  // the node migrates an old home, the user's shell lands here and reloads.
  QDir().mkpath(configDir);
  const QString qmlSourceDir =
      resolveQmlSourceDir(parser.isSet(qmlDirOption) ? parser.value(qmlDirOption) : QString());
  qInfo().noquote() << "[shell] config dir:" << configDir;
  if (!qmlSourceDir.isEmpty()) {
    qInfo().noquote() << "[shell] bricks from disk:" << qmlSourceDir;
  }

  // Configured before any engine exists so the first page already lands on it.
  WebProfile webProfile(QDir(storage.cache).filePath(QStringLiteral("shell-web")));
  // Every window's engine shares the one profile (and its cookies).
  qmlRegisterSingletonType<QQuickWebEngineProfile>("HalC2.Shell", 1, 0, "WebProfile", [&webProfile](QQmlEngine*, QJSEngine*) {
    QQmlEngine::setObjectOwnership(webProfile.profile(), QQmlEngine::CppOwnership);
    return webProfile.profile();
  });

  ShellBridge bridge;
  bridge.setLocalFolderImportEnabled(!parser.isSet(urlOption) || parser.isSet(localFolderImportOption));
  qmlRegisterType<LocalTranscriber>("HalC2.Shell", 1, 0, "LocalTranscriber");
  qmlRegisterType<LocalFolderModel>("HalC2.Shell", 1, 0, "LocalFolderModel");
  NativeShell native(&bridge);
  native.registerQmlSingletons();
  // Each window reopens where the user left it (its route and panels are
  // state); the drafts are every window's unsent work (data).
  native.setStoreDirs(storage.state, storage.data);
  native.controller<SettingsController>()->setDevicePath(QDir(configDir).filePath(QStringLiteral("preferences.json")));
  ThemeStore theme(configDir);
  // ThemeController's resolved theme is the palette under theme.json.
  theme.applyBaseTheme(bridge.state()->value(QStringLiteral("theme")));
  // Every window (the first, window.new's, restored ones) is its own engine on
  // its window's bridge.
  ShellWindows windows(&native, {configDir, qmlSourceDir}, &theme);
  ShellRuntime& runtime = *windows.runtime(native.main());
  // Closing the last window quits, except on macOS, where the app stays in the
  // dock and coming back to it shows the window again.
#ifdef Q_OS_MACOS
  QObject::connect(&app, &QGuiApplication::applicationStateChanged, &windows, [&windows](Qt::ApplicationState state) {
    if (state != Qt::ApplicationActive) return;
    for (QWindow* window : QGuiApplication::topLevelWindows()) {
      if (window->isVisible()) return;
    }
    windows.reopen();
  });
#else
  QObject::connect(&native, &NativeShell::lastWindowClosed, &app, &QCoreApplication::quit, Qt::QueuedConnection);
#endif

  // Alerts reach the desktop's notification service; a click shows its thread.
  NativeNotifications notifications;
  auto* alerts = native.controller<AlertController>();
  alerts->setPresenter({
      [&notifications](const QString& key, const QString& title, const QString& body, bool silent) {
        return notifications.show(key, title, body, silent);
      },
      [&notifications] { notifications.closeAll(); },
      [&notifications](bool enabled) { notifications.setEnabled(enabled); },
      [](const QString& kind) {
        // No audio module: the sound theme's player, where the desktop has one.
        static const QString player = QStandardPaths::findExecutable(QStringLiteral("canberra-gtk-play"));
        if (player.isEmpty()) return;
        const QString event = kind == QLatin1String("completion") ? QStringLiteral("complete") : QStringLiteral("dialog-question");
        QProcess::startDetached(player, {QStringLiteral("-i"), event});
      },
  });
  QObject::connect(&notifications, &NativeNotifications::activated, alerts, &AlertController::openThread);

  // mod+Q, guarded as `confirmQuit` says; a finished hold hides the windows
  // while the key is let go.
  auto* quitting = native.controller<QuitController>();
  QObject::connect(quitting, &QuitController::quitRequested, &app, &QCoreApplication::quit, Qt::QueuedConnection);
  QObject::connect(quitting, &QuitController::concealRequested, &app, [] {
    for (QWindow* window : QGuiApplication::topLevelWindows()) window->hide();
  });

  BackendProcess::Options backendOptions;
  backendOptions.nodeExecutable = parser.value(nodeOption);
  backendOptions.hostEntry = parser.value(hostEntryOption);
  backendOptions.hostArguments = parser.positionalArguments();
  // Without a root the node resolves the same XDG directories itself.
  if (!storage.root.isEmpty()) {
    backendOptions.hostArguments.prepend(QStringLiteral("--base-dir=%1").arg(storage.root));
  }
  // Attach mode: the host starts no node; it pairs the shell (and the app) with
  // the linked node, or hands back any other URL unchanged.
  if (parser.isSet(urlOption)) {
    backendOptions.hostArguments.prepend(
        QStringLiteral("--attach=%1").arg(QUrl::fromUserInput(parser.value(urlOption)).toString(QUrl::FullyEncoded)));
  }
  BackendProcess backend(backendOptions);
  // Announced before `ready`, so the shell's own connection starts with the page.
  QObject::connect(&backend, &BackendProcess::nodeAvailable, &native, &NativeShell::open);
  // On the first window's bridge, which every other window mirrors (NativeWindow).
  QObject::connect(&backend, &BackendProcess::ready, &bridge, &ShellBridge::setPageUrl);
  QObject::connect(&backend, &BackendProcess::failed, &bridge, [&bridge](const QString& message) {
    qCritical().noquote() << "[shell]" << message;
    bridge.publish(QStringLiteral("backendError"), message);
  });
  QObject::connect(&app, &QCoreApplication::aboutToQuit, &backend, &BackendProcess::stop);

  backend.start();

  // Scripted runs: replay --action and --key steps in command-line order once
  // the node's first snapshot is in (NativeShell::ready), then optionally grab
  // the window and quit.
  struct ScriptedStep {
    bool isKey;
    QString spec;
  };
  QList<ScriptedStep> scriptedSteps;
  {
    QStringList actions = parser.values(actionOption);
    QStringList keys = parser.values(keyOption);
    for (const QString& name : parser.optionNames()) {
      if (name == QStringLiteral("action")) {
        scriptedSteps.append({false, actions.takeFirst()});
      } else if (name == QStringLiteral("key")) {
        scriptedSteps.append({true, keys.takeFirst()});
      }
    }
  }
  const bool screenshotRequested = parser.isSet(screenshotOption);
  if (!scriptedSteps.isEmpty() || screenshotRequested) {
    const QString target = parser.value(screenshotOption);
    QObject::connect(&native, &NativeShell::ready, &runtime,
                     [&runtime, &bridge, &app, target, scriptedSteps,
                      screenshotRequested] {
                       int delay = 1500;
                       for (const ScriptedStep& step : scriptedSteps) {
                         if (step.isKey) {
                           QTimer::singleShot(delay, &runtime, [&runtime, step] {
                             qInfo().noquote() << "[shell] scripted key" << step.spec;
                             runtime.pressKey(step.spec);
                           });
                           delay += 1500;
                           continue;
                         }
                         const QString spec = step.spec;
                         QTimer::singleShot(delay, &bridge, [&bridge, spec] {
                           const int eq = spec.indexOf(QLatin1Char('='));
                           const QString name = eq < 0 ? spec : spec.left(eq);
                           QVariant payload;
                           if (eq >= 0) {
                             payload = QJsonDocument::fromJson(spec.mid(eq + 1).toUtf8())
                                           .toVariant();
                           }
                           qInfo().noquote() << "[shell] scripted action" << name;
                           bridge.dispatch(name, payload);
                         });
                         delay += 1500;
                       }
                       if (screenshotRequested) {
                         QTimer::singleShot(delay + 1500, &runtime, [&runtime, &app, target] {
                           const bool ok = runtime.captureWindow(target);
                           app.exit(ok ? 0 : 2);
                         });
                       }
                     },
                     Qt::SingleShotConnection);
    // A start that fails never reaches the node; grab the error the window shows
    // instead of waiting forever, and quit with a failure code.
    if (screenshotRequested) {
      QObject::connect(&backend, &BackendProcess::failed, &runtime,
                       [&runtime, &app, target] {
                         QTimer::singleShot(1500, &runtime, [&runtime, &app, target] {
                           runtime.captureWindow(target);
                           app.exit(2);
                         });
                       },
                       Qt::SingleShotConnection);
    }
  }

  windows.start();
  native.restoreWindows();
  return app.exec();
}
