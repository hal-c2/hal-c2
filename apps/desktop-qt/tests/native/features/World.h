#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QQmlPropertyMap>
#include <QSet>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariant>

#include <functional>
#include <memory>
#include <optional>

#include "FakeNode.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ThemeStore.h"
#include "WorkspaceController.h"

struct PageAction {
  QString type;
  QVariantMap payload;
};

// The shell as main.cpp builds it, the page as a recorder of what the shell
// asks of it (plus the composer echo the real page makes), and the node. One
// per scenario.
class World {
public:
  World();

  FakeNode node;
  QList<PageAction> pageActions;
  QVariant pageNative;  // what the last `shell.native` told the page
  QList<QVariantMap> follows;  // every `route.follow` the page was sent
  // The draft the last new thread opened.
  QString draftId;
  QVariantMap composer;
  std::optional<qsizetype> command;  // the command the last "receives" step found
  QSet<qsizetype> checkedCommands;
  int nextEdit = 1;
  bool checking = false;  // the running step is an outcome (Step::outcome)
  QVariantMap themeDraft;  // what the theme editor holds (ThemeController::draft)
  QString settingRow;  // the settings row the scenario is about
  // The shell's clipboard and the addresses it opened in the browser, recorded
  // instead of touching the desktop's.
  QString clipboard;
  bool clipboardFails = false;
  QList<QUrl> openedUrls;

  ShellBridge& bridge() { return *m_bridge; }
  NativeShell& native() { return *m_native; }
  // The shell's config directory (theme.json, preferences.json), fresh per
  // scenario and kept across restarts, and the palette main.cpp builds over it.
  QString configDir() const { return m_home.filePath(QStringLiteral("config")); }
  ThemeStore& theme() { return *m_theme; }
  QVariant state(const QString& key) const { return m_bridge->state()->value(key); }
  // The desktop quits and starts again: a new shell and page, the same files.
  void restart();

  void setTime(const QString& iso);
  void setTime(const QDateTime& now);
  QDateTime now() const { return m_now; }

  // Dispatches `thread.new`; the draft it opens (if any) becomes draftId.
  void startNewThread(const QVariantMap& payload);
  // The key of the sidebar's project named `name`; `name` itself when none is.
  QString projectKey(const QString& name) const;
  void publishComposer() { m_bridge->publish(QStringLiteral("composer"), composer); }
  // The page reports that its own navigation took it to `route` (`route.open`).
  void pageOpens(const QVariantMap& route, bool replace = false);

  void connect(const QString& token = QStringLiteral("node-token"));
  int shellSubscriptions() const;

  // `what` is read on timeout, so it can describe the state the wait gave up on.
  void waitFor(const std::function<bool()>& condition, const std::function<QString()>& what);
  void waitFor(const std::function<bool()>& condition, const QString& what);

  // A round trip through the node: everything the node sent before, and every
  // answer to a command sent before, has been handled once it returns.
  void sync();

  QList<PageAction> actionsOf(const QString& type) const;
  QString describePage() const;
  QString describeCommands() const;

private:
  void onPageAction(const QString& type, const QVariantMap& payload);

  void start();

  QDateTime m_now;
  // Where the shell keeps its files (the last route, config), across restarts.
  QTemporaryDir m_home;
  // Declared in teardown order: the shell goes before the bridge it intercepts.
  std::unique_ptr<ShellBridge> m_bridge;
  std::unique_ptr<NativeShell> m_native;
  std::unique_ptr<ThemeStore> m_theme;
};
