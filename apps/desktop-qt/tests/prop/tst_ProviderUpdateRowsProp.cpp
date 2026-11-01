// The provider-update state machines on a pinned clock. Rows: updates started
// on two environments, answered (to the current request or a stale one, with
// an error or a view), refused, and timing out; after every step each row says
// what the model expects, the next deadline is the earliest running one, an
// answer to a request started again is dropped, and an answer to the current
// one replaces its timeout however late. Sidebar: providers whose update
// states change, the notice dismissed and expiring; it never shows a key once
// dismissed or timed out, and a success alone carries a deadline.

#include "Prop.h"

#include "ProviderUpdates.h"

#include <map>
#include <optional>
#include <vector>

using namespace providerUpdates;

namespace {

const QStringList kEnvironments{QStringLiteral("windows"), QStringLiteral("wsl")};
const QStringList kErrors{QString(), QStringLiteral("npm is not installed"), QStringLiteral("boom")};
const QStringList kPhases{QStringLiteral("succeeded"), QStringLiteral("failed"), QStringLiteral("unchanged"),
                          QStringLiteral("running")};
const QString kTimedOut = QStringLiteral("Update timed out — try again.");
const QDateTime kEpoch = QDateTime::fromString(QStringLiteral("2026-09-23T09:00:00Z"), Qt::ISODate);

template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

// rc::Maybe as a std::optional.
template <typename T, typename F>
std::optional<T> maybe(F make) {
  if (!*rc::gen::arbitrary<bool>()) return std::nullopt;
  return make();
}

// An outdated Codex that has not been updated: its row names it while idle.
Group codexGroup(const QString& environmentId) {
  const QJsonObject codex{
      {QStringLiteral("instanceId"), QStringLiteral("codex")},
      {QStringLiteral("driver"), QStringLiteral("codex")},
      {QStringLiteral("enabled"), true},
      {QStringLiteral("checkedAt"), QStringLiteral("2026-09-23T09:00:00.000Z")},
      {QStringLiteral("versionAdvisory"), QJsonObject{{QStringLiteral("status"), QStringLiteral("behind_latest")},
                                                      {QStringLiteral("currentVersion"), QStringLiteral("0.50.0")},
                                                      {QStringLiteral("latestVersion"), QStringLiteral("0.51.0")},
                                                      {QStringLiteral("updateCommand"), QStringLiteral("npm i -g codex")},
                                                      {QStringLiteral("canUpdate"), true}}}};
  return group(environmentId, environmentId, QJsonArray{codex});
}

// ---- Rows ----

struct RowModel {
  int version = 0;
  bool running = false;
  std::optional<qint64> deadline;
  QString error;
  // The kept terminal phase and its description.
  std::optional<std::pair<QString, QString>> result;
};

struct RowsModel {
  qint64 now = 0;
  std::map<QString, RowModel> rows;

  RowModel row(const QString& id) const {
    auto found = rows.find(id);
    return found == rows.end() ? RowModel{} : found->second;
  }
};

struct RowsSut {
  Rows rows;
  qint64 now = 0;
};

void check(const RowsModel& expected, const RowsSut& sut) {
  std::optional<qint64> next;
  for (const QString& id : kEnvironments) {
    const RowModel row = expected.row(id);
    const RowStatus status = sut.rows.status(codexGroup(id), QString());
    RowStatus want;
    if (!row.error.isEmpty()) want = {QStringLiteral("failed"), row.error};
    else if (row.result && row.result->first == QLatin1String("succeeded")) want = {QStringLiteral("success"), QStringLiteral("Updated")};
    else if (row.result) want = {row.result->first, row.result->second};
    else if (row.running) want = {QStringLiteral("loading"), QStringLiteral("Updating…")};
    else want = {QStringLiteral("idle"), QStringLiteral("Codex")};
    RC_ASSERT(status.kind == want.kind);
    RC_ASSERT(status.text == want.text);
    RC_ASSERT(sut.rows.running(id) == row.running);
    // Only a running row waits on a deadline.
    RC_ASSERT(row.deadline.has_value() == row.running);
    if (row.deadline && (!next || *row.deadline < *next)) next = row.deadline;
  }
  const std::optional<QDateTime> deadline = sut.rows.deadline();
  RC_ASSERT(deadline.has_value() == next.has_value());
  if (next) RC_ASSERT(*deadline == kEpoch.addMSecs(*next));
}

using RowsCommand = rc::state::Command<RowsModel, RowsSut>;

struct Start : RowsCommand {
  QString id = pick(kEnvironments);

  void apply(RowsModel& model) const override {
    RowModel& row = model.rows[id];
    if (row.running) return;
    ++row.version;
    row.running = true;
    row.deadline = model.now + Rows::kExpiryMs;
    row.error.clear();
    row.result.reset();
  }
  void run(const RowsModel& model, RowsSut& sut) const override {
    RowsModel expected = model;
    apply(expected);
    const std::optional<int> version = sut.rows.start(id, kEpoch.addMSecs(sut.now));
    if (model.row(id).running) RC_ASSERT(!version.has_value());
    else RC_ASSERT(version == std::optional<int>(expected.row(id).version));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Start(" << id.toStdString() << ")"; }
};

struct Settle : RowsCommand {
  QString id = pick(kEnvironments);
  // The current request, else a stale or never-made one.
  bool current = *rc::gen::arbitrary<bool>();
  int other = *rc::gen::inRange(1, 6);
  QString error = pick(kErrors);
  std::optional<QString> phase = maybe<QString>([] { return pick(kPhases); });

  int version(const RowsModel& model) const {
    const int now = model.row(id).version;
    return current ? now : (other == now ? now + 1 : other);
  }
  void checkPreconditions(const RowsModel& model) const override {
    if (current) RC_PRE(model.row(id).version > 0);
  }
  void apply(RowsModel& model) const override {
    auto found = model.rows.find(id);
    if (found == model.rows.end() || found->second.version != version(model)) return;
    RowModel& row = found->second;
    row.running = false;
    row.deadline.reset();
    row.error = error;
    row.result.reset();
    if (error.isEmpty() && phase && *phase != QLatin1String("running")) row.result = std::pair{*phase, QStringLiteral("said ") + *phase};
  }
  void run(const RowsModel& model, RowsSut& sut) const override {
    RowsModel expected = model;
    apply(expected);
    std::optional<View> view;
    if (phase) view = View{*phase, QStringLiteral("info"), *phase, QStringLiteral("said ") + *phase};
    sut.rows.settle(id, version(model), error, view);
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "Settle(" << id.toStdString() << (current ? ", current" : ", other ") << (current ? "" : std::to_string(other))
       << ", " << error.toStdString() << ", " << (phase ? phase->toStdString() : "-") << ")";
  }
};

struct Refuse : RowsCommand {
  QString id = pick(kEnvironments);
  QString error = pick(kErrors.mid(1));

  void apply(RowsModel& model) const override {
    RowModel& row = model.rows[id];
    if (row.running) return;
    row.error = error;
    row.result.reset();
  }
  void run(const RowsModel& model, RowsSut& sut) const override {
    RowsModel expected = model;
    apply(expected);
    sut.rows.refuse(id, error);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Refuse(" << id.toStdString() << ", " << error.toStdString() << ")"; }
};

struct AdvanceRows : RowsCommand {
  qint64 ms = *rc::gen::element<qint64>(1000, Rows::kExpiryMs / 2, Rows::kExpiryMs, Rows::kExpiryMs + 1);

  void apply(RowsModel& model) const override {
    model.now += ms;
    for (auto& [id, row] : model.rows) {
      if (!row.deadline || *row.deadline > model.now) continue;
      row.deadline.reset();
      row.running = false;
      row.error = kTimedOut;
    }
  }
  void run(const RowsModel& model, RowsSut& sut) const override {
    RowsModel expected = model;
    apply(expected);
    sut.now += ms;
    bool timedOut = false;
    for (const auto& [id, row] : model.rows) timedOut = timedOut || (row.deadline && *row.deadline <= expected.now);
    RC_ASSERT(sut.rows.expire(kEpoch.addMSecs(sut.now)) == timedOut);
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Advance(" << ms << ")"; }
};

// ---- Sidebar ----

const QStringList kDrivers{QStringLiteral("codex"), QStringLiteral("claudeAgent")};
const QStringList kStatuses{QString(), QStringLiteral("running"), QStringLiteral("succeeded"), QStringLiteral("failed"),
                            QStringLiteral("unchanged")};
const QStringList kFinished{QStringLiteral("2026-09-23T08:00:00.000Z"), QStringLiteral("2026-09-23T09:30:00.000Z"),
                            QStringLiteral("2026-09-23T10:00:00.000Z")};
const QStringList kChecked{QStringLiteral("2026-09-23T09:00:00.000Z"), QStringLiteral("2026-09-23T09:15:00.000Z")};
const QStringList kMessages{QString(), QStringLiteral("boom")};

struct ProviderSpec {
  QString status;
  QString finishedAt;
  QString checkedAt;
  QString message;
};

QJsonArray providers(const std::map<QString, ProviderSpec>& specs) {
  QJsonArray list;
  for (const auto& [driver, spec] : specs) {
    QJsonObject state;
    if (!spec.status.isEmpty()) state.insert(QStringLiteral("status"), spec.status);
    if (!spec.status.isEmpty() && spec.status != QLatin1String("running")) state.insert(QStringLiteral("finishedAt"), spec.finishedAt);
    if (!spec.message.isEmpty()) state.insert(QStringLiteral("message"), spec.message);
    list.append(QJsonObject{{QStringLiteral("instanceId"), driver},
                            {QStringLiteral("driver"), driver},
                            {QStringLiteral("enabled"), true},
                            {QStringLiteral("checkedAt"), spec.checkedAt},
                            {QStringLiteral("updateState"), state}});
  }
  return list;
}

struct SidebarModel {
  qint64 now = 0;
  std::map<QString, ProviderSpec> specs;
  std::optional<QString> visibleAfter;
  QSet<QString> dismissed;
  std::optional<Notice> notice;
  std::optional<qint64> deadline;

  // Sidebar::refresh: a new notice starts its own time, the same one keeps it.
  void refresh() {
    const std::optional<Notice> next = providerUpdates::notice(providers(specs), visibleAfter.value_or(QString()), dismissed);
    const bool same = next.has_value() == notice.has_value() && (!next || next->key == notice->key);
    if (!same) {
      deadline.reset();
      if (next && next->dismissAfterMs > 0) deadline = now + next->dismissAfterMs;
    }
    notice = next;
  }
};

struct SidebarSut {
  Sidebar sidebar;
  qint64 now = 0;
};

void check(const SidebarModel& expected, const SidebarSut& sut) {
  const std::optional<Notice>& notice = sut.sidebar.current();
  RC_ASSERT(notice.has_value() == expected.notice.has_value());
  if (notice) {
    RC_ASSERT(notice->key == expected.notice->key);
    RC_ASSERT(notice->title == expected.notice->title);
    RC_ASSERT(notice->description == expected.notice->description);
    // Gone once dismissed or timed out, until its key changes.
    RC_ASSERT(!expected.dismissed.contains(notice->key));
  }
  const std::optional<QDateTime> deadline = sut.sidebar.deadline();
  RC_ASSERT(deadline.has_value() == expected.deadline.has_value());
  if (deadline) {
    RC_ASSERT(*deadline == kEpoch.addMSecs(*expected.deadline));
    RC_ASSERT(notice && notice->tone == QLatin1String("success"));
  }
}

using SidebarCommand = rc::state::Command<SidebarModel, SidebarSut>;

struct SetProvider : SidebarCommand {
  QString driver = pick(kDrivers);
  // Absent: the provider goes away.
  std::optional<ProviderSpec> spec = maybe<ProviderSpec>([] {
    return ProviderSpec{pick(kStatuses), pick(kFinished), pick(kChecked), pick(kMessages)};
  });

  void apply(SidebarModel& model) const override {
    if (spec) model.specs[driver] = *spec;
    else model.specs.erase(driver);
    const QJsonArray list = providers(model.specs);
    if (!model.visibleAfter && !list.isEmpty()) model.visibleAfter = latestCheckedAt(list);
    model.refresh();
  }
  void run(const SidebarModel& model, SidebarSut& sut) const override {
    SidebarModel expected = model;
    apply(expected);
    sut.sidebar.setProviders(providers(expected.specs), kEpoch.addMSecs(sut.now));
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "SetProvider(" << driver.toStdString();
    if (spec) os << ", " << spec->status.toStdString() << " " << spec->finishedAt.toStdString() << " " << spec->checkedAt.toStdString() << " " << spec->message.toStdString();
    os << ")";
  }
};

struct Dismiss : SidebarCommand {
  void apply(SidebarModel& model) const override {
    if (!model.notice || !model.notice->dismissible) return;
    model.dismissed.insert(model.notice->key);
    model.refresh();
  }
  void run(const SidebarModel& model, SidebarSut& sut) const override {
    SidebarModel expected = model;
    apply(expected);
    sut.sidebar.dismiss(kEpoch.addMSecs(sut.now));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Dismiss"; }
};

struct AdvanceSidebar : SidebarCommand {
  qint64 ms = *rc::gen::element<qint64>(1000, 2999, 3000, 60000);

  void apply(SidebarModel& model) const override {
    model.now += ms;
    if (!model.deadline || *model.deadline > model.now || !model.notice) return;
    model.dismissed.insert(model.notice->key);
    model.refresh();
  }
  void run(const SidebarModel& model, SidebarSut& sut) const override {
    SidebarModel expected = model;
    apply(expected);
    sut.now += ms;
    sut.sidebar.expire(kEpoch.addMSecs(sut.now));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Advance(" << ms << ")"; }
};

}  // namespace

class ProviderUpdateRowsProp : public QObject {
  Q_OBJECT

private slots:
  void rows() {
    QVERIFY(rc::check("each environment's row says how its latest update went", [] {
      RowsSut sut;
      rc::state::check(RowsModel{}, sut, rc::state::gen::execOneOfWithArgs<Start, Start, Settle, Settle, Refuse, AdvanceRows>());
    }));
  }

  void sidebar() {
    QVERIFY(rc::check("the sidebar notice never returns once dismissed or timed out", [] {
      SidebarSut sut;
      rc::state::check(SidebarModel{}, sut,
                       rc::state::gen::execOneOfWithArgs<SetProvider, SetProvider, SetProvider, Dismiss, AdvanceSidebar>());
    }));
  }
};

HAL_C2_PROP_MAIN(ProviderUpdateRowsProp)
#include "tst_ProviderUpdateRowsProp.moc"
