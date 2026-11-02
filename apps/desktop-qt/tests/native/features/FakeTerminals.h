#pragma once
// What the other terminal steps files need from TerminalSteps.cpp: the MC's
// terminal manager and the thread the drawer is on.

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QPair>
#include <QString>
#include <QStringList>

#include <optional>

#include "TerminalController.h"

class FakeMc;
class QQuickItem;
class World;

namespace terminalfake {

// The MC's terminal manager: terminals attach with the `terminal` shape and
// are listed by `terminals`; `terminal.*` calls are recorded and act on them
// the way the MC's does.
struct FakeTerminals {
  struct Terminal {
    QJsonObject summary;
    QString history;
    qint64 sequence = 0;
  };
  // What a subscription that asked for `acks` holds, as HalC2.Terminal.OutputWindow:
  // the output it sent and has not heard back about, and whether it held some back.
  struct Window {
    QList<QPair<qint64, qsizetype>> pending;
    qsizetype bytes = 0;
    bool behind = false;
  };
  static constexpr qsizetype kWindowLimit = 64 * 1024;
  // By subscription id: only those that asked.
  QHash<int, Window> windows;
  // Every `ack` frame.
  QList<QJsonObject> acks;
  // By "threadId/terminalId".
  QMap<QString, Terminal> terminals;
  // Every terminal.* call, as {method, payload}.
  QList<QJsonObject> calls;
  // Why terminal.open fails, when it does.
  QString refuseOpen;
  // Why terminal.close fails, when it does.
  QString refuseClose;
  // Why terminal.write fails, when it does (the reason may be empty).
  std::optional<QString> refuseWrite;
  // The list stays silent about a terminal just opened.
  bool quietOpen = false;
  // A close's `remove` waits in heldRemoves, as if the list had not got there yet.
  bool holdRemove = false;
  QList<QJsonObject> heldRemoves;
  // What the shell prints back when it is written exactly this.
  QHash<QString, QString> replies;
  // The terminal the steps' right panel tab runs.
  QString panelTerminal;
};

// To the `terminal` subscriptions of "threadId/terminalId".
void sendTerminal(FakeMc& mc, const QString& key, const QJsonObject& event);
// To the latest `terminals` subscription.
void sendTerminals(FakeMc& mc, const QJsonObject& event);
QJsonObject terminalSummary(const QString& threadId, const QString& terminalId, const QString& cwd);
// The visible items of the world's brick named `objectName`, in drawing order.
QList<QQuickItem*> visibleItems(World& world, const QString& objectName);
// A terminal the MC already runs, as another client left it.
void addTerminal(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& label, bool busy);
void print(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& data);
// The terminal's output window of its subscription, if it asked for one.
FakeTerminals::Window* terminalWindow(FakeMc& mc, const QString& key);
// The `terminal` subscriptions still attached, by terminal key.
QStringList attached(FakeMc& mc);
QString tabLabels(World& world);
TerminalSession* terminalSession(World& world, const QString& terminalId);
// The latest attach of the terminal: its launch input.
std::optional<QJsonObject> terminalAttach(World& world, const QString& threadId, const QString& terminalId);
std::optional<QJsonObject> terminalCall(World& world, const QString& method, const QString& threadId, const QString& terminalId);
QString describeTerminalCalls(World& world);
QStringList terminalWrites(World& world, const QString& terminalId);
void addAction(World& world, const QString& project, const QString& name, const QString& command);
// Shows a thread of the project, on a worktree when given one.
void showThread(World& world, const QString& project, const QString& worktree = {});
// The id of the thread the header shows.
QString shownThread(World& world);
// The thread the header shows, or one of the MC's first project shown now.
QString ensureThread(World& world);
// The drawer's (or the right panel's) terminals, in order.
QList<TerminalTabs::Row> rowsIn(World& world, bool panel);
QString describeRows(World& world);
bool toastShown(World& world, const QString& title);
// Closing a terminal asks first (terminal/tabs.feature): the user says yes.
void confirmTerminalClose(World& world);
// The thread's drawer, open on a terminal that has printed some output, drawn
// in World::brick (TerminalMenuSteps.cpp).
QQuickItem* drawnTerminal(World& world);
// The platform the drawn terminal behaves as: "macOS", "Linux" or "Windows".
void setTerminalPlatform(World& world, const QString& platform);
// The last of these calls the MC got.
std::optional<QJsonObject> lastTerminalCall(World& world, const QString& method, const QString& threadId, const QString& terminalId);
// The MC's project "p1" at /work/p1, connected, unless a Background set one up.
void ensureProject(World& world);

}  // namespace terminalfake
