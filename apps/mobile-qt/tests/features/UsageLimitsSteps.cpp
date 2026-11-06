// Subscription limits on the phone (features/providers/usage-limits.feature):
// Usage → Limits from home, the /usage-limits answer over the composer, and
// the Subscription usage widget on the home screen (FakeWidgetSystem.h). The
// providers are ComposerSteps' fake config (FakeThreads.h); limit checks are
// UpdateSteps' `server.refreshProviders`.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const QDateTime kNow = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
const QString kEmail = QStringLiteral("sam@example.com");

QString at(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

QJsonObject limitsWindow(const QString& kind, const QString& label, double used, const QDateTime& resetsAt) {
  const bool session = kind == QLatin1String("session");
  return {{S("id"), session ? S("five-hour") : S("weekly")},
          {S("kind"), kind},
          {S("label"), label},
          {S("usedPercent"), used},
          {S("resetsAt"), at(resetsAt)},
          {S("windowDurationMins"), session ? 300 : 10080}};
}

// A subscription's session window `used` percent spent, and its weekly one half that.
QJsonObject limits(double used, const QDateTime& checkedAt) {
  return {{S("checkedAt"), at(checkedAt)},
          {S("windows"), QJsonArray{limitsWindow(S("session"), S("5-hour"), used, kNow.addSecs(3600)),
                                    limitsWindow(S("weekly"), S("Weekly"), used / 2, kNow.addDays(3))}}};
}

QJsonObject provider(const QString& driver, const QString& name, const QJsonObject& usageLimits) {
  return {{S("instanceId"), driver},
          {S("driver"), driver},
          {S("displayName"), name},
          {S("enabled"), true},
          {S("installed"), true},
          {S("status"), S("ready")},
          {S("auth"), QJsonObject{{S("status"), S("authenticated")}, {S("email"), kEmail}}},
          {S("usageLimits"), usageLimits}};
}

QJsonArray background() {
  return {provider(S("codex"), S("Codex"), limits(40, kNow)), provider(S("claudeAgent"), S("Claude"), limits(20, kNow))};
}

QVariantMap usage(World& world) {
  return world.state(S("usage")).toMap();
}

QString screenTexts(World& world) {
  return world.texts().join(S(" | "));
}

int limitChecks(World& world) {
  world.sync();
  int count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("server.refreshProviders")) ++count;
  }
  return count;
}

void goHome(World& world) {
  world.foreground();
  const auto home = [&] { return world.state(S("route")).toMap().value(S("kind")) == QLatin1String("home") && world.find(S("homeScreen")) != nullptr; };
  for (int tries = 0; tries < 6 && !home(); ++tries) {
    world.back();
    world.sync();
  }
  world.waitFor(home, [&] { return S("the home screen; the screen says: %1").arg(screenTexts(world)); });
}

bool limitsShown(World& world) {
  const QVariantMap page = usage(world);
  return page.value(S("open")).toBool() && page.value(S("metric")) == QLatin1String("limits") && world.find(S("usageScreen")) != nullptr;
}

// From home, the user opens Usage and its Limits.
void openLimits(World& world) {
  goHome(world);
  world.tap(S("usage"));
  world.item(S("usageScreen"));
  world.tap(S("usageMetric_limits"));
  world.waitFor([&] { return limitsShown(world); }, [&] { return S("Limits; usage is %1").arg(show(usage(world))); });
}

QVariantMap pool(World& world, const QString& driver) {
  for (const QVariant& found : at(usage(world), S("limits.pools")).toList()) {
    if (found.toMap().value(S("driver")) == driver) return found.toMap();
  }
  return {};
}

// What the widget draws of `driver`; empty when it leaves the provider out.
QJsonObject drawn(World& world, const QString& driver) {
  for (const QJsonValue& entry : world.widgets->drawn().value(QLatin1String("providers")).toArray()) {
    if (entry.toObject().value(QLatin1String("driver")) == driver) return entry.toObject();
  }
  return {};
}

// The driver of the provider the scenario calls `name`.
QString driverOf(const QString& name) {
  return name == QLatin1String("Claude") ? S("claudeAgent") : name.toLower();
}

QStringList kinds(const QJsonObject& provider) {
  QStringList found;
  for (const QJsonValue& window : provider.value(QLatin1String("windows")).toArray()) found.append(window.toObject().value(QLatin1String("kind")).toString());
  return found;
}

// The user put the widget on the home screen and came back to the app.
void placeWidget(World& world) {
  if (world.widgets->count > 0) return;
  world.widgets->count = 1;
  world.background();
  world.foreground();
  world.waitFor([&] { return world.state(S("usageWidget")).toMap().value(S("placed")).toBool(); },
                [&] { return S("the app to know of the widget; it says %1").arg(show(world.state(S("usageWidget")))); });
}

// /usage-limits: Codex with a subscription and the command, Antigravity with neither.
QJsonArray commandProviders() {
  const auto entry = [](const QString& id, const QString& name, const QString& slug) {
    return QJsonObject{{S("instanceId"), id}, {S("driver"), id}, {S("displayName"), name}, {S("enabled"), true}, {S("installed"), true},
                       {S("status"), S("ready")}, {S("models"), QJsonArray{QJsonObject{{S("slug"), slug}, {S("name"), slug}}}}};
  };
  QJsonObject codex = entry(S("codex"), S("Codex"), S("gpt-5"));
  codex.insert(S("usageLimits"), QJsonObject{{S("checkedAt"), at(kNow)},
                                             {S("windows"), QJsonArray{limitsWindow(S("session"), S("5-hour"), 40, kNow.addSecs(3600))}}});
  codex.insert(S("slashCommands"), QJsonArray{QJsonObject{{S("name"), S("usage-limits")}, {S("description"), S("Show this provider's usage limits")}}});
  return {codex, entry(S("antigravity"), S("Antigravity"), S("gemini-pro"))};
}

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

void openThreadOn(World& world, const QString& title, const QString& instanceId, const QString& slug) {
  offerProviders(world.mc, commandProviders());
  world.thread = haveThread(world, title);
  updateRow(world.mc, world.thread, {{S("modelSelection"), QJsonObject{{S("instanceId"), instanceId}, {S("model"), slug}}}});
  goHome(world);
  openThread(world, title);
  world.waitFor([&] { return composer(world).value(S("selectedModel")) == slug; },
                [&] { return S("the composer on %1; it shows %2").arg(slug, show(composer(world))); });
  // The phone told the environment it answers the command itself.
  bool told = false;
  for (const QJsonObject& sub : std::as_const(world.mc.subscriptions)) {
    const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("config") && shape.value(QLatin1String("usageLimitsCommand")).toBool()) told = true;
  }
  expect(told, S("no config subscription said the phone answers /usage-limits"));
}

int dispatches(World& world) {
  world.sync();
  int count = 0;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) ++count;
  }
  return count;
}

// The user types `text` into the composer and sends it.
void send(World& world, const QString& text) {
  QQuickItem* input = world.item(S("input"));
  world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
  world.tap(input);
  world.type(text);
  world.tap(S("primaryAction"));
  world.sync();
}

const Steps steps([] {
  // The Background: the phone is paired, and the environment's Codex and
  // Claude report a session and a weekly window each.
  step(S("a connected environment with Codex and Claude signed in with subscriptions"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    threadList(world);
    world.setTime(kNow);
    offerProviders(world.mc, background());
  });

  // Pooling.
  step(S("the same Codex account is signed in on two environments and reported by a hub"), [](World& world, const Captures&, const Table&) {
    QJsonArray own = background();
    own[0] = provider(S("codex"), S("Codex"), limits(40, kNow.addSecs(-3 * 60)));
    offerProviders(world.mc, own);
    offerProvidersOn(world.mc, S("Studio"), {provider(S("codex"), S("Codex"), limits(60, kNow.addSecs(-60)))});
    world.mc.join(S("Studio"));
    // The hub's read is the oldest, the other environment's the freshest.
    const QJsonObject account{{S("id"), S("codex-ops.json")},
                              {S("driver"), S("codex")},
                              {S("email"), kEmail},
                              {S("usageLimits"), QJsonObject{{S("checkedAt"), at(kNow.addSecs(-5 * 60))},
                                                             {S("windows"), QJsonArray{limitsWindow(S("session"), S("5-hour"), 50, kNow.addSecs(2 * 3600))}}}}};
    offerLimitSources(world.mc, world.mc.environmentId,
                      {QJsonObject{{S("id"), S("team-hub")}, {S("kind"), S("cliproxy")}, {S("label"), S("Team hub")}, {S("checkedAt"), at(kNow)},
                                   {S("accounts"), QJsonArray{account}}}});
  });
  step(S("the user opens Limits(?: again)?"), [](World& world, const Captures&, const Table&) { openLimits(world); });
  step(S("that account is counted once in each window"), [](World& world, const Captures&, const Table&) {
    // The other environment's read, the freshest, shows once both have reported.
    world.waitFor([&] {
      const QVariantList windows = pool(world, S("codex")).value(S("windows")).toList();
      return windows.size() == 2 && windows[0].toMap().value(S("remainingPercent")).toInt() == 40;
    }, [&] { return S("the freshest read's two Codex windows; usage is %1").arg(show(usage(world))); });
    world.sync();
    for (const QVariant& window : pool(world, S("codex")).value(S("windows")).toList()) {
      expect(window.toMap().value(S("accounts")).toList().size() == 1,
             S("one account in %1; the pool is %2").arg(window.toMap().value(S("label")).toString(), show(pool(world, S("codex")))));
    }
    expect(world.shows(S("40% left")), S("the pooled window is not on screen; it says: %1").arg(screenTexts(world)));
  });

  // Throttling.
  step(S("the user opened Limits two minutes ago"), [](World& world, const Captures&, const Table&) {
    openLimits(world);
    world.waitFor([&] { return limitChecks(world) == 1; }, [&] { return S("limits to be checked once; they were checked %1 times").arg(limitChecks(world)); });
    goHome(world);
    world.setTime(kNow.addSecs(2 * 60));
  });
  step(S("the environment is not checked again yet"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(limitChecks(world) == 1, S("limits to be checked once; they were checked %1 times").arg(limitChecks(world)));
  });

  // Grok before its first metered use.
  step(S("Grok is signed in with a subscription and has not used any metered credit yet"), [](World& world, const Captures&, const Table&) {
    QJsonArray providers = background();
    providers.append(provider(S("grok"), S("Grok"), QJsonObject{{S("checkedAt"), at(kNow)}, {S("windows"), QJsonArray()}}));
    offerProviders(world.mc, providers);
  });
  step(S("Grok's account is listed with the notice %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString notice = S("Grok: ") + c[0];
    world.waitFor([&] { return at(usage(world), S("limits.notices")).toStringList().contains(notice); },
                  [&] { return S("the notice %1; usage is %2").arg(notice, show(usage(world))); });
    expect(world.shows(notice), S("the notice is not on screen; it says: %1").arg(screenTexts(world)));
  });
  step(S("it is not reported as not supported"), [](World& world, const Captures&, const Table&) {
    for (const QString& notice : at(usage(world), S("limits.notices")).toStringList()) {
      expect(!notice.contains(S("not supported"), Qt::CaseInsensitive), S("Grok is reported so: %1").arg(notice));
    }
  });

  // /usage-limits.
  step(S("a Codex thread"), [](World& world, const Captures&, const Table&) { openThreadOn(world, S("Codex limits"), S("codex"), S("gpt-5")); });
  step(S("an Antigravity thread"), [](World& world, const Captures&, const Table&) {
    openThreadOn(world, S("Antigravity work"), S("antigravity"), S("gemini-pro"));
  });
  step(S("the user sends %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { send(world, c[0]); });
  step(S("Codex's windows are shown above the composer without running the agent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !composer(world).value(S("usageLimits")).isNull(); },
                  [&] { return S("the limits over the composer; it shows %1").arg(show(composer(world))); });
    const QVariantMap limits = composer(world).value(S("usageLimits")).toMap();
    const QVariantMap window = limits.value(S("windows")).toList().value(0).toMap();
    expect(limits.value(S("provider")) == QLatin1String("Codex") && window.value(S("label")) == QLatin1String("5-hour") &&
               window.value(S("remainingPercent")).toDouble() == 60,
           S("the composer shows %1").arg(show(limits)));
    world.waitFor([&] { return world.shows(S("60% left")) && world.shows(S("5-hour")); },
                  [&] { return S("the limits on screen; it says: %1").arg(screenTexts(world)); });
    expect(dispatches(world) == 0 && composer(world).value(S("text")).toString().isEmpty(), S("the command went to the agent"));
  });
  step(S("they close when the user sends the next message"), [](World& world, const Captures&, const Table&) {
    send(world, S("Add a tax line"));
    world.waitFor([&] { return dispatches(world) == 1; }, S("the message to reach the MC"));
    expect(composer(world).value(S("usageLimits")).isNull(), S("the limits stayed open"));
    // Asked for again, they also close when dismissed.
    send(world, S("/usage-limits"));
    world.waitFor([&] { return !composer(world).value(S("usageLimits")).isNull(); }, S("the limits to open again"));
    world.tap(S("composerUsageLimitsDismiss"));
    world.waitFor([&] { return composer(world).value(S("usageLimits")).isNull(); }, S("the limits to close when dismissed"));
  });
  step(S("the user opens the composer's command menu"), [](World& world, const Captures&, const Table&) {
    QQuickItem* input = world.item(S("input"));
    world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
    world.tap(input);
    world.type(S("/"));
    world.waitFor([&] { return !composer(world).value(S("suggestions")).toList().isEmpty(); },
                  [&] { return S("the command menu; the composer shows %1").arg(show(composer(world))); });
  });
  step(S("%1 is not offered").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QStringList offered;
    for (const QVariant& item : composer(world).value(S("suggestions")).toList()) offered.append(item.toMap().value(S("label")).toString());
    expect(offered.contains(S("/model")) && !offered.contains(c[0]), S("the menu offers %1").arg(offered.join(S(", "))));
    expect(!world.shows(c[0], true), S("the menu shows %1").arg(c[0]));
  });

  // The Subscription usage widget.
  step(S("the user added the Subscription usage widget"), [](World& world, const Captures&, const Table&) { placeWidget(world); });
  step(S("the user looks at the home screen"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !drawn(world, S("codex")).isEmpty() && !drawn(world, S("claudeAgent")).isEmpty(); },
                  [&] { return S("the widget to have Codex and Claude; it draws %1").arg(show(world.widgets->drawn().toVariantMap())); });
    world.background();
  });
  step(S("remaining Codex and Claude quotas are shown"), [](World& world, const Captures&, const Table&) {
    const auto remaining = [&](const QString& driver) {
      QList<int> found;
      for (const QJsonValue& window : drawn(world, driver).value(QLatin1String("windows")).toArray()) found.append(window.toObject().value(QLatin1String("remainingPercent")).toInt());
      return found;
    };
    expect(remaining(S("codex")) == QList<int>{60, 80} && remaining(S("claudeAgent")) == QList<int>{80, 90},
           S("the widget draws %1").arg(show(world.widgets->drawn().toVariantMap())));
    expect(drawn(world, S("claudeAgent")).value(QLatin1String("label")).toString().startsWith(QLatin1String("Claude")),
           S("Claude is drawn as %1").arg(drawn(world, S("claudeAgent")).value(QLatin1String("label")).toString()));
  });
  step(S("tapping it opens Limits"), [](World& world, const Captures&, const Table&) {
    const QString link = world.widgets->drawn().value(QLatin1String("url")).toString();
    world.foreground();
    world.followLink(link);
    world.waitFor([&] { return limitsShown(world); }, [&] { return S("Limits from %1; usage is %2").arg(link, show(usage(world))); });
  });
  step(S("the user sets the widget to show only the weekly window for (\\w+)"), [](World& world, const Captures& c, const Table&) {
    placeWidget(world);
    openLimits(world);
    const QString driver = driverOf(c[0]);
    world.waitFor([&] {
      for (const QVariant& entry : world.state(S("usageWidget")).toMap().value(S("providers")).toList()) {
        if (entry.toMap().value(S("driver")) == driver) return true;
      }
      return false;
    }, [&] { return S("%1 among the widget's providers; they are %2").arg(c[0], show(world.state(S("usageWidget")))); });
    world.tap(S("widgetShow_%1_weekly").arg(driver));
    world.background();
  });
  step(S("the widget shows (\\w+)'s weekly window only"), [](World& world, const Captures& c, const Table&) {
    const QString driver = driverOf(c[0]);
    world.waitFor([&] { return kinds(drawn(world, driver)) == QStringList{S("weekly")}; },
                  [&] { return S("only %1's weekly window; the widget draws %2").arg(c[0], show(world.widgets->drawn().toVariantMap())); });
    expect(kinds(drawn(world, S("codex"))) == (QStringList{S("session"), S("weekly")}),
           S("Codex kept both windows; it draws %1").arg(kinds(drawn(world, S("codex"))).join(S(", "))));
  });
});

}  // namespace
