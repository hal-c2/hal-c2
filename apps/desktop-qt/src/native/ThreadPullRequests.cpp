#include "ThreadPullRequests.h"
#include "TimelineModel.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>

#include <algorithm>

#include "McClient.h"
#include "PullRequestLinks.h"
#include "ShellStore.h"

namespace {

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QString keyOf(const QJsonObject& link) {
  return QStringLiteral("%1/%2#%3")
      .arg(text(link, QLatin1String("host")).toLower(), text(link, QLatin1String("repository")).toLower())
      .arg(link.value(QLatin1String("number")).toInteger());
}

QJsonObject snapshotOf(const QJsonObject& link) {
  return link.value(QLatin1String("snapshot")).toObject();
}

// ThreadPullRequestsPanel's SOURCE_LABELS.
QString sourceLabelOf(const QString& source) {
  if (source == QLatin1String("manual")) return QStringLiteral("Linked by you");
  if (source == QLatin1String("created")) return QStringLiteral("Created from this thread");
  if (source == QLatin1String("agent")) return QStringLiteral("Linked by the agent");
  if (source == QLatin1String("stack")) return QStringLiteral("Found in the stack");
  if (source == QLatin1String("stack-dismissed")) return QStringLiteral("Dismissed");
  return {};
}

// A stack of a thread's links, bottom to top: the host's own, or links whose
// base branch is another's head.
struct Chain {
  bool native = false;
  QList<QJsonObject> layers;
};

QString repositoryKeyOf(const QJsonObject& link) {
  return text(link, QLatin1String("host")).toLower() + QLatin1Char('/') + text(link, QLatin1String("repository")).toLower();
}

// packages/shared threadPullRequests.ts resolveThreadPullRequestChains: the
// host's stacks win; the rest chain by matching one link's base branch to
// another's head in the same repository. A head several links share names no
// parent, and links in a cycle stand alone.
QList<Chain> chainsOf(const QList<QJsonObject>& links) {
  QList<Chain> chains;
  QSet<QString> placed;
  QStringList stackOrder;
  QHash<QString, QList<QJsonObject>> stacks;
  for (const QJsonObject& link : links) {
    const QJsonObject stack = link.value(QLatin1String("stack")).toObject();
    if (stack.isEmpty()) continue;
    const QString key = repositoryKeyOf(link) + QStringLiteral("#stack:") + stack.value(QLatin1String("id")).toVariant().toString();
    if (!stacks.contains(key)) stackOrder.append(key);
    stacks[key].append(link);
  }
  for (const QString& key : std::as_const(stackOrder)) {
    QList<QJsonObject> members = stacks.value(key);
    QHash<int, int> position;
    const QJsonArray layers = members.first().value(QLatin1String("stack")).toObject().value(QLatin1String("layers")).toArray();
    for (qsizetype at = 0; at < layers.size(); ++at) position.insert(layers.at(at).toObject().value(QLatin1String("number")).toInt(), int(at));
    std::stable_sort(members.begin(), members.end(), [&](const QJsonObject& a, const QJsonObject& b) {
      return position.value(a.value(QLatin1String("number")).toInt()) < position.value(b.value(QLatin1String("number")).toInt());
    });
    for (const QJsonObject& member : std::as_const(members)) placed.insert(keyOf(member));
    chains.append({true, members});
  }
  QList<QJsonObject> remaining;
  for (const QJsonObject& link : links) {
    if (!placed.contains(keyOf(link))) remaining.append(link);
  }
  const auto branchKey = [](const QJsonObject& link, QLatin1StringView field) {
    return repositoryKeyOf(link) + QLatin1Char(':') + text(snapshotOf(link), field);
  };
  // The link whose head each branch is, or -1 when several are.
  QHash<QString, int> byHead;
  for (qsizetype at = 0; at < remaining.size(); ++at) {
    if (!remaining.at(at).value(QLatin1String("snapshot")).isObject()) continue;
    const QString key = branchKey(remaining.at(at), QLatin1String("headBranch"));
    byHead.insert(key, byHead.contains(key) ? -1 : int(at));
  }
  const auto parentOf = [&](qsizetype at) {
    if (!remaining.at(at).value(QLatin1String("snapshot")).isObject()) return -1;
    return byHead.value(branchKey(remaining.at(at), QLatin1String("baseBranch")), -1);
  };
  QSet<int> hasChild;
  for (qsizetype at = 0; at < remaining.size(); ++at) {
    const int parent = parentOf(at);
    if (parent >= 0 && parent != at) hasChild.insert(parent);
  }
  // Walk from each top (a link nothing builds on) down its base chain.
  for (qsizetype top = 0; top < remaining.size(); ++top) {
    if (hasChild.contains(int(top))) continue;
    QList<QJsonObject> layers;
    for (int cursor = int(top); cursor >= 0 && !placed.contains(keyOf(remaining.at(cursor))); cursor = parentOf(cursor)) {
      placed.insert(keyOf(remaining.at(cursor)));
      layers.prepend(remaining.at(cursor));
    }
    if (!layers.isEmpty()) chains.append({false, layers});
  }
  for (const QJsonObject& link : std::as_const(remaining)) {
    if (!placed.contains(keyOf(link))) chains.append({false, {link}});
  }
  return chains;
}

qint64 activityAt(const QJsonObject& link) {
  const QString updated = text(snapshotOf(link), QLatin1String("updatedAt"));
  const QDateTime at = QDateTime::fromString(updated.isEmpty() ? text(link, QLatin1String("linkedAt")) : updated, Qt::ISODate);
  return at.isValid() ? at.toMSecsSinceEpoch() : 0;
}

qint64 latestActivity(const Chain& chain) {
  qint64 latest = 0;
  for (const QJsonObject& layer : chain.layers) latest = std::max(latest, activityAt(layer));
  return latest;
}

}  // namespace

ThreadPullRequests::ThreadPullRequests(McClient* client, ShellStore* store, Notify notify, Open open, QObject* parent)
    : QAbstractListModel(parent), m_client(client), m_store(store), m_notify(std::move(notify)), m_open(std::move(open)) {}

bool ThreadPullRequests::available() const {
  if (m_thread.isEmpty() || m_store->environment(environmentId()).isEmpty()) return true;
  return m_store->supports(environmentId(), QStringLiteral("threadPullRequests"));
}

QString ThreadPullRequests::notice() const {
  if (m_thread.isEmpty() || m_store->environment(environmentId()).isEmpty()) return {};
  return m_store->supports(environmentId(), QStringLiteral("threadPullRequests"))
             ? QString()
             : tr("Update this environment's server to see branch pull requests.");
}

void ThreadPullRequests::setThread(const QString& threadKey) {
  if (threadKey != m_thread) {
    m_thread = threadKey;
    m_project.clear();
    m_projectThread.clear();
    m_projectProblem.clear();
    emit projectChanged();
    m_problem.clear();
    m_reference.clear();
    m_dirty = false;
    m_linkOpen = false;
    emit stateChanged();
  }
  QList<QJsonObject> visible;
  QList<QJsonObject> dismissed;
  for (const QJsonValue& value : m_store->threadRow(threadKey).value(QLatin1String("pullRequests")).toArray()) {
    const QJsonObject link = value.toObject();
    (text(link, QLatin1String("source")) == QLatin1String("stack-dismissed") ? dismissed : visible).append(link);
  }
  const bool online = m_store->environmentOnline(environmentId());
  if (online != m_online) {
    m_online = online;
    emit stateChanged();
  }
  // pullRequestListLines: a stack sorts by its most recent layer and reads
  // bottom to top beneath that slot.
  QList<Chain> chains = chainsOf(visible);
  std::stable_sort(chains.begin(), chains.end(), [](const Chain& a, const Chain& b) { return latestActivity(a) > latestActivity(b); });
  QList<QJsonObject> links;
  QList<Line> lines;
  for (const Chain& chain : std::as_const(chains)) {
    for (qsizetype depth = 0; depth < chain.layers.size(); ++depth) {
      links.append(chain.layers.at(depth));
      lines.append({int(depth), depth == 0 && chain.layers.size() > 1 ? int(chain.layers.size()) : 0, chain.native});
    }
  }
  if (links == m_links && dismissed == m_dismissed) return;
  m_dismissed = dismissed;
  if (links == m_links) {
    emit rowsChanged();
    return;
  }
  const bool sameRows = links.size() == m_links.size() &&
                        std::equal(links.cbegin(), links.cend(), m_links.cbegin(),
                                   [](const QJsonObject& a, const QJsonObject& b) { return keyOf(a) == keyOf(b); });
  if (sameRows) {
    // The same pull requests, newly synced: rows change in place.
    m_links = links;
    m_lines = lines;
    emit dataChanged(index(0), index(int(m_links.size()) - 1));
  } else {
    beginResetModel();
    m_links = links;
    m_lines = lines;
    endResetModel();
    emit countChanged();
    // A linked one leaves the project's list, an unlinked one returns to it.
    emit projectChanged();
  }
  emit rowsChanged();
}

int ThreadPullRequests::openCount() const {
  return int(std::count_if(m_links.cbegin(), m_links.cend(), [](const QJsonObject& link) {
    return !link.value(QLatin1String("snapshot")).isObject() || text(snapshotOf(link), QLatin1String("state")) == QLatin1String("open");
  }));
}

void ThreadPullRequests::setLinkOpen(bool open) {
  if (open == m_linkOpen && (open || (m_problem.isEmpty() && !m_dirty))) return;
  m_linkOpen = open;
  m_problem.clear();
  m_reference.clear();
  m_dirty = false;
  emit stateChanged();
}

// LinkPullRequestDialog: what the reference says once the user typed, ahead of
// why the last link failed.
QString ThreadPullRequests::problem() const {
  if (m_dirty) {
    const auto resolved = resolve(m_reference);
    if (const QString* problem = std::get_if<QString>(&resolved)) return *problem;
  }
  return m_problem;
}

void ThreadPullRequests::setReference(const QString& reference) {
  if (reference == m_reference && m_dirty) return;
  m_reference = reference;
  m_dirty = true;
  emit stateChanged();
}

bool ThreadPullRequests::canLink() const {
  return !m_thread.isEmpty() && m_online && !m_linking && std::holds_alternative<Target>(resolve(m_reference));
}

QString ThreadPullRequests::preview() const {
  const auto resolved = resolve(m_reference);
  const Target* target = std::get_if<Target>(&resolved);
  return target ? QStringLiteral("%1/%2 #%3").arg(target->host, target->repository).arg(target->number) : QString();
}

QVariantList ThreadPullRequests::dismissed() const {
  QVariantList dismissed;
  for (const QJsonObject& link : m_dismissed) {
    dismissed.append(QVariantMap{{QStringLiteral("key"), keyOf(link)},
                                 {QStringLiteral("number"), link.value(QLatin1String("number")).toInt()},
                                 {QStringLiteral("repository"), text(link, QLatin1String("repository"))},
                                 {QStringLiteral("title"), text(snapshotOf(link), QLatin1String("title"))},
                                 {QStringLiteral("url"), text(link, QLatin1String("url"))},
                                 {QStringLiteral("sourceLabel"), sourceLabelOf(text(link, QLatin1String("source")))}});
  }
  return dismissed;
}

QString ThreadPullRequests::syncedLabel() const {
  QString latest;
  for (const QJsonObject& link : m_links) latest = std::max(latest, text(snapshotOf(link), QLatin1String("syncedAt")));
  return latest.isEmpty() ? QString() : QStringLiteral("synced %1").arg(ago(latest));
}

// formatRelativeTimeLabel: "just now", then minutes, hours and days ago (relativeTime).
QString ThreadPullRequests::ago(const QString& iso) const {
  const QDateTime at = QDateTime::fromString(iso, Qt::ISODate);
  if (!at.isValid()) return {};
  const QDateTime now = m_now();
  // A time ahead of the clock (its skew) still reads "just now".
  return relativeTime(std::min(at, now), now);
}

int ThreadPullRequests::indexOf(const QString& key) const {
  for (qsizetype row = 0; row < m_links.size(); ++row) {
    if (keyOf(m_links.at(row)) == key) return int(row);
  }
  return -1;
}

QString ThreadPullRequests::urlOf(const QString& key) const {
  if (const QJsonObject* link = find(key)) return text(*link, QLatin1String("url"));
  for (const QJsonObject& link : m_dismissed) {
    if (keyOf(link) == key) return text(link, QLatin1String("url"));
  }
  for (const QJsonObject& entry : m_project) {
    if (QStringLiteral("%1/%2#%3").arg(text(entry, QLatin1String("host")), text(entry, QLatin1String("repository"))).arg(entry.value(QLatin1String("number")).toInt()) == key) {
      return text(entry, QLatin1String("url"));
    }
  }
  const qsizetype slash = key.indexOf(QLatin1Char('/'));
  const qsizetype hash = key.lastIndexOf(QLatin1Char('#'));
  if (slash <= 0 || hash <= slash) return {};
  return PullRequestLinks::pageOf(key.left(slash), key.mid(slash + 1, hash - slash - 1), key.mid(hash + 1).toInt());
}

const QJsonObject* ThreadPullRequests::find(const QString& key) const {
  const int row = indexOf(key);
  return row < 0 ? nullptr : &m_links.at(row);
}

// --- Naming a pull request -------------------------------------------------------------

// The host, repository and number behind a pull request URL (PullRequestLinks::parse).
std::optional<ThreadPullRequests::Target> ThreadPullRequests::parseUrl(const QString& url) {
  const std::optional<PullRequestLink> link = PullRequestLinks::parse(url);
  if (!link) return std::nullopt;
  return Target{link->host, link->repository, link->number, link->url};
}

// A URL may name any repository on a host
// a project here reads, since that project lends the MC its credentials
// there (findProjectOnChangeRequestHost); Azure DevOps reads with the
// checkout's own organization and project, so there it takes a project of that
// repository. A bare number means the thread's own repository.
std::variant<ThreadPullRequests::Target, QString> ThreadPullRequests::resolve(const QString& input) const {
  const QString trimmed = input.trimmed();
  if (trimmed.isEmpty()) return QStringLiteral("Paste a pull request URL or enter 123 / #123.");
  const QList<QJsonObject> projects = m_store->projectRows(environmentId());
  if (const std::optional<Target> target = parseUrl(trimmed)) {
    const bool readable = !PullRequestLinks::projectFor(projects, PullRequestLink{{}, target->host, target->repository, target->number, target->url}, true).isEmpty();
    if (!readable) return QStringLiteral("No project in this environment can read %1/%2.").arg(target->host, target->repository);
    return *target;
  }
  static const QRegularExpression bare(QStringLiteral("^#?([0-9]+)$"));
  const QRegularExpressionMatch number = bare.match(trimmed);
  if (!number.hasMatch() || number.captured(1).toInt() <= 0) return QStringLiteral("Use a pull request URL, 123, or #123.");
  const QJsonObject row = m_store->threadRow(m_thread);
  const auto [host, repository] = PullRequestLinks::repositoryOf(m_store->projectRow(environmentId(), text(row, QLatin1String("projectId"))));
  if (host.isEmpty() || repository.isEmpty()) return QStringLiteral("Paste a full URL to link a pull request from another repository.");
  const int value = number.captured(1).toInt();
  const QString page = PullRequestLinks::pageOf(host, repository, value);
  if (page.isEmpty()) return QStringLiteral("Paste a full URL; this project's host has no known pull request URL.");
  return Target{host, repository, value, page};
}

// --- Actions ---------------------------------------------------------------------------

void ThreadPullRequests::link(const QString& input) {
  if (m_thread.isEmpty() || m_linking || !m_online) return;
  m_reference = input;
  m_dirty = true;
  const auto resolved = resolve(input);
  if (std::holds_alternative<QString>(resolved)) {
    emit stateChanged();
    return;
  }
  const Target target = std::get<Target>(resolved);
  m_linking = true;
  m_problem.clear();
  emit stateChanged();
  const QString thread = m_thread;
  m_client->dispatchCommand(this, environmentId(),
                            {{QStringLiteral("type"), QStringLiteral("thread.pull-request.link")},
                             {QStringLiteral("threadId"), threadId()},
                             {QStringLiteral("host"), target.host},
                             {QStringLiteral("repository"), target.repository},
                             {QStringLiteral("number"), target.number},
                             {QStringLiteral("url"), target.url},
                             {QStringLiteral("source"), QStringLiteral("manual")}},
                            [this, thread](const QJsonValue&, const std::optional<QString>& error) {
                              if (thread != m_thread) return;
                              m_linking = false;
                              if (error) {
                                m_problem = QStringLiteral("Could not link the pull request: %1").arg(*error);
                              } else {
                                m_linkOpen = false;
                                m_reference.clear();
                                m_dirty = false;
                              }
                              emit stateChanged();
                            });
}

void ThreadPullRequests::unlink(const QString& key) {
  const QJsonObject* link = find(key);
  if (!link || !m_online) return;
  const int number = link->value(QLatin1String("number")).toInt();
  m_client->dispatchCommand(this, environmentId(),
                            {{QStringLiteral("type"), QStringLiteral("thread.pull-request.unlink")},
                             {QStringLiteral("threadId"), threadId()},
                             {QStringLiteral("host"), link->value(QLatin1String("host"))},
                             {QStringLiteral("repository"), link->value(QLatin1String("repository"))},
                             {QStringLiteral("number"), number}},
                            [notify = m_notify](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) notify(QStringLiteral("error"), QStringLiteral("Could not unlink the pull request"), *error);
                            });
}

QVariantList ThreadPullRequests::projectOpen() const {
  QVariantList open;
  for (const QJsonObject& entry : m_project) {
    const QString key = QStringLiteral("%1/%2#%3").arg(text(entry, QLatin1String("host")), text(entry, QLatin1String("repository"))).arg(entry.value(QLatin1String("number")).toInt());
    // The linked ones are the rows above.
    if (find(key)) continue;
    open.append(QVariantMap{{QStringLiteral("key"), key},
                            {QStringLiteral("number"), entry.value(QLatin1String("number")).toInt()},
                            {QStringLiteral("title"), text(entry, QLatin1String("title"))},
                            {QStringLiteral("author"), text(entry.value(QLatin1String("author")).toObject(), QLatin1String("login"))},
                            {QStringLiteral("branches"), QStringLiteral("%1 → %2").arg(text(entry, QLatin1String("headBranch")), text(entry, QLatin1String("baseBranch")))},
                            {QStringLiteral("draft"), entry.value(QLatin1String("isDraft")).toBool()},
                            {QStringLiteral("url"), text(entry, QLatin1String("url"))}});
  }
  return open;
}

void ThreadPullRequests::loadProject(bool again) {
  if (m_thread.isEmpty() || !m_online || (!again && m_projectThread == m_thread)) return;
  const QString thread = m_thread;
  m_projectThread = thread;
  const QString projectId = m_store->threadRow(thread).value(QLatin1String("projectId")).toString();
  m_client->call(this, environmentId(), QStringLiteral("pullRequests.list"),
                 QJsonObject{{QStringLiteral("state"), QStringLiteral("open")}, {QStringLiteral("involvement"), QStringLiteral("all")},
                             {QStringLiteral("projectId"), projectId}, {QStringLiteral("limit"), 50}},
                 [this, thread](const QJsonValue& result, const std::optional<QString>& error) {
                   if (thread != m_thread) return;
                   m_project.clear();
                   m_projectProblem = error.value_or(QString());
                   // A read that failed is tried again the next time the tab asks.
                   if (error) m_projectThread.clear();
                   for (const QJsonValue& entry : result.toObject().value(QLatin1String("entries")).toArray()) m_project.append(entry.toObject());
                   emit projectChanged();
                 });
}

void ThreadPullRequests::refresh() {
  loadProject(true);
  if (m_links.isEmpty() || m_refreshing > 0 || !m_online) return;
  m_refreshing = int(m_links.size());
  emit stateChanged();
  const QString thread = m_thread;
  // One failure is told once, however many pull requests it stopped.
  auto failed = std::make_shared<bool>(false);
  for (const QJsonObject& link : std::as_const(m_links)) {
    const QJsonObject reference{{QStringLiteral("host"), link.value(QLatin1String("host"))},
                                {QStringLiteral("repository"), link.value(QLatin1String("repository"))},
                                {QStringLiteral("number"), link.value(QLatin1String("number"))}};
    m_client->call(this, environmentId(), QStringLiteral("pullRequests.invalidate"), QJsonObject{{QStringLiteral("reference"), reference}},
                   [this, thread, failed](const QJsonValue&, const std::optional<QString>& error) {
                     if (error && !*failed) {
                       *failed = true;
                       m_notify(QStringLiteral("error"), QStringLiteral("Could not refresh pull requests"), *error);
                     }
                     if (thread != m_thread || m_refreshing == 0) return;
                     if (--m_refreshing == 0) emit stateChanged();
                   });
  }
}

void ThreadPullRequests::open(const QString& key) {
  if (const QJsonObject* link = find(key)) m_open(QUrl(text(*link, QLatin1String("url"))));
}

void ThreadPullRequests::copyLink(const QString& key) {
  const QJsonObject* link = find(key);
  if (!link) return;
  const QString url = text(*link, QLatin1String("url"));
  if (m_copy) {
    m_copy(url);
  } else if (QClipboard* clipboard = QGuiApplication::clipboard()) {
    clipboard->setText(url);
  }
}

// --- Rows ------------------------------------------------------------------------------

int ThreadPullRequests::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_links.size());
}

QVariant ThreadPullRequests::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_links.size()) return {};
  const QJsonObject& link = m_links.at(index.row());
  const QJsonObject snapshot = snapshotOf(link);
  const bool synced = link.value(QLatin1String("snapshot")).isObject();
  const QString state = !synced ? QStringLiteral("unknown")
                        : snapshot.value(QLatin1String("isDraft")).toBool() && text(snapshot, QLatin1String("state")) == QLatin1String("open")
                            ? QStringLiteral("draft")
                            : text(snapshot, QLatin1String("state"));
  switch (role) {
    case KeyRole:
      return keyOf(link);
    case HostRole:
      return text(link, QLatin1String("host"));
    case RepositoryRole:
      return text(link, QLatin1String("repository"));
    case NumberRole:
      return link.value(QLatin1String("number")).toInt();
    case UrlRole:
      return text(link, QLatin1String("url"));
    case TitleRole:
      return text(snapshot, QLatin1String("title"));
    case StateRole:
      return state;
    case StateLabelRole:
      if (state == QLatin1String("unknown")) return QStringLiteral("Waiting for host state");
      return state.isEmpty() ? QString() : state.left(1).toUpper() + state.mid(1);
    case ChecksRole:
      return text(snapshot, QLatin1String("checksState"));
    case ChecksLabelRole: {
      const QString checks = text(snapshot, QLatin1String("checksState"));
      if (checks == QLatin1String("passing")) return QStringLiteral("Checks passing");
      if (checks == QLatin1String("failing")) return QStringLiteral("Checks failing");
      if (checks == QLatin1String("pending")) return QStringLiteral("Checks running");
      return QString();
    }
    case ReviewRole:
      return text(snapshot, QLatin1String("reviewDecision"));
    case ReviewLabelRole: {
      const QString review = text(snapshot, QLatin1String("reviewDecision"));
      if (review == QLatin1String("approved")) return QStringLiteral("Approved");
      if (review == QLatin1String("changes-requested")) return QStringLiteral("Changes requested");
      if (review == QLatin1String("review-required")) return QStringLiteral("Review required");
      return QString();
    }
    case ConflictingRole:
      return text(snapshot, QLatin1String("mergeability")) == QLatin1String("conflicting");
    case AdditionsRole:
      return snapshot.value(QLatin1String("additions")).toInt(-1);
    case DeletionsRole:
      return snapshot.value(QLatin1String("deletions")).toInt(-1);
    case AuthorRole:
      return text(snapshot, QLatin1String("author"));
    case BranchesRole: {
      const QString head = text(snapshot, QLatin1String("headBranch"));
      const QString base = text(snapshot, QLatin1String("baseBranch"));
      return head.isEmpty() || base.isEmpty() ? QString() : head + QStringLiteral(" → ") + base;
    }
    case SourceRole:
      return text(link, QLatin1String("source"));
    case SourceLabelRole:
      return sourceLabelOf(text(link, QLatin1String("source")));
    case LinkedNoteRole: {
      const QString when = ago(text(link, QLatin1String("linkedAt")));
      const QString how = sourceLabelOf(text(link, QLatin1String("source")));
      return when.isEmpty() ? how : how + QStringLiteral(" · ") + when;
    }
    case DepthRole:
      return m_lines.value(index.row()).depth;
    case StackSizeRole:
      return m_lines.value(index.row()).stackSize;
    case StackNoteRole: {
      const Line line = m_lines.value(index.row());
      if (line.stackSize == 0) return QString();
      return line.native ? QStringLiteral("GitHub stack of %1: merging a layer lands the ones below it.").arg(line.stackSize)
                         : QStringLiteral("%1 pull requests chained by base branch.").arg(line.stackSize);
    }
    case StackLabelRole: {
      const QJsonArray layers = link.value(QLatin1String("stack")).toObject().value(QLatin1String("layers")).toArray();
      for (qsizetype layer = 0; layer < layers.size(); ++layer) {
        if (layers.at(layer).toObject().value(QLatin1String("number")).toInt() == link.value(QLatin1String("number")).toInt()) {
          return QStringLiteral("Layer %1 of %2").arg(layer + 1).arg(layers.size());
        }
      }
      return QString();
    }
    case UnlinkLabelRole:
      return text(link, QLatin1String("source")) == QLatin1String("stack") ? QStringLiteral("Dismiss from thread")
                                                                             : QStringLiteral("Unlink from thread");
    default:
      return {};
  }
}

QHash<int, QByteArray> ThreadPullRequests::roleNames() const {
  return {
      {KeyRole, "linkKey"},
      {HostRole, "host"},
      {RepositoryRole, "repository"},
      {NumberRole, "number"},
      {UrlRole, "url"},
      {TitleRole, "title"},
      {StateRole, "state"},
      {StateLabelRole, "stateLabel"},
      {ChecksRole, "checks"},
      {ChecksLabelRole, "checksLabel"},
      {ReviewRole, "review"},
      {ReviewLabelRole, "reviewLabel"},
      {ConflictingRole, "conflicting"},
      {AdditionsRole, "additions"},
      {DeletionsRole, "deletions"},
      {AuthorRole, "author"},
      {BranchesRole, "branches"},
      {SourceRole, "source"},
      {SourceLabelRole, "sourceLabel"},
      {UnlinkLabelRole, "unlinkLabel"},
      {StackLabelRole, "stackLabel"},
      {LinkedNoteRole, "linkedNote"},
      {DepthRole, "depth"},
      {StackSizeRole, "stackSize"},
      {StackNoteRole, "stackNote"},
  };
}
