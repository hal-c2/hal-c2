#include "ThreadPullRequests.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QUrl>

#include "NodeClient.h"
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

bool hostOf(const QString& host, const QString& apex, const QString& label) {
  return host == apex || host.endsWith(QLatin1Char('.') + apex) ||
         (!label.isEmpty() && host.split(QLatin1Char('.')).contains(label));
}

// A repository's pull request page, as the node builds it
// (mcp/tools/pull_requests.ex url/4) from the host alone.
QString pageOf(const QString& host, const QString& repository, int number) {
  if (hostOf(host, QStringLiteral("gitlab.com"), QStringLiteral("gitlab"))) {
    return QStringLiteral("https://%1/%2/-/merge_requests/%3").arg(host, repository).arg(number);
  }
  if (hostOf(host, QStringLiteral("bitbucket.org"), QStringLiteral("bitbucket"))) {
    return QStringLiteral("https://%1/%2/pull-requests/%3").arg(host, repository).arg(number);
  }
  if (hostOf(host, QStringLiteral("dev.azure.com"), {}) || host.endsWith(QLatin1String(".visualstudio.com"))) {
    return QStringLiteral("https://%1/%2/pullrequest/%3").arg(host, repository).arg(number);
  }
  return QStringLiteral("https://%1/%2/pull/%3").arg(host, repository).arg(number);
}

// The host a project's checkout reads ("github.com/acme/shop" gives github.com),
// and its repository.
std::pair<QString, QString> repositoryOf(const QJsonObject& project) {
  const QString key = project.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString().toLower();
  const qsizetype slash = key.indexOf(QLatin1Char('/'));
  if (slash <= 0) return {};
  return {key.left(slash), key.mid(slash + 1)};
}

// One name for an Azure DevOps repository however it is reached, over SSH,
// visualstudio.com or dev.azure.com (canonicalRepositoryKey in
// packages/shared/src/sourceControl.ts).
QString canonicalKey(QString key) {
  static const QRegularExpression ssh(
      QStringLiteral("^(?:ssh\\.dev\\.azure\\.com|vs-ssh\\.visualstudio\\.com)/v3/([^/]+)/([^/]+)/([^/]+)$"));
  static const QRegularExpression legacy(QStringLiteral("^([^.]+)\\.visualstudio\\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)$"));
  key.replace(ssh, QStringLiteral("dev.azure.com/\\1/\\2/_git/\\3"));
  key.replace(legacy, QStringLiteral("dev.azure.com/\\1/\\2/_git/\\3"));
  return key;
}

}  // namespace

ThreadPullRequests::ThreadPullRequests(NodeClient* client, ShellStore* store, Notify notify, Open open, QObject* parent)
    : QAbstractListModel(parent), m_client(client), m_store(store), m_notify(std::move(notify)), m_open(std::move(open)) {}

void ThreadPullRequests::setThread(const QString& threadKey) {
  if (threadKey != m_thread) {
    m_thread = threadKey;
    m_problem.clear();
    m_linkOpen = false;
    emit stateChanged();
  }
  QList<QJsonObject> links;
  for (const QJsonValue& value : m_store->threadRow(threadKey).value(QLatin1String("pullRequests")).toArray()) {
    const QJsonObject link = value.toObject();
    if (text(link, QLatin1String("source")) != QLatin1String("stack-dismissed")) links.append(link);
  }
  const bool online = m_store->environmentOnline(environmentId());
  if (online != m_online) {
    m_online = online;
    emit stateChanged();
  }
  if (links == m_links) return;
  const bool sameRows = links.size() == m_links.size() &&
                        std::equal(links.cbegin(), links.cend(), m_links.cbegin(),
                                   [](const QJsonObject& a, const QJsonObject& b) { return keyOf(a) == keyOf(b); });
  if (sameRows) {
    // The same pull requests, newly synced: rows change in place.
    m_links = links;
    emit dataChanged(index(0), index(int(m_links.size()) - 1));
  } else {
    beginResetModel();
    m_links = links;
    endResetModel();
    emit countChanged();
  }
  emit rowsChanged();
}

int ThreadPullRequests::openCount() const {
  return int(std::count_if(m_links.cbegin(), m_links.cend(), [](const QJsonObject& link) {
    return !link.value(QLatin1String("snapshot")).isObject() || text(snapshotOf(link), QLatin1String("state")) == QLatin1String("open");
  }));
}

void ThreadPullRequests::setLinkOpen(bool open) {
  if (open == m_linkOpen && (open || m_problem.isEmpty())) return;
  m_linkOpen = open;
  m_problem.clear();
  emit stateChanged();
}

void ThreadPullRequests::setProblem(const QString& problem) {
  if (problem == m_problem) return;
  m_problem = problem;
  emit stateChanged();
}

int ThreadPullRequests::indexOf(const QString& key) const {
  for (qsizetype row = 0; row < m_links.size(); ++row) {
    if (keyOf(m_links.at(row)) == key) return int(row);
  }
  return -1;
}

const QJsonObject* ThreadPullRequests::find(const QString& key) const {
  const int row = indexOf(key);
  return row < 0 ? nullptr : &m_links.at(row);
}

// --- Naming a pull request -------------------------------------------------------------

// The host, repository and number behind a pull request URL, as the node
// parses it (projection/pull_requests.ex parse_change_request_url/1).
std::optional<ThreadPullRequests::Target> ThreadPullRequests::parseUrl(const QString& url) {
  const QUrl parsed(url.trimmed(), QUrl::StrictMode);
  if (!parsed.isValid() || (parsed.scheme() != QLatin1String("http") && parsed.scheme() != QLatin1String("https")) ||
      parsed.host().isEmpty()) {
    return std::nullopt;
  }
  QString host = parsed.host().toLower();
  const QString path = parsed.path().isEmpty() ? QStringLiteral("/") : parsed.path();
  static const QRegularExpression github(QStringLiteral("^/([^/]+/[^/]+)/pull/([0-9]+)(?:/|$)"));
  static const QRegularExpression forgejo(QStringLiteral("^/([^/]+(?:/[^/]+)+)/pulls/([0-9]+)(?:/|$)"));
  static const QRegularExpression gitlab(QStringLiteral("^/([^/]+(?:/[^/]+)+)/-/merge_requests/([0-9]+)(?:/|$)"));
  static const QRegularExpression bitbucket(QStringLiteral("^/([^/]+/[^/]+)/pull-requests/([0-9]+)(?:/|$)"));
  static const QRegularExpression azure(QStringLiteral("^/((?:[^/]+/)*_git/[^/]+)/pullrequest/([0-9]+)(?:/|$)"));
  QRegularExpressionMatch match;
  if (hostOf(host, QStringLiteral("github.com"), QStringLiteral("github")) && (match = github.match(path)).hasMatch()) {
  } else if ((match = forgejo.match(path)).hasMatch()) {
    // Forgejo and Gitea keep a port that is not the scheme's.
    if (parsed.port() > 0 && parsed.port() != (parsed.scheme() == QLatin1String("https") ? 443 : 80)) {
      host += QStringLiteral(":%1").arg(parsed.port());
    }
  } else if ((match = gitlab.match(path)).hasMatch()) {
  } else if (hostOf(host, QStringLiteral("bitbucket.org"), QStringLiteral("bitbucket"))) {
    match = bitbucket.match(path);
  } else if (hostOf(host, QStringLiteral("dev.azure.com"), {}) || host.endsWith(QLatin1String(".visualstudio.com"))) {
    match = azure.match(path);
  }
  if (!match.hasMatch()) return std::nullopt;
  bool ok = false;
  const int number = match.captured(2).toInt(&ok);
  if (!ok || number <= 0) return std::nullopt;
  return Target{host, match.captured(1).toLower(), number, url.trimmed()};
}

// As the web's LinkPullRequestDialog: a URL may name any repository on a host
// a project here reads, since that project lends the node its credentials
// there (findProjectOnChangeRequestHost); Azure DevOps reads with the
// checkout's own organization and project, so there it takes a project of that
// repository. A bare number means the thread's own repository.
std::variant<ThreadPullRequests::Target, QString> ThreadPullRequests::resolve(const QString& input) const {
  const QString trimmed = input.trimmed();
  if (trimmed.isEmpty()) return QStringLiteral("Paste a pull request URL or enter 123 / #123.");
  const QList<QJsonObject> projects = m_store->projectRows(environmentId());
  if (const std::optional<Target> target = parseUrl(trimmed)) {
    const QString host = target->host.section(QLatin1Char(':'), 0, 0);
    const QString wanted = canonicalKey(target->host + QLatin1Char('/') + target->repository);
    const bool azure = wanted.startsWith(QLatin1String("dev.azure.com/"));
    const bool readable = std::any_of(projects.cbegin(), projects.cend(), [&](const QJsonObject& project) {
      const auto [projectHost, repository] = repositoryOf(project);
      return azure ? canonicalKey(projectHost + QLatin1Char('/') + repository) == wanted : projectHost == host;
    });
    if (!readable) return QStringLiteral("No project in this environment can read %1/%2.").arg(target->host, target->repository);
    return *target;
  }
  static const QRegularExpression bare(QStringLiteral("^#?([0-9]+)$"));
  const QRegularExpressionMatch number = bare.match(trimmed);
  if (!number.hasMatch() || number.captured(1).toInt() <= 0) return QStringLiteral("Use a pull request URL, 123, or #123.");
  const QJsonObject row = m_store->threadRow(m_thread);
  const auto [host, repository] = repositoryOf(m_store->projectRow(environmentId(), text(row, QLatin1String("projectId"))));
  if (host.isEmpty() || repository.isEmpty()) return QStringLiteral("Paste a full URL to link a pull request from another repository.");
  const int value = number.captured(1).toInt();
  return Target{host, repository, value, pageOf(host, repository, value)};
}

// --- Actions ---------------------------------------------------------------------------

void ThreadPullRequests::link(const QString& input) {
  if (m_thread.isEmpty() || m_linking || !m_online) return;
  const auto resolved = resolve(input);
  if (const QString* problem = std::get_if<QString>(&resolved)) {
    setProblem(*problem);
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
                            [notify = m_notify, number](const QJsonValue&, const std::optional<QString>& error) {
                              if (error) notify(QStringLiteral("error"), QStringLiteral("Could not unlink pull request #%1").arg(number), *error);
                            });
}

void ThreadPullRequests::refresh() {
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
  if (QClipboard* clipboard = QGuiApplication::clipboard()) clipboard->setText(text(*link, QLatin1String("url")));
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
    case SourceLabelRole: {
      // ThreadPullRequestsPanel's SOURCE_LABELS.
      const QString source = text(link, QLatin1String("source"));
      if (source == QLatin1String("manual")) return QStringLiteral("Linked by you");
      if (source == QLatin1String("created")) return QStringLiteral("Created from this thread");
      if (source == QLatin1String("agent")) return QStringLiteral("Linked by the agent");
      if (source == QLatin1String("stack")) return QStringLiteral("Found in the stack");
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
  };
}
