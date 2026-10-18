// WorkspaceController::openHere: an editor or the file manager starts only on
// the machine the user sits at. The MC and a cluster member each say which
// machine they run on (`platform.machineId`: this one, another, or none) and
// change their minds; the member joins late; the MC drops and comes back,
// announcing what changed meanwhile in its snapshot; the user goes between a
// thread of each and opens files, the file manager and the workspace.
//
// The model is where the shell may start one: the environment says it is on
// this machine, or, saying nothing, it is the shell's own MC on a loopback
// address (the fake MC's). Every open there asks that environment's MC to
// start it on the path. A member's file elsewhere opens from the folder the
// shell's MC keeps for it, when that MC runs here and answers files.localPath
// with one (an older MC answers null, one without FUSE says why); the shell's
// MC starts it there. Every other open asks no MC to start anything and tells
// the user why. Whichever thread is open, the editors offered are this
// machine's: the thread's environment's when it runs here, else the shell's own.

#include "Prop.h"

#include <QJsonArray>
#include <QTemporaryDir>
#include <QTimeZone>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThisMachine.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace prop = halc2::prop;

namespace {

const QString kHere = QStringLiteral("5e1f00000000000000000000000000000000000000000000000000000000c0de");
const QString kElsewhere = QStringLiteral("a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1");
const QString kMember = QStringLiteral("env-c");
const QString kTold = QStringLiteral("The files are on another machine and can't be opened here yet.");
const QString kFolders = QStringLiteral("/home/user/.local/state/hal-c2/elixir/machines");
const QString kNoFuse = QStringLiteral("The file is on \"env-c\". To open it here, install FUSE 3 (fuse3).");
const QDateTime kEpoch(QDate(2026, 10, 16), QTime(9, 0), QTimeZone::UTC);

enum class Machine { Here, Elsewhere, Unsaid };
enum class Open { File, Reveal, Workspace };
// How the shell's MC answers files.localPath for the member.
enum class Folder { Older, Mounted, NoFuse };

void showValue(Machine machine, std::ostream& os) {
  os << (machine == Machine::Here ? "here" : machine == Machine::Elsewhere ? "elsewhere" : "unsaid");
}
void showValue(Folder folder, std::ostream& os) {
  os << (folder == Folder::Older ? "older" : folder == Folder::Mounted ? "mounted" : "no fuse");
}
void showValue(Open open, std::ostream& os) {
  os << (open == Open::File ? "file" : open == Open::Reveal ? "reveal" : "workspace");
}

QJsonObject platformOf(Machine machine) {
  if (machine == Machine::Unsaid) return {};
  return {{QStringLiteral("machineId"), machine == Machine::Here ? kHere : kElsewhere}};
}

// Each MC's editors, told apart so the list offered says whose it is.
QJsonArray editorsOf(bool member) {
  return member ? QJsonArray{QStringLiteral("zed"), QStringLiteral("file-manager")}
                : QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")};
}

struct Model {
  Machine own = Machine::Unsaid;
  Machine member = Machine::Unsaid;
  bool joined = false;
  bool connected = true;
  Folder folder = Folder::Older;
  // The thread open: -1 none, 0 the MC's own, 1 the member's.
  int route = -1;

  bool here(int which) const {
    // Unsaid, the shell's own MC is here by its loopback address; a member never is.
    return which == 0 ? own != Machine::Elsewhere : member == Machine::Here;
  }
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  // Every `shell.openInEditor`: the environment it was for and its payload.
  QList<std::pair<QString, QJsonObject>> opened;
  Folder folder = Folder::Older;

  Sut() {
    thisMachine::setIdForTesting(kHere);
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject& shape) {
      const bool member = shape.value(QLatin1String("environment")).toString() == kMember;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()},
                                                      {QStringLiteral("availableEditors"), editorsOf(member)},
                                                      {QStringLiteral("shellRevealInFileManager"), true}}}});
    });
    mc.onRpc(QStringLiteral("shell.openInEditor"), [this](const FakeMc::Rpc& rpc) {
      opened.append({rpc.environment.isEmpty() ? mc.environmentId : rpc.environment, rpc.payload});
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(QStringLiteral("files.localPath"), [this](const FakeMc::Rpc& rpc) {
      // Asked of the shell's own MC, for the member's file.
      const QString environment = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
      if (environment != mc.environmentId || rpc.payload.value(QLatin1String("environmentId")).toString() != kMember) {
        mc.refuse(rpc, QStringLiteral("files.localPath was asked of %1 for %2").arg(environment, rpc.payload.value(QLatin1String("environmentId")).toString()));
        return;
      }
      const QString path = rpc.payload.value(QLatin1String("path")).toString();
      if (folder == Folder::Older) {
        mc.reply(rpc, QJsonValue::Null);
      } else if (folder == Folder::Mounted) {
        mc.reply(rpc, QJsonObject{{QStringLiteral("path"), kFolders + QLatin1Char('/') + kMember + path}});
      } else {
        mc.reply(rpc, QJsonObject{{QStringLiteral("reason"), QStringLiteral("no_fuse")}, {QStringLiteral("machine"), kMember}, {QStringLiteral("message"), kNoFuse}});
      }
    });
    mc.projects.insert(QStringLiteral("p1"), project(QStringLiteral("p1"), QStringLiteral("/work/p1")));
    mc.threads.insert(QStringLiteral("t1"), thread(QStringLiteral("t1"), QStringLiteral("p1")));
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->synchronized(); }));
    native->controller<ToastController>()->setClock([] { return kEpoch; });
  }

  ~Sut() {
    native.reset();
    thisMachine::setIdForTesting(std::nullopt);
  }

  static QJsonObject project(const QString& id, const QString& root) {
    return {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("workspaceRoot"), root}, {QStringLiteral("scripts"), QJsonArray()}};
  }
  static QJsonObject thread(const QString& id, const QString& projectId) {
    return {{QStringLiteral("id"), id},
            {QStringLiteral("title"), id},
            {QStringLiteral("projectId"), projectId},
            {QStringLiteral("createdAt"), QStringLiteral("2026-10-16T08:00:00Z")},
            {QStringLiteral("updatedAt"), QStringLiteral("2026-10-16T08:00:00Z")}};
  }

  static QString environmentOf(int which) { return which == 0 ? QStringLiteral("env-a") : kMember; }
  static QString keyOf(int which) { return which == 0 ? QStringLiteral("env-a:t1") : kMember + QStringLiteral(":t7"); }
  static QString rootOf(int which) { return which == 0 ? QStringLiteral("/work/p1") : QStringLiteral("/work/ops"); }

  WorkspaceController* workspace() const { return native->controller<WorkspaceController>(); }
  QVariantMap state() const { return bridge.state()->value(QStringLiteral("workspace")).toMap(); }

  QStringList offered() const {
    QStringList ids;
    for (const QVariant& editor : state().value(QStringLiteral("editors")).toList()) ids.append(editor.toMap().value(QStringLiteral("id")).toString());
    return ids;
  }

  // The newest toast's id and title.
  std::pair<QString, QString> newestToast() const {
    const QVariantList items = bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    if (items.isEmpty()) return {};
    const QVariantMap first = items.first().toMap();
    return {first.value(QStringLiteral("id")).toString(), first.value(QStringLiteral("title")).toString()};
  }

  int shellSubscriptions() const {
    int count = 0;
    for (const QJsonObject& sub : mc.subscriptions) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) count++;
    }
    return count;
  }

  // A round trip through the MC: what the shell asked before is in.
  void sync() {
    auto done = std::make_shared<bool>(false);
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [done](const QJsonValue&, const std::optional<QString>&) { *done = true; });
    RC_ASSERT(prop::until([done] { return *done; }));
  }

  // The shell holds each environment's machine as the model has it.
  void sees(const Model& model) const {
    const auto holds = [this](const QString& environment, Machine machine) {
      return native->store()->environment(environment).value(QLatin1String("platform")).toObject().value(QLatin1String("machineId")).toString() ==
             platformOf(machine).value(QLatin1String("machineId")).toString();
    };
    RC_ASSERT(prop::until([&] { return holds(QStringLiteral("env-a"), model.own) && (!model.joined || holds(kMember, model.member)); }));
  }
};

using Command = rc::state::Command<Model, Sut>;

struct Announce : Command {
  explicit Announce(const Model&) {}
  int which = *rc::gen::inRange(0, 2);
  Machine machine = *rc::gen::element(Machine::Here, Machine::Elsewhere, Machine::Unsaid);

  void checkPreconditions(const Model& model) const override { RC_PRE(which == 0 || model.joined); }
  void apply(Model& model) const override { (which == 0 ? model.own : model.member) = machine; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    // Unheard while the MC is down; its snapshot says so on the way back.
    if (which == 0) {
      sut.mc.platform = platformOf(machine);
      sut.mc.announceEnvironment();
    } else {
      sut.mc.peerPlatforms.insert(kMember, platformOf(machine));
      sut.mc.join(QStringLiteral("mc-c"), kMember);
    }
    if (next.connected) sut.sees(next);
  }
  void show(std::ostream& os) const override {
    os << "Announce(" << (which == 0 ? "own" : "member") << ", ";
    showValue(machine, os);
    os << ")";
  }
};

struct Join : Command {
  explicit Join(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.joined && model.connected); }
  void apply(Model& model) const override { model.joined = true; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.mc.join(QStringLiteral("mc-c"), kMember);
    sut.mc.sendPeerRow(kMember, QStringLiteral("ops"), Sut::project(QStringLiteral("ops"), Sut::rootOf(1)), QStringLiteral("project"));
    sut.mc.sendPeerRow(kMember, QStringLiteral("t7"), Sut::thread(QStringLiteral("t7"), QStringLiteral("ops")));
    sut.sync();
    sut.sees(next);
  }
  void show(std::ostream& os) const override { os << "Join"; }
};

struct Go : Command {
  explicit Go(const Model&) {}
  int which = *rc::gen::inRange(0, 2);

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected && (which == 0 || model.joined)); }
  void apply(Model& model) const override { model.route = which; }
  void run(const Model&, Sut& sut) const override {
    sut.native->controller<NavigationController>()->open(NavigationController::Route::thread(Sut::keyOf(which)));
    RC_ASSERT(prop::until([&] { return sut.state().value(QStringLiteral("threadKey")) == Sut::keyOf(which); }));
  }
  void show(std::ostream& os) const override { os << "Go(" << (which == 0 ? "own" : "member") << ")"; }
};

struct Answer : Command {
  explicit Answer(const Model&) {}
  Folder folder = *rc::gen::element(Folder::Older, Folder::Mounted, Folder::NoFuse);
  void apply(Model& model) const override { model.folder = folder; }
  void run(const Model&, Sut& sut) const override { sut.folder = folder; }
  void show(std::ostream& os) const override {
    os << "Answer(";
    showValue(folder, os);
    os << ")";
  }
};

struct Drop : Command {
  explicit Drop(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected); }
  void apply(Model& model) const override { model.connected = false; }
  void run(const Model&, Sut& sut) const override {
    sut.mc.stopAccepting();
    sut.mc.drop();
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

struct Reconnect : Command {
  explicit Reconnect(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.connected); }
  void apply(Model& model) const override { model.connected = true; }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const int before = sut.shellSubscriptions();
    sut.mc.startAccepting();
    RC_ASSERT(prop::until([&] { return sut.shellSubscriptions() > before; }));
    sut.sync();
    sut.sees(next);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

struct OpenIt : Command {
  explicit OpenIt(const Model&) {}
  Open open = *rc::gen::element(Open::File, Open::Reveal, Open::Workspace);

  void checkPreconditions(const Model& model) const override { RC_PRE(model.connected && model.route >= 0); }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    const int which = model.route;
    // This machine's editors: the thread's MC's when it runs here, else the shell's.
    const bool memberList = which == 1 && model.here(1);
    QStringList expected;
    for (const QJsonValue& id : editorsOf(memberList)) expected.append(id.toString());
    RC_ASSERT(prop::until([&] { return sut.offered() == expected; }));

    const QString editor = open == Open::Reveal ? QStringLiteral("file-manager") : expected.first();
    const QString path = open == Open::Workspace ? Sut::rootOf(which) : Sut::rootOf(which) + QStringLiteral("/src/app.ts");
    const qsizetype before = sut.opened.size();
    const QString toastBefore = sut.newestToast().first;
    if (open == Open::Workspace) {
      sut.bridge.dispatch(QStringLiteral("workspace.openInEditor"), QVariantMap{{QStringLiteral("editorId"), editor}});
    } else {
      RC_ASSERT(sut.workspace()->openInEditor(open == Open::Reveal ? QString() : editor, path, open == Open::Reveal));
    }
    // Two round trips: the shell may ask where the file is here before it asks to open it.
    sut.sync();
    sut.sync();
    const auto [toastId, toastTitle] = sut.newestToast();
    // A member's file elsewhere is in the shell's MC's folder for it, when that MC runs here.
    const bool asked = !model.here(which) && which == 1 && model.here(0);
    const bool mounted = asked && model.folder == Folder::Mounted;
    if (model.here(which) || mounted) {
      QJsonObject payload{{QStringLiteral("cwd"), mounted ? kFolders + QLatin1Char('/') + kMember + path : path}, {QStringLiteral("editor"), editor}};
      if (open == Open::Reveal) payload.insert(QStringLiteral("reveal"), true);
      RC_ASSERT(sut.opened.size() == before + 1);
      RC_ASSERT(sut.opened.last().first == (mounted ? Sut::environmentOf(0) : Sut::environmentOf(which)));
      RC_ASSERT(sut.opened.last().second == payload);
      RC_ASSERT(toastId == toastBefore);
    } else {
      RC_ASSERT(sut.opened.size() == before);
      RC_ASSERT(toastId != toastBefore);
      RC_ASSERT(toastTitle == (asked && model.folder == Folder::NoFuse ? kNoFuse : kTold));
    }
  }
  void show(std::ostream& os) const override {
    os << "Open(";
    showValue(open, os);
    os << ")";
  }
};

}  // namespace

class WorkspaceOpenHereProp : public QObject {
  Q_OBJECT

private slots:
  void model() {
    QVERIFY(rc::check("an editor or the file manager starts only on this machine, whatever the MCs say and when", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Announce, Announce, Announce, Join, Go, Go, Answer, Drop, Reconnect, OpenIt, OpenIt, OpenIt>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceOpenHereProp)
#include "tst_WorkspaceOpenHereProp.moc"
