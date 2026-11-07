#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

#include <optional>

// What a link in the conversation points to, when it is a pull request: the
// host below which its repository is addressed, the repository as that host
// writes it (both lower case, as the MC and a project's repository identity
// write them), its number and its page. No layout and no MC here, so the
// phone can tell links apart the same way.
//
// Nothing guesses: a host is recognised by the path shape it alone uses,
// guarded by a hostname it could plausibly be served from, and anything else
// (an issue, a commit, a repository root) is an ordinary link. A lookalike
// hostname ("github.com.evil.test") still parses; what keeps it a link is
// that no project is checked out from it (projectFor).
struct PullRequestLink {
  // github, gitlab, forgejo, bitbucket or azure-devops.
  QString provider;
  // Forgejo's keeps a port that is not the scheme's.
  QString host;
  QString repository;
  int number = 0;
  // The pull request's page; for a written number, the pull request page it
  // may be (candidate).
  QString url;
  // Read from GitHub's page for an issue: GitHub writes every "#123" through
  // /issues/, pull requests included, so it is one only if the host says so.
  bool candidate = false;

  // "host/repository#number", as the right panel's review tabs name it.
  QString key() const;
};

namespace PullRequestLinks {

// The pull request a URL names, or nothing.
std::optional<PullRequestLink> parse(const QString& url);
// parse(), or the pull request a GitHub "#123" autolink to an issue page may be.
std::optional<PullRequestLink> claim(const QString& url);
// The host itself, one of its subdomains, or an install named after the provider.
bool isHostOf(const QString& host, const QString& apex, const QString& label = {});
// A repository's pull request page, from the host alone, as the MC builds it
// (mcp/tools/pull_requests.ex url/4); empty on a host it does not know.
QString pageOf(const QString& host, const QString& repository, int number);
// One name for an Azure DevOps repository however it is reached.
QString canonicalKey(QString key);
// The host and repository of a project's checkout ("github.com/acme/shop").
std::pair<QString, QString> repositoryOf(const QJsonObject& project);
// The id of the project the link belongs to: the one checked out from its
// repository, else (anyHost) any project on its host, which lends the MC its
// credentials there; Azure DevOps reads with a checkout's own organization
// and project, so it needs the repository's. Empty when none can read it.
QString projectFor(const QList<QJsonObject>& projects, const PullRequestLink& link, bool anyHost);
// "Open on GitHub", ..., named for where the user lands.
QString openOnHostLabel(const QString& provider);

}  // namespace PullRequestLinks
