// The native Source Control settings section (SourceControlSettingsController):
// the @desktop scenarios of features/settings/source-control.feature and
// source-control-writing.feature. The fake answers
// `server.discoverSourceControl` with the tools a scenario gives the machine;
// what the node does with a setting is its own scenarios', so these check
// what the section saves.

#include <QJsonArray>
#include <QJsonObject>

#include <functional>

#include "FakeConfig.h"
#include "FakeNode.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QString kInstructions = QStringLiteral("Keep titles under 50 characters.");

QJsonObject some(const QString& value) {
  return {{QStringLiteral("_tag"), QStringLiteral("Some")}, {QStringLiteral("value"), value}};
}

QJsonObject none() {
  return {{QStringLiteral("_tag"), QStringLiteral("None")}};
}

QJsonObject tool(const QString& kind, const QString& label, const QString& executable, bool available) {
  return {{QStringLiteral("kind"), kind},
          {QStringLiteral("label"), label},
          {QStringLiteral("executable"), executable},
          {QStringLiteral("installHint"), QStringLiteral("Install %1 and make sure `%2` is on the PATH.").arg(label, executable)},
          {QStringLiteral("status"), available ? QStringLiteral("available") : QStringLiteral("missing")},
          {QStringLiteral("version"), available ? some(QStringLiteral("2.45.0")) : none()},
          {QStringLiteral("detail"), none()}};
}

QJsonObject hostItem(const QString& kind, const QString& label, const QString& executable, bool available, const QString& auth,
                     const QString& account = {}) {
  QJsonObject item = tool(kind, label, executable, available);
  item.remove(QStringLiteral("detail"));
  item.insert(QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), available ? auth : QStringLiteral("unknown")},
                                                  {QStringLiteral("account"), account.isEmpty() ? none() : some(account)},
                                                  {QStringLiteral("host"), none()},
                                                  {QStringLiteral("detail"), none()}});
  return item;
}

struct FakeSourceControl {
  QJsonArray versionControl;
  QList<QJsonObject> hosts;
  QString refusal;
  QString mode;  // the writing style the scenario picked

  FakeSourceControl() {
    QJsonObject git = tool(QStringLiteral("git"), QStringLiteral("Git"), QStringLiteral("git"), true);
    git.insert(QStringLiteral("implemented"), true);
    QJsonObject jj = tool(QStringLiteral("jj"), QStringLiteral("Jujutsu"), QStringLiteral("jj"), true);
    jj.insert(QStringLiteral("implemented"), false);
    versionControl = {git, jj};
    hosts = {hostItem(QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("gh"), true, QStringLiteral("authenticated"), QStringLiteral("octocat")),
             hostItem(QStringLiteral("gitlab"), QStringLiteral("GitLab"), QStringLiteral("glab"), false, QStringLiteral("unknown")),
             hostItem(QStringLiteral("bitbucket"), QStringLiteral("Bitbucket"), QString(), true, QStringLiteral("unknown"))};
  }

  QJsonObject& host(const QString& kind) {
    for (QJsonObject& entry : hosts) {
      if (entry.value(QLatin1String("kind")) == kind) return entry;
    }
    Q_UNREACHABLE();
  }
};

const FakeNode::Extension discovery([](FakeNode& node) {
  node.onRpc(QStringLiteral("server.discoverSourceControl"), [&node](const FakeNode::Rpc& rpc) {
    const FakeSourceControl& fake = node.part<FakeSourceControl>();
    if (!fake.refusal.isEmpty()) {
      node.refuse(rpc, fake.refusal);
      return;
    }
    QJsonArray hosts;
    for (const QJsonObject& entry : fake.hosts) hosts.append(entry);
    node.reply(rpc, QJsonObject{{QStringLiteral("versionControlSystems"), fake.versionControl}, {QStringLiteral("sourceControlProviders"), hosts}});
  });
});

FakeSourceControl& fake(World& world) {
  return world.node.part<FakeSourceControl>();
}

QJsonObject provider(const QString& instanceId, const QString& name, const QString& model, bool enabled = true) {
  return {{QStringLiteral("instanceId"), instanceId},
          {QStringLiteral("driver"), instanceId},
          {QStringLiteral("displayName"), name},
          {QStringLiteral("enabled"), enabled},
          {QStringLiteral("installed"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("authenticated")}}},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), model}, {QStringLiteral("name"), model}}}}};
}

QVariantMap section(World& world) {
  return world.state(QStringLiteral("sourceControlSettings")).toMap();
}

QVariantMap found(World& world) {
  return section(world).value(QStringLiteral("discovery")).toMap();
}

QVariantMap part(World& world, const QString& key) {
  return section(world).value(key).toMap();
}

void send(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("sourceControlSettings.") + action, payload);
}

// The tool of `kind` the section lists, empty while it does not.
QVariantMap listed(World& world, const QString& kind) {
  for (const QString& group : {QStringLiteral("versionControl"), QStringLiteral("providers")}) {
    for (const QVariant& entry : found(world).value(group).toList()) {
      if (entry.toMap().value(QStringLiteral("kind")) == kind) return entry.toMap();
    }
  }
  return {};
}

// A scan of the machine as the scenario now has it, once it answers.
void scan(World& world) {
  send(world, QStringLiteral("scan"));
  world.waitFor([&] {
    const QVariantMap discovery = found(world);
    const QString status = discovery.value(QStringLiteral("status")).toString();
    return !discovery.value(QStringLiteral("scanning")).toBool() && (status == QLatin1String("ready") || status == QLatin1String("error"));
  }, [&] { return QStringLiteral("the scan to finish; the section is %1").arg(show(section(world))); });
}

QJsonObject style(const QJsonObject& settings) {
  return settings.value(QLatin1String("sourceControlWritingStyle")).toObject();
}

QJsonObject saved(World& world) {
  return fakeConfig(world.node).settings;
}

void open(World& world) {
  FakeConfig& config = fakeConfig(world.node);
  config.config.insert(QStringLiteral("providers"), QJsonArray{provider(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("codex-model")),
                                                               provider(QStringLiteral("claude"), QStringLiteral("Claude"), QStringLiteral("claude-model"))});
  world.connect();
  world.sync();
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/source-control")));
  world.waitFor([&] {
    return section(world).value(QStringLiteral("open")).toBool() && found(world).value(QStringLiteral("status")) == QLatin1String("ready") &&
           world.state(QStringLiteral("settingsScope")).toMap().value(QStringLiteral("editable")).toBool();
  }, [&] { return QStringLiteral("source control settings to show; they are %1").arg(show(section(world))); });
}

void waitSaved(World& world, const std::function<bool(const QJsonObject&)>& done, const QString& what) {
  world.waitFor([&] { return done(saved(world)); }, [&] { return QStringLiteral("%1; the settings are %2").arg(what, show(saved(world).toVariantMap())); });
}

qint64 fetchOverride(const QJsonObject& settings) {
  const QJsonObject overrides = settings.value(QLatin1String("backgroundActivity")).toObject().value(QLatin1String("overrides")).toObject();
  return overrides.contains(QLatin1String("automaticGitFetchInterval")) ? qint64(overrides.value(QLatin1String("automaticGitFetchInterval")).toDouble())
                                                                         : -1;
}

void setInterval(World& world, int seconds) {
  send(world, QStringLiteral("fetchInterval"), {{QStringLiteral("seconds"), seconds}});
  waitSaved(world, [seconds](const QJsonObject& settings) { return fetchOverride(settings) == qint64(seconds) * 1000; },
            QStringLiteral("a %1 second fetch interval to be saved").arg(seconds));
  world.waitFor([&] { return part(world, QStringLiteral("fetchInterval")).value(QStringLiteral("seconds")).toInt() == seconds; },
                [&] { return QStringLiteral("the interval to show %1 seconds; it is %2").arg(seconds).arg(show(part(world, QStringLiteral("fetchInterval")))); });
}

QString modeOf(const QString& label) {
  if (label == QLatin1String("Repository conventions")) return QStringLiteral("repo_conventions");
  if (label == QLatin1String("Conventional Commits")) return QStringLiteral("conventional_commits");
  if (label == QLatin1String("Custom instructions")) return QStringLiteral("custom");
  return label;
}

QString writerKey(const QJsonObject& settings) {
  const QJsonObject selection = settings.value(QLatin1String("sourceControlWriterModelSelection")).toObject();
  return selection.isEmpty() ? QString() : selection.value(QLatin1String("instanceId")).toString() + QLatin1Char(':') + selection.value(QLatin1String("model")).toString();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user is connected to an environment and opens Settings, Source Control"),
       [](World& world, const Captures&, const Table&) { open(world); });

  // source-control.feature
  step(QStringLiteral("the panel loads"), [](World& world, const Captures&, const Table&) { scan(world); });
  step(QStringLiteral("each version control and hosting tool is listed as available, missing or status unknown"),
       [](World& world, const Captures&, const Table&) {
         expect(listed(world, QStringLiteral("git")).value(QStringLiteral("available")).toBool(), QStringLiteral("Git to be available; %1").arg(show(found(world))));
         expect(!listed(world, QStringLiteral("gitlab")).isEmpty() && !listed(world, QStringLiteral("gitlab")).value(QStringLiteral("available")).toBool(),
                QStringLiteral("GitLab to be missing; %1").arg(show(found(world))));
         expect(listed(world, QStringLiteral("bitbucket")).value(QStringLiteral("authLabel")) == QLatin1String("Status unknown"),
                QStringLiteral("Bitbucket's status to be unknown; %1").arg(show(found(world))));
         expect(listed(world, QStringLiteral("github")).value(QStringLiteral("authLabel")) == QLatin1String("Authenticated"),
                QStringLiteral("GitHub to be authenticated; %1").arg(show(found(world))));
       });
  step(QStringLiteral("each available tool shows its version"), [](World& world, const Captures&, const Table&) {
    for (const QString& kind : {QStringLiteral("git"), QStringLiteral("github")}) {
      expect(listed(world, kind).value(QStringLiteral("version")) == QLatin1String("2.45.0"), QStringLiteral("%1 to show its version; %2").arg(kind, show(found(world))));
    }
    expect(listed(world, QStringLiteral("gitlab")).value(QStringLiteral("version")).toString().isEmpty(), QStringLiteral("a missing tool to show none"));
  });
  step(QStringLiteral("the GitHub CLI is signed in as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).host(QStringLiteral("github")) = hostItem(QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("gh"), true,
                                                                       QStringLiteral("authenticated"), c[0]);
    scan(world);
  });
  step(QStringLiteral("GitHub reads %1 without the account name").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap github = listed(world, QStringLiteral("github"));
    expect(github.value(QStringLiteral("summary")) == c[0] && github.value(QStringLiteral("hasAccount")).toBool() &&
               github.value(QStringLiteral("account")).toString().isEmpty(),
           QStringLiteral("GitHub to read %1 and keep its account hidden; it is %2").arg(c[0], show(github)));
  });
  step(QStringLiteral("the user reveals the account"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("reveal"), {{QStringLiteral("kind"), QStringLiteral("github")}, {QStringLiteral("revealed"), true}});
  });
  step(QStringLiteral("the account %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listed(world, QStringLiteral("github")).value(QStringLiteral("account")) == c[0]; },
                  [&] { return QStringLiteral("%1 to show; GitHub is %2").arg(c[0], show(listed(world, QStringLiteral("github")))); });
  });
  step(QStringLiteral("the user revealed the GitHub account"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("reveal"), {{QStringLiteral("kind"), QStringLiteral("github")}, {QStringLiteral("revealed"), true}});
    world.waitFor([&] { return listed(world, QStringLiteral("github")).value(QStringLiteral("account")) == QLatin1String("octocat"); },
                  [&] { return QStringLiteral("the account to show; GitHub is %1").arg(show(listed(world, QStringLiteral("github")))); });
  });
  step(QStringLiteral("the user hides it"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("reveal"), {{QStringLiteral("kind"), QStringLiteral("github")}, {QStringLiteral("revealed"), false}});
  });
  step(QStringLiteral("the account name is hidden again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap github = listed(world, QStringLiteral("github"));
      return github.value(QStringLiteral("hasAccount")).toBool() && github.value(QStringLiteral("account")).toString().isEmpty();
    }, [&] { return QStringLiteral("the account to hide; GitHub is %1").arg(show(listed(world, QStringLiteral("github")))); });
  });
  step(QStringLiteral("the GitHub CLI is installed but not signed in"), [](World& world, const Captures&, const Table&) {
    fake(world).host(QStringLiteral("github")) =
        hostItem(QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("gh"), true, QStringLiteral("unauthenticated"));
  });
  step(QStringLiteral("GitHub reads %1 with how to sign in").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap github = listed(world, QStringLiteral("github"));
    const QString summary = github.value(QStringLiteral("summary")).toString();
    expect(github.value(QStringLiteral("authLabel")) == c[0] && github.value(QStringLiteral("authWarning")).toBool() &&
               summary.contains(QLatin1String("Sign in")) && summary.contains(QLatin1String("gh")),
           QStringLiteral("GitHub to read %1 with how to sign in; it is %2").arg(c[0], show(github)));
  });
  step(QStringLiteral("the GitLab CLI is not installed"), [](World& world, const Captures&, const Table&) {
    fake(world).host(QStringLiteral("gitlab")) =
        hostItem(QStringLiteral("gitlab"), QStringLiteral("GitLab"), QStringLiteral("glab"), false, QStringLiteral("unknown"));
  });
  step(QStringLiteral("GitLab is shown as missing with its install instructions"), [](World& world, const Captures&, const Table&) {
    const QVariantMap gitlab = listed(world, QStringLiteral("gitlab"));
    expect(!gitlab.isEmpty() && !gitlab.value(QStringLiteral("available")).toBool() &&
               gitlab.value(QStringLiteral("summary")).toString().contains(QLatin1String("Install GitLab")),
           QStringLiteral("GitLab to be missing with how to install it; it is %1").arg(show(gitlab)));
  });
  step(QStringLiteral("the GitHub CLI was missing when the panel loaded"), [](World& world, const Captures&, const Table&) {
    fake(world).host(QStringLiteral("github")) =
        hostItem(QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("gh"), false, QStringLiteral("unknown"));
    scan(world);
    expect(!listed(world, QStringLiteral("github")).value(QStringLiteral("available")).toBool(), QStringLiteral("GitHub to be missing"));
  });
  step(QStringLiteral("the user has since installed and signed in to it"), [](World& world, const Captures&, const Table&) {
    fake(world).host(QStringLiteral("github")) = hostItem(QStringLiteral("github"), QStringLiteral("GitHub"), QStringLiteral("gh"), true,
                                                                       QStringLiteral("authenticated"), QStringLiteral("octocat"));
  });
  step(QStringLiteral("the user rescans Git and hosting integrations"), [](World& world, const Captures&, const Table&) { scan(world); });
  step(QStringLiteral("GitHub reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listed(world, QStringLiteral("github")).value(QStringLiteral("authLabel")) == c[0]; },
                  [&] { return QStringLiteral("GitHub to read %1; it is %2").arg(c[0], show(listed(world, QStringLiteral("github")))); });
  });
  step(QStringLiteral("the environment has no version control or hosting tools"), [](World& world, const Captures&, const Table&) {
    fake(world).versionControl = {};
    fake(world).hosts.clear();
  });
  step(QStringLiteral("the user is told nothing was detected yet and to install Git on the server and rescan"),
       [](World& world, const Captures&, const Table&) {
         const QVariantMap discovery = found(world);
         expect(discovery.value(QStringLiteral("title")) == QLatin1String("Nothing detected yet") &&
                    discovery.value(QStringLiteral("detail")).toString().startsWith(QLatin1String("Install Git on the server")) &&
                    discovery.value(QStringLiteral("detail")).toString().endsWith(QLatin1String("then rescan.")),
                QStringLiteral("to be told nothing was detected; the section shows %1").arg(show(discovery)));
       });
  step(QStringLiteral("the scan fails"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal = QStringLiteral("The node could not run the scan.");
  });
  step(QStringLiteral("hosts HAL-C2 cannot use yet are marked \"Coming Soon\""), [](World& world, const Captures&, const Table&) {
    expect(listed(world, QStringLiteral("jj")).value(QStringLiteral("comingSoon")).toBool() &&
               listed(world, QStringLiteral("jj")).value(QStringLiteral("summary")) == QLatin1String("Support for Jujutsu is coming soon."),
           QStringLiteral("Jujutsu to be coming soon; %1").arg(show(found(world))));
    expect(!listed(world, QStringLiteral("git")).value(QStringLiteral("comingSoon")).toBool(), QStringLiteral("Git to be usable"));
  });
  step(QStringLiteral("the user sets the automatic Git fetch interval to (\\d+) seconds"),
       [](World& world, const Captures& c, const Table&) { send(world, QStringLiteral("fetchInterval"), {{QStringLiteral("seconds"), c[0].toInt()}}); });
  step(QStringLiteral("Git fetches every (\\d+) seconds while a thread is on screen"), [](World& world, const Captures& c, const Table&) {
    waitSaved(world, [&](const QJsonObject& settings) { return fetchOverride(settings) == c[0].toLongLong() * 1000; },
              QStringLiteral("a %1 second fetch interval to be saved").arg(c[0]));
    world.waitFor([&] { return part(world, QStringLiteral("fetchInterval")).value(QStringLiteral("seconds")).toInt() == c[0].toInt(); },
                  [&] { return QStringLiteral("the interval to show; it is %1").arg(show(part(world, QStringLiteral("fetchInterval")))); });
  });
  step(QStringLiteral("the user set the automatic Git fetch interval to (\\d+) seconds"),
       [](World& world, const Captures& c, const Table&) { setInterval(world, c[0].toInt()); });
  step(QStringLiteral("the user resets the fetch interval"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("resetFetchInterval"));
  });
  step(QStringLiteral("the interval follows the background activity profile again"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) { return fetchOverride(settings) < 0; }, QStringLiteral("the fetch override to go"));
    world.waitFor([&] {
      const QVariantMap interval = part(world, QStringLiteral("fetchInterval"));
      return !interval.value(QStringLiteral("custom")).toBool() && interval.value(QStringLiteral("seconds")) == interval.value(QStringLiteral("preset"));
    }, [&] { return QStringLiteral("the interval to follow its preset; it is %1").arg(show(part(world, QStringLiteral("fetchInterval")))); });
  });
  step(QStringLiteral("Git never fetches in the background"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) { return fetchOverride(settings) == 0; }, QStringLiteral("fetching to be turned off"));
  });

  // source-control-writing.feature
  step(QStringLiteral("the user picks the writing style %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).mode = modeOf(c[0]);
    send(world, QStringLiteral("writingMode"), {{QStringLiteral("mode"), fake(world).mode}});
  });
  step(QStringLiteral("the panel explains %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return part(world, QStringLiteral("writingStyle")).value(QStringLiteral("description")) == c[0]; },
                  [&] { return QStringLiteral("the style to be explained; it is %1").arg(show(part(world, QStringLiteral("writingStyle")))); });
  });
  step(QStringLiteral("generated commits and pull requests follow that style"), [](World& world, const Captures&, const Table&) {
    const QString mode = fake(world).mode;
    waitSaved(world, [mode](const QJsonObject& settings) { return style(settings).value(QLatin1String("mode")) == mode; },
              QStringLiteral("the %1 style to be saved").arg(mode));
  });
  step(QStringLiteral("the writing style is Custom instructions"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.node, QStringLiteral("sourceControlWritingStyle"), QJsonObject{{QStringLiteral("mode"), QStringLiteral("custom")}});
    world.waitFor([&] { return part(world, QStringLiteral("writingStyle")).value(QStringLiteral("mode")) == QLatin1String("custom"); },
                  [&] { return QStringLiteral("the custom style to show; it is %1").arg(show(part(world, QStringLiteral("writingStyle")))); });
  });
  step(QStringLiteral("the user writes %1 as the instructions").arg(q), [](World& world, const Captures& c, const Table&) {
    send(world, QStringLiteral("instructions"), {{QStringLiteral("text"), c[0]}});
  });
  step(QStringLiteral("generated commits and pull requests follow those instructions"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) {
      return style(settings).value(QLatin1String("mode")) == QLatin1String("custom") && style(settings).value(QLatin1String("customInstructions")) == kInstructions;
    }, QStringLiteral("the instructions to be saved"));
  });
  step(QStringLiteral("the settings scope covers two environments"), [](World& world, const Captures&, const Table&) {
    // A server whose style differs, so the instructions are one for both.
    FakeConfig::Document& server = documentOf(world.node, QStringLiteral("server"));
    server.settings.insert(QStringLiteral("sourceControlWritingStyle"), QJsonObject{{QStringLiteral("mode"), QStringLiteral("conventional_commits")}});
    world.node.linkLabels.insert(QStringLiteral("server"), QStringLiteral("server"));
    world.node.link(QStringLiteral("server"));
    world.waitFor([&] { return world.state(QStringLiteral("settingsScope")).toMap().value(QStringLiteral("environments")).toList().size() == 2; },
                  [&] { return QStringLiteral("two environments; the scope is %1").arg(show(world.state(QStringLiteral("settingsScope")))); });
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
    world.waitFor([&] {
      return world.native().controller<SettingsScopeController>()->targets().size() == 2 &&
             part(world, QStringLiteral("writingStyle")).value(QStringLiteral("mixed")).toBool();
    }, [&] { return QStringLiteral("both environments' styles, mixed; the section is %1").arg(show(section(world))); });
  });
  step(QStringLiteral("the user writes custom instructions"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("instructions"), {{QStringLiteral("text"), kInstructions}});
  });
  step(QStringLiteral("both environments use those instructions"), [](World& world, const Captures&, const Table&) {
    const auto custom = [](const QJsonObject& settings) {
      return style(settings).value(QLatin1String("mode")) == QLatin1String("custom") && style(settings).value(QLatin1String("customInstructions")) == kInstructions;
    };
    world.waitFor([&] { return custom(saved(world)) && custom(documentOf(world.node, QStringLiteral("server")).settings); }, [&] {
      return QStringLiteral("both to use the instructions; here %1, the server %2")
          .arg(show(saved(world).toVariantMap()), show(documentOf(world.node, QStringLiteral("server")).settings.toVariantMap()));
    });
  });
  step(QStringLiteral("following change request templates is shown on"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return part(world, QStringLiteral("templates")).value(QStringLiteral("value")).toBool(); },
                  [&] { return QStringLiteral("templates to be shown followed; the row is %1").arg(show(part(world, QStringLiteral("templates")))); });
  });
  step(QStringLiteral("the environment's settings leave templates followed"), [](World& world, const Captures&, const Table&) {
    // Absent means followed: the node writes to a repository's template unless told not to.
    expect(style(saved(world)).value(QLatin1String("followChangeRequestTemplates")).toBool(true),
           QStringLiteral("the environment to follow templates; its settings are %1").arg(show(saved(world).toVariantMap())));
  });
  step(QStringLiteral("the user turns off following change request templates"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("templates"), {{QStringLiteral("enabled"), false}});
  });
  step(QStringLiteral("pull request descriptions are written without the repository's template"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) { return style(settings).value(QLatin1String("followChangeRequestTemplates")) == QJsonValue(false); },
              QStringLiteral("templates to be turned off"));
    world.waitFor([&] { return !part(world, QStringLiteral("templates")).value(QStringLiteral("value")).toBool(); },
                  [&] { return QStringLiteral("the row to be off; it is %1").arg(show(part(world, QStringLiteral("templates")))); });
  });
  step(QStringLiteral("the user turns on a separate source control writer model and picks one"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("writerModel"), {{QStringLiteral("enabled"), true}});
    waitSaved(world, [](const QJsonObject& settings) { return !writerKey(settings).isEmpty(); }, QStringLiteral("a writer model to be saved"));
    send(world, QStringLiteral("pickWriterModel"), {{QStringLiteral("key"), QStringLiteral("claude:claude-model")}});
  });
  step(QStringLiteral("commits, pull requests and branch names are written by that model"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) { return writerKey(settings) == QLatin1String("claude:claude-model"); },
              QStringLiteral("Claude to write source control text"));
  });
  step(QStringLiteral("a separate source control writer model is on"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.node, QStringLiteral("sourceControlWriterModelSelection"),
                  QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("codex-model")}});
    world.waitFor([&] { return part(world, QStringLiteral("writerModel")).value(QStringLiteral("on")).toBool(); },
                  [&] { return QStringLiteral("the writer model to be on; it is %1").arg(show(part(world, QStringLiteral("writerModel")))); });
  });
  step(QStringLiteral("the user turns it off"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("writerModel"), {{QStringLiteral("enabled"), false}});
  });
  step(QStringLiteral("the environment's text generation model writes source control text again"), [](World& world, const Captures&, const Table&) {
    waitSaved(world, [](const QJsonObject& settings) { return settings.value(QLatin1String("sourceControlWriterModelSelection")).isNull(); },
              QStringLiteral("the writer model to be off"));
  });
  step(QStringLiteral("the provider of a model is turned off"), [](World& world, const Captures&, const Table&) {
    publishProviders(world.node, QJsonArray{provider(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("codex-model")),
                                            provider(QStringLiteral("claude"), QStringLiteral("Claude"), QStringLiteral("claude-model"), false)});
  });
  step(QStringLiteral("the user looks at the writer model choices"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& model : part(world, QStringLiteral("writerModel")).value(QStringLiteral("models")).toList()) {
        if (!model.toMap().value(QStringLiteral("reason")).toString().isEmpty()) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a model to be unusable; the choices are %1").arg(show(part(world, QStringLiteral("writerModel")))); });
  });
  step(QStringLiteral("that model cannot be picked and the reason is shown"), [](World& world, const Captures&, const Table&) {
    QString reason;
    for (const QVariant& model : part(world, QStringLiteral("writerModel")).value(QStringLiteral("models")).toList()) {
      if (model.toMap().value(QStringLiteral("key")) == QLatin1String("claude:claude-model")) reason = model.toMap().value(QStringLiteral("reason")).toString();
    }
    expect(reason == QLatin1String("Claude is turned off."), QStringLiteral("Claude's model to say why; it says \"%1\"").arg(reason));
    const int writes = fakeConfig(world.node).writes.size();
    send(world, QStringLiteral("pickWriterModel"), {{QStringLiteral("key"), QStringLiteral("claude:claude-model")}});
    world.sync();
    expect(fakeConfig(world.node).writes.size() == writes, QStringLiteral("picking it to save nothing"));
  });
  step(QStringLiteral("saving settings fails"), [](World& world, const Captures&, const Table&) {
    fakeConfig(world.node).refuseWrites = QStringLiteral("The settings file is read-only.");
  });
  step(QStringLiteral("the user picks a writer model"), [](World& world, const Captures&, const Table&) {
    send(world, QStringLiteral("pickWriterModel"), {{QStringLiteral("key"), QStringLiteral("codex:codex-model")}});
  });
});

}  // namespace
