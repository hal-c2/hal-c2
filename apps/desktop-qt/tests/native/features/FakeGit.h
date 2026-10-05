#pragma once
// What another steps file needs from WorkspaceSteps.cpp's git.

#include <QString>
#include <QStringList>

class World;

// The folder `cwd` on the MC is a git checkout with these branches (most
// recently committed first), on `current`; its status goes to whoever follows it.
void fakeGitRepo(World& world, const QString& cwd, const QStringList& branches, const QString& current, const QString& defaultBranch);
