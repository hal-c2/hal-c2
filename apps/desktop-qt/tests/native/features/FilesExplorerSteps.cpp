// The Files tab's tree beyond browsing (features/files/file-explorer.feature):
// every folder at once, following the agent's changes, and what a file's entry
// offers (FileActionsController). PanelSteps.cpp has the browsing itself.

#include <QQuickItem>

#include "Brick.h"
#include "ComposerController.h"
#include "FilesWorkspace.h"
#include "NavigationController.h"

namespace {

using namespace filesteps;

struct Explorer {
  // The file the user last chose something for.
  QString chosen;
};

QString composerText(World& world) {
  return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("text")).toString();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user expands every folder"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.brick->click(QStringLiteral("filesExpandAll"));
    waitForTree(world);
  });
  step(QStringLiteral("%1 is visible").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForTree(world);
    const QStringList shown = tree(world).visiblePaths();
    expect(std::any_of(shown.cbegin(), shown.cend(), [&](const QString& path) { return path.section(QLatin1Char('/'), -1) == c[0]; }) &&
               tree(world).allExpanded(),
           describeTree(world));
    // Ignored folders stay closed.
    for (const QString& path : shown) {
      for (const QString& ignored : std::as_const(fakeFiles(world.mc).ignored)) {
        expect(!path.startsWith(ignored + QLatin1Char('/')), describeTree(world));
      }
    }
  });
  step(QStringLiteral("the user collapses every folder"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("filesExpandAll"));
  });
  step(QStringLiteral("only the top level is visible"), [](World& world, const Captures&, const Table&) {
    const QStringList shown = tree(world).visiblePaths();
    expect(!shown.isEmpty() && !tree(world).allExpanded() &&
               std::none_of(shown.cbegin(), shown.cend(), [](const QString& path) { return path.contains(QLatin1Char('/')); }),
           describeTree(world));
  });

  // The user has the file's folder open when the agent's change lands.
  step(QStringLiteral("the agent creates %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openFilesTab(world);
    const QString folder = c[0].section(QLatin1Char('/'), 0, -2);
    if (!folder.isEmpty()) tree(world).expand(folder);
    waitForTree(world);
    expect(!tree(world).visiblePaths().contains(c[0]), describeTree(world));
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("export const checkout = true;\n"));
    stream::startRun(world);
    stream::addItem(world, QStringLiteral("file_change"), {{QStringLiteral("changes"), QJsonArray{QJsonObject{{QStringLiteral("path"), c[0]}}}}});
  });
  step(QStringLiteral("%1 appears in the tree").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return tree(world).visiblePaths().contains(c[0]); }, [&] { return describeTree(world); });
  });

  step(QStringLiteral("the user adds %1 to the chat").arg(q), [](World& world, const Captures& c, const Table&) {
    // With no chat open the Files tab is not on screen; the action is what is left to ask.
    if (world.state(QStringLiteral("composer")).isNull()) {
      world.bridge().dispatch(QStringLiteral("files.addToChat"), QVariantMap{{QStringLiteral("path"), c[0]}});
    } else {
      choose(world, c[0], QStringLiteral("fileEntryAddToChat"));
    }
  });
  step(QStringLiteral("the composer mentions %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString mention = QStringLiteral("[%1](%2) ").arg(c[0].section(QLatin1Char('/'), -1), c[0]);
    world.waitFor([&] { return composerText(world) == mention; }, [&] { return QStringLiteral("the mention; the composer has \"%1\"").arg(composerText(world)); });
  });
  step(QStringLiteral("no chat is open for %1").arg(q), [](World& world, const Captures&, const Table&) {
    // Away from every thread and draft: the settings.
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
    world.sync();
    expect(world.state(QStringLiteral("composer")).isNull(), QStringLiteral("a composer is open: %1").arg(show(world.state(QStringLiteral("composer")))));
  });
  step(QStringLiteral("the user is told to open a chat for this project and try again"), [](World& world, const Captures&, const Table&) {
    const auto told = [&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (at(toast, QStringLiteral("type")) == QLatin1String("error") && at(toast, QStringLiteral("title")) == QLatin1String("Unable to add to chat") &&
            at(toast, QStringLiteral("description")) == QLatin1String("Open a chat for this project and try again.")) {
          return true;
        }
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("the toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });

  step(QStringLiteral("the user chooses to (open|reveal in its folder|open with the editor|copy a mention of) %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.mc.part<Explorer>().chosen = c[1];
         if (c[0] == QLatin1String("open")) {
           choose(world, c[1], QStringLiteral("fileEntryOpen"));
         } else if (c[0] == QLatin1String("copy a mention of")) {
           choose(world, c[1], QStringLiteral("fileEntryCopyMention"));
         } else {
           // The environment has an editor and a file manager that can select a file.
           setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")}},
                             {QStringLiteral("shellRevealInFileManager"), true}});
           choose(world, c[1], c[0] == QLatin1String("reveal in its folder") ? QStringLiteral("fileEntryReveal") : QStringLiteral("fileEntryEditor-vscode"));
         }
       });
  step(QStringLiteral("the file opens in the viewer"), [](World& world, const Captures&, const Table&) {
    const QString chosen = world.mc.part<Explorer>().chosen;
    world.waitFor([&] { return files(world).openPath() == chosen && files(world).fileStatus() == QLatin1String("ready"); },
                  [&] { return QStringLiteral("%1 in the viewer; it has \"%2\" (%3)").arg(chosen, files(world).openPath(), files(world).fileStatus()); });
  });
  step(QStringLiteral("the system file manager shows the file"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> calls = editorCalls(world);
    const QJsonObject wanted{{QStringLiteral("cwd"), workspaceRoot(world) + QLatin1Char('/') + world.mc.part<Explorer>().chosen},
                             {QStringLiteral("editor"), QStringLiteral("file-manager")}, {QStringLiteral("reveal"), true}};
    expect(calls.size() == 1 && calls.first() == wanted, QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
  });
  step(QStringLiteral("the file opens in the user's editor"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> calls = editorCalls(world);
    // The explorer's file in VS Code, or the changed file another surface opened.
    const OpenedInEditor other = world.mc.part<OpenedInEditor>();
    const QJsonObject wanted{{QStringLiteral("cwd"), workspaceRoot(world) + QLatin1Char('/') + (other.path.isEmpty() ? world.mc.part<Explorer>().chosen : other.path)},
                             {QStringLiteral("editor"), other.path.isEmpty() ? QStringLiteral("vscode") : other.editor}};
    expect(calls.size() == 1 && calls.first() == wanted, QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
  });
  step(QStringLiteral("a mention of %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.clipboard == QStringLiteral("[%1](%2)").arg(c[0].section(QLatin1Char('/'), -1), c[0]),
           QStringLiteral("the clipboard has \"%1\"").arg(world.clipboard));
  });
});

}  // namespace
