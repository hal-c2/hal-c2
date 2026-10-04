#include "World.h"

#include <QDateTime>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QTest>

#include "Brick.h"
#include "ComposerController.h"
#include "DraftController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "OnboardingController.h"
#include "ProviderSettingsController.h"
#include "SettingsController.h"
#include "FileActionsController.h"
#include "ThreadMenuController.h"
#include "RightPanelController.h"
#include "ThreadStore.h"
#include "ToastController.h"
#include "UsageController.h"

World::World() {
  m_now = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
  QDir(m_home.path()).mkpath(QStringLiteral("config"));
  start();
}

World::~World() {
  brick.reset();
}

// As main.cpp wires them.
void World::start() {
  m_bridge = std::make_unique<ShellBridge>();
  m_native = std::make_unique<NativeShell>(m_bridge.get());
  m_native->client()->setRetryDelays({20});
  m_native->sidebar()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
  m_native->controller<ThreadStore>()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
  m_native->setStoreDirs(m_home.filePath(QStringLiteral("state")), m_home.filePath(QStringLiteral("data")));
  // The shell runs its own local MC, so local folders are its to open.
  m_bridge->setLocalFolderImportEnabled(true);
  m_native->controller<SettingsController>()->setDevicePath(QDir(configDir()).filePath(QStringLiteral("preferences.json")));
  m_theme = std::make_unique<ThemeStore>(configDir());
  m_theme->applyBaseTheme(state(QStringLiteral("theme")));
  QObject::connect(m_bridge.get(), &ShellBridge::stateEntryChanged, m_theme.get(), [this](const QString& key, const QVariant& value) {
    if (key == QLatin1String("theme")) m_theme->applyBaseTheme(value);
  });
  m_bridge->setUrlOpener([this](const QUrl& url) { openedUrls.append(url); });
  const auto writeClipboard = [this](const QString& text) {
    if (clipboardFails) return false;
    clipboard = text;
    return true;
  };
  m_native->controller<ThreadMenuController>()->setClipboardWriter(writeClipboard);
  m_native->controller<FileActionsController>()->setClipboardWriter(writeClipboard);
  m_native->controller<ProviderSettingsController>()->setClipboardWriter(writeClipboard);
  m_native->controller<RightPanelController>()->review()->setClipboardWriter(writeClipboard);
  setTime(m_now);
  QObject::connect(m_bridge.get(), &ShellBridge::actionRequested, m_bridge.get(),
                   [this](const QString& type, const QVariant& payload) { brickActions.append({type, payload.toMap()}); });
  QObject::connect(m_native.get(), &NativeShell::lastWindowClosed, m_native.get(), [this] { ++lastWindowClosed; });
  m_native->restoreWindows();
}

ShellWindows& World::showWindows() {
  if (!m_windows) {
    const QString dir = m_home.filePath(QStringLiteral("windows"));
    QDir().mkpath(dir);
    QFile shell(QDir(dir).filePath(QStringLiteral("shell.qml")));
    if (!shell.exists() && shell.open(QIODevice::WriteOnly)) shell.write("import QtQuick\nWindow { visible: true }\n");
    shell.close();
    m_windows = std::make_unique<ShellWindows>(m_native.get(), ShellRuntime::Options{dir, {}}, m_theme.get());
    m_windows->start();
  }
  return *m_windows;
}

void World::closeWindow(NativeWindow* window) {
  ShellRuntime* runtime = showWindows().runtime(window);
  expect(runtime && runtime->window(), QStringLiteral("the window %1 is not on screen").arg(window->id()));
  runtime->window()->close();
  // The shell closes it once the window's own close is over.
  QCoreApplication::sendPostedEvents();
  QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
}

void World::restart() {
  brick.reset();
  m_windows.reset();
  m_theme.reset();
  m_native.reset();
  m_bridge.reset();
  brickActions.clear();
  start();
}

void World::startNewThread(const QVariantMap& payload) {
  m_bridge->dispatch(QStringLiteral("thread.new"), payload);
  const QVariantMap route = state(QStringLiteral("route")).toMap();
  if (route.value(QStringLiteral("kind")) == QLatin1String("draft")) draftId = route.value(QStringLiteral("draftId")).toString();
}

void World::openDraft(const QString& projectId) {
  draftId = m_native->controller<DraftController>()->start(mc.environmentId, projectId);
}

QString World::projectKey(const QString& name) const {
  for (const QVariant& project : state(QStringLiteral("sidebar")).toMap().value(QStringLiteral("projects")).toList()) {
    const QVariantMap map = project.toMap();
    if (map.value(QStringLiteral("displayName")).toString() == name) return map.value(QStringLiteral("key")).toString();
  }
  return name;
}

void World::setTime(const QString& iso) {
  setTime(QDateTime::fromString(iso, Qt::ISODate));
}

void World::setTime(const QDateTime& time) {
  const QDateTime now = time.toLocalTime();
  m_now = now;
  m_native->sidebar()->setClock([now] { return now; });
  m_native->controller<ComposerController>()->setClock([now] { return now.toUTC(); });
  m_native->controller<ToastController>()->setClock([now] { return now.toUTC(); });
  m_native->controller<ThreadStore>()->setClock([now] { return now.toUTC(); });
  m_native->controller<RightPanelController>()->agents()->setClock([now] { return now.toUTC(); });
  m_native->controller<UsageController>()->setClock([now] { return now.toUTC(); });
  m_native->controller<OnboardingController>()->setClock([now] { return now.toUTC(); });
  m_native->controller<ToastController>()->expire();
}

void World::connect(const QString& token) {
  m_native->open(mc.origin(), token);
  waitFor([this] { return shellSubscriptions() >= 1; }, QStringLiteral("the shell to subscribe"));
}

int World::shellSubscriptions() const {
  int count = 0;
  for (const QJsonObject& sub : mc.subscriptions) {
    if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) count++;
  }
  return count;
}

void World::waitFor(const std::function<bool()>& condition, const std::function<QString()>& what) {
  if (!QTest::qWaitFor(condition, 5000)) fail(QStringLiteral("timed out waiting for ") + what());
}

void World::waitFor(const std::function<bool()>& condition, const QString& what) {
  waitFor(condition, [what] { return what; });
}

void World::sync() {
  bool done = false;
  m_native->client()->call(m_native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
  waitFor([&done] { return done; }, QStringLiteral("a round trip through the MC"));
}

QList<BrickAction> World::actionsOf(const QString& type) const {
  QList<BrickAction> result;
  for (const BrickAction& action : brickActions) {
    if (action.type == type) result.append(action);
  }
  return result;
}

QString World::describeBrickActions() const {
  QStringList lines;
  for (const BrickAction& action : brickActions) lines.append(action.type + QLatin1Char(' ') + show(action.payload));
  return lines.isEmpty() ? QStringLiteral("(nothing)") : lines.join(QStringLiteral("; "));
}

QString World::describeCommands() const {
  QStringList lines;
  for (const QJsonObject& command : mc.commands) {
    lines.append(QString::fromUtf8(QJsonDocument(command).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}
