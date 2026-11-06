// The requests the "Some requests are slow" warning lists
// (src/native/SlowRequests), over any order of calls starting and ending and
// time passing: a tracked call is listed once it has waited its threshold
// when the time is next told, until it ends; untracked calls never are; and
// each step says whether the list changed.

#include "Prop.h"

#include <QList>

#include <algorithm>
#include <string>
#include <vector>

#include "SlowRequests.h"

namespace {

const std::vector<std::string> kMethods{"projects.searchEntries",       "git.listBranches",    "server.updateProvider",
                                        "server.updateServer",          "pullRequests.detail", "server.getUsageSummary",
                                        "orchestration.subscribeThread"};

bool tracked(const std::string& method) {
  return method.find("subscribe") == std::string::npos && method.rfind("pullRequests.", 0) != 0 &&
         method != "server.getUsageSummary";
}

qint64 threshold(const std::string& method) {
  return method == "server.updateProvider" || method == "server.updateServer" ? 120'000 : 15'000;
}

struct Call {
  int id = 0;
  std::string method;
  qint64 started = 0;
};

struct Model {
  qint64 now = 0;
  std::vector<Call> waiting;  // in the order they started
  std::vector<int> slow;      // in the order they became slow

  std::optional<qint64> nextDeadline() const {
    std::optional<qint64> next;
    for (const Call& call : waiting) {
      const qint64 deadline = call.started + threshold(call.method);
      if (!next || deadline < *next) next = deadline;
    }
    return next;
  }
};

struct Sut {
  SlowRequests requests;
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& expected, const Sut& sut) {
  const QList<SlowRequests::Request>& slow = sut.requests.slow();
  RC_ASSERT(std::size_t(slow.size()) == expected.slow.size());
  for (qsizetype index = 0; index < slow.size(); ++index) RC_ASSERT(slow.at(index).id == expected.slow.at(index));
  RC_ASSERT(std::size_t(sut.requests.tracking()) == expected.waiting.size() + expected.slow.size());
  RC_ASSERT(sut.requests.nextDeadline() == expected.nextDeadline());
  RC_ASSERT(sut.requests.description().isEmpty() == expected.slow.empty());
}

bool endIn(Model& model, int id) {
  std::erase_if(model.waiting, [id](const Call& call) { return call.id == id; });
  return std::erase(model.slow, id) > 0;
}

// A call goes out, with an id that may still be listed (the client's ids are
// never reused, but the list must not count one twice).
struct Start : Command {
  int id = *rc::gen::inRange(0, 6);
  std::string method = *rc::gen::elementOf(kMethods);

  explicit Start(const Model&) {}

  bool applyTo(Model& model) const {
    if (!tracked(method)) return false;
    const bool changed = endIn(model, id);
    model.waiting.push_back({id, method, model.now});
    return changed;
  }
  void apply(Model& model) const override { applyTo(model); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const bool changed = applyTo(expected);
    RC_ASSERT(sut.requests.start(id, QStringLiteral("env"), QString::fromStdString(method), model.now) == changed);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Start(" << id << ", " << method << ")"; }
};

// A call is answered or fails, or a stray answer arrives.
struct End : Command {
  int id = *rc::gen::inRange(0, 6);

  explicit End(const Model&) {}

  void apply(Model& model) const override { endIn(model, id); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const bool changed = endIn(expected, id);
    RC_ASSERT(sut.requests.end(id) == changed);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "End(" << id << ")"; }
};

// Time passes and the requests are told.
struct Advance : Command {
  qint64 by = *rc::gen::elementOf(std::vector<qint64>{0, 1'000, 14'999, 15'000, 60'000, 120'000});

  explicit Advance(const Model&) {}

  bool applyTo(Model& model) const {
    model.now += by;
    bool changed = false;
    for (auto it = model.waiting.begin(); it != model.waiting.end();) {
      if (model.now - it->started >= threshold(it->method)) {
        model.slow.push_back(it->id);
        it = model.waiting.erase(it);
        changed = true;
      } else {
        ++it;
      }
    }
    return changed;
  }
  void apply(Model& model) const override { applyTo(model); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const bool changed = applyTo(expected);
    RC_ASSERT(sut.requests.advance(expected.now) == changed);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Advance(" << by << ")"; }
};

}  // namespace

class SlowRequestsProp : public QObject {
  Q_OBJECT

private slots:
  void listsTrackedCallsThatWaitedTheirThreshold() {
    QVERIFY(rc::check("a tracked call is listed once it waited its threshold, until it ends", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Start, Start, End, Advance>());
    }));
  }

  void makesRoomForTheNewest() {
    QVERIFY(rc::check("at most 256 calls are tracked, and the newest always is", [] {
      const int extra = *rc::gen::inRange(1, 40);
      SlowRequests requests;
      for (int id = 0; id < SlowRequests::kMaxTracked + extra; ++id)
        requests.start(id, QStringLiteral("env"), QStringLiteral("git.listBranches"), 0);
      RC_ASSERT(requests.tracking() == SlowRequests::kMaxTracked);
      requests.advance(15'000);
      RC_ASSERT(requests.slow().last().id == SlowRequests::kMaxTracked + extra - 1);
      RC_ASSERT(requests.slow().first().id == extra);
    }));
  }
};

HAL_C2_PROP_MAIN(SlowRequestsProp)
#include "tst_SlowRequestsProp.moc"
