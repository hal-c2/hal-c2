// ThreadDiff: the Diff tab of two threads against a fake MC that holds every
// diff it is asked for and answers them in any order. Meanwhile each
// thread's turns finish and leave checkpoints that become ready in any order
// (their file summaries sometimes later still), the thread is rewound and new
// turns take the rewound turns' numbers, and all of it streams into each
// thread's timeline. The user switches thread
// (its timeline sometimes not there yet), shows and hides the tab, picks a
// turn, all changes, the working tree or the branch, changes the base and
// whitespace options, focuses one file and reloads. Each thread keeps its
// own selection and base. A latest turn that changed no files opens on all
// changes when an earlier one changed some, until the user picks the latest
// turn. While the checkout is shown, a change the agent
// makes (here, a checkpoint's status) asks for it again without blanking it,
// and the same answer leaves it as it was. A review the MC cut short lists
// its files, and the user opens them (or retries one that failed) to load
// each one's changes. Files are marked viewed and unmarked: remembered per
// thread and diff source, a viewed file collapsed. A reload of a diff
// already shown that fails keeps it on screen with the reason as its
// message; any other failure is an error with nothing shown.
//
// The model is what the user should see. The picker's selection is always
// one of its choices. Each property's signal fires once when it changes and
// never otherwise. The diff on screen is the newest answer asked for. And
// once nothing is on its way, a shown tab's diff is what the MC would answer
// now for what is selected: never a turn's diff from before a rewind.

#include "Prop.h"
#include "WorkspaceModels.h"

#include <QJsonArray>
#include <QSet>
#include <QSignalSpy>

#include <memory>
#include <optional>
#include <tuple>

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
  // How many files its summary lists; it can come after the checkpoint is ready.
  int files = 0;
  bool operator==(const Checkpoint&) const = default;
};

void showValue(const Checkpoint& checkpoint, std::ostream& os) {
  os << checkpoint.id.toStdString() << " turn " << checkpoint.ordinal << " " << checkpoint.status.toStdString() << " " << checkpoint.files << " files";
}

using Checkpoints = QList<Checkpoint>;

// Turn number -> the ready checkpoint's id. As the MC counts them, turns are
// the ready checkpoints in order: one still being written has no number yet.
QMap<int, QString> readyTurns(const Checkpoints& checkpoints) {
  QMap<int, QString> byOrdinal;
  for (const Checkpoint& checkpoint : checkpoints) {
    if (checkpoint.status == QLatin1String("ready")) byOrdinal.insert(checkpoint.ordinal, checkpoint.id);
  }
  QMap<int, QString> turns;
  for (const QString& id : std::as_const(byOrdinal)) turns.insert(int(turns.size()) + 1, id);
  return turns;
}

// The checkpoint's file summary as the MC streams it.
QJsonArray filesOf(const Checkpoint& checkpoint) {
  QJsonArray files;
  for (int i = 0; i < checkpoint.files; ++i) {
    files.append(QJsonObject{{QStringLiteral("path"), QStringLiteral("f%1.txt").arg(i)}, {QStringLiteral("additions"), 1}, {QStringLiteral("deletions"), 1}});
  }
  return files;
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
  // One file's changes of a review cut short.
  QString file;
  // Which of the client's requests it was: only the newest is shown.
  int number = 0;
  // Which listing of a review cut short a file's request is for.
  int listing = 0;

  bool sameAsked(const Request& other) const {
    return method == other.method && thread == other.thread && from == other.from && to == other.to && whitespace == other.whitespace &&
           cwd == other.cwd && base == other.base && file == other.file;
  }
};

void showValue(const Request& request, std::ostream& os) {
  os << request.method.toStdString();
  if (request.cwd.isEmpty()) {
    os << " of " << request.thread.toStdString() << " " << request.from << ".." << request.to;
  } else {
    os << " of '" << request.cwd.toStdString() << "' base '" << request.base.toStdString() << "'";
  }
  if (!request.file.isEmpty()) os << " file " << request.file.toStdString();
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
  if (!request.file.isEmpty()) return {std::nullopt, {request.file}};
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
  // The user picked the latest turn, so it is shown even when it changed nothing.
  bool latestPicked = false;
  QString cwd;
  QString base;
  bool whitespace = true;

  // What each other thread had selected, its base, and whether the latest turn was picked.
  QMap<QString, std::tuple<int, QString, bool>> choices_;
  // A load following the checkout keeps a shown diff until it is answered.
  bool quiet = false;
  // The review answer shown (its kind and files), and the focus shown of it:
  // the same again changes nothing.
  QString sourceKey;
  QString presented;
  // A review cut short: its files, how far each one's changes are, and which
  // the user opened.
  bool lazy = false;
  QString lazyKind;
  int listing = 0;
  QMap<QString, QString> fileStates;
  QSet<QString> opened;

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
  // The key of what was last shown whole: its failed reload keeps it shown.
  QString shownKey;
  // Viewed files by thread and diff source, kept across selections.
  QMap<QString, QSet<QString>> viewed;
  int request = 0;
  QList<Request> pending;

  QMap<int, QString> turns() const { return timeline ? readyTurns(mc.value(thread)) : QMap<int, QString>(); }
  int latestTurn() const { return turns().isEmpty() ? 0 : turns().lastKey(); }
  // What the panel opens proactively on (latestCheckpoint).
  std::optional<Checkpoint> latestCheckpoint() const {
    const QString id = turns().value(latestTurn());
    for (const Checkpoint& checkpoint : mc.value(thread)) {
      if (!id.isEmpty() && checkpoint.id == id) return checkpoint;
    }
    return std::nullopt;
  }
  // How many files the summary of turn `turn`'s checkpoint lists.
  int filesOf(int turn) const {
    const QString id = turns().value(turn);
    for (const Checkpoint& checkpoint : mc.value(thread)) {
      if (checkpoint.id == id) return checkpoint.files;
    }
    return 0;
  }
  // The default shows all changes when the latest turn changed no files and an earlier one did.
  bool opensOnAllChanges() const {
    if (latestPicked || turns().size() < 2 || filesOf(latestTurn()) > 0) return false;
    for (int turn = 1; turn < latestTurn(); ++turn) {
      if (filesOf(turn) > 0) return true;
    }
    return false;
  }
  // What the picker shows.
  int picked() const { return selection == -1 && opensOnAllChanges() ? 0 : selection; }
  int effective() const { return selection == -1 && turns().isEmpty() && !cwd.isEmpty() ? int(ThreadDiff::WorkingTree) : picked(); }
  bool reviewing() const { return effective() <= ThreadDiff::WorkingTree; }
  int shownTurn() const {
    if (effective() == 0 || reviewing()) return 0;
    return effective() > 0 ? effective() : latestTurn();
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
    } else if (effective() == 0) {
      request.method = QStringLiteral("orchestration.getFullThreadDiff");
      request.to = latestTurn();
    } else {
      request.method = QStringLiteral("orchestration.getTurnDiff");
      request.from = shownTurn() - 1;
      request.to = shownTurn();
    }
    return request;
  }
  QString viewedKey() const {
    return QStringLiteral("%1 %2 %3").arg(thread).arg(effective()).arg(effective() == ThreadDiff::Branch ? base : QString());
  }
  QStringList viewedPaths() const {
    const QSet<QString> paths = viewed.value(viewedKey());
    QStringList out(paths.cbegin(), paths.cend());
    out.sort();
    return out;
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
      dropReview();
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
    if (reviewing() && quiet) return;
    setStatus(QStringLiteral("loading"), reviewing() ? QStringLiteral("Loading changes...") : QStringLiteral("Loading checkpoint diff..."));
  }

  // The agent changed the checkout: what is shown of it is asked for again.
  void follow() {
    if (!reviewing()) return;
    loaded.reset();
    quiet = status == QLatin1String("ready");
    load();
    quiet = false;
  }

  // The thread's checkpoints changed in its stream.
  void streamed(const QString& thread, const Checkpoints& next) {
    const QStringList before = mutationOf(mc.value(thread));
    mc[thread] = next;
    if (thread != this->thread) return;
    readCheckpoints();
    if (timeline && mutationOf(next) != before) follow();
  }
  static QStringList mutationOf(const Checkpoints& checkpoints) {
    QStringList out;
    for (const Checkpoint& checkpoint : checkpoints) out.append(checkpoint.id + QLatin1Char('=') + checkpoint.status);
    out.sort();
    return out;
  }

  void setStatus(const QString& next, const QString& why = {}) {
    status = next;
    message = why;
  }
  void clearDiff() {
    files.clear();
    fileTotal = 0;
  }
  void dropReview() {
    sourceKey.clear();
    lazy = false;
  }
  void present(const QStringList& diff) {
    files = diff;
    fileTotal = int(diff.size());
    // A review cut short shows every file it lists.
    if (lazy || (!focus.isEmpty() && !diff.contains(focus))) focus.clear();
    presented = focus;
  }
  QStringList shown() const { return focus.isEmpty() ? files : QStringList{focus}; }

  void answer(const Request& request, const Answer& answer) {
    if (!request.file.isEmpty()) {
      // A file's changes are taken while its listing is shown.
      if (request.listing != listing || !lazy || !fileStates.contains(request.file)) return;
      QString& state = fileStates[request.file];
      if (!state.isEmpty()) state = answer.error ? QStringLiteral("error") : QString();
      return;
    }
    if (request.number != this->request) return;
    if (answer.error) {
      loaded.reset();
      // The same selection read again keeps the diff shown, with the reason.
      if (!files.isEmpty() && keyOf(request) == shownKey) {
        setStatus(QStringLiteral("ready"), *answer.error);
        return;
      }
      dropReview();
      clearDiff();
      setStatus(QStringLiteral("error"), *answer.error);
      return;
    }
    if (request.method == QLatin1String("review.getDiffPreview")) {
      comparedBase = answer.base;
      comparedHead = answer.head;
      truncated = answer.truncated;
      const QString kind = request.selection == ThreadDiff::Branch ? QStringLiteral("branch-range") : QStringLiteral("working-tree");
      const QString key = kind + QLatin1Char(' ') + answer.files.join(QLatin1Char(',')) + (answer.truncated ? QStringLiteral(" cut") : QString());
      if (key != sourceKey || focus != presented) {
        sourceKey = key;
        lazy = answer.truncated && !answer.files.isEmpty();
        lazyKind = kind;
        if (lazy) {
          ++listing;
          fileStates.clear();
          for (const QString& file : answer.files) fileStates.insert(file, QStringLiteral("unloaded"));
          opened.clear();
        }
        present(answer.files);
      }
    } else {
      dropReview();
      present(answer.files);
    }
    if (!answer.files.isEmpty()) {
      shownKey = keyOf(request);
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
    // All changes of a thread with no turns is not a choice, nor the checkout without one.
    if (selection == 0 && turns().isEmpty()) selection = -1;
    if (selection <= ThreadDiff::WorkingTree && cwd.isEmpty()) selection = -1;
    load();
  }
};

// The picker's facts, and what each property's signal covers.
struct Facts {
  QList<int> choices;
  int latestTurn;
  std::optional<Checkpoint> latestCheckpoint;
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
  QStringList viewed;
};

Facts factsOf(const Model& model) {
  return {model.choices(), model.latestTurn(), model.latestCheckpoint(), model.picked(), model.shownTurn(), model.reviewing(), model.status, model.message,
          model.focus,     model.fileTotal,    model.base,      model.comparedBase, model.comparedHead, model.truncated, model.viewedPaths()};
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
  std::unique_ptr<QSignalSpy> viewedChanged;
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
      request.file = p.value(QLatin1String("file")).toObject().value(QLatin1String("path")).toString();
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
    viewedChanged = std::make_unique<QSignalSpy>(diff.get(), &ThreadDiff::viewedChanged);
  }
  ~Sut() {
    turnsChanged.reset();
    selectionChanged.reset();
    statusChanged.reset();
    focusChanged.reset();
    reviewChanged.reset();
    viewedChanged.reset();
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
                                         {QStringLiteral("files"), filesOf(checkpoint)}}});
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
      } else if (!request.file.isEmpty()) {
        // One file's changes, from either source.
        const QString patch = patchOf({request.file});
        QJsonArray sources;
        for (const QString kind : {QStringLiteral("working-tree"), QStringLiteral("branch-range")}) {
          sources.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("diff"), patch}, {QStringLiteral("truncated"), false}});
        }
        mc.reply(answered.rpc, QJsonObject{{QStringLiteral("sources"), sources}});
      } else if (request.method == QLatin1String("review.getDiffPreview")) {
        const auto source = [](const QString& kind, const Answer& answer) {
          // A source cut short counts every file.
          QJsonArray stats;
          for (const QString& file : answer.files) {
            stats.append(QJsonObject{{QStringLiteral("path"), file}, {QStringLiteral("previousPath"), QJsonValue()},
                                     {QStringLiteral("additions"), 1}, {QStringLiteral("deletions"), 1}});
          }
          const QString patch = patchOf(answer.files);
          return QJsonObject{{QStringLiteral("kind"), kind},           {QStringLiteral("diff"), patch},
                             {QStringLiteral("diffHash"), QString::number(qHash(patch), 16)},
                             {QStringLiteral("baseRef"), answer.base}, {QStringLiteral("headRef"), answer.head},
                             {QStringLiteral("truncated"), answer.truncated}, {QStringLiteral("files"), stats}};
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
  RC_ASSERT(diff.selection() == expected.picked());
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
  RC_ASSERT(diff.viewedPaths() == expected.viewedPaths());
  // A shown viewed file is collapsed (one shown alone is shown open).
  if (expected.status == QLatin1String("ready") && !expected.lazy && expected.focus.isEmpty()) {
    for (const QString& path : expected.viewedPaths()) {
      const int file = diff.model()->fileOf(path);
      if (file >= 0) RC_ASSERT(!diff.model()->expanded(file));
    }
  }
  RC_ASSERT(diff.baseRef() == expected.base);
  RC_ASSERT(diff.ignoreWhitespace() == expected.whitespace);
  if (expected.status == QLatin1String("ready")) {
    RC_ASSERT(diff.fileTotal() == expected.fileTotal);
    RC_ASSERT(sut.paths() == expected.shown());
  }
  if (expected.status == QLatin1String("empty") || expected.status == QLatin1String("error")) RC_ASSERT(sut.paths().isEmpty());
  if (expected.status == QLatin1String("ready") && expected.lazy) {
    DiffModel& model = *diff.model();
    for (int f = 0; f < model.fileCount(); ++f) {
      RC_ASSERT(model.state(f) == expected.fileStates.value(model.path(f)));
      RC_ASSERT(model.expanded(f) == expected.opened.contains(model.path(f)));
    }
  }

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
  RC_ASSERT(sut.turnsChanged->count() ==
            (before.choices != after.choices || before.latestTurn != after.latestTurn || before.latestCheckpoint != after.latestCheckpoint ? 1 : 0));
  // The latest checkpoint as the timeline has it.
  const QJsonObject latest = diff.latestCheckpoint();
  RC_ASSERT(latest.value(QLatin1String("id")).toString() == (after.latestCheckpoint ? after.latestCheckpoint->id : QString()));
  RC_ASSERT(int(latest.value(QLatin1String("files")).toArray().size()) == (after.latestCheckpoint ? after.latestCheckpoint->files : 0));
  RC_ASSERT(sut.selectionChanged->count() ==
            (before.selection != after.selection || before.shownTurn != after.shownTurn || before.reviewing != after.reviewing ? 1 : 0));
  RC_ASSERT(sut.statusChanged->count() == (before.status != after.status || before.message != after.message ? 1 : 0));
  RC_ASSERT(sut.focusChanged->count() == (before.focus != after.focus || before.fileTotal != after.fileTotal ? 1 : 0));
  RC_ASSERT(sut.reviewChanged->count() == (before.base != after.base || before.comparedBase != after.comparedBase ||
                                                   before.comparedHead != after.comparedHead || before.truncated != after.truncated
                                               ? 1
                                               : 0));
  RC_ASSERT(sut.viewedChanged->count() == (before.viewed != after.viewed ? 1 : 0));
  for (QSignalSpy* spy : {sut.turnsChanged.get(), sut.selectionChanged.get(), sut.statusChanged.get(), sut.focusChanged.get(),
                          sut.reviewChanged.get(), sut.viewedChanged.get()}) {
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
    const Checkpoints checkpoints = next(model);
    ++model.serial;
    model.streamed(thread, checkpoints);
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
    model.streamed(thread, next(model));
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << id.toStdString() << " of " << thread.toStdString() << " is ready"; }
};

// A checkpoint's summary lists the files its turn changed.
struct Summarize : Step<Summarize> {
  QString thread = *oneOf(kThreads);
  QString id;
  int files = *rc::gen::inRange(1, 4);
  explicit Summarize(const Model& model) {
    QStringList ids;
    for (const Checkpoint& checkpoint : model.mc.value(thread)) {
      if (checkpoint.files != files) ids.append(checkpoint.id);
    }
    RC_PRE(!ids.isEmpty());
    id = *oneOf(ids);
  }
  void checkPreconditions(const Model& model) const override {
    const Checkpoints checkpoints = model.mc.value(thread);
    RC_PRE(std::any_of(checkpoints.begin(), checkpoints.end(), [&](const Checkpoint& checkpoint) { return checkpoint.id == id; }));
  }
  Checkpoints next(const Model& model) const {
    Checkpoints checkpoints = model.mc.value(thread);
    for (Checkpoint& checkpoint : checkpoints) {
      if (checkpoint.id == id) checkpoint.files = files;
    }
    return checkpoints;
  }
  // As any change to the checkpoints, it asks again for a diff that failed.
  void apply(Model& model) const override {
    model.streamed(thread, next(model));
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << id.toStdString() << " of " << thread.toStdString() << " lists " << files << " files"; }
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
    model.streamed(thread, next(model));
  }
  void act(const Model& before, Sut& sut) const { sut.stream(thread, next(before)); }
  void show(std::ostream& os) const override { os << thread.toStdString() << " is rewound to turn " << turn; }
};

// --- The user ----------------------------------------------------------------------

// The thread's checkout becomes `cwd`; the checkout's own choices go with it.
void checkOut(Model& model, const QString& cwd) {
  if (cwd == model.cwd) return;
  model.cwd = cwd;
  if (cwd.isEmpty() && model.selection <= ThreadDiff::WorkingTree) model.selection = -1;
  model.load();
}

struct SetThread : Step<SetThread> {
  QString thread = *oneOf(kThreads);
  bool timeline = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
  QString cwd = *oneOf(kCheckouts);
  explicit SetThread(const Model&) {}
  void apply(Model& model) const override {
    if (thread == model.thread && timeline == model.timeline) {
      checkOut(model, cwd);
      return;
    }
    if (thread != model.thread) {
      if (!model.thread.isEmpty()) model.choices_.insert(model.thread, {model.selection, model.base, model.latestPicked});
      const auto [selection, base, latestPicked] = model.choices_.value(thread, {-1, QString(), false});
      model.choices_.remove(thread);
      model.thread = thread;
      ++model.request;
      model.loaded.reset();
      model.shownKey.clear();
      model.clearDiff();
      model.focus.clear();
      model.comparedBase.clear();
      model.comparedHead.clear();
      model.truncated = false;
      model.dropReview();
      model.selection = selection;
      model.base = base;
      model.latestPicked = latestPicked;
      model.setStatus(QStringLiteral("idle"));
    }
    model.timeline = timeline;
    // The thread's choice is checked against its own checkout.
    model.cwd = cwd;
    model.readCheckpoints();
  }
  void act(const Model&, Sut& sut) const {
    sut.diff->setThread(kEnvironment, thread, timeline ? sut.timelines.at(thread).get() : nullptr, cwd);
  }
  void show(std::ostream& os) const override {
    os << "open " << thread.toStdString() << (timeline ? "" : " before its timeline") << " on '" << cwd.toStdString() << "'";
  }
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
  void apply(Model& model) const override { checkOut(model, cwd); }
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
    // Picking the latest turn shows it from then on, even when it changed nothing.
    if (next == model.selection && !(next == -1 && model.opensOnAllChanges())) {
      if (next == -1) model.latestPicked = true;
      return;
    }
    model.selection = next;
    model.latestPicked = next == -1;
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

// A file of a review cut short is opened, or retried after it failed.
struct OpenFile : Step<OpenFile> {
  QString path;
  explicit OpenFile(const Model& model) {
    QStringList paths;
    for (auto it = model.fileStates.cbegin(); it != model.fileStates.cend(); ++it) {
      if (it.value() == QLatin1String("unloaded") || it.value() == QLatin1String("error")) paths.append(it.key());
    }
    RC_PRE(model.lazy && model.status == QLatin1String("ready") && !paths.isEmpty());
    path = *oneOf(paths);
  }
  void checkPreconditions(const Model& model) const override {
    const QString state = model.fileStates.value(path);
    RC_PRE(model.lazy && model.status == QLatin1String("ready") && (state == QLatin1String("unloaded") || state == QLatin1String("error")));
  }
  void apply(Model& model) const override {
    model.fileStates[path] = QStringLiteral("loading");
    model.opened.insert(path);
    Request request{QStringLiteral("review.getDiffPreview"), {}, -1, -1, model.whitespace, model.cwd};
    if (model.lazyKind == QLatin1String("branch-range")) request.base = model.base;
    request.file = path;
    request.listing = model.listing;
    model.pending.append(request);
  }
  void act(const Model& before, Sut& sut) const {
    // Opening it asks for its changes; a failed one opened already has a retry.
    if (before.opened.contains(path)) {
      sut.diff->retryFile(path);
    } else {
      sut.diff->model()->setExpanded(sut.diff->model()->fileOf(path), true);
    }
  }
  void show(std::ostream& os) const override { os << "open " << path.toStdString(); }
};

// A file is marked viewed or not. Only on a diff shown whole: on one cut
// short, expanding a file would ask the MC for it, which OpenFile covers.
struct SetViewed : Step<SetViewed> {
  QString path = *oneOf(kFocus.mid(1));
  bool viewed = *rc::gen::arbitrary<bool>();
  explicit SetViewed(const Model& model) { RC_PRE(model.status == QLatin1String("ready") && !model.lazy); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.status == QLatin1String("ready") && !model.lazy); }
  void apply(Model& model) const override {
    if (!model.shown().contains(path)) return;
    QSet<QString>& paths = model.viewed[model.viewedKey()];
    if (viewed == paths.contains(path)) return;
    if (viewed) {
      paths.insert(path);
    } else {
      paths.remove(path);
    }
    if (paths.isEmpty()) model.viewed.remove(model.viewedKey());
  }
  void act(const Model&, Sut& sut) const { sut.diff->setViewed(path, viewed); }
  void show(std::ostream& os) const override { os << "mark " << path.toStdString() << (viewed ? " viewed" : " not viewed"); }
};

}  // namespace

class WorkspaceThreadDiffProp : public QObject {
  Q_OBJECT

private slots:
  void diff() {
    QVERIFY(rc::check("the Diff tab shows what the MC says of the selection, which is always one of the choices", [] {
      Sut sut;
      rc::state::check(Model(), sut,
                       rc::state::gen::execOneOfWithArgs<NewTurn, NewTurn, Ready, Summarize, Rewind, SetThread, SetActive, SetActive, SetCheckout,
                                                         Select, Select, SetBase, SetWhitespace, Focus, Reload, AnswerOne, AnswerOne,
                                                         AnswerOne, AnswerOne, OpenFile, OpenFile, SetViewed, SetViewed>());
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceThreadDiffProp)
#include "tst_WorkspaceThreadDiffProp.moc"
