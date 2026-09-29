// A thread's timeline: the node's `stream` shape for the open thread (faked
// here as entity rows the steps change), and what the ThreadStore's
// TimelineModel shows of it.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QPersistentModelIndex>
#include <QSignalSpy>

#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Stream.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using namespace stream;

void sendSnapshot(FakeNode& node, int id, const QString& thread) {
  QJsonArray rows;
  const QMap<QString, QJsonObject> entities = node.part<FakeStreams>().threads.value(thread);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const QStringList key = it.key().split(QLatin1Char('\n'));
    rows.append(QJsonArray{key.at(0), key.at(1), *it});
  }
  const int offset = node.part<FakeStreams>().seq;
  node.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), offset},
             {QStringLiteral("at"), iso(now())}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
             {QStringLiteral("done"), true}});
  node.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), offset}});
}

const FakeNode::Extension streams([](FakeNode& node) {
  node.onShape(QStringLiteral("stream"), [&node](int id, const QJsonObject& shape) {
    FakeStreams& fake = node.part<FakeStreams>();
    const QString target = shape.value(QLatin1String("environment")).toString();
    if (fake.offline.contains(target)) {
      node.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unknown environment")}});
      node.forget(id);
      return;
    }
    sendSnapshot(node, id, shape.value(QLatin1String("stream")).toString());
  });
});

// Rows of a kind, newest last.
QList<int> rowsOf(TimelineModel& model, const QString& kind) {
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) rows.append(row);
  }
  return rows;
}

int lastRowOf(World& world, const QString& kind) {
  TimelineModel& model = timeline(world);
  const QList<int> rows = rowsOf(model, kind);
  if (rows.isEmpty()) fail(QStringLiteral("no %1 row; %2").arg(kind, describe(model)));
  return rows.last();
}

// The row showing this item.
int rowShowing(World& world, const QString& itemId) {
  TimelineModel& model = timeline(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::IdRole).toString() == itemId) return row;
    for (const QVariant& entry : role(model, row, TimelineModel::EntriesRole).toList()) {
      if (entry.toMap().value(QStringLiteral("id")).toString() == itemId) return row;
    }
  }
  fail(QStringLiteral("no row shows %1; %2").arg(itemId, describe(model)));
}

QVariantMap lastEntry(World& world) {
  const QVariantList entries = role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::EntriesRole).toList();
  if (entries.isEmpty()) fail(QStringLiteral("the work row shows no calls; %1").arg(describe(timeline(world))));
  return entries.last().toMap();
}

void expectAnswer(World& world, const QString& text) {
  TimelineModel& model = timeline(world);
  for (const int row : rowsOf(model, QStringLiteral("message"))) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return;
  }
  fail(QStringLiteral("\"%1\" is not shown; %2").arg(text, describe(model)));
}

void keepRows(World& world) {
  TimelineModel& model = timeline(world);
  FakeStreams& fake = world.node.part<FakeStreams>();
  fake.kept.clear();
  for (int row = 0; row < model.rowCount(); ++row) fake.kept.append(QPersistentModelIndex(model.index(row)));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Background.
  step(QStringLiteral("a connected environment with the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
  });
  const auto lookAt = [](World& world, const Captures& c, const Table&) { lookAtThread(world, c[0]); };
  step(QStringLiteral("the user is looking at a thread in %1").arg(q), lookAt);
  step(QStringLiteral("the user is looking at a long thread in %1").arg(q), lookAt);

  // Streaming.
  step(QStringLiteral("the agent is reasoning before it answers"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("reasoning"), {{QStringLiteral("streaming"), true}, {QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("text"), QStringLiteral("The cart total needs")}});
  });
  step(QStringLiteral("the reasoning is streaming"), [](World& world, const Captures&, const Table&) {
    // Streamed text redraws its row; the row list stays as it is.
    TimelineModel& model = timeline(world);
    QSignalSpy redrawn(&model, &TimelineModel::dataChanged);
    QSignalSpy inserted(&model, &TimelineModel::rowsInserted);
    QSignalSpy removed(&model, &TimelineModel::rowsRemoved);
    QSignalSpy reset(&model, &TimelineModel::modelReset);
    change(world, QStringLiteral("turn-item"), lastEntry(world).value(QStringLiteral("id")).toString(), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral(" a tax line")}}}});
    expect(redrawn.size() == 1 && inserted.isEmpty() && removed.isEmpty() && reset.isEmpty(),
           QStringLiteral("streamed text redrew %1 rows, inserted %2, removed %3, reset %4")
               .arg(redrawn.size()).arg(inserted.size()).arg(removed.size()).arg(reset.size()));
  });
  step(QStringLiteral("the reasoning is finished"), [](World& world, const Captures&, const Table&) {
    set(world, QStringLiteral("turn-item"), lastEntry(world).value(QStringLiteral("id")).toString(),
        {{QStringLiteral("streaming"), false}, {QStringLiteral("status"), QStringLiteral("completed")}});
  });
  step(QStringLiteral("the reasoning is labelled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastEntry(world).value(QStringLiteral("label")).toString();
    expect(label == c[0], QStringLiteral("the reasoning is labelled \"%1\"").arg(label));
  });

  step(QStringLiteral("the agent has been working for (\\d+) seconds"), [](World& world, const Captures& c, const Table&) {
    startRun(world, c[0].toInt());
  });
  step(QStringLiteral("the thread says the agent is working"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    expect(model.working(), QStringLiteral("the thread is not working; %1").arg(describe(model)));
    expect(model.workingLabel() == QLatin1String("Working for 12s"), QStringLiteral("the thread says \"%1\"").arg(model.workingLabel()));
  });
  step(QStringLiteral("the elapsed time keeps counting"), [](World& world, const Captures&, const Table&) {
    world.setTime(QStringLiteral("2026-09-23T10:00:05Z"));
    const QString label = timeline(world).workingLabel();
    expect(label == QLatin1String("Working for 17s"), QStringLiteral("five seconds later the thread says \"%1\"").arg(label));
  });

  const auto fourCallsAndAnswer = [](World& world) {
    startRun(world);
    for (int n = 1; n <= 4; ++n) addCommand(world, n);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart now shows tax.")}});
  };
  step(QStringLiteral("the agent ran four tool calls and then answered"), [fourCallsAndAnswer](World& world, const Captures&, const Table&) {
    fourCallsAndAnswer(world);
  });
  step(QStringLiteral("the turn completes after 2 minutes"), [](World& world, const Captures&, const Table&) {
    settleRun(world, QStringLiteral("completed"), 120);
  });
  const auto expectFolded = [](World& world, const QString& label) {
    TimelineModel& model = timeline(world);
    const int fold = lastRowOf(world, QStringLiteral("fold"));
    const QString title = role(model, fold, TimelineModel::TitleRole).toString();
    expect(title == label, QStringLiteral("the work folds behind \"%1\"").arg(title));
    expect(!role(model, fold, TimelineModel::ExpandedRole).toBool() && rowsOf(model, QStringLiteral("work")).isEmpty(),
           QStringLiteral("the work is not folded away; %1").arg(describe(model)));
  };
  step(QStringLiteral("the tool calls fold behind %1").arg(q), [expectFolded](World& world, const Captures& c, const Table&) {
    expectFolded(world, c[0]);
  });
  step(QStringLiteral("the answer stays visible"), [](World& world, const Captures&, const Table&) {
    expectAnswer(world, QStringLiteral("The cart now shows tax."));
  });
  step(QStringLiteral("a finished turn is folded behind %1").arg(q), [fourCallsAndAnswer, expectFolded](World& world, const Captures& c, const Table&) {
    fourCallsAndAnswer(world);
    settleRun(world, QStringLiteral("completed"), 120);
    expectFolded(world, c[0]);
  });
  const auto toggleFold = [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    model.toggle(role(model, lastRowOf(world, QStringLiteral("fold")), TimelineModel::IdRole).toString());
  };
  step(QStringLiteral("the user opens the folded work"), toggleFold);
  step(QStringLiteral("the user closes it again"), toggleFold);
  step(QStringLiteral("its tool calls are shown"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int work = lastRowOf(world, QStringLiteral("work"));
    const int calls = role(model, work, TimelineModel::EntriesRole).toList().size() + role(model, work, TimelineModel::HiddenCountRole).toInt();
    expect(calls == 4, QStringLiteral("the open fold shows %1 calls; %2").arg(calls).arg(describe(model)));
  });
  step(QStringLiteral("the tool calls fold away"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    expect(rowsOf(model, QStringLiteral("work")).isEmpty(), QStringLiteral("the calls are still shown; %1").arg(describe(model)));
  });

  step(QStringLiteral("the user interrupted a turn after (\\d+) seconds"), [](World& world, const Captures& c, const Table&) {
    startRun(world, c[0].toInt());
    addCommand(world, 1, QStringLiteral("interrupted"));
  });
  step(QStringLiteral("the user interrupted a turn before it did any work"), [](World& world, const Captures&, const Table&) {
    startRun(world, -1, QStringLiteral("starting"));
    addItem(world, QStringLiteral("run_interrupt_result"), {{QStringLiteral("message"), QStringLiteral("Interrupted by the user")}});
  });
  step(QStringLiteral("the turn settles"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.node.part<FakeStreams>();
    settleRun(world, QStringLiteral("interrupted"), fake.runStarted.isValid() ? int(fake.runStarted.secsTo(now())) : 0);
  });
  step(QStringLiteral("its work folds behind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = role(timeline(world), lastRowOf(world, QStringLiteral("fold")), TimelineModel::TitleRole).toString();
    expect(title == c[0], QStringLiteral("the work folds behind \"%1\"").arg(title));
  });

  // Catching up.
  step(QStringLiteral("the agent is writing a reply"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("id"), QStringLiteral("reply")}, {QStringLiteral("streaming"), true}, {QStringLiteral("text"), QStringLiteral("The cart")}});
    keepRows(world);
  });
  step(QStringLiteral("the agent finishes the reply while the shell is disconnected"), [](World& world, const Captures&, const Table&) {
    change(world, QStringLiteral("turn-item"), QStringLiteral("reply"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral(" now shows tax.")}}}, {QStringLiteral("s"), QJsonObject{{QStringLiteral("streaming"), false}}}});
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the agent writes more than the shell has read"), [](World& world, const Captures&, const Table&) {
    change(world, QStringLiteral("turn-item"), QStringLiteral("reply"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral(" now shows tax.")}}}}, true);
  });
  step(QStringLiteral("the node tells the shell to resync the thread"), [](World& world, const Captures&, const Table&) {
    const FakeStreams& fake = world.node.part<FakeStreams>();
    const qsizetype before = world.node.subscriptions.size();
    for (const int id : followers(world, fake.thread)) {
      world.node.send({{QStringLiteral("t"), QStringLiteral("resync")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0}});
    }
    world.waitFor([&] { return world.node.subscriptions.size() > before; }, QStringLiteral("the shell to subscribe again"));
    world.sync();
  });
  step(QStringLiteral("the whole reply is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<int> messages = rowsOf(timeline(world), QStringLiteral("message"));
      return !messages.isEmpty() && role(timeline(world), messages.last(), TimelineModel::TextRole).toString() == QLatin1String("The cart now shows tax.");
    }, [&] { return QStringLiteral("the whole reply; %1").arg(describe(timeline(world))); });
  });
  step(QStringLiteral("the rows shown before are kept"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QList<QPersistentModelIndex> kept = world.node.part<FakeStreams>().kept;
    expect(!kept.isEmpty(), QStringLiteral("no rows were shown before"));
    // Rows only go when the turn settles and folds its calls away; the reply's row stays.
    for (const QPersistentModelIndex& index : kept) {
      expect(index.isValid() || !rowsOf(model, QStringLiteral("fold")).isEmpty(), QStringLiteral("a row was dropped; %1").arg(describe(model)));
    }
    expect(model.indexOf(QStringLiteral("reply")) >= 0 && kept.last().isValid() &&
               kept.last().data(TimelineModel::IdRole).toString() == QLatin1String("reply"),
           QStringLiteral("the reply's row was replaced; %1").arg(describe(model)));
  });

  // A thread on another node.
  step(QStringLiteral("the user is looking at a thread on another node of the cluster"), [](World& world, const Captures&, const Table&) {
    world.node.join(kPeer, kPeerEnvironment);
    world.node.send({{QStringLiteral("t"), QStringLiteral("shell.node")}, {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
                     {QStringLiteral("node"), kPeer}, {QStringLiteral("online"), true}});
    world.node.send({{QStringLiteral("t"), QStringLiteral("shell.rows")}, {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
                     {QStringLiteral("node"), kPeer},
                     {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{kPeerThread, QStringLiteral("thread"),
                                                                    QJsonObject{{QStringLiteral("id"), kPeerThread}, {QStringLiteral("title"), QStringLiteral("Remote")}, {QStringLiteral("projectId"), kProject},
                                                                                {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}}})}}});
    world.sync();
    FakeStreams& fake = world.node.part<FakeStreams>();
    fake.thread = kPeerThread;
    fake.environment = kPeerEnvironment;
    look(world, kPeerEnvironment + QLatin1Char(':') + kPeerThread);
  });
  step(QStringLiteral("the agent has answered %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), c[0]}});
    settleRun(world, QStringLiteral("completed"), 30);
  });
  const auto setPeer = [](World& world, bool online) {
    FakeStreams& fake = world.node.part<FakeStreams>();
    if (online) {
      fake.offline.remove(fake.environment);
    } else {
      fake.offline.insert(fake.environment);
      for (const int id : followers(world, fake.thread)) {
        world.node.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unknown node")}});
        world.node.forget(id);
      }
    }
    world.node.send({{QStringLiteral("t"), QStringLiteral("shell.node")}, {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
                     {QStringLiteral("node"), kPeer}, {QStringLiteral("online"), online}});
    world.sync();
  };
  step(QStringLiteral("that node leaves the cluster"), [setPeer](World& world, const Captures&, const Table&) { setPeer(world, false); });
  step(QStringLiteral("that node rejoins the cluster"), [setPeer](World& world, const Captures&, const Table&) { setPeer(world, true); });
  // A thread on an environment the node is linked to, reached through it.
  step(QStringLiteral("the user is looking at a thread on an environment the node is linked to"), [](World& world, const Captures&, const Table&) {
    const QString environment = QStringLiteral("env-c");
    const QString thread = QStringLiteral("thread-linked");
    world.node.sendLinkRow(environment, thread,
                           {{QStringLiteral("id"), thread}, {QStringLiteral("title"), QStringLiteral("Linked")}, {QStringLiteral("projectId"), kProject},
                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.node.link(environment);
    world.sync();
    FakeStreams& fake = world.node.part<FakeStreams>();
    fake.thread = thread;
    fake.environment = environment;
    look(world, environment + QLatin1Char(':') + thread);
  });
  const auto setLink = [](World& world, bool online) {
    FakeStreams& fake = world.node.part<FakeStreams>();
    if (online) {
      fake.offline.remove(fake.environment);
    } else {
      fake.offline.insert(fake.environment);
      for (const int id : followers(world, fake.thread)) {
        world.node.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("unreachable")}});
        world.node.forget(id);
      }
    }
    world.node.setLinkProblem(fake.environment, online ? QString() : QStringLiteral("unreachable"));
    world.sync();
  };
  step(QStringLiteral("that environment becomes unreachable"), [setLink](World& world, const Captures&, const Table&) { setLink(world, false); });
  step(QStringLiteral("that environment is reachable again"), [setLink](World& world, const Captures&, const Table&) { setLink(world, true); });
  step(QStringLiteral("the thread says its node cannot be reached"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    world.waitFor([&] { return model.status() == QLatin1String("unreachable"); }, [&] { return describe(model); });
    expect(!model.problem().isEmpty(), QStringLiteral("the thread does not say why"));
  });
  step(QStringLiteral("the answer %1 is still shown").arg(q), [](World& world, const Captures& c, const Table&) {
    expectAnswer(world, c[0]);
  });
  step(QStringLiteral("the thread follows its node again"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    world.waitFor([&] { return model.status() == QLatin1String("live"); }, [&] { return describe(model); });
  });

  // Tool calls.
  step(QStringLiteral("the agent has run five tool calls in a row in the running turn"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    for (int n = 1; n <= 5; ++n) addCommand(world, n);
  });
  step(QStringLiteral("the latest tool call is shown"), [](World& world, const Captures&, const Table&) {
    const QString command = lastEntry(world).value(QStringLiteral("command")).toString();
    expect(command == QLatin1String("bun test cart-5"), QStringLiteral("the call shown is \"%1\"").arg(command));
  });
  step(QStringLiteral("the other four are behind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const int work = lastRowOf(world, QStringLiteral("work"));
    const int hidden = role(model, work, TimelineModel::HiddenCountRole).toInt();
    const int shown = role(model, work, TimelineModel::EntriesRole).toList().size();
    expect(QStringLiteral("+%1 previous tool calls").arg(hidden) == c[0] && shown == 1,
           QStringLiteral("%1 calls are shown, %2 behind; %3").arg(shown).arg(hidden).arg(describe(model)));
  });
  const auto toggleGroup = [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    model.toggle(role(model, lastRowOf(world, QStringLiteral("work")), TimelineModel::IdRole).toString());
  };
  step(QStringLiteral("the user shows the previous tool calls"), toggleGroup);
  step(QStringLiteral("the user hides them again"), toggleGroup);
  step(QStringLiteral("all five tool calls are shown"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int shown = role(model, lastRowOf(world, QStringLiteral("work")), TimelineModel::EntriesRole).toList().size();
    expect(shown == 5, QStringLiteral("%1 calls are shown; %2").arg(shown).arg(describe(model)));
  });

  step(QStringLiteral("the agent's tool call is still running"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, QStringLiteral("running"));
  });
  step(QStringLiteral("the agent's tool call failed"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, QStringLiteral("failed"));
  });
  step(QStringLiteral("the agent's tool call was interrupted"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, QStringLiteral("interrupted"));
  });
  step(QStringLiteral("the agent's tool call was declined by the user"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    set(world, QStringLiteral("runtime-request"), QStringLiteral("request-1"),
        {{QStringLiteral("id"), QStringLiteral("request-1")}, {QStringLiteral("status"), QStringLiteral("resolved")}, {QStringLiteral("decision"), QStringLiteral("decline")}});
    addItem(world, QStringLiteral("approval_request"), {{QStringLiteral("requestId"), QStringLiteral("request-1")}, {QStringLiteral("prompt"), QStringLiteral("Run rm -rf dist?")}});
  });
  step(QStringLiteral("the call is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastEntry(world).value(QStringLiteral("statusLabel")).toString();
    expect(label == c[0], QStringLiteral("the call is marked \"%1\"").arg(label));
  });

  step(QStringLiteral("the agent changed %1 and %1 in one turn").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    for (const QString& path : {c[0], c[1]}) addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), path}});
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Both files are updated.")}});
    world.node.part<FakeStreams>().changedFiles = {c[0], c[1]};
  });
  step(QStringLiteral("the turn completes"), [](World& world, const Captures&, const Table&) {
    QJsonArray files;
    int n = 0;
    for (const QString& path : world.node.part<FakeStreams>().changedFiles) {
      ++n;
      files.append(QJsonObject{{QStringLiteral("path"), path}, {QStringLiteral("kind"), QStringLiteral("modified")},
                               {QStringLiteral("additions"), 10 * n}, {QStringLiteral("deletions"), n}});
    }
    addItem(world, QStringLiteral("checkpoint"), {{QStringLiteral("files"), files}});
    settleRun(world, QStringLiteral("completed"), 60);
  });
  step(QStringLiteral("the reply lists both files with their added and removed lines"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int reply = lastRowOf(world, QStringLiteral("message"));
    const QVariantList files = role(model, reply, TimelineModel::FilesRole).toList();
    const QStringList changed = world.node.part<FakeStreams>().changedFiles;
    expect(files.size() == changed.size(), QStringLiteral("the reply lists %1").arg(show(files)));
    for (qsizetype i = 0; i < files.size(); ++i) {
      const QVariantMap file = files.at(i).toMap();
      expect(file.value(QStringLiteral("path")) == changed.at(i) && file.value(QStringLiteral("additions")).toInt() > 0 &&
                 file.value(QStringLiteral("deletions")).toInt() > 0,
             QStringLiteral("the reply lists %1").arg(show(files)));
    }
  });

  // Runs and the queue.
  step(QStringLiteral("the user's message was (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QString> intents{
        {QStringLiteral("queued behind the active turn"), QStringLiteral("queued_turn")},
        {QStringLiteral("sent as a steer"), QStringLiteral("steer")},
        {QStringLiteral("queued and later promoted to a steer"), QStringLiteral("promoted_queued_to_steer")},
    };
    if (!intents.contains(c[0])) fail(QStringLiteral("unknown way of sending: %1").arg(c[0]));
    const QString run = startRun(world, 0, QStringLiteral("queued"));
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("inputIntent"), intents.value(c[0])}});
  });
  step(QStringLiteral("the message is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const int row = rowShowing(world, QStringLiteral("message:") + world.node.part<FakeStreams>().run);
    const QString marker = role(model, row, TimelineModel::MarkerRole).toString();
    expect(marker == c[0], QStringLiteral("the message is marked \"%1\"").arg(marker));
  });

  // Plans and subagents.
  step(QStringLiteral("the agent proposes a plan whose first heading is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("proposed_plan"), {{QStringLiteral("markdown"), QStringLiteral("Here is the plan.\n\n## %1\n\n- Add the line\n- Test it").arg(c[0])}});
  });
  step(QStringLiteral("the plan card is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = role(timeline(world), lastRowOf(world, QStringLiteral("plan")), TimelineModel::TitleRole).toString();
    expect(title == c[0], QStringLiteral("the plan card is titled \"%1\"").arg(title));
  });
  step(QStringLiteral("a plan without a heading is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addItem(world, QStringLiteral("proposed_plan"), {{QStringLiteral("markdown"), QStringLiteral("Add the line, then test it.")}});
    const QString title = role(timeline(world), lastRowOf(world, QStringLiteral("plan")), TimelineModel::TitleRole).toString();
    expect(title == c[0], QStringLiteral("the plan card is titled \"%1\"").arg(title));
  });

  step(QStringLiteral("the agent has a subagent that is (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QString> statuses{
        {QStringLiteral("running"), QStringLiteral("running")},
        {QStringLiteral("waiting on a request"), QStringLiteral("waiting")},
        {QStringLiteral("idle and resumable"), QStringLiteral("idle")},
        {QStringLiteral("completed"), QStringLiteral("completed")},
        {QStringLiteral("failed"), QStringLiteral("failed")},
        {QStringLiteral("cancelled"), QStringLiteral("cancelled")},
    };
    if (!statuses.contains(c[0])) fail(QStringLiteral("unknown subagent status: %1").arg(c[0]));
    startRun(world);
    addItem(world, QStringLiteral("subagent"), {{QStringLiteral("status"), statuses.value(c[0])}, {QStringLiteral("title"), QStringLiteral("Tax tests")},
                                                {QStringLiteral("prompt"), QStringLiteral("write the tax tests")}, {QStringLiteral("childThreadId"), QStringLiteral("thread-child")}});
  });
  step(QStringLiteral("the subagent is shown as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = role(timeline(world), lastRowOf(world, QStringLiteral("subagent")), TimelineModel::StatusLabelRole).toString();
    expect(label == c[0], QStringLiteral("the subagent is shown as \"%1\"").arg(label));
  });

  const QList<std::pair<QString, QJsonObject>> contextEvents{
      {QStringLiteral("the conversation is forked"), {{QStringLiteral("type"), QStringLiteral("fork")}, {QStringLiteral("targetThreadId"), QStringLiteral("thread-2")}}},
      {QStringLiteral("the context is handed to another agent"), {{QStringLiteral("type"), QStringLiteral("handoff")}, {QStringLiteral("summary"), QStringLiteral("Cart tax so far")}}},
      {QStringLiteral("the agent creates a thread"), {{QStringLiteral("type"), QStringLiteral("thread_created")}, {QStringLiteral("title"), QStringLiteral("Tax tests")}}},
      {QStringLiteral("the context is compacted"), {{QStringLiteral("type"), QStringLiteral("compaction")}, {QStringLiteral("summary"), QStringLiteral("Earlier turns")}}},
  };
  for (const auto& [event, fields] : contextEvents) {
    step(event, [fields](World& world, const Captures&, const Table&) {
      startRun(world);
      addItem(world, fields.value(QLatin1String("type")).toString(), fields);
    });
  }
  step(QStringLiteral("the timeline marks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = role(timeline(world), lastRowOf(world, QStringLiteral("marker")), TimelineModel::TitleRole).toString();
    expect(title == c[0], QStringLiteral("the timeline marks \"%1\"").arg(title));
  });
});

}  // namespace
