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
// is not shown after it, however late it is answered. A tick only ever flips the
// task the user clicked, in the text they clicked it in, or nothing: edits and
// the agent add tasks above it, so a tick landing late would land on another.

#include "Prop.h"

#include <QJsonArray>
#include <QJsonObject>

#include <functional>

#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"

namespace {

const QStringList kEnvironments{QStringLiteral("env-a"), QStringLiteral("env-b")};
const QString kTasks = QStringLiteral("t.md");
const QStringList kPaths{QStringLiteral("a.txt"), kTasks, QStringLiteral("/tmp/x.txt"), QStringLiteral("/tmp/y.txt")};
const QString kRoot = QStringLiteral("/w");

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

bool outside(const QString& path) { return path.startsWith(QLatin1Char('/')); }

// New text in a file: the tasks file takes it as the first task, moving the others along.
QString adding(const QString& text, const QString& label) {
  const qsizetype line = text.indexOf(QLatin1Char('\n'));
  if (line < 0) return text + label;
  return text.left(line + 1) + QStringLiteral("- [ ]") + label + QLatin1Char('\n') + text.mid(line + 1);
}

// Each task of a text, in order, as its label and whether it is ticked.
QList<std::pair<QString, bool>> tasksOf(const QString& text) {
  QList<std::pair<QString, bool>> tasks;
  for (const QString& line : text.split(QLatin1Char('\n'))) {
    if (line.startsWith(QLatin1String("- ["))) tasks.append({line.mid(5), line.at(3) == u'x'});
  }
  return tasks;
}

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
  QList<std::function<void(bool)>> heldReads;
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
  // Tasks the user clicked, as "<environment> <path> <label>"; no other may be ticked.
  QSet<QString> clicked;
  // A read failed, which leaves the file without its text until it is read again.
  bool readFailed = false;
  // The agent changed the file while it loaded, so a failed read is read again.
  bool changedWhileLoading = false;
  int agentWrites = 0;

  Sut() {
    for (const QString& environment : kEnvironments) {
      for (const QString& path : kPaths) disk.insert(key(environment, path), environment + QLatin1Char(':') + path);
      disk[key(environment, kTasks)] += QStringLiteral("\n- [ ] t0\n- [ ] t1\n- [ ] t2");
    }
    mc.onRpc(QStringLiteral("projects.listEntries"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonObject{{QStringLiteral("entries"), QJsonArray()}}); });
    mc.onRpc(QStringLiteral("projects.readFile"), [this](const FakeMc::Rpc& rpc) {
      const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
      const QJsonObject answer{{QStringLiteral("relativePath"), path}, {QStringLiteral("contents"), disk.value(key(rpc.environment, path))}};
      if (holdReads) {
        heldReads.append([this, rpc, answer](bool fail) { fail ? mc.refuse(rpc, QStringLiteral("Could not read the file.")) : mc.reply(rpc, answer); });
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
  void opening(const std::function<void()>& open, bool hold = false) {
    holdReads = hold;
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

  // Whether a text of this file has a task ticked that the user never clicked.
  bool tickedUnasked(const QString& environment, const QString& path, const QString& text) const {
    const QList<std::pair<QString, bool>> tasks = tasksOf(text);
    return std::any_of(tasks.cbegin(), tasks.cend(), [&](const auto& task) { return task.second && !clicked.contains(key(environment, path) + QLatin1Char(' ') + task.first); });
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
  for (const Sut::Write& write : std::as_const(sut.held)) {
    RC_ASSERT(write.contents.startsWith(write.environment + QLatin1Char(':') + write.path));
    RC_ASSERT(!sut.tickedUnasked(write.environment, write.path, write.contents));
  }
  for (const QString& environment : kEnvironments) RC_ASSERT(!sut.tickedUnasked(environment, kTasks, sut.disk.value(Sut::key(environment, kTasks))));
  for (auto it = sut.disk.cbegin(); it != sut.disk.cend(); ++it) RC_ASSERT(it.value().startsWith(it.key().section(QLatin1Char(' '), 0, 0) + QLatin1Char(':') + it.key().section(QLatin1Char(' '), 1)));
  // env-b's files outside the workspace are never written.
  for (const QString& path : kPaths) {
    if (outside(path)) RC_ASSERT(sut.disk.value(Sut::key(QStringLiteral("env-b"), path)) == QStringLiteral("env-b:") + path);
  }
  if (expected.openPath.isEmpty()) return;
  // A file opened while its writes land reads after them; the read may be held too.
  if (files.fileStatus() == QLatin1String("loading") && !(sut.held.isEmpty() && sut.heldReads.isEmpty())) return;
  // Until a read answers: the problem, or loading again.
  if (sut.readFailed && files.fileStatus() != QLatin1String("ready")) return;
  RC_ASSERT(files.text().contains(sut.typed));
  RC_ASSERT(!sut.tickedUnasked(expected.environment, expected.openPath, files.text()));
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
    sut.changedWhileLoading = false;
  }
  void show(std::ostream& os) const override { os << "workspace of " << environment.toStdString(); }
};

struct Open : Step<Open> {
  QString path = *oneOf(kPaths);
  // The MC holds this read, for AnswerRead to answer.
  bool slow = *rc::gen::arbitrary<bool>();
  explicit Open(const Model& model) { RC_PRE(!model.environment.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.environment.isEmpty()); }
  void apply(Model& model) const override { model.openPath = path; }
  void act(const Model& before, Sut& sut) const {
    if (path != before.openPath) sut.edited = false;
    sut.opening([&] { sut.files->openFile(path); }, slow);
    // Older replies are dropped: a failure cannot carry over.
    sut.readFailed = false;
    sut.changedWhileLoading = false;
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
    sut.files->edit(adding(text, QStringLiteral(" +%1").arg(before.edits)));
    // Read-only takes no edit.
    if (!editable) RC_ASSERT(sut.files->text() == text && !sut.files->editing());
    sut.edited = sut.edited || editable;
    if (editable) sut.typed = QStringLiteral(" +%1").arg(before.edits);
  }
  void show(std::ostream& os) const override { os << "edit"; }
};

// The user clicks a task of the markdown they see, whatever else is under way.
struct Tick : Step<Tick> {
  int pick = *rc::gen::inRange(0, 8);
  explicit Tick(const Model& model) { RC_PRE(model.openPath == kTasks); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.openPath == kTasks); }
  void apply(Model&) const override {}
  void act(const Model& before, Sut& sut) const {
    const QList<std::pair<QString, bool>> tasks = tasksOf(sut.files->text());
    if (tasks.isEmpty()) return;
    sut.clicked.insert(Sut::key(before.environment, before.openPath) + QLatin1Char(' ') + tasks.at(pick % tasks.size()).first);
    sut.files->toggleTask(pick % tasks.size());
  }
  void show(std::ostream& os) const override { os << "tick task #" << pick; }
};

// The user enters or leaves edit mode without typing.
struct SetEditing : Step<SetEditing> {
  bool editing = *rc::gen::arbitrary<bool>();
  explicit SetEditing(const Model& model) { RC_PRE(!model.openPath.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.openPath.isEmpty()); }
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const { sut.files->setEditing(editing); }
  void show(std::ostream& os) const override { os << (editing ? "enter" : "leave") << " edit mode"; }
};

// The agent rewrites the open project file: it adds to what is on disk.
struct AgentWrites : Step<AgentWrites> {
  explicit AgentWrites(const Model& model) { RC_PRE(!model.openPath.isEmpty() && !outside(model.openPath)); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.openPath.isEmpty() && !outside(model.openPath)); }
  void apply(Model&) const override {}
  void act(const Model& before, Sut& sut) const {
    QString& text = sut.disk[Sut::key(before.environment, before.openPath)];
    text = adding(text, QStringLiteral(" agent%1").arg(++sut.agentWrites));
    // An unreadable file is read again, and a load under way is read after it.
    sut.readFailed = false;
    sut.changedWhileLoading = sut.files->fileStatus() == QLatin1String("loading");
    sut.files->followOpenFile();
  }
  void show(std::ostream& os) const override { os << "the agent rewrites the file"; }
};

// The MC answers one read it holds, if any, or fails it.
struct AnswerRead : Step<AnswerRead> {
  int pick = *rc::gen::inRange(0, 4);
  bool fail = *rc::gen::inRange(0, 4) == 0;
  explicit AnswerRead(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    if (sut.heldReads.isEmpty()) return;
    const int at = pick % sut.heldReads.size();
    const bool latest = at == sut.heldReads.size() - 1;
    sut.readFailed = sut.readFailed || (fail && !(latest && sut.changedWhileLoading));
    if (latest) sut.changedWhileLoading = false;
    sut.heldReads.takeAt(at)(fail);
  }
  void show(std::ostream& os) const override { os << (fail ? "fail a read" : "answer a read"); }
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
    for (int round = 0; round < 100 && !(sut.held.isEmpty() && sut.heldReads.isEmpty()); ++round) {
      while (!sut.held.isEmpty()) sut.answer(0);
      while (!sut.heldReads.isEmpty()) sut.heldReads.takeFirst()(false);
      RC_ASSERT(sut.sync());
    }
    RC_ASSERT(sut.held.isEmpty() && sut.heldReads.isEmpty());
    if (before.openPath.isEmpty() || sut.files->fileStatus() != QLatin1String("ready")) return;
    const bool refused = outside(before.openPath) && sut.refused.contains(before.environment);
    if (refused) {
      RC_ASSERT(sut.disk.value(Sut::key(before.environment, before.openPath)) == before.environment + QLatin1Char(':') + before.openPath);
    } else {
      RC_ASSERT(!sut.files->unsaved());
      // Edited here or before a visit elsewhere, it shows what is on disk.
      RC_ASSERT(sut.disk.value(Sut::key(before.environment, before.openPath)) == sut.files->text());
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
      rc::state::check(Model(), sut, rc::state::gen::execOneOfWithArgs<SetTarget, Open, Open, Edit, Edit, Tick, Tick, Tick, SetEditing, Answer, Answer, AgentWrites, AnswerRead, AnswerRead, Settle, Close>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceFilesSaveProp)
#include "tst_WorkspaceFilesSaveProp.moc"
