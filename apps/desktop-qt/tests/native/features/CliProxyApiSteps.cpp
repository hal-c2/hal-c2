// CLIProxyAPI's page (features/plugins/cliproxyapi.feature): its real package from
// plugins/cliproxyapi, drawn by the desktop against a fake of its MC part that
// answers `status`, `signIn`, `finishSignIn` and `retry` as the MC part does and
// publishes `status`, `accounts`, `usage`, `keys` and `logs`. The proxy itself is
// the MC's scenarios' (apps/server-ex/test/steps/plugins/cliproxyapi_steps.exs).

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQuickItem>
#include <QQuickWindow>

#include "Harness.h"
#include "Plugins.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("cliproxyapi");
const QString kSignInUrl = QStringLiteral("https://claude.ai/oauth/authorize?code=true&state=st-1");

QString package() { return QDir(QStringLiteral(HAL_C2_FEATURES_DIR "/../plugins/cliproxyapi")).absolutePath(); }

// The MC part's state: the proxy's, its accounts and the sign-in under way.
struct FakeCliProxyApi {
  QString mode = QStringLiteral("run");
  QString state = QStringLiteral("running");
  QString message;
  QString address = QStringLiteral("http://127.0.0.1:8317");
  // Why the proxy gives no usage, when it gives none.
  QString usageNote;
  // Why the host did not add Codex via CLIProxyAPI, when it did not.
  QString codexTaken;
  QString email;
  QJsonValue signIn = QJsonValue::Null;
  QString pasted;
};

FakeCliProxyApi& state(World& world) { return world.mc.part<FakeCliProxyApi>(); }

QJsonObject manifest() {
  QFile file(QDir(package()).filePath(QStringLiteral("plugin.json")));
  expect(file.open(QIODevice::ReadOnly), QStringLiteral("%1 cannot be read").arg(file.fileName()));
  return QJsonDocument::fromJson(file.readAll()).object();
}

// The plugin as the MC lists it: its manifest, running with its permissions granted.
QJsonObject entry(const QJsonObject& manifest) {
  QJsonArray permissions;
  QJsonObject settings;
  for (const QJsonValue& each : manifest.value(QLatin1String("permissions")).toArray()) {
    QJsonObject permission = each.toObject();
    permission.insert(QStringLiteral("label"), permission.value(QLatin1String("id")));
    permission.insert(QStringLiteral("granted"), true);
    permissions.append(permission);
  }
  for (const QJsonValue& each : manifest.value(QLatin1String("settings")).toArray()) {
    settings.insert(each.toObject().value(QLatin1String("key")).toString(), each.toObject().value(QLatin1String("default")));
  }
  return {{QStringLiteral("id"), kId},
          {QStringLiteral("name"), manifest.value(QLatin1String("name"))},
          {QStringLiteral("version"), manifest.value(QLatin1String("version"))},
          {QStringLiteral("description"), manifest.value(QLatin1String("description"))},
          {QStringLiteral("author"), manifest.value(QLatin1String("author"))},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("error"), QJsonValue::Null},
          {QStringLiteral("lastError"), QJsonValue::Null},
          {QStringLiteral("revision"), QStringLiteral("1")},
          {QStringLiteral("runsCode"), true},
          {QStringLiteral("permissions"), permissions},
          {QStringLiteral("settingsSchema"), manifest.value(QLatin1String("settings"))},
          {QStringLiteral("settings"), settings},
          {QStringLiteral("contributes"), manifest.value(QLatin1String("contributes"))}};
}

QJsonObject instance(const QString& name, const QString& label) {
  return {{QStringLiteral("name"), name},
          {QStringLiteral("instanceId"), QStringLiteral("plugin_cliproxyapi_") + name},
          {QStringLiteral("label"), label},
          {QStringLiteral("state"), QStringLiteral("added")}};
}

QJsonObject status(World& world) {
  const FakeCliProxyApi& fake = state(world);
  QJsonObject codex = instance(QStringLiteral("codex"), QStringLiteral("Codex via CLIProxyAPI"));
  if (!fake.codexTaken.isEmpty()) {
    codex.insert(QStringLiteral("state"), QStringLiteral("taken"));
    codex.insert(QStringLiteral("message"), fake.codexTaken);
  }
  return {{QStringLiteral("mode"), fake.mode},
          {QStringLiteral("state"), fake.state},
          {QStringLiteral("message"), fake.message},
          {QStringLiteral("pid"), 4242},
          {QStringLiteral("restarts"), 0},
          {QStringLiteral("output"), QJsonArray()},
          {QStringLiteral("version"), QStringLiteral("8.0.79")},
          {QStringLiteral("latest"), QJsonValue::Null},
          {QStringLiteral("binary"), QStringLiteral("/usr/bin/cli-proxy-api")},
          {QStringLiteral("source"), QStringLiteral("path")},
          {QStringLiteral("address"), fake.address},
          {QStringLiteral("error"), QJsonValue::Null},
          {QStringLiteral("instances"), QJsonArray{instance(QStringLiteral("claude"), QStringLiteral("Claude via CLIProxyAPI")),
                                                   codex}}};
}

QString accountName(const QString& email) { return QStringLiteral("claude-%1.json").arg(email); }

QJsonArray accounts(World& world) {
  const QString& email = state(world).email;
  if (email.isEmpty()) return {};
  return {QJsonObject{{QStringLiteral("id"), accountName(email)},
                      {QStringLiteral("name"), accountName(email)},
                      {QStringLiteral("provider"), QStringLiteral("claude")},
                      {QStringLiteral("email"), email},
                      {QStringLiteral("status"), QStringLiteral("active")},
                      {QStringLiteral("message"), QString()},
                      {QStringLiteral("disabled"), false},
                      {QStringLiteral("unavailable"), false}}};
}

QJsonArray usage(World& world) {
  const QString& email = state(world).email;
  if (email.isEmpty()) return {};
  return {QJsonObject{{QStringLiteral("day"), QStringLiteral("2026-11-19")},
                      {QStringLiteral("account"), email},
                      {QStringLiteral("model"), QStringLiteral("claude-sonnet-4")},
                      {QStringLiteral("requests"), 2},
                      {QStringLiteral("failed"), 1},
                      {QStringLiteral("inputTokens"), 150},
                      {QStringLiteral("outputTokens"), 25},
                      {QStringLiteral("cachedTokens"), 0},
                      {QStringLiteral("reasoningTokens"), 0},
                      {QStringLiteral("totalTokens"), 175}}};
}

QJsonArray keys(World& world) {
  if (state(world).email.isEmpty()) return {};
  return {QJsonObject{{QStringLiteral("provider"), QStringLiteral("claude")},
                      {QStringLiteral("id"), QStringLiteral("k1")},
                      {QStringLiteral("name"), QString()},
                      {QStringLiteral("baseUrl"), QString()},
                      {QStringLiteral("keys"), QJsonArray{QStringLiteral("sk-a…mnop")}}}};
}

QJsonArray logs(World& world) {
  if (state(world).email.isEmpty()) return {};
  return {QStringLiteral("POST /v1/messages 200")};
}

// What `status`, `refresh` and `retry` answer: everything the page shows.
QJsonObject view(World& world) {
  return {{QStringLiteral("status"), status(world)}, {QStringLiteral("accounts"), accounts(world)},
          {QStringLiteral("signIn"), state(world).signIn},  {QStringLiteral("usage"), usage(world)},
          {QStringLiteral("usageNote"), state(world).usageNote},
          {QStringLiteral("logs"), logs(world)},            {QStringLiteral("keys"), keys(world)}};
}

void publish(World& world) {
  FakePluginPart& part = fakePluginPart(world, kId);
  part.topics.insert(QStringLiteral("status"), status(world));
  part.topics.insert(QStringLiteral("accounts"), QJsonObject{{QStringLiteral("accounts"), accounts(world)}, {QStringLiteral("signIn"), state(world).signIn}});
  part.topics.insert(QStringLiteral("usage"), QJsonObject{{QStringLiteral("rows"), usage(world)}, {QStringLiteral("days"), 7}, {QStringLiteral("note"), state(world).usageNote}});
  part.topics.insert(QStringLiteral("keys"), QJsonObject{{QStringLiteral("keys"), keys(world)}});
  part.topics.insert(QStringLiteral("logs"), QJsonObject{{QStringLiteral("lines"), logs(world)}});
  for (const QString& topic : {QStringLiteral("status"), QStringLiteral("accounts"), QStringLiteral("usage"), QStringLiteral("keys"), QStringLiteral("logs")})
    publishTopic(world, kId, topic);
}

// The calls the page makes, answered as the MC part answers them.
void answer(World& world, const FakeMc::Rpc& rpc) {
  FakeCliProxyApi& fake = state(world);
  const QString method = rpc.payload.value(QLatin1String("method")).toString();
  const QJsonObject input = rpc.payload.value(QLatin1String("input")).toObject();
  if (method == QLatin1String("status") || method == QLatin1String("refresh")) return world.mc.reply(rpc, view(world));
  if (method == QLatin1String("retry")) {
    fake.state = QStringLiteral("running");
    fake.message.clear();
    world.mc.reply(rpc, view(world));
    return publish(world);
  }
  if (fake.state != QLatin1String("running")) return world.mc.refuse(rpc, QStringLiteral("CLIProxyAPI is not running."));
  if (method == QLatin1String("signIn")) {
    fake.signIn = QJsonObject{{QStringLiteral("provider"), input.value(QLatin1String("provider"))},
                              {QStringLiteral("state"), QStringLiteral("st-1")},
                              {QStringLiteral("url"), kSignInUrl},
                              {QStringLiteral("status"), QStringLiteral("wait")},
                              {QStringLiteral("error"), QJsonValue::Null}};
    world.mc.reply(rpc, QJsonObject{{QStringLiteral("url"), kSignInUrl}});
    return publish(world);
  }
  if (method == QLatin1String("finishSignIn")) {
    world.mc.reply(rpc, QJsonObject{{QStringLiteral("signIn"), fake.signIn}});
    return;
  }
  world.mc.refuse(rpc, QStringLiteral("Unknown method %1.").arg(method));
}

QList<QJsonObject> asked(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("plugins.call") && rpc.payload.value(QLatin1String("method")) == method) found.append(rpc.payload.value(QLatin1String("input")).toObject());
  }
  return found;
}

// The first `method` call the page made, once it has reached the MC.
QJsonObject waitAsked(World& world, const QString& method) {
  world.waitFor([&] { return !asked(world, method).isEmpty(); }, QStringLiteral("the page to call %1").arg(method));
  return asked(world, method).value(0);
}

QString textOf(World& world, const QString& objectName) { return waitShownNamed(world, objectName)->property("text").toString(); }

// Waits until `objectName`'s text holds `part`.
void waitSays(World& world, const QString& objectName, const QString& part) {
  world.waitFor([&] { return textOf(world, objectName).contains(part); },
                [&] { return QStringLiteral("%1 to say %2, not %3").arg(objectName, part, textOf(world, objectName)); });
}

void click(World& world, const QString& objectName) {
  QQuickItem* item = waitShownNamed(world, objectName);
  world.waitFor([&] { return item->isEnabled(); }, QStringLiteral("%1 to be enabled").arg(objectName));
  clickItem(world, item);
}

// With HAL_C2_SHOTS set, the window as drawn now goes to <dir>/cliproxyapi-<name>.png.
void shoot(World& world, const QString& name) {
  const QString dir = qEnvironmentVariable("HAL_C2_SHOTS");
  if (dir.isEmpty()) return;
  QDir().mkpath(dir);
  pluginShell(world)->grabWindow().save(QDir(dir).filePath(QStringLiteral("cliproxyapi-%1.png").arg(name)));
}

void openPage(World& world) {
  FakePluginPart part;
  part.package = package();
  part.call = [&world](const FakeMc::Rpc& rpc) { answer(world, rpc); };
  runFakePlugin(world, entry(manifest()), part);
  publish(world);
  switchToTab(world, QStringLiteral("CLIProxyAPI"));
  waitShownNamed(world, QStringLiteral("cliproxyapiPage"));
}

const Steps steps([] {
  // The MC scenarios' fake proxy; here the MC part is faked whole.
  step(QStringLiteral("a fake CLIProxyAPI"), [](World&, const Captures&, const Table&) {});

  step(QStringLiteral("the CLIProxyAPI page with the proxy running(?: and the \"claude\" account %1)?").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).email = c[0];
    openPage(world);
  });
  step(QStringLiteral("the CLIProxyAPI page with the proxy refusing the management key saying %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).state = QStringLiteral("blocked");
    state(world).message = c[0];
    openPage(world);
  });

  step(QStringLiteral("the CLIProxyAPI page connected to the proxy at %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).mode = QStringLiteral("connect");
    state(world).state = QStringLiteral("connected");
    state(world).address = c[0];
    openPage(world);
  });
  step(QStringLiteral("the CLIProxyAPI page with the proxy giving no usage, saying %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).usageNote = c[0];
    openPage(world);
  });
  step(QStringLiteral("the CLIProxyAPI page with \"Codex via CLIProxyAPI\" not added, saying %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).codexTaken = c[0];
    openPage(world);
  });

  step(QStringLiteral("the page says it is connected to the proxy at %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiState"), QStringLiteral("Connected to CLIProxyAPI at %1").arg(c[0]));
  });
  step(QStringLiteral("the page says the proxy gives no usage, saying %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiUsageNote"), QStringLiteral("The proxy gives no usage: %1").arg(c[0]));
  });
  step(QStringLiteral("the page shows %1 as not added, saying %2").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString name = c[0].startsWith(QLatin1String("Claude")) ? QStringLiteral("claude") : QStringLiteral("codex");
    waitSays(world, QStringLiteral("cliproxyapiInstanceText:") + name, QStringLiteral("%1 · not added: ").arg(c[0]));
    waitSays(world, QStringLiteral("cliproxyapiInstanceText:") + name, c[1]);
  });

  step(QStringLiteral("the page shows the proxy running CLIProxyAPI 8.0.79"), [](World& world, const Captures&, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiState"), QStringLiteral("Running CLIProxyAPI 8.0.79 at http://127.0.0.1:8317"));
  });
  step(QStringLiteral("the page lists the account %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(drawsText(waitShownNamed(world, QStringLiteral("cliproxyapiAccount:") + accountName(c[0])), QStringLiteral("Claude · ") + c[0]),
           QStringLiteral("the account %1 is not shown").arg(c[0]));
  });
  step(QStringLiteral("the page shows usage for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiUsage:") + c[0], QStringLiteral("2026-11-19 · %1 · claude-sonnet-4 · 2 request(s) · 175 tokens · 1 failed").arg(c[0]));
  });
  step(QStringLiteral("the page shows the %1 key %2").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("claude"), QStringLiteral("only a claude key is faked"));
    expect(drawsText(waitShownNamed(world, QStringLiteral("cliproxyapiKey:claude:0")), QStringLiteral("Claude · ") + c[1]), QStringLiteral("the key %1 is not shown").arg(c[1]));
  });
  step(QStringLiteral("the page shows the log line %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiLog"), c[0]);
    shoot(world, QStringLiteral("page"));
  });

  step(QStringLiteral("the user signs in to Claude on the page"), [](World& world, const Captures&, const Table&) {
    click(world, QStringLiteral("cliproxyapiSignIn:claude"));
    const QJsonObject asking = waitAsked(world, QStringLiteral("signIn"));
    expect(asking == QJsonObject{{QStringLiteral("provider"), QStringLiteral("claude")}}, QStringLiteral("the MC was asked %1").arg(show(asking.toVariantMap())));
  });
  step(QStringLiteral("the page shows the sign-in address and asks for the address the browser ended on"), [](World& world, const Captures&, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiSignInUrl"), kSignInUrl);
    waitSays(world, QStringLiteral("cliproxyapiSignInHelp"), QStringLiteral("copy that page's whole address and paste it below"));
    waitShownNamed(world, QStringLiteral("cliproxyapiSignInAddress"));
    shoot(world, QStringLiteral("sign-in"));
  });
  step(QStringLiteral("the user pastes %1 on the page").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    state(world).pasted = c[0];
    waitShownNamed(world, QStringLiteral("cliproxyapiSignInAddress"))->setProperty("text", c[0]);
    click(world, QStringLiteral("cliproxyapiFinishSignIn"));
  });
  step(QStringLiteral("the page asked the MC to finish the sign-in with that address"), [](World& world, const Captures&, const Table&) {
    const QJsonObject finishing = waitAsked(world, QStringLiteral("finishSignIn"));
    expect(finishing == QJsonObject{{QStringLiteral("address"), state(world).pasted}}, QStringLiteral("the MC was asked %1").arg(show(finishing.toVariantMap())));
  });

  step(QStringLiteral("the page says the proxy refused the management key %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    waitSays(world, QStringLiteral("cliproxyapiState"), QStringLiteral("CLIProxyAPI refused the management key"));
    waitSays(world, QStringLiteral("cliproxyapiMessage"), c[0]);
    shoot(world, QStringLiteral("refused"));
  });
  step(QStringLiteral("the user retries on the page"), [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("cliproxyapiRetry")); });
  step(QStringLiteral("the page asked the MC to retry"), [](World& world, const Captures&, const Table&) {
    waitAsked(world, QStringLiteral("retry"));
    waitSays(world, QStringLiteral("cliproxyapiState"), QStringLiteral("Running CLIProxyAPI 8.0.79"));
  });
});

}  // namespace
