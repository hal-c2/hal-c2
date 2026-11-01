// A page's history as the user looks through it (SpaceHistory), against a model
// of what they should see.
//
// The model keeps the MC's versions of two pages, the page whose history is shown
// and the version being read. The user opens and closes histories, asks for more
// and reads versions while the MC writes new ones (each asked about, as the
// controller does) and answers come late, out of order, or as refusals. After each
// step the rows hold only the shown page's versions, newest first and none twice;
// at most one stretch is on its way; and an answer to anything since replaced
// changes nothing. Once every answer is in and none was refused, the rows are the
// page's newest versions, whatever raced whatever. A refresh that reaches a row
// already held never leaves fewer rows, though the MC sends only so many at once.

#include "Prop.h"

#include <QAbstractItemModelTester>

#include <algorithm>
#include <vector>

#include "SpaceController.h"

namespace {

const QStringList kPages{QStringLiteral("page-1"), QStringLiteral("page-2")};
// What the fake MC sends when not told how many, small enough to page through.
constexpr int kStretch = 3;
constexpr int kMaxVersions = 12;
// The most the fake MC sends at once, below what a refresh asks for.
constexpr int kMost = 5;

struct Model {
  // Each page's versions, oldest first; numbers are never shared between pages.
  QHash<QString, QList<qint64>> versions;
  qint64 seq = 0;
  QString shown;
  // Reads asked for and not yet answered, the one on screen, and whether it came.
  std::vector<int> reads;
  int nextRead = 0;
  int reading = -1;
  bool arrived = false;
};

struct Sut {
  struct Waiting {
    int token;
    QJsonObject answer;
    bool fromTheTop;
  };

  SpaceHistory history{[](const QString&) { return QString(); }};
  QAbstractItemModelTester rows{history.versions()};
  std::vector<Waiting> waiting;
  QHash<int, int> readTokens;
  // The stretch still wanted, and whether a refusal may have left the rows behind.
  int live = 0;
  bool missed = false;
};

using Command = rc::state::Command<Model, Sut>;

QJsonObject answerTo(const Model& model, const QJsonObject& payload) {
  const QList<qint64> all = model.versions.value(payload.value(QLatin1String("pageId")).toString());
  const qint64 before = payload.value(QLatin1String("before")).toInteger(-1);
  const int limit = std::min(payload.value(QLatin1String("limit")).toInt(kStretch), kMost);
  QJsonArray shown;
  QJsonValue next(QJsonValue::Null);
  for (auto it = all.crbegin(); it != all.crend(); ++it) {
    if (before >= 0 && *it >= before) continue;
    if (shown.size() == limit) {
      next = shown.last().toObject().value(QLatin1String("version"));
      break;
    }
    shown.append(QJsonObject{{QStringLiteral("version"), *it}, {QStringLiteral("at"), QStringLiteral("2026-09-23T10:00:00Z")}});
  }
  return {{QStringLiteral("versions"), shown}, {QStringLiteral("nextBefore"), next}};
}

// Sends what the history asked for, as the MC reads it at this moment.
void ask(const Model& model, Sut& sut, const SpaceHistory::Next& request) {
  if (!request) return;
  RC_ASSERT(sut.live == 0);
  sut.live = request->token;
  sut.waiting.push_back({request->token, answerTo(model, request->payload), !request->payload.contains(QLatin1String("before"))});
}

QList<qint64> rowsOf(const Sut& sut) {
  QList<qint64> rows;
  for (const QVariantMap& row : sut.history.versions()->rows()) rows.append(row.value(QStringLiteral("version")).toLongLong());
  return rows;
}

void check(const Model& model, const Sut& sut) {
  RC_ASSERT(sut.history.pageId() == model.shown);
  RC_ASSERT(sut.history.shown() == !model.shown.isEmpty());
  RC_ASSERT(sut.history.loading() == (sut.live != 0));
  const QList<qint64> rows = rowsOf(sut);
  const QList<qint64> all = model.versions.value(model.shown);
  RC_ASSERT(std::is_sorted(rows.begin(), rows.end(), std::greater<>()));
  RC_ASSERT(std::adjacent_find(rows.begin(), rows.end()) == rows.end());
  for (const qint64 version : rows) RC_ASSERT(all.contains(version));
  RC_ASSERT(sut.history.reading() == (model.reading >= 0));
  RC_ASSERT(sut.history.version().isEmpty() == !model.arrived);
  RC_ASSERT(sut.history.blocks()->rowCount() == (model.arrived ? 1 : 0));
}

void answer(const Model& model, Sut& sut, size_t index, bool refuse) {
  const Sut::Waiting waiting = sut.waiting.at(index);
  sut.waiting.erase(sut.waiting.begin() + static_cast<std::ptrdiff_t>(index));
  const bool live = waiting.token == sut.live;
  const QList<qint64> held = rowsOf(sut);
  const auto keeps = [&] {
    return live && !refuse && waiting.fromTheTop && held.contains(waiting.answer.value(QLatin1String("nextBefore")).toInteger(-1));
  };
  if (live) {
    sut.live = 0;
    if (refuse) {
      sut.missed = true;
    } else if (waiting.fromTheTop) {
      sut.missed = false;
    }
  }
  ask(model, sut, refuse ? sut.history.failed(waiting.token) : sut.history.receive(waiting.token, waiting.answer));
  if (keeps()) RC_ASSERT(rowsOf(sut).size() >= held.size());
}

struct Open : Command {
  QString page = kPages.at(*rc::gen::inRange(0, 2));

  void apply(Model& model) const override {
    model.shown = page;
    model.reading = -1;
    model.arrived = false;
  }
  void run(const Model& before, Sut& sut) const override {
    const Model model = nextState(before);
    sut.live = 0;
    sut.missed = false;
    ask(model, sut, sut.history.open(page));
    check(model, sut);
  }
  void show(std::ostream& os) const override { os << "Open(" << page.toStdString() << ")"; }
};

struct Close : Command {
  void apply(Model& model) const override {
    model.shown.clear();
    model.reading = -1;
    model.arrived = false;
  }
  void run(const Model& before, Sut& sut) const override {
    sut.live = 0;
    sut.missed = false;
    sut.history.close();
    check(nextState(before), sut);
  }
  void show(std::ostream& os) const override { os << "Close"; }
};

struct Write : Command {
  QString page = kPages.at(*rc::gen::inRange(0, 2));

  void checkPreconditions(const Model& model) const override { RC_PRE(model.versions.value(page).size() < kMaxVersions); }
  void apply(Model& model) const override { model.versions[page].append(++model.seq); }
  void run(const Model& before, Sut& sut) const override {
    const Model model = nextState(before);
    if (model.shown == page) ask(model, sut, sut.history.refresh());
    check(model, sut);
  }
  void show(std::ostream& os) const override { os << "Write(" << page.toStdString() << ")"; }
};

struct More : Command {
  void run(const Model& model, Sut& sut) const override {
    ask(model, sut, sut.history.more());
    check(model, sut);
  }
  void show(std::ostream& os) const override { os << "More"; }
};

struct Answer : Command {
  int pick = *rc::gen::inRange(0, 8);
  bool refuse = *rc::gen::weightedElement<bool>({{1, true}, {4, false}});

  void run(const Model& model, Sut& sut) const override {
    if (!sut.waiting.empty()) answer(model, sut, static_cast<size_t>(pick) % sut.waiting.size(), refuse);
    check(model, sut);
  }
  void show(std::ostream& os) const override { os << "Answer(" << pick << (refuse ? " refused)" : ")"); }
};

// Every answer in, none refused: the rows are the page's newest versions.
struct Settle : Command {
  void run(const Model& model, Sut& sut) const override {
    while (!sut.waiting.empty()) answer(model, sut, 0, false);
    check(model, sut);
    if (model.shown.isEmpty() || sut.missed) return;
    QList<qint64> newest = model.versions.value(model.shown);
    std::reverse(newest.begin(), newest.end());
    const QList<qint64> rows = rowsOf(sut);
    RC_ASSERT(rows == newest.first(rows.size()));
    RC_ASSERT(rows.isEmpty() == newest.isEmpty());
    RC_ASSERT(sut.history.hasMore() == (rows.size() < newest.size()));
  }
  void show(std::ostream& os) const override { os << "Settle"; }
};

struct Read : Command {
  int pick = *rc::gen::inRange(0, 8);

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.shown.isEmpty()); }
  void apply(Model& model) const override {
    model.reads.push_back(model.nextRead);
    model.reading = model.nextRead++;
    model.arrived = false;
  }
  void run(const Model& before, Sut& sut) const override {
    sut.readTokens.insert(before.nextRead, sut.history.read(pick).token);
    check(nextState(before), sut);
  }
  void show(std::ostream& os) const override { os << "Read(" << pick << ")"; }
};

struct Back : Command {
  void apply(Model& model) const override {
    model.reading = -1;
    model.arrived = false;
  }
  void run(const Model& before, Sut& sut) const override {
    sut.history.stopReading();
    check(nextState(before), sut);
  }
  void show(std::ostream& os) const override { os << "Back"; }
};

struct AnswerRead : Command {
  int pick = *rc::gen::inRange(0, 8);
  bool refuse = *rc::gen::weightedElement<bool>({{1, true}, {4, false}});

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.reads.empty()); }
  void apply(Model& model) const override {
    const auto at = model.reads.begin() + static_cast<std::ptrdiff_t>(static_cast<size_t>(pick) % model.reads.size());
    if (*at == model.reading) {
      model.arrived = !refuse;
      if (refuse) model.reading = -1;
    }
    model.reads.erase(at);
  }
  void run(const Model& before, Sut& sut) const override {
    const int read = before.reads.at(static_cast<size_t>(pick) % before.reads.size());
    const int token = sut.readTokens.take(read);
    if (refuse) {
      sut.history.failedVersion(token);
    } else {
      sut.history.receiveVersion(token, {{QStringLiteral("version"), read},
                                         {QStringLiteral("at"), QStringLiteral("2026-09-23T10:00:00Z")},
                                         {QStringLiteral("title"), QStringLiteral("Roadmap")},
                                         {QStringLiteral("blocks"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("b1")}}}}});
    }
    check(nextState(before), sut);
  }
  void show(std::ostream& os) const override { os << "AnswerRead(" << pick << (refuse ? " refused)" : ")"); }
};

}  // namespace

class SpaceHistoryProp : public QObject {
  Q_OBJECT

private slots:
  void history() {
    QVERIFY(rc::check("the versions shown are the shown page's, whatever order the answers come in", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<Open, Close, Write, Write, Write, More, Answer, Answer, Answer, Settle, Read, Back,
                                                         AnswerRead>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceHistoryProp)
#include "tst_SpaceHistoryProp.moc"
