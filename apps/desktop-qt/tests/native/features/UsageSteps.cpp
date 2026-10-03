// The usage page on the desktop (UsageController), and the MC's side of it:
// the @shared scenarios of features/settings/usage.feature.

#include <algorithm>

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
  QHash<QString, QString> providers;  // by environment; the MC's own is Codex
  QHash<QString, int> versions;       // contract versions other than 5
  QSet<QString> scanning;             // environments that never answer
  QString refusal;                    // the MC's own summary fails so
  QList<FakeMc::Rpc> summaries;
  int rates = 0;
  qsizetype readsAtRefresh = 0;
  int limitChecks = 0;
  int followedBefore = 0;
  QString hoveredDay;                 // the chart's day under the pointer
  // provider.consumeResetCredit: what the MC says, and what it was asked.
  QString creditOutcome = QStringLiteral("reset");
  QList<QJsonObject> redeemed;
};

FakeUsage& fake(World& world) {
  return world.mc.part<FakeUsage>();
}

QString environmentOf(FakeMc& mc, const FakeMc::Rpc& rpc) {
  return rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
}

QString providerOf(FakeMc& mc, const QString& environment) {
  return mc.part<FakeUsage>().providers.value(environment, QStringLiteral("codex"));
}

QJsonObject summary(FakeMc& mc, const QString& environment, const QJsonObject& input) {
  const QString provider = providerOf(mc, environment);
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
      {QStringLiteral("contractVersion"), mc.part<FakeUsage>().versions.value(environment, 5)},
      // An hourly read is as new as the window it was asked over.
      {QStringLiteral("readAt"), input.value(QLatin1String("untilTime")).toString(QStringLiteral("2026-09-23T10:00:00.000Z"))},
      {QStringLiteral("timeZone"), input.value(QLatin1String("timeZone"))},
      {QStringLiteral("sinceDay"), input.value(QLatin1String("sinceDay"))},
      {QStringLiteral("untilDay"), input.value(QLatin1String("untilDay"))},
      {QStringLiteral("buckets"), QJsonArray{bucket}},
      {QStringLiteral("sources"), QJsonArray{source}},
      {QStringLiteral("pricing"), QJsonObject{{QStringLiteral("status"), QStringLiteral("fresh")}}},
  };
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("server.getUsageSummary"), [&mc](const FakeMc::Rpc& rpc) {
    FakeUsage& fake = mc.part<FakeUsage>();
    const QString environment = environmentOf(mc, rpc);
    fake.summaries.append(rpc);
    if (fake.scanning.contains(environment)) return;
    if (!fake.refusal.isEmpty() && environment == mc.environmentId) {
      mc.refuse(rpc, fake.refusal, {{QStringLiteral("_tag"), QStringLiteral("UsageReadError")}});
      return;
    }
    mc.reply(rpc, summary(mc, environment, rpc.payload));
  });
  mc.onRpc(QStringLiteral("server.refreshUsageRates"), [&mc](const FakeMc::Rpc& rpc) {
    ++mc.part<FakeUsage>().rates;
    mc.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("fresh")}});
  });
  mc.onRpc(QStringLiteral("provider.consumeResetCredit"), [&mc](const FakeMc::Rpc& rpc) {
    FakeUsage& fake = mc.part<FakeUsage>();
    fake.redeemed.append(rpc.payload);
    if (fake.creditOutcome == QLatin1String("reset")) {
      // The credit is spent and the windows clear.
      QJsonArray providers = fakeConfig(mc).config.value(QLatin1String("providers")).toArray();
      for (qsizetype i = 0; i < providers.size(); ++i) {
        QJsonObject provider = providers[i].toObject();
        if (provider.value(QLatin1String("instanceId")) != rpc.payload.value(QLatin1String("instanceId"))) continue;
        QJsonObject limits = provider.value(QLatin1String("usageLimits")).toObject();
        limits.insert(QStringLiteral("resetCredits"), QJsonObject{{QStringLiteral("availableCount"), 0}});
        provider.insert(QStringLiteral("usageLimits"), limits);
        providers[i] = provider;
      }
      fakeConfig(mc).config.insert(QStringLiteral("providers"), providers);
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("outcome"), fake.creditOutcome}});
  });
  mc.onRpc(QStringLiteral("server.refreshProviders"), [&mc](const FakeMc::Rpc& rpc) {
    ++mc.part<FakeUsage>().limitChecks;
    // Each environment re-reads its own providers.
    const FakeConfig& config = fakeConfig(mc);
    const QJsonObject& own = config.elsewhere.contains(rpc.environment) ? config.elsewhere[rpc.environment] : config.config;
    mc.reply(rpc, QJsonObject{{QStringLiteral("providers"), own.value(QLatin1String("providers"))}});
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
  const QString provider = providerOf(world.mc, environment);
  world.waitFor([&] { return environmentRow(world, environment).value(QStringLiteral("status")) == QLatin1String("ready") && counted(world, provider); },
                [&] { return QStringLiteral("the usage of %1 to be shown; the page is %2").arg(environment, show(usage(world))); });
}

void link(World& world, const QString& environment, const QString& provider) {
  fake(world).providers.insert(environment, provider);
  world.mc.link(environment);
}

QList<FakeMc::Rpc> summariesFor(World& world, const QString& environment) {
  QList<FakeMc::Rpc> calls;
  for (const FakeMc::Rpc& rpc : fake(world).summaries) {
    if (environmentOf(world.mc, rpc) == environment) calls.append(rpc);
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

// The Codex account's banked reset credits as the page shows them.
QVariantMap credit(World& world) {
  for (const QVariant& pool : at(usage(world), QStringLiteral("limits.pools")).toList()) {
    const QVariantList credits = pool.toMap().value(QStringLiteral("credits")).toList();
    if (pool.toMap().value(QStringLiteral("driver")) == QLatin1String("codex") && !credits.isEmpty()) return credits[0].toMap();
  }
  return {};
}

void setProviders(World& world, const QJsonArray& providers) {
  fakeConfig(world.mc).config.insert(QStringLiteral("providers"), providers);
}

// One hub (a usage-limit source) on this MC, as HalC2.UsageLimitSources publishes it.
void setHub(World& world, const QString& label, const QJsonArray& accounts, const QString& error = {}) {
  QJsonObject hub{{QStringLiteral("id"), QStringLiteral("team-hub")},
                  {QStringLiteral("kind"), QStringLiteral("cliproxy")},
                  {QStringLiteral("label"), label},
                  {QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
                  {QStringLiteral("accounts"), accounts}};
  if (!error.isEmpty()) hub.insert(QStringLiteral("error"), error);
  fakeConfig(world.mc).sources.insert(world.mc.environmentId, QJsonArray{hub});
}

QJsonObject hubAccount(World& world, const QString& email, bool credit) {
  QJsonObject limits{{QStringLiteral("checkedAt"), world.now().toUTC().toString(Qt::ISODateWithMs)},
                     {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 50, world.now().addSecs(2 * 3600))}}};
  if (credit) {
    limits.insert(QStringLiteral("resetCredits"), QJsonObject{{QStringLiteral("availableCount"), 1},
                                                              {QStringLiteral("nextCreditId"), QStringLiteral("credit-1")}});
  }
  QJsonObject account{{QStringLiteral("id"), QStringLiteral("codex-ops.json")},
                      {QStringLiteral("driver"), QStringLiteral("codex")},
                      {QStringLiteral("usageLimits"), limits}};
  if (!email.isEmpty()) account.insert(QStringLiteral("email"), email);
  return account;
}

QVariantList codexAccounts(World& world) {
  for (const QVariant& pool : at(usage(world), QStringLiteral("limits.pools")).toList()) {
    if (pool.toMap().value(QStringLiteral("driver")) != QLatin1String("codex")) continue;
    return pool.toMap().value(QStringLiteral("windows")).toList().value(0).toMap().value(QStringLiteral("accounts")).toList();
  }
  return {};
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
      const QList<FakeMc::Rpc> calls = summariesFor(world, world.mc.environmentId);
      if (calls.isEmpty()) return false;
      for (auto it = expected.begin(); it != expected.end(); ++it) {
        if (calls.last().payload.value(it.key()) != it.value()) return false;
      }
      if (at(usage(world), QStringLiteral("summary.periods")).toList().isEmpty()) return false;
      // The chart has every period of the window, and what was spent falls inside it.
      const QVariantList chart = at(usage(world), QStringLiteral("summary.chart")).toList();
      double charted = 0;
      for (const QVariant& period : chart) {
        for (const QVariant& cost : period.toMap().value(QStringLiteral("costUsd")).toList()) charted += cost.toDouble();
      }
      return chart.size() == (days == 1 ? 24 : days) && qFuzzyCompare(charted, at(usage(world), QStringLiteral("summary.costUsd")).toDouble());
    }, [&] {
      const QList<FakeMc::Rpc> calls = summariesFor(world, world.mc.environmentId);
      return QStringLiteral("usage to be read over %1; it was asked for %2 and shows %3")
          .arg(QString::fromUtf8(QJsonDocument(expected).toJson(QJsonDocument::Compact)),
               calls.isEmpty() ? QStringLiteral("nothing") : QString::fromUtf8(QJsonDocument(calls.last().payload).toJson(QJsonDocument::Compact)),
               show(usage(world)));
    });
  });
  // The chart. Drawing it and following the pointer are UsageChart.qml's
  // (tst_UsagePage.qml); these read what the page is given to draw.
  step(QStringLiteral("Codex and Claude both have usage in the past (?:7 days|24 hours)"), [](World& world, const Captures&, const Table&) {
    // This environment's history is Codex's; another brings Claude's.
    link(world, QStringLiteral("laptop"), QStringLiteral("claude"));
  });
  step(QStringLiteral("the chart draws Codex and Claude over all (\\d+) days"), [](World& world, const Captures& c, const Table&) {
    const QString today = world.now().toLocalTime().date().toString(Qt::ISODate);
    world.waitFor([&] {
      const QVariantList chart = at(usage(world), QStringLiteral("summary.chart")).toList();
      if (chart.size() != c[0].toInt() || chart.last().toMap().value(QStringLiteral("key")) != today) return false;
      if (!counted(world, QStringLiteral("codex")) || !counted(world, QStringLiteral("claude"))) return false;
      return std::all_of(chart.begin(), chart.end(), [](const QVariant& day) {
        return day.toMap().value(QStringLiteral("costUsd")).toList().size() == 2;
      });
    }, [&] { return QStringLiteral("a chart of %1 days ending %2 for Codex and Claude; the page is %3").arg(c[0], today, show(usage(world))); });
  });
  step(QStringLiteral("(\\d+) minutes pass and %1 is slow to answer").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, world.mc.environmentId);
    expectShown(world, c[1]);
    world.setTime(world.now().addSecs(c[0].toInt() * 60));
    fake(world).scanning.insert(c[1]);
  });
  step(QStringLiteral("the chart still draws Codex and Claude"), [](World& world, const Captures&, const Table&) {
    // This environment's new read has landed: the chart starts where its window does.
    QDateTime until = world.now().toUTC();
    until.setTime(QTime(until.time().hour(), until.time().minute()));
    const QString since = until.addSecs(-24 * 60 * 60).toString(Qt::ISODateWithMs);
    const auto chart = [&] { return at(usage(world), QStringLiteral("summary.chart")).toList(); };
    world.waitFor([&] { return !chart().isEmpty() && chart().first().toMap().value(QStringLiteral("key")) == since; },
                  [&] { return QStringLiteral("a chart from %1; the page is %2").arg(since, show(usage(world))); });
    double codex = 0, claude = 0;
    for (const QVariant& hour : chart()) {
      const QVariantList cost = hour.toMap().value(QStringLiteral("costUsd")).toList();
      codex += cost.value(0).toDouble();
      claude += cost.value(1).toDouble();
    }
    expect(codex > 0 && claude > 0, QStringLiteral("both providers on the chart; the page is %1").arg(show(usage(world))));
  });
  step(QStringLiteral("the user hovers a day"), [](World& world, const Captures&, const Table&) {
    fake(world).hoveredDay = world.now().toLocalTime().date().toString(Qt::ISODate);
  });
  step(QStringLiteral("that day's cost for each provider is read out"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& value : at(usage(world), QStringLiteral("summary.chart")).toList()) {
      const QVariantMap day = value.toMap();
      if (day.value(QStringLiteral("key")) != fake(world).hoveredDay) continue;
      // Codex first, as the page lists them; each history spent 1.5 that day.
      expect(day.value(QStringLiteral("costUsd")).toList() == QVariantList{1.5, 1.5},
             QStringLiteral("Codex and Claude to have spent 1.5 each on %1; the day is %2").arg(fake(world).hoveredDay, show(day)));
      return;
    }
    expect(false, QStringLiteral("the chart to have %1; the page is %2").arg(fake(world).hoveredDay, show(usage(world))));
  });
  step(QStringLiteral("%1 is still scanning and %1 has finished").arg(q), [](World& world, const Captures& c, const Table&) {
    link(world, c[0], QStringLiteral("grok"));
    link(world, c[1], QStringLiteral("claude"));
    fake(world).scanning.insert(c[0]);
  });
  step(QStringLiteral("%1 is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    link(world, c[0], QStringLiteral("claude"));
    world.mc.setLinkProblem(c[0], QStringLiteral("unreachable"));
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
  step(QStringLiteral("(?:the usage of %1|%1 usage) is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShown(world, c[0].isEmpty() ? c[1] : c[0]);
  });
  step(QStringLiteral("the usage of this environment is shown"), [](World& world, const Captures&, const Table&) {
    expectShown(world, world.mc.environmentId);
  });
  step(QStringLiteral("%1 is shown as still scanning").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return environmentRow(world, c[0]).value(QStringLiteral("status")) == QLatin1String("scanning") &&
                               usage(world).value(QStringLiteral("scanning")).toBool(); },
                  [&] { return QStringLiteral("%1 to be scanning; the page is %2").arg(c[0], show(usage(world))); });
  });
  step(QStringLiteral("the usage of (this environment|%1) is not counted").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString environment = c.size() < 2 || c[1].isEmpty() ? world.mc.environmentId : c[1];
    // What is counted has landed.
    world.waitFor([&] { return !at(usage(world), QStringLiteral("summary")).isNull(); },
                  [&] { return QStringLiteral("usage to be shown; the page is %1").arg(show(usage(world))); });
    world.sync();
    expect(!counted(world, providerOf(world.mc, environment)),
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
  step(QStringLiteral("the MC cannot read usage"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal = QStringLiteral("Usage read failed (scanFailed): Transcripts could not be scanned.");
  });
  step(QStringLiteral("the MC can read usage again"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal.clear();
  });
  step(QStringLiteral("the user refreshes usage"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !usage(world).value(QStringLiteral("refreshing")).toBool(); }, QStringLiteral("no refresh to be running"));
    fake(world).readsAtRefresh = summariesFor(world, world.mc.environmentId).size();
    world.bridge().dispatch(QStringLiteral("usage.refresh"), {});
  });
  step(QStringLiteral("the MC is asked for the latest model prices"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).rates == 1; },
                  [&] { return QStringLiteral("prices to be fetched once; they were fetched %1 times").arg(fake(world).rates); });
  });
  step(QStringLiteral("usage is read again"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = fake(world).readsAtRefresh;
    world.waitFor([&] { return summariesFor(world, world.mc.environmentId).size() == before + 1 &&
                               !usage(world).value(QStringLiteral("refreshing")).toBool(); },
                  [&] { return QStringLiteral("usage to be read once more than %1 times; it was read %2 times")
                            .arg(before).arg(summariesFor(world, world.mc.environmentId).size()); });
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
    fake(world).followedBefore = world.mc.subscribers(QStringLiteral("config")).size();
    showUsage(world, QStringLiteral("limits"));
    world.waitFor([&] { return world.mc.subscribers(QStringLiteral("config")).size() > fake(world).followedBefore; },
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
    world.waitFor([&] { return world.mc.subscribers(QStringLiteral("config")).size() == fake(world).followedBefore; },
                  [&] { return QStringLiteral("only the shell's own config to be followed; %1 are").arg(world.mc.subscribers(QStringLiteral("config")).size()); });
  });
  // Reset credits.
  step(QStringLiteral("Codex has a reset credit banked"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    setProviders(world, {codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"),
                               {{QStringLiteral("checkedAt"), now.toUTC().toString(Qt::ISODateWithMs)},
                                {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 90, now.addSecs(3600))}},
                                {QStringLiteral("resetCredits"),
                                 QJsonObject{{QStringLiteral("availableCount"), 1},
                                             {QStringLiteral("nextExpiresAt"), now.addDays(27).toUTC().toString(Qt::ISODateWithMs)}}}})});
  });
  step(QStringLiteral("(no rate-limit window is in use|the account has no credit left|the credit was redeemed on another device)"),
       [](World& world, const Captures& c, const Table&) {
         fake(world).creditOutcome = c[0].startsWith(QLatin1String("no rate")) ? QStringLiteral("nothingToReset")
                                     : c[0].startsWith(QLatin1String("the account")) ? QStringLiteral("noCredit")
                                                                                     : QStringLiteral("alreadyRedeemed");
       });
  step(QStringLiteral("limits show (\\d+) reset credits? banked for Codex"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return credit(world).value(QStringLiteral("available")).toInt() == c[0].toInt(); },
                  [&] { return QStringLiteral("%1 banked; the credits are %2").arg(c[0], show(credit(world))); });
  });
  step(QStringLiteral("the user uses the reset credit and confirms"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("limits"));
    world.waitFor([&] { return credit(world).value(QStringLiteral("available")).toInt() > 0; },
                  [&] { return QStringLiteral("a banked credit to spend; the page is %1").arg(show(usage(world))); });
    world.bridge().dispatch(QStringLiteral("usage.resetCredit"), QVariantMap{{QStringLiteral("key"), credit(world).value(QStringLiteral("key"))}});
  });
  step(QStringLiteral("the credit is spent on the Codex instance"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject>& redeemed = fake(world).redeemed;
    expect(redeemed.size() == 1 && redeemed[0].value(QLatin1String("instanceId")) == QLatin1String("codex"),
           QStringLiteral("one redemption on the codex instance; the MC was asked %1 times").arg(redeemed.size()));
  });
  step(QStringLiteral("the credit is still banked"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return credit(world).value(QStringLiteral("available")).toInt() == 1; },
                  [&] { return QStringLiteral("one credit banked; the credits are %1").arg(show(credit(world))); });
    expect(fake(world).redeemed.isEmpty(), QStringLiteral("no credit to be spent"));
  });

  // providers/usage-limits.feature: the desktop half.
  step(QStringLiteral("a connected environment with Codex and Claude signed in with subscriptions"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    const QDateTime now = world.now();
    const QJsonObject limits{{QStringLiteral("checkedAt"), now.toUTC().toString(Qt::ISODateWithMs)},
                             {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 40, now.addSecs(3600))}}};
    QJsonObject claude = codex(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), QStringLiteral("sam@example.com"), limits);
    claude.insert(QStringLiteral("driver"), QStringLiteral("claudeAgent"));
    setProviders(world, {codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"), limits), claude});
  });
  step(QStringLiteral("the same Codex account is signed in on two environments and reported by a hub"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    const auto limits = [&](double used, int minutesAgo) {
      return QJsonObject{{QStringLiteral("checkedAt"), now.addSecs(-60 * minutesAgo).toUTC().toString(Qt::ISODateWithMs)},
                         {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), used, now.addSecs(3600)),
                                                                QJsonObject{{QStringLiteral("id"), QStringLiteral("weekly")},
                                                                            {QStringLiteral("kind"), QStringLiteral("weekly")},
                                                                            {QStringLiteral("label"), QStringLiteral("Weekly")},
                                                                            {QStringLiteral("usedPercent"), used / 2},
                                                                            {QStringLiteral("resetsAt"), now.addDays(3).toUTC().toString(Qt::ISODateWithMs)},
                                                                            {QStringLiteral("windowDurationMins"), 10080}}}}};
    };
    setProviders(world, {codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"), limits(40, 3))});
    fakeConfig(world.mc).elsewhere.insert(
        QStringLiteral("Studio"),
        QJsonObject{{QStringLiteral("providers"),
                     QJsonArray{codex(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("sam@example.com"), limits(60, 1))}}});
    world.mc.link(QStringLiteral("Studio"));
    // The hub's read is the oldest, the other environment's the freshest.
    QJsonObject account = hubAccount(world, QStringLiteral("sam@example.com"), false);
    QJsonObject read = account.value(QLatin1String("usageLimits")).toObject();
    read.insert(QStringLiteral("checkedAt"), now.addSecs(-5 * 60).toUTC().toString(Qt::ISODateWithMs));
    account.insert(QStringLiteral("usageLimits"), read);
    setHub(world, QStringLiteral("Team hub"), {account});
  });
  step(QStringLiteral("the user opens Limits"), [](World& world, const Captures&, const Table&) {
    showUsage(world, QStringLiteral("limits"));
  });
  step(QStringLiteral("that account is counted once in each window"), [](World& world, const Captures&, const Table&) {
    const auto pool = [&] {
      for (const QVariant& found : at(usage(world), QStringLiteral("limits.pools")).toList()) {
        if (found.toMap().value(QStringLiteral("driver")) == QLatin1String("codex")) return found.toMap();
      }
      return QVariantMap();
    };
    // The other environment's read, the freshest, shows once both have reported.
    world.waitFor([&] {
      const QVariantList windows = pool().value(QStringLiteral("windows")).toList();
      return windows.size() == 2 && windows[0].toMap().value(QStringLiteral("remainingPercent")).toInt() == 40;
    }, [&] { return QStringLiteral("the freshest read's two Codex windows; the page is %1").arg(show(usage(world))); });
    world.sync();
    for (const QVariant& window : pool().value(QStringLiteral("windows")).toList()) {
      expect(window.toMap().value(QStringLiteral("accounts")).toList().size() == 1,
             QStringLiteral("one account in %1; the pool is %2").arg(window.toMap().value(QStringLiteral("label")).toString(), show(pool())));
    }
  });

  // Usage-limit sources (hubs).
  step(QStringLiteral("an MC the user administers"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
  });
  step(QStringLiteral("the hub %1 reports a Codex account").arg(q), [](World& world, const Captures& c, const Table&) {
    setHub(world, c[0], {hubAccount(world, {}, false)});
  });
  step(QStringLiteral("the hub %1 reports the Codex account %1( with a banked reset credit)?").arg(q),
       [](World& world, const Captures& c, const Table&) {
         setHub(world, c[0], {hubAccount(world, c[1], c.size() > 2 && !c[2].isEmpty())});
       });
  step(QStringLiteral("the hub %1 cannot be read: %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setHub(world, c[0], {}, c[1]);
  });
  step(QStringLiteral("Codex is signed in here as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setProviders(world, {codex(QStringLiteral("codex"), QStringLiteral("Codex"), c[0],
                               {{QStringLiteral("checkedAt"), world.now().addSecs(-60).toUTC().toString(Qt::ISODateWithMs)},
                                {QStringLiteral("windows"), QJsonArray{limitsWindow(QStringLiteral("5-hour"), 40, world.now().addSecs(3600))}}})});
  });
  step(QStringLiteral("Codex limits include the account %1 of the hub").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& account : codexAccounts(world)) {
        if (account.toMap().value(QStringLiteral("name")) == c[0]) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the hub's %1 in Codex limits; the page is %2").arg(c[0], show(usage(world))); });
  });
  step(QStringLiteral("Codex limits count one account"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !codexAccounts(world).isEmpty(); },
                  [&] { return QStringLiteral("Codex limits; the page is %1").arg(show(usage(world))); });
    world.sync();
    expect(codexAccounts(world).size() == 1, QStringLiteral("one Codex account; they are %1").arg(show(codexAccounts(world))));
  });
  // A hub the user added, its key sealed on the MC, its account in limits.
  step(QStringLiteral("a hub %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& config = fakeConfig(world.mc);
    config.settings.insert(QStringLiteral("usageLimitSources"),
                           QJsonObject{{QStringLiteral("team-hub"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("cliproxy")},
                                                                              {QStringLiteral("label"), c[0]},
                                                                              {QStringLiteral("url"), QStringLiteral("https://hub.example")},
                                                                              {QStringLiteral("managementKey"), QStringLiteral("••••••")},
                                                                              {QStringLiteral("enabled"), true}}}});
    config.secrets.insert(QStringLiteral("hub/team-hub"), QStringLiteral("hub-key"));
    setHub(world, c[0], {hubAccount(world, {}, false)});
    showUsage(world, QStringLiteral("limits"));
    world.waitFor([&] { return !codexAccounts(world).isEmpty(); },
                  [&] { return QStringLiteral("the hub's account in limits; the page is %1").arg(show(usage(world))); });
  });
  step(QStringLiteral("its accounts leave limits"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return codexAccounts(world).isEmpty(); },
                  [&] { return QStringLiteral("no hub account in limits; the page is %1").arg(show(usage(world))); });
  });
  step(QStringLiteral("the credit is spent through the hub"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !fake(world).redeemed.isEmpty(); }, QStringLiteral("a credit to be spent"));
    const QJsonObject input = fake(world).redeemed.first();
    expect(input.value(QLatin1String("sourceId")) == QLatin1String("team-hub") &&
               input.value(QLatin1String("accountId")) == QLatin1String("codex-ops.json") &&
               input.value(QLatin1String("creditId")) == QLatin1String("credit-1"),
           QStringLiteral("the hub's credit to be spent; the MC was asked %1").arg(QString::fromUtf8(QJsonDocument(input).toJson(QJsonDocument::Compact))));
  });
});

}  // namespace
