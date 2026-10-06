#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlPropertyMap>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QtLogging>

#include "MobileApp.h"
#include "NativeShell.h"
#include "ScriptedRun.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"

namespace {

// A phone keeps everything in the app's own storage. On a desktop the binary
// is a development build of the phone's UI, and the default HAL-C2 home there
// is the installed desktop app's: it must be told where to keep its files.
QString resolveHome(const QString& override) {
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
  Q_UNUSED(override);
  return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#else
  return override.trimmed();
#endif
}

// A development build's window at another size than the root asks for
// (HAL_C2_MOBILE_SIZE=360x640), to look at small phones and wide windows. A
// phone's window is the screen.
void resizeForDevelopment(QQuickWindow* window) {
#if !defined(Q_OS_ANDROID) && !defined(Q_OS_IOS)
  const QStringList size = qEnvironmentVariable("HAL_C2_MOBILE_SIZE").split(QLatin1Char('x'));
  if (window && size.size() == 2 && size.at(0).toInt() > 0 && size.at(1).toInt() > 0) {
    window->resize(size.at(0).toInt(), size.at(1).toInt());
  }
#else
  Q_UNUSED(window);
#endif
}

}  // namespace

int main(int argc, char* argv[]) {
  QCoreApplication::setOrganizationName(QStringLiteral("HAL-C2"));
  QCoreApplication::setOrganizationDomain(QStringLiteral("hal-c2.example"));
  QCoreApplication::setApplicationName(QStringLiteral("hal-c2"));
  QCoreApplication::setApplicationVersion(QStringLiteral(HAL_C2_APP_VERSION));

  QGuiApplication app(argc, argv);
  MobileApp::prepare();

  QCommandLineParser parser;
  parser.setApplicationDescription(QStringLiteral("HAL-C2 mobile"));
  parser.addHelpOption();
  parser.addVersionOption();
  const QCommandLineOption homeDirOption(
      QStringLiteral("home-dir"),
      QStringLiteral("One root for the app's files (<dir>/config, data, state, cache). Needed off a phone."),
      QStringLiteral("dir"));
  const QCommandLineOption urlOption(
      QStringLiteral("url"), QStringLiteral("Pair with the MC this pairing link names, as entering it in the app does."),
      QStringLiteral("url"));
  parser.addOptions({homeDirOption, urlOption});
  ScriptedRun::addOptions(parser);
  parser.process(app);

  const QString home = resolveHome(parser.value(homeDirOption));
  if (home.isEmpty()) {
    qCritical("[mobile] --home-dir is needed on a desktop: the default home there belongs to the desktop app.");
    return 2;
  }
  // The shell, the phone's window and its pairing (MobileApp), which the
  // scenarios build the same way.
  MobileApp mobile({home, QStringLiteral(HAL_C2_QML_SOURCE_DIR), QStringLiteral(HAL_C2_MOBILE_QML_SOURCE_DIR)});
  qInfo().noquote() << "[mobile] home:" << mobile.storage().root;
  ShellBridge& bridge = mobile.bridge();
  ShellRuntime& runtime = mobile.runtime();
  mobile.start();
  if (parser.isSet(urlOption)) {
    bridge.dispatch(QStringLiteral("pairing.pair"), QVariantMap{{QStringLiteral("link"), parser.value(urlOption)}});
  }
  resizeForDevelopment(runtime.window());
  // Scripted runs act on the environment's rows once they are in, or on the
  // pairing screen when there is no environment to wait for.
  if (ScriptedRun::requested(parser)) {
    const auto play = [&parser, &runtime, &bridge] { ScriptedRun::play(parser, &runtime, &bridge); };
    const bool unpaired = bridge.state()->value(QStringLiteral("pairing")).toMap().value(QStringLiteral("phase")) == QLatin1String("unpaired");
    if (unpaired) {
      play();
    } else {
      QObject::connect(&mobile.native(), &NativeShell::ready, &runtime, play, Qt::SingleShotConnection);
    }
  }
  return app.exec();
}
