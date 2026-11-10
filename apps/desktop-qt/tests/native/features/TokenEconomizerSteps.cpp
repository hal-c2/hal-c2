// TokenEconomizer's page (features/plugins/token-economizer-*.feature): its real
// package from plugins/token-economizer, drawn by the desktop against a fake of
// its MC part that publishes `loopGuard`, `toolPrune` and `microSkills:<project>`
// as the MC part does and answers the calls the page makes.

#include <QDir>
#include <algorithm>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QImage>
#include <QQuickItem>
#include <QQuickWindow>

#include "Harness.h"
#include "Plugins.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("token-economizer");
const QString kProject = QStringLiteral("p1");
const QString kFact = QStringLiteral("pytest-as-module");
const QString kThread = QStringLiteral("t-partial");

QString package() { return QDir(QStringLiteral(HAL_C2_FEATURES_DIR "/../plugins/token-economizer")).absolutePath(); }

// The MC part's state: the project's micro-skills entry and its tool evidence.
struct FakeTokenEconomizer {
  QJsonObject skills;
  // The entry its saved file reads as once repaired, read on the next call by name.
  QJsonObject repaired;
  // The fact, as listed while it is not dropped.
  QJsonObject fact;
  QJsonObject prune;
  // Evidence saved but not loaded since the MC started: only a call naming the
  // project loads it.
  QJsonObject saved;
  // Whether a new conversation in the project is told the fact.
  bool staged = false;
};

FakeTokenEconomizer& state(World& world) { return world.mc.part<FakeTokenEconomizer>(); }

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

QJsonObject loopGuard() {
  return {{QStringLiteral("mode"), QStringLiteral("nudge")}, {QStringLiteral("watching"), 0}, {QStringLiteral("turns"), 12},
          {QStringLiteral("nudges"), 1}, {QStringLiteral("aborts"), 0}, {QStringLiteral("recent"), QJsonArray()}};
}

QJsonObject toolPrune(World& world) {
  const QJsonObject& prune = state(world).prune;
  return {{QStringLiteral("mode"), QStringLiteral("propose")},
          {QStringLiteral("unreadable"), QJsonArray()},
          {QStringLiteral("projects"), prune.isEmpty() ? QJsonArray() : QJsonArray{prune}}};
}

QJsonObject microSkills(World& world) {
  const QJsonObject& skills = state(world).skills;
  return {{QStringLiteral("mode"), QStringLiteral("envfacts")},
          {QStringLiteral("projects"), skills.isEmpty() ? QJsonArray() : QJsonArray{skills}}};
}

void publish(World& world) {
  FakePluginPart& part = fakePluginPart(world, kId);
  part.topics.insert(QStringLiteral("loopGuard"), loopGuard());
  part.topics.insert(QStringLiteral("toolPrune"), toolPrune(world));
  part.topics.insert(QStringLiteral("microSkills:") + kProject, state(world).skills);
  publishTopic(world, kId, QStringLiteral("toolPrune"));
  publishTopic(world, kId, QStringLiteral("microSkills:") + kProject);
}

QJsonObject history(const QString& at, int read) {
  return {{QStringLiteral("state"), at},
          {QStringLiteral("startedAt"), QStringLiteral("2026-11-01T09:00:00Z")},
          {QStringLiteral("threads"), 5},
          {QStringLiteral("threadsRead"), read},
          {QStringLiteral("turns"), 9},
          {QStringLiteral("pending"), 0},
          {QStringLiteral("skipped"), QJsonObject{{QStringLiteral("older than 30 days"), 2}}}};
}

QJsonObject skillsEntry(const QJsonArray& skills, const QJsonArray& dropped, const QJsonObject& history) {
  return {{QStringLiteral("projectId"), kProject}, {QStringLiteral("history"), history}, {QStringLiteral("turns"), 9},
          {QStringLiteral("staged"), QString()}, {QStringLiteral("skills"), skills}, {QStringLiteral("dropped"), dropped},
          {QStringLiteral("held"), QJsonValue::Null}, {QStringLiteral("extractors"), QJsonArray()}};
}

const QString kHeld = QStringLiteral("Its saved file is not valid JSON.");
const QString kFile = QStringLiteral("/data/plugins/token-economizer/micro-skills/0f3a.json");

// A held project's entry, as the MC part lists it: learned nothing, saying why and where.
QJsonObject heldEntry() {
  QJsonObject held = skillsEntry({}, {}, QJsonObject{{QStringLiteral("state"), QStringLiteral("none")}});
  held.insert(QStringLiteral("turns"), 0);
  held.insert(QStringLiteral("held"), kHeld);
  held.insert(QStringLiteral("file"), kFile);
  return held;
}

QJsonObject learnedFact() {
  return {{QStringLiteral("id"), kFact},
          {QStringLiteral("family"), QStringLiteral("test-command")},
          {QStringLiteral("claim"), QStringLiteral("Run the tests with `python -m pytest`; `pytest` is not on PATH.")},
          {QStringLiteral("state"), QStringLiteral("ACTIVE")},
          {QStringLiteral("staged"), true},
          {QStringLiteral("high"), true},
          {QStringLiteral("source"), QStringLiteral("envfacts")},
          {QStringLiteral("evidence"), QJsonObject{{QStringLiteral("confirms"), 4},
                                                   {QStringLiteral("contradicts"), 0},
                                                   {QStringLiteral("fired"), 3},
                                                   {QStringLiteral("exercised"), 4},
                                                   {QStringLiteral("firingRate"), 0.75}}}};
}

// The project as the sidebar lists it, so the page asks for it by name.
void ensureProject(World& world) {
  if (world.mc.projects.contains(kProject)) return;
  const QJsonObject row{{QStringLiteral("id"), kProject},
                        {QStringLiteral("title"), kProject},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject},
                        {QStringLiteral("scripts"), QJsonArray()},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
  world.mc.projects.insert(kProject, row);
  world.mc.sendRow(kProject, row, QStringLiteral("project"));
}

QJsonObject tool(const QString& at, int unused) {
  return {{QStringLiteral("state"), at}, {QStringLiteral("unusedSessions"), unused}, {QStringLiteral("unusedPrompts"), unused * 3},
          {QStringLiteral("loadedSessions"), unused}};
}

// The project's evidence for Claude: "CronCreate" as `at`, threads holding pruning
// off as `unresolved` and away as `away`.
QJsonObject pruneOf(const QString& at, const QJsonArray& unresolved = {}, const QJsonArray& away = {}) {
  const bool off = at == QLatin1String("off");
  return {{QStringLiteral("projectId"), kProject},
          {QStringLiteral("provider"), QStringLiteral("claudeAgent")},
          {QStringLiteral("unit"), QStringLiteral("tool")},
          {QStringLiteral("mode"), QStringLiteral("propose")},
          {QStringLiteral("off"), off ? QJsonArray{QStringLiteral("CronCreate")} : QJsonArray()},
          {QStringLiteral("proposed"), at == QLatin1String("proposed") ? QJsonArray{QStringLiteral("CronCreate")} : QJsonArray()},
          {QStringLiteral("kept"), at == QLatin1String("kept") ? QJsonArray{QStringLiteral("CronCreate")} : QJsonArray()},
          {QStringLiteral("pending"), QJsonArray()},
          {QStringLiteral("sessions"), 6},
          {QStringLiteral("prompts"), 18},
          {QStringLiteral("tools"), QJsonObject{{QStringLiteral("CronCreate"), tool(at, 5)}, {QStringLiteral("Bash"), tool(QStringLiteral("used"), 0)}}},
          {QStringLiteral("unresolved"), unresolved},
          {QStringLiteral("unreadable"), false},
          {QStringLiteral("away"), away}};
}

// The calls the page makes, answered as the MC part answers them.
void answer(World& world, const FakeMc::Rpc& rpc) {
  FakeTokenEconomizer& fake = state(world);
  const QString method = rpc.payload.value(QLatin1String("method")).toString();
  const QJsonObject input = rpc.payload.value(QLatin1String("input")).toObject();
  if (method == QLatin1String("status")) return world.mc.reply(rpc, loopGuard());
  if (method == QLatin1String("toolPrune")) {
    QJsonObject answer = toolPrune(world);
    answer.remove(QStringLiteral("unreadable"));
    // Naming the project loads its saved evidence, as the topic then carries it.
    if (input.contains(QLatin1String("projectId"))) {
      if (input.value(QLatin1String("projectId")) == kProject && fake.prune.isEmpty()) fake.prune = fake.saved;
      const QJsonObject prune = input.value(QLatin1String("projectId")) == kProject ? fake.prune : QJsonObject();
      answer.insert(QStringLiteral("projects"), prune.isEmpty() ? QJsonArray() : QJsonArray{prune});
    }
    return world.mc.reply(rpc, answer);
  }
  if (method == QLatin1String("microSkills")) {
    // Naming a held project reads its file again.
    if (input.value(QLatin1String("projectId")) == kProject && !fake.repaired.isEmpty()) {
      fake.skills = fake.repaired;
      fake.repaired = {};
    }
    return world.mc.reply(rpc, microSkills(world));
  }
  if (method == QLatin1String("toolPruneRestore")) {
    fake.prune = pruneOf(QStringLiteral("kept"));
  } else if (method == QLatin1String("toolPruneApply")) {
    fake.prune = pruneOf(QStringLiteral("off"));
  } else if (input.value(QLatin1String("projectId")) != kProject) {
    return world.mc.refuse(rpc, QStringLiteral("Give a projectId and an id."));
  } else if (method == QLatin1String("microSkills.drop")) {
    fake.staged = false;
    fake.skills = skillsEntry({}, QJsonArray{kFact}, fake.skills.value(QLatin1String("history")).toObject());
  } else if (method == QLatin1String("microSkills.restore")) {
    fake.skills = skillsEntry(QJsonArray{fake.fact}, {}, fake.skills.value(QLatin1String("history")).toObject());
  } else if (method == QLatin1String("microSkills.forget")) {
    fake.staged = false;
    fake.skills = skillsEntry({}, fake.skills.value(QLatin1String("dropped")).toArray(), history(QStringLiteral("running"), 0));
  } else {
    return world.mc.refuse(rpc, QStringLiteral("Unknown method %1.").arg(method));
  }
  world.mc.reply(rpc, method.startsWith(QLatin1String("microSkills")) ? microSkills(world) : toolPrune(world));
  publish(world);
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

// Waits until `objectName`'s text holds every one of `parts`.
void waitSays(World& world, const QString& objectName, const QStringList& parts) {
  world.waitFor(
      [&] {
        const QString text = textOf(world, objectName);
        return std::all_of(parts.cbegin(), parts.cend(), [&](const QString& part) { return text.contains(part); });
      },
      [&] { return QStringLiteral("%1 to say %2, not %3").arg(objectName, parts.join(QLatin1String(" … ")), textOf(world, objectName)); });
}

void click(World& world, const QString& objectName) {
  QQuickItem* item = waitShownNamed(world, objectName);
  world.waitFor([&] { return item->isEnabled(); }, QStringLiteral("%1 to be enabled").arg(objectName));
  clickItem(world, item);
}

// With HAL_C2_SHOTS set, the window as drawn now goes to <dir>/token-economizer-<name>.png.
void shoot(World& world, const QString& name) {
  const QString dir = qEnvironmentVariable("HAL_C2_SHOTS");
  if (dir.isEmpty()) return;
  QDir().mkpath(dir);
  pluginShell(world)->grabWindow().save(QDir(dir).filePath(QStringLiteral("token-economizer-%1.png").arg(name)));
}

void runPlugin(World& world) {
  FakePluginPart part;
  part.package = package();
  part.call = [&world](const FakeMc::Rpc& rpc) { answer(world, rpc); };
  runFakePlugin(world, entry(manifest()), part);
  publish(world);
}

const QString kKey = kProject + QStringLiteral(":claudeAgent");

const Steps steps([] {
  step(QStringLiteral("an MC running the TokenEconomizer plugin( with micro-skills)?"), [](World& world, const Captures&, const Table&) { runPlugin(world); });

  step(QStringLiteral("the person opens TokenEconomizer's page"), [](World& world, const Captures&, const Table&) {
    switchToTab(world, QStringLiteral("TokenEconomizer"));
    waitShownNamed(world, QStringLiteral("tokenEconomizerPage"));
  });

  // --- micro-skills ---
  step(QStringLiteral("TokenEconomizer has learned a fact on a project"), [](World& world, const Captures&, const Table&) {
    FakeTokenEconomizer& fake = state(world);
    fake.fact = learnedFact();
    fake.skills = skillsEntry(QJsonArray{fake.fact}, {}, QJsonObject{{QStringLiteral("state"), QStringLiteral("none")}});
    fake.staged = true;
    publish(world);
  });
  step(QStringLiteral("the fact is listed with how many turns confirmed it and how often it fires"), [](World& world, const Captures&, const Table&) {
    expect(drawsText(waitShownNamed(world, QStringLiteral("tokenEconomizerFact:") + kFact), state(world).fact.value(QLatin1String("claim")).toString()),
           QStringLiteral("the fact's claim is not shown"));
    waitSays(world, QStringLiteral("tokenEconomizerEvidence:") + kFact, {QStringLiteral("confirmed by 4 turn(s)"), QStringLiteral("fires 75%"), QStringLiteral("active, staged")});
    shoot(world, QStringLiteral("facts"));
  });
  step(QStringLiteral("the person drops the fact there"), [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("tokenEconomizerDrop:") + kFact); });
  step(QStringLiteral("a new conversation in that project is not told the fact"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !state(world).staged; }, QStringLiteral("the fact to be dropped"));
    const QJsonObject dropped = waitAsked(world, QStringLiteral("microSkills.drop"));
    expect(dropped == QJsonObject{{QStringLiteral("projectId"), kProject}, {QStringLiteral("id"), kFact}}, QStringLiteral("the MC was asked %1").arg(show(dropped.toVariantMap())));
  });
  step(QStringLiteral("the page lists it as dropped, with a way to restore it"), [](World& world, const Captures&, const Table&) {
    expect(drawsText(waitShownNamed(world, QStringLiteral("tokenEconomizerDropped:") + kFact), QStringLiteral("Dropped: %1, never staged or learned again").arg(kFact)), QStringLiteral("the dropped fact is not named"));
    world.waitFor([&] { return findNamed(waitShownNamed(world, QStringLiteral("tokenEconomizerPage")), QStringLiteral("tokenEconomizerFact:") + kFact) == nullptr; },
                  QStringLiteral("the dropped fact to leave the facts"));
    click(world, QStringLiteral("tokenEconomizerRestore:") + kFact);
    waitShownNamed(world, QStringLiteral("tokenEconomizerFact:") + kFact);
  });

  step(QStringLiteral("TokenEconomizer holds a project's micro-skills, its saved file not being valid JSON"), [](World& world, const Captures&, const Table&) {
    state(world).skills = heldEntry();
    publish(world);
  });
  step(QStringLiteral("the page shows the project as held, saying why and naming its file"), [](World& world, const Captures&, const Table&) {
    waitSays(world, QStringLiteral("tokenEconomizerHeld"), {QStringLiteral("Held: ") + kHeld, QStringLiteral("Repair or remove the file")});
    waitSays(world, QStringLiteral("tokenEconomizerHeldFile"), {kFile});
    shoot(world, QStringLiteral("held"));
  });
  step(QStringLiteral("the page offers no way to drop or forget there"), [](World& world, const Captures&, const Table&) {
    QQuickItem* forget = findNamed(waitShownNamed(world, QStringLiteral("tokenEconomizerPage")), QStringLiteral("tokenEconomizerForget"));
    expect(forget == nullptr || !forget->isVisible(), QStringLiteral("Forget is offered on a held project"));
  });
  step(QStringLiteral("the person repairs the file and reads it again from the page"), [](World& world, const Captures&, const Table&) {
    FakeTokenEconomizer& fake = state(world);
    fake.fact = learnedFact();
    fake.repaired = skillsEntry(QJsonArray{fake.fact}, {}, QJsonObject{{QStringLiteral("state"), QStringLiteral("none")}});
    click(world, QStringLiteral("tokenEconomizerReadAgain"));
    world.waitFor([&] { return asked(world, QStringLiteral("microSkills")).contains(QJsonObject{{QStringLiteral("projectId"), kProject}}); },
                  QStringLiteral("the page to ask for the project by name"));
    QQuickItem* held = findNamed(waitShownNamed(world, QStringLiteral("tokenEconomizerPage")), QStringLiteral("tokenEconomizerHeld"));
    world.waitFor([&] { return held == nullptr || !held->isVisible(); }, QStringLiteral("the project to no longer show as held"));
  });

  // --- the import from history ---
  step(QStringLiteral("TokenEconomizer's history import on a project is under way"), [](World& world, const Captures&, const Table&) {
    state(world).skills = skillsEntry({}, {}, history(QStringLiteral("running"), 2));
    publish(world);
  });
  step(QStringLiteral("the project shows how many threads the import read of how many, and what it left out"), [](World& world, const Captures&, const Table&) {
    waitSays(world, QStringLiteral("tokenEconomizerImport"), {QStringLiteral("running"), QStringLiteral("read 2 of 5 thread"), QStringLiteral("older than 30 days: 2")});
  });
  step(QStringLiteral("the person forgets what the project learned there"), [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("tokenEconomizerForget")); });
  step(QStringLiteral("the page shows the project having learned nothing, its import running again"), [](World& world, const Captures&, const Table&) {
    const QJsonObject forgot = waitAsked(world, QStringLiteral("microSkills.forget"));
    expect(forgot == QJsonObject{{QStringLiteral("projectId"), kProject}}, QStringLiteral("the MC was asked %1").arg(show(forgot.toVariantMap())));
    waitSays(world, QStringLiteral("tokenEconomizerImport"), {QStringLiteral("running"), QStringLiteral("read 0 of 5 thread")});
    expect(findNamed(waitShownNamed(world, QStringLiteral("tokenEconomizerPage")), QStringLiteral("tokenEconomizerFact:") + kFact) == nullptr, QStringLiteral("a fact is still listed"));
  });

  // --- tool pruning ---
  step(QStringLiteral("a project where %1 is turned off for Claude").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("CronCreate"), QStringLiteral("only CronCreate is faked"));
    state(world).prune = pruneOf(QStringLiteral("off"));
    publish(world);
  });
  step(QStringLiteral("the page shows %1 as off, with the evidence for it").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = waitShownNamed(world, QStringLiteral("tokenEconomizerTool:%1:%2").arg(kKey, c[0]));
    expect(drawsText(row, QStringLiteral("%1 · Off").arg(c[0])), QStringLiteral("%1 is not shown as off").arg(c[0]));
    expect(drawsText(row, QStringLiteral("unused for the last 5 conversation(s) and 15 prompt(s); loaded in 5")), QStringLiteral("%1's evidence is not shown").arg(c[0]));
    shoot(world, QStringLiteral("tools-off"));
  });
  step(QStringLiteral("the page offers to give it back"), [](World& world, const Captures&, const Table&) {
    click(world, QStringLiteral("tokenEconomizerGiveBack:%1:CronCreate").arg(kKey));
    const QJsonObject restored = waitAsked(world, QStringLiteral("toolPruneRestore"));
    expect(restored == QJsonObject{{QStringLiteral("projectId"), kProject}, {QStringLiteral("provider"), QStringLiteral("claudeAgent")}, {QStringLiteral("tools"), QJsonArray{QStringLiteral("CronCreate")}}},
           QStringLiteral("the MC was asked %1").arg(show(restored.toVariantMap())));
    world.waitFor([&] { return drawsText(waitShownNamed(world, QStringLiteral("tokenEconomizerTool:%1:CronCreate").arg(kKey)), QStringLiteral("CronCreate · Given back")); },
                  QStringLiteral("CronCreate to be listed as given back"));
  });

  step(QStringLiteral("a project where %1 was turned off for Claude before the MC restarted").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("CronCreate"), QStringLiteral("only CronCreate is faked"));
    ensureProject(world);
    state(world).saved = pruneOf(QStringLiteral("off"));
    publish(world);
  });
  step(QStringLiteral("the page asked for the project's tools by name"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return asked(world, QStringLiteral("toolPrune")).contains(QJsonObject{{QStringLiteral("projectId"), kProject}}); },
                  QStringLiteral("the page to ask for %1's tools by name").arg(kProject));
  });

  step(QStringLiteral("tool pruning heard only part of a turn of a Claude thread in a project"), [](World& world, const Captures&, const Table&) {
    state(world).prune = pruneOf(QStringLiteral("proposed"));
  });
  step(QStringLiteral("it could not read that turn back from the thread"), [](World& world, const Captures&, const Table&) {
    state(world).prune = pruneOf(QStringLiteral("proposed"), QJsonArray{kThread});
    publish(world);
  });
  step(QStringLiteral("the thread moved to another machine before that turn could be read back"), [](World& world, const Captures&, const Table&) {
    state(world).prune = pruneOf(QStringLiteral("proposed"), {}, QJsonArray{kThread});
    publish(world);
  });
  step(QStringLiteral("the page shows that nothing is turned off for the project's new conversations until that thread is read back"),
       [](World& world, const Captures&, const Table&) {
         waitSays(world, QStringLiteral("tokenEconomizerUnresolved:") + kKey, {QStringLiteral("Nothing is turned off for this project's new conversations until 1 thread(s) are read back")});
         waitShownNamed(world, QStringLiteral("tokenEconomizerHolding:%1:%2").arg(kKey, kThread));
         shoot(world, QStringLiteral("held-off"));
       });
  step(QStringLiteral("the page lists the thread as away, not as holding pruning off"), [](World& world, const Captures&, const Table&) {
    expect(drawsText(waitShownNamed(world, QStringLiteral("tokenEconomizerAway:%1:%2").arg(kKey, kThread)), QStringLiteral("Away on another machine, holding nothing off until it comes back: ") + kThread),
           QStringLiteral("the thread is not listed as away"));
    QQuickItem* page = waitShownNamed(world, QStringLiteral("tokenEconomizerPage"));
    QQuickItem* holding = findNamed(page, QStringLiteral("tokenEconomizerHolding:%1:%2").arg(kKey, kThread));
    QQuickItem* unresolved = findNamed(page, QStringLiteral("tokenEconomizerUnresolved:") + kKey);
    expect((holding == nullptr || !holding->isVisible()) && (unresolved == nullptr || !unresolved->isVisible()), QStringLiteral("the away thread is listed as holding pruning off"));
  });
});

}  // namespace
