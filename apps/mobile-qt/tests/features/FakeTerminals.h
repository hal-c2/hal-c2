#pragma once
// The MC's terminal manager as the phone's scenarios need it, after the
// desktop's (tests/native/features/FakeTerminals.h, whose steps take its World).

#include <QJsonObject>
#include <QList>
#include <functional>
#include <QMap>
#include <QString>
#include <QStringList>

class FakeMc;
class World;

namespace terminalfake {

struct FakeTerminals {
  struct Terminal {
    QJsonObject summary;
    QString history;
    qint64 sequence = 0;
  };
  // By "threadId/terminalId".
  QMap<QString, Terminal> terminals;
  // Every terminal.* call, as {method, payload}.
  QList<QJsonObject> calls;
  // While set, a terminal.close waits in `heldCloses` until a step runs it.
  bool holdCloses = false;
  QList<std::function<void()>> heldCloses;
};

// A terminal the MC already has, in `status`.
void addTerminal(World& world, const QString& terminalId, const QString& status = QStringLiteral("running"), bool busy = false);
void print(World& world, const QString& terminalId, const QString& data);
// Its shell ends: still listed, as exited.
void endShell(World& world, const QString& terminalId);
// The data of the terminal's terminal.write calls, in order.
QStringList writes(World& world, const QString& terminalId);

}  // namespace terminalfake
