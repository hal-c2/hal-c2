// The right panel beside a thread (RightPanelController): its tabs, the Diff
// tab over the node's checkpoint diffs, and the Files tab over the node's
// workspace (features/source-control/checkpoint-diffs.feature,
// timeline/checkpoints.feature, files/file-explorer.feature,
// files/file-viewer-and-editing.feature, navigation/layout.feature's right
// panel). The node's side is faked here: one patch per finished turn, and a
// project's files as a map of paths.

#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QSet>
#include <QTimer>

#include "DiffModel.h"
#include "FileTreeModel.h"
#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadDiff.h"
#include "WorkspaceFiles.h"
#include "World.h"

namespace {

using namespace stream;

// The node's workspace of the thread's project: file paths to contents, and
// the folders git ignores.
struct FakeFiles {
  QMap<QString, QString> files;
  QSet<QString> ignored;
  // Folders ("" the top) whose next listing fails.
  QSet<QString> failOnce;
  bool cannotList = false;
  QSet<QString> readFailsOnce;
  // A file larger than the node reads whole, by its full size in bytes.
  QHash<QString, qint64> truncated;
};

// The node's checkpoints: each finished turn's patch.
struct FakeDiffs {
  QMap<int, QString> patches;
  bool failing = false;
  QList<QJsonObject> asked;
  // The run each turn was.
  QMap<int, QString> runs;
};

QString patchAdding(const QString& path, const QStringList& lines) {
  QString patch = QStringLiteral("diff --git a/%1 b/%1\nnew file mode 100644\n--- /dev/null\n+++ b/%1\n@@ -0,0 +1,%2 @@\n")
                      .arg(path)
                      .arg(lines.size());
  for (const QString& line : lines) patch += QLatin1Char('+') + line + QLatin1Char('\n');
  return patch;
}

// Every folder a path is under, and the path.
QStringList withFolders(const QString& path) {
  QStringList paths;
  const QStringList parts = path.split(QLatin1Char('/'));
  for (qsizetype i = 1; i <= parts.size(); ++i) paths.append(parts.mid(0, i).join(QLatin1Char('/')));
  return paths;
}

QJsonObject entry(const FakeFiles& fake, const QString& path) {
  const bool directory = !fake.files.contains(path);
  bool ignored = false;
  for (const QString& folder : withFolders(path)) ignored = ignored || fake.ignored.contains(folder);
  return {{QStringLiteral("path"), path}, {QStringLiteral("kind"), directory ? QStringLiteral("directory") : QStringLiteral("file")},
          {QStringLiteral("ignored"), ignored}};
}

const FakeNode::Extension extension([](FakeNode& node) {
  // projects.listEntries, searchEntries and readFile as apps/server-ex
  // lib/hal_c2/workspace.ex answers them.
  node.onRpc(QStringLiteral("projects.listEntries"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = node.part<FakeFiles>();
    const QString folder = rpc.payload.value(QLatin1String("directoryPath")).toString();
    if (fake.cannotList || fake.failOnce.remove(folder)) {
      node.refuse(rpc, QStringLiteral("Could not list %1.").arg(folder.isEmpty() ? QStringLiteral("the project") : folder));
      return;
    }
    QSet<QString> children;
    for (auto it = fake.files.cbegin(); it != fake.files.cend(); ++it) {
      for (const QString& path : withFolders(it.key())) {
        const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
        if ((slash < 0 ? QString() : path.left(slash)) == folder) children.insert(path);
      }
    }
    QJsonArray entries;
    for (const QString& path : children) entries.append(entry(fake, path));
    node.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
  });
  node.onRpc(QStringLiteral("projects.searchEntries"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = node.part<FakeFiles>();
    const QString query = rpc.payload.value(QLatin1String("query")).toString();
    QSet<QString> matches;
    for (auto it = fake.files.cbegin(); it != fake.files.cend(); ++it) {
      for (const QString& path : withFolders(it.key())) {
        if (path.section(QLatin1Char('/'), -1).contains(query, Qt::CaseInsensitive)) matches.insert(path);
      }
    }
    QJsonArray entries;
    for (const QString& path : matches) entries.append(entry(fake, path));
    node.reply(rpc, QJsonObject{{QStringLiteral("entries"), entries}, {QStringLiteral("truncated"), false}});
  });
  node.onRpc(QStringLiteral("projects.readFile"), [&node](const FakeNode::Rpc& rpc) {
    FakeFiles& fake = node.part<FakeFiles>();
    const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
    if (fake.readFailsOnce.remove(path) || !fake.files.contains(path)) {
      node.refuse(rpc, QStringLiteral("Could not read %1.").arg(path));
      return;
    }
    const QString contents = fake.files.value(path);
    node.reply(rpc, QJsonObject{{QStringLiteral("contents"), contents},
                                {QStringLiteral("byteLength"), double(fake.truncated.value(path, contents.toUtf8().size()))},
                                {QStringLiteral("truncated"), fake.truncated.contains(path)}});
  });

  // A turn's diff is the patches of the turns in its range (a fake's
  // stand-in for diffing two checkpoints).
  const auto diff = [&node](const FakeNode::Rpc& rpc, int from) {
    FakeDiffs& fake = node.part<FakeDiffs>();
    fake.asked.append(QJsonObject{{QStringLiteral("method"), rpc.method}, {QStringLiteral("payload"), rpc.payload}});
    if (fake.failing) {
      node.refuse(rpc, QStringLiteral("Checkpoint unavailable for turn %1.").arg(rpc.payload.value(QLatin1String("toTurnCount")).toInt()));
      return;
    }
    QString patch;
    for (int turn = from + 1; turn <= rpc.payload.value(QLatin1String("toTurnCount")).toInt(); ++turn) patch += fake.patches.value(turn);
    node.reply(rpc, QJsonObject{{QStringLiteral("diff"), patch}});
  };
  node.onRpc(QStringLiteral("orchestration.getTurnDiff"), [diff](const FakeNode::Rpc& rpc) {
    diff(rpc, rpc.payload.value(QLatin1String("fromTurnCount")).toInt());
  });
  node.onRpc(QStringLiteral("orchestration.getFullThreadDiff"), [diff](const FakeNode::Rpc& rpc) { diff(rpc, 0); });
});

RightPanelController* panel(World& world) {
  return world.native().controller<RightPanelController>();
}

QString describePanel(World& world) {
  return QStringLiteral("the panel is %1").arg(show(world.state(QStringLiteral("panel"))));
}

// --- Turns and checkpoints -----------------------------------------------------------

// A turn that finished and left a checkpoint, changing `files` with `patch`.
void finishTurn(World& world, int turn, const QString& patch) {
  const QString run = startRun(world);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Answer %1").arg(turn)}});
  settleRun(world, QStringLiteral("completed"), 30);
  set(world, QStringLiteral("checkpoint"), QStringLiteral("cp-%1").arg(turn),
      {{QStringLiteral("id"), QStringLiteral("cp-%1").arg(turn)}, {QStringLiteral("scopeId"), QStringLiteral("scope-1")},
       {QStringLiteral("runId"), run}, {QStringLiteral("appRunOrdinal"), turn}, {QStringLiteral("status"), QStringLiteral("ready")}});
  world.node.part<FakeDiffs>().patches.insert(turn, patch);
  world.node.part<FakeDiffs>().runs.insert(turn, run);
}

void finishTurns(World& world, int count) {
  for (int turn = 1; turn <= count; ++turn) {
    const QString path = QStringLiteral("src/turn%1.ts").arg(turn);
    finishTurn(world, turn, patchAdding(path, {QStringLiteral("export const turn = %1;").arg(turn), QStringLiteral("export const done = true;")}));
  }
}

// checkpoint.rollback as the node does it (lib/hal_c2/orchestration/rollback.ex):
// the later runs are rolled back and their checkpoints go stale.
void rollBackOnCommand(World& world) {
  world.node.effects.append([&world](const QJsonObject& command) {
    if (command.value(QLatin1String("type")).toString() != QLatin1String("checkpoint.rollback")) return;
    const int target = command.value(QLatin1String("checkpointId")).toString().section(QLatin1Char('-'), 1).toInt();
    // After the command's answer, as the node's events follow it.
    QTimer::singleShot(0, &world.bridge(), [&world, target] {
      const QMap<int, QString> runs = world.node.part<FakeDiffs>().runs;
      for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
        if (it.key() <= target) continue;
        set(world, QStringLiteral("run"), *it, {{QStringLiteral("status"), QStringLiteral("rolled_back")}});
        set(world, QStringLiteral("checkpoint"), QStringLiteral("cp-%1").arg(it.key()), {{QStringLiteral("status"), QStringLiteral("stale")}});
      }
    });
  });
}

ThreadDiff& diff(World& world) {
  return *panel(world)->diff();
}

void waitForDiff(World& world) {
  world.waitFor([&] { return diff(world).status() != QLatin1String("loading") && diff(world).status() != QLatin1String("idle"); },
                [&] { return QStringLiteral("the diff to load; it is %1 (%2)").arg(diff(world).status(), diff(world).message()); });
}

void openDiff(World& world, int turn) {
  world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}, {QStringLiteral("turn"), turn}});
  waitForDiff(world);
}

QString describeDiff(World& world) {
  return QStringLiteral("the diff (%1) shows %2").arg(diff(world).status(), diff(world).model()->paths().join(QStringLiteral(", ")));
}

void expectDiffOf(World& world, const QStringList& paths) {
  waitForDiff(world);
  expect(diff(world).status() == QLatin1String("ready") && diff(world).model()->paths() == paths, describeDiff(world));
}

QStringList turnFiles(int from, int to) {
  QStringList paths;
  for (int turn = from; turn <= to; ++turn) paths.append(QStringLiteral("src/turn%1.ts").arg(turn));
  return paths;
}

// The rows of one file in the diff: its header, then its hunks and lines when expanded.
QList<QVariantMap> rowsOfFile(World& world, const QString& path) {
  DiffModel& model = *diff(world).model();
  QList<QVariantMap> rows;
  const int file = model.fileOf(path);
  if (file < 0) fail(describeDiff(world));
  for (int row = model.rowOfFile(file); row < model.rowCount(); ++row) {
    const QModelIndex index = model.index(row);
    if (model.data(index, DiffModel::FileRole).toInt() != file) break;
    rows.append({{QStringLiteral("kind"), model.data(index, DiffModel::KindRole)},
                 {QStringLiteral("expanded"), model.data(index, DiffModel::ExpandedRole)},
                 {QStringLiteral("sign"), model.data(index, DiffModel::SignRole)},
                 {QStringLiteral("rightSign"), model.data(index, DiffModel::RightSignRole)}});
  }
  return rows;
}

// --- Files ---------------------------------------------------------------------------

WorkspaceFiles& files(World& world) {
  return *panel(world)->files();
}

FileTreeModel& tree(World& world) {
  return *files(world).tree();
}

QString describeTree(World& world) {
  QStringList rows;
  FileTreeModel& model = tree(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    const QModelIndex index = model.index(row);
    rows.append(QStringLiteral("%1%2 (%3%4)")
                    .arg(QString(model.data(index, FileTreeModel::DepthRole).toInt() * 2, QLatin1Char(' ')),
                         model.data(index, FileTreeModel::NameRole).toString(), model.data(index, FileTreeModel::KindRole).toString(),
                         model.data(index, FileTreeModel::ProblemRole).toString().isEmpty()
                             ? QString()
                             : QStringLiteral(": ") + model.data(index, FileTreeModel::ProblemRole).toString()));
  }
  return QStringLiteral("the tree (%1) is [%2]").arg(model.rootStatus(), rows.join(QStringLiteral("; ")));
}

bool settled(World& world) {
  if (files(world).searching()) return false;
  FileTreeModel& model = tree(world);
  if (model.rootStatus() == QLatin1String("loading")) return false;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.data(model.index(row), FileTreeModel::KindRole).toString() == QLatin1String("loading")) return false;
  }
  return true;
}

void waitForTree(World& world) {
  world.waitFor([&] { return settled(world); }, [&] { return QStringLiteral("the tree to settle; %1").arg(describeTree(world)); });
}

void openFiles(World& world) {
  world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("files")}});
  waitForTree(world);
}

void openFile(World& world, const QString& path, int line = 0) {
  QVariantMap payload{{QStringLiteral("tab"), QStringLiteral("files")}, {QStringLiteral("path"), path}};
  if (line > 0) payload.insert(QStringLiteral("line"), line);
  world.bridge().dispatch(QStringLiteral("panel.open"), payload);
  world.waitFor([&] { return files(world).fileStatus() != QLatin1String("loading"); }, QStringLiteral("the file to load"));
  waitForTree(world);
}

QStringList childrenOf(World& world, const QString& folder) {
  QStringList names;
  for (const QString& path : tree(world).visiblePaths()) {
    if (path.section(QLatin1Char('/'), 0, -2) == folder && path.contains(QLatin1Char('/'))) names.append(path.section(QLatin1Char('/'), -1));
  }
  return names;
}

void expectShownUnder(World& world, const QStringList& names, const QString& folder) {
  waitForTree(world);
  const QStringList shown = childrenOf(world, folder);
  for (const QString& name : names) expect(shown.contains(name), describeTree(world));
}

// A text file of `count` numbered lines.
QString linesOf(int count) {
  QString text;
  for (int line = 1; line <= count; ++line) text += QStringLiteral("const line%1 = %1;\n").arg(line);
  return text;
}

// --- Tabs ----------------------------------------------------------------------------

QStringList tabTitles(World& world) {
  QStringList titles;
  for (const QVariant& tab : at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList()) titles.append(at(tab, QStringLiteral("title")).toString());
  return titles;
}

QString tabIdTitled(World& world, const QString& title) {
  for (const QVariant& tab : at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList()) {
    if (at(tab, QStringLiteral("title")) == title) return at(tab, QStringLiteral("id")).toString();
  }
  fail(describePanel(world));
}

// The page's own right panel for the thread, as ShellRightPanelBridge publishes it.
void pagePublishes(World& world, bool open, const QString& active, const QVariantList& surfaces, const QVariantMap& canAdd) {
  const QString threadKey = world.node.environmentId + QLatin1Char(':') + kThread;
  world.bridge().publish(QStringLiteral("rightPanel"),
                         QVariantMap{{QStringLiteral("threadKey"), threadKey},
                                     {QStringLiteral("isOpen"), open},
                                     {QStringLiteral("activeSurfaceId"), active.isEmpty() ? QVariant() : QVariant(active)},
                                     {QStringLiteral("surfaces"), surfaces},
                                     {QStringLiteral("canAdd"), canAdd},
                                     {QStringLiteral("embedPath"), QStringLiteral("/embed/env-a/thread-1")}});
}

const QHash<QString, QString> kKinds{{QStringLiteral("diff"), QStringLiteral("diff")},
                                     {QStringLiteral("files"), QStringLiteral("files")},
                                     {QStringLiteral("agents"), QStringLiteral("agents")},
                                     {QStringLiteral("terminal"), QStringLiteral("terminal")},
                                     {QStringLiteral("pull request"), QStringLiteral("pull-requests")},
                                     {QStringLiteral("previews"), QStringLiteral("previews")}};

// The thread's row with `links` linked pull requests, as the node sends it.
void linkPullRequests(World& world, int links) {
  QJsonArray pullRequests;
  for (int number = 1; number <= links; ++number) {
    pullRequests.append(QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                    {QStringLiteral("number"), number}, {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/%1").arg(number)},
                                    {QStringLiteral("source"), QStringLiteral("agent")}, {QStringLiteral("snapshot"), QJsonValue()}});
  }
  QJsonObject row = world.node.threads.value(kThread);
  row.insert(QStringLiteral("pullRequests"), pullRequests);
  world.node.threads.insert(kThread, row);
  world.node.sendRow(kThread, row);
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  // Backgrounds.
  step(QStringLiteral("a connected environment with the thread %1 in the git project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.projects.insert(c[1], {{QStringLiteral("id"), c[1]}, {QStringLiteral("title"), c[1]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[1]}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    lookAtThread(world, c[1]);
  });
  step(QStringLiteral("the agent finished (\\d+) turns in %1 that each edited files").arg(q), [](World& world, const Captures& c, const Table&) {
    finishTurns(world, c[0].toInt());
  });
  step(QStringLiteral("a thread in %1 with three finished turns").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    finishTurns(world, 3);
    rollBackOnCommand(world);
  });
  step(QStringLiteral("the user is looking at a thread"), [](World& world, const Captures&, const Table&) {
    world.node.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
  });

  // The Diff tab.
  step(QStringLiteral("the user opens the diff of the latest turn"), [](World& world, const Captures&, const Table&) { openDiff(world, -1); });
  step(QStringLiteral("the changes of turn (\\d+) are shown"), [](World& world, const Captures& c, const Table&) {
    const int turn = c[0].toInt();
    expectDiffOf(world, turnFiles(turn, turn));
    const QJsonObject asked = world.node.part<FakeDiffs>().asked.last();
    expect(asked.value(QLatin1String("method")) == QLatin1String("orchestration.getTurnDiff") &&
               asked.value(QLatin1String("payload")).toObject().value(QLatin1String("fromTurnCount")).toInt() == turn - 1,
           QStringLiteral("the diff asked %1").arg(show(asked.toVariantMap())));
  });
  step(QStringLiteral("the user can switch to any earlier turn or to all changes"), [](World& world, const Captures&, const Table&) {
    QStringList labels;
    for (const QVariant& choice : diff(world).choices()) labels.append(choice.toMap().value(QStringLiteral("label")).toString());
    const QStringList wanted{QStringLiteral("Latest turn"), QStringLiteral("All changes"), QStringLiteral("Turn 3"), QStringLiteral("Turn 2"), QStringLiteral("Turn 1")};
    expect(labels == wanted, QStringLiteral("the picker offers %1").arg(labels.join(QStringLiteral(", "))));
    for (int turn = 1; turn <= 2; ++turn) {
      diff(world).select(turn);
      expectDiffOf(world, turnFiles(turn, turn));
    }
    diff(world).select(0);
    expectDiffOf(world, turnFiles(1, 3));
    expect(world.node.part<FakeDiffs>().asked.last().value(QLatin1String("method")) == QLatin1String("orchestration.getFullThreadDiff"),
           QStringLiteral("all changes were not asked of the whole thread"));
  });
  step(QStringLiteral("the node cannot read the checkpoints of %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.node.part<FakeDiffs>().failing = true;
  });
  step(QStringLiteral("the node can read the checkpoints again"), [](World& world, const Captures&, const Table&) {
    world.node.part<FakeDiffs>().failing = false;
  });
  step(QStringLiteral("the user is told the diff could not be loaded"), [](World& world, const Captures&, const Table&) {
    waitForDiff(world);
    expect(diff(world).status() == QLatin1String("error") && diff(world).message().contains(QStringLiteral("Checkpoint unavailable")),
           QStringLiteral("the diff is %1: %2").arg(diff(world).status(), diff(world).message()));
  });
  step(QStringLiteral("the user asks for the diff again"), [](World& world, const Captures&, const Table&) {
    diff(world).reload();
    waitForDiff(world);
  });
  step(QStringLiteral("turn (\\d+) changed (\\d+) lines of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList lines;
    for (int line = 1; line <= c[1].toInt(); ++line) lines.append(QStringLiteral("export const rate%1 = %1;").arg(line));
    world.node.part<FakeDiffs>().patches.insert(c[0].toInt(), patchAdding(c[2], lines));
  });
  step(QStringLiteral("%1 is listed collapsed").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForDiff(world);
    const QList<QVariantMap> rows = rowsOfFile(world, c[0]);
    expect(rows.size() == 1 && !rows.first().value(QStringLiteral("expanded")).toBool(), QStringLiteral("the file has %1 rows").arg(rows.size()));
  });
  step(QStringLiteral("the user expands %1 in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    diff(world).model()->setExpanded(diff(world).model()->fileOf(c[0]), true);
  });
  step(QStringLiteral("the user collapses %1 in the diff").arg(q), [](World& world, const Captures& c, const Table&) {
    diff(world).model()->setExpanded(diff(world).model()->fileOf(c[0]), false);
  });
  step(QStringLiteral("the (\\d+) lines of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QVariantMap> rows = rowsOfFile(world, c[1]);
    const auto added = std::count_if(rows.cbegin(), rows.cend(), [](const QVariantMap& row) { return row.value(QStringLiteral("sign")) == QLatin1String("+"); });
    expect(added == c[0].toInt(), QStringLiteral("%1 added lines are shown").arg(added));
  });
  step(QStringLiteral("the user collapses every file in the diff"), [](World& world, const Captures&, const Table&) {
    diff(world).model()->collapseAll();
  });
  step(QStringLiteral("the user expands every file in the diff"), [](World& world, const Captures&, const Table&) {
    diff(world).model()->expandAll();
  });
  step(QStringLiteral("only the files' headers are shown"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    expect(model.rowCount() == model.fileCount(), QStringLiteral("%1 rows for %2 files").arg(model.rowCount()).arg(model.fileCount()));
  });
  step(QStringLiteral("every file's lines are shown"), [](World& world, const Captures&, const Table&) {
    DiffModel& model = *diff(world).model();
    for (const QString& path : model.paths()) {
      expect(rowsOfFile(world, path).size() > 1, QStringLiteral("%1 shows no lines").arg(path));
    }
  });
  step(QStringLiteral("turn (\\d+) rewrote a line of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeDiffs>().patches.insert(
        c[0].toInt(), QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1,2 +1,2 @@\n const cart = [];\n-export const tax = 0;\n+export const tax = 0.2;\n").arg(c[1]));
  });
  step(QStringLiteral("the user shows the diff side by side"), [](World& world, const Captures&, const Table&) {
    diff(world).model()->setSplit(true);
  });
  step(QStringLiteral("the user shows the diff as one column"), [](World& world, const Captures&, const Table&) {
    diff(world).model()->setSplit(false);
  });
  step(QStringLiteral("the removed and added line of %1 are shown side by side").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QVariantMap> rows = rowsOfFile(world, c[0]);
    const bool paired = std::any_of(rows.cbegin(), rows.cend(), [](const QVariantMap& row) {
      return row.value(QStringLiteral("sign")) == QLatin1String("-") && row.value(QStringLiteral("rightSign")) == QLatin1String("+");
    });
    QVariantList shown;
    for (const QVariantMap& row : rows) shown.append(row);
    expect(paired, QStringLiteral("the rows are %1").arg(show(shown)));
  });
  step(QStringLiteral("the removed and added line of %1 are shown one above the other").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QVariantMap> rows = rowsOfFile(world, c[0]);
    QStringList signs;
    for (const QVariantMap& row : rows) signs.append(row.value(QStringLiteral("sign")).toString());
    expect(signs.contains(QStringLiteral("-")) && signs.contains(QStringLiteral("+")) &&
               signs.indexOf(QStringLiteral("-")) < signs.indexOf(QStringLiteral("+")),
           QStringLiteral("the signs are %1").arg(signs.join(QLatin1Char(' '))));
  });

  // Reverting.
  step(QStringLiteral("the user reverts the thread to the checkpoint after turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    openDiff(world, c[0].toInt());
    diff(world).requestRevert(c[0].toInt());
    expect(diff(world).revertTurn() == c[0].toInt(), QStringLiteral("the revert was not asked about"));
    diff(world).confirmRevert(true);
    world.waitFor([&] { return !diff(world).reverting(); }, QStringLiteral("the revert to finish"));
    world.sync();
  });
  step(QStringLiteral("the user starts reverting to the checkpoint after turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    openDiff(world, c[0].toInt());
    diff(world).requestRevert(c[0].toInt());
  });
  step(QStringLiteral("the user rolls back to a checkpoint"), [](World& world, const Captures&, const Table&) {
    openDiff(world, -1);
    diff(world).requestRevert();
  });
  step(QStringLiteral("the user is asked to confirm that the rollback cannot be undone"), [](World& world, const Captures&, const Table&) {
    expect(diff(world).revertTurn() == 3, QStringLiteral("the user is asked about turn %1").arg(diff(world).revertTurn()));
    const auto sent = std::count_if(world.node.commands.cbegin(), world.node.commands.cend(), [](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("checkpoint.rollback");
    });
    expect(sent == 0, QStringLiteral("a rollback was sent before the user confirmed"));
  });
  step(QStringLiteral("the user cancels the revert"), [](World& world, const Captures&, const Table&) {
    diff(world).cancelRevert();
    world.sync();
  });
  step(QStringLiteral("no rollback is sent"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& command : std::as_const(world.node.commands)) {
      expect(command.value(QLatin1String("type")) != QLatin1String("checkpoint.rollback"), QStringLiteral("a rollback was sent"));
    }
    expect(diff(world).revertTurn() == 0, QStringLiteral("the user is still asked to revert"));
  });
  step(QStringLiteral("the node refuses rollbacks with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.refusals.insert(QStringLiteral("checkpoint.rollback"), c[0]);
  });
  step(QStringLiteral("turns 2 and 3 are removed from the conversation"), [](World& world, const Captures&, const Table&) {
    const QStringList answers{QStringLiteral("Answer 2"), QStringLiteral("Answer 3")};
    world.waitFor([&] {
      TimelineModel& model = timeline(world);
      for (int row = 0; row < model.rowCount(); ++row) {
        if (answers.contains(role(model, row, TimelineModel::TextRole).toString())) return false;
      }
      return true;
    }, [&] { return describe(timeline(world)); });
  });
  step(QStringLiteral("turns 1 to 3 are still shown"), [](World& world, const Captures&, const Table&) {
    world.sync();
    TimelineModel& model = timeline(world);
    QStringList texts;
    for (int row = 0; row < model.rowCount(); ++row) texts.append(role(model, row, TimelineModel::TextRole).toString());
    for (int turn = 1; turn <= 3; ++turn) expect(texts.contains(QStringLiteral("Answer %1").arg(turn)), describe(model));
  });
  step(QStringLiteral("the workspace files match the end of turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject rollback = [&] {
      for (const QJsonObject& command : std::as_const(world.node.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("checkpoint.rollback")) return command;
      }
      fail(world.describeCommands());
    }();
    expect(rollback.value(QLatin1String("checkpointId")) == QStringLiteral("cp-%1").arg(c[0]) &&
               rollback.value(QLatin1String("scopeId")) == QLatin1String("scope-1") && rollback.value(QLatin1String("restoreFiles")).toBool(),
           QStringLiteral("the rollback was %1").arg(show(rollback.toVariantMap())));
    // The later turns' checkpoints are gone from the picker.
    world.waitFor([&] { return diff(world).latestTurn() == c[0].toInt(); },
                  [&] { return QStringLiteral("the latest turn to be %1; it is %2").arg(c[0]).arg(diff(world).latestTurn()); });
  });

  // The Files tab.
  step(QStringLiteral("%1 holds %1, %1, %1 and an ignored %1 folder").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = world.node.part<FakeFiles>();
    for (const QString& path : {c[1], c[2], c[3]}) fake.files.insert(path, QStringLiteral("// %1\n").arg(path));
    fake.files.insert(c[4] + QStringLiteral("/left-pad/index.js"), QStringLiteral("module.exports = {};\n"));
    fake.ignored.insert(c[4]);
    lookAtThread(world, c[0]);
  });
  step(QStringLiteral("%1 holds the text file %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeFiles>().files.insert(c[1], linesOf(12));
    lookAtThread(world, c[0]);
  });
  step(QStringLiteral("the user expands %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!panel(world)->isOpen() || panel(world)->activeTab() != QLatin1String("files")) openFiles(world);
    tree(world).expand(c[0]);
    waitForTree(world);
  });
  step(QStringLiteral("%1 and %1 are shown under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShownUnder(world, {c[0], c[1]}, c[2]);
  });
  step(QStringLiteral("%1 is shown under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectShownUnder(world, {c[0]}, c[1]);
  });
  step(QStringLiteral("listing %1 fails once").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeFiles>().failOnce.insert(c[0]);
  });
  step(QStringLiteral("the user is told the folder could not be loaded"), [](World& world, const Captures&, const Table&) {
    FileTreeModel& model = tree(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      const QModelIndex index = model.index(row);
      if (model.data(index, FileTreeModel::KindRole) == QLatin1String("error") &&
          model.data(index, FileTreeModel::ProblemRole).toString().startsWith(QStringLiteral("Could not list"))) {
        return;
      }
    }
    fail(describeTree(world));
  });
  step(QStringLiteral("the user retries"), [](World& world, const Captures&, const Table&) {
    // What failed is what is retried: the file, the project's listing or a folder's.
    if (files(world).fileStatus() == QLatin1String("error")) {
      files(world).reloadFile();
      world.waitFor([&] { return files(world).fileStatus() != QLatin1String("loading"); }, QStringLiteral("the file to load"));
      return;
    }
    if (tree(world).rootStatus() == QLatin1String("error")) {
      files(world).reload();
    } else {
      FileTreeModel& model = tree(world);
      for (int row = 0; row < model.rowCount(); ++row) {
        const QModelIndex index = model.index(row);
        if (model.data(index, FileTreeModel::KindRole) == QLatin1String("error")) {
          model.retry(model.data(index, FileTreeModel::PathRole).toString());
          break;
        }
      }
    }
    waitForTree(world);
  });
  step(QStringLiteral("the environment cannot list %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.node.part<FakeFiles>().cannotList = true;
  });
  step(QStringLiteral("the environment can list %1 again").arg(q), [](World& world, const Captures&, const Table&) {
    world.node.part<FakeFiles>().cannotList = false;
  });
  step(QStringLiteral("the user opens the Files tab"), [](World& world, const Captures&, const Table&) { openFiles(world); });
  step(QStringLiteral("the user is told the files could not be listed"), [](World& world, const Captures&, const Table&) {
    expect(tree(world).rootStatus() == QLatin1String("error") && tree(world).rootProblem().startsWith(QStringLiteral("Could not list")),
           describeTree(world));
  });
  step(QStringLiteral("the top of %1 is shown").arg(q), [](World& world, const Captures&, const Table&) {
    waitForTree(world);
    expect(tree(world).visiblePaths() == QStringList({QStringLiteral("node_modules"), QStringLiteral("src"), QStringLiteral("README.md")}),
           describeTree(world));
  });
  step(QStringLiteral("the user filters the tree by %1 and hides non-matches").arg(q), [](World& world, const Captures& c, const Table&) {
    openFiles(world);
    files(world).setQuery(c[0]);
    waitForTree(world);
  });
  step(QStringLiteral("only %1 and its folders are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(tree(world).visiblePaths() == withFolders(c[0]), describeTree(world));
  });
  step(QStringLiteral("the user stops filtering"), [](World& world, const Captures&, const Table&) {
    files(world).setQuery({});
    waitForTree(world);
  });
  step(QStringLiteral("the full tree is shown again"), [](World& world, const Captures&, const Table&) {
    expect(!tree(world).filtered() &&
               tree(world).visiblePaths() == QStringList({QStringLiteral("node_modules"), QStringLiteral("src"), QStringLiteral("README.md")}),
           describeTree(world));
  });
  step(QStringLiteral("the user opens %1 from a message").arg(q), [](World& world, const Captures& c, const Table&) { openFile(world, c[0]); });
  step(QStringLiteral("the tree reveals and selects %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tree(world).selectedPath() == c[0]; }, [&] { return describeTree(world); });
    for (const QString& path : withFolders(c[0])) expect(tree(world).visiblePaths().contains(path), describeTree(world));
  });

  // The file viewer.
  step(QStringLiteral("%1 in %1 is 3 MB").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = world.node.part<FakeFiles>();
    fake.files.insert(c[0], linesOf(200));
    fake.truncated.insert(c[0], 3 * 1024 * 1024);
  });
  step(QStringLiteral("the user opens %1").arg(q), [](World& world, const Captures& c, const Table&) { openFile(world, c[0]); });
  step(QStringLiteral("the user opens %1 at line (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    openFile(world, c[0], c[1].toInt());
  });
  step(QStringLiteral("the user is told the preview is limited to the first 1 MB of the file"), [](World& world, const Captures&, const Table&) {
    expect(files(world).truncatedNotice() == QLatin1String("Preview limited to the first 1 MB of a 3,145,728 byte file."),
           QStringLiteral("the viewer says \"%1\"").arg(files(world).truncatedNotice()));
  });
  step(QStringLiteral("%1 has (\\d+) lines").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeFiles>().files.insert(c[0], linesOf(c[1].toInt()));
  });
  step(QStringLiteral("line (\\d+) is revealed"), [](World& world, const Captures& c, const Table&) {
    expect(files(world).revealLine() == c[0].toInt(), QStringLiteral("line %1 is revealed").arg(files(world).revealLine()));
  });
  step(QStringLiteral("the user turns word wrap on for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openFile(world, c[0]);
    files(world).setWrap(true);
  });
  step(QStringLiteral("the user turns word wrap off"), [](World& world, const Captures&, const Table&) { files(world).setWrap(false); });
  // FilesPanel wraps the viewer's lines to its width while `wrap` is on (tst_FilesPanel.qml).
  step(QStringLiteral("long lines wrap"), [](World& world, const Captures&, const Table&) {
    expect(files(world).wrap(), QStringLiteral("the viewer does not wrap"));
  });
  step(QStringLiteral("long lines scroll sideways"), [](World& world, const Captures&, const Table&) {
    expect(!files(world).wrap(), QStringLiteral("the viewer wraps"));
  });
  step(QStringLiteral("reading %1 fails once").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeFiles>().readFailsOnce.insert(c[0]);
  });
  step(QStringLiteral("the user is told the file could not be read"), [](World& world, const Captures&, const Table&) {
    expect(files(world).fileStatus() == QLatin1String("error") && files(world).fileProblem().startsWith(QStringLiteral("Could not read")),
           QStringLiteral("the viewer is %1: %2").arg(files(world).fileStatus(), files(world).fileProblem()));
  });
  step(QStringLiteral("the contents of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString contents = world.node.part<FakeFiles>().files.value(c[0]);
    expect(files(world).openPath() == c[0] && files(world).fileStatus() == QLatin1String("ready") &&
               files(world).lines()->rowCount() == contents.count(QLatin1Char('\n')),
           QStringLiteral("the viewer shows %1 (%2, %3 lines)").arg(files(world).openPath(), files(world).fileStatus()).arg(files(world).lines()->rowCount()));
  });
  step(QStringLiteral("the user closes the file"), [](World& world, const Captures&, const Table&) { files(world).closeFile(); });
  step(QStringLiteral("no file is open and the tree is shown"), [](World& world, const Captures&, const Table&) {
    expect(files(world).openPath().isEmpty() && files(world).fileStatus() == QLatin1String("none") && tree(world).rowCount() > 0,
           QStringLiteral("the viewer shows \"%1\"; %2").arg(files(world).openPath(), describeTree(world)));
    expect(panel(world)->isOpen() && panel(world)->activeTab() == QLatin1String("files"), describePanel(world));
  });

  // The panel and its tabs (layout.feature).
  step(QStringLiteral("the right panel is (open|closed)"), [](World& world, const Captures& c, const Table&) {
    const bool open = c[0] == QLatin1String("open");
    if (!world.checking) panel(world)->setOpen(open);
    world.sync();
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool() == open, describePanel(world));
  });
  step(QStringLiteral("the user toggles the right panel"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.toggle"), QVariantMap());
  });
  step(QStringLiteral("the right panel has %1 and %1 tabs").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : {c[0], c[1]}) panel(world)->addTab(title.toLower());
    expect(tabTitles(world) == QStringList({c[0], c[1]}), describePanel(world));
  });
  step(QStringLiteral("the user switches to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.activate"), QVariantMap{{QStringLiteral("id"), tabIdTitled(world, c[0])}});
  });
  step(QStringLiteral("the %1 tab is active").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == tabIdTitled(world, c[0]), describePanel(world));
  });
  step(QStringLiteral("the user closes the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.close"), QVariantMap{{QStringLiteral("id"), tabIdTitled(world, c[0])}});
  });
  step(QStringLiteral("only the %1 tab remains").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(tabTitles(world) == QStringList{c[0]} && at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == tabIdTitled(world, c[0]),
           describePanel(world));
  });
  // A pull request to show is one linked to the thread (its row's).
  step(QStringLiteral("the thread can show (diff|files|agents|terminal|pull request|previews)"), [](World& world, const Captures& c, const Table&) {
    pagePublishes(world, false, {}, {}, {{QStringLiteral("diff"), true}, {QStringLiteral("files"), true}, {QStringLiteral("terminal"), true}, {QStringLiteral("pullRequest"), true}});
    if (c[0] == QLatin1String("pull request")) linkPullRequests(world, 1);
  });
  step(QStringLiteral("the thread has no pull request"), [](World& world, const Captures&, const Table&) {
    pagePublishes(world, false, {}, {}, {{QStringLiteral("diff"), true}, {QStringLiteral("files"), true}, {QStringLiteral("terminal"), true}, {QStringLiteral("pullRequest"), false}});
    linkPullRequests(world, 0);
  });
  step(QStringLiteral("the user adds an? (diff|files|agents|terminal|pull request|previews) tab to the right panel"), [](World& world, const Captures& c, const Table&) {
    const QString kind = kKinds.value(c[0]);
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("canAdd.") + (kind == QLatin1String("pull-requests") ? QStringLiteral("pullRequests") : kind)).toBool(),
           describePanel(world));
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), kind}});
    world.sync();
    // The page adds its own tabs and shows the one it added, as ChatView does.
    for (const PageAction& action : world.actionsOf(QStringLiteral("rightPanel.add"))) {
      const QString added = action.payload.value(QStringLiteral("kind")).toString();
      const QString id = added == QLatin1String("terminal") ? QStringLiteral("terminal:default") : added;
      pagePublishes(world, true, id, {QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("kind"), added}, {QStringLiteral("title"), added == QLatin1String("terminal") ? QStringLiteral("Terminal") : QStringLiteral("Pull request")}}},
                    {{QStringLiteral("diff"), true}, {QStringLiteral("files"), true}, {QStringLiteral("terminal"), true}, {QStringLiteral("pullRequest"), true}});
    }
  });
  step(QStringLiteral("an? (diff|files|agents|terminal|pull request|previews) tab opens in the right panel"), [](World& world, const Captures& c, const Table&) {
    const QString kind = kKinds.value(c[0]);
    const QVariant state = world.state(QStringLiteral("panel"));
    const QString active = at(state, QStringLiteral("activeId")).toString();
    bool shown = false;
    for (const QVariant& tab : at(state, QStringLiteral("tabs")).toList()) {
      shown = shown || (at(tab, QStringLiteral("id")) == active && at(tab, QStringLiteral("kind")) == kind);
    }
    expect(at(state, QStringLiteral("isOpen")).toBool() && shown, describePanel(world));
  });
  step(QStringLiteral("the user looks at what can be added to the right panel"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("pull request cannot be added"), [](World& world, const Captures&, const Table&) {
    expect(!at(world.state(QStringLiteral("panel")), QStringLiteral("canAdd.pullRequests")).toBool() &&
               at(world.state(QStringLiteral("panel")), QStringLiteral("canAdd.diff")).toBool(),
           describePanel(world));
  });
});

}  // namespace
