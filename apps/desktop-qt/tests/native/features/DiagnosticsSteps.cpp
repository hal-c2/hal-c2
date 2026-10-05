// The native Diagnostics settings page (DiagnosticsController): the @desktop
// and @shared scenarios of features/settings/diagnostics.feature, against a
// MC whose `server.*` diagnostics calls this file fakes.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeMc.h"
#include "Harness.h"
#include "SettingsController.h"
#include <QTest>
#include <QQuickItem>
#include "Brick.h"
#include "World.h"

namespace {

const QString kLogs = QStringLiteral("/home/user/.local/state/hal-c2/elixir/logs");
constexpr int kAgentPid = 4102;

struct FakeDiagnostics {
  QList<QJsonObject> signals_;  // every server.signalProcess payload
  QList<QJsonObject> editorCalls;  // every shell.openInEditor payload
};

// A provider session and a terminal under the MC.
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
          {QStringLiteral("processCount"), 4},
          {QStringLiteral("totalRssBytes"), 104857600},
          {QStringLiteral("totalCpuPercent"), 5.0},
          {QStringLiteral("processes"),
           QJsonArray{process(kAgentPid, 4000, QStringLiteral("codex app-server"), 0), process(4210, 4000, QStringLiteral("/bin/zsh -l"), 0),
                      // What the shell runs, and a helper of the MC's own.
                      process(4211, 4210, QStringLiteral("bun dev"), 1), process(4300, 4000, QStringLiteral("epmd -daemon"), 0)}}};
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("server.getProcessDiagnostics"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, processes()); });
  mc.onRpc(QStringLiteral("server.getProcessResourceHistory"), [&mc](const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{QStringLiteral("windowMs"), rpc.payload.value(QLatin1String("windowMs"))},
                                {QStringLiteral("sampleIntervalMs"), 5000},
                                {QStringLiteral("retainedSampleCount"), 0},
                                {QStringLiteral("totalCpuSecondsApprox"), 0},
                                {QStringLiteral("topProcesses"), QJsonArray()},
                                {QStringLiteral("buckets"), QJsonArray()}});
  });
  mc.onRpc(QStringLiteral("server.getTraceDiagnostics"), [&mc](const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{QStringLiteral("recordCount"), 0},
                                {QStringLiteral("failureCount"), 0},
                                {QStringLiteral("slowSpanCount"), 0},
                                {QStringLiteral("parseErrorCount"), 0}});
  });
  mc.onRpc(QStringLiteral("server.signalProcess"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeDiagnostics>().signals_.append(rpc.payload);
    mc.reply(rpc, QJsonObject{{QStringLiteral("pid"), rpc.payload.value(QLatin1String("pid"))},
                                {QStringLiteral("signal"), rpc.payload.value(QLatin1String("signal"))},
                                {QStringLiteral("signaled"), true}});
  });
});

FakeDiagnostics& fake(World& world) {
  return world.mc.part<FakeDiagnostics>();
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

// The MC's config as it announces a change, with `editors` as its editors.
void setEditors(World& world, const QJsonArray& editors) {
  FakeConfig& config = fakeConfig(world.mc);
  config.config.insert(QStringLiteral("availableEditors"), editors);
  QJsonObject frame = config.config;
  frame.insert(QStringLiteral("settings"), config.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), frame}});
  }
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  // Process groups (settings/resource-telemetry.feature).
  const auto groups = [](World& world) { return at(at(diagnostics(world), QStringLiteral("processes")), QStringLiteral("groups")).toList(); };
  step(QStringLiteral("the user watches the resource monitor"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) {
      world.connect();
      world.sync();
    }
    open(world);
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nDiagnosticsSettings {}\n", QSize(900, 1400));
  });
  step(QStringLiteral("processes are grouped as server, provider and terminal"), [groups](World& world, const Captures&, const Table&) {
    QStringList shown;
    for (const QVariant& group : groups(world)) {
      QStringList names;
      for (const QVariant& row : at(group, QStringLiteral("rows")).toList()) names.append(at(row, QStringLiteral("name")).toString());
      shown.append(QStringLiteral("%1: %2").arg(at(group, QStringLiteral("label")).toString(), names.join(QStringLiteral(", "))));
    }
    // A shell's child goes with its terminal.
    expect(shown == QStringList{QStringLiteral("Server: epmd"), QStringLiteral("Provider: codex"), QStringLiteral("Terminal: zsh, bun")},
           QStringLiteral("the groups are %1").arg(shown.join(QStringLiteral("; "))));
    world.brick->grab();
    for (const QString& id : {QStringLiteral("server"), QStringLiteral("provider"), QStringLiteral("terminal")}) {
      expect(world.brick->item(QStringLiteral("processGroup:") + id)->isVisible(), QStringLiteral("the page has no %1 group").arg(id));
    }
  });
  step(QStringLiteral("each group can be collapsed and expanded again"), [groups](World& world, const Captures&, const Table&) {
    const auto listed = [&world](int pid) {
      world.brick->grab();
      // Repeater delegates are the item tree's children.
      const QString name = QStringLiteral("process:%1").arg(pid);
      std::function<bool(const QQuickItem*)> shown = [&](const QQuickItem* item) {
        if (item->objectName() == name && item->isVisible()) return true;
        for (const QQuickItem* child : item->childItems()) {
          if (shown(child)) return true;
        }
        return false;
      };
      return shown(world.brick->window().contentItem());
    };
    const QHash<QString, int> first{{QStringLiteral("server"), 4300}, {QStringLiteral("provider"), kAgentPid}, {QStringLiteral("terminal"), 4210}};
    for (auto it = first.cbegin(); it != first.cend(); ++it) {
      expect(listed(it.value()), QStringLiteral("%1 is not listed").arg(it.value()));
      const auto foldOf = [&world](const QString& id) {
        QQuickItem* found = nullptr;
        std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
          if (item->objectName() == QLatin1String("fold")) found = found ? found : item;
          for (QQuickItem* child : item->childItems()) find(child);
        };
        world.brick->grab();
        find(world.brick->item(QStringLiteral("processGroup:") + id));
        expect(found != nullptr, QStringLiteral("the %1 group cannot be folded").arg(id));
        return found;
      };
      QQuickItem* fold = foldOf(it.key());
      QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(fold));
      expect(!listed(it.value()), QStringLiteral("the %1 group did not collapse").arg(it.key()));
      // The others stay open.
      for (auto other = first.cbegin(); other != first.cend(); ++other) {
        if (other.key() != it.key()) expect(listed(other.value()), QStringLiteral("%1 went with the %2 group").arg(other.value()).arg(it.key()));
      }
      fold = foldOf(it.key());
      QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(fold));
      expect(listed(it.value()), QStringLiteral("the %1 group did not expand").arg(it.key()));
    }
  });

  step(QStringLiteral("an MC running a provider session and a terminal"), [](World& world, const Captures&, const Table&) {
    FakeConfig& config = fakeConfig(world.mc);
    config.config.insert(QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("zed"), QStringLiteral("cursor")});
    config.config.insert(QStringLiteral("observability"), QJsonObject{{QStringLiteral("logsDirectoryPath"), kLogs}});
    // Over the workspace's fake: this page's calls are this file's to read.
    world.mc.onRpc(QStringLiteral("shell.openInEditor"), [&world](const FakeMc::Rpc& rpc) {
      fake(world).editorCalls.append(rpc.payload);
      world.mc.reply(rpc, QJsonValue::Null);
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
           QStringLiteral("the MC was asked for %1").arg(show(call.toVariantMap())));
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
