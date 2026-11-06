// "/usage-limits" in the composer (ComposerController::slashUsageLimits): the
// desktop's half of features/providers/usage-limits.feature. The MC offers
// the command to a client that says it answers it itself, on the providers
// with limits to show (apps/server-ex HalC2.ProviderUsageLimits).

#include <QJsonArray>
#include <QJsonObject>

#include <QQuickItem>
#include <QRegularExpression>

#include "Brick.h"
#include "SettingsController.h"
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

QJsonObject limits(World& world, double used = 40) {
  return {{QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
          {QStringLiteral("windows"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("five-hour")},
                                                             {QStringLiteral("kind"), QStringLiteral("session")},
                                                             {QStringLiteral("label"), QStringLiteral("5-hour")},
                                                             {QStringLiteral("usedPercent"), used},
                                                             {QStringLiteral("resetsAt"), world.now().addSecs(3600).toUTC().toString(Qt::ISODateWithMs)},
                                                             {QStringLiteral("windowDurationMins"), 300}}}}};
}

QJsonObject entry(const QString& id, const QString& driver, const QString& name, const QString& slug) {
  return {{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), driver}, {QStringLiteral("displayName"), name},
          {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), QJsonArray{model(slug)}}};
}

// A Codex instance offering the command, with its limits unless `limits` is empty.
QJsonObject codex(const QString& id, const QString& name, const QJsonObject& limits) {
  QJsonObject codex = entry(id, QStringLiteral("codex"), name, QStringLiteral("gpt-5"));
  if (!limits.isEmpty()) codex.insert(QStringLiteral("usageLimits"), limits);
  codex.insert(QStringLiteral("slashCommands"),
               QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("usage-limits")},
                                      {QStringLiteral("description"), QStringLiteral("Show this provider's usage limits")}}});
  return codex;
}

// Codex with a subscription's windows and the command; Antigravity with neither.
QJsonArray providers(World& world) {
  return {codex(QStringLiteral("codex"), QStringLiteral("Codex"), limits(world)),
          entry(QStringLiteral("antigravity"), QStringLiteral("antigravity"), QStringLiteral("Antigravity"), QStringLiteral("gemini-pro"))};
}

// A hub's Codex accounts, by id.
QJsonArray hub(World& world, const QStringList& accounts) {
  QJsonArray listed;
  for (const QString& id : accounts) {
    listed.append(QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("driver"), QStringLiteral("codex")}, {QStringLiteral("usageLimits"), limits(world, 50)}});
  }
  return {QJsonObject{{QStringLiteral("id"), QStringLiteral("team-hub")},
                      {QStringLiteral("kind"), QStringLiteral("cliproxy")},
                      {QStringLiteral("label"), QStringLiteral("Team hub")},
                      {QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
                      {QStringLiteral("accounts"), listed}}};
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

void openThreadOn(World& world, const QString& instanceId, const QString& slug, const QJsonArray& catalogue = {}, const QJsonArray& sources = {}) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
  world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  publishProviders(world.mc, catalogue.isEmpty() ? providers(world) : catalogue);
  if (!sources.isEmpty()) {
    publishSources(world.mc, sources);
    world.waitFor([&] { return world.native().controller<SettingsController>()->config().contains(QLatin1String("usageLimitSources")); },
                  QStringLiteral("the hubs to be read"));
  }
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

// The answer as drawn above the composer.
Brick& answer(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nComposerUsageLimits { width: 600 }\n", QSize(600, 300));
  world.brick->grab();
  return *world.brick;
}

// Whether any shown text holds `part`.
bool showsPart(const QQuickItem* item, const QString& part) {
  if (!item->isVisible()) return false;
  if (item->property("text").toString().contains(part)) return true;
  const QList<QQuickItem*> children = item->childItems();
  return std::any_of(children.begin(), children.end(), [&](const QQuickItem* child) { return showsPart(child, part); });
}

void openAnswer(World& world) {
  send(world, QStringLiteral("/usage-limits"));
  world.waitFor([&] { return !composer(world).value(QStringLiteral("usageLimits")).isNull(); },
                [&] { return QStringLiteral("the answer; the composer shows %1").arg(show(composer(world))); });
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
    const QVariantMap account = limits.value(QStringLiteral("accounts")).toList().value(0).toMap();
    const QVariantMap window = account.value(QStringLiteral("windows")).toList().value(0).toMap();
    expect(account.value(QStringLiteral("label")) == QLatin1String("Codex") && window.value(QStringLiteral("label")) == QLatin1String("5-hour") &&
               window.value(QStringLiteral("remainingPercent")).toDouble() == 60,
           QStringLiteral("the composer shows %1").arg(show(composer(world).value(QStringLiteral("usageLimits")))));
    expect(answer(world).shows(QStringLiteral("Usage limits")) && world.brick->shows(QStringLiteral("5-hour")) && world.brick->shows(QStringLiteral("60% left")),
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
  // Whose limits the answer shows.
  step(QStringLiteral("a Codex thread whose limits come from (.+)"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject antigravity = entry(QStringLiteral("antigravity"), QStringLiteral("antigravity"), QStringLiteral("Antigravity"), QStringLiteral("gemini-pro"));
    if (c[0].contains(QLatin1String("plan"))) {
      static const QRegularExpression plan(QStringLiteral("\"([^\"]+)\" plan"));
      QJsonObject one = codex(QStringLiteral("codex"), QStringLiteral("Codex"), limits(world));
      one.insert(QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("authenticated")},
                                                     {QStringLiteral("label"), plan.match(c[0]).captured(1)}});
      openThreadOn(world, QStringLiteral("codex"), QStringLiteral("gpt-5"), {one, antigravity});
    } else if (c[0].contains(QLatin1String("named"))) {
      static const QRegularExpression named(QStringLiteral("named \"([^\"]+)\""));
      const QString name = named.match(c[0]).captured(1);
      // The default instance reports no limits of its own.
      openThreadOn(world, QStringLiteral("codex_work"), QStringLiteral("gpt-5"),
                   {codex(QStringLiteral("codex"), QStringLiteral("Codex"), {}), codex(QStringLiteral("codex_work"), name, limits(world)), antigravity});
    } else {
      openThreadOn(world, QStringLiteral("codex"), QStringLiteral("gpt-5"), {codex(QStringLiteral("codex"), QStringLiteral("Codex"), {}), antigravity},
                   hub(world, {QStringLiteral("ops.json"), QStringLiteral("build.json"), QStringLiteral("review.json")}));
    }
  });
  step(QStringLiteral("the answer is headed %1 and says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(answer(world).shows(c[0]) && answer(world).shows(c[1]),
           QStringLiteral("the answer is %1").arg(show(composer(world).value(QStringLiteral("usageLimits")))));
    expect(!dispatched(world), QStringLiteral("the command went to the agent: %1").arg(world.describeCommands()));
  });

  // An account named by its email.
  step(QStringLiteral("a hub account is labelled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openThreadOn(world, QStringLiteral("codex"), QStringLiteral("gpt-5"), {codex(QStringLiteral("codex"), QStringLiteral("Codex"), {})},
                 hub(world, {c[0]}));
  });
  step(QStringLiteral("the answer does not show %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !composer(world).value(QStringLiteral("usageLimits")).isNull(); }, QStringLiteral("the answer"));
    QQuickItem* account = answer(world).item(QStringLiteral("composerUsageLimitsAccount"));
    expect(account->isVisible() && !showsPart(answer(world).root(), c[0]),
           QStringLiteral("the answer shows %1 as \"%2\"").arg(c[0], account->property("text").toString()));
    // Only the account is hidden; the hub it came through is still named.
    expect(showsPart(answer(world).root(), QStringLiteral("Team hub")), QStringLiteral("the hub's name is hidden too"));
  });
  step(QStringLiteral("the user chooses to reveal the account"), [](World& world, const Captures&, const Table&) {
    answer(world).click(QStringLiteral("composerUsageLimitsAccount"));
  });
  step(QStringLiteral("the answer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(showsPart(answer(world).root(), c[0]),
           QStringLiteral("the account reads \"%1\"").arg(answer(world).item(QStringLiteral("composerUsageLimitsAccount"))->property("text").toString()));
  });
  step(QStringLiteral("the user can hide it again"), [](World& world, const Captures&, const Table&) {
    answer(world).click(QStringLiteral("composerUsageLimitsAccount"));
    expect(!showsPart(answer(world).root(), QStringLiteral("@example.com")), QStringLiteral("the account stayed revealed"));
  });

  // Dismissed.
  step(QStringLiteral("the answer to %1 is shown above the composer").arg(q), [](World& world, const Captures&, const Table&) {
    openThreadOn(world, QStringLiteral("codex"), QStringLiteral("gpt-5"));
    openAnswer(world);
    expect(answer(world).shows(QStringLiteral("Usage limits")), QStringLiteral("the answer is not drawn"));
  });
  step(QStringLiteral("the user dismisses the usage limits"), [](World& world, const Captures&, const Table&) {
    answer(world).click(QStringLiteral("composerUsageLimitsDismiss"));
  });
  step(QStringLiteral("the answer is gone"), [](World& world, const Captures&, const Table&) {
    expect(composer(world).value(QStringLiteral("usageLimits")).isNull() && !answer(world).shows(QStringLiteral("Usage limits")),
           QStringLiteral("the answer stayed: %1").arg(show(composer(world).value(QStringLiteral("usageLimits")))));
  });
  step(QStringLiteral("nothing was sent to the agent"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!dispatched(world), QStringLiteral("the MC was sent %1").arg(world.describeCommands()));
  });
});

}  // namespace
