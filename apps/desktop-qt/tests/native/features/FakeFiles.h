#pragma once

#include <QHash>
#include <QMap>
#include <QSet>
#include <QString>
#include <QStringList>

#include "FakeMc.h"

// The MC's workspace of the thread's project (PanelSteps.cpp,
// PaletteSteps.cpp): file paths to contents, and the folders git ignores, as
// apps/server-ex lib/hal_c2/workspace.ex answers projects.listEntries,
// searchEntries, searchContents and readFile. Also the environment's folders
// for filesystem.browse (browser.ex): folder paths under `home`. While the
// MC holds "search", file searches wait for answerHeld(). A file's address
// (signFile) serves its bytes: a small PNG for an image.
struct FakeFiles {
  QMap<QString, QString> files;
  QSet<QString> ignored;
  // Files of the host outside every workspace, by their full path: read
  // (readFile takes a full path), never listed.
  QMap<QString, QString> outside;
  // Folders ("" the top) whose next listing fails.
  QSet<QString> failOnce;
  bool cannotList = false;
  QSet<QString> readFailsOnce;
  // Files whose next download from their signed address fails.
  QSet<QString> loadFailsOnce;
  // The file each signed address serves, by its token; the paths downloaded.
  QHash<QString, QString> signedFiles;
  QStringList downloaded;
  // A file larger than the MC reads whole, by its full size in bytes.
  QHash<QString, qint64> truncated;
  // The machine's folders, absolute, for filesystem.browse; "~" is `home`.
  QString home = QStringLiteral("/home/sam");
  QSet<QString> folders;
};

FakeFiles& fakeFiles(FakeMc& mc);
// As apps/server-ex lib/hal_c2/attachments.ex create_url for a file of a
// workspace (workspace-file, draft-workspace-file, media-file): an address
// under /api/assets/ good for an hour. False for any other resource.
bool signFile(FakeMc& mc, const FakeMc::Rpc& rpc);
// Every folder a path is under, and the path.
QStringList withFolders(const QString& path);
