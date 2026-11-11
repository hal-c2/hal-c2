// The composer's suggestion menus (features/composer/context-references.feature):
// the files, skills and commands a trigger character offers, what choosing
// one puts in the draft, and the keys that walk, take and dismiss them. The
// provider's skills and commands come from the MC's provider snapshot; the
// files from its workspace search (FakeFiles).

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>

#include "ComposerBrick.h"
#include "ComposerController.h"
#include "ComposerModel.h"
#include "FakeConfig.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "WorkspaceController.h"
#include "World.h"

namespace {

// The provider's skills and commands as the scenario has them, the text the
// user typed before acting on the menu, and the suggestion last found offered
// ("the user chooses it").
struct References {
  QJsonArray skills;
  QJsonArray commands;
  // Each folder's own skills, which the MC reads only once a composer asks
  // for that folder; and the folders it has read.
  QHash<QString, QJsonArray> folderSkills;
  QJsonArray snapshots;
  bool published = false;
  QString typed;
  QString offered;
};

References& refs(World& world) {
  return world.mc.part<References>();
}

QVariantMap composerState(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QString draftText(World& world) {
  return composerState(world).value(QStringLiteral("text")).toString();
}

QVariantList offered(World& world) {
  return composerState(world).value(QStringLiteral("suggestions")).toList();
}

QString kindOf(const QVariant& item) {
  return item.toMap().value(QStringLiteral("kind")).toString();
}

QString labelOf(const QVariant& item) {
  return item.toMap().value(QStringLiteral("label")).toString();
}

QString idOf(const QVariant& item) {
  return item.toMap().value(QStringLiteral("id")).toString();
}

// What a suggestion names: a skill's or command's name, a path, or a
// built-in command's word.
QString nameOf(const QVariant& item) {
  const QString id = idOf(item);
  if (id.startsWith(QLatin1String("slash:"))) return id.mid(6);
  return id.section(u':', 2);
}

QString describeMenu(World& world) {
  const QVariantMap state = composerState(world);
  return QStringLiteral("the draft reads \"%1\", the menu is %2 with %3 (empty text %4)")
      .arg(state.value(QStringLiteral("text")).toString(), show(state.value(QStringLiteral("triggerKind"))),
           show(state.value(QStringLiteral("suggestions"))), show(state.value(QStringLiteral("suggestionsEmptyText"))));
}

QStringList quotedIn(const QString& text) {
  static const QRegularExpression quoted(QStringLiteral("\"([^\"]*)\""));
  QStringList found;
  for (auto it = quoted.globalMatch(text); it.hasNext();) found.append(it.next().captured(1));
  return found;
}

// The thread's provider, with the scenario's skills and commands, announced
// without a round trip, so an RPC handler can send it.
void announce(World& world) {
  References& r = refs(world);
  r.published = true;
  publishProviders(world.mc, {QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")},
                                          {QStringLiteral("driver"), QStringLiteral("codex")},
                                          {QStringLiteral("displayName"), QStringLiteral("Codex")},
                                          {QStringLiteral("enabled"), true},
                                          {QStringLiteral("installed"), true},
                                          {QStringLiteral("status"), QStringLiteral("ready")},
                                          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-5")},
                                                                                            {QStringLiteral("name"), QStringLiteral("GPT-5")}}}},
                                          {QStringLiteral("slashCommands"), r.commands},
                                          {QStringLiteral("skills"), r.skills},
                                          {QStringLiteral("workspaceSnapshots"), r.snapshots}}});
  // The open thread runs on it, as every thread the MC holds names a model.
  if (world.mc.threads.contains(stream::kThread) && !world.mc.threads.value(stream::kThread).contains(QLatin1String("modelSelection"))) {
    QJsonObject& row = world.mc.threads[stream::kThread];
    row.insert(QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}});
    world.mc.sendRow(stream::kThread, row);
  }
}

void publish(World& world) {
  announce(world);
  world.sync();
}

// The MC reads a folder's skills when asked for it and announces them with
// the providers (`server.refreshProviders` with a `cwd`).
void readFoldersWhenAsked(World& world) {
  world.mc.onRpc(QStringLiteral("server.refreshProviders"), [&world](const FakeMc::Rpc& rpc) {
    References& r = refs(world);
    const QString cwd = rpc.payload.value(QLatin1String("cwd")).toString();
    if (r.folderSkills.contains(cwd)) {
      r.snapshots.append(QJsonObject{{QStringLiteral("cwd"), cwd}, {QStringLiteral("skills"), r.folderSkills.value(cwd)},
                                     {QStringLiteral("slashCommands"), QJsonArray()}});
      announce(world);
    }
    world.mc.reply(rpc, QJsonObject{{QStringLiteral("providers"), fakeConfig(world.mc).config.value(QLatin1String("providers"))}});
  });
}

void ensureProvider(World& world) {
  if (!refs(world).published) publish(world);
}

void addSkill(World& world, const QString& name, const QJsonObject& more = {}) {
  QJsonObject skill{{QStringLiteral("name"), name}, {QStringLiteral("enabled"), true}};
  for (auto it = more.begin(); it != more.end(); ++it) skill.insert(it.key(), it.value());
  refs(world).skills.append(skill);
}

void addCommand(World& world, const QString& name) {
  refs(world).commands.append(QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("description"), QStringLiteral("Run %1").arg(name)}});
}

QString target(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

// The user types `text` into the draft (the composer's debounced edit, as the
// brick dispatches it); with the composer on screen its editor follows.
void typeText(World& world, const QString& text) {
  refs(world).typed = text;
  world.bridge().dispatch(QStringLiteral("composer.text.set"),
                          QVariantMap{{QStringLiteral("target"), target(world)},
                                      {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                           {QStringLiteral("revision"), world.nextEdit++}}},
                                      {QStringLiteral("text"), text},
                                      {QStringLiteral("cursor"), text.size()}});
  world.sync();
  if (composerBrickShown(world)) settleComposer(world);
}

// Types `text` key by key into the composer on screen.
void typeOnScreen(World& world, const QString& text) {
  composerBrick(world);
  refs(world).typed = text;
  typeInComposer(world, text);
  settleComposer(world);
}

void waitForMenu(World& world, const std::function<bool(const QVariantList&)>& done, const QString& what) {
  world.waitFor([&] { return done(offered(world)); }, [&] { return QStringLiteral("%1; %2").arg(what, describeMenu(world)); });
}

// The menu has answered the text typed: its suggestions, or why it has none.
void waitForAnswer(World& world) {
  world.sync();
  world.waitFor([&] {
    const QVariantMap state = composerState(world);
    return state.value(QStringLiteral("triggerKind")).isNull() || !offered(world).isEmpty() ||
           !state.value(QStringLiteral("suggestionsEmptyText")).isNull();
  }, [&] { return QStringLiteral("the menu to answer; %1").arg(describeMenu(world)); });
}

// The first suggestion that `matches`; remembered for "the user chooses it".
QVariant waitForOffered(World& world, const std::function<bool(const QVariant&)>& matches, const QString& what) {
  QVariant found;
  waitForMenu(world, [&](const QVariantList& items) {
    for (const QVariant& item : items) {
      if (matches(item)) {
        found = item;
        return true;
      }
    }
    return false;
  }, what);
  refs(world).offered = idOf(found);
  return found;
}

void choose(World& world, const QString& id) {
  world.bridge().dispatch(QStringLiteral("composer.suggest.select"), QVariantMap{{QStringLiteral("id"), id}});
  world.sync();
  if (composerBrickShown(world)) settleComposer(world);
}

// Whether `query`'s letters appear in `value` in order.
bool inOrder(const QString& value, const QString& query) {
  qsizetype at = 0;
  for (const QChar c : query.toLower()) {
    at = value.toLower().indexOf(c, at);
    if (at < 0) return false;
    ++at;
  }
  return true;
}

QQuickItem* suggestionList(World& world) {
  QQuickItem* list = composerPart(world, QStringLiteral("suggestionList"));
  expect(list != nullptr, QStringLiteral("the composer has no suggestion list"));
  return list;
}

int highlighted(World& world) {
  return suggestionList(world)->property("currentIndex").toInt();
}

// The composer on screen offers suggestions for `text`, typed key by key.
void offeredOnScreen(World& world, const QString& text, int count = -1) {
  openTurnThread(world);
  typeOnScreen(world, text);
  waitForMenu(world, [&](const QVariantList& items) { return count < 0 ? !items.isEmpty() : items.size() == count; },
              QStringLiteral("suggestions for \"%1\"").arg(text));
  world.waitFor([&] { return suggestionList(world)->property("count").toInt() == offered(world).size(); },
                QStringLiteral("the suggestion list to show the suggestions"));
}

void expectInteractionMode(World& world, const QString& mode) {
  world.waitFor([&] { return composerState(world).value(QStringLiteral("interactionMode")) == mode; },
                [&] { return QStringLiteral("the thread to be in %1 mode; the composer shows %2").arg(mode, show(composerState(world))); });
}

const Steps steps([] {
  const QString q = kQuoted;
  const QString list = QStringLiteral("(\"[^\"]*\"(?:(?:, | and )\"[^\"]*\")*)");

  // The workspace and the provider.
  step(QStringLiteral("the project has the files? %1").arg(list), [](World& world, const Captures& c, const Table&) {
    for (const QString& path : quotedIn(c[0])) fakeFiles(world.mc).files.insert(path, QString());
  });
  step(QStringLiteral("the provider offers the skills? %1").arg(list), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : quotedIn(c[0])) addSkill(world, name);
    publish(world);
  });
  step(QStringLiteral("the provider offers the commands? %1").arg(list), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : quotedIn(c[0])) addCommand(world, name);
    publish(world);
  });
  step(QStringLiteral("the provider offers the commands %1 and the skill %2").arg(list, q), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : quotedIn(c[0])) addCommand(world, name);
    addSkill(world, c[1]);
    publish(world);
  });
  step(QStringLiteral("the provider offers the skill %1 and also a command %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addSkill(world, c[0]);
    addCommand(world, c[1]);
    publish(world);
  });
  // A command and a skill whose names start with the word and are as long as
  // the built-in's (a longer name ranks lower).
  step(QStringLiteral("the provider offers a command and a skill that both match %1 as well as %1 does").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString word = c[0].mid(1);
         const QString builtIn = c[1].mid(1);
         expect(builtIn.startsWith(word) && builtIn.size() > word.size(), QStringLiteral("\"%1\" does not start with \"%2\"").arg(builtIn, word));
         const qsizetype pad = builtIn.size() - word.size();
         addCommand(world, word + QString(pad, u'x'));
         addSkill(world, word + QString(pad, u'y'));
         publish(world);
       });
  step(QStringLiteral("the provider reports the skill %1 from two places and a skill %1 the user may not run").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addSkill(world, c[0], {{QStringLiteral("scope"), QStringLiteral("repo")}, {QStringLiteral("path"), QStringLiteral("/work/shop/.codex/skills/review")}});
         addSkill(world, c[0], {{QStringLiteral("scope"), QStringLiteral("user")}, {QStringLiteral("path"), QStringLiteral("/home/sam/.codex/skills/review")}});
         addSkill(world, c[1], {{QStringLiteral("userInvocable"), false}});
         publish(world);
       });
  step(QStringLiteral("the provider offers the skill %1 with no display name").arg(q), [](World& world, const Captures& c, const Table&) {
    addSkill(world, c[0]);
    publish(world);
  });
  step(QStringLiteral("the provider offers the skill %1 described as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addSkill(world, c[0], {{QStringLiteral("description"), c[1]}});
    publish(world);
  });
  step(QStringLiteral("the provider offers a skill described as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addSkill(world, QStringLiteral("release-notes"), {{QStringLiteral("description"), c[0]}});
    publish(world);
  });
  step(QStringLiteral("the provider reports different skills for %1 and for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& folder : {c[0], c[1]}) {
      refs(world).folderSkills.insert(folder, QJsonArray{QJsonObject{{QStringLiteral("name"), folder.section(u'/', -1) + QStringLiteral("-deploy")},
                                                                     {QStringLiteral("enabled"), true}}});
    }
    readFoldersWhenAsked(world);
    publish(world);
  });
  step(QStringLiteral("skills are shown in the slash menu"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    settings->set(QStringLiteral("showSkillsInSlashMenu"), true);
    expect(settings->setting(QStringLiteral("showSkillsInSlashMenu")) == QVariant(true), QStringLiteral("skills are not shown in the slash menu"));
  });
  step(QStringLiteral("the Build and Plan toggle setting is on"), [](World& world, const Captures&, const Table&) {
    ensureProvider(world);
    expect(world.native().controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true),
           QStringLiteral("plan mode could not be turned on"));
    world.sync();
  });
  step(QStringLiteral("the thread is (building|planning)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = c[0] == QLatin1String("planning") ? QStringLiteral("plan") : QStringLiteral("default");
    world.bridge().dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    expectInteractionMode(world, mode);
  });

  // Typing.
  step(QStringLiteral("the user types %1 in a thread working in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openTurnThread(world);
    QJsonObject& row = world.mc.threads[stream::kThread];
    row.insert(QStringLiteral("worktreePath"), c[1]);
    world.mc.sendRow(stream::kThread, row);
    world.waitFor([&] {
      const auto& place = world.native().controller<WorkspaceController>()->place();
      return place && place->cwd() == c[1];
    }, QStringLiteral("the thread to work in %1").arg(c[1]));
    typeText(world, c[0]);
  });
  step(QStringLiteral("the user types %1 and (no skill matches|no file or folder matches|no command matches)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         ensureProvider(world);
         fakeFiles(world.mc);
         typeText(world, c[0]);
       });
  step(QStringLiteral("the user types %1 and the files have not come back yet").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(QStringLiteral("src/cart.ts"), QString());
    world.mc.hold(QStringLiteral("search"));
    typeText(world, c[0]);
  });
  step(QStringLiteral("the user types %1 and chooses %1").arg(q), [](World& world, const Captures& c, const Table&) {
    typeText(world, c[0]);
    choose(world, idOf(waitForOffered(world, [&](const QVariant& item) { return nameOf(item) == c[1]; }, QStringLiteral("\"%1\" to be offered").arg(c[1]))));
  });

  // What the menu offers.
  step(QStringLiteral("the user is offered (files and folders|skills|commands) matching %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString what = c[0];
    const QString query = c[1];
    const QStringList kinds = what == QLatin1String("skills")   ? QStringList{QStringLiteral("skill")}
                              : what == QLatin1String("commands") ? QStringList{QStringLiteral("slash-command"), QStringLiteral("provider-slash-command")}
                                                                  : QStringList{QStringLiteral("path")};
    waitForMenu(world, [](const QVariantList& items) { return !items.isEmpty(); }, QStringLiteral("%1 to be offered").arg(what));
    for (const QVariant& item : offered(world)) {
      expect(kinds.contains(kindOf(item)), QStringLiteral("not only %1 are offered: %2").arg(what, describeMenu(world)));
      const QString name = nameOf(item);
      // A skill or command may match by its description as well as its name.
      const bool matches = what == QLatin1String("files and folders")
                               ? name.contains(query, Qt::CaseInsensitive)
                               : inOrder(name, query) || item.toMap().value(QStringLiteral("description")).toString().contains(query, Qt::CaseInsensitive);
      expect(matches, QStringLiteral("%1 does not match \"%2\": %3").arg(name, query, describeMenu(world)));
    }
    if (what == QLatin1String("files and folders")) {
      QSet<QString> found;
      for (const QVariant& item : offered(world)) found.insert(idOf(item).section(u':', 1, 1));
      expect(found.contains(QStringLiteral("file")) && found.contains(QStringLiteral("directory")), QStringLiteral("not both files and folders: %1").arg(describeMenu(world)));
    }
  });
  step(QStringLiteral("the user is offered suggestions"), [](World& world, const Captures&, const Table&) {
    fakeFiles(world.mc).files.insert(QStringLiteral("README.md"), QString());
    offeredOnScreen(world, QStringLiteral("@rea"));
  });
  step(QStringLiteral("the user typed %1 and suggestions are offered").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(QStringLiteral("README.md"), QString());
    offeredOnScreen(world, c[0]);
  });
  step(QStringLiteral("the user typed %1 and three files are offered").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const char* path : {"search.ts", "shop.ts", "style.css"}) fakeFiles(world.mc).files.insert(QString::fromLatin1(path), QString());
    offeredOnScreen(world, c[0], 3);
  });
  step(QStringLiteral("the user typed %1 and %1 is highlighted").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[1], QString());
    offeredOnScreen(world, c[0]);
    world.waitFor([&] { return labelOf(offered(world).value(highlighted(world))) == c[1]; },
                  [&] { return QStringLiteral("\"%1\" to be highlighted; row %2 is, of %3").arg(c[1]).arg(highlighted(world)).arg(describeMenu(world)); });
  });
  step(QStringLiteral("the provider command %1 is offered").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return kindOf(item) == QLatin1String("provider-slash-command") && nameOf(item) == c[0]; },
                   QStringLiteral("the provider command \"%1\" to be offered").arg(c[0]));
  });
  step(QStringLiteral("no provider command is offered"), [](World& world, const Captures&, const Table&) {
    // Mid-sentence the menu may not open at all: nothing there starts with the word.
    waitForAnswer(world);
    for (const QVariant& item : offered(world)) {
      expect(kindOf(item) != QLatin1String("provider-slash-command"), QStringLiteral("a provider command is offered: %1").arg(describeMenu(world)));
    }
  });
  step(QStringLiteral("a built-in command or skill is offered"), [](World& world, const Captures&, const Table&) {
    waitForOffered(world, [](const QVariant& item) { return kindOf(item) == QLatin1String("skill") || idOf(item).startsWith(QLatin1String("slash:")); },
                   QStringLiteral("a built-in command or skill to be offered"));
  });
  step(QStringLiteral("the built-in model command is offered"), [](World& world, const Captures&, const Table&) {
    waitForOffered(world, [](const QVariant& item) { return idOf(item) == QLatin1String("slash:model"); }, QStringLiteral("/model to be offered"));
  });
  step(QStringLiteral("the skill %1 is offered").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return kindOf(item) == QLatin1String("skill") && nameOf(item) == c[0]; },
                   QStringLiteral("the skill \"%1\" to be offered").arg(c[0]));
  });
  step(QStringLiteral("the suggestion %1 is offered").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return labelOf(item) == c[0]; }, QStringLiteral("\"%1\" to be offered").arg(c[0]));
  });
  step(QStringLiteral("the skill %1 is offered once").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return nameOf(item) == c[0]; }, QStringLiteral("the skill \"%1\" to be offered").arg(c[0]));
    const QVariantList items = offered(world);
    const auto count = std::count_if(items.cbegin(), items.cend(), [&](const QVariant& item) { return nameOf(item) == c[0]; });
    expect(count == 1, QStringLiteral("\"%1\" is offered %2 times: %3").arg(c[0]).arg(count).arg(describeMenu(world)));
  });
  step(QStringLiteral("only the skills reported for %1 are offered").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = c[0].section(u'/', -1) + QStringLiteral("-deploy");
    waitForMenu(world, [&](const QVariantList& items) {
      return items.size() == 1 && kindOf(items.first()) == QLatin1String("skill") && nameOf(items.first()) == wanted;
    }, QStringLiteral("only \"%1\" to be offered").arg(wanted));
  });
  step(QStringLiteral("the skill %1 is not offered").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForAnswer(world);
    for (const QVariant& item : offered(world)) expect(nameOf(item) != c[0], QStringLiteral("\"%1\" is offered: %2").arg(c[0], describeMenu(world)));
  });
  step(QStringLiteral("%1 is offered once, as the skill").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return nameOf(item) == c[0]; }, QStringLiteral("\"%1\" to be offered").arg(c[0]));
    QStringList kinds;
    for (const QVariant& item : offered(world)) {
      if (nameOf(item) == c[0]) kinds.append(kindOf(item));
    }
    expect(kinds == QStringList{QStringLiteral("skill")}, QStringLiteral("\"%1\" is offered as %2").arg(c[0], kinds.join(u", ")));
  });
  step(QStringLiteral("%1 is offered first, then %1, then %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForMenu(world, [](const QVariantList& items) { return items.size() >= 4; }, QStringLiteral("four suggestions"));
    QStringList names;
    for (const QVariant& item : offered(world)) names.append(nameOf(item));
    const bool ordered = names.size() == 4 && names.at(0) == c[0] && names.at(1) == c[1] &&
                         QSet<QString>{names.at(2), names.at(3)} == QSet<QString>{c[2], c[3]};
    expect(ordered, QStringLiteral("the menu offers %1").arg(names.join(u", ")));
  });
  step(QStringLiteral("%1 is offered before the provider command, and the skill last").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForMenu(world, [](const QVariantList& items) { return items.size() >= 3; }, QStringLiteral("three suggestions"));
    const QVariantList items = offered(world);
    qsizetype builtIn = -1, command = -1, skill = -1;
    for (qsizetype i = 0; i < items.size(); ++i) {
      if (labelOf(items.at(i)) == c[0] && builtIn < 0) builtIn = i;
      if (kindOf(items.at(i)) == QLatin1String("provider-slash-command") && command < 0) command = i;
      if (kindOf(items.at(i)) == QLatin1String("skill")) skill = i;
    }
    expect(builtIn >= 0 && command > builtIn && skill > command && skill == command + 1,
           QStringLiteral("the menu offers %1").arg(describeMenu(world)));
  });
  step(QStringLiteral("the skill is shown as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForOffered(world, [&](const QVariant& item) { return kindOf(item) == QLatin1String("skill") && labelOf(item) == c[0]; },
                   QStringLiteral("a skill shown as \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("no slash command or skill suggestions are offered"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QString kind = composerState(world).value(QStringLiteral("triggerKind")).toString();
    expect(kind != QLatin1String("slash-command") && kind != QLatin1String("skill"), QStringLiteral("a menu is open: %1").arg(describeMenu(world)));
    expect(offered(world).isEmpty(), describeMenu(world));
  });
  step(QStringLiteral("no skill menu opens"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(composerState(world).value(QStringLiteral("triggerKind")).toString() != QLatin1String("skill"), QStringLiteral("the skill menu is open: %1").arg(describeMenu(world)));
  });
  step(QStringLiteral("the skill menu opens"), [](World& world, const Captures&, const Table&) {
    waitForAnswer(world);
    const QVariantMap state = composerState(world);
    expect(state.value(QStringLiteral("triggerKind")) == QLatin1String("skill") &&
               (!offered(world).isEmpty() || !state.value(QStringLiteral("suggestionsEmptyText")).isNull()),
           QStringLiteral("no skill menu: %1").arg(describeMenu(world)));
  });

  // Choosing and dismissing.
  step(QStringLiteral("the user chooses %1 from the suggestions").arg(q), [](World& world, const Captures& c, const Table&) {
    choose(world, idOf(waitForOffered(world, [&](const QVariant& item) { return labelOf(item) == c[0]; }, QStringLiteral("\"%1\" to be offered").arg(c[0]))));
  });
  step(QStringLiteral("the user chooses it"), [](World& world, const Captures&, const Table&) {
    // The model picker's provider-setup offer is chosen in the same words.
    if (modelPickerChoosesSetup(world)) return;
    expect(!refs(world).offered.isEmpty(), QStringLiteral("nothing was offered to choose"));
    choose(world, refs(world).offered);
  });
  step(QStringLiteral("the user chooses the built-in command %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    typeText(world, c[0]);
    const QString id = QStringLiteral("slash:") + c[0].mid(1);
    waitForOffered(world, [&](const QVariant& item) { return idOf(item) == id; }, QStringLiteral("%1 to be offered").arg(c[0]));
    choose(world, id);
  });
  step(QStringLiteral("the user dismisses (?:them with Escape|the suggestions)"), [](World& world, const Captures&, const Table&) {
    expect(pressInComposer(world, QStringLiteral("Escape")), QStringLiteral("the composer is not on screen"));
    settleComposer(world);
  });
  step(QStringLiteral("the user presses Up on the first suggestion"), [](World& world, const Captures&, const Table&) {
    expect(highlighted(world) == 0, QStringLiteral("row %1 is highlighted").arg(highlighted(world)));
    pressInComposer(world, QStringLiteral("Up"));
  });

  // What the draft holds.
  step(QStringLiteral("the (first|last) suggestion is highlighted"), [](World& world, const Captures& c, const Table&) {
    const int count = suggestionList(world)->property("count").toInt();
    const int expected = c[0] == QLatin1String("first") ? 0 : count - 1;
    expect(count > 1 && highlighted(world) == expected, QStringLiteral("row %1 of %2 is highlighted").arg(highlighted(world)).arg(count));
  });
  step(QStringLiteral("the draft references %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString link = composer::pathLink(c[0]).trimmed();
    world.waitFor([&] { return draftText(world).contains(link); }, [&] { return QStringLiteral("the draft to hold %1; it reads \"%2\"").arg(link, draftText(world)); });
  });
  step(QStringLiteral("the draft references the skill %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString skill = u'$' + c[0] + u' ';
    world.waitFor([&] { return draftText(world).contains(skill); }, [&] { return QStringLiteral("the draft to hold %1; it reads \"%2\"").arg(skill, draftText(world)); });
  });
  step(QStringLiteral("the draft reads %1 followed by the skill %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString expected = c[0] + u'$' + c[1] + u' ';
    world.waitFor([&] { return draftText(world) == expected; }, [&] { return QStringLiteral("the draft to read \"%1\"; it reads \"%2\"").arg(expected, draftText(world)); });
  });
  step(QStringLiteral("the draft reads %1 with the caret after the space").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariantMap state = composerState(world);
    expect(state.value(QStringLiteral("text")) == c[0] && state.value(QStringLiteral("cursor")).toInt() == c[0].size() && c[0].endsWith(u' '),
           QStringLiteral("the draft reads \"%1\" with the caret at %2").arg(state.value(QStringLiteral("text")).toString()).arg(state.value(QStringLiteral("cursor")).toInt()));
  });
  step(QStringLiteral("no suggestion is inserted"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    expect(draftText(world) == refs(world).typed && !composerItem(world)->property("suggesting").toBool(),
           QStringLiteral("after Escape %1").arg(describeMenu(world)));
  });
  step(QStringLiteral("%1 is removed from the draft").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    expect(!draftText(world).contains(c[0]), QStringLiteral("the draft reads \"%1\"").arg(draftText(world)));
  });
  step(QStringLiteral("the next letter the user types follows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInComposer(world, QStringLiteral("d"));
    settleComposer(world);
    const QString expected = refs(world).typed + u'd';
    expect(refs(world).typed.endsWith(c[0]) && draftText(world) == expected, QStringLiteral("the draft reads \"%1\"").arg(draftText(world)));
  });

  // What the built-in commands do.
  step(QStringLiteral("the thread switches to planning"), [](World& world, const Captures&, const Table&) { expectInteractionMode(world, QStringLiteral("plan")); });
  step(QStringLiteral("the thread switches back to building"), [](World& world, const Captures&, const Table&) {
    expectInteractionMode(world, QStringLiteral("default"));
  });
  step(QStringLiteral("the user is asked to choose a model"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return modelPickerShownOpen(world); }, QStringLiteral("the model picker to open"));
  });

  // Sending.
  step(QStringLiteral("pressing Enter sends the draft with %1 as typed").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    settleComposer(world);
    expect(pressInComposer(world, QStringLiteral("Enter")), QStringLiteral("the composer is not on screen"));
    world.waitFor([&] {
      for (const QJsonObject& command : world.mc.commands) {
        if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a message to be sent; the MC has %1").arg(world.describeCommands()); });
    QString sent;
    for (const QJsonObject& command : world.mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) sent = command.value(QLatin1String("text")).toString();
    }
    expect(sent == c[0], QStringLiteral("the agent received \"%1\"").arg(sent));
  });
});

}  // namespace
