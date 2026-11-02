#include "PullRequestReference.h"

#include <QRegularExpression>
#include <QStringList>

namespace pullRequestReference {

namespace {

QRegularExpression pattern(const char* source) {
  return QRegularExpression(QString::fromLatin1(source), QRegularExpression::CaseInsensitiveOption);
}

// `az repos pr checkout`'s pull request: its --id (or -i), else its first
// argument that is not an option.
QString azureCheckout(const QString& arguments) {
  const QStringList parts = arguments.trimmed().split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
  for (qsizetype index = 0; index < parts.size(); ++index) {
    const QString& part = parts.at(index);
    if (part == QLatin1String("--id") || part == QLatin1String("-i")) return parts.value(index + 1);
    if (part.startsWith(QLatin1String("--id="))) return part.mid(5);
  }
  for (const QString& part : parts) {
    if (!part.startsWith(QLatin1Char('-'))) return part;
  }
  return {};
}

}  // namespace

std::optional<QString> parse(const QString& input) {
  static const QRegularExpression forgejoUrl = pattern("^https?://[^/\\s]+/(?:[^/\\s]+/)+[^/\\s]+/pulls/(\\d+)(?:[/?#].*)?$");
  static const QRegularExpression githubUrl = pattern("^https://github\\.com/[^/\\s]+/[^/\\s]+/pull/(\\d+)(?:[/?#].*)?$");
  static const QRegularExpression gitlabUrl = pattern("^https://[^/\\s]*gitlab[^/\\s]*/.+/-/merge_requests/(\\d+)(?:[/?#].*)?$");
  static const QRegularExpression azureUrl = pattern(
      "^https://(?:dev\\.azure\\.com/[^/\\s]+/[^/\\s]+|[^/\\s]+\\.visualstudio\\.com/[^/\\s]+)/_git/[^/\\s]+/pullrequest/(\\d+)(?:[/?#].*)?$");
  static const QRegularExpression number = pattern("^#?(\\d+)$");
  static const QRegularExpression tea = pattern("^tea\\s+(?:pr|pulls)\\s+checkout\\s+(.+)$");
  static const QRegularExpression gh = pattern("^gh\\s+pr\\s+checkout\\s+(.+)$");
  static const QRegularExpression glab = pattern("^glab\\s+mr\\s+checkout\\s+(.+)$");
  static const QRegularExpression az = pattern("^az\\s+repos\\s+pr\\s+checkout\\s+(.+)$");

  const QString trimmed = input.trimmed();
  if (trimmed.isEmpty()) return std::nullopt;
  QString named = trimmed;
  QRegularExpressionMatch match;
  if ((match = tea.match(trimmed)).hasMatch() || (match = gh.match(trimmed)).hasMatch() || (match = glab.match(trimmed)).hasMatch()) {
    named = match.captured(1).trimmed();
  } else if ((match = az.match(trimmed)).hasMatch()) {
    named = azureCheckout(match.captured(1));
  }
  if (named.isEmpty()) return std::nullopt;
  for (const QRegularExpression* url : {&forgejoUrl, &githubUrl, &gitlabUrl, &azureUrl}) {
    if (url->match(named).hasMatch()) return named;
  }
  if ((match = number.match(named)).hasMatch()) return match.captured(1);
  return std::nullopt;
}

}  // namespace pullRequestReference
