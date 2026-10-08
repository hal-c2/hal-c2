// ThreadDiff: the Diff tab of two threads against a fake MC that holds every
// diff it is asked for and answers them in any order. Meanwhile each
// thread's turns finish and leave checkpoints that become ready in any order,
// the thread is rewound and new turns take the rewound turns' numbers, and
// all of it streams into each thread's timeline. The user switches thread
// (its timeline sometimes not there yet), shows and hides the tab, picks a
// turn, all changes, the working tree or the branch, changes the base and
// whitespace options, focuses one file and reloads.
//
// The model is what the user should see. The picker's selection is always
// one of its choices. Each property's signal fires once when it changes and
// never otherwise. The diff on screen is the newest answer asked for. And
// once nothing is on its way, a shown tab's diff is what the MC would answer
// now for what is selected: never a turn's diff from before a rewind.

#include "Prop.h"
#include "WorkspaceModels.h"

#include <QJsonArray>
#include <QSignalSpy>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "ThreadDiff.h"
#include "TimelineModel.h"

namespace {

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

const QString kEnvironment = QStringLiteral("env-a");
const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2")};
const QStringList kCheckouts{QString(), QStringLiteral("/c1"), QStringLiteral("/c2")};
const QStringList kBases{QString(), QStringLiteral("main"), QStringLiteral(" dev ")};
// Every non-empty diff changes `two.txt`; no diff changes `gone.txt`.
const QStringList kFocus{QString(), QStringLiteral("two.txt"), QStringLiteral("gone.txt")};

// A finished turn's checkpoint as the MC streams it.
struct Checkpoint {
  QString id;
  int ordinal = 0;
  // ready, pending (not written yet) or stale (rewound).
  QString status;
  bool operator==(const Checkpoint&) const = default;
};

void showValue(const Checkpoint& checkpoint, std::ostream& os) {
  os << checkpoint.id.toStdString() << " turn " << checkpoint.ordinal << " " << checkpoint.status.toStdString();
}

using Checkpoints = QList<Checkpoint>;

// Turn number -> the ready checkpoint's id.
QMap<int, QString> readyTurns(const Checkpoints& checkpoints) {
  QMap<int, QString> turns;
  for (const Checkpoint& checkpoint : checkpoints) {
    if (checkpoint.status == QLatin1String("ready")) turns.insert(checkpoint.ordinal, checkpoint.id);
  }
  return turns;
}

QString patchOf(const QStringList& files) {
  QString patch;
  for (const QString& file : files) {
    patch += QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1 +1 @@\n-old\n+new\n").arg(file);
  }
  return patch;
}

// What the MC is asked. `selection` only says which source of a review answer
// the client shows; the MC never sees it.
struct Request {
  QString method;
  QString thread;
  int from = -1;
  int to = -1;
  bool whitespace = false;
  QString cwd;
  QString base;
  int selection = 0;
  // Which of the client's requests it was: only the newest is shown.
  int number = 0;

  bool sameAsked(const Request& other) const {
    return method == other.method && thread == other.thread && from == other.from && to == other.to && whitespace == other.whitespace &&
           cwd == other.cwd && base == other.base;
  }
};

void showValue(const Request& request, std::ostream& os) {
  os << request.method.toStdString();
  if (request.cwd.isEmpty()) {
    os << " of " << request.thread.toStdString() << " " << request.from << ".." << request.to;
  } else {
    os << " of '" << request.cwd.toStdString() << "' base '" << request.base.toStdString() << "'";
  }
  os << (request.whitespace ? " ignoring whitespace" : "");
}

// What the MC answers to `request`, from the checkpoints it has now: the
// diff's files, or why there is none.
struct Answer {
  std::optional<QString> error;
  QStringList files;
  QString base;
  QString head;
  bool truncated = false;
};

Answer answerOf(const Request& request, const QMap<QString, Checkpoints>& mc) {
  const QString ws = request.whitespace ? QStringLiteral("-ws") : QString();
  if (request.method == QLatin1String("review.getDiffPreview")) {
    const bool branch = request.selection == ThreadDiff::Branch;
    Answer answer;
    answer.base = request.base.isEmpty() ? QStringLiteral("main") : request.base;
    answer.head = QStringLiteral("feature");
    answer.truncated = request.cwd == QLatin1String("/c2");
    // Nothing uncommitted in /c2, and nothing against an explicit main.
    const bool empty = branch ? request.base == QLatin1String("main") : request.cwd == QLatin1String("/c2");
    if (!empty) {
      answer.files = {QStringLiteral("%1%2-%3%4.txt").arg(branch ? QStringLiteral("br") : QStringLiteral("wt"), request.cwd.mid(1),
                                                          answer.base, ws),
                      QStringLiteral("two.txt")};
    }
    return answer;
  }
  const QMap<int, QString> turns = readyTurns(mc.value(request.thread));
  if (!turns.contains(request.to)) return {QStringLiteral("Turn %1 has no checkpoint.").arg(request.to)};
  const QString to = turns.value(request.to);
  // A diff of a checkpoint whose number divides by 3 changed nothing.
  if (to.mid(3).toInt() % 3 == 0) return {};
  QString tag;
  if (request.method == QLatin1String("orchestration.getFullThreadDiff")) {
    tag = QStringLiteral("all-") + to;
  } else {
    tag = turns.value(request.from, request.from == 0 ? QStringLiteral("base") : QStringLiteral("none")) + QLatin1Char('_') + to;
  }
  return {std::nullopt, {request.thread + QLatin1Char('-') + tag + ws + QStringLiteral(".txt"), QStringLiteral("two.txt")}};
}

struct Model {
  // The MC's checkpoints of each thread, streamed into its timeline as they change.
  QMap<QString, Checkpoints> mc;
  int serial = 0;

  QString thread;
  bool timeline = false;
  bool active = false;
  int selection = -1;
  QString cwd;
  QString base;
  bool whitespace = true;

  QString status = QStringLiteral("idle");
  QString message;
  // The selection's diff, and the one file of it shown.
  QStringList files;
  QString focus;
  int fileTotal = 0;
  QString comparedBase;
  QString comparedHead;
  bool truncated = false;

  // What was last asked for (or found to be empty), so a repeat asks nothing.
  std::optional<QString> loaded;
  int request = 0;
  QList<Request> pending;

  QMap<int, QString> turns() const { return timeline ? readyTurns(mc.value(thread)) : QMap<int, QString>(); }
  int latestTurn() const { return turns().isEmpty() ? 0 : turns().lastKey(); }
  int effective() const { return selection == -1 && turns().isEmpty() && !cwd.isEmpty() ? int(ThreadDiff::WorkingTree) : selection; }
  bool reviewing() const { return effective() <= ThreadDiff::WorkingTree; }
  int shownTurn() const {
    if (selection == 0 || reviewing()) return 0;
    return selection > 0 ? selection : latestTurn();
  }
  QList<int> choices() const {
    QList<int> values;
    if (!turns().isEmpty()) {
      values = {-1, 0};
      const QList<int> numbers = turns().keys();
      for (auto it = numbers.crbegin(); it != numbers.crend(); ++it) values.append(*it);
    }
    if (!cwd.isEmpty()) values << ThreadDiff::WorkingTree << ThreadDiff::Branch;
    return values;
  }

  // What the selection asks the MC.
  Request wanted() const {
    Request request{{}, thread, -1, -1, whitespace};
    if (reviewing()) {
      request.method = QStringLiteral("review.getDiffPreview");
      request.thread.clear();
      request.cwd = cwd;
      request.selection = effective();
      if (request.selection == ThreadDiff::Branch) request.base = base;
    } else if (selection == 0) {
      request.method = QStringLiteral("orchestration.getFullThreadDiff");
      request.to = latestTurn();
    } else {
      request.method = QStringLiteral("orchestration.getTurnDiff");
      request.from = shownTurn() - 1;
      request.to = shownTurn();
    }
    return request;
  }
  // The request with what it depends on: the checkpoints it is between.
  QString keyOf(const Request& request) const {
    const QMap<int, QString> ready = turns();
    return QString::fromStdString(rc::toString(request)) + QStringLiteral(" %1 %2 %3").arg(request.selection).arg(ready.value(request.from), ready.value(request.to));
  }

  void load() {
    if (!active || thread.isEmpty()) return;
    if (!timeline) {
      // Whatever is shown is asked for again once the timeline comes.
      ++request;
      loaded.reset();
      setStatus(QStringLiteral("loading"), QStringLiteral("Loading checkpoint diff..."));
      return;
    }
    if (!reviewing() && turns().isEmpty()) {
      ++request;
      loaded.reset();
      clearDiff();
      setStatus(QStringLiteral("empty"), QStringLiteral("No completed turns yet."));
      return;
    }
    Request next = wanted();
    const QString key = keyOf(next);
    if (loaded == key) return;
    loaded = key;
    next.number = ++request;
    pending.append(next);
    setStatus(QStringLiteral("loading"), reviewing() ? QStringLiteral("Loading changes...") : QStringLiteral("Loading checkpoint diff..."));
  }

  void setStatus(const QString& next, const QString& why = {}) {
    status = next;
    message = why;
  }
  void clearDiff() {
    files.clear();
    fileTotal = 0;
  }
  void present(const QStringList& diff) {
    files = diff;
    fileTotal = int(diff.size());
    if (!focus.isEmpty() && !diff.contains(focus)) focus.clear();
  }
  QStringList shown() const { return focus.isEmpty() ? files : QStringList{focus}; }

  void answer(const Request& request, const Answer& answer) {
    if (request.number != this->request) return;
    if (answer.error) {
      loaded.reset();
      clearDiff();
      setStatus(QStringLiteral("error"), *answer.error);
      return;
    }
    if (request.method == QLatin1String("review.getDiffPreview")) {
      comparedBase = answer.base;
      comparedHead = answer.head;
      truncated = answer.truncated;
    }
    present(answer.files);
    if (!answer.files.isEmpty()) {
      setStatus(QStringLiteral("ready"));
    } else if (request.method != QLatin1String("review.getDiffPreview")) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No net changes in this selection."));
    } else if (request.selection == ThreadDiff::Branch) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No changes against %1.").arg(comparedBase));
    } else {
      setStatus(QStringLiteral("empty"), QStringLiteral("No uncommitted changes."));
    }
  }

  // The thread's timeline read its checkpoints again.
  void readCheckpoints() {
    if (selection > 0 && !turns().contains(selection)) selection = -1;
    // All changes of a thread with no turns is not a choice.
    if (selection == 0 && turns().isEmpty()) selection = -1;
    load();
  }
};

// The picker's facts, and what each property's signal covers.
struct Facts {
  QList<int> choices;
  int latestTurn;
  int selection;
  int shownTurn;
  bool reviewing;
  QString status;
  QString message;
  QString focus;
  int fileTotal;
  QString base;
  QString comparedBase;
  QString comparedHead;
  bool truncated;
};

Facts factsOf(const Model& model) {
  return {model.choices(), model.latestTurn(), model.selection, model.shownTurn(), model.reviewing(), model.status, model.message,
          model.focus,     model.fileTotal,    model.base,      model.comparedBase, model.comparedHead, model.truncated};
}

struct Sut {
  struct Held {
    Request request;
    FakeMc::Rpc rpc;
  };

  FakeMc mc;
  McClient client;
  std::map<QString, std::unique_ptr<TimelineModel>> timelines;
  std::unique_ptr<ThreadDiff> diff;
  std::unique_ptr<halc2::prop::ModelMirror> mirror;
  std::unique_ptr<QSignalSpy> turnsChanged;
  std::unique_ptr<QSignalSpy> selectionChanged;
  std::unique_ptr<QSignalSpy> statusChanged;
  std::unique_ptr<QSignalSpy> focusChanged;
  std::unique_ptr<QSignalSpy> reviewChanged;
  QObject barrier;
  QList<Held> held;
  QMap<QString, Checkpoints> checkpoints;

  Sut() {
    const auto hold = [this](const FakeMc::Rpc& rpc) {
      const QJsonObject& p = rpc.payload;
      Request request{rpc.method,
                      p.value(QLatin1String("threadId")).toString(),
                      p.value(QLatin1String("fromTurnCount")).toInt(-1),
                      p.value(QLatin1String("toTurnCount")).toInt(-1),
                      p.value(QLatin1String("ignoreWhitespace")).toBool(),
                      p.value(QLatin1String("cwd")).toString(),
                      p.value(QLatin1String("baseRef")).toString()};
      held.append({request, rpc});
    };
    for (const char* method : {"orchestration.getTurnDiff", "orchestration.getFullThreadDiff", "review.getDiffPreview"}) {
      mc.onRpc(QString::fromLatin1(method), hold);
    }
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    halc2::prop::until([this] { return client.isReady(); });
    for (const QString& thread : kThreads) timelines[thread] = std::make_unique<TimelineModel>(kEnvironment + QLatin1Char(':') + thread);
    diff = std::make_unique<ThreadDiff>(&client, [](const QString&, const QString&, const QString&) {});
    mirror = std::make_unique<halc2::prop::ModelMirror>(diff->model());
    turnsChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::turnsChanged);
    selectionChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::selectionChanged);
    statusChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::statusChanged);
    focusChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::focusChanged);
    reviewChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::reviewChanged);
  }
  ~Sut() {
    turnsChanged.reset();
    selectionChanged.reset();
    statusChanged.reset();
    focusChanged.reset();
    reviewChanged.reset();
    mirror.reset();
    diff.reset();
  }

  // Once this comes back, everything the client sent before it has reached
  // the MC and every answer sent before it has been read.
  bool sync() {
    auto answered = std::make_shared<bool>(false);
    client.call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) {
      *answered = true;
    });
    return halc2::prop::until([&] { return *answered; });
  }

  // The thread's checkpoints as one snapshot of its stream.
  void stream(const QString& thread, const Checkpoints& next) {
    checkpoints[thread] = next;
    QJsonArray rows;
    for (const Checkpoint& checkpoint : next) {
      rows.append(QJsonArray{QStringLiteral("checkpoint"), checkpoint.id,
                             QJsonObject{{QStringLiteral("id"), checkpoint.id},
                                         {QStringLiteral("appRunOrdinal"), checkpoint.ordinal},
                                         {QStringLiteral("status"), checkpoint.status},
                                         {QStringLiteral("files"), QJsonArray()}}});
    }
    timelines.at(thread)->receive({{QStringLiteral("t"), QStringLiteral("snapshot")},
                                   {QStringLiteral("part"), 0},
                                   {QStringLiteral("done"), true},
                                   {QStringLiteral("rows"), rows},
                                   {QStringLiteral("offset"), int(next.size())},
                                   {QStringLiteral("handle"), QStringLiteral("log")}});
  }

  void answer(const Request& request, int rank, bool ok) {
    for (qsizetype i = 0; i < held.size(); ++i) {
      if (!held.at(i).request.sameAsked(request) || rank-- > 0) continue;
      const Held answered = held.takeAt(i);
      // The client's selection picks the source; the MC sends both.
      Request asked = answered.request;
      asked.selection = ThreadDiff::WorkingTree;
      const Answer tree = answerOf(asked, checkpoints);
      asked.selection = ThreadDiff::Branch;
      const Answer branch = answerOf(asked, checkpoints);
      const Answer turn = answerOf(answered.request, checkpoints);
      if (!ok) {
        mc.refuse(answered.rpc, QStringLiteral("no"));
      } else if (request.method == QLatin1String("review.getDiffPreview")) {
        const auto source = [](const QString& kind, const Answer& answer) {
          return QJsonObject{{QStringLiteral("kind"), kind},           {QStringLiteral("diff"), patchOf(answer.files)},
                             {QStringLiteral("baseRef"), answer.base}, {QStringLiteral("headRef"), answer.head},
                             {QStringLiteral("truncated"), answer.truncated}};
        };
        mc.reply(answered.rpc, QJsonObject{{QStringLiteral("sources"), QJsonArray{source(QStringLiteral("working-tree"), tree),
                                                                                  source(QStringLiteral("branch-range"), branch)}}});
      } else if (turn.error) {
        mc.refuse(answered.rpc, *turn.error);
      } else {
        mc.reply(answered.rpc, QJsonObject{{QStringLiteral("diff"), patchOf(turn.files)}});
      }
      return;
    }
    RC_FAIL("the MC holds no " + rc::toString(request));
  }

  QStringList paths() const { return diff->model()->paths(); }
};

QStringList asked(const QList<Request>& requests) {
  QStringList out;
  for (const Request& request : requests) out.append(QString::fromStdString(rc::toString(request)));
  std::sort(out.begin(), out.end());
  return out;
}

void check(const Facts& before, const Model& expected, Sut& sut) {
  RC_ASSERT(sut.sync());
  QList<Request> held;
  for (const Sut::Held& request : sut.held) held.append(request.request);
  RC_ASSERT(asked(held) == asked(expected.pending));

  ThreadDiff& diff = *sut.diff;
  QList<int> choices;
  for (const QVariant& choice : diff.choices()) choices.append(choice.toMap().value(QStringLiteral("value")).toInt());
  RC_ASSERT(choices == expected.choices());
  RC_ASSERT(diff.latestTurn() == expected.latestTurn());
  RC_ASSERT(diff.selection() == expected.selection);
  // The picker shows the selection: it is one of the choices, or the first.
  RC_ASSERT(diff.selection() == -1 || choices.contains(diff.selection()));
  RC_ASSERT(diff.shownTurn() == expected.shownTurn());
  RC_ASSERT(diff.reviewing() == expected.reviewing());
  RC_ASSERT(diff.status() == expected.status);
  RC_ASSERT(diff.message() == expected.message);
  RC_ASSERT(diff.focusPath() == expected.focus);
  RC_ASSERT(diff.comparedBase() == expected.comparedBase);
  RC_ASSERT(diff.comparedHead() == expected.comparedHead);
  RC_ASSERT(diff.truncated() == expected.truncated);
  RC_ASSERT(diff.baseRef() == expected.base);
  RC_ASSERT(diff.ignoreWhitespace() == expected.whitespace);
  if (expected.status == QLatin1String("ready")) {
    RC_ASSERT(diff.fileTotal() == expected.fileTotal);
    RC_ASSERT(sut.paths() == expected.shown());
  }
  if (expected.status == QLatin1String("empty") || expected.status == QLatin1String("error")) RC_ASSERT(sut.paths().isEmpty());

  // What a shown tab settles on is what the MC says now.
  const bool settled = expected.status == QLatin1String("ready") || expected.status == QLatin1String("empty");
  if (expected.active && expected.timeline && settled && (expected.reviewing() || !expected.turns().isEmpty())) {
    const Answer now = answerOf(expected.wanted(), expected.mc);
    RC_ASSERT(!now.error);
    RC_ASSERT(diff.fileTotal() == int(now.files.size()));
    // A focus kept while there was nothing to show is shown once its file is.
    RC_ASSERT(sut.paths() == (now.files.contains(expected.focus) ? QStringList{expected.focus} : now.files));
  }

  const Facts after = factsOf(expected);
  RC_ASSERT(sut.turnsChanged->count() == (before.choices != after.choices || before.latestTurn != after.latestTurn ? 1 : 0));
  RC_ASSERT(sut.selectionChanged->count() ==
            (before.selection != after.selection || before.shownTurn != after.shownTurn || before.reviewing != after.reviewing ? 1 : 0));
  RC_ASSERT(sut.statusChanged->count() == (before.status != after.status || before.message != after.message ? 1 : 0));
  RC_ASSERT(sut.focusChanged->count() == (before.focus != after.focus || before.fileTotal != after.fileTotal ? 1 : 0));
  RC_ASSERT(sut.reviewChanged->count() == (before.base != after.base || before.comparedBase != after.comparedBase ||
                                                   before.comparedHead != after.comparedHead || before.truncated != after.truncated
                                               ? 1
                                               : 0));
  for (QSignalSpy* spy : {sut.turnsChanged.get(), sut.selectionChanged.get(), sut.statusChanged.get(), sut.focusChanged.get(),
                          sut.reviewChanged.get()}) {
    spy->clear();
  }
  const QStringList problems = sut.mirror->problems();
  RC_ASSERT(problems == QStringList());
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(factsOf(before), expected, sut);
  }
};

// --- The MC's checkpoints ---------------------------------------------------------

// A turn finished: its checkpoint is ready, or still being written.
struct NewTurn : Step<NewTurn> {
  QString thread = *oneOf(kThreads);
  bool ready = *rc::gen::weightedElement<bool>({{3, true}, {1, false}});
  explicit NewTurn(const Model& model) { RC_PRE(model.mc.value(thread).size() < 8); }
  Checkpoints next(const Model& model) const {
    Checkpoints checkpoints = model.mc.value(thread);
    int ordinal = 1;
    for (const Checkpoint& checkpoint : checkpoints) {
      if (checkpoint.status != QLatin1String("stale")) ordinal = std::max(ordinal, checkpoint.ordinal + 1);
    }
    checkpoints.append({QStringLiteral("cp-%1").arg(model.serial + 1), ordinal, ready ? QStringLiteral("ready") : QStringLiteral("pending")});
    return checkpoints;
  }
  void apply(Model& model) const override {
    model.mc[thread] = next(model);
    ++model.serial;
    if (thread == model.thread) model.readCheckpoints();
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << "a turn of " << thread.toStdString() << (ready ? " finishes" : " is writing its checkpoint"); }
};

// A checkpoint being written is ready, out of order with the others.
struct Ready : Step<Ready> {
  QString thread = *oneOf(kThreads);
  QString id;
  explicit Ready(const Model& model) {
    QStringList ids;
    for (const Checkpoint& checkpoint : model.mc.value(thread)) {
      if (checkpoint.status == QLatin1String("pending")) ids.append(checkpoint.id);
    }
    RC_PRE(!ids.isEmpty());
    id = *oneOf(ids);
  }
  void checkPreconditions(const Model& model) const override {
    const Checkpoints checkpoints = model.mc.value(thread);
    RC_PRE(std::any_of(checkpoints.begin(), checkpoints.end(),
                       [&](const Checkpoint& checkpoint) { return checkpoint.id == id && checkpoint.status == QLatin1String("pending"); }));
  }
  Checkpoints next(const Model& model) const {
    Checkpoints checkpoints = model.mc.value(thread);
    for (Checkpoint& checkpoint : checkpoints) {
      if (checkpoint.id == id) checkpoint.status = QStringLiteral("ready");
    }
    return checkpoints;
  }
  void apply(Model& model) const override {
    model.mc[thread] = next(model);
    if (thread == model.thread) model.readCheckpoints();
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << id.toStdString() << " of " << thread.toStdString() << " is ready"; }
};

// The thread is rewound to after `turn`: later checkpoints go stale, and the
// next turn takes the first rewound turn's number.
struct Rewind : Step<Rewind> {
  QString thread = *oneOf(kThreads);
  int turn = *rc::gen::inRange(0, 4);
  explicit Rewind(const Model&) {}
  Checkpoints next(const Model& model) const {
    Checkpoints checkpoints = model.mc.value(thread);
    for (Checkpoint& checkpoint : checkpoints) {
      if (checkpoint.ordinal > turn) checkpoint.status = QStringLiteral("stale");
    }
    return checkpoints;
  }
  void apply(Model& model) const override {
    model.mc[thread] = next(model);
    if (thread == model.thread) model.readCheckpoints();
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << thread.toStdString() << " is rewound to turn " << turn; }
};

// --- The user ----------------------------------------------------------------------

struct SetThread : Step<SetThread> {
  QString thread = *oneOf(kThreads);
  bool timeline = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  explicit SetThread(const Model&) {}
  void apply(Model& model) const override {
    if (thread == model.thread && timeline == model.timeline) return;
    if (thread != model.thread) {
      model.thread = thread;
      ++model.request;
      model.loaded.reset();
      model.clearDiff();
      model.focus.clear();
      model.comparedBase.clear();
      model.comparedHead.clear();
      model.truncated = false;
      model.selection = -1;
      model.setStatus(QStringLiteral("idle"));
    }
    model.timeline = timeline;
    model.readCheckpoints();
  }
  void act(const Model&, Sut& sut) const { sut.diff->setThread(kEnvironment, thread, timeline ? sut.timelines.at(thread).get() : nullptr); }
  void show(std::ostream& os) const override { os << "open " << thread.toStdString() << (timeline ? "" : " before its timeline"); }
};

struct SetActive : Step<SetActive> {
  bool active = *rc::gen::arbitrary<bool>();
  explicit SetActive(const Model&) {}
  void apply(Model& model) const override {
    model.active = active;
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->setActive(active); }
  void show(std::ostream& os) const override { os << (active ? "show the tab" : "hide the tab"); }
};

struct SetCheckout : Step<SetCheckout> {
  QString cwd = *oneOf(kCheckouts);
  explicit SetCheckout(const Model&) {}
  void apply(Model& model) const override {
    if (cwd == model.cwd) return;
    model.cwd = cwd;
    // The checkout's own choices go with it.
    if (cwd.isEmpty() && model.selection <= ThreadDiff::WorkingTree) model.selection = -1;
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->setCheckout(cwd); }
  void show(std::ostream& os) const override { os << "checkout '" << cwd.toStdString() << "'"; }
};

struct Select : Step<Select> {
  int selection = *rc::gen::inRange(-4, 5);
  explicit Select(const Model&) {}
  void apply(Model& model) const override {
    int next = selection;
    if (next > 0 && !model.turns().contains(next)) return;
    if (next < ThreadDiff::Branch || (next <= ThreadDiff::WorkingTree && model.cwd.isEmpty())) next = -1;
    // All changes needs a turn.
    if (next == 0 && model.turns().isEmpty()) next = -1;
    if (next == model.selection) return;
    model.selection = next;
    model.focus.clear();
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->select(selection); }
  void show(std::ostream& os) const override { os << "select " << selection; }
};

struct SetBase : Step<SetBase> {
  QString base = *oneOf(kBases);
  explicit SetBase(const Model&) {}
  void apply(Model& model) const override {
    const QString next = base.trimmed();
    if (next == model.base) return;
    model.base = next;
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->setBaseRef(base); }
  void show(std::ostream& os) const override { os << "base '" << base.toStdString() << "'"; }
};

struct SetWhitespace : Step<SetWhitespace> {
  bool ignore = *rc::gen::arbitrary<bool>();
  explicit SetWhitespace(const Model&) {}
  void apply(Model& model) const override {
    if (ignore == model.whitespace) return;
    model.whitespace = ignore;
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->setIgnoreWhitespace(ignore); }
  void show(std::ostream& os) const override { os << (ignore ? "hide whitespace changes" : "show whitespace changes"); }
};

struct Focus : Step<Focus> {
  QString path = *oneOf(kFocus);
  explicit Focus(const Model&) {}
  void apply(Model& model) const override {
    if (path == model.focus) return;
    model.focus = path;
    if (model.status == QLatin1String("ready")) model.present(model.files);
  }
  void act(const Model&, Sut& sut) const {
    if (path.isEmpty()) {
      sut.diff->showAllFiles();
    } else {
      sut.diff->focusFile(path);
    }
  }
  void show(std::ostream& os) const override {
    if (path.isEmpty()) {
      os << "show all files";
    } else {
      os << "focus " << path.toStdString();
    }
  }
};

struct Reload : Step<Reload> {
  explicit Reload(const Model&) {}
  void apply(Model& model) const override {
    model.loaded.reset();
    model.load();
  }
  void act(const Model&, Sut& sut) const { sut.diff->reload(); }
  void show(std::ostream& os) const override { os << "reload"; }
};

struct AnswerOne : Step<AnswerOne> {
  Request request;
  int rank = 0;
  bool ok = *rc::gen::weightedElement<bool>({{5, true}, {1, false}});
  explicit AnswerOne(const Model& model) {
    RC_PRE(!model.pending.isEmpty());
    const int index = *rc::gen::inRange<int>(0, int(model.pending.size()));
    request = model.pending.at(index);
    for (int i = 0; i < index; ++i) rank += model.pending.at(i).sameAsked(request) ? 1 : 0;
  }
  // The one pending request this answers.
  qsizetype indexIn(const Model& model) const {
    int skip = rank;
    for (qsizetype i = 0; i < model.pending.size(); ++i) {
      if (model.pending.at(i).sameAsked(request) && skip-- == 0) return i;
    }
    return -1;
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(indexIn(model) >= 0); }
  void apply(Model& model) const override {
    const Request answered = model.pending.takeAt(indexIn(model));
    model.answer(answered, ok ? answerOf(answered, model.mc) : Answer{QStringLiteral("no")});
  }
  void act(const Model&, Sut& sut) const { sut.answer(request, rank, ok); }
  void show(std::ostream& os) const override {
    os << (ok ? "answer " : "refuse ");
    rc::show(request, os);
    os << " #" << rank;
  }
};

}  // namespace

class WorkspaceThreadDiffProp : public QObject {
  Q_OBJECT

private slots:
  void diff() {
    QVERIFY(rc::check("the Diff tab shows what the MC says of the selection, which is always one of the choices", [] {
      Sut sut;
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<NewTurn, NewTurn, Ready, Rewind, SetThread, SetActive, SetActive, SetCheckout,
                                                         Select, Select, SetBase, SetWhitespace, Focus, Reload, AnswerOne, AnswerOne,
                                                         AnswerOne, AnswerOne>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceThreadDiffProp)
#include "tst_WorkspaceThreadDiffProp.moc"
