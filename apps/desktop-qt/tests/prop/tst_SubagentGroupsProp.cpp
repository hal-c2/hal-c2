// The subagents of a running turn as the timeline groups them (TimelineModel)
// and the Agents tab counts them (AgentsModel), against a model of what the
// user should see.
//
// Subagents arrive one at a time under one of two provider turns, change
// status, and a reply can come between them. Subagents that one provider turn
// started in a row are one group; a lone one is its own row. The user opens
// and closes groups. After each step:
// - the subagent rows are the model's groups, in order;
// - each group is open exactly when the user left it open, whatever arrived
//   since, and lists its members only then;
// - each group reads its counts;
// - a group's span moves exactly while one of its subagents works;
// - the Agents tab counts the subagents still working, and says so only when
//   that count changes.

#include "Prop.h"

#include <QAbstractItemModelTester>
#include <QSignalSpy>

#include <memory>

#include "AgentsModel.h"
#include "TimelineModel.h"

namespace {

const QString kKey = QStringLiteral("env-1:thread-1");
const QString kRun = QStringLiteral("run-1");
const QString kHandle = QStringLiteral("log-1");
constexpr int kMaxItems = 9;

const QStringList kTurns{QStringLiteral("turn-a"), QStringLiteral("turn-b")};
const QStringList kStatuses{QStringLiteral("pending"),   QStringLiteral("running"), QStringLiteral("waiting"), QStringLiteral("completed"),
                            QStringLiteral("failed"),    QStringLiteral("cancelled"), QStringLiteral("idle")};

QDateTime clock() {
  return QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
}

QString pick(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

bool working(const QString& status) {
  return status == QLatin1String("pending") || status == QLatin1String("running") || status == QLatin1String("waiting");
}

// One turn item after the run's opening message: a subagent, or a reply.
struct Entry {
  QString id;
  QString turn;  // empty for a reply
  QString status;
};

struct Model {
  QList<Entry> entries;
  // The groups the user has open, by row id.
  QSet<QString> open;
  qint64 seq = 1;
};

// A run of subagents one turn started in a row.
struct Group {
  QString id;
  QStringList members;
  QStringList statuses;
};

QList<Group> groupsOf(const Model& model) {
  QList<Group> groups;
  QString turn;
  for (const Entry& entry : model.entries) {
    if (entry.turn.isEmpty()) {
      turn.clear();
      continue;
    }
    if (entry.turn != turn || groups.isEmpty()) groups.append({QStringLiteral("subagents:") + entry.id, {}, {}});
    turn = entry.turn;
    groups.last().members.append(entry.id);
    groups.last().statuses.append(entry.status);
  }
  return groups;
}

// "2 working · 1 done", working first, then the outcomes (subagentDisplay.ts).
QString counts(const QStringList& statuses) {
  const QList<std::pair<QString, std::function<bool(const QString&)>>> words{
      {QStringLiteral("working"), working},
      {QStringLiteral("done"), [](const QString& s) { return s == QLatin1String("completed"); }},
      {QStringLiteral("failed"), [](const QString& s) { return s == QLatin1String("failed"); }},
      {QStringLiteral("stopped"), [](const QString& s) { return s == QLatin1String("cancelled"); }},
      {QStringLiteral("idle"), [](const QString& s) { return s == QLatin1String("idle"); }},
  };
  QStringList parts;
  for (const auto& [word, counts] : words) {
    const auto n = std::count_if(statuses.cbegin(), statuses.cend(), counts);
    if (n > 0) parts.append(QStringLiteral("%1 %2").arg(n).arg(word));
  }
  return parts.join(QStringLiteral(" · "));
}

// A subagent row as the user sees it: its id, kind, whether it is open and
// what it reads.
struct Shown {
  QString id;
  QString kind;
  bool open = false;
  QString text;
  bool operator==(const Shown&) const = default;
};

std::ostream& operator<<(std::ostream& os, const Shown& row) {
  return os << row.kind.toStdString() << "(" << row.id.toStdString() << (row.open ? ", open" : "") << ", " << row.text.toStdString() << ")";
}

QList<Shown> project(const Model& model) {
  QList<Shown> rows;
  for (const Group& group : groupsOf(model)) {
    if (group.members.size() == 1) {
      rows.append({group.members.first(), QStringLiteral("subagent")});
      continue;
    }
    const bool open = model.open.contains(group.id);
    rows.append({group.id, QStringLiteral("subagents"), open, counts(group.statuses)});
    if (open) {
      for (const QString& member : group.members) rows.append({member, QStringLiteral("subagent")});
    }
  }
  return rows;
}

// Whether a group's span is moving: some group has a working member.
bool ticking(const Model& model) {
  const QList<Group> groups = groupsOf(model);
  return std::any_of(groups.cbegin(), groups.cend(), [](const Group& group) {
    return group.members.size() > 1 && std::any_of(group.statuses.cbegin(), group.statuses.cend(), working);
  });
}

int liveCount(const Model& model) {
  return int(std::count_if(model.entries.cbegin(), model.entries.cend(), [](const Entry& e) { return !e.turn.isEmpty() && working(e.status); }));
}

QJsonObject eventsFrame(qint64 seq, const QList<std::tuple<QString, QString, QJsonObject>>& changes) {
  QJsonArray list;
  qint64 at = seq - changes.size();
  for (const auto& [kind, id, fields] : changes) {
    list.append(QJsonArray{++at, kind, id, QJsonObject{{QStringLiteral("s"), fields}}, QStringLiteral("2026-09-23T10:00:00Z")});
  }
  return {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq}, {QStringLiteral("events"), list}};
}

struct Sut {
  std::unique_ptr<TimelineModel> timeline;
  std::unique_ptr<QAbstractItemModelTester> tester;
  AgentsModel agents;
  int liveSignals = 0;

  Sut() {
    timeline = std::make_unique<TimelineModel>(kKey);
    timeline->setClock(clock);
    timeline->setFolds(TimelineModel::Folds::Desktop);
    tester = std::make_unique<QAbstractItemModelTester>(timeline.get(), QAbstractItemModelTester::FailureReportingMode::Fatal);
    agents.setClock(clock);
    agents.setThread(QStringLiteral("env-1"), timeline.get());
    QObject::connect(&agents, &AgentsModel::liveAgentCountChanged, &agents, [this] { ++liveSignals; });
    const QJsonArray rows{
        QJsonArray{QStringLiteral("run"), kRun,
                   QJsonObject{{QStringLiteral("id"), kRun}, {QStringLiteral("ordinal"), 1}, {QStringLiteral("status"), QStringLiteral("running")},
                               {QStringLiteral("requestedAt"), QStringLiteral("2026-09-23T09:59:00Z")}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T09:59:00Z")}}},
        QJsonArray{QStringLiteral("turn-item"), QStringLiteral("message:") + kRun,
                   QJsonObject{{QStringLiteral("id"), QStringLiteral("message:") + kRun}, {QStringLiteral("type"), QStringLiteral("user_message")},
                               {QStringLiteral("runId"), kRun}, {QStringLiteral("ordinal"), 1}, {QStringLiteral("status"), QStringLiteral("completed")},
                               {QStringLiteral("text"), QStringLiteral("Add a tax line")}}}};
    timeline->receive({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("part"), 0}, {QStringLiteral("rows"), rows},
                       {QStringLiteral("done"), true}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), kHandle},
                       {QStringLiteral("floor"), QJsonValue(QJsonValue::Null)}});
    timeline->receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), kHandle}});
  }

  ~Sut() {
    agents.setThread({}, nullptr);
    tester.reset();
  }

  QList<Shown> rows() const {
    QList<Shown> rows;
    for (int row = 0; row < timeline->rowCount(); ++row) {
      const auto value = [&](int role) { return timeline->data(timeline->index(row), role); };
      const QString kind = value(TimelineModel::KindRole).toString();
      if (kind != QLatin1String("subagent") && kind != QLatin1String("subagents")) continue;
      const bool group = kind == QLatin1String("subagents");
      rows.append({value(TimelineModel::IdRole).toString(), kind, group && value(TimelineModel::ExpandedRole).toBool(),
                   group ? value(TimelineModel::TextRole).toString() : QString()});
    }
    return rows;
  }

  void check(const Model& expected, int liveBefore) {
    const QList<Shown> want = project(expected);
    const QList<Shown> got = rows();
    RC_LOG() << "want " << rc::toString(std::vector<Shown>(want.cbegin(), want.cend())) << "\n";
    RC_ASSERT(got == want);
    const int live = liveCount(expected);
    RC_ASSERT(agents.liveAgentCount() == live);
    RC_ASSERT(liveSignals == (live == liveBefore ? 0 : 1));
    RC_ASSERT(timeline->spansTicking() == ticking(expected));
  }
};

using Command = rc::state::Command<Model, Sut>;

// Commands that change the MC's thread: the model moves on, the client is
// sent the events, and the rows follow.
struct Change : Command {
  virtual QList<std::tuple<QString, QString, QJsonObject>> changes(const Model& model) const = 0;
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const int liveBefore = sut.agents.liveAgentCount();
    sut.liveSignals = 0;
    sut.timeline->receive(eventsFrame(next.seq, changes(model)));
    sut.check(next, liveBefore);
  }
};

struct AddSubagent : Change {
  QString turn;
  QString status;
  explicit AddSubagent(const Model&) : turn(pick(kTurns)), status(pick(kStatuses)) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.entries.size() < kMaxItems); }
  QString id(const Model& model) const { return QStringLiteral("item-%1").arg(model.entries.size() + 1); }
  void apply(Model& model) const override {
    model.entries.append({id(model), turn, status});
    model.seq += 2;
  }
  QList<std::tuple<QString, QString, QJsonObject>> changes(const Model& model) const override {
    const QString item = id(model);
    const QString agent = QStringLiteral("task-") + item;
    const int ordinal = int(model.entries.size()) + 2;
    return {{QStringLiteral("subagent"), agent,
             QJsonObject{{QStringLiteral("id"), agent}, {QStringLiteral("threadId"), QStringLiteral("thread-1")}, {QStringLiteral("runId"), kRun},
                         {QStringLiteral("title"), item}, {QStringLiteral("status"), status}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T09:59:30Z")}}},
            {QStringLiteral("turn-item"), item,
             QJsonObject{{QStringLiteral("id"), item}, {QStringLiteral("type"), QStringLiteral("subagent")}, {QStringLiteral("runId"), kRun},
                         {QStringLiteral("ordinal"), ordinal}, {QStringLiteral("subagentId"), agent}, {QStringLiteral("providerTurnId"), turn},
                         {QStringLiteral("title"), item}, {QStringLiteral("status"), status}}}};
  }
  void show(std::ostream& os) const override { os << "AddSubagent(" << turn.toStdString() << ", " << status.toStdString() << ")"; }
};

// The agent says something between its subagents.
struct Reply : Change {
  explicit Reply(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.entries.size() < kMaxItems); }
  QString id(const Model& model) const { return QStringLiteral("item-%1").arg(model.entries.size() + 1); }
  void apply(Model& model) const override {
    model.entries.append({id(model), {}, QStringLiteral("completed")});
    model.seq += 1;
  }
  QList<std::tuple<QString, QString, QJsonObject>> changes(const Model& model) const override {
    const QString item = id(model);
    return {{QStringLiteral("turn-item"), item,
             QJsonObject{{QStringLiteral("id"), item}, {QStringLiteral("type"), QStringLiteral("assistant_message")}, {QStringLiteral("runId"), kRun},
                         {QStringLiteral("ordinal"), int(model.entries.size()) + 2}, {QStringLiteral("status"), QStringLiteral("completed")},
                         {QStringLiteral("text"), QStringLiteral("On it.")}}}};
  }
  void show(std::ostream& os) const override { os << "Reply"; }
};

struct ChangeStatus : Change {
  QString item;
  QString status;
  explicit ChangeStatus(const Model& model) {
    QStringList ids;
    for (const Entry& entry : model.entries) {
      if (!entry.turn.isEmpty()) ids.append(entry.id);
    }
    RC_PRE(!ids.isEmpty());
    item = pick(ids);
    status = pick(kStatuses);
  }
  void checkPreconditions(const Model& model) const override {
    RC_PRE(std::any_of(model.entries.cbegin(), model.entries.cend(), [&](const Entry& e) { return e.id == item && !e.turn.isEmpty(); }));
  }
  void apply(Model& model) const override {
    for (Entry& entry : model.entries) {
      if (entry.id == item) entry.status = status;
    }
    model.seq += 2;
  }
  QList<std::tuple<QString, QString, QJsonObject>> changes(const Model&) const override {
    const QJsonObject fields{{QStringLiteral("status"), status}};
    return {{QStringLiteral("subagent"), QStringLiteral("task-") + item, fields}, {QStringLiteral("turn-item"), item, fields}};
  }
  void show(std::ostream& os) const override { os << "ChangeStatus(" << item.toStdString() << ", " << status.toStdString() << ")"; }
};

// The user opens or closes a group.
struct Toggle : Command {
  QString group;
  explicit Toggle(const Model& model) {
    QStringList ids;
    for (const Group& found : groupsOf(model)) {
      if (found.members.size() > 1) ids.append(found.id);
    }
    RC_PRE(!ids.isEmpty());
    group = pick(ids);
  }
  void checkPreconditions(const Model& model) const override {
    const QList<Group> groups = groupsOf(model);
    RC_PRE(std::any_of(groups.cbegin(), groups.cend(), [&](const Group& g) { return g.id == group && g.members.size() > 1; }));
  }
  void apply(Model& model) const override {
    if (!model.open.remove(group)) model.open.insert(group);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const int liveBefore = sut.agents.liveAgentCount();
    sut.liveSignals = 0;
    sut.timeline->toggle(group);
    sut.check(next, liveBefore);
  }
  void show(std::ostream& os) const override { os << "Toggle(" << group.toStdString() << ")"; }
};

}  // namespace

class SubagentGroupsProp : public QObject {
  Q_OBJECT

private slots:
  void groups() {
    QVERIFY(rc::check("subagents one turn started in a row are one group, open as the user left it, and the live ones are counted", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<AddSubagent, AddSubagent, AddSubagent, Reply, ChangeStatus, ChangeStatus, Toggle, Toggle>());
    }));
  }
};

HAL_C2_PROP_MAIN(SubagentGroupsProp)
#include "tst_SubagentGroupsProp.moc"
