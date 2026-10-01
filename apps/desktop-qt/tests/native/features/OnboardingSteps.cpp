// The first-run gate and the welcome wizard on the desktop
// (OnboardingController): the @desktop scenarios of
// features/navigation/welcome-wizard.feature.

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeProjects.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Onboarding.h"
#include "OnboardingController.h"
#include "SettingsController.h"
#include "World.h"

namespace {

// The MC's `agentSessions.*`: what a scan finds, and what importing does.
struct FakeSessions {
  QJsonArray candidates;
  QString refuseImport;
  bool holdImport = false;
  QList<FakeMc::Rpc> heldImports;
  QList<QJsonObject> imports;
  // What the setup terminal was sent (terminal.write payloads).
  QList<QJsonObject> writes;
  // The preferences file as it was before it became unreadable.
  QByteArray savedPreferences;
  QDateTime savedModified;
};

FakeSessions& fake(World& world) {
  return world.mc.part<FakeSessions>();
}

void answerImport(FakeMc& mc, const FakeMc::Rpc& rpc) {
  mc.reply(rpc, QJsonObject{{QStringLiteral("importedCount"), 2}, {QStringLiteral("skippedCount"), 0}});
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("agentSessions.scan"), [&mc](const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{QStringLiteral("candidates"), mc.part<FakeSessions>().candidates}});
  });
  mc.onRpc(QStringLiteral("agentSessions.import"), [&mc](const FakeMc::Rpc& rpc) {
    FakeSessions& sessions = mc.part<FakeSessions>();
    sessions.imports.append(rpc.payload);
    if (!sessions.refuseImport.isEmpty()) return mc.refuse(rpc, sessions.refuseImport);
    if (sessions.holdImport) return sessions.heldImports.append(rpc);
    answerImport(mc, rpc);
  });
});

QVariantMap onboarding(World& world) {
  return world.state(QStringLiteral("onboarding")).toMap();
}

OnboardingController* controller(World& world) {
  return world.native().controller<OnboardingController>();
}

void act(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(action, payload);
  world.sync();
}

QString preferencesPath(World& world) {
  return QDir(world.configDir()).filePath(QStringLiteral("preferences.json"));
}

// The MC's own computer, its config as the MC publishes it.
void describeComputer(World& world, const QString& label) {
  world.mc.label = label;
  FakeConfig& config = fakeConfig(world.mc);
  config.config.insert(QStringLiteral("cwd"), QStringLiteral("/home/ada"));
  config.config.insert(QStringLiteral("environment"),
                       QJsonObject{{QStringLiteral("platform"), QJsonObject{{QStringLiteral("os"), QStringLiteral("linux")}}}});
}

QString driverOf(const QString& agent) {
  return agent == QLatin1String("Claude Code") ? QStringLiteral("claudeAgent") : QStringLiteral("codex");
}

// An agent on the MC's computer, as its provider probe reports it.
void giveAgent(World& world, const QString& agent, const QString& state, const QString& instanceId = {}) {
  const QString driver = driverOf(agent);
  const bool installed = state != QLatin1String("not installed");
  const bool signedIn = state == QLatin1String("installed and signed in");
  QJsonObject provider{{QStringLiteral("instanceId"), instanceId.isEmpty() ? driver : instanceId},
                       {QStringLiteral("driver"), driver},
                       {QStringLiteral("enabled"), true},
                       {QStringLiteral("installed"), installed},
                       {QStringLiteral("status"), !installed ? QStringLiteral("error") : signedIn ? QStringLiteral("ready") : QStringLiteral("error")},
                       {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), !installed ? QStringLiteral("unknown")
                                                                                  : signedIn ? QStringLiteral("authenticated")
                                                                                             : QStringLiteral("unauthenticated")}}}};
  if (!installed) provider.insert(QStringLiteral("message"), agent + QStringLiteral(" is not installed."));
  FakeConfig& config = fakeConfig(world.mc);
  QJsonArray providers = config.config.value(QLatin1String("providers")).toArray();
  for (qsizetype i = providers.size() - 1; i >= 0; --i) {
    if (providers.at(i).toObject().value(QLatin1String("driver")) == driver) providers.removeAt(i);
  }
  providers.append(provider);
  config.config.insert(QStringLiteral("providers"), providers);
}

void openHalC2(World& world) {
  world.connect();
  world.waitFor([&] {
    const QVariantMap state = onboarding(world);
    return state.value(QStringLiteral("gate")) != QLatin1String("pending") || !state.value(QStringLiteral("recovery")).isNull();
  }, [&] { return QStringLiteral("the gate to decide; it is %1").arg(show(onboarding(world))); });
}

void openWizard(World& world) {
  if (world.shellSubscriptions() == 0) openHalC2(world);
  world.waitFor([&] { return onboarding(world).value(QStringLiteral("gate")) == QLatin1String("wizard"); },
                [&] { return QStringLiteral("the wizard; the gate is %1").arg(show(onboarding(world))); });
}

QVariantMap computer(World& world, const QString& label) {
  for (const QVariant& entry : onboarding(world).value(QStringLiteral("computers")).toList()) {
    if (entry.toMap().value(QStringLiteral("label")) == label) return entry.toMap();
  }
  return {};
}

// Links a computer the MC reaches, named `label`.
void linkComputer(World& world, const QString& label, const QString& problem = {}) {
  world.mc.linkLabels.insert(label, label);
  if (!problem.isEmpty()) world.mc.linkProblems.insert(label, problem);
  world.mc.link(label);
}

void continueTo(World& world, const QString& step) {
  for (int tries = 0; tries < 2 && onboarding(world).value(QStringLiteral("step")) != step; ++tries) {
    world.waitFor([&] { return onboarding(world).value(QStringLiteral("canContinue")).toBool() ||
                               onboarding(world).value(QStringLiteral("step")) != QLatin1String("connection"); },
                  [&] { return QStringLiteral("to be able to continue; the wizard is %1").arg(show(onboarding(world))); });
    act(world, QStringLiteral("onboarding.continue"));
  }
  world.waitFor([&] { return onboarding(world).value(QStringLiteral("step")) == step; },
                [&] { return QStringLiteral("the %1 step; the wizard is %2").arg(step, show(onboarding(world))); });
}

QVariantMap card(World& world, const QString& agent, const QString& label) {
  for (const QVariant& section : onboarding(world).value(QStringLiteral("agents")).toList()) {
    if (section.toMap().value(QStringLiteral("label")) != label) continue;
    for (const QVariant& entry : section.toMap().value(QStringLiteral("cards")).toList()) {
      if (entry.toMap().value(QStringLiteral("name")) == agent) return entry.toMap();
    }
  }
  return {};
}

// The agents step, with the MC's providers checked.
void checkAgents(World& world) {
  openWizard(world);
  continueTo(world, QStringLiteral("agents"));
  world.waitFor([&] {
    const QVariantList sections = onboarding(world).value(QStringLiteral("agents")).toList();
    if (sections.isEmpty()) return false;
    // An agent the MC does not report stays "checking", as on the web.
    for (const QVariant& entry : sections.first().toMap().value(QStringLiteral("cards")).toList()) {
      if (entry.toMap().value(QStringLiteral("state")) != QLatin1String("checking")) return true;
    }
    return false;
  }, [&] { return QStringLiteral("the agents to be checked; the wizard is %1").arg(show(onboarding(world))); });
}

// Opens the setup terminal for `agent` on the MC's computer.
void setUp(World& world, const QString& agent) {
  world.mc.onRpc(QStringLiteral("terminal.write"), [&world](const FakeMc::Rpc& rpc) {
    fake(world).writes.append(rpc.payload);
    world.mc.passOn(rpc);
  });
  checkAgents(world);
  act(world, QStringLiteral("onboarding.agent"),
      {{QStringLiteral("environmentId"), world.mc.environmentId}, {QStringLiteral("driver"), driverOf(agent)}});
  world.waitFor([&] {
    const QString status = onboarding(world).value(QStringLiteral("terminal")).toMap().value(QStringLiteral("status")).toString();
    return status == QLatin1String("ready") || status == QLatin1String("openFailed");
  }, [&] { return QStringLiteral("the setup terminal; the wizard is %1").arg(show(onboarding(world))); });
}

QList<QJsonObject> terminalInputs(World& world) {
  QList<QJsonObject> inputs;
  for (const QJsonObject& subscription : std::as_const(world.mc.subscriptions)) {
    const QJsonObject shape = subscription.value(QLatin1String("shape")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("terminal")) inputs.append(shape);
  }
  return inputs;
}

QJsonObject candidate(const QString& path, const QJsonValue& git, int threads, const QString& lastActiveAt) {
  return {{QStringLiteral("path"), path},
          {QStringLiteral("title"), QFileInfo(path).fileName()},
          {QStringLiteral("sources"), QJsonArray{QStringLiteral("claudeAgent"), QStringLiteral("codex")}},
          {QStringLiteral("threadCount"), threads},
          {QStringLiteral("lastActiveAt"), lastActiveAt},
          {QStringLiteral("alreadyImported"), false},
          {QStringLiteral("git"), git}};
}

QJsonObject repository(const QString& name) {
  return {{QStringLiteral("remoteKey"), QStringLiteral("github.com/") + name}, {QStringLiteral("repository"), name}};
}

// A busy recent repository (selected by default), a quiet one, and a plain folder.
void findProjects(World& world) {
  fake(world).candidates = {
      candidate(QStringLiteral("/home/ada/api"), repository(QStringLiteral("acme/api")), 5, QStringLiteral("2026-09-22T10:00:00.000Z")),
      candidate(QStringLiteral("/home/ada/site"), repository(QStringLiteral("acme/site")), 1, QStringLiteral("2026-09-21T10:00:00.000Z")),
      candidate(QStringLiteral("/home/ada/notes"), QJsonValue::Null, 4, QStringLiteral("2026-09-20T10:00:00.000Z")),
  };
}

QVariantMap importState(World& world) {
  return onboarding(world).value(QStringLiteral("import")).toMap();
}

void reachImport(World& world) {
  openWizard(world);
  continueTo(world, QStringLiteral("agents"));
  continueTo(world, QStringLiteral("import"));
  world.waitFor([&] {
    const QVariantList scans = importState(world).value(QStringLiteral("scans")).toList();
    return !scans.isEmpty() && std::none_of(scans.cbegin(), scans.cend(), [](const QVariant& scan) {
      return scan.toMap().value(QStringLiteral("pending")).toBool();
    });
  }, [&] { return QStringLiteral("the scans; the wizard is %1").arg(show(onboarding(world))); });
}

QVariantList importKeys(World& world) {
  QVariantList keys;
  for (const QVariant& scan : importState(world).value(QStringLiteral("scans")).toList()) {
    for (const QVariant& group : scan.toMap().value(QStringLiteral("repositories")).toList()) {
      for (const QVariant& entry : group.toMap().value(QStringLiteral("candidates")).toList()) keys.append(entry.toMap().value(QStringLiteral("key")));
    }
    for (const QVariant& entry : scan.toMap().value(QStringLiteral("other")).toMap().value(QStringLiteral("candidates")).toList()) {
      keys.append(entry.toMap().value(QStringLiteral("key")));
    }
  }
  return keys;
}

void importProject(World& world) {
  fake(world).candidates = {
      candidate(QStringLiteral("/home/ada/api"), repository(QStringLiteral("acme/api")), 5, QStringLiteral("2026-09-22T10:00:00.000Z"))};
  reachImport(world);
  act(world, QStringLiteral("onboarding.project"), {{QStringLiteral("keys"), importKeys(world)}, {QStringLiteral("selected"), true}});
  act(world, QStringLiteral("onboarding.import"));
}

void appOpens(World& world) {
  world.waitFor([&] {
    const QVariantMap state = onboarding(world);
    return state.value(QStringLiteral("gate")) == QLatin1String("app") && state.value(QStringLiteral("recovery")).isNull();
  }, [&] { return QStringLiteral("the app; the gate is %1").arg(show(onboarding(world))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // ---- When the wizard appears ----
  step(QStringLiteral("a fresh installation with no workspace"), [](World& world, const Captures&, const Table&) {
    expect(world.mc.projects.isEmpty() && world.mc.threads.isEmpty() && !QFile::exists(preferencesPath(world)),
           QStringLiteral("the installation is not fresh"));
  });
  step(QStringLiteral("a workspace that already has projects"), [](World& world, const Captures&, const Table&) {
    world.mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")},
                                                        {QStringLiteral("title"), QStringLiteral("shop")},
                                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                        {QStringLiteral("scripts"), QJsonArray()}});
  });
  step(QStringLiteral("the user opens HAL-C2"), [](World& world, const Captures&, const Table&) { openHalC2(world); });
  step(QStringLiteral("the app opens without the wizard"), [](World& world, const Captures&, const Table&) {
    appOpens(world);
    // Saved quietly, so the next start decides without the MC.
    world.waitFor([&] { return !world.native().controller<SettingsController>()->deviceSettings().value(QLatin1String("onboardingCompletedAt")).toString().isEmpty(); },
                  QStringLiteral("setup to be saved as done"));
  });
  step(QStringLiteral("the app cannot confirm the workspace during startup"), [](World& world, const Captures&, const Table&) {
    world.mc.holdSnapshot = true;
    controller(world)->setDecisionTimeout(20);
  });
  step(QStringLiteral("the user reloads"), [](World& world, const Captures&, const Table&) {
    world.mc.connections.clear();
    // Long enough for the step after to see it waiting again.
    controller(world)->setDecisionTimeout(60000);
    act(world, QStringLiteral("onboarding.reload"));
  });
  step(QStringLiteral("the app tries again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.mc.connections.isEmpty() && world.shellSubscriptions() >= 1; },
                  QStringLiteral("the shell to connect again"));
    const QVariantMap state = onboarding(world);
    expect(state.value(QStringLiteral("gate")) == QLatin1String("pending") && state.value(QStringLiteral("recovery")).isNull(),
           QStringLiteral("the gate to wait again; it is %1").arg(show(state)));
  });
  step(QStringLiteral("the saved settings cannot be read"), [](World& world, const Captures&, const Table&) {
    QFile file(preferencesPath(world));
    expect(file.open(QIODevice::WriteOnly), QStringLiteral("cannot write %1").arg(file.fileName()));
    fake(world).savedPreferences = R"({"onboardingCompletedAt":"2026-09-01T10:00:00.000Z","sidebarWidth":312})";
    file.write(fake(world).savedPreferences);
    file.close();
    file.setPermissions(QFileDevice::Permissions());
    fake(world).savedModified = QFileInfo(file).lastModified();
    world.native().controller<SettingsController>()->reloadDevice();
    expect(world.native().controller<SettingsController>()->deviceUnreadable(), QStringLiteral("the preferences are readable"));
  });
  step(QStringLiteral("the saved settings are left untouched"), [](World& world, const Captures&, const Table&) {
    const QFileInfo info(preferencesPath(world));
    expect(info.lastModified() == fake(world).savedModified && info.size() == fake(world).savedPreferences.size(),
           QStringLiteral("the preferences were written"));
  });
  step(QStringLiteral("storage becomes available and the user retries"), [](World& world, const Captures&, const Table&) {
    QFile(preferencesPath(world)).setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    act(world, QStringLiteral("onboarding.retry"));
  });
  step(QStringLiteral("the app continues with the saved settings"), [](World& world, const Captures&, const Table&) {
    appOpens(world);
    const QJsonObject device = world.native().controller<SettingsController>()->deviceSettings();
    expect(device.value(QLatin1String("sidebarWidth")).toInt() == 312 &&
               device.value(QLatin1String("onboardingCompletedAt")) == QLatin1String("2026-09-01T10:00:00.000Z"),
           QStringLiteral("the device settings are %1").arg(show(device.toVariantMap())));
    QFile file(preferencesPath(world));
    expect(file.open(QIODevice::ReadOnly) && file.readAll() == fake(world).savedPreferences, QStringLiteral("the preferences were rewritten"));
  });
  step(QStringLiteral("the settings cannot be saved"), [](World& world, const Captures&, const Table&) {
    openWizard(world);
    // A file where the preferences' directory would be.
    const QString blocker = QDir(world.configDir()).filePath(QStringLiteral("blocked"));
    QFile file(blocker);
    if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(blocker));
    world.native().controller<SettingsController>()->setDevicePath(QDir(blocker).filePath(QStringLiteral("preferences.json")));
  });
  step(QStringLiteral("the user finishes the wizard"), [](World& world, const Captures&, const Table&) {
    reachImport(world);
    act(world, QStringLiteral("onboarding.skip"));
  });

  // ---- Connect your computers ----
  step(QStringLiteral("the user opened HAL-C2 from a desktop app named %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.label = c[0];
    openWizard(world);
  });
  step(QStringLiteral("%1 is connected and selected").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap entry = computer(world, c[0]);
      return entry.value(QStringLiteral("connected")).toBool() && entry.value(QStringLiteral("selected")).toBool();
    }, [&] { return QStringLiteral("%1 connected and selected; the wizard is %2").arg(c[0], show(onboarding(world))); });
  });
  step(QStringLiteral("a saved computer and a computer discovered through HAL-C2 Connect"), [](World& world, const Captures&, const Table&) {
    world.mc.label = QStringLiteral("studio");
    linkComputer(world, QStringLiteral("laptop"));
    openWizard(world);
    world.mc.join(QStringLiteral("mc-b"), QStringLiteral("env-found"));
    world.sync();
  });
  step(QStringLiteral("both computers are selected"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      QStringList selected;
      for (const QVariant& entry : onboarding(world).value(QStringLiteral("computers")).toList()) {
        if (entry.toMap().value(QStringLiteral("selected")).toBool()) selected.append(entry.toMap().value(QStringLiteral("environmentId")).toString());
      }
      return selected.contains(QStringLiteral("laptop")) && selected.contains(QStringLiteral("env-found"));
    }, [&] { return QStringLiteral("both selected; the wizard is %1").arg(show(onboarding(world))); });
  });
  step(QStringLiteral("a selected, connected computer %1").arg(q), [](World& world, const Captures& c, const Table&) {
    linkComputer(world, c[0]);
    openWizard(world);
    world.waitFor([&] { return computer(world, c[0]).value(QStringLiteral("connected")).toBool() && computer(world, c[0]).value(QStringLiteral("selected")).toBool(); },
                  [&] { return QStringLiteral("%1 selected; the wizard is %2").arg(c[0], show(onboarding(world))); });
  });
  step(QStringLiteral("the user unchecks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    act(world, QStringLiteral("onboarding.select"),
        {{QStringLiteral("environmentId"), computer(world, c[0]).value(QStringLiteral("environmentId"))}, {QStringLiteral("selected"), false}});
  });
  step(QStringLiteral("%1 is not set up by the wizard").arg(q), [](World& world, const Captures& c, const Table&) {
    continueTo(world, QStringLiteral("agents"));
    const QVariantList sections = onboarding(world).value(QStringLiteral("agents")).toList();
    expect(!sections.isEmpty() && std::none_of(sections.cbegin(), sections.cend(), [&](const QVariant& section) {
      return section.toMap().value(QStringLiteral("label")) == c[0];
    }), QStringLiteral("the wizard sets up %1").arg(show(sections)));
  });
  step(QStringLiteral("%1 stays connected").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(computer(world, c[0]).value(QStringLiteral("connected")).toBool() && world.mc.linked.contains(c[0]),
           QStringLiteral("%1 is no longer connected; the wizard is %2").arg(c[0], show(onboarding(world))));
  });
  step(QStringLiteral("the user adds a computer by pasting a pairing link"), [](World& world, const Captures&, const Table&) {
    world.mc.onRpc(QStringLiteral("hal-c2.linkEnvironment"), [&world](const FakeMc::Rpc& rpc) {
      expect(rpc.payload.value(QLatin1String("pairingUrl")) == QLatin1String("http://desk:3773/pair#token=abc"),
             QStringLiteral("paired with %1").arg(rpc.payload.value(QLatin1String("pairingUrl")).toString()));
      linkComputer(world, QStringLiteral("desk"));
      world.mc.reply(rpc, QJsonObject{{QStringLiteral("environmentId"), QStringLiteral("desk")}, {QStringLiteral("label"), QStringLiteral("desk")}});
    });
    openWizard(world);
    act(world, QStringLiteral("onboarding.pair"), {{QStringLiteral("pairingUrl"), QStringLiteral(" http://desk:3773/pair#token=abc ")}});
  });
  step(QStringLiteral("the computer connects and is selected"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap entry = computer(world, QStringLiteral("desk"));
      return entry.value(QStringLiteral("connected")).toBool() && entry.value(QStringLiteral("selected")).toBool() &&
             !onboarding(world).value(QStringLiteral("pairing")).toBool();
    }, [&] { return QStringLiteral("desk selected; the wizard is %1").arg(show(onboarding(world))); });
  });
  step(QStringLiteral("the user adds a computer with a pairing link that fails"), [](World& world, const Captures&, const Table&) {
    world.mc.onRpc(QStringLiteral("hal-c2.linkEnvironment"), [&world](const FakeMc::Rpc& rpc) {
      world.mc.refuse(rpc, QStringLiteral("the pairing link is invalid or expired"));
    });
    openWizard(world);
    act(world, QStringLiteral("onboarding.pair"), {{QStringLiteral("pairingUrl"), QStringLiteral("http://desk:3773/pair#token=old")}});
  });
  step(QStringLiteral("a selected computer is still connecting"), [](World& world, const Captures&, const Table&) {
    linkComputer(world, QStringLiteral("laptop"), QStringLiteral("connecting"));
    openWizard(world);
    world.waitFor([&] { return computer(world, QStringLiteral("laptop")).value(QStringLiteral("selected")).toBool(); },
                  [&] { return QStringLiteral("laptop selected; the wizard is %1").arg(show(onboarding(world))); });
  });
  step(QStringLiteral("the user cannot continue yet"), [](World& world, const Captures&, const Table&) {
    expect(!onboarding(world).value(QStringLiteral("canContinue")).toBool(), QStringLiteral("the user can continue"));
    act(world, QStringLiteral("onboarding.continue"));
    expect(onboarding(world).value(QStringLiteral("step")) == QLatin1String("connection"), QStringLiteral("the wizard moved on"));
  });
  step(QStringLiteral("that computer connects"), [](World& world, const Captures&, const Table&) {
    world.mc.setLinkProblem(QStringLiteral("laptop"), {});
    world.sync();
  });
  step(QStringLiteral("the user can continue"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return onboarding(world).value(QStringLiteral("canContinue")).toBool(); },
                  [&] { return QStringLiteral("to be able to continue; the wizard is %1").arg(show(onboarding(world))); });
  });

  // ---- Check your agents ----
  step(QStringLiteral("the computer %1 has (Claude Code|Codex) (not installed|installed but signed out|installed and signed in)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         describeComputer(world, c[0]);
         giveAgent(world, c[1], c[2]);
       });
  step(QStringLiteral("the wizard checks agents"), [](World& world, const Captures&, const Table&) { checkAgents(world); });
  step(QStringLiteral("(Claude Code|Codex) on %1 offers (Install|Sign in|nothing to do)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap shown = card(world, c[0], c[1]);
    const QString state = shown.value(QStringLiteral("state")).toString();
    const QString offer = state == QLatin1String("install") ? QStringLiteral("Install")
                          : state == QLatin1String("signIn") ? QStringLiteral("Sign in")
                          : state == QLatin1String("ready")  ? QStringLiteral("nothing to do")
                                                             : state;
    expect(offer == c[2], QStringLiteral("%1 offers %2; the wizard is %3").arg(c[0], offer, show(onboarding(world))));
  });
  step(QStringLiteral("Codex is not installed on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    describeComputer(world, c[0]);
    giveAgent(world, QStringLiteral("Codex"), QStringLiteral("not installed"));
  });
  step(QStringLiteral("the user chooses to install Codex"), [](World& world, const Captures&, const Table&) {
    setUp(world, QStringLiteral("Codex"));
  });
  step(QStringLiteral("a terminal opens on %1 with the vendor's installer command ready").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString installer = QStringLiteral("curl -fsSL https://chatgpt.com/codex/install.sh | sh");
    world.waitFor([&] {
      for (const QJsonObject& write : std::as_const(fake(world).writes)) {
        if (write.value(QLatin1String("data")) == installer) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the installer typed; the terminal was sent %1").arg(show(QJsonArray::fromVariantList([&] {
      QVariantList list;
      for (const QJsonObject& write : std::as_const(fake(world).writes)) list.append(write.toVariantMap());
      return list;
    }()).toVariantList())); });
    const QList<QJsonObject> inputs = terminalInputs(world);
    expect(!inputs.isEmpty() && inputs.last().value(QLatin1String("environment")) == world.mc.environmentId &&
               world.mc.label == c[0] &&
               inputs.last().value(QLatin1String("input")).toObject().value(QLatin1String("cwd")) == QLatin1String("/home/ada"),
           QStringLiteral("the terminal opened as %1").arg(show(inputs.isEmpty() ? QVariant() : inputs.last().toVariantMap())));
    expect(controller(world)->terminal() != nullptr, QStringLiteral("the wizard has no terminal to show"));
  });
  step(QStringLiteral("the user is asked to review the command and press Enter to run it"), [](World& world, const Captures&, const Table&) {
    const QVariantMap terminal = onboarding(world).value(QStringLiteral("terminal")).toMap();
    expect(terminal.value(QStringLiteral("status")) == QLatin1String("ready"), QStringLiteral("the terminal is %1").arg(show(terminal)));
    for (const QJsonObject& write : std::as_const(fake(world).writes)) {
      const QString data = write.value(QLatin1String("data")).toString();
      expect(!data.contains(QLatin1Char('\r')) && !data.contains(QLatin1Char('\n')), QStringLiteral("the command was run: %1").arg(data));
    }
  });
  step(QStringLiteral("the Codex instance on %1 has its own home directory and a secret variable").arg(q), [](World& world, const Captures& c, const Table&) {
    describeComputer(world, c[0]);
    giveAgent(world, QStringLiteral("Codex"), QStringLiteral("installed but signed out"), QStringLiteral("codex_work"));
    FakeConfig& config = fakeConfig(world.mc);
    config.settings.insert(QStringLiteral("providerInstances"), QJsonObject{{QStringLiteral("codex_work"), QJsonObject{
        {QStringLiteral("driver"), QStringLiteral("codex")},
        {QStringLiteral("config"), QJsonObject{{QStringLiteral("binaryPath"), QStringLiteral("~/bin/codex work")},
                                               {QStringLiteral("homePath"), QStringLiteral("/home/ada/.codex-work")}}},
        {QStringLiteral("environment"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("OPENAI_API_KEY")},
                                                               {QStringLiteral("sensitive"), true},
                                                               {QStringLiteral("valueRedacted"), true}}}}}}});
    config.secrets.insert(QStringLiteral("codex_work/OPENAI_API_KEY"), QStringLiteral("sk-secret"));
  });
  step(QStringLiteral("the user chooses to sign in to Codex"), [](World& world, const Captures&, const Table&) {
    setUp(world, QStringLiteral("Codex"));
  });
  step(QStringLiteral("the terminal runs with that home and variable"), [](World& world, const Captures&, const Table&) {
    // The MC starts it with the instance's env and home (HalC2.Terminal).
    const QList<QJsonObject> inputs = terminalInputs(world);
    expect(!inputs.isEmpty() && inputs.last().value(QLatin1String("input")).toObject().value(QLatin1String("providerInstanceId")) == QLatin1String("codex_work"),
           QStringLiteral("the terminal opened as %1").arg(show(inputs.isEmpty() ? QVariant() : inputs.last().toVariantMap())));
    world.waitFor([&] {
      for (const QJsonObject& write : std::as_const(fake(world).writes)) {
        if (write.value(QLatin1String("data")) == QLatin1String("~/'bin/codex work' login")) return true;
      }
      return false;
    }, QStringLiteral("the instance's own sign-in command to be typed"));
  });
  step(QStringLiteral("the secret stays redacted where the user can see it"), [](World& world, const Captures&, const Table&) {
    expect(!show(onboarding(world)).contains(QLatin1String("sk-secret")), QStringLiteral("the wizard shows the secret"));
    for (const QJsonObject& input : terminalInputs(world)) {
      expect(!show(input.toVariantMap()).contains(QLatin1String("sk-secret")), QStringLiteral("the shell sent the secret"));
    }
    for (const QJsonObject& write : std::as_const(fake(world).writes)) {
      expect(!show(write.toVariantMap()).contains(QLatin1String("sk-secret")), QStringLiteral("the terminal was sent the secret"));
    }
  });
  step(QStringLiteral("terminals cannot start on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    describeComputer(world, c[0]);
    giveAgent(world, QStringLiteral("Codex"), QStringLiteral("not installed"));
    world.mc.onShape(QStringLiteral("terminal"), [&world](int id, const QJsonObject&) {
      world.mc.forget(id);
      world.mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Terminal limit reached on this machine")}});
    });
  });

  // ---- Import your projects ----
  step(QStringLiteral("every listed project is selected"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = importState(world);
    expect(state.value(QStringLiteral("total")).toInt() == 3 && state.value(QStringLiteral("selectedCount")).toInt() == 3,
           QStringLiteral("the import is %1").arg(show(state)));
  });
  step(QStringLiteral("no project is selected"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = importState(world);
    expect(state.value(QStringLiteral("total")).toInt() == 3 && state.value(QStringLiteral("selectedCount")).toInt() == 0,
           QStringLiteral("the import is %1").arg(show(state)));
  });
  step(QStringLiteral("reading thread history will fail"), [](World& world, const Captures&, const Table&) {
    fake(world).refuseImport = QStringLiteral("cannot read ~/.codex/sessions");
  });
  step(QStringLiteral("the user imports a project"), [](World& world, const Captures&, const Table&) { importProject(world); });

  // ---- Moving through the wizard ----
  step(QStringLiteral("the user continues without importing projects"), [](World& world, const Captures&, const Table&) {
    reachImport(world);
    act(world, QStringLiteral("onboarding.skip"));
  });
  step(QStringLiteral("the app opens"), [](World& world, const Captures&, const Table&) { appOpens(world); });
  step(QStringLiteral("the user is on the import step"), [](World& world, const Captures&, const Table&) {
    linkComputer(world, QStringLiteral("laptop"));
    openWizard(world);
    world.waitFor([&] { return !computer(world, QStringLiteral("laptop")).isEmpty(); }, QStringLiteral("laptop to be offered"));
    act(world, QStringLiteral("onboarding.select"), {{QStringLiteral("environmentId"), QStringLiteral("laptop")}, {QStringLiteral("selected"), false}});
    reachImport(world);
  });
  step(QStringLiteral("the user returns to the connect step from the progress bar"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("onboarding.stage"), {{QStringLiteral("index"), 0}});
  });
  step(QStringLiteral("the connect step is shown with the earlier choices"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = onboarding(world);
    expect(state.value(QStringLiteral("step")) == QLatin1String("connection") &&
               !computer(world, QStringLiteral("laptop")).value(QStringLiteral("selected")).toBool() &&
               onboarding(world).value(QStringLiteral("computers")).toList().first().toMap().value(QStringLiteral("selected")).toBool(),
           QStringLiteral("the wizard is %1").arg(show(state)));
  });
  step(QStringLiteral("an import is running"), [](World& world, const Captures&, const Table&) {
    fake(world).holdImport = true;
    importProject(world);
    world.waitFor([&] { return !fake(world).heldImports.isEmpty(); }, QStringLiteral("the import to start"));
  });
  step(QStringLiteral("the user cannot move to another step until it finishes"), [](World& world, const Captures&, const Table&) {
    expect(onboarding(world).value(QStringLiteral("importing")).toBool(), QStringLiteral("no import is running"));
    for (int index : {0, 1}) {
      act(world, QStringLiteral("onboarding.stage"), {{QStringLiteral("index"), index}});
      expect(onboarding(world).value(QStringLiteral("step")) == QLatin1String("import"),
             QStringLiteral("the wizard moved to %1").arg(onboarding(world).value(QStringLiteral("step")).toString()));
    }
    act(world, QStringLiteral("onboarding.skip"));
    expect(onboarding(world).value(QStringLiteral("gate")) == QLatin1String("wizard"), QStringLiteral("the wizard closed mid-import"));
    // Once it lands, the app opens on the imported project.
    for (const FakeMc::Rpc& rpc : std::exchange(fake(world).heldImports, {})) answerImport(world.mc, rpc);
    appOpens(world);
  });
});

}  // namespace

bool onboardingShows(World& world, const QString& text) {
  const QVariantMap state = onboarding(world);
  const QString recovery = state.value(QStringLiteral("recovery")).toString();
  if (recovery == QLatin1String("settings")) return text == QLatin1String("Could not read settings");
  if (recovery == QLatin1String("connection")) return text == QLatin1String("Still connecting");
  return state.value(QStringLiteral("gate")) == QLatin1String("wizard") && text == QLatin1String("Set up HAL-C2");
}

bool onboardingTells(World& world, const QString& text) {
  const QVariantMap state = onboarding(world);
  if (state.value(QStringLiteral("pairingError")) == text) return true;
  if (state.value(QStringLiteral("import")).toMap().value(QStringLiteral("error")) == text) return true;
  return state.value(QStringLiteral("terminal")).toMap().value(QStringLiteral("status")) == QLatin1String("openFailed") &&
         text == QLatin1String("Could not open the setup terminal.");
}

bool onboardingChooses(World& world, const QString& choice) {
  if (choice != QLatin1String("Select all") && choice != QLatin1String("Select none")) return false;
  if (onboarding(world).value(QStringLiteral("step")) != QLatin1String("import")) {
    findProjects(world);
    reachImport(world);
  }
  act(world, choice == QLatin1String("Select all") ? QStringLiteral("onboarding.selectAll") : QStringLiteral("onboarding.selectNone"));
  return true;
}
