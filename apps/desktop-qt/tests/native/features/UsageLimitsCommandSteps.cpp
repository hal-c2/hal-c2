// "/usage-limits" in the composer (ComposerController::slashUsageLimits): the
// desktop's half of features/providers/usage-limits.feature. The MC offers
// the command to a client that says it answers it itself, on the providers
// with limits to show (apps/server-ex HalC2.ProviderUsageLimits).

#include <QJsonArray>
#include <QJsonObject>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SharedSteps.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

QJsonObject model(const QString& slug) {
  return {{QStringLiteral("slug"), slug}, {QStringLiteral("name"), slug}};
}

// Codex with a subscription's windows and the command; Antigravity with neither.
QJsonArray providers(World& world) {
  const QJsonObject limits{
      {QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
      {QStringLiteral("windows"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("five-hour")},
                                                         {QStringLiteral("kind"), QStringLiteral("session")},
                                                         {QStringLiteral("label"), QStringLiteral("5-hour")},
                                                         {QStringLiteral("usedPercent"), 40},
                                                         {QStringLiteral("resetsAt"), world.now().addSecs(3600).toUTC().toString(Qt::ISODateWithMs)},
                                                         {QStringLiteral("windowDurationMins"), 300}}}}};
  const auto entry = [](const QString& id, const QString& name, const QString& slug) {
    return QJsonObject{{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name},
                       {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
                       {QStringLiteral("models"), QJsonArray{model(slug)}}};
  };
  QJsonObject codex = entry(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("gpt-5"));
  codex.insert(QStringLiteral("usageLimits"), limits);
  codex.insert(QStringLiteral("slashCommands"),
               QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("usage-limits")},
                                      {QStringLiteral("description"), QStringLiteral("Show this provider's usage limits")}}});
  return {codex, entry(QStringLiteral("antigravity"), QStringLiteral("Antigravity"), QStringLiteral("gemini-pro"))};
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

void openThreadOn(World& world, const QString& instanceId, const QString& slug) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
  world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  publishProviders(world.mc, providers(world));
  lookAtThread(world, kProject);
  QJsonObject& row = world.mc.threads[kThread];
  row.insert(QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), slug}});
  world.mc.sendRow(kThread, row);
  world.waitFor([&] { return composer(world).value(QStringLiteral("selectedModel")) == slug; },
                [&] { return QStringLiteral("the composer on %1; it shows %2").arg(slug, show(composer(world))); });
  // The client told the environment it answers the command itself.
  bool told = false;
  for (const QJsonObject& sub : world.mc.subscriptions) {
    const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("config") && shape.value(QLatin1String("usageLimitsCommand")).toBool()) told = true;
  }
  expect(told, QStringLiteral("no config subscription said the client answers /usage-limits"));
}

void send(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), text}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
}

bool dispatched(World& world) {
  for (const QJsonObject& command : world.mc.commands) {
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) return true;
  }
  return false;
}

}  // namespace

void expectCommandNotOffered(World& world, const QString& command) {
  const QVariantList suggestions = composer(world).value(QStringLiteral("suggestions")).toList();
  if (suggestions.isEmpty() || !command.startsWith(QLatin1Char('/'))) return;
  QStringList offered;
  for (const QVariant& item : suggestions) offered.append(item.toMap().value(QStringLiteral("label")).toString());
  expect(offered.contains(QStringLiteral("/model")) && !offered.contains(command), QStringLiteral("the menu offers %1").arg(offered.join(QStringLiteral(", "))));
  // Sent anyway, it is an ordinary message to the agent.
  send(world, command);
  world.waitFor([&] { return dispatched(world); }, QStringLiteral("the message to be sent"));
  expect(composer(world).value(QStringLiteral("usageLimits")).isNull(), QStringLiteral("limits were shown"));
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a Codex thread"), [](World& world, const Captures&, const Table&) {
    openThreadOn(world, QStringLiteral("codex"), QStringLiteral("gpt-5"));
  });
  step(QStringLiteral("an Antigravity thread"), [](World& world, const Captures&, const Table&) {
    openThreadOn(world, QStringLiteral("antigravity"), QStringLiteral("gemini-pro"));
  });
  step(QStringLiteral("Codex's windows are shown above the composer without running the agent"), [](World& world, const Captures&, const Table&) {
    const QVariantMap limits = composer(world).value(QStringLiteral("usageLimits")).toMap();
    const QVariantMap window = limits.value(QStringLiteral("windows")).toList().value(0).toMap();
    expect(limits.value(QStringLiteral("provider")) == QLatin1String("Codex") && window.value(QStringLiteral("label")) == QLatin1String("5-hour") &&
               window.value(QStringLiteral("remainingPercent")).toDouble() == 60,
           QStringLiteral("the composer shows %1").arg(show(composer(world).value(QStringLiteral("usageLimits")))));
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nComposerUsageLimits { width: 600 }\n", QSize(600, 200));
    expect(world.brick->shows(QStringLiteral("Codex limits")) && world.brick->shows(QStringLiteral("5-hour")) && world.brick->shows(QStringLiteral("60% left")),
           QStringLiteral("the limits are not drawn"));
    world.sync();
    expect(!dispatched(world) && composer(world).value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the command went to the agent: %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("they close when the user sends the next message"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("Add a tax line"));
    world.waitFor([&] { return dispatched(world); }, [&] { return QStringLiteral("the message; the MC has %1").arg(world.describeCommands()); });
    expect(composer(world).value(QStringLiteral("usageLimits")).isNull(), QStringLiteral("the limits stayed open"));
    // Asked for again, they also close when dismissed.
    send(world, QStringLiteral("/usage-limits"));
    expect(!composer(world).value(QStringLiteral("usageLimits")).isNull(), QStringLiteral("the limits did not open again"));
    world.brick->click(QStringLiteral("composerUsageLimitsDismiss"));
    expect(composer(world).value(QStringLiteral("usageLimits")).isNull(), QStringLiteral("the limits stayed open"));
  });
  step(QStringLiteral("the user opens the composer's command menu"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.mc.environmentId + QLatin1Char(':') + kThread},
                                        {QStringLiteral("text"), QStringLiteral("/")}, {QStringLiteral("cursor"), 1}});
    world.waitFor([&] { return !composer(world).value(QStringLiteral("suggestions")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the command menu; the composer shows %1").arg(show(composer(world))); });
  });
});

}  // namespace
