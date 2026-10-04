#pragma once

#include <QDateTime>
#include <QHash>
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

#include "FakeMc.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellWindows.h"
#include "ThemeStore.h"
#include "WorkspaceController.h"

class Brick;

// An action no controller handled, or one native code sent the bricks
// (ShellBridge::actionRequested).
struct BrickAction {
  QString type;
  QVariantMap payload;
};

// The shell as main.cpp builds it, a recorder of what reaches the bricks, and
// the MC. One per scenario.
class World {
public:
  World();
  ~World();

  FakeMc mc;
  QList<BrickAction> brickActions;
  // The draft the last new thread opened.
  QString draftId;
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
  // A brick the scenario keeps on screen (DeviceSteps' DevicePanel): it goes
  // before the shell it draws, on restart too.
  std::unique_ptr<Brick> brick;
  // A question a brick asks in a dialog of its own: "the user confirms" and "the user cancels" answer it.
  std::function<void(bool accepted)> answerQuestion;
  // What else a page tells the user in place (an inline error), for "the user is told".
  std::function<QStringList()> toldInPlace;
  // Steps two pages share the words of: what they check on the settings page, by a name the two files agree on
  // ("hasAction", "invalidProjectFile", "isShown", "openResult", "inView"), set while a scenario is on that page.
  QHash<QString, std::function<void(const QStringList& captures)>> onSettingsPage;

  ShellBridge& bridge() { return *m_bridge; }
  NativeShell& native() { return *m_native; }
  // The shell's config directory (theme.json, preferences.json), fresh per
  // scenario and kept across restarts, and the palette main.cpp builds over it.
  QString configDir() const { return m_home.filePath(QStringLiteral("config")); }
  // Where the shell keeps its state (`state/`) and data (`data/`).
  QString homeDir() const { return m_home.path(); }
  ThemeStore& theme() { return *m_theme; }
  QVariant state(const QString& key) const { return m_bridge->state()->value(key); }
  // The desktop quits and starts again: a new shell, the same files.
  void restart();
  // Puts every window of the shell on screen (as main.cpp does), each a
  // bare window, so the user can close them.
  ShellWindows& showWindows();
  // Closes `window` as the user does, from its window on screen.
  void closeWindow(NativeWindow* window);
  // How often the user closed the last window left.
  int lastWindowClosed = 0;

  void setTime(const QString& iso);
  void setTime(const QDateTime& now);
  QDateTime now() const { return m_now; }

  // Dispatches `thread.new`; the draft it opens (if any) becomes draftId.
  void startNewThread(const QVariantMap& payload);
  // Opens the draft of the MC's project `projectId`, which becomes draftId.
  void openDraft(const QString& projectId);
  // The key of the sidebar's project named `name`; `name` itself when none is.
  QString projectKey(const QString& name) const;

  void connect(const QString& token = QStringLiteral("mc-token"));
  int shellSubscriptions() const;

  // `what` is read on timeout, so it can describe the state the wait gave up on.
  void waitFor(const std::function<bool()>& condition, const std::function<QString()>& what);
  void waitFor(const std::function<bool()>& condition, const QString& what);

  // A round trip through the MC: everything the MC sent before, and every
  // answer to a command sent before, has been handled once it returns.
  void sync();

  QList<BrickAction> actionsOf(const QString& type) const;
  QString describeBrickActions() const;
  QString describeCommands() const;

private:
  void start();

  QDateTime m_now;
  // Where the shell keeps its files (the last route, config), across restarts.
  QTemporaryDir m_home;
  // Declared in teardown order: the shell goes before the bridge it intercepts.
  std::unique_ptr<ShellBridge> m_bridge;
  std::unique_ptr<NativeShell> m_native;
  std::unique_ptr<ThemeStore> m_theme;
  std::unique_ptr<ShellWindows> m_windows;
};
