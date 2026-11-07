#pragma once

class QString;
struct World;

// The Pull requests tab's share of phrases other domains also use ("the user
// chooses …", "it says …", "the pull request cannot be linked"), whose one
// step definition lives with the domain that had it first. Each returns
// whether it took the step.
bool pullRequestThreadChooses(World& world, const QString& what);
bool pullRequestReviewSays(World& world, const QString& what);
bool pullRequestCannotBeLinked(World& world);
