// WorkspaceFiles saving edits against a fake MC that holds every write and
// answers them in any order. Two environments: env-a's session has terminal
// access, env-b's does not, so env-b refuses a write by full path (a file
// outside the workspace) for want of terminal:operate, as the MC's socket does
// (apps/server-ex lib/hal_c2/rpc.ex required_scope/2). Meanwhile the user moves
// between the environments and between a project file and two files outside
// it, edits, and closes.
//
// What the user is promised: a write only ever carries the text of the file it
// writes; once an environment refused a write by full path, its files outside
// the workspace open read-only and nothing more is sent to it by full path;
// every other edit is still written once its writes are answered; and the agent
// rewriting the open file never takes back an edit: a read from before a save
// is not shown after it, however late it is answered.

#include "Prop.h"

#include <QJsonArray>
#include <QJsonObject>

#include <functional>

#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"

namespace {

const QStringList kEnvironments{QStringLiteral("env-a"), QStringLiteral("env-b")};
const QStringList kPaths{QStringLiteral("a.txt"), QStringLiteral("/tmp/x.txt"), QStringLiteral("/tmp/y.txt")};
const QString kRoot = QStringLiteral("/w");

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

bool outside(const QString& path) { return path.startsWith(QLatin1Char('/')); }

// What the user sees and does; the rest is read off the fake MC.
struct Model {
  QString environment;
  QString openPath;
  // Edits so far, so each is new text.
  int edits = 0;
};

struct Sut {
  struct Write {
    QString environment;
    QString path;
    QString contents;
    FakeMc::Rpc rpc;
  };

  FakeMc mc;
  McClient client;
  std::unique_ptr<WorkspaceFiles> files;
  QObject barrier;
  // Each environment's disk, by path: every file starts as "<environment>:<path>".
  QHash<QString, QString> disk;
  QList<Write> held;
  // Reads the viewer makes on its own of an open file, answered with what the disk held when asked.
  bool holdReads = false;
  QList<std::function<void()>> heldReads;
  // The last edit typed into the open file; the viewer must keep showing it.
  QString typed;
  // Every write sent, as "<environment> <path>", and the environments that refused one by full path.
  QStringList sent;
  QSet<QString> refused;
  // Writes by full path sent after their environment refused one (checked, not thrown, out of the event loop).
  QStringList resent;
  // The user edited the file since opening it. (Read again, it may show the text
  // from before a write still under way: the MC answers each call on its own.)
  bool edited = false;

  Sut() {
    for (const QString& environment : kEnvironments) {
      for (const QString& path : kPaths) disk.insert(key(environment, path), environment + QLatin1Char(':') + path);
    }
    mc.onRpc(QStringLiteral("projects.listEntries"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonObject{{QStringLiteral("entries"), QJsonArray()}}); });
    mc.onRpc(QStringLiteral("projects.readFile"), [this](const FakeMc::Rpc& rpc) {
      const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
      const QJsonObject answer{{QStringLiteral("relativePath"), path}, {QStringLiteral("contents"), disk.value(key(rpc.environment, path))}};
      if (holdReads) {
        heldReads.append([this, rpc, answer] { mc.reply(rpc, answer); });
      } else {
        mc.reply(rpc, answer);
      }
    });
    mc.onRpc(QStringLiteral("projects.writeFile"), [this](const FakeMc::Rpc& rpc) {
      const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
      // Sent by full path to an environment that already refused one: the promise is broken.
      if (outside(path) && refused.contains(rpc.environment)) resent.append(rpc.environment + QLatin1Char(' ') + path);
      sent.append(rpc.environment + QLatin1Char(' ') + path);
      held.append({rpc.environment, path, rpc.payload.value(QLatin1String("contents")).toString(), rpc});
    });
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    halc2::prop::until([this] { return client.isReady(); });
    files = std::make_unique<WorkspaceFiles>(&client);
    files->setSaveDelay(0);
  }
  ~Sut() { files.reset(); }

  // The user's own open is answered at once: only reads that follow the agent wait.
  void opening(const std::function<void()>& open) {
    holdReads = false;
    typed.clear();
    open();
    RC_ASSERT(sync());
    holdReads = true;
  }

  static QString key(const QString& environment, const QString& path) { return environment + QLatin1Char(' ') + path; }

  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
    return halc2::prop::until([&] { return *answered; });
  }

  // The MC answers the `index`-th write it holds: env-b refuses one by full path.
  void answer(qsizetype index) {
    const Write write = held.takeAt(index);
    if (outside(write.path) && write.environment == QLatin1String("env-b")) {
      refused.insert(write.environment);
      mc.refuse(write.rpc, QStringLiteral("terminal:operate is required"),
                QJsonObject{{QStringLiteral("_tag"), QStringLiteral("EnvironmentScopeRequiredError")},
                            {QStringLiteral("requiredScope"), QStringLiteral("terminal:operate")}});
      return;
    }
    disk.insert(key(write.environment, write.path), write.contents);
    mc.reply(write.rpc, QJsonObject{{QStringLiteral("relativePath"), write.path}});
  }
};

void check(const Model& expected, Sut& sut) {
  RC_ASSERT(sut.sync());
  WorkspaceFiles& files = *sut.files;
  RC_ASSERT(files.environment() == expected.environment);
  RC_ASSERT(files.openPath() == expected.openPath);
  RC_ASSERT(sut.resent == QStringList());
  // A write carries only its own file's text: what it held, edited.
  for (const Sut::Write& write : std::as_const(sut.held)) RC_ASSERT(write.contents.startsWith(write.environment + QLatin1Char(':') + write.path));
  for (auto it = sut.disk.cbegin(); it != sut.disk.cend(); ++it) RC_ASSERT(it.value().startsWith(it.key().section(QLatin1Char(' '), 0, 0) + QLatin1Char(':') + it.key().section(QLatin1Char(' '), 1)));
  // env-b's files outside the workspace are never written.
  for (const QString& path : kPaths) {
    if (outside(path)) RC_ASSERT(sut.disk.value(Sut::key(QStringLiteral("env-b"), path)) == QStringLiteral("env-b:") + path);
  }
  if (expected.openPath.isEmpty()) return;
  RC_ASSERT(files.text().contains(sut.typed));
  RC_ASSERT(files.fileStatus() == QStringLiteral("ready"));
  const bool readOnly = outside(expected.openPath) && sut.refused.contains(expected.environment);
  RC_ASSERT(files.editable() == !readOnly);
  RC_ASSERT(files.readOnlyReason().isEmpty() == !readOnly);
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(expected, sut);
  }
};

struct SetTarget : Step<SetTarget> {
  QString environment = *oneOf(kEnvironments);
  explicit SetTarget(const Model&) {}
  void apply(Model& model) const override {
    if (environment == model.environment) return;
    model.environment = environment;
    model.openPath.clear();
  }
  void act(const Model& before, Sut& sut) const {
    if (environment != before.environment) sut.edited = false;
    sut.opening([&] { sut.files->setTarget(environment, kRoot); });
  }
  void show(std::ostream& os) const override { os << "workspace of " << environment.toStdString(); }
};

struct Open : Step<Open> {
  QString path = *oneOf(kPaths);
  explicit Open(const Model& model) { RC_PRE(!model.environment.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.environment.isEmpty()); }
  void apply(Model& model) const override { model.openPath = path; }
  void act(const Model& before, Sut& sut) const {
    if (path != before.openPath) sut.edited = false;
    sut.opening([&] { sut.files->openFile(path); });
  }
  void show(std::ostream& os) const override { os << "open " << path.toStdString(); }
};

// The user types at the end of the open file, if they can.
struct Edit : Step<Edit> {
  explicit Edit(const Model& model) { RC_PRE(!model.openPath.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.openPath.isEmpty()); }
  void apply(Model& model) const override { ++model.edits; }
  void act(const Model& before, Sut& sut) const {
    const bool editable = sut.files->editable();
    const QString text = sut.files->text();
    sut.files->setEditing(true);
    sut.files->edit(text + QStringLiteral(" +%1").arg(before.edits));
    // Read-only takes no edit.
    if (!editable) RC_ASSERT(sut.files->text() == text && !sut.files->editing());
    sut.edited = sut.edited || editable;
    if (editable) sut.typed = QStringLiteral(" +%1").arg(before.edits);
  }
  void show(std::ostream& os) const override { os << "edit"; }
};

// The agent rewrites the open project file: it adds to the end of what is on disk.
struct AgentWrites : Step<AgentWrites> {
  explicit AgentWrites(const Model& model) { RC_PRE(model.openPath == kPaths.first()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.openPath == kPaths.first()); }
  void apply(Model&) const override {}
  void act(const Model& before, Sut& sut) const {
    sut.disk[Sut::key(before.environment, before.openPath)] += QStringLiteral(" agent");
    sut.files->followOpenFile();
  }
  void show(std::ostream& os) const override { os << "the agent rewrites the file"; }
};

// The MC answers the oldest read it holds, if any.
struct AnswerRead : Step<AnswerRead> {
  explicit AnswerRead(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    if (!sut.heldReads.isEmpty()) sut.heldReads.takeFirst()();
  }
  void show(std::ostream& os) const override { os << "answer a read"; }
};

// The MC answers one write it holds, if any.
struct Answer : Step<Answer> {
  int pick = *rc::gen::inRange(0, 4);
  explicit Answer(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    if (!sut.held.isEmpty()) sut.answer(pick % sut.held.size());
  }
  void show(std::ostream& os) const override { os << "answer write #" << pick; }
};

// Every write is answered, the next ones too: the open file's edit is saved,
// unless it was refused.
struct Settle : Step<Settle> {
  explicit Settle(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model& before, Sut& sut) const {
    sut.files->setEditing(false);
    RC_ASSERT(sut.sync());
    for (int round = 0; round < 10 && !(sut.held.isEmpty() && sut.heldReads.isEmpty()); ++round) {
      while (!sut.held.isEmpty()) sut.answer(0);
      while (!sut.heldReads.isEmpty()) sut.heldReads.takeFirst()();
      RC_ASSERT(sut.sync());
    }
    RC_ASSERT(sut.held.isEmpty() && sut.heldReads.isEmpty());
    if (before.openPath.isEmpty() || sut.files->fileStatus() != QLatin1String("ready")) return;
    const bool refused = outside(before.openPath) && sut.refused.contains(before.environment);
    if (refused) {
      RC_ASSERT(sut.disk.value(Sut::key(before.environment, before.openPath)) == before.environment + QLatin1Char(':') + before.openPath);
    } else {
      RC_ASSERT(!sut.files->unsaved());
      if (sut.edited) RC_ASSERT(sut.disk.value(Sut::key(before.environment, before.openPath)) == sut.files->text());
    }
  }
  void show(std::ostream& os) const override { os << "answer every write"; }
};

struct Close : Step<Close> {
  explicit Close(const Model&) {}
  void apply(Model& model) const override { model.openPath.clear(); }
  void act(const Model&, Sut& sut) const {
    sut.edited = false;
    sut.typed.clear();
    sut.files->closeFile();
  }
  void show(std::ostream& os) const override { os << "close the file"; }
};

}  // namespace

class WorkspaceFilesSaveProp : public QObject {
  Q_OBJECT

private slots:
  void saves() {
    QVERIFY(rc::check("edits are written to their own file, never by full path where that was refused", [] {
      Sut sut;
      RC_ASSERT(sut.client.isReady());
      rc::state::check(Model(), sut, rc::state::gen::execOneOfWithArgs<SetTarget, Open, Open, Edit, Edit, Answer, Answer, AgentWrites, AnswerRead, Settle, Close>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceFilesSaveProp)
#include "tst_WorkspaceFilesSaveProp.moc"
