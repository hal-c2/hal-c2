// The phone's terminal screen (features/mobile/terminal.feature and the @mobile
// scenarios of features/terminal/), with the real engine, against the MC's
// terminal manager as FakeTerminals fakes it. A soft keyboard has no offscreen
// form: its steps assert what the screen asked of it and where the focus is.

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <QtMath>

#include "FakeTerminals.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "TerminalController.h"
#include "World.h"

namespace terminalfake {

namespace {

QString keyOf(const QJsonObject& input) {
  return input.value(QLatin1String("threadId")).toString() + QLatin1Char('/') + input.value(QLatin1String("terminalId")).toString();
}

void toTerminal(FakeMc& mc, const QString& key, const QJsonObject& event) {
  for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
    if (keyOf(mc.shapeOf(id).value(QLatin1String("input")).toObject()) != key) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
  }
}

void toList(FakeMc& mc, const QJsonObject& event) {
  const QList<int> ids = mc.subscribers(QStringLiteral("terminals"));
  if (ids.isEmpty()) return;
  mc.send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), ids.last()}, {QStringLiteral("event"), event}});
}

QJsonObject summaryOf(const QString& threadId, const QString& terminalId, const QString& cwd) {
  return {{QStringLiteral("threadId"), threadId},
          {QStringLiteral("terminalId"), terminalId},
          {QStringLiteral("cwd"), cwd},
          {QStringLiteral("worktreePath"), QJsonValue::Null},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("pid"), 100},
          {QStringLiteral("exitCode"), QJsonValue::Null},
          {QStringLiteral("exitSignal"), QJsonValue::Null},
          {QStringLiteral("hasRunningSubprocess"), false},
          {QStringLiteral("label"), terminalId},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
}

void sendSnapshot(FakeMc& mc, int id, const QString& key) {
  const FakeTerminals::Terminal& terminal = mc.part<FakeTerminals>().terminals[key];
  QJsonObject snapshot = terminal.summary;
  snapshot.insert(QStringLiteral("history"), terminal.history);
  snapshot.insert(QStringLiteral("sequence"), terminal.sequence);
  mc.send({{QStringLiteral("t"), QStringLiteral("terminal")},
           {QStringLiteral("id"), id},
           {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), snapshot}}}});
}

// terminal.open and an attach that says where: a shell that has ended, or never
// started, starts; one that runs is left alone.
void ensureRunning(FakeMc& mc, const QJsonObject& input) {
  FakeTerminals& fake = mc.part<FakeTerminals>();
  const QString key = keyOf(input);
  if (!fake.terminals.contains(key)) {
    const QJsonObject summary = summaryOf(input.value(QLatin1String("threadId")).toString(), input.value(QLatin1String("terminalId")).toString(),
                                          input.value(QLatin1String("cwd")).toString());
    fake.terminals.insert(key, {summary, QString()});
    toList(mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
    return;
  }
  FakeTerminals::Terminal& terminal = fake.terminals[key];
  const QString status = terminal.summary.value(QLatin1String("status")).toString();
  if (status != QLatin1String("exited") && status != QLatin1String("error")) return;
  terminal.summary.insert(QStringLiteral("status"), QStringLiteral("running"));
  terminal.history.clear();
  toList(mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), terminal.summary}});
  for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
    if (keyOf(mc.shapeOf(id).value(QLatin1String("input")).toObject()) == key) sendSnapshot(mc, id, key);
  }
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(QStringLiteral("terminals"), [&mc](int id, const QJsonObject& shape) {
    if (shape.value(QLatin1String("environment")) != mc.environmentId) {
      mc.forget(id);
      return;
    }
    QJsonArray list;
    for (const FakeTerminals::Terminal& terminal : std::as_const(mc.part<FakeTerminals>().terminals)) list.append(terminal.summary);
    toList(mc, {{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}});
  });
  mc.onShape(QStringLiteral("terminal"), [&mc](int id, const QJsonObject& shape) {
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    FakeTerminals& fake = mc.part<FakeTerminals>();
    if (!fake.terminals.contains(keyOf(input))) {
      if (!input.contains(QLatin1String("cwd"))) {
        mc.forget(id);
        mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Unknown terminal")}});
        return;
      }
      ensureRunning(mc, input);
    }
    sendSnapshot(mc, id, keyOf(input));
  });
  mc.onFrame(QStringLiteral("ack"), [](const QJsonObject&) {});
  mc.onRpc(QStringLiteral("terminal."), [&mc](const FakeMc::Rpc& rpc) {
    FakeTerminals& fake = mc.part<FakeTerminals>();
    fake.calls.append({{QStringLiteral("method"), rpc.method}, {QStringLiteral("payload"), rpc.payload}});
    const QString key = keyOf(rpc.payload);
    if (rpc.method == QLatin1String("terminal.open")) {
      ensureRunning(mc, rpc.payload);
    } else if (rpc.method == QLatin1String("terminal.clear")) {
      fake.terminals[key].history.clear();
      toTerminal(mc, key, {{QStringLiteral("type"), QStringLiteral("cleared")}});
    } else if (rpc.method == QLatin1String("terminal.close")) {
      auto close = [&mc, rpc, key] {
        mc.part<FakeTerminals>().terminals.remove(key);
        toTerminal(mc, key, {{QStringLiteral("type"), QStringLiteral("closed")}});
        toList(mc, {{QStringLiteral("type"), QStringLiteral("remove")},
                    {QStringLiteral("threadId"), rpc.payload.value(QLatin1String("threadId"))},
                    {QStringLiteral("terminalId"), rpc.payload.value(QLatin1String("terminalId"))}});
        mc.reply(rpc, QJsonValue::Null);
      };
      if (fake.holdCloses) {
        fake.heldCloses.append(close);
      } else {
        close();
      }
      return;
    }
    mc.reply(rpc, QJsonValue::Null);
  });
});

}  // namespace

void addTerminal(World& world, const QString& terminalId, const QString& status, bool busy) {
  QJsonObject summary = summaryOf(world.thread, terminalId, QStringLiteral("/work/shop"));
  summary.insert(QStringLiteral("status"), status);
  summary.insert(QStringLiteral("hasRunningSubprocess"), busy);
  world.mc.part<FakeTerminals>().terminals.insert(world.thread + QLatin1Char('/') + terminalId, {summary, QString()});
  toList(world.mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
}

void print(World& world, const QString& terminalId, const QString& data) {
  const QString key = world.thread + QLatin1Char('/') + terminalId;
  FakeTerminals::Terminal& terminal = world.mc.part<FakeTerminals>().terminals[key];
  terminal.history += data;
  ++terminal.sequence;
  toTerminal(world.mc, key, {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), data}, {QStringLiteral("sequence"), terminal.sequence}});
}

void endShell(World& world, const QString& terminalId) {
  const QString key = world.thread + QLatin1Char('/') + terminalId;
  FakeTerminals::Terminal& terminal = world.mc.part<FakeTerminals>().terminals[key];
  terminal.summary.insert(QStringLiteral("status"), QStringLiteral("exited"));
  toTerminal(world.mc, key, {{QStringLiteral("type"), QStringLiteral("exited")}, {QStringLiteral("exitCode"), 0}});
  toList(world.mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), terminal.summary}});
}

QStringList writes(World& world, const QString& terminalId) {
  QStringList data;
  for (const QJsonObject& call : std::as_const(world.mc.part<FakeTerminals>().calls)) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == QLatin1String("terminal.write") && payload.value(QLatin1String("terminalId")) == terminalId) {
      data.append(payload.value(QLatin1String("data")).toString());
    }
  }
  return data;
}

}  // namespace terminalfake

namespace {

using namespace terminalfake;
using S = QString;

// What a scenario remembers between steps.
struct Seen {
  QSize size;
  qreal scroll = 0;
  QString typedAt;
  qsizetype writes = 0;
  qsizetype calls = 0;
  QString clipboard;
  bool tooManyLines = false;
};

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

QString describeCalls(World& world) {
  QStringList lines;
  for (const QJsonObject& call : std::as_const(world.mc.part<FakeTerminals>().calls)) {
    lines.append(QString::fromUtf8(QJsonDocument(call).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

// The scenarios of features/terminal/ have no Background.
void ensureThread(World& world) {
  if (!world.thread.isEmpty() && world.isOpen() && (terminals(world)->isOpen() || !shownThread(world).isEmpty())) return;
  pairWithEnvironment(world);
  world.thread = haveThread(world, S("Fix checkout"));
  openThread(world, S("Fix checkout"));
}

QQuickItem* terminalItem(World& world) {
  const QString active = terminals(world)->activeTerminalId();
  QQuickItem* cell = world.find(S("terminalCell-") + active);
  QQuickItem* found = world.findWhere([&](QQuickItem* item) {
    return item->objectName() == QLatin1String("HalC2Terminal") && item->isVisible() && (!cell || cell->isAncestorOf(item));
  });
  return found;
}

bool showing(World& world, const QString& terminalId) {
  QQuickItem* screen = world.find(S("terminalScreen"));
  return screen && screen->isVisible() && terminals(world)->isOpen() && terminals(world)->activeTerminalId() == terminalId && terminalItem(world) != nullptr;
}

QString describeScreen(World& world) {
  return S("the active terminal is %1 (%2), and the screen says: %3")
      .arg(terminals(world)->activeTerminalId(), terminals(world)->isOpen() ? S("open") : S("shut"), screenTexts(world));
}

void waitShown(World& world, const QString& terminalId) {
  world.waitFor([&] { return showing(world, terminalId); }, [&] { return S("%1 on the screen; %2").arg(terminalId, describeScreen(world)); });
}

// The screen of the terminal opening picks, drawn and ready.
void openTerminal(World& world) {
  ensureThread(world);
  world.tap(S("threadTerminal"));
  world.waitFor([&] { QQuickItem* screen = world.find(S("terminalScreen")); return screen && screen->isVisible() && terminalItem(world); },
                [&] { return S("the terminal's screen; %1").arg(describeScreen(world)); });
}

void ensureShown(World& world) {
  ensureThread(world);
  if (!terminals(world)->isOpen()) openTerminal(world);
  world.waitFor([&] { return terminalItem(world) != nullptr; }, [&] { return S("a terminal; %1").arg(describeScreen(world)); });
  world.sync();
}

QString activeId(World& world) {
  return terminals(world)->activeTerminalId();
}

QString terminalText(World& world) {
  QQuickItem* terminal = terminalItem(world);
  if (!terminal) return {};
  QString text;
  QMetaObject::invokeMethod(terminal, "text", Q_RETURN_ARG(QString, text));
  return text;
}

QString selectedText(World& world) {
  QString text;
  QMetaObject::invokeMethod(terminalItem(world), "selectedText", Q_RETURN_ARG(QString, text));
  return text;
}

bool hasSelection(World& world) {
  QQuickItem* terminal = terminalItem(world);
  return terminal && terminal->property("hasSelection").toBool();
}

void waitForOutput(World& world, const QString& text) {
  world.waitFor([&] { return terminalText(world).contains(text); }, [&] { return S("%1 on the terminal, which shows: %2").arg(text, terminalText(world)); });
}

// Enough output to fill the terminal, and more with `extra` rows.
void fill(World& world, int extra = 0) {
  ensureShown(world);
  const int rows = terminalItem(world)->property("rows").toInt();
  QString output;
  // A word as wide as the rest of the row, so the middle of the terminal is on one.
  const int columns = terminalItem(world)->property("columns").toInt();
  for (int row = 0; row < rows + extra; ++row) {
    const QString line = S("row %1 3 tests failed ").arg(row + 1);
    output += line + S("x").repeated(std::max<int>(1, columns - 1 - line.size())) + S("\r\n");
  }
  print(world, activeId(world), output);
  waitForOutput(world, S("row %1").arg(rows + extra));
}

// A key of the row, scrolled to as a thumb would.
void pressRowKey(World& world, const QString& name) {
  QQuickItem* key = nullptr;
  world.waitFor([&] { return (key = world.find(S("terminalKey:") + name)) != nullptr; }, [&] { return S("the key %1 on the row; the screen says: %2").arg(name, screenTexts(world)); });
  QQuickItem* row = world.find(S("terminalKeyRow"));
  const qreal most = std::max<qreal>(0, row->property("contentWidth").toReal() - row->width());
  row->setProperty("contentX", std::clamp(key->x() - (row->width() - key->width()) / 2, qreal(0), most));
  world.sync();
  world.tap(key);
}

QString joinedWrites(World& world) {
  return writes(world, activeId(world)).join(QString());
}

void waitWritten(World& world, const QString& data) {
  world.waitFor([&] { return joinedWrites(world).endsWith(data); }, [&] {
    QQuickItem* focused = world.window().activeFocusItem();
    return S("the terminal to receive %1; it got %2, the MC has %3, and the focus is on %4")
        .arg(data.toUtf8().toHex(), joinedWrites(world).toUtf8().toHex(), describeCalls(world), focused ? focused->objectName() + S(" ") + focused->metaObject()->className() : S("nothing"));
  });
}

QString heldModifier(World& world) {
  return at(world.state(S("mobileTerminal")), S("held")).toString();
}

void openMenu(World& world) {
  ensureThread(world);
  if (terminals(world)->isOpen()) {
    world.tap(S("terminalMenu"));
  } else {
    QQuickItem* entry = world.find(S("threadTerminal"));
    world.hold(entry, [&] { return world.state(S("menu")).isValid() && !world.state(S("menu")).isNull() && !at(world.state(S("menu")), S("items")).toList().isEmpty(); },
               S("the terminal menu"));
  }
  world.waitFor([&] { return world.find(S("mobileMenuItem:new")) != nullptr; }, [&] { return S("the terminal menu; the screen says: %1").arg(screenTexts(world)); });
}

// The ids of the menu's rows, in order, without their groups'.
QStringList menuRows(World& world) {
  QStringList rows;
  for (const QVariant& item : at(world.state(S("menu")), S("items")).toList()) {
    const QVariantList children = item.toMap().value(S("children")).toList();
    if (children.isEmpty()) rows.append(item.toMap().value(S("id")).toString());
    for (const QVariant& child : children) rows.append(child.toMap().value(S("id")).toString());
  }
  return rows;
}

QVariantMap menuRow(World& world, const QString& id) {
  for (const QVariant& item : at(world.state(S("menu")), S("items")).toList()) {
    if (item.toMap().value(S("id")) == id) return item.toMap();
    for (const QVariant& child : item.toMap().value(S("children")).toList()) {
      if (child.toMap().value(S("id")) == id) return child.toMap();
    }
  }
  fail(S("the menu has no %1, only %2").arg(id, menuRows(world).join(S(", "))));
}

void choose(World& world, const QString& id) {
  world.tap(S("mobileMenuItem:") + id);
  world.awaitPopup(S("mobileMenu"), false);
  world.sync();
}

void addScript(World& world, const QString& name, bool setup = false) {
  QJsonObject row = world.mc.projects.value(S("shop"));
  QJsonArray scripts = row.value(QLatin1String("scripts")).toArray();
  scripts.append(QJsonObject{{S("id"), name}, {S("name"), name}, {S("command"), S("bun run ") + name}, {S("icon"), S("play")}, {S("runOnWorktreeCreate"), setup}});
  row.insert(S("scripts"), scripts);
  world.mc.projects.insert(S("shop"), row);
  QJsonArray rows;
  rows.append(QJsonArray{S("shop"), S("project"), row});
  world.mc.sendRows(world.mc.name, rows);
  world.sync();
}

// Terminals of the thread, as the phone has heard of them.
void known(World& world, const QStringList& ids) {
  world.waitFor([&] {
    const QVariantList listed = terminals(world)->listing();
    for (const QString& id : ids) {
      if (std::none_of(listed.begin(), listed.end(), [&](const QVariant& row) { return row.toMap().value(S("terminalId")) == id; })) return false;
    }
    return true;
  }, [&] { return S("the phone to hear of %1; it lists %2").arg(ids.join(S(", ")), show(terminals(world)->listing())); });
}

void have(World& world, const QStringList& ids) {
  ensureThread(world);
  for (const QString& id : ids) addTerminal(world, id);
  known(world, ids);
}

void openOn(World& world, const QString& id) {
  if (!terminals(world)->isOpen()) openTerminal(world);
  if (activeId(world) != id) {
    openMenu(world);
    choose(world, S("terminal:") + id);
  }
  waitShown(world, id);
}

// The window's focus takes this as the keyboard's.
void pressChord(World& world, Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
  QTest::keyClick(&world.window(), key, modifiers);
}

void useClipboard(const QString& text) {
  QGuiApplication::clipboard()->setText(text);
}

QList<QJsonObject> callsNamed(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const QJsonObject& call : std::as_const(world.mc.part<FakeTerminals>().calls)) {
    if (call.value(QLatin1String("method")) == method) found.append(call.value(QLatin1String("payload")).toObject());
  }
  return found;
}

void addVisibleLines(World& world) {
  ensureShown(world);
  openMenu(world);
  choose(world, S("context"));
}

QVariantMap contextState(World& world) {
  return at(world.state(S("mobileTerminal")), S("context")).toMap();
}

QVariantList draftContexts(World& world) {
  return at(world.state(S("composer")), S("terminalContexts")).toList();
}

void waitDraftRange(World& world, int start, int end) {
  world.waitFor([&] {
    const QVariantList contexts = draftContexts(world);
    return !contexts.isEmpty() && contexts.last().toMap().value(S("lineStart")).toInt() == start && contexts.last().toMap().value(S("lineEnd")).toInt() == end;
  }, [&] { return S("lines %1 to %2 in the draft, which has %3").arg(start).arg(end).arg(show(draftContexts(world))); });
}

void printLines(World& world, int count) {
  ensureShown(world);
  QString output;
  for (int line = 1; line <= count; ++line) output += S("output line %1\r\n").arg(line);
  print(world, activeId(world), output);
  waitForOutput(world, S("output line %1").arg(count));
}

// A word of the output, under a finger held down until it is selected.
void selectWord(World& world) {
  QQuickItem* fingers = world.find(S("terminalFingers"));
  world.hold(fingers, [&] { return hasSelection(world); }, S("a word to be selected"));
  world.sync();
}

void waitShows(World& world, const QString& text) {
  world.waitFor([&] { return world.shows(text); }, [&] { return S("%1 on the sheet, which says: %2").arg(text, screenTexts(world)); });
}

void toastSays(World& world, const QString& text) {
  world.waitFor([&] { return show(world.state(S("toasts"))).contains(text); }, [&] { return S("%1 in the toasts: %2").arg(text, show(world.state(S("toasts")))); });
}

// The connection drops and comes back on its own, with what the descriptor says now.
void reconnect(World& world) {
  McClient* client = world.native().client();
  client->setRetryDelays({20, 20});
  const qsizetype before = world.mc.connections.size();
  world.mc.drop();
  world.waitFor([&] { return world.mc.connections.size() > before && client->phase() == McClient::Phase::Ready; }, S("the phone to connect again"));
  world.sync();
}

const QHash<QString, QString> kEncoded{
    {S("Escape"), S("\x1b")},        {S("Tab"), S("\t")},          {S("back-tab"), S("\x1b[Z")},     {S("the Up arrow"), S("\x1b[A")},
    {S("the Left arrow"), S("\x1b[D")}, {S("a tilde"), S("~")},    {S("a pipe"), S("|")},            {S("Control-C"), S("\x03")},
    {S("a Control-C"), S("\x03")},   {S("Control-Z"), S("\x1a")},  {S("the delete key"), S("\x7f")}, {S("Return"), S("\r")},
    {S("the Up arrow with Control"), S("\x1b[1;5A")}, {S("the Left arrow with Meta"), S("\x1b[1;3D")}, {S("the Up arrow with Meta"), S("\x1b[1;3A")},
};

const Steps steps([] {
  // Opening.

  step(S("the user opens the terminal"), [](World& world, const Captures&, const Table&) {
    openTerminal(world);
  });

  step(S("the user sees that the terminal is opening"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("terminalScreen")) != nullptr; }, [&] { return S("the terminal's screen; it says: %1").arg(screenTexts(world)); });
  });

  step(S("the thread's terminal session is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !callsNamed(world, S("terminal.write")).isEmpty() || world.mc.part<FakeTerminals>().terminals.contains(world.thread + S("/term-1")); },
                  [&] { return S("the thread's terminal to start; the MC got %1").arg(describeCalls(world)); });
    waitShown(world, S("term-1"));
  });

  step(S("the thread's shell %1 is running and %1 is not").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ensureThread(world);
    addTerminal(world, c[1], S("exited"));
    addTerminal(world, c[0]);
    known(world, {c[0], c[1]});
  });

  step(S("the user opens the terminal without choosing one"), [](World& world, const Captures&, const Table&) {
    openTerminal(world);
  });

  step(S("the thread has %1 and %1 running").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1]});
  });

  step(S("the thread works in its own worktree"), [](World& world, const Captures&, const Table&) {
    QJsonObject row = world.mc.threads.value(world.thread);
    row.insert(S("worktreePath"), S("/work/worktrees/checkout"));
    world.mc.threads.insert(world.thread, row);
    world.mc.sendRow(world.thread, row);
    world.waitFor([&] { return at(world.state(S("workspace")), S("worktreePath")) == QLatin1String("/work/worktrees/checkout"); }, S("the thread's worktree"));
  });

  step(S("the user opens a terminal that has not been started"), [](World& world, const Captures&, const Table&) {
    openTerminal(world);
  });

  step(S("its shell starts in the thread's worktree"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.part<FakeTerminals>().terminals.contains(world.thread + S("/term-1")); }, S("the shell to start"));
    const QString cwd = world.mc.part<FakeTerminals>().terminals.value(world.thread + S("/term-1")).summary.value(QLatin1String("cwd")).toString();
    expect(cwd == QLatin1String("/work/worktrees/checkout"), S("it started in %1").arg(cwd));
  });

  step(S("the user has opened %1 on the phone before").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openTerminal(world);
    waitShown(world, c[0]);
    QQuickItem* terminal = terminalItem(world);
    world.waitFor([&] { return !callsNamed(world, S("terminal.resize")).isEmpty(); }, [&] { return S("the shell to hear the size: %1").arg(describeCalls(world)); });
    world.mc.part<Seen>().size = QSize(terminal->property("columns").toInt(), terminal->property("rows").toInt());
    world.back();
    world.waitFor([&] { return !terminals(world)->isOpen(); }, S("the terminal to be left"));
    world.mc.part<Seen>().calls = world.mc.part<FakeTerminals>().calls.size();
  });

  step(S("the user opens %1 again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openTerminal(world);
    waitShown(world, c[0]);
    world.sync();
  });

  step(S("it opens at the size it last had"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalItem(world);
    const QSize now(terminal->property("columns").toInt(), terminal->property("rows").toInt());
    expect(now == world.mc.part<Seen>().size, S("it is %1x%2").arg(now.width()).arg(now.height()));
  });

  step(S("it does not briefly show another size"), [](World& world, const Captures&, const Table&) {
    const QSize size = world.mc.part<Seen>().size;
    const QList<QJsonObject> calls = world.mc.part<FakeTerminals>().calls;
    for (qsizetype index = world.mc.part<Seen>().calls; index < calls.size(); ++index) {
      if (calls.at(index).value(QLatin1String("method")) != QLatin1String("terminal.resize")) continue;
      const QJsonObject payload = calls.at(index).value(QLatin1String("payload")).toObject();
      expect(payload.value(QLatin1String("cols")).toInt() == size.width() && payload.value(QLatin1String("rows")).toInt() == size.height(),
             S("the shell was told %1").arg(show(payload.toVariantMap())));
    }
  });

  step(S("the environment %1 is not connected").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    McClient* client = world.native().client();
    client->setRetryDelays({20, 3600000});
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&] { return client->phase() == McClient::Phase::Retrying && client->retryDelay() == 3600000; }, S("the phone to give up for now"));
  });

  step(S("the user is told the terminal will load when the environment is ready"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* notice = world.find(S("terminalWaiting")); return notice && notice->isVisible(); },
                  [&] { return S("the notice; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the user is offered to reconnect it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* button = world.find(S("terminalReconnect"));
    expect(button && button->isVisible(), S("no way to reconnect; the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the terminal session is (running a task|waiting for input|starting|finished|failed to start|not started yet)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("not started yet")) return;
    const QString status = c[0] == QLatin1String("starting")          ? S("starting")
                           : c[0] == QLatin1String("finished")        ? S("exited")
                           : c[0] == QLatin1String("failed to start") ? S("error")
                                                                      : S("running");
    addTerminal(world, S("term-1"), status, c[0] == QLatin1String("running a task"));
    known(world, {S("term-1")});
  });

  step(S("the terminal is labelled %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      QQuickItem* entry = world.find(S("threadTerminal"));
      return entry && entry->property("label").toString().endsWith(c[0]);
    }, [&] { return S("the label %1; the terminal's state is %2").arg(c[0], show(world.state(S("mobileTerminal")))); });
  });

  step(S("the thread has no workspace folder"), [](World& world, const Captures&, const Table&) {
    QJsonObject row = world.mc.projects.value(S("shop"));
    row.insert(S("workspaceRoot"), QString());
    world.mc.projects.insert(S("shop"), row);
    QJsonArray rows;
    rows.append(QJsonArray{S("shop"), S("project"), row});
    world.mc.sendRows(world.mc.name, rows);
    world.sync();
  });

  step(S("the thread offers no terminal"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* entry = world.find(S("threadTerminal")); return !entry || !entry->isVisible(); }, [&] { return S("no terminal to open; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("a thread with a running terminal on a paired environment"), [](World& world, const Captures&, const Table&) {
    have(world, {S("term-1")});
    print(world, S("term-1"), S("recent output\r\n"));
  });

  step(S("the user opens the thread's terminal on the phone"), [](World& world, const Captures&, const Table&) {
    openTerminal(world);
  });

  step(S("the phone shows the same terminal and its recent output"), [](World& world, const Captures&, const Table&) {
    waitShown(world, S("term-1"));
    waitForOutput(world, S("recent output"));
  });

  // Several terminals.

  step(S("the terminal %1 is open").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0]});
    openOn(world, c[0]);
  });

  step(S("the user opens a new terminal"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    choose(world, S("new"));
  });

  step(S("both terminals are listed"), [](World& world, const Captures&, const Table&) {
    waitShown(world, S("term-2"));
    openMenu(world);
    const QStringList rows = menuRows(world);
    expect(rows.contains(S("terminal:term-1")) && rows.contains(S("terminal:term-2")), S("the menu has %1").arg(rows.join(S(", "))));
  });

  step(S("%1 and %1 are open").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1]});
    openOn(world, c[1]);
  });

  step(S("the user switches to %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openMenu(world);
    choose(world, S("terminal:") + c[0]);
  });

  step(S("%1 and %1 are open and the user is in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1]});
    openOn(world, c[2]);
  });

  step(S("the shell in %1 exits").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    endShell(world, c[0]);
    world.sync();
  });

  step(S("only %1 is open").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0]});
    openOn(world, c[0]);
  });

  step(S("the thread is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen() && world.find(S("terminalScreen")) == nullptr; }, [&] { return S("the thread; %1").arg(describeScreen(world)); });
    QQuickItem* composer = world.find(S("threadTerminal"));
    expect(composer && composer->isVisible(), S("the thread's screen is not up: %1").arg(screenTexts(world)));
  });

  step(S("the user has the thread's files open"), [](World& world, const Captures&, const Table&) {
    ensureThread(world);
    world.tap(S("openFiles"));
    world.item(S("filesPanel"));
  });

  step(S("the user steps back from the terminal"), [](World& world, const Captures&, const Table&) {
    world.back();
    world.sync();
  });

  step(S("the thread's files are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen() && world.find(S("terminalScreen")) == nullptr; }, [&] { return S("the files; %1").arg(describeScreen(world)); });
    world.item(S("filesPanel"));
  });

  step(S("the user is in %1 and has opened another screen over it").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0]});
    openOn(world, c[0]);
    world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QString()));
    world.waitFor([&] { return world.find(S("terminalScreen")) == nullptr; }, S("the other screen to cover the terminal"));
  });

  step(S("%1 starts again before the user returns").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addTerminal(world, c[0]);
    world.sync();
  });

  step(S("the user returns to the terminal"), [](World& world, const Captures&, const Table&) {
    world.back();
    world.sync();
  });

  step(S("the terminal is left for the previous live session or the thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen(); }, [&] { return S("the terminal to be left; %1").arg(describeScreen(world)); });
  });

  step(S("the ended shell is not shown"), [](World& world, const Captures&, const Table&) {
    expect(world.find(S("terminalScreen")) == nullptr, S("the terminal's screen is up: %1").arg(screenTexts(world)));
  });

  step(S("%1, %1 and %1 are running and the user is in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1], c[2]});
    openOn(world, c[3]);
  });

  step(S("%1 and %1 are running and the user is in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1]});
    openOn(world, c[2]);
  });

  step(S("%1 ended while no terminal screen of the phone had it open").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addTerminal(world, c[0], S("exited"));
    known(world, {c[0]});
  });

  step(S("%1 starts a new shell").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& open : callsNamed(world, S("terminal.open"))) {
        if (open.value(QLatin1String("terminalId")) == c[0]) return showing(world, c[0]);
      }
      return false;
    }, [&] { return S("%1 to start; the MC got %2; %3").arg(c[0], describeCalls(world), describeScreen(world)); });
  });

  step(S("a thread with two terminals"), [](World& world, const Captures&, const Table&) {
    have(world, {S("term-1"), S("term-2")});
    print(world, S("term-1"), S("the first's output\r\n"));
    print(world, S("term-2"), S("the second's output\r\n"));
    world.sync();
  });

  step(S("the user picks the second terminal on the phone"), [](World& world, const Captures&, const Table&) {
    openTerminal(world);
    openMenu(world);
    choose(world, S("terminal:term-2"));
  });

  step(S("the phone shows the second terminal's output"), [](World& world, const Captures&, const Table&) {
    waitShown(world, S("term-2"));
    waitForOutput(world, S("the second's output"));
  });

  // Typing and the row of keys.

  step(S("the phone shows a thread's terminal"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    waitShown(world, activeId(world));
  });

  step(S("the user types %1 and sends it").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.type(c[0]);
    pressChord(world, Qt::Key_Return);
  });

  step(S("the shell runs %1 and the phone shows its output").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitWritten(world, c[0] + S("\r"));
    print(world, activeId(world), S("On branch main\r\n"));
    waitForOutput(world, S("On branch main"));
  });

  step(S("the user is typing in the terminal"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    useClipboard(S("from the clipboard"));
  });

  step(S("the user presses %1 on the accessory row").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ensureShown(world);
    world.mc.part<Seen>().writes = writes(world, activeId(world)).size();
    pressRowKey(world, c[0]);
  });

  step(S("the terminal receives (Escape|Tab|back-tab|the Up arrow( with Control| with Meta)?|the Left arrow( with Meta)?|a tilde|a pipe|Control-C|a Control-C|Control-Z|the delete key|Return)"), [](World& world, const Captures& c, const Table&) {
    waitWritten(world, kEncoded.value(c[0]));
  });

  step(S("the terminal receives %1 with Meta").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitWritten(world, QChar(0x1b) + c[0]);
  });

  step(S("the terminal receives a Control chord"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return heldModifier(world) == QLatin1String("ctrl"); }, S("ctrl to wait for a key"));
    world.type(S("c"));
    waitWritten(world, S("\x03"));
  });

  step(S("the terminal receives an Alt chord"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return heldModifier(world) == QLatin1String("alt"); }, S("alt to wait for a key"));
    world.type(S("x"));
    waitWritten(world, S("\x1bx"));
  });

  step(S("the terminal receives the clipboard contents"), [](World& world, const Captures&, const Table&) {
    waitWritten(world, S("from the clipboard"));
  });

  step(S("the terminal is shown and the keyboard is hidden"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    pressRowKey(world, S("hide"));
    world.waitFor([&] { QQuickItem* show = world.find(S("terminalShowKeyboard")); return show && show->isVisible(); }, S("the keyboard to go"));
  });

  step(S("the user touches the terminal"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalFingers"));
  });

  // Offscreen there is no keyboard to rise: the screen wants it and the terminal has the focus.
  step(S("the keyboard is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* row = world.find(S("terminalKeyRow")); return row && row->isVisible() && terminalItem(world)->hasActiveFocus(); },
                  S("the screen to want the keyboard, with the focus in the terminal"));
  });

  step(S("the keyboard and the accessory row are showing"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    QQuickItem* row = world.find(S("terminalKeyRow"));
    expect(row && row->isVisible(), S("no row of keys; the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user hides the keyboard"), [](World& world, const Captures&, const Table&) {
    pressRowKey(world, S("hide"));
  });

  step(S("the accessory row is hidden too"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("terminalKeyRow")) == nullptr; }, S("the row to go"));
  });

  step(S("the terminal offers a way to show the keyboard again"), [](World& world, const Captures&, const Table&) {
    expect(world.find(S("terminalShowKeyboard")) != nullptr, S("no way back to the keyboard"));
  });

  step(S("the user shows the keyboard"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalShowKeyboard"));
  });

  step(S("the keyboard and the accessory row are back"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("terminalKeyRow")) && terminalItem(world)->hasActiveFocus(); }, S("the row and the focus to come back"));
  });

  // Modifiers.

  step(S("the thread's environment runs on (macOS|Linux|Windows)"), [](World& world, const Captures& c, const Table&) {
    const QString os = c[0] == QLatin1String("macOS") ? S("darwin") : c[0].toLower();
    world.mc.platform = QJsonObject{{S("os"), os}};
    world.mc.announceEnvironment();
    world.sync();
  });

  step(S("the user opens the accessory row"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
  });

  step(S("it offers the modifier keys (\\w+) and (\\w+)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QStringList modifiers = at(world.state(S("mobileTerminal")), S("modifiers")).toStringList();
      return modifiers == QStringList{c[0], c[1]} && world.find(S("terminalKey:") + c[0]) && world.find(S("terminalKey:") + c[1]);
    }, [&] { return S("%1 and %2; the terminal's state is %3").arg(c[0], c[1], show(world.state(S("mobileTerminal")))); });
  });

  step(S("the user has pressed %1 on the accessory row").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ensureShown(world);
    pressRowKey(world, c[0]);
    world.waitFor([&] { return heldModifier(world) == c[0]; }, [&] { return S("%1 to wait for a key; %2").arg(c[0], show(world.state(S("mobileTerminal")))); });
    useClipboard(S("from the clipboard"));
  });

  step(S("%1 is no longer waiting for a key").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return heldModifier(world) != c[0]; }, [&] { return S("%1 to let go; %2").arg(c[0], show(world.state(S("mobileTerminal")))); });
  });

  step(S("the user presses %1 again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    pressRowKey(world, c[0]);
  });

  step(S("typing %1 sends a plain %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.type(c[0]);
    waitWritten(world, c[1]);
  });

  step(S("the user clears the terminal"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    pressRowKey(world, S("clear"));
  });

  step(S("the terminal shows earlier output"), [](World& world, const Captures&, const Table&) {
    printLines(world, 3);
  });

  step(S("the terminal screen is empty"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalText(world).trimmed().isEmpty(); }, [&] { return S("nothing on the terminal, which shows: %1").arg(terminalText(world)); });
  });

  step(S("the phone's clipboard is pasted into the terminal"), [](World& world, const Captures&, const Table&) {
    waitWritten(world, S("from the clipboard"));
  });

  // Paste.

  step(S("the phone's clipboard holds two lines of text"), [](World& world, const Captures&, const Table&) {
    useClipboard(S("first\nsecond"));
  });

  step(S("the terminal receives the two lines separated by Enter"), [](World& world, const Captures&, const Table&) {
    waitWritten(world, S("first\rsecond"));
  });

  step(S("the paste is not wrapped in any markers"), [](World& world, const Captures&, const Table&) {
    expect(joinedWrites(world) == S("first\rsecond"), S("the terminal got %1").arg(show(joinedWrites(world))));
  });

  step(S("the phone's clipboard holds text with tabs and with a hidden control character"), [](World& world, const Captures&, const Table&) {
    useClipboard(S("a\tb\x01" "c"));
  });

  step(S("the terminal receives the tabs as they were"), [](World& world, const Captures&, const Table&) {
    waitWritten(world, S("a\tb c"));
  });

  step(S("each hidden control character reaches the terminal as a space"), [](World& world, const Captures&, const Table&) {
    expect(!joinedWrites(world).contains(QChar(1)), S("the control character reached it: %1").arg(show(joinedWrites(world))));
  });

  step(S("the phone's clipboard holds more than 65,000 characters"), [](World& world, const Captures&, const Table&) {
    // An emoji every few characters, so a cut falls on one sooner or later.
    QString text;
    while (text.size() < 66000) text += QString::fromUtf8("abc\xF0\x9F\x98\x80");
    world.mc.part<Seen>().clipboard = text;
    useClipboard(text);
  });

  step(S("the terminal receives all of it in several writes"), [](World& world, const Captures&, const Table&) {
    const QString& text = world.mc.part<Seen>().clipboard;
    world.waitFor([&] { return joinedWrites(world) == text; }, [&] { return S("all of the paste; %1 of %2 characters came").arg(joinedWrites(world).size()).arg(text.size()); });
    expect(writes(world, activeId(world)).size() > 1, S("it came in one write"));
  });

  step(S("no emoji or other character is cut in two"), [](World& world, const Captures&, const Table&) {
    for (const QString& write : writes(world, activeId(world))) {
      expect(!write.at(write.size() - 1).isHighSurrogate() && !write.at(0).isLowSurrogate(), S("a write cuts an emoji"));
    }
  });

  step(S("the phone's clipboard holds a long text"), [](World& world, const Captures&, const Table&) {
    const QString text = S("x").repeated(40000) + S("!");
    world.mc.part<Seen>().clipboard = text;
    useClipboard(text);
  });

  step(S("the user presses %1 twice in a row").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ensureShown(world);
    pressRowKey(world, c[0]);
    pressRowKey(world, c[0]);
  });

  step(S("the terminal receives the first paste in full before the second begins"), [](World& world, const Captures&, const Table&) {
    const QString& text = world.mc.part<Seen>().clipboard;
    world.waitFor([&] { return joinedWrites(world) == text + text; }, [&] { return S("both pastes in order; %1 characters came").arg(joinedWrites(world).size()); });
  });

  step(S("the phone cannot read its clipboard"), [](World& world, const Captures&, const Table&) {
    // QClipboard answers an unreadable clipboard with no text.
    useClipboard(QString());
    ensureShown(world);
  });

  step(S("nothing is typed into the terminal"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(writes(world, activeId(world)).isEmpty(), S("the terminal got %1").arg(show(joinedWrites(world))));
  });

  step(S("the terminal stays usable"), [](World& world, const Captures&, const Table&) {
    world.type(S("x"));
    waitWritten(world, S("x"));
  });

  step(S("the terminal's shell has ended"), [](World& world, const Captures&, const Table&) {
    have(world, {S("term-1"), S("term-2")});
    openOn(world, S("term-1"));
    world.mc.part<Seen>().typedAt = S("term-1");
    endShell(world, S("term-1"));
    world.waitFor([&] { return activeId(world) == QLatin1String("term-2"); }, [&] { return S("the screen to move on; %1").arg(describeScreen(world)); });
  });

  // What a key on the row sends is what the terminal's input is: a key still
  // in flight when the shell ended must not reach a session.
  step(S("the user presses a key on the accessory row"), [](World& world, const Captures&, const Table&) {
    endShell(world, S("term-2"));
    world.waitFor([&] { return !terminals(world)->isOpen(); }, S("the screen to shut"));
    world.bridge().dispatch(S("mobileTerminal.input"), QVariantMap{{S("data"), S("x")}});
    world.sync();
  });

  step(S("nothing is sent to the terminal"), [](World& world, const Captures&, const Table&) {
    expect(callsNamed(world, S("terminal.write")).isEmpty(), S("the MC got %1").arg(describeCalls(world)));
  });

  // A finger.

  step(S("the terminal has more output than fits on screen"), [](World& world, const Captures&, const Table&) {
    fill(world, 200);
    pressRowKey(world, S("hide"));
    world.sync();
  });

  step(S("the user drags a finger down the terminal"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalItem(world);
    const qreal before = terminal->property("scrollOffset").toReal();
    world.mc.part<Seen>().scroll = before;
    const int cell = qCeil(terminal->property("cellHeight").toReal());
    // Touch moves wait for the next frame: wait for them with the finger still down.
    // A pixel more than five rows: the Terminal adds up rows as fractions, and exactly
    // five may come to just under it until the next move.
    world.swipe(world.find(S("terminalFingers")), QPoint(0, cell * 5 + 1), [&] {
      world.window().update();
      QTest::qWaitFor([&] { return before - terminal->property("scrollOffset").toReal() >= 5; }, 500);
      world.mc.part<Seen>().scroll = before - terminal->property("scrollOffset").toReal();
    });
  });

  step(S("older output is shown"), [](World& world, const Captures&, const Table&) {
    expect(!terminalItem(world)->property("atBottom").toBool(), S("the terminal is still at its newest output"));
  });

  step(S("the terminal scrolls one row for each row's height the finger moved"), [](World& world, const Captures&, const Table&) {
    expect(qRound(world.mc.part<Seen>().scroll) == 5, S("five rows' height scrolled %1 rows").arg(world.mc.part<Seen>().scroll));
  });

  step(S("the user flicks the terminal"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalItem(world);
    const int cell = qCeil(terminal->property("cellHeight").toReal());
    world.swipe(world.find(S("terminalFingers")), QPoint(0, cell * 4));
    world.mc.part<Seen>().scroll = terminal->property("scrollOffset").toReal();
  });

  step(S("the terminal keeps scrolling for a moment"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalItem(world);
    const qreal lifted = world.mc.part<Seen>().scroll;
    world.waitFor([&] { return terminal->property("scrollOffset").toReal() != lifted; }, S("the output to carry on after the finger lifted"));
    expect(world.find(S("terminalFingers"))->property("flicking").toBool(), S("the flick ended at once"));
  });

  step(S("the user touches the terminal while it is scrolling"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalFingers"));
  });

  step(S("it stops"), [](World& world, const Captures&, const Table&) {
    expect(!world.find(S("terminalFingers"))->property("flicking").toBool(), S("the output still scrolls"));
  });

  step(S("the terminal is shown"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
  });

  step(S("the phone is turned or the keyboard opens"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !callsNamed(world, S("terminal.resize")).isEmpty(); }, S("the shell to hear the first size"));
    QQuickItem* terminal = terminalItem(world);
    world.mc.part<Seen>().size = QSize(terminal->property("columns").toInt(), terminal->property("rows").toInt());
    world.mc.part<Seen>().calls = callsNamed(world, S("terminal.resize")).size();
    const QPointer<QQuickItem> before = terminal;
    world.resize(world.window().height(), world.window().width());
    world.sync();
    expect(before == terminalItem(world), S("turning the phone built the terminal anew"));
  });

  step(S("the shell is told how many columns and rows now fit"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      QQuickItem* terminal = terminalItem(world);
      const QList<QJsonObject> resizes = callsNamed(world, S("terminal.resize"));
      return terminal && resizes.size() > world.mc.part<Seen>().calls && resizes.last().value(QLatin1String("cols")).toInt() == terminal->property("columns").toInt() &&
             resizes.last().value(QLatin1String("rows")).toInt() == terminal->property("rows").toInt();
    }, [&] { return S("the shell to hear the new size: %1; %2").arg(describeCalls(world), describeScreen(world)); });
  });

  step(S("the shell is not told again while the size is unchanged"), [](World& world, const Captures&, const Table&) {
    const qsizetype told = callsNamed(world, S("terminal.resize")).size();
    world.resize(world.window().width(), world.window().height());
    world.sync();
    expect(callsNamed(world, S("terminal.resize")).size() == told, S("the shell was told again: %1").arg(describeCalls(world)));
  });

  // The menu.

  step(S("the user opens the terminal menu( of the thread)?"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
  });

  step(S("%1 has the script %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addScript(world, c[1]);
  });

  step(S("%1 has the scripts %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addScript(world, c[1]);
    addScript(world, c[2]);
  });

  step(S("%1 has no saved scripts").arg(kQuoted), [](World&, const Captures&, const Table&) {});

  step(S("%1 has the script %1 that runs when a worktree is created").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addScript(world, c[1], true);
  });

  step(S("the thread has a terminal that is running and one that has ended"), [](World& world, const Captures&, const Table&) {
    addTerminal(world, S("term-1"));
    addTerminal(world, S("term-2"), S("exited"));
    known(world, {S("term-1"), S("term-2")});
  });

  step(S("%1 and %1 are listed with the commands they run").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : {c[0], c[1]}) {
      const QVariantMap row = menuRow(world, S("script:") + name);
      expect(row.value(S("subtitle")) == QString(S("bun run ") + name), S("%1 is listed as %2").arg(name, show(row)));
      waitShows(world, S("bun run ") + name);
    }
  });

  step(S("the running terminal is listed with its state and the folder it is in"), [](World& world, const Captures&, const Table&) {
    const QVariantMap row = menuRow(world, S("terminal:term-1"));
    expect(row.value(S("subtitle")) == S("Ready · shop"), S("it is listed as %1").arg(show(row)));
  });

  step(S("the user is( still)? offered to open a new terminal"), [](World& world, const Captures&, const Table&) {
    expect(menuRows(world).contains(S("new")), S("the menu has %1").arg(menuRows(world).join(S(", "))));
  });

  step(S("the menu says the project has no saved scripts yet"), [](World& world, const Captures&, const Table&) {
    waitShows(world, S("This project has no saved scripts yet"));
  });

  step(S("no script can be chosen"), [](World& world, const Captures&, const Table&) {
    for (const QString& id : menuRows(world)) expect(!id.startsWith(QLatin1String("script:")), S("the menu offers %1").arg(id));
    expect(!menuRow(world, S("no-scripts")).value(S("enabled")).toBool(), S("the notice can be chosen"));
  });

  step(S("the thread has %1 running and %1 ended").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addTerminal(world, c[0]);
    addTerminal(world, c[1], S("exited"));
    known(world, {c[0], c[1]});
  });

  step(S("the user is in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openOn(world, c[0]);
  });

  step(S("only %1 is listed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QStringList listed = menuRows(world).filter(QRegularExpression(S("^terminal:")));
    expect(listed == QStringList{S("terminal:") + c[0]}, S("the menu lists %1").arg(listed.join(S(", "))));
  });

  step(S("the user is in %1 and its shell has ended").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0]});
    openOn(world, c[0]);
    endShell(world, c[0]);
    world.waitFor([&] { return !terminals(world)->isOpen(); }, [&] { return S("the thread again; %1").arg(describeScreen(world)); });
  });

  step(S("%1 is listed with its state").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariantMap row = menuRow(world, S("terminal:") + c[0]);
    expect(row.value(S("subtitle")).toString().startsWith(S("Exited · ")), S("it is listed as %1").arg(show(row)));
  });

  step(S("the thread has %1, %1 and %1 running").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0], c[1], c[2]});
  });

  step(S("they are listed as %1, %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QStringList listed = menuRows(world).filter(QRegularExpression(S("^terminal:")));
    expect(listed == QStringList{S("terminal:") + c[0], S("terminal:") + c[1], S("terminal:") + c[2]}, S("the menu lists %1").arg(listed.join(S(", "))));
  });

  step(S("the thread works in the folder %1").arg(kQuoted), [](World&, const Captures&, const Table&) {});

  step(S("the offer to open a new terminal says it starts in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString said = S("Start another shell in ") + c[0];
    expect(menuRow(world, S("new")).value(S("subtitle")) == said, S("the menu says: %1").arg(show(menuRow(world, S("new")))));
    waitShows(world, said);
  });

  step(S("the script is listed as %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitShows(world, c[0]);
  });

  step(S("the user runs %1 from the terminal( menu)?").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QJsonArray scripts = world.mc.projects.value(S("shop")).value(QLatin1String("scripts")).toArray();
    if (std::none_of(scripts.begin(), scripts.end(), [&](const QJsonValue& script) { return script.toObject().value(QLatin1String("id")) == c[0]; })) addScript(world, c[0]);
    openMenu(world);
    choose(world, S("script:") + c[0]);
  });

  step(S("%1 runs in a terminal session").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !callsNamed(world, S("terminal.write")).isEmpty(); }, [&] { return S("%1 to be typed: %2").arg(c[0], describeCalls(world)); });
    waitWritten(world, S("bun run ") + c[0] + S("\r"));
  });

  step(S("%1 runs in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return writes(world, c[1]).join(QString()).contains(S("bun run ") + c[0]); }, [&] { return S("%1 in %2: %3").arg(c[0], c[1], describeCalls(world)); });
  });

  step(S("the thread has no shell running"), [](World&, const Captures&, const Table&) {});

  step(S("the MC is slow to close a terminal"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeTerminals>().holdCloses = true;
  });

  step(S("the user closes the terminal from the terminal menu"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    choose(world, S("close"));
    world.awaitPopup(S("confirmDialog"));
    world.tap(S("confirmAccept"));
    world.waitFor([&] { return !callsNamed(world, S("terminal.close")).isEmpty(); }, [&] { return S("terminal.close: %1").arg(describeCalls(world)); });
  });

  step(S("the MC closes %1").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    FakeTerminals& fake = world.mc.part<FakeTerminals>();
    fake.holdCloses = false;
    for (const auto& close : std::exchange(fake.heldCloses, {})) close();
    world.sync();
  });

  step(S("%1 is still open").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // Output sent after the MC's `remove` and answer: once it shows, both came.
    print(world, c[0], S("still here"));
    waitForOutput(world, S("still here"));
    expect(terminals(world)->tabs()->indexOf(c[0]) >= 0, S("%1 is gone; the user is in %2").arg(c[0], activeId(world)));
    expect(activeId(world) == c[0], S("the user is in %1").arg(activeId(world)));
  });

  step(S("the thread has %1 running").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    have(world, {c[0]});
  });

  step(S("%1 is left as it was").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(writes(world, c[0]).isEmpty(), S("%1 got %2").arg(c[0], writes(world, c[0]).join(S(", "))));
  });

  step(S("%1 is starting in a new terminal").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    addScript(world, c[0]);
    openMenu(world);
    choose(world, S("script:") + c[0]);
  });

  step(S("the terminal attaches and its output arrives"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !activeId(world).isEmpty() && terminalItem(world); }, [&] { return S("the terminal; %1").arg(describeScreen(world)); });
    print(world, activeId(world), S("$ "));
    waitForOutput(world, S("$"));
  });

  step(S("the command is typed into the shell once"), [](World& world, const Captures&, const Table&) {
    waitWritten(world, S("bun run test\r"));
    expect(joinedWrites(world) == QLatin1String("bun run test\r"), S("the shell got %1").arg(show(joinedWrites(world))));
  });

  step(S("it is not typed again when the terminal is shown again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(S("terminal.toggle"));
    world.waitFor([&] { return !terminals(world)->isOpen(); }, S("the terminal to be left"));
    world.tap(S("threadTerminal"));
    world.waitFor([&] { return terminalItem(world) != nullptr; }, S("the terminal back"));
    world.sync();
    expect(joinedWrites(world) == QLatin1String("bun run test\r"), S("the shell got %1").arg(show(joinedWrites(world))));
  });

  // Text size.

  step(S("the terminal text size is ([\\d.]+) points"), [](World& world, const Captures& c, const Table&) {
    ensureShown(world);
    const double points = c[0].toDouble();
    if (!world.state(S("mobileTerminal")).toMap().contains(S("asked"))) {
      const double now = at(world.state(S("mobileTerminal")), S("textSize")).toDouble();
      if (world.mc.part<Seen>().writes == 0 && now != points && !world.mc.part<Seen>().typedAt.startsWith(S("size"))) {
        world.bridge().dispatch(S("mobileTerminal.textSize"), QVariantMap{{S("points"), points}});
        world.mc.part<Seen>().typedAt = S("size");
        world.sync();
        return;
      }
    }
    world.mc.part<Seen>().typedAt = S("size");
    world.waitFor([&] { return qFuzzyCompare(at(world.state(S("mobileTerminal")), S("textSize")).toDouble(), points); },
                  [&] { return S("%1 points; the terminal's state is %2").arg(c[0], show(world.state(S("mobileTerminal")))); });
  });

  step(S("the user (increases|decreases) the text size"), [](World& world, const Captures& c, const Table&) {
    openMenu(world);
    const QString id = c[0] == QLatin1String("increases") ? S("larger") : S("smaller");
    if (menuRow(world, id).value(S("enabled")).toBool()) {
      choose(world, id);
    } else {
      world.bridge().dispatch(S("menu.select"), QVariantMap{{S("requestId"), at(world.state(S("menu")), S("requestId"))}, {S("id"), QVariant()}});
      world.awaitPopup(S("mobileMenu"), false);
      world.sync();
    }
  });

  // Lines for the draft.

  step(S("the terminal shows a failing test"), [](World& world, const Captures&, const Table&) {
    printLines(world, 3);
  });

  step(S("the terminal shows six lines"), [](World& world, const Captures&, const Table&) {
    printLines(world, 6);
  });

  step(S("the terminal shows nothing"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
  });

  // No terminal has rows enough on a phone to fill an item: what such a screen would hand over.
  step(S("the user adds the visible lines as context"), [](World& world, const Captures&, const Table&) {
    if (world.mc.part<Seen>().tooManyLines) {
      world.bridge().dispatch(S("mobileTerminal.context.open"), QVariantMap{{S("lines"), QStringList(70, S("x").repeated(1000))}});
      return;
    }
    addVisibleLines(world);
  });

  step(S("the user attaches the selected output"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalContextAttach"));
  });

  step(S("the draft carries those lines"), [](World& world, const Captures&, const Table&) {
    waitDraftRange(world, 1, 3);
  });

  step(S("the draft already carries the most context items it can"), [](World& world, const Captures&, const Table&) {
    printLines(world, 2);
    for (int item = 0; item < 200; ++item) {
      world.bridge().dispatch(S("composer.terminalContext.add"),
                              QVariantMap{{S("terminalId"), S("term-1")}, {S("terminalLabel"), S("term-1")}, {S("lineStart"), item + 1}, {S("lineEnd"), item + 1}, {S("text"), S("line %1").arg(item)}});
    }
    world.waitFor([&] { return draftContexts(world).size() >= 200; }, [&] { return S("the draft to fill; it has %1").arg(draftContexts(world).size()); });
  });

  step(S("the user is told there are too many context items"), [](World& world, const Captures&, const Table&) {
    toastSays(world, S("Too many context items"));
  });

  step(S("the user is told there is no visible output to attach"), [](World& world, const Captures&, const Table&) {
    toastSays(world, S("There is no visible output to attach."));
  });

  step(S("no list of lines is shown"), [](World& world, const Captures&, const Table&) {
    expect(contextState(world).isEmpty() && !world.find(S("terminalContextLine:0")), S("a list of lines is up: %1").arg(screenTexts(world)));
  });

  step(S("the user taps the second line and then the fourth"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("terminalContextLine:3")) != nullptr; }, [&] { return S("the lines; the screen says: %1").arg(screenTexts(world)); });
    world.tap(S("terminalContextLine:1"));
    world.waitFor([&] { return contextState(world).value(S("end")).toInt() == 1; }, S("the second line alone"));
    world.tap(S("terminalContextLine:3"));
    world.waitFor([&] { return contextState(world).value(S("end")).toInt() == 3; }, S("lines two to four"));
  });

  step(S("the draft carries lines 2 to 4"), [](World& world, const Captures&, const Table&) {
    waitDraftRange(world, 2, 4);
  });

  step(S("the excerpt names the terminal and those lines"), [](World& world, const Captures&, const Table&) {
    const QVariantMap excerpt = draftContexts(world).last().toMap();
    expect(excerpt.value(S("label")).toString().startsWith(activeId(world).isEmpty() ? S("term-1") : activeId(world)), S("the excerpt says %1").arg(show(excerpt)));
  });

  step(S("all six lines are selected"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("terminalContextLine:5")) != nullptr; }, [&] { return S("six lines; the screen says: %1").arg(screenTexts(world)); });
    expect(contextState(world).value(S("start")).toInt() == 0 && contextState(world).value(S("end")).toInt() == 5, S("the selection is %1").arg(show(contextState(world))));
  });

  step(S("the terminal shows more lines than a context item can carry"), [](World& world, const Captures&, const Table&) {
    ensureShown(world);
    world.mc.part<Seen>().tooManyLines = true;
  });

  step(S("the user is told to select fewer lines"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Select fewer lines to fit the context limit.")); }, [&] { return S("the notice; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the selection cannot be attached"), [](World& world, const Captures&, const Table&) {
    expect(!world.find(S("terminalContextAttach"))->isEnabled(), S("it can be attached"));
  });

  step(S("the user is choosing which visible lines to add"), [](World& world, const Captures&, const Table&) {
    printLines(world, 3);
    addVisibleLines(world);
    world.waitFor([&] { return world.find(S("terminalContextCancel")) != nullptr; }, S("the list of lines"));
  });

  step(S("the user cancels"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalContextCancel"));
    world.sync();
  });

  step(S("the draft carries no terminal lines"), [](World& world, const Captures&, const Table&) {
    expect(draftContexts(world).isEmpty(), S("the draft has %1").arg(show(draftContexts(world))));
  });

  step(S("the terminal is still shown"), [](World& world, const Captures&, const Table&) {
    expect(terminals(world)->isOpen() && terminalItem(world), S("the terminal went; %1").arg(describeScreen(world)));
  });

  step(S("the user selects output and adds it to the message"), [](World& world, const Captures&, const Table&) {
    printLines(world, 3);
    addVisibleLines(world);
    world.waitFor([&] { return world.find(S("terminalContextAttach")) != nullptr; }, S("the list of lines"));
    world.tap(S("terminalContextAttach"));
  });

  step(S("the draft gains an excerpt naming the terminal and lines"), [](World& world, const Captures&, const Table&) {
    waitDraftRange(world, 1, 3);
  });

  // Selecting.

  step(S("the terminal shows output with %1").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    fill(world);
  });

  step(S("the user long presses a word in the output"), [](World& world, const Captures&, const Table&) {
    selectWord(world);
  });

  step(S("the user copies the selection"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Seen>().clipboard = selectedText(world);
    world.tap(S("terminalCopy"));
  });

  step(S("the selected text is on the clipboard"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.clipboard.isEmpty(); }, S("the clipboard"));
    expect(world.clipboard == world.mc.part<Seen>().clipboard, S("the clipboard has %1, and %2 was selected").arg(world.clipboard, world.mc.part<Seen>().clipboard));
    expect(!world.clipboard.contains(QLatin1Char(' ')) && terminalText(world).contains(world.clipboard), S("%1 is not a word of the output").arg(world.clipboard));
  });

  step(S("the user has selected (a word|text) in the terminal"), [](World& world, const Captures&, const Table&) {
    fill(world);
    selectWord(world);
    world.mc.part<Seen>().clipboard = selectedText(world);
  });

  step(S("the user drags a selection handle across the output"), [](World& world, const Captures&, const Table&) {
    world.swipe(world.find(S("terminalSelectionHandle")), QPoint(0, 60));
    world.sync();
  });

  step(S("the selection covers whole words from its start to the handle"), [](World& world, const Captures&, const Table&) {
    const QString before = world.mc.part<Seen>().clipboard;
    const QString now = selectedText(world);
    expect(now.size() > before.size() && now.contains(before), S("the selection went from %1 to %2").arg(before, now));
    expect(!now.at(now.size() - 1).isSpace(), S("the selection ends in a space: %1").arg(show(now)));
  });

  step(S("the user chooses \"Select All\""), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalSelectAll"));
    world.sync();
  });

  step(S("the whole terminal screen is selected"), [](World& world, const Captures&, const Table&) {
    const QString selected = selectedText(world);
    expect(selected.contains(S("row 2 ")) && selected.contains(S("row %1").arg(terminalItem(world)->property("rows").toInt())), S("selected: %1").arg(selected));
  });

  step(S("the user closes the selection menu"), [](World& world, const Captures&, const Table&) {
    world.tap(S("terminalSelectionClose"));
  });

  step(S("nothing is selected in the terminal"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !hasSelection(world); }, [&] { return S("no selection; %1 is selected").arg(selectedText(world)); });
  });

  step(S("the terminal receives new output"), [](World& world, const Captures&, const Table&) {
    print(world, activeId(world), S("new output\r\n"));
    waitForOutput(world, S("new output"));
  });

  // A hardware keyboard, in the layout a tablet has room for.

  step(S("the user presses %1 in the terminal").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ensureThread(world);
    if (!terminals(world)->isOpen()) world.bridge().dispatch(S("terminal.toggle"));
    world.waitFor([&] { return terminalItem(world) != nullptr; }, [&] { return S("the terminal; %1").arg(describeScreen(world)); });
    QQuickItem* terminal = terminalItem(world);
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus() && !activeId(world).isEmpty(); }, S("the terminal to take the keyboard"));
    world.sync();
    static const QHash<QString, QPair<Qt::Key, Qt::KeyboardModifiers>> keys{
        {S("Escape"), {Qt::Key_Escape, Qt::NoModifier}},   {S("Up"), {Qt::Key_Up, Qt::NoModifier}},     {S("Left"), {Qt::Key_Left, Qt::NoModifier}},
        {S("Tab"), {Qt::Key_Tab, Qt::NoModifier}},         {S("Shift-Tab"), {Qt::Key_Backtab, Qt::ShiftModifier}},
        {S("Ctrl-C"), {Qt::Key_C, Qt::ControlModifier}},   {S("Ctrl-Z"), {Qt::Key_Z, Qt::ControlModifier}},
        {S("Backspace"), {Qt::Key_Backspace, Qt::NoModifier}}, {S("Enter"), {Qt::Key_Return, Qt::NoModifier}},
    };
    const auto key = keys.value(c[0]);
    pressChord(world, key.first, key.second);
  });

  // Reconnecting.

  step(S("the phone shows a running terminal"), [](World& world, const Captures&, const Table&) {
    have(world, {S("term-1")});
    openOn(world, S("term-1"));
    print(world, S("term-1"), S("before the drop\r\n"));
    waitForOutput(world, S("before the drop"));
  });

  step(S("the phone loses its connection and reconnects"), [](World& world, const Captures&, const Table&) {
    reconnect(world);
  });

  step(S("the terminal shows its history and continues streaming"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return showing(world, S("term-1")) && !world.mc.subscribers(S("terminal")).isEmpty(); }, [&] { return S("the terminal attached again; %1").arg(describeScreen(world)); });
    world.sync();
    waitForOutput(world, S("before the drop"));
    print(world, S("term-1"), S("after the drop\r\n"));
    waitForOutput(world, S("after the drop"));
  });
});

}  // namespace
