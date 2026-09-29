// The usage page on the desktop (UsageController), and the node's side of it:
// the @shared scenarios of features/settings/usage.feature.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// Each environment's session history, as apps/server-ex HalC2.Usage answers
// `server.getUsageSummary`: one provider per environment, so what each one
// contributes can be told apart.
struct FakeUsage {
  QHash<QString, QString> providers;  // by environment; the node's own is Codex
  QHash<QString, int> versions;       // contract versions other than 5
  QSet<QString> scanning;             // environments that never answer
  QString refusal;                    // the node's own summary fails so
  QList<FakeNode::Rpc> summaries;
  int rates = 0;
  qsizetype readsAtRefresh = 0;
  int limitChecks = 0;
  int followedBefore = 0;
};

FakeUsage& fake(World& world) {
  return world.node.part<FakeUsage>();
}

QString environmentOf(FakeNode& node, const FakeNode::Rpc& rpc) {
  return rpc.environment.isEmpty() ? node.environmentId : rpc.environment;
}

QString providerOf(FakeNode& node, const QString& environment) {
  return node.part<FakeUsage>().providers.value(environment, QStringLiteral("codex"));
}

QJsonObject summary(FakeNode& node, const QString& environment, const QJsonObject& input) {
  const QString provider = providerOf(node, environment);
  QJsonObject bucket{
      {QStringLiteral("day"), input.value(QLatin1String("untilDay"))},
      {QStringLiteral("provider"), provider},
      {QStringLiteral("model"), QStringLiteral("model-") + provider},
      {QStringLiteral("totals"), QJsonObject{{QStringLiteral("uncachedInputTokens"), 1000},
                                             {QStringLiteral("cachedInputTokens"), 500},
                                             {QStringLiteral("cacheCreationTokens"), 0},
                                             {QStringLiteral("outputTokens"), 200},
                                             {QStringLiteral("reasoningTokens"), 50}}},
      {QStringLiteral("costUsd"), 1.5},
      {QStringLiteral("cacheSavingsUsd"), 0.25},
      {QStringLiteral("costSource"), QStringLiteral("modelPriced")},
      {QStringLiteral("records"), 3},
      {QStringLiteral("unpricedRecords"), 0},
      {QStringLiteral("sessions"), 1},
  };
  if (input.value(QLatin1String("resolution")) == QLatin1String("hour")) {
    bucket.insert(QStringLiteral("hourStart"), input.value(QLatin1String("sinceTime")));
  }
  const QJsonObject source{
      {QStringLiteral("fingerprint"), QJsonObject{{QStringLiteral("hostId"), environment},
                                                  {QStringLiteral("provider"), provider},
                                                  {QStringLiteral("resolvedHomePath"), QStringLiteral("/home/sam/.") + provider},
                                                  {QStringLiteral("volumeId"), QStringLiteral("disk")}}},
      {QStringLiteral("status"), QStringLiteral("ok")},
      {QStringLiteral("distinctSessions"), 2},
  };
  return {
      {QStringLiteral("contractVersion"), node.part<FakeUsage>().versions.value(environment, 5)},
      {QStringLiteral("readAt"), QStringLiteral("2026-09-23T10:00:00.000Z")},
      {QStringLiteral("timeZone"), input.value(QLatin1String("timeZone"))},
      {QStringLiteral("sinceDay"), input.value(QLatin1String("sinceDay"))},
      {QStringLiteral("untilDay"), input.value(QLatin1String("untilDay"))},
      {QStringLiteral("buckets"), QJsonArray{bucket}},
      {QStringLiteral("sources"), QJsonArray{source}},
      {QStringLiteral("pricing"), QJsonObject{{QStringLiteral("status"), QStringLiteral("fresh")}}},
  };
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onRpc(QStringLiteral("server.getUsageSummary"), [&node](const FakeNode::Rpc& rpc) {
    FakeUsage& fake = node.part<FakeUsage>();
    const QString environment = environmentOf(node, rpc);
    fake.summaries.append(rpc);
    if (fake.scanning.contains(environment)) return;
    if (!fake.refusal.isEmpty() && environment == node.environmentId) {
      node.refuse(rpc, fake.refusal, {{QStringLiteral("_tag"), QStringLiteral("UsageReadError")}});
      return;
    }
    node.reply(rpc, summary(node, environment, rpc.payload));
  });
  node.onRpc(QStringLiteral("server.refreshUsageRates"), [&node](const FakeNode::Rpc& rpc) {
    ++node.part<FakeUsage>().rates;
    node.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("fresh")}});
  });
  node.onRpc(QStringLiteral("server.refreshProviders"), [&node](const FakeNode::Rpc& rpc) {
    ++node.part<FakeUsage>().limitChecks;
    node.reply(rpc, QJsonObject{{QStringLiteral("providers"), fakeConfig(node).config.value(QLatin1String("providers"))}});
  });
});

QVariantMap usage(World& world) {
  return world.state(QStringLiteral("usage")).toMap();
}

void ensureConnected(World& world) {
  if (world.shellSubscriptions() > 0) return;
  world.connect();
  world.sync();
}

void showUsage(World& world, const QString& metric, int days = 0) {
  ensureConnected(world);
  world.bridge().dispatch(QStringLiteral("usage.open"), {});
  world.bridge().dispatch(QStringLiteral("usage.metric"), QVariantMap{{QStringLiteral("metric"), metric}});
  if (days > 0) world.bridge().dispatch(QStringLiteral("usage.window"), QVariantMap{{QStringLiteral("days"), days}});
  world.waitFor([&] {
    const QVariantMap page = usage(world);
    return page.value(QStringLiteral("open")).toBool() && page.value(QStringLiteral("metric")) == metric &&
           (days == 0 || page.value(QStringLiteral("windowDays")).toInt() == days);
  }, [&] { return QStringLiteral("usage to show %1; it is %2").arg(metric, show(usage(world))); });
}

QVariantMap environmentRow(World& world, const QString& id) {
  for (const QVariant& row : usage(world).value(QStringLiteral("environments")).toList()) {
    if (row.toMap().value(QStringLiteral("id")) == id) return row.toMap();
  }
  return {};
}

bool counted(World& world, const QString& provider) {
  for (const QVariant& row : at(usage(world), QStringLiteral("summary.providers")).toList()) {
    if (row.toMap().value(QStringLiteral("id")) == provider) return true;
  }
  return false;
}

void expectShown(World& world, const QString& environment) {
  const QString provider = providerOf(world.node, environment);
  world.waitFor([&] { return environmentRow(world, environment).value(QStringLiteral("status")) == QLatin1String("ready") && counted(world, provider); },
                [&] { return QStringLiteral("the usage of %1 to be shown; the page is %2").arg(environment, show(usage(world))); });
}

void link(World& world, const QString& environment, const QString& provider) {
  fake(world).providers.insert(environment, provider);
  world.node.link(environment);
}

QList<FakeNode::Rpc> summariesFor(World& world, const QString& environment) {
  QList<FakeNode::Rpc> calls;
  for (const FakeNode::Rpc& rpc : fake(world).summaries) {
    if (environmentOf(world.node, rpc) == environment) calls.append(rpc);
  }
  return calls;
}

QJsonObject limitsWindow(const QString& label, double used, const QDateTime& resetsAt) {
  return {{QStringLiteral("id"), QStringLiteral("five-hour")},
          {QStringLiteral("kind"), QStringLiteral("session")},
          {QStringLiteral("label"), label},
          {QStringLiteral("usedPercent"), used},
          {QStringLiteral("resetsAt"), resetsAt.toUTC().toString(Qt::ISODateWithMs)},
          {QStringLiteral("windowDurationMins"), 300}};
}

QJsonObject codex(const QString& instanceId, const QString& name, const QString& email, const QJsonObject& limits) {
  return {{QStringLiteral("instanceId"), instanceId},
          {QStringLiteral("driver"), QStringLiteral("codex")},
          {QStringLiteral("displayName"), name},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("authenticated")}, {QStringLiteral("email"), email}}},
          {QStringLiteral("usageLimits"), limits}};
}

void setProviders(World& world, const QJsonArray& providers) {
  fakeConfig(world.node).config.insert(QStringLiteral("providers"), providers);
}

const Steps steps([] {
  const QString q = kQuoted;

  // Reading usage.
  step(QStringLiteral("the user views (cost|tokens) for the past (24 hours|7 days|30 days|90 days)"),
       [](World& world, const Captures& c, const Table&) {
         showUsage(world, c[0], c[1] == QLatin1String("24 hours") ? 1 : c[1].section(QLatin1Char(' '), 0, 0).toInt());
       });
  step(QStringLiteral("the numbers cover that window"), [](World& world, const Captures&, const Table&) {
    const int days = usage(world).value(QStringLiteral("windowDays")).toInt();
    const QDateTime now = world.now().toUTC();
    QJsonObject expected;
    if (days == 1) {
      QDateTime until = now;
      until.setTime(QTime(now.time().hour(), now.time().minute()));
      expected = {{QStringLiteral("resolution"), QStringLiteral("hour")},
                  {QStringLiteral("sinceTime"), until.addSecs(-24 * 60 * 60).toString(Qt::ISODateWithMs)},
                  {QStringLiteral("untilTime"), until.toString(Qt::ISODateWithMs)}};
    } else {
      const QDate today = now.toLocalTime().date();
      expected = {{QStringLiteral("resolution"), QStringLiteral("day")},
                  {QStringLiteral("sinceDay"), today.addDays(-(days - 1)).toString(Qt::ISODate)},
                  {QStringLiteral("untilDay"), today.toString(Qt::ISODate)}};
    }
    world.waitFor([&] {
      const QList<FakeNode::Rpc> calls = summariesFor(world, world.node.environmentId);
      if (calls.isEmpty()) return false;
      for (auto it = expected.begin(); it != expected.end(); ++it) {
        if (calls.last().payload.value(it.key()) != it.value()) return false;
      }
      return !at(usage(world), QStringLiteral("summary.periods")).toList().isEmpty();
    }, [&] {
      const QList<FakeNode::Rpc> calls = summariesFor(world, world.node.environmentId);
      return QStringLiteral("usage to be read over %1; it was asked for %2 and shows %3")
          .arg(QString::fromUtf8(QJsonDocument(expected).toJson(QJsonDocument::Compact)),
               calls.isEmpty() ? QStringLiteral("nothing") : QString::fromUtf8(QJsonDocument(calls.last().payload).toJson(QJsonDocument::Compact)),
               show(usage(world)));
    });
  });
  step(QStringLiteral("%1 is still scanning and %1 has finished").arg(q), [](World& world, const Captures& c, const Table&) {
    link(world, c[0], QStringLiteral("grok"));
    link(world, c[1], QStringLiteral("claude"));
    fake(world).scanning.insert(c[0]);
  });
  step(QStringLiteral("%1 is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    link(world, c[0], QStringLiteral("claude"));
    world.node.setLinkProblem(c[0], QStringLiteral("unreachable"));
  });
  step(QStringLiteral("%1 runs an older server version").arg(q), [](World& world, const Captures& c, const Table&) {
    link(world, c[0], QStringLiteral("claude"));
    fake(world).versions.insert(c[0], 3);
  });
  step(QStringLiteral("the user views usage for all environments"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("cost"));
    world.bridge().dispatch(QStringLiteral("usage.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
  });
  step(QStringLiteral("the user views usage for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showUsage(world, QStringLiteral("cost"));
    world.waitFor([&] { return !environmentRow(world, c[0]).isEmpty(); },
                  [&] { return QStringLiteral("%1 to be offered; the page is %2").arg(c[0], show(usage(world))); });
    world.bridge().dispatch(QStringLiteral("usage.environment"), QVariantMap{{QStringLiteral("id"), c[0]}});
  });
  step(QStringLiteral("(?:the usage of )?%1(?: usage)? is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, c[0]);
  });
  step(QStringLiteral("the usage of this environment is shown"), [](World& world, const Captures&, const Table&) {
    expectShown(world, world.node.environmentId);
  });
  step(QStringLiteral("%1 is shown as still scanning").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return environmentRow(world, c[0]).value(QStringLiteral("status")) == QLatin1String("scanning") &&
                               usage(world).value(QStringLiteral("scanning")).toBool(); },
                  [&] { return QStringLiteral("%1 to be scanning; the page is %2").arg(c[0], show(usage(world))); });
  });
  step(QStringLiteral("the usage of (this environment|%1) is not counted").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString environment = c.size() < 2 || c[1].isEmpty() ? world.node.environmentId : c[1];
    // What is counted has landed.
    world.waitFor([&] { return !at(usage(world), QStringLiteral("summary")).isNull(); },
                  [&] { return QStringLiteral("usage to be shown; the page is %1").arg(show(usage(world))); });
    world.sync();
    expect(!counted(world, providerOf(world.node, environment)),
           QStringLiteral("the usage of %1 to be left out; the page is %2").arg(environment, show(usage(world))));
  });
  step(QStringLiteral("the user is told some environments could not report usage"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& notice : usage(world).value(QStringLiteral("notices")).toList()) {
        if (notice.toString().endsWith(QLatin1String("could not report usage."))) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a notice that usage could not be reported; the page is %1").arg(show(usage(world))); });
  });
  step(QStringLiteral("usage says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap page = usage(world);
      QVariantList said = page.value(QStringLiteral("notices")).toList();
      said.append(at(page, QStringLiteral("limits.notices")).toList());
      said.append(page.value(QStringLiteral("message")));
      return said.contains(c[0]);
    }, [&] { return QStringLiteral("usage to say %1; the page is %2").arg(c[0], show(usage(world))); });
  });
  step(QStringLiteral("the node cannot read usage"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal = QStringLiteral("Usage read failed (scanFailed): Transcripts could not be scanned.");
  });
  step(QStringLiteral("the node can read usage again"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal.clear();
  });
  step(QStringLiteral("the user refreshes usage"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !usage(world).value(QStringLiteral("refreshing")).toBool(); }, QStringLiteral("no refresh to be running"));
    fake(world).readsAtRefresh = summariesFor(world, world.node.environmentId).size();
    world.bridge().dispatch(QStringLiteral("usage.refresh"), {});
  });
  step(QStringLiteral("the node is asked for the latest model prices"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).rates == 1; },
                  [&] { return QStringLiteral("prices to be fetched once; they were fetched %1 times").arg(fake(world).rates); });
  });
  step(QStringLiteral("usage is read again"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = fake(world).readsAtRefresh;
    world.waitFor([&] { return summariesFor(world, world.node.environmentId).size() == before + 1 &&
                               !usage(world).value(QStringLiteral("refreshing")).toBool(); },
                  [&] { return QStringLiteral("usage to be read once more than %1 times; it was read %2 times")
                            .arg(before).arg(summariesFor(world, world.node.environmentId).size()); });
  });
  step(QStringLiteral("the user switched usage to tokens"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("tokens"));
  });
  step(QStringLiteral("the user opens usage again"), [](World& world, const Captures&, const Table&) {
    world.restart();
    world.connect();
    world.bridge().dispatch(QStringLiteral("usage.open"), {});
  });
  step(QStringLiteral("it shows tokens"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return usage(world).value(QStringLiteral("open")).toBool() &&
                               usage(world).value(QStringLiteral("metric")) == QLatin1String("tokens"); },
                  [&] { return QStringLiteral("usage to show tokens; it is %1").arg(show(usage(world))); });
  });

  // Limits.
  step(QStringLiteral("two Codex accounts"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    setProviders(world, {
        codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"),
              {{QStringLiteral("checkedAt"), now.toUTC().toString(Qt::ISODateWithMs)},
               {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 40, now.addSecs(3 * 3600))}}}),
        codex(QStringLiteral("codex-work"), QStringLiteral("Codex Work"), QStringLiteral("sam@work.example"),
              {{QStringLiteral("checkedAt"), now.toUTC().toString(Qt::ISODateWithMs)},
               {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 20, now.addSecs(3600))}}}),
    });
  });
  step(QStringLiteral("Codex could not read its limits"), [](World& world, const Captures&, const Table&) {
    setProviders(world, {codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"),
                               {{QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
                                {QStringLiteral("windows"), QJsonArray()},
                                {QStringLiteral("unavailable"), QJsonObject{{QStringLiteral("reason"), QStringLiteral("probeFailed")}}}})});
  });
  step(QStringLiteral("no provider reports limits"), [](World& world, const Captures&, const Table&) {
    setProviders(world, {});
  });
  step(QStringLiteral("the user views limits"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    fake(world).followedBefore = world.node.subscribers(QStringLiteral("config")).size();
    showUsage(world, QStringLiteral("limits"));
    world.waitFor([&] { return world.node.subscribers(QStringLiteral("config")).size() > fake(world).followedBefore; },
                  QStringLiteral("limits to be followed"));
  });
  step(QStringLiteral("Codex shows one 5-hour number made up of both accounts"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantList pools = at(usage(world), QStringLiteral("limits.pools")).toList();
      if (pools.size() != 1 || pools[0].toMap().value(QStringLiteral("label")) != QLatin1String("Codex")) return false;
      const QVariantList windows = pools[0].toMap().value(QStringLiteral("windows")).toList();
      return windows.size() == 1 && windows[0].toMap().value(QStringLiteral("label")) == QLatin1String("5-hour") &&
             windows[0].toMap().value(QStringLiteral("remainingPercent")).toInt() == 70 &&
             windows[0].toMap().value(QStringLiteral("accounts")).toList().size() == 2;
    }, [&] { return QStringLiteral("one Codex 5-hour pool at 70% from two accounts; the page is %1").arg(show(usage(world))); });
  });
  step(QStringLiteral("the account that resets soonest comes first"), [](World& world, const Captures&, const Table&) {
    const QVariantList accounts = at(usage(world), QStringLiteral("limits.pools")).toList().value(0).toMap()
                                      .value(QStringLiteral("windows")).toList().value(0).toMap()
                                      .value(QStringLiteral("accounts")).toList();
    expect(accounts.value(0).toMap().value(QStringLiteral("name")) == QLatin1String("Codex Work"),
           QStringLiteral("Codex Work, which resets in an hour, to come first; the accounts are %1").arg(show(accounts)));
  });
  step(QStringLiteral("limits were checked two minutes ago"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("limits"));
    world.waitFor([&] { return fake(world).limitChecks == 1; }, QStringLiteral("limits to be checked"));
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
    world.setTime(world.now().addSecs(2 * 60));
  });
  step(QStringLiteral("the user opens limits"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("limits"));
  });
  step(QStringLiteral("the limits are not checked again"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fake(world).limitChecks == 1,
           QStringLiteral("limits to be checked once; they were checked %1 times").arg(fake(world).limitChecks));
  });
  step(QStringLiteral("the limits are checked again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).limitChecks == 2; },
                  [&] { return QStringLiteral("limits to be checked twice; they were checked %1 times").arg(fake(world).limitChecks); });
  });
  step(QStringLiteral("the user leaves usage"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  });
  step(QStringLiteral("limits are no longer followed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.node.subscribers(QStringLiteral("config")).size() == fake(world).followedBefore; },
                  [&] { return QStringLiteral("only the shell's own config to be followed; %1 are").arg(world.node.subscribers(QStringLiteral("config")).size()); });
  });
});

}  // namespace
