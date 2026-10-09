#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlContext>
#include <QStyleHints>
#include <QTemporaryDir>
#include <QTest>

#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "ThemeStore.h"

class ShellRuntimeTest : public QObject {
  Q_OBJECT

private slots:
  void appAppearanceUpdatesQmlWithoutReloading() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("{\"id\":\"system-glass\",\"appearance\":\"light\","
      "\"colors\":{\"canvas\":\"#fafafa\",\"text\":\"#1d1d1f\"},"
      "\"variants\":{\"dark\":{\"canvas\":\"#1c1c1e\",\"text\":\"#f5f5f7\",\"darkOnly\":\"#123456\"}},"
      "\"window\":{\"followSystemAppearance\":true}}");
    file.close();
    ThemeStore theme(directory.path());
    QVERIFY(theme.followsSystemAppearance());
    QCOMPARE(theme.appearance(), QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark
                                    ? QString("dark") : QString("light"));
    QQmlEngine engine;
    engine.rootContext()->setContextProperty("Theme", &theme);
    QQmlComponent component(&engine);
    component.setData("import QtQuick\nRectangle { color: Theme.palette.color(\"canvas\", \"#111111\") }", QUrl());
    QScopedPointer<QObject> item(component.create());
    QVERIFY2(item, qPrintable(component.errorString()));
    for (const bool dark : {true, false, true}) {
      // The app's appearance, as ThemeController resolves it.
      theme.applyBaseTheme(QVariantMap{{"id", "hal-c2"}, {"appearance", dark ? "dark" : "light"}});
      QCOMPARE(theme.appearance(), dark ? QString("dark") : QString("light"));
      QCOMPARE(item->property("color").value<QColor>(), QColor(dark ? "#1c1c1e" : "#fafafa"));
      QCOMPARE(theme.colors().contains("darkOnly"), dark);
    }
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write("{\"id\":\"fixed\",\"appearance\":\"light\",\"colors\":{\"canvas\":\"#ffffff\"}}");
    file.close();
    theme.reload();
    QVERIFY(!theme.followsSystemAppearance());
    theme.applyBaseTheme(QVariantMap{{"id", "hal-c2"}, {"appearance", "dark"}, {"colors", QVariantMap{{"text", "#eeeeee"}}}});
    QCOMPARE(theme.appearance(), QString("light"));
    QCOMPARE(item->property("color").value<QColor>(), QColor("#ffffff"));
    QVERIFY(file.remove());
    theme.reload();
    QVERIFY(!theme.followsSystemAppearance());
  }

  void liquidGlassThemeOptInResetsWhenThemeChanges() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(R"({"version":1,"id":"glass","appearance":"light","colors":{},
                   "window":{"transparent":true,"blur":true,"liquidGlass":true,"frameless":false}})");
    file.close();
    ThemeStore theme(directory.path());
    QVERIFY(theme.windowLiquidGlass());
    QVERIFY(theme.windowTransparent());
    QVERIFY(theme.windowBlur());
    QVERIFY(!theme.frameless());
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(R"({"version":1,"id":"plain","appearance":"light","colors":{}})");
    file.close();
    theme.reload();
    QVERIFY(!theme.windowLiquidGlass());
    QVERIFY(!theme.windowTransparent());
    QVERIFY(!theme.windowBlur());
    QVERIFY(file.remove());
    theme.reload();
    QVERIFY(!theme.windowLiquidGlass());
  }

  // The interface font is the application's: text that names no family is
  // written in it without a binding, whether made before or after the change.
  void textThatNamesNoFamilyIsWrittenInTheInterfaceFont() {
    const QString system = QGuiApplication::font().family();
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData("import QtQuick\nimport QtQuick.Controls.Basic\nWindow {\n"
                      "Text { objectName: \"plain\" }\n"
                      "Text { objectName: \"sized\"; property int size: 20; font.pixelSize: size; font.weight: Font.DemiBold }\n"
                      "Text { objectName: \"code\"; font.family: \"monospace\" }\n"
                      "Button { objectName: \"button\" }\n"
                      "TextField { objectName: \"field\" }\n"
                      "Popup { Label { objectName: \"inPopup\" } }\n"
                      "Component { id: late; Text {} }\n"
                      "function make() { return late.createObject(contentItem); }\n}", QUrl());
    QScopedPointer<QObject> window(component.create());
    QVERIFY2(window, qPrintable(component.errorString()));
    const auto family = [&](const char* name) { return window->findChild<QObject*>(name)->property("font").value<QFont>().family(); };
    const QStringList inherits{"plain", "sized", "button", "field", "inPopup"};
    {
      ThemeStore theme(directory.path());
      theme.applyBaseTheme(QVariantMap{{"appearance", "dark"}, {"fontUi", "Inter"}});
      QCOMPARE(QGuiApplication::font().family(), QString("Inter"));
      for (const QString& name : inherits) QCOMPARE(family(qPrintable(name)), QString("Inter"));
      QCOMPARE(family("code"), QString("monospace"));
      // What a label set of its own font is kept, and still follows its binding.
      QObject* sized = window->findChild<QObject*>("sized");
      QCOMPARE(sized->property("font").value<QFont>().pixelSize(), 20);
      QCOMPARE(sized->property("font").value<QFont>().weight(), QFont::DemiBold);
      sized->setProperty("size", 24);
      QCOMPARE(sized->property("font").value<QFont>().pixelSize(), 24);
      // A second change reaches the same labels, and one made since.
      QVariant result;
      QVERIFY(QMetaObject::invokeMethod(window.data(), "make", Q_RETURN_ARG(QVariant, result)));
      QObject* made = result.value<QObject*>();
      QVERIFY(made);
      QCOMPARE(made->property("font").value<QFont>().family(), QString("Inter"));
      theme.applyBaseTheme(QVariantMap{{"appearance", "dark"}, {"fontUi", "\"IBM Plex Sans\""}});
      for (const QString& name : inherits) QCOMPARE(family(qPrintable(name)), QString("IBM Plex Sans"));
      QCOMPARE(made->property("font").value<QFont>().family(), QString("IBM Plex Sans"));
      // A list that ends in the system's font, none of it installed, is the system's font.
      theme.applyBaseTheme(QVariantMap{{"appearance", "dark"}, {"fontUi", "\"No Such Family\", system-ui, sans-serif"}});
      QCOMPARE(theme.fontUi(), QString());
      for (const QString& name : inherits) QCOMPARE(family(qPrintable(name)), system);
      theme.applyBaseTheme(QVariantMap{{"appearance", "dark"}, {"fontUi", "Inter"}});
      QCOMPARE(family("plain"), QString("Inter"));
    }
    // The font was the application's before the store and is again after it.
    QCOMPARE(QGuiApplication::font().family(), system);
  }

  void qmlPaletteFollowsTheBaseTheme() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ThemeStore theme(directory.path());
    QQmlEngine engine;
    engine.rootContext()->setContextProperty("Theme", &theme);
    QQmlComponent component(&engine);
    component.setData("import QtQuick\nRectangle { color: Theme.palette.color(\"canvas\", \"#111111\") }", QUrl());
    QScopedPointer<QObject> item(component.create());
    QVERIFY2(item, qPrintable(component.errorString()));
    QCOMPARE(item->property("color").value<QColor>(), QColor("#111111"));
    theme.applyBaseTheme(QVariantMap{{"appearance", "light"}, {"colors", QVariantMap{{"canvas", "#ffffff"}}}});
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#ffffff"));
    QCOMPARE(item->property("color").value<QColor>(), QColor("#ffffff"));
    theme.applyBaseTheme(QVariantMap{{"appearance", "dark"}, {"colors", QVariantMap{{"canvas", "#0c2238cc"}}}});
    QCOMPARE(item->property("color").value<QColor>(), QColor(12, 34, 56, 204));
    QFile overrideFile(directory.filePath("theme.json"));
    QVERIFY(overrideFile.open(QIODevice::WriteOnly));
    overrideFile.write("{\"colors\":{\"canvas\":\"#abcdef\"}}");
    overrideFile.close();
    theme.reload();
    QCOMPARE(item->property("color").value<QColor>(), QColor("#abcdef"));
    QVERIFY(overrideFile.remove());
    theme.reload();
    QCOMPARE(item->property("color").value<QColor>(), QColor(12, 34, 56, 204));
  }

  void folderDropsResolveOnlyExistingLocalDirectories() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ShellBridge bridge;
    const auto url = QUrl::fromLocalFile(directory.path());
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.setMcOrigin(QUrl("https://remote.example"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.setMcOrigin(QUrl("http://127.0.0.1:6182"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.setLocalFolderImportEnabled(true);
    QCOMPARE(bridge.localDirectoryPath(url), QFileInfo(directory.path()).canonicalFilePath());
    QVERIFY(bridge.localDirectoryPath(QUrl("https://example.com/folder")).isEmpty());
    QVERIFY(bridge.localDirectoryPath(QUrl("file://server/share")).isEmpty());
    QVERIFY(bridge.localDirectoryPath(QUrl::fromLocalFile(directory.filePath("missing"))).isEmpty());
    QFile file(directory.filePath("file.txt"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.close();
    QVERIFY(bridge.localDirectoryPath(QUrl::fromLocalFile(file.fileName())).isEmpty());
    // An MC on another machine: its folders are not this machine's.
    bridge.setMcOrigin(QUrl("https://remote.example"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
  }

  void themeRecoversAfterReadFailureWithoutAcceptingInvalidJson() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("{\"colors\":{\"canvas\":\"#123456\"}}");
    file.close();
    ThemeStore theme(directory.path());
    QVERIFY(theme.lastError().isEmpty());
    const auto permissions = file.permissions();
    QVERIFY(file.setPermissions(QFile::WriteOwner));
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    QVERIFY(file.setPermissions(permissions));
    theme.reload();
    QVERIFY(theme.lastError().isEmpty());
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#123456"));

    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write("invalid JSON");
    file.close();
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#123456"));
  }

  // Scenario: A user's own shell layout replaces the default, A broken shell
  // layout falls back to the default, A shell layout change applies without
  // restarting (features/navigation/layout.feature). That the fallback's
  // error is on screen is tst_ShellExamples::brokenShellFallsBackAndSaysWhy.
  void reloadKeepsSingletonsAndRecoversFromInvalidSource() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString config = directory.filePath("config");
    const QString sources = directory.filePath("qml");
    QVERIFY(QDir().mkpath(config));
    QVERIFY(QDir().mkpath(sources + "/HalC2/Bricks"));
    const QString shellPath = config + "/shell.qml";
    const QString defaultPath = sources + "/HalC2/Bricks/DefaultShell.qml";
    const auto writeSource = [](const QString& path, const QByteArray& contents) {
      QFile file(path);
      return file.open(QIODevice::WriteOnly) && file.write(contents) == contents.size();
    };
    const auto source = [](int revision) {
      return QByteArray(R"(
import QtQuick
import HalC2.Shell
Window {
  objectName: "reload-probe"
  property int revision: )") + QByteArray::number(revision) + QByteArray(revision, ' ') + R"(
  property int protocol: Shell.protocolVersion
  property string prompt: Shell.state.composer.text
  property real radiusValue: Theme.radius
  property string configValue: Runtime.configDir
}
)";
    };
    QVERIFY(writeSource(shellPath, source(1)));
    QVERIFY(writeSource(defaultPath, source(0)));
    ShellBridge bridge;
    bridge.publish("composer", QVariantMap{{"text", "Retained draft"}});
    ThemeStore theme(config);
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Terminals.qml")),
                             "HalC2.Shell", 1, 0, "Terminals");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Keybindings.qml")),
                             "HalC2.Shell", 1, 0, "Keybindings");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Panel.qml")),
                             "HalC2.Shell", 1, 0, "Panel");
    ShellRuntime runtime({config, sources}, &bridge, &theme);
    const auto window = []() -> QQuickWindow* {
      QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
      for (auto* candidate : QGuiApplication::allWindows()) {
        if (candidate->objectName() == "reload-probe") return qobject_cast<QQuickWindow*>(candidate);
      }
      return nullptr;
    };
    const auto verifySingletons = [&](QQuickWindow* root) {
      QVERIFY(root);
      QCOMPARE(root->property("protocol").toInt(), bridge.protocolVersion());
      QCOMPARE(root->property("prompt").toString(), QString("Retained draft"));
      QCOMPARE(root->property("radiusValue").toReal(), theme.radius());
      QCOMPARE(root->property("configValue").toString(), config);
    };
    runtime.start();
    verifySingletons(window());
    for (int revision = 2; revision <= 3; ++revision) {
      QPointer<QQuickWindow> previous = window();
      QVERIFY(writeSource(shellPath, source(revision)));
      runtime.reload();
      verifySingletons(window());
      QVERIFY(previous.isNull());
      QCOMPARE(window()->property("revision").toInt(), revision);
      QCOMPARE(runtime.generation(), revision);
    }
    QPointer<QQuickWindow> working = window();
    QVERIFY(writeSource(shellPath, "invalid QML"));
    QVERIFY(writeSource(defaultPath, "invalid QML"));
    runtime.reload();
    QCOMPARE(window(), working.data());
    QCOMPARE(runtime.generation(), 3);
    QVERIFY(!runtime.lastError().isEmpty());
    verifySingletons(window());

    QVERIFY(writeSource(defaultPath, source(4)));
    runtime.reload();
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 4);
    QVERIFY(!runtime.usingUserShell());
    QVERIFY(writeSource(shellPath, source(5)));
    runtime.reload();
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 5);
    QVERIFY(runtime.usingUserShell());
    QVERIFY(runtime.lastError().isEmpty());

    // Saving the file is enough: the runtime watches it.
    QVERIFY(writeSource(shellPath, source(6)));
    QTRY_COMPARE(runtime.generation(), 6);
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 6);

    QVERIFY(writeSource(shellPath, "import QtQml\nQtObject {}"));
    runtime.reload();
    QVERIFY(window());
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 4);
    QVERIFY(!runtime.usingUserShell());
    QVERIFY(runtime.lastError().contains("Window"));
    auto* engine = runtime.findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    QTRY_COMPARE(engine->rootObjects().size(), 1);

    working = window();
    const int generation = runtime.generation();
    QVERIFY(writeSource(defaultPath, "import QtQml\nQtObject {}"));
    runtime.reload();
    QCOMPARE(window(), working.data());
    QCOMPARE(runtime.generation(), generation);
    QCOMPARE(engine->rootObjects().size(), 1);
  }
};

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  useSoftwareRenderingWithoutDisplay();
  ShellRuntimeTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ShellRuntime.moc"
