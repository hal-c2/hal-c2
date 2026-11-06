// PlanController saving the open thread's plan to its workspace, against a fake
// MC that holds every write and answers it, or refuses it, when told. The user
// saves again and again, sometimes with no path, while writes are under way.
//
// What the user is promised: an empty path writes nothing and says so; only one
// write is under way at a time, and saving meanwhile sends nothing; each write
// carries the plan whole, ending in one newline, at the path given, trimmed;
// `planSave` says a save is under way exactly while one is, and counts the
// writes that went through, so the dialog closes on one and stays open on a
// refusal; and each answer is told as a toast.

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
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QString kKey = QStringLiteral("env-a:t1");
const QString kRoot = QStringLiteral("/work/p1");
const QString kMarkdown = QStringLiteral("# Tax line\n\n- add it\n\n\n");
const QStringList kPaths{QString(), QStringLiteral("  "), QStringLiteral("tax-line.md"), QStringLiteral(" plans/tax.md ")};
const QDateTime kEpoch(QDate(2026, 11, 6), QTime(9, 0), QTimeZone::UTC);

struct Model {
  bool saving = false;
  int saved = 0;
  int sent = 0;
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  QList<FakeMc::Rpc> held;
  int sent = 0;

  Sut() {
    mc.onRpc(QStringLiteral("projects.writeFile"), [this](const FakeMc::Rpc& rpc) {
      ++sent;
      held.append(rpc);
    });
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("p1")},
                                                         {QStringLiteral("workspaceRoot"), kRoot},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("title"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-11-06T08:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-11-06T08:00:00Z")}});
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->store()->synchronized(); }));
    native->controller<ToastController>()->setClock([] { return kEpoch; });
    native->controller<NavigationController>()->open(NavigationController::Route::thread(kKey));
    RC_ASSERT(prop::until([this] { return turn().value(QStringLiteral("threadKey")) == kKey; }));
    sync();
    // The plan the thread offers, as the composer publishes it once the agent proposed one.
    QVariantMap offered = turn();
    offered.insert(QStringLiteral("plan"), QVariantMap{{QStringLiteral("id"), QStringLiteral("plan-1")}, {QStringLiteral("markdown"), kMarkdown}});
    bridge.publish(QStringLiteral("turn"), offered);
  }

  ~Sut() { native.reset(); }

  QVariantMap turn() const { return bridge.state()->value(QStringLiteral("turn")).toMap(); }
  QVariantMap planSave() const { return bridge.state()->value(QStringLiteral("planSave")).toMap(); }

  QString newestToast() const {
    const QVariantList items = bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    return items.isEmpty() ? QString() : items.first().toMap().value(QStringLiteral("title")).toString();
  }

  // A round trip through the MC: what the shell asked before is in, and answered.
  void sync() {
    auto done = std::make_shared<bool>(false);
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [done](const QJsonValue&, const std::optional<QString>&) { *done = true; });
    RC_ASSERT(prop::until([done] { return *done; }));
  }

  void check(const Model& model) const {
    RC_ASSERT(sent == model.sent);
    RC_ASSERT(held.size() == (model.saving ? 1 : 0));
    RC_ASSERT(planSave().value(QStringLiteral("saving")).toBool() == model.saving);
    RC_ASSERT(planSave().value(QStringLiteral("saved")).toInt() == model.saved);
  }
};

using Command = rc::state::Command<Model, Sut>;

struct Save : Command {
  explicit Save(const Model&) {}
  QString path = *rc::gen::elementOf(std::vector<QString>(kPaths.begin(), kPaths.end()));

  bool empty() const { return path.trimmed().isEmpty(); }
  void apply(Model& model) const override {
    if (empty() || model.saving) return;
    model.saving = true;
    model.sent++;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.bridge.dispatch(QStringLiteral("plan.save"), QVariantMap{{QStringLiteral("path"), path}});
    sut.sync();
    sut.check(next);
    if (empty()) RC_ASSERT(sut.newestToast() == QStringLiteral("Enter a workspace path"));
    if (next.sent > model.sent) {
      const QJsonObject payload = sut.held.last().payload;
      RC_ASSERT(payload.value(QLatin1String("cwd")).toString() == kRoot);
      RC_ASSERT(payload.value(QLatin1String("relativePath")).toString() == path.trimmed());
      RC_ASSERT(payload.value(QLatin1String("contents")).toString() == QStringLiteral("# Tax line\n\n- add it\n"));
    }
  }
  void show(std::ostream& os) const override { os << "Save(\"" << path.toStdString() << "\")"; }
};

struct Answer : Command {
  explicit Answer(const Model&) {}
  bool refused = *rc::gen::arbitrary<bool>();

  void checkPreconditions(const Model& model) const override { RC_PRE(model.saving); }
  void apply(Model& model) const override {
    model.saving = false;
    if (!refused) model.saved++;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const FakeMc::Rpc rpc = sut.held.takeFirst();
    if (refused) {
      sut.mc.refuse(rpc, QStringLiteral("EACCES: permission denied"));
    } else {
      sut.mc.reply(rpc, QJsonObject{{QStringLiteral("relativePath"), rpc.payload.value(QLatin1String("relativePath"))}});
    }
    sut.sync();
    sut.check(next);
    RC_ASSERT(sut.newestToast() == (refused ? QStringLiteral("Could not save plan") : QStringLiteral("Plan saved to workspace")));
  }
  void show(std::ostream& os) const override { os << "Answer(" << (refused ? "refused" : "written") << ")"; }
};

}  // namespace

class PlanSaveProp : public QObject {
  Q_OBJECT

private slots:
  void model() {
    QVERIFY(rc::check("one plan save at a time, each told, and counted only when it went through", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Save, Save, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(PlanSaveProp)
#include "tst_PlanSaveProp.moc"
