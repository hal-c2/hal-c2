#include <QFile>
#include <QJsonDocument>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QPointer>
#include <QSignalSpy>
#include <QQuickWebEngineProfile>
#include <QTemporaryDir>
#include <QTest>
#include <QtWebEngineQuick>
#include <memory>

#include "ShellBridge.h"
#include "LocalFolderModel.h"
#include "ShellRuntime.h"
#include "ThemeStore.h"
#include "WebProfile.h"

// List delegates belong to the visual tree, not necessarily the QObject tree.
static QQuickItem* findVisualItem(QQuickItem* parent, const QString& name) {
  if (parent->objectName() == name) return parent;
  for (auto* child : parent->childItems()) {
    if (auto* found = findVisualItem(child, name)) return found;
  }
  return nullptr;
}

class ShellExamplesTest : public QObject {
  Q_OBJECT

  QTemporaryDir directory;
  ShellBridge bridge;
  QVariantMap initialState;
  std::unique_ptr<ThemeStore> theme;
  std::unique_ptr<WebProfile> profile;
  std::unique_ptr<ShellRuntime> runtime;

  static QObject* terminalsOf(QQmlEngine* engine) {
    return engine->singletonInstance<QObject*>("HalC2.Shell", "Terminals");
  }

private slots:
  void initTestCase() {
    QVERIFY(directory.isValid());
    qmlRegisterType<LocalFolderModel>("HalC2.Shell", 1, 0, "LocalFolderModel");
    theme = std::make_unique<ThemeStore>(directory.path());
    profile = std::make_unique<WebProfile>(directory.filePath("web"));
    qmlRegisterSingletonInstance("HalC2.Shell", 1, 0, "WebProfile", profile->profile());
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Terminals.qml")),
                             "HalC2.Shell", 1, 0, "Terminals");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Keybindings.qml")),
                             "HalC2.Shell", 1, 0, "Keybindings");
    // Settings opens the native General page, which reads these.
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Settings.qml")),
                             "HalC2.Shell", 1, 0, "Settings");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Themes.qml")),
                             "HalC2.Shell", 1, 0, "Themes");
    // A thread route shows the native centre, which reads this.
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Threads.qml")),
                             "HalC2.Shell", 1, 0, "Threads");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/Panel.qml")),
                             "HalC2.Shell", 1, 0, "Panel");
    qmlRegisterSingletonType(QUrl::fromLocalFile(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/tests/imports/HalC2/Shell/PaletteModel.qml")),
                             "HalC2.Shell", 1, 0, "PaletteModel");
    runtime = std::make_unique<ShellRuntime>(
        ShellRuntime::Options{directory.path(), QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/qml")},
        &bridge, theme.get());
    bridge.setPageUrl(QUrl("about:blank"));
    const auto state = QJsonDocument::fromJson(R"({
      "workspace": {
        "projectTitle": "Example project", "threadTitle": "Fix TUI Readability Issue",
        "isDraft": false, "renameRequestId": 0, "scripts": [], "editors": [],
        "branch": "feature/a-descriptive-branch-name-that-needs-to-fit",
        "environments": [], "environmentChangeable": false, "activeEnvironmentId": null,
        "envMode": "local", "envModeLabel": "Local checkout", "envModeChangeable": false,
        "canOpenPullRequest": false, "branchChangeable": false, "branchSwitchPending": false,
        "branches": [], "branchesLoading": false, "branchesTotal": 0,
        "git": {"hasUpstream": false, "hasWorkingTreeChanges": false, "pullRequest": null}
      },
      "sidebar": {
        "projects": [], "scopeProjectKey": null, "activeThreadKey": null,
        "activeDraftId": null, "drafts": [], "pinned": [], "active": [],
        "snoozed": [], "settled": [], "settledTotal": 0
      },
      "layout": {"sidebarCollapsed": false},
      "notifications": {"items": []}
    })").toVariant().toMap();
    for (auto it = state.cbegin(); it != state.cend(); ++it) bridge.publish(it.key(), it.value());
    initialState = state;
  }

  // A thread or draft route shows the shell's own centre in the page's
  // place (js/centreViews.js); any other route shows the page again.
  void threadRoutesDrawTheCentre(QQuickWindow* window) {
    auto* page = findVisualItem(window->contentItem(), "HalC2WebSurface");
    QVERIFY(page);
    QVERIFY(page->isVisible());
    bridge.publish("route", QVariantMap{{"kind", "thread"}, {"threadKey", "env-a:thread-1"}, {"title", "Tax line"}});
    QTRY_VERIFY(findVisualItem(window->contentItem(), "threadTimeline"));
    auto* timeline = findVisualItem(window->contentItem(), "threadTimeline");
    QTRY_VERIFY(timeline->isVisible());
    QVERIFY(!page->isVisible());
    QTRY_VERIFY(timeline->width() >= 300 && timeline->height() > 0);
    QVERIFY(timeline->mapToScene(QPointF(timeline->width(), 0)).x() <= window->width());
    bridge.publish("route", QVariantMap{{"kind", "draft"}, {"draftId", "draft-1"}});
    auto* placeholder = findVisualItem(window->contentItem(), "threadPlaceholder");
    QVERIFY(placeholder);
    QTRY_COMPARE(placeholder->property("text").toString(), QString("What should we build in Example project?"));
    QVERIFY(placeholder->isVisible());
    QVERIFY(!page->isVisible());
    bridge.publish("route", QVariantMap{{"kind", "settings"}, {"section", "/settings/projects"}});
    QTRY_VERIFY(page->isVisible());
    bridge.publish("route", QVariant());
    QTRY_VERIFY(page->isVisible());
  }

  void layoutsFit_data() {
    QTest::addColumn<QString>("example");
    QTest::addColumn<int>("width");
    for (const auto& example : {"minimal", "glass", "terminal", "dashboard", "folders"}) {
      for (const int width : {1400, 1000, 640}) {
        QTest::newRow(qPrintable(QString("%1-%2").arg(example).arg(width))) << QString(example) << width;
      }
    }
#ifdef Q_OS_MACOS
    for (const int width : {1400, 1000, 900, 640}) {
      QTest::newRow(qPrintable(QString("glass-macos-%1").arg(width))) << QString("glass-macos") << width;
    }
#endif
  }

  void layoutsFit() {
    QFETCH(QString, example);
    QFETCH(int, width);
    const QDir source(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/examples/") + example);
    for (const auto& file : source.entryList(QDir::Files)) {
      const QString target = directory.filePath(file);
      if (QFile::exists(target)) QVERIFY(QFile::remove(target));
      QVERIFY(QFile::copy(source.filePath(file), target));
    }
    theme->reload();
    runtime->reload();
    QVERIFY2(runtime->usingUserShell(), qPrintable(runtime->lastError()));
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    window->resize(width, 880);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    auto* title = window->findChild<QQuickItem*>("threadLabel");
    QVERIFY(title);
    if (width == 1400) QTRY_VERIFY(!title->property("truncated").toBool());
    QTRY_VERIFY(title->mapToScene(QPointF(title->width(), 0)).x() <= window->width());
    if (width == 1000) threadRoutesDrawTheCentre(window);

    if (example == "glass-macos") {
      // The page's breakpoints: the sidebar goes off-canvas under 768, the
      // right panel becomes a sheet under 980. Panels slide, so every
      // geometry check waits.
      const bool sidebarOverlay = width < 768;
      const bool inspectorOverlay = width < 980;
      auto* navigation = window->findChild<QQuickItem*>("macNavigation");
      auto* content = window->findChild<QQuickItem*>("macContent");
      QVERIFY(navigation);
      QVERIFY(content);
      QVERIFY(!(window->flags() & Qt::FramelessWindowHint));
      QVERIFY(theme->windowLiquidGlass());
      QTRY_VERIFY(navigation->isVisible());
      QTRY_COMPARE(navigation->width(), 256);
      QTRY_COMPARE(content->width(), sidebarOverlay ? width : width - 256);
      const qreal withSidebar = content->width();
      bridge.publish("layout", QVariantMap{{"sidebarCollapsed", true}});
      QTRY_VERIFY(!navigation->isVisible());
      QTRY_COMPARE(content->width(), width);
      bridge.publish("settings", QVariantMap{{"active", true}, {"sections", QVariantList{}},
                                             {"searchQuery", ""}, {"searchResults", QVariantList{}}});
      QTRY_VERIFY(navigation->isVisible());
      QTRY_COMPARE(navigation->width(), 256);
      QTRY_COMPARE(content->width(), width - 256);
      bridge.publish("settings", QVariant());
      QTRY_VERIFY(!navigation->isVisible());
      bridge.publish("layout", QVariantMap{{"sidebarCollapsed", false}});
      QTRY_VERIFY(navigation->isVisible());
      QTRY_COMPARE(content->width(), withSidebar);
      QVERIFY(content->width() >= 300);
      QVERIFY(content->mapToScene(QPointF(content->width(), 0)).x() <= window->width());
      auto* inspector = window->findChild<QQuickItem*>("macInspector");
      QVERIFY(inspector);
      if (sidebarOverlay) {
        bridge.publish("layout", QVariantMap{{"sidebarCollapsed", true}});
        QTRY_VERIFY(!navigation->isVisible());
      }
      const qreal beforeInspector = content->width();
      content->forceActiveFocus();
      QTRY_VERIFY(content->hasActiveFocus());
      auto panel = QJsonDocument::fromJson(R"({
        "isOpen":true,"tabs":[],"activeId":"","embedPath":"",
        "canAdd":{"diff":true,"files":true,"terminal":true,"pullRequest":false}
      })").toVariant().toMap();
      bridge.publish("panel", panel);
      QTRY_VERIFY(inspector->isVisible());
      QTRY_VERIFY(inspector->width() > 0);
      QTRY_COMPARE(inspector->mapToScene(QPointF(inspector->width(), 0)).x(), qreal(window->width()));
      if (inspectorOverlay) {
        // A sheet: the content keeps its width, loses input, and Escape closes it.
        QTRY_COMPARE(content->width(), beforeInspector);
        QVERIFY(!content->isEnabled());
        QVERIFY(!content->hasActiveFocus());
        auto* toggle = window->findChild<QQuickItem*>("macInspectorToggle");
        QVERIFY(toggle);
        toggle->forceActiveFocus();
        QSignalSpy actions(&bridge, &ShellBridge::actionRequested);
        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_COMPARE(actions.count(), 1);
        QCOMPARE(actions.first().first().toString(), "rightPanel.toggle");
        // The page remains authoritative and publishes the result of the action.
      } else {
        // Beside the content: the content folds back and stays usable.
        QTRY_VERIFY(content->width() < beforeInspector);
        QVERIFY(content->isEnabled());
        QVERIFY(content->hasActiveFocus());
      }
      QTRY_VERIFY(content->width() >= 300);
      panel["isOpen"] = false;
      bridge.publish("panel", panel);
      QTRY_VERIFY(!inspector->isVisible());
      QTRY_VERIFY(content->isEnabled());
      QTRY_VERIFY(content->hasActiveFocus());
      QTRY_COMPARE(content->width(), beforeInspector);
      if (!sidebarOverlay) QVERIFY(navigation->isVisible());
      bridge.publish("panel", QVariant());
      bridge.publish("layout", QVariantMap{{"sidebarCollapsed", false}});
      if (sidebarOverlay) {
        QTRY_VERIFY(navigation->isVisible());
        QTRY_COMPARE(navigation->x(), 0);
        QTRY_VERIFY(!content->isEnabled());
        QSignalSpy actions(&bridge, &ShellBridge::actionRequested);
        QTest::keyClick(window, Qt::Key_Escape);
        QTRY_COMPARE(actions.count(), 1);
        QCOMPARE(actions.first().first().toString(), "sidebar.toggle");
        bridge.publish("layout", QVariantMap{{"sidebarCollapsed", true}});
        QTRY_VERIFY(content->isEnabled());
        QTRY_VERIFY(content->hasActiveFocus());
        bridge.publish("layout", QVariantMap{{"sidebarCollapsed", false}});
      }
      // The terminal drawer folds open to its height and back to nothing.
      // The slot stays visible at zero height (an invisible item gets no layout
      // height, so it could never open); the drawer inside it is what hides.
      auto* terminal = window->findChild<QQuickItem*>("macTerminal");
      QVERIFY(terminal);
      QVERIFY(!terminal->childItems().isEmpty());
      auto* drawer = terminal->childItems().first();
      QCOMPARE(terminal->height(), 0);
      QVERIFY(!drawer->isVisible());
      QObject* terminals = terminalsOf(engine);
      QVERIFY(terminals);
      const qreal beforeTerminal = content->height();
      terminals->setProperty("available", true);
      terminals->setProperty("open", true);
      QTRY_COMPARE(terminal->height(), 280);
      QVERIFY(drawer->isVisible());
      QCOMPARE(content->height(), beforeTerminal);
      terminals->setProperty("open", false);
      QTRY_COMPARE(terminal->height(), 0);
      QVERIFY(!drawer->isVisible());
      QMetaObject::invokeMethod(terminals, "reset");
    }

    if (example == "folders") {
      auto* explorer = window->findChild<QQuickItem*>("folderExplorer");
      QVERIFY(explorer);
      auto* page = window->findChild<QQuickItem*>("HalC2WebSurface");
      QVERIFY(page);
      auto* threads = window->findChild<QQuickItem*>("threadSidebar");
      QVERIFY(threads);
      QVERIFY(threads->isVisible());
      QVERIFY(explorer->isVisible());
      QTRY_VERIFY(explorer->width() > 0);
      QTRY_VERIFY(page->mapToScene(QPointF()).x() >= explorer->mapToScene(QPointF(explorer->width(), 0)).x());
      QTRY_VERIFY(page->width() >= 300);
      if (width >= 1100) {
        QTRY_VERIFY(explorer->mapToScene(QPointF()).x() >= threads->mapToScene(QPointF(threads->width(), 0)).x());
      } else {
        QTRY_VERIFY(explorer->mapToScene(QPointF()).y() >= threads->mapToScene(QPointF(0, threads->height())).y());
      }
    }
    if (example != "dashboard") return;
    QVERIFY(window->setProperty("drawerOpen", true));
    auto* drawer = window->findChild<QQuickItem*>("drawer");
    QVERIFY(drawer);
    QTRY_VERIFY(drawer->opacity() > 0.99);
    for (const auto& name : {"workspaceCard", "calendarCard", "metersCard", "agentCard"}) {
      auto* card = window->findChild<QQuickItem*>(name);
      QVERIFY2(card, name);
      QTRY_VERIFY2(card->mapToItem(drawer, QPointF(card->width(), 0)).x() <= drawer->width() - 10, name);
      QVERIFY(card->mapToItem(drawer, QPointF(0, 0)).x() >= 10);
    }
    auto* branch = window->findChild<QQuickItem*>("branchChip");
    QVERIFY(branch);
    QTRY_VERIFY(branch->width() <= branch->parentItem()->width());
    if (width == 1000) {
      drawer->setHeight(200);
      auto* actions = window->findChild<QQuickItem*>("agentActions");
      QVERIFY(actions);
      const auto area = actions->mapRectToScene(QRectF(0, 0, actions->width(), actions->height())).toAlignedRect();
      QVERIFY(area.top() > drawer->mapToScene(QPointF(0, drawer->height())).y());
      QVERIFY(area.bottom() < window->height());
      const auto clipped = window->grabWindow().copy(area);
      QVERIFY(!clipped.isNull());
      actions->setVisible(false);
      QTRY_COMPARE(window->grabWindow().copy(area), clipped);
      actions->setVisible(true);
    }
    auto* scroll = window->findChild<QObject*>("drawerScroll");
    QVERIFY(scroll);
    auto* content = scroll->property("contentItem").value<QQuickItem*>();
    QVERIFY(content);
    const qreal bottom = content->property("contentHeight").toReal() - content->height();
    if (bottom > 0) {
      QVERIFY(content->setProperty("contentY", bottom));
      auto* agent = window->findChild<QQuickItem*>("agentCard");
      QVERIFY(agent);
      QTRY_VERIFY(agent->mapToItem(drawer, QPointF(0, agent->height())).y() <= drawer->height() - 10);
    }
  }

  // Scenario: A right panel tab is activated from the keyboard (features/navigation/focus.feature)
  void panelTabsSupportKeyboardActivationAndClose() {
    QFile source(directory.filePath("shell.qml"));
    QVERIFY(source.open(QIODevice::WriteOnly | QIODevice::Truncate));
    source.write("import QtQuick\nimport HalC2.Bricks\nShellWindow { width: 600; height: 400; RightPanel { anchors.fill: parent } }");
    source.close();
    bridge.publish("panel", QJsonDocument::fromJson(R"({
      "isOpen": true, "activeId": "diff", "embedPath": "/test",
      "tabs": [{"id": "diff", "kind": "diff", "title": "Diff", "native": true},
               {"id": "files", "kind": "files", "title": "Files", "native": true}],
      "canAdd": {"diff": true, "files": true, "terminal": true, "pullRequest": false}
    })").toVariant());
    runtime->reload();
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    QTRY_VERIFY(findVisualItem(window->contentItem(), "panelTab-files"));
    auto* tab = findVisualItem(window->contentItem(), "panelTab-files");
    auto* close = findVisualItem(window->contentItem(), "panelClose-files");
    QVERIFY(tab);
    QVERIFY(close);
    QSignalSpy actions(&bridge, &ShellBridge::actionRequested);
    tab->forceActiveFocus(Qt::TabFocusReason);
    QTest::keyClick(window, Qt::Key_Return);
    QCOMPARE(actions.size(), 1);
    QCOMPARE(actions.last().at(0).toString(), QString("rightPanel.activate"));
    QCOMPARE(actions.last().at(1).toMap().value("id").toString(), QString("files"));
    close->forceActiveFocus(Qt::TabFocusReason);
    QTest::keyClick(window, Qt::Key_Space);
    QCOMPARE(actions.size(), 2);
    QCOMPARE(actions.last().at(0).toString(), QString("rightPanel.close"));
    QCOMPARE(actions.last().at(1).toMap().value("id").toString(), QString("files"));
    bridge.publish("panel", QVariant());
  }

  // Scenario: Explicitly opening a terminal focuses it (features/navigation/focus.feature)
  void terminalDrawerTakesAndReturnsTheKeyboard() {
    QFile source(directory.filePath("shell.qml"));
    QVERIFY(source.open(QIODevice::WriteOnly | QIODevice::Truncate));
    source.write("import QtQuick\nimport QtQuick.Controls\nimport QtQuick.Layouts\nimport HalC2.Bricks\n"
                 "ShellWindow { width: 600; height: 600; ColumnLayout { anchors.fill: parent\n"
                 "  TextField { objectName: 'composerField'; Layout.fillWidth: true; focus: true }\n"
                 "  TerminalDrawer { objectName: 'terminalDrawer'; Layout.fillWidth: true } } }");
    source.close();
    runtime->reload();
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    QObject* terminals = terminalsOf(engine);
    QVERIFY(terminals);
    terminals->setProperty("available", true);
    terminals->setProperty("height", 240);
    QMetaObject::invokeMethod(terminals, "addTab", Q_ARG(QVariant, "term-1"), Q_ARG(QVariant, "Terminal 1"), Q_ARG(QVariant, QVariant()));
    terminals->setProperty("activeTerminalId", "term-1");
    terminals->setProperty("activeGroup", "term-1");
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    window->requestActivate();
    QVERIFY(QTest::qWaitForWindowExposed(window));
    auto* composer = window->findChild<QQuickItem*>("composerField");
    auto* drawer = window->findChild<QQuickItem*>("terminalDrawer");
    QVERIFY(composer);
    QVERIFY(drawer);
    composer->forceActiveFocus();
    QTRY_COMPARE(window->activeFocusItem(), composer);

    // The toggle opened the drawer and asked for focus: the terminal gets the keys.
    terminals->setProperty("open", true);
    QMetaObject::invokeMethod(terminals, "focusRequested", Q_ARG(QString, "term-1"));
    QTRY_VERIFY(window->activeFocusItem() && drawer->isAncestorOf(window->activeFocusItem()));
    QCOMPARE(window->activeFocusItem()->objectName(), QString("HalC2Terminal"));

    // What is typed there goes to the terminal's session.
    QTest::keyClick(window, Qt::Key_A);
    auto* session = qvariant_cast<QObject*>(
        window->activeFocusItem()->property("session"));
    QVERIFY(session);
    QTRY_COMPARE(session->property("written").toStringList(), QStringList{"a"});

    // Closing it hands them back to the composer.
    terminals->setProperty("open", false);
    QTRY_COMPARE(window->activeFocusItem(), composer);

    QMetaObject::invokeMethod(terminals, "reset");
  }

  // Scenario: The user splits a terminal tab (features/terminal/tabs.feature): the
  // right panel's terminal tab lays its group out side by side, and its split
  // buttons act on the group's active terminal until the group is full.
  void terminalPanelTabShowsItsSplitGroup() {
    QFile source(directory.filePath("shell.qml"));
    QVERIFY(source.open(QIODevice::WriteOnly | QIODevice::Truncate));
    source.write("import QtQuick\nimport HalC2.Bricks\nShellWindow { width: 800; height: 400; RightPanel { anchors.fill: parent } }");
    source.close();
    bridge.publish("panel", QJsonDocument::fromJson(R"({
      "isOpen": true, "activeId": "terminal:group-1", "embedPath": "/test",
      "tabs": [{"id": "terminal:group-1", "kind": "terminal", "title": "Terminal", "native": true}],
      "canAdd": {"diff": true, "files": true, "terminal": true, "pullRequest": false}
    })").toVariant());
    runtime->reload();
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    QObject* terminals = terminalsOf(engine);
    QVERIFY(terminals);
    terminals->setProperty("available", true);
    QMetaObject::invokeMethod(terminals, "addTab", Q_ARG(QVariant, "term-1"), Q_ARG(QVariant, "Terminal 1"), Q_ARG(QVariant, QVariant()));
    QMetaObject::invokeMethod(terminals, "addTab", Q_ARG(QVariant, "term-2"), Q_ARG(QVariant, "Terminal 2"),
                              Q_ARG(QVariant, QVariantMap({{"group", "group-1"}, {"panel", true}, {"slot", 0}, {"span", 2}})));
    QMetaObject::invokeMethod(terminals, "addTab", Q_ARG(QVariant, "term-3"), Q_ARG(QVariant, "Terminal 3"),
                              Q_ARG(QVariant, QVariantMap({{"group", "group-1"}, {"panel", true}, {"slot", 1}, {"span", 2}, {"current", true}})));
    terminals->setProperty("groupSizes", QVariantMap{{"group-1", 2}});
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    QVERIFY(QTest::qWaitForWindowExposed(window));

    QTRY_VERIFY(findVisualItem(window->contentItem(), "terminalCell-term-3"));
    auto* left = findVisualItem(window->contentItem(), "terminalCell-term-2");
    auto* right = findVisualItem(window->contentItem(), "terminalCell-term-3");
    QVERIFY(left);
    auto* drawers = findVisualItem(window->contentItem(), "terminalCell-term-1");
    QVERIFY(drawers && !drawers->isVisible() && !drawers->property("item").value<QQuickItem*>());  // the drawer's, not made here
    QTRY_VERIFY(right->width() > 0);
    QCOMPARE(left->y(), right->y());
    QCOMPARE(left->x() + left->width(), right->x());
    QVERIFY(qAbs(left->width() - right->width()) <= 1);

    auto* split = findVisualItem(window->contentItem(), "terminalPanelSplit");
    QVERIFY(split);
    QSignalSpy actions(&bridge, &ShellBridge::actionRequested);
    QVERIFY(QMetaObject::invokeMethod(split, "clicked"));
    QCOMPARE(actions.size(), 1);
    QCOMPARE(actions.last().at(0).toString(), QString("terminal.split"));
    QCOMPARE(actions.last().at(1).toMap().value("terminalId").toString(), QString("term-3"));

    terminals->setProperty("groupSizes", QVariantMap{{"group-1", 4}});
    QTRY_VERIFY(!split->isEnabled());
    bridge.publish("panel", QVariant());
    QMetaObject::invokeMethod(terminals, "reset");
  }

  void dashboardDimmerPreservesRoundedCorners() {
    const QDir source(QStringLiteral(HAL_C2_TEST_SOURCE_DIR "/examples/dashboard"));
    for (const auto& file : source.entryList(QDir::Files)) {
      const QString target = directory.filePath(file);
      if (QFile::exists(target)) QVERIFY(QFile::remove(target));
      QVERIFY(QFile::copy(source.filePath(file), target));
    }
    theme->reload();
    runtime->reload();
    QVERIFY2(runtime->usingUserShell(), qPrintable(runtime->lastError()));
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    window->resize(1400, 880);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    auto* page = findVisualItem(window->contentItem(), "HalC2WebSurface");
    auto* drawer = findVisualItem(window->contentItem(), "drawer");
    QVERIFY(page);
    QVERIFY(drawer);
    QTRY_VERIFY(page->width() > 400);
    QTRY_VERIFY(page->height() > 400);
    // about:blank lacks the app's CSS corner mask; isolate the native dimmer.
    page->setVisible(false);
    const QRect bounds = page->mapRectToScene(QRectF(0, 0, page->width(), page->height())).toAlignedRect();
    const QPoint corner = bounds.topLeft() + QPoint(1, 1);
    const QPoint center = QPoint(bounds.center().x(), bounds.bottom() - 30);
    const QImage closed = window->grabWindow();
    QVERIFY(!closed.isNull());
    QVERIFY(window->setProperty("drawerOpen", true));
    QTRY_VERIFY(drawer->opacity() > 0.99);
    QTRY_VERIFY(window->grabWindow().pixelColor(center) != closed.pixelColor(center));
    QCOMPARE(window->grabWindow().pixelColor(corner), closed.pixelColor(corner));
    QSignalSpy unloadWarnings(engine, &QQmlEngine::warnings);
    QVERIFY(unloadWarnings.isValid());
    QVERIFY(window->setProperty("drawerOpen", false));
    QTRY_VERIFY(drawer->opacity() < 0.01);
    QTRY_COMPARE(window->grabWindow().pixelColor(center), closed.pixelColor(center));
    QCOMPARE(unloadWarnings.count(), 0);
  }

  void extensionToolbarReservesSpaceAndReleasesIt_data() {
    QTest::addColumn<int>("width");
    QTest::newRow("narrow") << 640;
    QTest::newRow("wide") << 1280;
  }

  void extensionToolbarReservesSpaceAndReleasesIt() {
    QFETCH(int, width);
    QFile source(directory.filePath("shell.qml"));
    QVERIFY(source.open(QIODevice::WriteOnly | QIODevice::Truncate));
    source.write(R"(
      import QtQuick
      import HalC2.Bricks
      DefaultShell {
        property bool toolbarEnabled: true
        toolbar: toolbarEnabled ? extension : null
        Component {
          id: extension
          Item { implicitHeight: 48; objectName: "toolbarContent" }
        }
      }
    )");
    source.close();
    runtime->reload();
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    window->resize(width, 820);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    auto* workspace = window->property("workspace").value<QQuickItem*>();
    auto* webView = window->property("webView").value<QQuickItem*>();
    auto* toolbar = window->findChild<QQuickItem*>("extensionToolbar");
    QVERIFY(workspace);
    QVERIFY(webView);
    QVERIFY(toolbar);
    QTRY_COMPARE(toolbar->height(), 48);
    QTRY_COMPARE(toolbar->mapToScene(QPointF()).y(), workspace->mapToScene(QPointF(0, workspace->height())).y());
    QTRY_COMPARE(webView->mapToScene(QPointF()).y(), toolbar->mapToScene(QPointF(0, toolbar->height())).y());
    QPointer<QQuickItem> content = toolbar->property("item").value<QQuickItem*>();
    QVERIFY(content);
    QCOMPARE(content->width(), toolbar->width());

    QVERIFY(window->setProperty("toolbarEnabled", false));
    QTRY_VERIFY(!toolbar->property("active").toBool());
    QTRY_VERIFY(!toolbar->isVisible());
    QTRY_VERIFY(content.isNull());
    QTRY_COMPARE(webView->mapToScene(QPointF()).y(), workspace->mapToScene(QPointF(0, workspace->height())).y());
  }

  // Scenario: The sidebar snaps rather than animating its width, Settings
  // replace the thread list with the settings sections
  // (features/navigation/layout.feature): the built-in layout hides the thread
  // list in one step, and shows the settings sections in its place.
  void defaultShellHidesTheThreadListAtOnce() {
    QFile::remove(directory.filePath("shell.qml"));
    runtime->reload();
    QVERIFY(!runtime->usingUserShell());
    QVERIFY2(runtime->lastError().isEmpty(), qPrintable(runtime->lastError()));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    window->resize(1200, 800);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    auto* sidebar = findVisualItem(window->contentItem(), "threadSidebar");
    auto* settingsNav = findVisualItem(window->contentItem(), "settingsNav");
    auto* workspace = findVisualItem(window->contentItem(), "workspace");
    QVERIFY(sidebar);
    QVERIFY(settingsNav);
    QVERIFY(workspace);
    QTRY_VERIFY(sidebar->isVisible());
    QTRY_COMPARE(workspace->width(), window->width() - 256.0);

    QSignalSpy resized(workspace, &QQuickItem::widthChanged);
    bridge.publish("layout", QVariantMap{{"sidebarCollapsed", true}});
    QTRY_VERIFY(!sidebar->isVisible());
    QTRY_COMPARE(workspace->width(), qreal(window->width()));
    QCOMPARE(resized.count(), 1);

    resized.clear();
    bridge.publish("layout", QVariantMap{{"sidebarCollapsed", false}});
    QTRY_VERIFY(sidebar->isVisible());
    QTRY_COMPARE(workspace->width(), window->width() - 256.0);
    QCOMPARE(resized.count(), 1);

    bridge.publish("route", QVariantMap{{"kind", "settings"}, {"section", "/settings/general"}});
    QTRY_VERIFY(settingsNav->isVisible());
    QVERIFY(!sidebar->isVisible());
    QCOMPARE(settingsNav->x(), 0.0);
    bridge.publish("route", QVariant());
    QTRY_VERIFY(sidebar->isVisible());
    QVERIFY(!settingsNav->isVisible());
  }

  // Scenario: A broken shell layout falls back to the default
  // (features/navigation/layout.feature): the built-in shell shows, and says
  // why, until the file is fixed.
  void brokenShellFallsBackAndSaysWhy() {
    QFile source(directory.filePath("shell.qml"));
    QVERIFY(source.open(QIODevice::WriteOnly | QIODevice::Truncate));
    source.write("import QtQuick\nimport HalC2.Bricks\nShellWindow { Nonsense {} }");
    source.close();
    runtime->reload();
    QVERIFY(!runtime->usingUserShell());
    QVERIFY(runtime->lastError().contains("Nonsense"));
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    QVERIFY(QTest::qWaitForWindowExposed(window));
    QVERIFY(findVisualItem(window->contentItem(), "threadSidebar"));
    auto* error = findVisualItem(window->contentItem(), "shellError");
    QVERIFY(error);
    QTRY_VERIFY(error->isVisible());

    QVERIFY(QFile::remove(directory.filePath("shell.qml")));
    runtime->reload();
    QVERIFY(runtime->lastError().isEmpty());
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    error = findVisualItem(window->contentItem(), "shellError");
    QVERIFY(error);
    QVERIFY(!error->isVisible());
  }

  // Scenario: A theme can ask for the system window frame, and Scenario: A
  // theme can make the window translucent (features/navigation/windows.feature).
  void themeSetsTheWindowFrameAndOpacity() {
    QFile::remove(directory.filePath("shell.qml"));
    QFile file(directory.filePath("theme.json"));
    const bool hadTheme = file.exists();
    QByteArray previous;
    if (hadTheme) {
      QVERIFY(file.open(QIODevice::ReadOnly));
      previous = file.readAll();
      file.close();
    }
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(R"({"window": {"frameless": false, "opacity": 0.9}})");
    file.close();
    theme->reload();
    runtime->reload();
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    auto* engine = runtime->findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    auto* window = qobject_cast<QQuickWindow*>(engine->rootObjects().last());
    QVERIFY(window);
    QVERIFY(!window->flags().testFlag(Qt::FramelessWindowHint));
    QCOMPARE(window->opacity(), 0.9);

    // Back to the default: HAL-C2 draws its own frame, opaque.
    if (hadTheme) {
      QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
      file.write(previous);
      file.close();
    } else {
      QVERIFY(QFile::remove(directory.filePath("theme.json")));
    }
    theme->reload();
    QTRY_VERIFY(window->flags().testFlag(Qt::FramelessWindowHint) == theme->frameless());
  }

  void cleanupTestCase() {
    runtime.reset();
    profile.reset();
    theme.reset();
  }
};

int main(int argc, char** argv) {
  QtWebEngineQuick::initialize();
  QGuiApplication app(argc, argv);
  useSoftwareRenderingWithoutDisplay();
  ShellExamplesTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ShellExamples.moc"
