#include "PullRequestLinks.h"

#include <QHash>
#include <QRegularExpression>
#include <QUrl>

QString PullRequestLink::key() const {
  return QStringLiteral("%1/%2#%3").arg(host, repository).arg(number);
}

namespace PullRequestLinks {

bool isHostOf(const QString& host, const QString& apex, const QString& label) {
  return host == apex || host.endsWith(QLatin1Char('.') + apex) ||
         (!label.isEmpty() && host.split(QLatin1Char('.')).contains(label));
}

namespace {

bool isAzure(const QString& host) {
  return isHostOf(host, QStringLiteral("dev.azure.com")) || host.endsWith(QLatin1String(".visualstudio.com"));
}

std::optional<QUrl> webUrl(const QString& url) {
  const QUrl parsed(url.trimmed(), QUrl::StrictMode);
  // javascript:, mailto: and friends have no host to speak of and nothing to open.
  if (!parsed.isValid() || (parsed.scheme() != QLatin1String("http") && parsed.scheme() != QLatin1String("https")) ||
      parsed.host().isEmpty()) {
    return std::nullopt;
  }
  return parsed;
}

}  // namespace

// The host, repository and number behind a pull request URL, as the MC parses
// it (projection/pull_requests.ex parse_change_request_url/1) and as the web's
// parseChangeRequestUrl did: GitLab's /-/ marker is trusted on any hostname,
// the generic /pull/ only from a GitHub-ish one.
std::optional<PullRequestLink> parse(const QString& url) {
  const std::optional<QUrl> parsed = webUrl(url);
  if (!parsed) return std::nullopt;
  QString host = parsed->host().toLower();
  const QString path = parsed->path().isEmpty() ? QStringLiteral("/") : parsed->path();
  static const QRegularExpression github(QStringLiteral("^/([^/]+/[^/]+)/pull/([0-9]+)(?:/|$)"));
  static const QRegularExpression forgejo(QStringLiteral("^/([^/]+(?:/[^/]+)+)/pulls/([0-9]+)(?:/|$)"));
  static const QRegularExpression gitlab(QStringLiteral("^/([^/]+(?:/[^/]+)+)/-/merge_requests/([0-9]+)(?:/|$)"));
  static const QRegularExpression bitbucket(QStringLiteral("^/([^/]+/[^/]+)/pull-requests/([0-9]+)(?:/|$)"));
  static const QRegularExpression azure(QStringLiteral("^/((?:[^/]+/)*_git/[^/]+)/pullrequest/([0-9]+)(?:/|$)"));
  QRegularExpressionMatch match;
  QString provider;
  if (isHostOf(host, QStringLiteral("github.com"), QStringLiteral("github")) && (match = github.match(path)).hasMatch()) {
    provider = QStringLiteral("github");
  } else if ((match = forgejo.match(path)).hasMatch()) {
    provider = QStringLiteral("forgejo");
    // Forgejo and Gitea keep a port that is not the scheme's.
    if (parsed->port() > 0 && parsed->port() != (parsed->scheme() == QLatin1String("https") ? 443 : 80)) {
      host += QStringLiteral(":%1").arg(parsed->port());
    }
  } else if ((match = gitlab.match(path)).hasMatch()) {
    provider = QStringLiteral("gitlab");
  } else if (isHostOf(host, QStringLiteral("bitbucket.org"), QStringLiteral("bitbucket"))) {
    provider = QStringLiteral("bitbucket");
    match = bitbucket.match(path);
  } else if (isAzure(host)) {
    provider = QStringLiteral("azure-devops");
    match = azure.match(path);
  }
  if (!match.hasMatch()) return std::nullopt;
  bool ok = false;
  const int number = match.captured(2).toInt(&ok);
  if (!ok || number <= 0) return std::nullopt;
  return PullRequestLink{provider, host, match.captured(1).toLower(), number, url.trimmed(), false};
}

// GitHub writes every "#123" through /issues/, pull requests included, so an
// issue page there only builds a candidate the host must confirm
// (pullRequestCandidateUrlFromReferenceAutolink).
std::optional<PullRequestLink> claim(const QString& url) {
  if (std::optional<PullRequestLink> link = parse(url)) return link;
  const std::optional<QUrl> parsed = webUrl(url);
  if (!parsed) return std::nullopt;
  const QString host = parsed->host().toLower();
  if (!isHostOf(host, QStringLiteral("github.com"), QStringLiteral("github"))) return std::nullopt;
  static const QRegularExpression issue(QStringLiteral("^/([^/]+/[^/]+)/issues/([0-9]+)(?:/|$)"));
  const QRegularExpressionMatch match = issue.match(parsed->path());
  if (!match.hasMatch()) return std::nullopt;
  const int number = match.captured(2).toInt();
  if (number <= 0) return std::nullopt;
  QUrl candidate = *parsed;
  candidate.setPath(QStringLiteral("/%1/pull/%2").arg(match.captured(1)).arg(number));
  candidate.setQuery(QString());
  candidate.setFragment(QString());
  return PullRequestLink{QStringLiteral("github"), host, match.captured(1).toLower(), number, candidate.toString(), true};
}

// As the MC builds it (mcp/tools/pull_requests.ex url/4).
QString pageOf(const QString& host, const QString& repository, int number) {
  if (isHostOf(host, QStringLiteral("gitlab.com"), QStringLiteral("gitlab"))) {
    return QStringLiteral("https://%1/%2/-/merge_requests/%3").arg(host, repository).arg(number);
  }
  if (isHostOf(host, QStringLiteral("bitbucket.org"), QStringLiteral("bitbucket"))) {
    return QStringLiteral("https://%1/%2/pull-requests/%3").arg(host, repository).arg(number);
  }
  if (isAzure(host)) return QStringLiteral("https://%1/%2/pullrequest/%3").arg(host, repository).arg(number);
  return QStringLiteral("https://%1/%2/pull/%3").arg(host, repository).arg(number);
}

// Over SSH, visualstudio.com or dev.azure.com.
QString canonicalKey(QString key) {
  static const QRegularExpression ssh(
      QStringLiteral("^(?:ssh\\.dev\\.azure\\.com|vs-ssh\\.visualstudio\\.com)/v3/([^/]+)/([^/]+)/([^/]+)$"));
  static const QRegularExpression legacy(QStringLiteral("^([^.]+)\\.visualstudio\\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)$"));
  key.replace(ssh, QStringLiteral("dev.azure.com/\\1/\\2/_git/\\3"));
  key.replace(legacy, QStringLiteral("dev.azure.com/\\1/\\2/_git/\\3"));
  return key;
}

std::pair<QString, QString> repositoryOf(const QJsonObject& project) {
  const QString key = project.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString().toLower();
  const qsizetype slash = key.indexOf(QLatin1Char('/'));
  if (slash <= 0) return {};
  return {key.left(slash), key.mid(slash + 1)};
}

QString projectFor(const QList<QJsonObject>& projects, const PullRequestLink& link, bool anyHost) {
  const QString host = link.host.section(QLatin1Char(':'), 0, 0);
  const QString wanted = canonicalKey(host + QLatin1Char('/') + link.repository);
  const bool azure = wanted.startsWith(QLatin1String("dev.azure.com/"));
  const auto id = [](const QJsonObject& project) { return project.value(QLatin1String("id")).toString(); };
  for (const QJsonObject& project : projects) {
    const auto [projectHost, repository] = repositoryOf(project);
    if (!projectHost.isEmpty() && canonicalKey(projectHost + QLatin1Char('/') + repository) == wanted) return id(project);
  }
  if (!anyHost || azure) return {};
  for (const QJsonObject& project : projects) {
    if (repositoryOf(project).first == host) return id(project);
  }
  return {};
}

QString openOnHostLabel(const QString& provider) {
  static const QHash<QString, QString> labels{
      {QStringLiteral("github"), QStringLiteral("Open on GitHub")},
      {QStringLiteral("gitlab"), QStringLiteral("Open on GitLab")},
      {QStringLiteral("forgejo"), QStringLiteral("Open on Forgejo")},
      {QStringLiteral("bitbucket"), QStringLiteral("Open on Bitbucket")},
      {QStringLiteral("azure-devops"), QStringLiteral("Open on Azure DevOps")},
  };
  return labels.value(provider, QStringLiteral("Open on host"));
}

}  // namespace PullRequestLinks
