// The native Diagnostics settings page (DiagnosticsController): the @desktop
// and @shared scenarios of features/settings/diagnostics.feature, against a
// node whose `server.*` diagnostics calls this file fakes.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeNode.h"
#include "Harness.h"
#include "SettingsController.h"
#include "World.h"

namespace {

const QString kLogs = QStringLiteral("/home/user/.local/state/hal-c2/elixir/logs");
constexpr int kAgentPid = 4102;

struct FakeDiagnostics {
  QList<QJsonObject> signals_;  // every server.signalProcess payload
  QList<QJsonObject> editorCalls;  // every shell.openInEditor payload
};

// A provider session and a terminal under the node.
QJsonObject processes() {
  const auto process = [](int pid, int ppid, const QString& command, int depth) {
    return QJsonObject{{QStringLiteral("pid"), pid},
                       {QStringLiteral("ppid"), ppid},
                       {QStringLiteral("pgid"), pid},
                       {QStringLiteral("status"), QStringLiteral("S")},
                       {QStringLiteral("cpuPercent"), 2.5},
                       {QStringLiteral("rssBytes"), 52428800},
                       {QStringLiteral("elapsed"), QStringLiteral("00:42")},
                       {QStringLiteral("startTimeMs"), qint64(1767225600000) + pid},
                       {QStringLiteral("command"), command},
                       {QStringLiteral("depth"), depth},
                       {QStringLiteral("childPids"), QJsonArray()}};
  };
  return {{QStringLiteral("serverPid"), 4000},
          {QStringLiteral("readAt"), QStringLiteral("2026-01-01T00:00:00.000Z")},
          {QStringLiteral("processCount"), 2},
          {QStringLiteral("totalRssBytes"), 104857600},
          {QStringLiteral("totalCpuPercent"), 5.0},
          {QStringLiteral("processes"),
           QJsonArray{process(kAgentPid, 4000, QStringLiteral("codex app-server"), 0), process(4210, 4000, QStringLiteral("/bin/zsh -l"), 0)}}};
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onRpc(QStringLiteral("server.getProcessDiagnostics"), [&node](const FakeNode::Rpc& rpc) { node.reply(rpc, processes()); });
  node.onRpc(QStringLiteral("server.getProcessResourceHistory"), [&node](const FakeNode::Rpc& rpc) {
    node.reply(rpc, QJsonObject{{QStringLiteral("windowMs"), rpc.payload.value(QLatin1String("windowMs"))},
                                {QStringLiteral("sampleIntervalMs"), 5000},
                                {QStringLiteral("retainedSampleCount"), 0},
                                {QStringLiteral("totalCpuSecondsApprox"), 0},
                                {QStringLiteral("topProcesses"), QJsonArray()},
                                {QStringLiteral("buckets"), QJsonArray()}});
  });
  node.onRpc(QStringLiteral("server.getTraceDiagnostics"), [&node](const FakeNode::Rpc& rpc) {
    node.reply(rpc, QJsonObject{{QStringLiteral("recordCount"), 0},
                                {QStringLiteral("failureCount"), 0},
                                {QStringLiteral("slowSpanCount"), 0},
                                {QStringLiteral("parseErrorCount"), 0}});
  });
  node.onRpc(QStringLiteral("server.signalProcess"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeDiagnostics>().signals_.append(rpc.payload);
    node.reply(rpc, QJsonObject{{QStringLiteral("pid"), rpc.payload.value(QLatin1String("pid"))},
                                {QStringLiteral("signal"), rpc.payload.value(QLatin1String("signal"))},
                                {QStringLiteral("signaled"), true}});
  });
});

FakeDiagnostics& fake(World& world) {
  return world.node.part<FakeDiagnostics>();
}

QVariantMap diagnostics(World& world) {
  return world.state(QStringLiteral("diagnostics")).toMap();
}

void open(World& world) {
  world.bridge().dispatch(QStringLiteral("settings.open"), {});
  world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/diagnostics")}});
  world.waitFor([&] { return !at(at(diagnostics(world), QStringLiteral("processes")), QStringLiteral("rows")).toList().isEmpty(); },
                [&] { return QStringLiteral("the processes to be listed; diagnostics are %1").arg(show(diagnostics(world))); });
}

// The node's config as it announces a change, with `editors` as its editors.
void setEditors(World& world, const QJsonArray& editors) {
  FakeConfig& config = fakeConfig(world.node);
  config.config.insert(QStringLiteral("availableEditors"), editors);
  QJsonObject frame = config.config;
  frame.insert(QStringLiteral("settings"), config.settings);
  for (const int id : world.node.subscribers(QStringLiteral("config"))) {
    if (world.node.shapeOf(id).value(QLatin1String("environment")) != world.node.environmentId) continue;
    world.node.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), frame}});
  }
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a node running a provider session and a terminal"), [](World& world, const Captures&, const Table&) {
    FakeConfig& config = fakeConfig(world.node);
    config.config.insert(QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("zed"), QStringLiteral("cursor")});
    config.config.insert(QStringLiteral("observability"), QJsonObject{{QStringLiteral("logsDirectoryPath"), kLogs}});
    // Over the workspace's fake: this page's calls are this file's to read.
    world.node.onRpc(QStringLiteral("shell.openInEditor"), [&world](const FakeNode::Rpc& rpc) {
      fake(world).editorCalls.append(rpc.payload);
      world.node.reply(rpc, QJsonValue::Null);
    });
    world.connect();
    world.sync();
  });

  step(QStringLiteral("the user force kills a process"), [](World& world, const Captures&, const Table&) {
    open(world);
    world.bridge().dispatch(QStringLiteral("diagnostics.signal"), QVariantMap{{QStringLiteral("pid"), kAgentPid}, {QStringLiteral("signal"), QStringLiteral("SIGKILL")}});
    world.sync();
  });
  step(QStringLiteral("the user is asked to confirm because the process cannot handle it"), [](World& world, const Captures&, const Table&) {
    const QVariant question = world.state(QStringLiteral("confirmation"));
    expect(at(question, QStringLiteral("title")) == QStringLiteral("Send SIGKILL to process %1? This cannot be handled by the process.").arg(kAgentPid),
           QStringLiteral("the question is %1").arg(show(question)));
    expect(fake(world).signals_.isEmpty(), QStringLiteral("the signal went before the user answered"));
  });
  step(QStringLiteral("cancelling leaves the process running"), [](World& world, const Captures&, const Table&) {
    const QVariant question = world.state(QStringLiteral("confirmation"));
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), false}});
    world.sync();
    expect(fake(world).signals_.isEmpty(), QStringLiteral("%1 signals were sent").arg(fake(world).signals_.size()));
    expect(world.state(QStringLiteral("confirmation")).isNull(), QStringLiteral("the question stays"));
  });

  step(QStringLiteral("the user opens the logs folder"), [](World& world, const Captures&, const Table&) {
    // The user last opened something in Cursor.
    world.native().controller<SettingsController>()->writeDevice(QStringLiteral("lastEditor"), QStringLiteral("cursor"));
    open(world);
    world.bridge().dispatch(QStringLiteral("diagnostics.openLogs"), {});
    world.sync();
  });
  step(QStringLiteral("it opens in the user's preferred editor"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !fake(world).editorCalls.isEmpty(); }, QStringLiteral("the logs folder to open"));
    const QJsonObject call = fake(world).editorCalls.constLast();
    expect(call == QJsonObject{{QStringLiteral("cwd"), kLogs}, {QStringLiteral("editor"), QStringLiteral("cursor")}},
           QStringLiteral("the node was asked for %1").arg(show(call.toVariantMap())));
  });
  step(QStringLiteral("if no editor is available the user is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setEditors(world, QJsonArray());
    fake(world).editorCalls.clear();
    world.bridge().dispatch(QStringLiteral("diagnostics.openLogs"), {});
    world.sync();
    const QVariant error = at(at(diagnostics(world), QStringLiteral("logs")), QStringLiteral("error"));
    expect(error == c[0], QStringLiteral("the user is told %1").arg(show(error)));
    expect(fake(world).editorCalls.isEmpty(), QStringLiteral("an editor was asked anyway"));
  });
});

}  // namespace
