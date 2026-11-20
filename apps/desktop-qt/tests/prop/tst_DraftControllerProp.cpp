// DraftController as machines leave the cluster, against a fake MC. The
// machine joins with a project and leaves, removed from here or from another
// client; the user writes drafts for it and for this machine, goes home (which
// lands on the most recent project's draft), attaches files to them and removes
// the machine in Cluster settings, the MC holding each answer to give it before
// or after it says the machine went. After every step the drafts the user wrote
// are kept until an answer drops the ones its removal was asked with, unless
// written in or attached to since (even back to the same text), and no empty
// draft is kept for a machine that went (hal-c2#1589).

#include "Prop.h"

#include <QBuffer>
#include <QImage>
#include <QMap>
#include <QSet>
#include <QTemporaryDir>

#include <utility>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

const QString kBox = QStringLiteral("Build box");
const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");
// The machine's project is the most recent, so home lands on its draft.
const QString kLater = QStringLiteral("2026-09-24T09:00:00Z");

QJsonObject project(const QString& id, const QString& at) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("title"), id},
          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
          {QStringLiteral("scripts"), QJsonArray()},
          {QStringLiteral("createdAt"), at},
          {QStringLiteral("updatedAt"), at}};
}

struct Model {
  bool joined = false;
  // The removals the MC has not answered yet.
  int asked = 0;
  // Whether the user wrote a draft on this machine. Those on the other are
  // tracked by their ids (Shell::written).
  int local = 0;
};

// The app on a fake MC with a project of its own, on a home of its own.
struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QList<FakeMc::Rpc> removals;
  // The machine's drafts as each held removal was asked: how often each was
  // written in or attached to by then.
  QList<QMap<QString, int>> asked;
  // How often each of the machine's drafts was written in or attached to.
  QMap<QString, int> touched;
  // The machine's drafts the user wrote, by id, with what they hold.
  QMap<QString, QString> written;
  QSet<QString> reached;
  int writes = 0;

  Shell() {
    mc.projects.insert(QStringLiteral("shop"), project(QStringLiteral("shop"), kAt));
    mc.onRpc(QStringLiteral("cluster."), [this](const FakeMc::Rpc& rpc) {
      if (rpc.method == QLatin1String("cluster.remove")) removals.append(rpc);
      else mc.reply(rpc, QJsonObject());
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] { return native.isActive() && native.store()->synchronized(); })) qFatal("the shell did not start");
  }

  DraftController* drafts() const { return native.controller<DraftController>(); }
  ShellStore* store() { return native.store(); }

  // Waits for whatever the MC has sent so far to reach the shell.
  void barrier() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  // What the draft holds: its text, and how many files are attached to it.
  QString holds(const QString& id) const {
    const auto draft = drafts()->draft(id);
    const qsizetype files = native.controller<ComposerController>()->attachments(id).size();
    return (draft ? draft->text : QString()) + QStringLiteral(" +%1").arg(files);
  }

  // The drafts kept for the environment: their ids, and what they hold.
  QMap<QString, QString> kept(const QString& environment, bool writtenOnly = true) const {
    QMap<QString, QString> found;
    for (const DraftController::Draft& draft : drafts()->drafts()) {
      const QString held = holds(draft.id);
      if (draft.environmentId == environment && (!writtenOnly || held != QLatin1String(" +0"))) found.insert(draft.id, held);
    }
    return found;
  }

  // The machine's drafts as they are now, by how often each was touched.
  QMap<QString, int> doomed() const {
    QMap<QString, int> found;
    for (const DraftController::Draft& draft : drafts()->drafts()) {
      if (draft.environmentId == kBox) found.insert(draft.id, touched.value(draft.id));
    }
    return found;
  }

  void check(const Model& model) {
    barrier();
    RC_ASSERT(store()->servesEnvironment(kBox) == model.joined);
    RC_ASSERT(int(removals.size()) == model.asked);
    RC_ASSERT(int(asked.size()) == model.asked);
    RC_ASSERT(int(kept(mc.environmentId).size()) == model.local);
    // What the user wrote for the machine is kept, as written.
    RC_ASSERT(kept(kBox) == written);
    // No empty draft is kept for a machine that went.
    if (!model.joined) RC_ASSERT(kept(kBox, false) == written);
  }

  // Nothing held, the machine gone, no drafts, and the window home.
  Model reset() {
    for (const FakeMc::Rpc& rpc : std::exchange(removals, {})) mc.reply(rpc, QJsonObject());
    asked.clear();
    touched.clear();
    written.clear();
    if (mc.peers.contains(kBox)) mc.remove(kBox);
    barrier();
    RC_ASSERT(prop::until([this] { return !store()->servesEnvironment(kBox); }));
    // A copy: removing one changes the list.
    const QList<DraftController::Draft> all = drafts()->drafts();
    for (const DraftController::Draft& draft : all) drafts()->remove(draft.id);
    native.controller<NavigationController>()->open(NavigationController::Route());
    Model model;
    check(model);
    return model;
  }
};

using Command = rc::state::Command<Model, Shell>;

// The machine joins the cluster with its project.
struct Join : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.joined); }
  void apply(Model& model) const override { model.joined = true; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.mc.join(kBox);
    shell.mc.sendPeerRow(kBox, QStringLiteral("ops"), project(QStringLiteral("ops"), kLater), QStringLiteral("project"));
    RC_ASSERT(prop::until([&shell] { return bool(shell.store()->project(kBox + QStringLiteral(":ops"))); }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Join"; }
};

// The user writes in the project's draft on this machine or on the other, new
// text or the first text again.
struct Write : Command {
  bool box = *rc::gen::arbitrary<bool>();
  bool again = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override { RC_PRE(!box || model.joined); }
  void apply(Model& model) const override {
    // One draft per project, written in again.
    if (!box) model.local = 1;
  }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    const QString id = box ? shell.drafts()->start(kBox, QStringLiteral("ops"))
                           : shell.drafts()->start(shell.mc.environmentId, QStringLiteral("shop"));
    RC_ASSERT(!id.isEmpty());
    const QString text = again ? QStringLiteral("roll back the deploy")
                               : QStringLiteral("roll back the deploy %1").arg(++shell.writes);
    const bool edits = shell.drafts()->draft(id)->text != text;
    shell.drafts()->setText(id, text);
    if (box) {
      if (edits) ++shell.touched[id];
      shell.written.insert(id, shell.holds(id));
    }
    shell.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Write(" << (box ? "Build box" : "here") << (again ? ", again" : "") << ")";
  }
};

// The window opens the machine's project's draft and the user attaches a file
// to it.
struct Attach : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.joined); }
  void apply(Model&) const override {}
  void run(const Model& model, Shell& shell) const override {
    const QString id = shell.drafts()->start(kBox, QStringLiteral("ops"));
    RC_ASSERT(!id.isEmpty());
    RC_ASSERT(prop::until([&] {
      return shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString() == id;
    }));
    auto* composer = shell.native.controller<ComposerController>();
    const qsizetype files = composer->attachments(id).size();
    QImage picture(8, 8, QImage::Format_RGB32);
    picture.fill(Qt::darkCyan);
    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, "PNG");
    shell.bridge.dispatch(QStringLiteral("composer.attach"),
                          QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{
                                                                    {QStringLiteral("name"), QStringLiteral("shot.png")},
                                                                    {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                    {QStringLiteral("base64"), QString::fromLatin1(png.toBase64())},
                                                                }}}});
    RC_ASSERT(prop::until([&] { return composer->attachments(id).size() == files + 1; }));
    ++shell.touched[id];
    shell.written.insert(id, shell.holds(id));
    shell.check(model);
  }
  void show(std::ostream& os) const override { os << "Attach"; }
};

// The window goes home, which lands on the most recent project's draft.
struct Home : Command {
  void apply(Model&) const override {}
  void run(const Model& model, Shell& shell) const override {
    shell.native.controller<NavigationController>()->open(NavigationController::Route());
    shell.check(model);
  }
  void show(std::ostream& os) const override { os << "Home"; }
};

// The user removes the machine in Cluster settings; the MC holds its answer.
struct Remove : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.joined); }
  void apply(Model& model) const override { ++model.asked; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.asked.append(shell.doomed());
    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    RC_ASSERT(prop::until([&] { return int(shell.removals.size()) == next.asked; }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Remove"; }
};

// The MC answers the oldest removal, and the drafts the machine had when it
// was asked go; one started, written in or attached to since stays.
struct Answer : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.asked > 0); }
  void apply(Model& model) const override { --model.asked; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    if (model.joined) shell.reached.insert(QStringLiteral("answered first"));
    else shell.reached.insert(QStringLiteral("answered after"));
    const QMap<QString, int> doomed = shell.asked.takeFirst();
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    for (auto it = doomed.cbegin(); it != doomed.cend(); ++it) {
      if (shell.touched.value(it.key()) == it.value()) shell.written.remove(it.key());
    }
    shell.check(next);
    for (auto it = doomed.cbegin(); it != doomed.cend(); ++it) {
      // RC_ASSERT takes its expression apart, so `&&` would not short-circuit.
      const bool kept = shell.drafts()->draft(it.key()) && shell.touched.value(it.key()) == it.value();
      RC_ASSERT(!kept);
    }
  }
  void show(std::ostream& os) const override { os << "Answer"; }
};

// The MC says the machine went, removed here or from another client, or only
// switched off: its rows go, and its empty drafts with them.
struct Leave : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.joined); }
  void apply(Model& model) const override { model.joined = false; }
  void run(const Model& model, Shell& shell) const override {
    Model next = model;
    apply(next);
    shell.mc.remove(kBox);
    RC_ASSERT(prop::until([&shell] { return !shell.store()->servesEnvironment(kBox); }));
    shell.check(next);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

}  // namespace

class DraftControllerProp : public QObject {
  Q_OBJECT

private slots:
  void drafts() {
    Shell shell;
    QVERIFY(rc::check("what was written for a machine stays until the answer to its removal, and nothing empty outlives it", [&shell] {
      const Model initial = shell.reset();
      shell.reached.clear();
      rc::state::check(initial, shell,
                       rc::state::gen::execOneOfWithArgs<Join, Join, Write, Write, Attach, Home, Remove, Remove, Answer, Answer, Leave>());
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answered first")), "a removal answered while the machine was listed");
      RC_CLASSIFY(shell.reached.contains(QStringLiteral("answered after")), "a removal answered after the machine went");
    }));
  }
};

HAL_C2_PROP_MAIN(DraftControllerProp)
#include "tst_DraftControllerProp.moc"
