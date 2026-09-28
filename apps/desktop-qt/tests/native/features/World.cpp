#include "World.h"

#include <QDateTime>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QTest>

#include "ComposerController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ThreadStore.h"
#include "ToastController.h"

World::World() {
  m_now = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
  QDir(m_home.path()).mkpath(QStringLiteral("config"));
  start();
}

// As main.cpp wires them.
void World::start() {
  m_bridge = std::make_unique<ShellBridge>();
  m_native = std::make_unique<NativeShell>(m_bridge.get());
  m_native->client()->setRetryDelays({20});
  m_native->sidebar()->setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
  m_native->controller<NavigationController>()->setStorePath(m_home.filePath(QStringLiteral("state/shell-route.json")));
  m_native->controller<SettingsController>()->setDevicePath(QDir(configDir()).filePath(QStringLiteral("preferences.json")));
  m_theme = std::make_unique<ThemeStore>(configDir());
  m_theme->applyBaseTheme(state(QStringLiteral("theme")));
  QObject::connect(m_bridge.get(), &ShellBridge::stateEntryChanged, m_theme.get(), [this](const QString& key, const QVariant& value) {
    if (key == QLatin1String("theme")) m_theme->applyBaseTheme(value);
  });
  setTime(m_now);
  QObject::connect(m_bridge.get(), &ShellBridge::actionRequested, m_bridge.get(),
                   [this](const QString& type, const QVariant& payload) { onPageAction(type, payload.toMap()); });
}

void World::restart() {
  m_theme.reset();
  m_native.reset();
  m_bridge.reset();
  pageActions.clear();
  follows.clear();
  pageNative = QVariant();
  start();
  // The page loads again and publishes what it publishes.
  publishSidebarInput();
}

void World::pageOpens(const QVariantMap& route, bool replace) {
  QVariantMap payload{
      {QStringLiteral("kind"), QStringLiteral("home")},
      {QStringLiteral("threadKey"), QVariant::fromValue(nullptr)},
      {QStringLiteral("draftId"), QVariant::fromValue(nullptr)},
      {QStringLiteral("projectKey"), QVariant::fromValue(nullptr)},
      {QStringLiteral("section"), QVariant::fromValue(nullptr)},
  };
  payload.insert(route);
  payload.insert(QStringLiteral("replace"), replace);
  m_bridge->dispatch(QStringLiteral("route.open"), payload);
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
  m_native->controller<ToastController>()->expire();
}

void World::publishWorkspace(const QString& threadKey, const QJsonObject& project, const QString& worktreePath,
                             bool draft) {
  const bool known = !project.isEmpty();
  m_bridge->publish(QStringLiteral("workspace"),
                   QVariantMap{
                       {QStringLiteral("threadKey"), threadKey},
                       {QStringLiteral("isDraft"), draft},
                       {QStringLiteral("projectRoot"), known ? project.value(QLatin1String("workspaceRoot")).toVariant() : QVariant()},
                       {QStringLiteral("worktreePath"), worktreePath.isEmpty() ? QVariant() : QVariant(worktreePath)},
                       {QStringLiteral("scripts"), project.value(QLatin1String("scripts")).toArray().toVariantList()},
                       {QStringLiteral("terminalAvailable"), known},
                   });
}

void World::connect(const QString& token) {
  m_native->open(node.origin(), token);
  waitFor([this] { return shellSubscriptions() >= 1; }, QStringLiteral("the shell to subscribe"));
}

int World::shellSubscriptions() const {
  int count = 0;
  for (const QJsonObject& sub : node.subscriptions) {
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
  m_native->client()->call(node.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
  waitFor([&done] { return done; }, QStringLiteral("a round trip through the node"));
}

QList<PageAction> World::actionsOf(const QString& type) const {
  QList<PageAction> result;
  for (const PageAction& action : pageActions) {
    if (action.type == type) result.append(action);
  }
  return result;
}

QString World::describePage() const {
  QStringList lines;
  for (const PageAction& action : pageActions) lines.append(action.type + QLatin1Char(' ') + show(action.payload));
  for (const QVariantMap& route : follows) lines.append(QStringLiteral("route.follow ") + show(route));
  return lines.isEmpty() ? QStringLiteral("(nothing)") : lines.join(QStringLiteral("; "));
}

QString World::describeCommands() const {
  QStringList lines;
  for (const QJsonObject& command : node.commands) {
    lines.append(QString::fromUtf8(QJsonDocument(command).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

void World::onPageAction(const QString& type, const QVariantMap& payload) {
  // The page's record of who owns what, not a request for it to act on.
  if (type == QLatin1String("shell.native")) {
    pageNative = payload;
    return;
  }
  // Where the page is told to be; the page goes there and says nothing back.
  if (type == QLatin1String("route.follow")) {
    follows.append(payload);
    return;
  }
  pageActions.append({type, payload});
  // The page applies a text change to its draft and publishes it back.
  if (type == QLatin1String("composer.text.set") &&
      payload.value(QStringLiteral("target")) == composer.value(QStringLiteral("target"))) {
    composer.insert(QStringLiteral("text"), payload.value(QStringLiteral("text")));
    publishComposer();
  }
}
