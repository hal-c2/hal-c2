// The composer's $ menu offers the skills of the folder its thread works in.
// The provider's entry has one skill of its own; each folder's are the MC's to
// read, which it does only when a composer asks for that folder
// (`server.refreshProviders` with a `cwd`) and then announces with the
// providers. The composer asks once for each folder its thread works in, the
// first time it works there; the menu offers the entry's skill, and the
// folder's once the MC has read them, one per name, never another folder's.
// Scope: one thread on one online environment, the caret at the end of the
// text, within the five minutes after which a folder is asked again. Not
// modelled: the environment dropping while a read is held.

#include "Prop.h"

#include <QSet>

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "WorkspaceController.h"

namespace prop = halc2::prop;

namespace {

const QStringList kTexts{QString(), QStringLiteral("hello"), QStringLiteral("$")};
// The folders the thread can work in: the project's root, then worktrees.
const QStringList kFolders{QStringLiteral("/work/shop"), QStringLiteral("/work/worktrees/1"), QStringLiteral("/work/worktrees/2")};
// The entry's own skill, which each folder's snapshot also reports.
const QString kEverywhere = QStringLiteral("everywhere");

QString folderSkill(const QString& folder) { return folder.section(u'/', -1) + QStringLiteral("-deploy"); }

QJsonObject skill(const QString& name) {
  return QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("path"), QStringLiteral("/skills/") + name}, {QStringLiteral("enabled"), true}};
}

struct Model {
  QString text;
  int folder = 0;
  bool holding = false;
  // The folders the composer asked for, and those the MC has read.
  QSet<QString> asked{kFolders.first()};
  QSet<QString> read{kFolders.first()};

  QString cwd() const { return kFolders.at(folder); }
  bool menu() const { return text == QLatin1String("$"); }
  QStringList skills() const {
    QStringList names{kEverywhere};
    if (read.contains(cwd())) names.append(folderSkill(cwd()));
    names.sort();
    return names;
  }
};

struct Sut {
  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), kFolders.first()},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("t1")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers()}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), QJsonArray()}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 0},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    // The MC reads the folder (HalC2.Environment.refresh_providers) and
    // announces the providers with its snapshot; held, it reads it later.
    mc.onRpc(QStringLiteral("server.refreshProviders"), [this](const FakeMc::Rpc& rpc) {
      if (holding) {
        held.append(rpc);
        return;
      }
      readFolder(rpc);
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->threadOnline(key); }));
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    RC_ASSERT(prop::until([this] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(key);
      return timeline && timeline->status() == QLatin1String("live") && shown().value(QStringLiteral("target")).toString() == key;
    }));
    // The project's folder is read as the thread opens, before any hold.
    RC_ASSERT(prop::until([this] { return asks(kFolders.first()) >= 1; }));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  QJsonArray providers() const {
    return QJsonArray{QJsonObject{
        {QStringLiteral("instanceId"), QStringLiteral("codex")},
        {QStringLiteral("driver"), QStringLiteral("codex")},
        {QStringLiteral("enabled"), true},
        {QStringLiteral("status"), QStringLiteral("ready")},
        {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-a")}}}},
        {QStringLiteral("slashCommands"), QJsonArray()},
        {QStringLiteral("skills"), QJsonArray{skill(kEverywhere)}},
        {QStringLiteral("workspaceSnapshots"), snapshots},
    }};
  }

  void readFolder(const FakeMc::Rpc& rpc) {
    const QString cwd = rpc.payload.value(QLatin1String("cwd")).toString();
    if (!cwd.isEmpty()) {
      snapshots.append(QJsonObject{{QStringLiteral("cwd"), cwd},
                                   {QStringLiteral("checkedAt"), QStringLiteral("2026-11-11T12:00:00Z")},
                                   {QStringLiteral("slashCommands"), QJsonArray()},
                                   {QStringLiteral("skills"), QJsonArray{skill(folderSkill(cwd)), skill(kEverywhere)}}});
      for (const int id : mc.subscribers(QStringLiteral("config"))) {
        mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers()}});
      }
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("providers"), providers()}});
  }

  // How many times the composer asked for the folder.
  int asks(const QString& cwd) const {
    return int(std::count_if(mc.calls.cbegin(), mc.calls.cend(), [&](const FakeMc::Rpc& rpc) {
      return rpc.method == QLatin1String("server.refreshProviders") && rpc.payload.value(QLatin1String("cwd")).toString() == cwd;
    }));
  }

  QVariantMap shown() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }

  // The skills the menu offers, by name, sorted.
  QStringList skillsShown() const {
    QStringList names;
    for (const QVariant& item : shown().value(QStringLiteral("suggestions")).toList()) {
      const QVariantMap map = item.toMap();
      if (map.value(QStringLiteral("kind")).toString() == QLatin1String("skill")) {
        names.append(map.value(QStringLiteral("id")).toString().section(u':', 2));
      }
    }
    names.sort();
    return names;
  }

  void type(const QString& text) {
    bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), key},
                                                                    {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                                         {QStringLiteral("revision"), ++revision}}},
                                                                    {QStringLiteral("text"), text},
                                                                    {QStringLiteral("cursor"), text.size()}});
  }

  void workIn(const QString& cwd) {
    QJsonObject& row = mc.threads[QStringLiteral("t1")];
    row.insert(QStringLiteral("worktreePath"), cwd);
    mc.sendRow(QStringLiteral("t1"), row);
  }

  QTemporaryDir home;
  FakeMc mc;
  bool holding = false;
  QList<FakeMc::Rpc> held;
  QJsonArray snapshots;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString key = QStringLiteral("env-a:t1");
  int revision = 0;
};

bool menuIs(const Model& m, const Sut& sut) {
  const QVariantMap shown = sut.shown();
  if (shown.value(QStringLiteral("text")).toString() != m.text) return false;
  const QStringList skills = sut.skillsShown();
  if (!m.menu()) return skills.isEmpty();
  return skills == m.skills() && int(shown.value(QStringLiteral("suggestions")).toList().size()) == int(skills.size());
}

void verify(const Model& m, Sut& sut) {
  for (const QString& folder : m.asked) RC_ASSERT(prop::until([&] { return sut.asks(folder) >= 1; }));
  RC_ASSERT(prop::until([&] { return menuIs(m, sut); }));
  // Once the menu matches, each folder was asked exactly as often as the model says.
  for (const QString& folder : kFolders) {
    RC_LOG() << folder.toStdString() << " asked " << sut.asks(folder) << " times\n";
    RC_ASSERT(sut.asks(folder) == (m.asked.contains(folder) ? 1 : 0));
  }
}

using Command = rc::state::Command<Model, Sut>;

struct Type : Command {
  QString text = *rc::gen::elementOf(std::vector<QString>(kTexts.cbegin(), kTexts.cend()));
  void apply(Model& m) const override { m.text = text; }
  void run(const Model& m0, Sut& sut) const override {
    sut.type(text);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Type(\"" << text.toStdString() << "\")"; }
};

// The thread moves to another folder, one it may have worked in before.
struct WorkIn : Command {
  int folder = *rc::gen::inRange(0, int(kFolders.size()));
  void checkPreconditions(const Model& m) const override { RC_PRE(folder != m.folder); }
  void apply(Model& m) const override {
    m.folder = folder;
    m.asked.insert(m.cwd());
    if (!m.holding) m.read.insert(m.cwd());
  }
  void run(const Model& m0, Sut& sut) const override {
    const QString cwd = kFolders.at(folder);
    sut.workIn(cwd);
    RC_ASSERT(prop::until([&] {
      const auto& place = sut.native->controller<WorkspaceController>()->place();
      return place && place->cwd() == cwd;
    }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "WorkIn(" << kFolders.at(folder).toStdString() << ")"; }
};

// The MC holds the folders it is asked to read from now on.
struct Hold : Command {
  void apply(Model& m) const override { m.holding = true; }
  void run(const Model& m0, Sut& sut) const override {
    sut.holding = true;
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// It reads every folder it held, the older ones after the thread moved on.
struct ReadHeld : Command {
  void apply(Model& m) const override {
    m.holding = false;
    m.read = m.asked;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.holding = false;
    const QList<FakeMc::Rpc> held = std::exchange(sut.held, {});
    for (const FakeMc::Rpc& rpc : held) sut.readFolder(rpc);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "ReadHeld"; }
};

}  // namespace

class ComposerFolderSkillsProp : public QObject {
  Q_OBJECT

private slots:
  void theSkillMenuOffersTheFolderItsThreadWorksIn() {
    QVERIFY(rc::check("each folder is asked for once, and $ offers the entry's skills and the current folder's once read, one per name", [] {
      Sut sut;
      Model model;
      const auto commands = *rc::gen::scale(0.5, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Type, Type, WorkIn, Hold, ReadHeld>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerFolderSkillsProp)
#include "tst_ComposerFolderSkillsProp.moc"
