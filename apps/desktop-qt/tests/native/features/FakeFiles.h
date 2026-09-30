#pragma once

#include <QHash>
#include <QMap>
#include <QSet>
#include <QString>
#include <QStringList>

class FakeNode;

// The node's workspace of the thread's project (PanelSteps.cpp,
// PaletteSteps.cpp): file paths to contents, and the folders git ignores, as
// apps/server-ex lib/hal_c2/workspace.ex answers projects.listEntries,
// searchEntries, searchContents and readFile. Also the environment's folders
// for filesystem.browse (browser.ex): folder paths under `home`. While the
// node holds "search", file searches wait for answerHeld().
struct FakeFiles {
  QMap<QString, QString> files;
  QSet<QString> ignored;
  // Folders ("" the top) whose next listing fails.
  QSet<QString> failOnce;
  bool cannotList = false;
  QSet<QString> readFailsOnce;
  // A file larger than the node reads whole, by its full size in bytes.
  QHash<QString, qint64> truncated;
  // The machine's folders, absolute, for filesystem.browse; "~" is `home`.
  QString home = QStringLiteral("/home/sam");
  QSet<QString> folders;
};

FakeFiles& fakeFiles(FakeNode& node);
// Every folder a path is under, and the path.
QStringList withFolders(const QString& path);
