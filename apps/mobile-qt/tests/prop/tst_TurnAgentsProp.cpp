// The subagents of a thread's latest turn (src/TurnAgents) against a model of
// the turns and subagents the MC streams: turns start and settle, subagents
// spawn into the running turn, move between states and are heard from again,
// and the list opens and closes. After each step the list holds the turn the
// roster names (the running turn, else that of the subagent heard from last)
// in the order its subagents started, the summary reads as the model's, and
// QAbstractItemModelTester finds nothing wrong with the row signals.

#include "Prop.h"

#include <QAbstractItemModelTester>

#include <map>
#include <memory>
#include <vector>

#include "TimelineModel.h"
#include "TurnAgents.h"

namespace {

using S = QString;

const S kKey = S("env-1:thread-1");
constexpr int kMaxRuns = 3;
constexpr int kMaxAgents = 6;
const std::vector<S> kStatuses{S("pending"), S("running"), S("waiting"), S("idle"),
                               S("completed"), S("failed"),  S("cancelled")};
const QSet<S> kLive{S("pending"), S("running"), S("waiting")};

QDateTime base() { return QDateTime::fromString(S("2026-09-23T10:00:00Z"), Qt::ISODate); }
S at(int seconds) { return base().addSecs(seconds).toString(Qt::ISODateWithMs); }

struct Agent {
  int run = 0;
  S status;
  int started = 0;  // seconds after base()
  int updated = 0;
  bool native = false;  // managed by the provider: no thread of its own
};

struct Model {
  int runs = 0;           // runs started, run-0 .. run-(runs-1)
  bool running = false;   // the last run has not settled
  std::map<int, Agent> agents;  // by spawn number
  int clock = 0;          // seconds after base(), one per step
  bool active = false;
};

S agentId(int n) { return S("agent-%1").arg(n, 2, 10, QLatin1Char('0')); }
S runId(int n) { return S("run-%1").arg(n); }

// The rows the list should show, as (id, status, thread), and its summary.
struct Expected {
  QList<std::tuple<S, S, S>> rows;
  S summary;
};

Expected expected(const Model& m) {
  int run = -1;
  if (m.running) {
    run = m.runs - 1;
  } else {
    int latest = -1;
    S latestId;
    for (const auto& [n, agent] : m.agents) {
      if (latestId.isEmpty() || agent.updated > latest || (agent.updated == latest && agentId(n) > latestId)) {
        latest = agent.updated;
        latestId = agentId(n);
        run = agent.run;
      }
    }
  }
  Expected out;
  int live = 0;
  // Spawn number is start order: each spawns a step after the last.
  for (const auto& [n, agent] : m.agents) {
    if (agent.run != run) continue;
    out.rows.append({agentId(n), agent.status, agent.native ? S() : S("env-1:child-%1").arg(n)});
    if (kLive.contains(agent.status)) ++live;
  }
  const int total = int(out.rows.size());
  if (total > 0 && (m.running || live > 0)) {
    out.summary = live > 0 ? S("%1 of %2 agents working").arg(live).arg(total)
                           : (total == 1 ? S("1 agent done") : S("%1 agents done").arg(total));
  }
  return out;
}

struct Sut {
  Sut() : timeline(std::make_unique<TimelineModel>(kKey)), agents(std::make_unique<TurnAgents>()) {
    agents->setClock([] { return base().addSecs(3600); });
    timeline->subscribing();
    timeline->receive({{S("t"), S("snapshot")}, {S("part"), 0}, {S("rows"), QJsonArray()}, {S("done"), true},
                       {S("offset"), 0}, {S("handle"), S("log-1")}, {S("floor"), QJsonValue()}});
    timeline->receive({{S("t"), S("live")}, {S("offset"), 0}, {S("handle"), S("log-1")}});
    tester = std::make_unique<QAbstractItemModelTester>(agents.get(), QAbstractItemModelTester::FailureReportingMode::Fatal);
    agents->setTimeline(timeline.get());
  }

  void send(const S& kind, const S& id, const QJsonObject& patch, int clock) {
    ++seq;
    // A patch sets its fields (HalC2.Patch's `s`).
    const QJsonArray event{seq, kind, id, QJsonObject{{S("s"), patch}}, at(clock)};
    timeline->receive({{S("t"), S("events")}, {S("offset"), seq}, {S("events"), QJsonArray{QJsonValue(event)}}});
  }

  void sendRun(int n, const S& status, int ordinal) {
    send(S("run"), runId(n), {{S("status"), status}, {S("ordinal"), ordinal}}, 0);
  }

  void sendAgent(int n, const Agent& agent) {
    QJsonObject patch{{S("runId"), runId(agent.run)},
                      {S("title"), S("Agent %1").arg(n)},
                      {S("status"), agent.status},
                      {S("startedAt"), at(agent.started)},
                      {S("updatedAt"), at(agent.updated)}};
    if (!agent.native) patch.insert(S("childThreadId"), S("child-%1").arg(n));
    send(S("subagent"), agentId(n), patch, agent.updated);
  }

  void check(const Model& m) const {
    const Expected want = expected(m);
    RC_ASSERT(agents->rowCount() == int(want.rows.size()));
    for (int row = 0; row < want.rows.size(); ++row) {
      const auto& [id, status, thread] = want.rows.at(row);
      RC_ASSERT(agents->value(row, TurnAgents::IdRole).toString() == id);
      RC_ASSERT(agents->value(row, TurnAgents::StatusRole).toString() == status);
      RC_ASSERT(agents->value(row, TurnAgents::ThreadRole).toString() == thread);
      RC_ASSERT(agents->value(row, TurnAgents::RunningRole).toBool() == kLive.contains(status));
    }
    RC_ASSERT(agents->summary() == want.summary);
    RC_ASSERT(agents->active() == m.active);
  }

  qint64 seq = 0;
  std::unique_ptr<TimelineModel> timeline;
  std::unique_ptr<TurnAgents> agents;
  std::unique_ptr<QAbstractItemModelTester> tester;
};

using Command = rc::state::Command<Model, Sut>;

// A turn starts: the last one settled first.
struct StartRun : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.runs < kMaxRuns); }
  void apply(Model& m) const override {
    m.running = true;
    ++m.runs;
    ++m.clock;
  }
  void run(const Model& m, Sut& sut) const override {
    if (m.running) sut.sendRun(m.runs - 1, S("completed"), m.runs - 1);
    sut.sendRun(m.runs, S("running"), m.runs);
    Model next = m;
    apply(next);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "StartRun"; }
};

struct SettleRun : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.running); }
  void apply(Model& m) const override {
    m.running = false;
    ++m.clock;
  }
  void run(const Model& m, Sut& sut) const override {
    sut.sendRun(m.runs - 1, S("completed"), m.runs - 1);
    Model next = m;
    apply(next);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "SettleRun"; }
};

struct Spawn : Command {
  S status = *rc::gen::elementOf(std::vector<S>{S("pending"), S("running")});
  bool native = *rc::gen::weightedElement<bool>({{1, true}, {3, false}});
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.running);
    RC_PRE(int(m.agents.size()) < kMaxAgents);
  }
  void apply(Model& m) const override {
    ++m.clock;
    m.agents[int(m.agents.size())] = Agent{m.runs - 1, status, m.clock, m.clock, native};
  }
  void run(const Model& m, Sut& sut) const override {
    Model next = m;
    apply(next);
    const int n = int(m.agents.size());
    sut.sendAgent(n, next.agents.at(n));
    sut.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Spawn(" << status.toStdString() << (native ? ", native" : "") << ")";
  }
};

// A subagent of any turn moves on, or is heard from again in the state it is in.
struct Move : Command {
  int pick = *rc::gen::inRange(0, kMaxAgents);
  S status = *rc::gen::elementOf(kStatuses);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.agents.count(pick) == 1); }
  void apply(Model& m) const override {
    ++m.clock;
    Agent& agent = m.agents.at(pick);
    agent.status = status;
    agent.updated = m.clock;
  }
  void run(const Model& m, Sut& sut) const override {
    Model next = m;
    apply(next);
    sut.sendAgent(pick, next.agents.at(pick));
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Move(" << pick << ", " << status.toStdString() << ")"; }
};

// The list opens or closes.
struct Show : Command {
  bool active = *rc::gen::arbitrary<bool>();
  void apply(Model& m) const override { m.active = active; }
  void run(const Model& m, Sut& sut) const override {
    sut.agents->setActive(active);
    Model next = m;
    apply(next);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Show(" << active << ")"; }
};

}  // namespace

class TurnAgentsProp : public QObject {
  Q_OBJECT

private slots:

  void roster() {
    QVERIFY(rc::check("the list holds the latest turn's subagents in start order, summed up", [] {
      Sut sut;
      sut.check(Model{});
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<StartRun, SettleRun, Spawn, Move, Show>());
    }));
  }
};

HAL_C2_PROP_MAIN(TurnAgentsProp)
#include "tst_TurnAgentsProp.moc"
