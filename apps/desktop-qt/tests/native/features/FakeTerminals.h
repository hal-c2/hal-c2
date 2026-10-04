#pragma once
// What the other terminal steps files need from TerminalSteps.cpp: the MC's
// terminal manager and the thread the drawer is on.

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>

#include <optional>

#include "TerminalController.h"

class FakeMc;
class World;

namespace terminalfake {

// The MC's terminal manager: terminals attach with the `terminal` shape and
// are listed by `terminals`; `terminal.*` calls are recorded and act on them
// the way the MC's does.
struct FakeTerminals {
  struct Terminal {
    QJsonObject summary;
    QString history;
  };
  // By "threadId/terminalId".
  QMap<QString, Terminal> terminals;
  // Every terminal.* call, as {method, payload}.
  QList<QJsonObject> calls;
  // Why terminal.open fails, when it does.
  QString refuseOpen;
  // Why terminal.close fails, when it does.
  QString refuseClose;
  // What the shell prints back when it is written exactly this.
  QHash<QString, QString> replies;
  // The terminal the steps' right panel tab runs.
  QString panelTerminal;
};

// To the `terminal` subscriptions of "threadId/terminalId".
void sendTerminal(FakeMc& mc, const QString& key, const QJsonObject& event);
// A terminal the MC already runs, as another client left it.
void addTerminal(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& label, bool busy);
void print(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& data);
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
// The MC's project "p1" at /work/p1, connected, unless a Background set one up.
void ensureProject(World& world);

}  // namespace terminalfake
