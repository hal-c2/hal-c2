#pragma once

#include <QString>

#include <optional>

namespace pullRequestReference {

// What a pasted pull request names, as the MC's git.resolvePullRequest takes
// it: a GitHub, GitLab, Forgejo or Azure DevOps link as it was pasted, or a
// bare number. Checkout commands (`gh pr checkout 7`, `glab mr checkout 7`,
// `tea pr checkout 7`, `az repos pr checkout --id 7`) give what they check
// out. Nothing when the text names no pull request (upstream
// pullRequestReference.ts).
std::optional<QString> parse(const QString& input);

}  // namespace pullRequestReference
