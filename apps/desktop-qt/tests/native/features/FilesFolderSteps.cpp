// Managing folders on disk (features/files/folder-operations.feature) and
// dragging a folder over the window (files/adding-projects.feature): the
// FolderExplorer and ProjectFolderDrop bricks as DefaultShell places them,
// over real folders under the scenario's home. The paths a scenario names
// ("/home/sam/code") live under that home; the system Trash is a folder there.

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QDragEnterEvent>
#include <QDragLeaveEvent>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QMimeData>
#include <QQuickItem>
#include <QtQml/qqml.h>

#include "Brick.h"
#include "FilesFolders.h"
#include "FoldersController.h"
#include "Harness.h"
#include "LocalFolderModel.h"
#include "McClient.h"
#include "Stream.h"
#include "World.h"

namespace {

struct Folders {
  // The folder the user manages, as this machine names it.
  QString root;
  QString trash;
  bool trashUnavailable = false;
  // The disk under the managed folder before the operation under test.
  QStringList before;
  // The menu entry the user tried, for a folder it is not offered for.
  QString tried;
  // What the last drag over the window was answered with.
  bool dragAccepted = false;
};

Folders& folders(World& world) {
  return world.mc.part<Folders>();
}

// Where the scenario's machine keeps `path` ("/home/sam/code").
QString base(World& world) {
  const QString files = world.homeDir() + QStringLiteral("/files");
  QDir().mkpath(files);
  return QFileInfo(files).canonicalFilePath();
}

QString local(World& world, const QString& path) {
  return QDir::cleanPath(base(world) + path);
}

// A name under the managed folder, or a full path.
QString resolve(World& world, const QString& name) {
  return name.startsWith(QLatin1Char('/')) ? local(world, name) : QDir(folders(world).root).filePath(name);
}

void makeFile(const QString& path) {
  QDir().mkpath(QFileInfo(path).absolutePath());
  QFile file(path);
  expect(file.open(QIODevice::WriteOnly), QStringLiteral("cannot write %1").arg(path));
  file.write("kept\n");
}

QStringList listing(const QString& root) {
  QStringList paths;
  QDirIterator it(root, QDir::AllEntries | QDir::NoDotAndDotDot | QDir::System, QDirIterator::Subdirectories);
  while (it.hasNext()) paths.append(QDir(root).relativeFilePath(it.next()));
  paths.sort();
  return paths;
}

QQuickItem* explorer(World& world) {
  expect(world.brick != nullptr, QStringLiteral("the folder explorer is not open"));
  return world.brick->item(QStringLiteral("folderExplorer"));
}

// The explorer as DefaultShell shows it: made when `folders.toggle` opens it,
// gone when it closes.
void openExplorer(World& world) {
  if (world.state(QStringLiteral("folders")).toMap().value(QStringLiteral("open")).toBool()) {
    world.bridge().dispatch(FoldersController::kToggle, QVariantMap{});
    world.brick.reset();
  }
  world.bridge().dispatch(FoldersController::kToggle, QVariantMap{});
  expect(world.state(QStringLiteral("folders")).toMap().value(QStringLiteral("open")).toBool(), QStringLiteral("the folder explorer did not open"));
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                               "FolderExplorer { visible: Shell.state.folders?.open ?? false }\n",
                                        QSize(420, 760));
}

// A part of the explorer or of its dialog, which is the overlay's only while it is open.
QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* found = world.brick->root()->findChild<QQuickItem*>(objectName);
  expect(found != nullptr, QStringLiteral("the explorer has no %1").arg(objectName));
  return found;
}

QString text(World& world, const QString& objectName) {
  const QQuickItem* label = part(world, objectName);
  return label->isVisible() ? label->property("text").toString() : QString();
}

QString describe(World& world) {
  return QStringLiteral("the explorer (local %6, visible %7) shows \"%1\" (selected \"%2\"), says \"%3\", hints \"%4\" and its dialog says \"%5\"")
      .arg(explorer(world)->property("rootPath").toString(), explorer(world)->property("selectedPath").toString(),
           text(world, QStringLiteral("folderExplorerStatus")), text(world, QStringLiteral("folderExplorerHint")),
           text(world, QStringLiteral("folderOperationError")))
      .arg(explorer(world)->property("localAccess").toBool())
      .arg(explorer(world)->isVisible());
}

void select(World& world, const QString& path) {
  explorer(world)->setProperty("selectedPath", path == explorer(world)->property("rootPath").toString() ? QString() : path);
}

bool offered(World& world, const QString& operation) {
  // The menu's entries follow these.
  return explorer(world)->property(operation == QLatin1String("create") ? "directorySelected" : "canModifySelection").toBool();
}

QObject* dialog(World& world) {
  QObject* found = world.brick->window().findChild<QObject*>(QStringLiteral("folderOperationDialog"));
  if (!found) found = explorer(world)->findChild<QObject*>(QStringLiteral("folderOperationDialog"));
  expect(found != nullptr, QStringLiteral("the explorer has no operation dialog"));
  return found;
}

// Chooses create, rename, move or trash for `path` from its menu.
void begin(World& world, const QString& operation, const QString& path) {
  select(world, path);
  expect(offered(world, operation), QStringLiteral("%1 is not offered for %2; %3").arg(operation, path, describe(world)));
  folders(world).before = listing(folders(world).root);
  QMetaObject::invokeMethod(explorer(world), "beginOperation", Q_ARG(QVariant, operation));
  world.waitFor([&] { return dialog(world)->property("opened").toBool(); }, QStringLiteral("the folder dialog to open"));
}

void type(World& world, const QString& entry) {
  part(world, QStringLiteral("folderOperationInput"))->setProperty("text", entry);
}

void confirm(World& world) {
  world.brick->click(QStringLiteral("folderOperationConfirm"));
}

void run(World& world, const QString& operation, const QString& path, const QString& entry) {
  begin(world, operation, path);
  type(world, entry);
  confirm(world);
}

void expectFinished(World& world) {
  world.waitFor([&] { return !dialog(world)->property("visible").toBool(); }, [&] { return QStringLiteral("the folder dialog to close; ") + describe(world); });
}

// A project of this machine at `path`.
void registerProject(World& world, const QString& path) {
  QDir().mkpath(path);
  const QString id = QFileInfo(path).fileName();
  const QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("workspaceRoot"), path},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("scripts"), QJsonArray()}};
  world.mc.projects.insert(id, row);
  world.mc.sendRow(id, row, QStringLiteral("project"));
  world.sync();
}

// --- Dragging over the window ---------------------------------------------------------

void drag(World& world, const QList<QUrl>& urls) {
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nProjectFolderDrop { objectName: \"folderDrop\" }\n", QSize(900, 700));
  QMimeData data;
  data.setUrls(urls);
  QDragEnterEvent enter(QPoint(450, 350), Qt::CopyAction, &data, Qt::LeftButton, Qt::NoModifier);
  enter.ignore();
  QCoreApplication::sendEvent(&world.brick->window(), &enter);
  folders(world).dragAccepted = enter.isAccepted();
  // The overlay is read while the drag is over the window; the drag's data is gone after.
  world.brick->grab();
}

void tryOperation(World& world, const QString& operation, const QString& folder) {
  folders(world).before = listing(folders(world).root);
  select(world, local(world, folder));
  folders(world).tried = operation;
}

}  // namespace

bool renameManagedFolder(World& world, const QString& folder, const QString& name) {
  if (folders(world).root.isEmpty()) return false;
  run(world, QStringLiteral("rename"), resolve(world, folder), name);
  expectFinished(world);
  return true;
}

bool tryMoveManagedFolder(World& world, const QString& folder) {
  if (folders(world).root.isEmpty()) return false;
  tryOperation(world, QStringLiteral("move"), folder);
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;
  static const bool registered = [] {
    qmlRegisterType<LocalFolderModel>("HalC2.Shell", 1, 0, "LocalFolderModel");
    return true;
  }();
  Q_UNUSED(registered);
  // A full path on the scenario's machine.
  const QString path = QStringLiteral("\"(/[^\"]*)\"");

  step(QStringLiteral("the user manages (?:the folder )?%1").arg(path), [](World& world, const Captures& c, const Table&) {
    Folders& state = folders(world);
    if (state.root.isEmpty()) {
      state.root = local(world, c[0]);
      for (const QString& folder : {QStringLiteral("old"), QStringLiteral("tmp"), QStringLiteral("archive/2025"), QStringLiteral("shop/tmp")}) {
        QDir(state.root).mkpath(folder);
      }
      makeFile(QDir(state.root).filePath(QStringLiteral("notes.txt")));
      state.trash = base(world) + QStringLiteral("/.Trash");
      QDir().mkpath(state.trash);
      World* self = &world;
      LocalFolderModel::setTrash([self](const QString& source) {
        const Folders& state = folders(*self);
        return !state.trashUnavailable && QDir().rename(source, QDir(state.trash).filePath(QFileInfo(source).fileName()));
      });
      openExplorer(world);
    }
    world.waitFor([&] { return explorer(world)->property("localAccess").toBool(); }, QStringLiteral("the explorer to see the local environment"));
    QMetaObject::invokeMethod(explorer(world), "openRoot", Q_ARG(QVariant, state.root));
    expect(explorer(world)->property("rootPath").toString() == state.root, describe(world));
  });

  step(QStringLiteral("the desktop app shows an environment on another machine"), [](World& world, const Captures&, const Table&) {
    // As main.cpp starts a shell attached to an MC elsewhere.
    world.bridge().setLocalFolderImportEnabled(false);
    world.bridge().setMcOrigin(QUrl(QStringLiteral("https://mc-b.example.ts.net")));
    if (world.brick) {
      world.bridge().dispatch(FoldersController::kToggle, QVariantMap{{QStringLiteral("open"), false}});
      world.brick.reset();
    }
  });
  step(QStringLiteral("the user opens the folder explorer"), [](World& world, const Captures&, const Table&) { openExplorer(world); });
  step(QStringLiteral("the user is told folder management needs a connected local environment"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderExplorerUnavailable")).startsWith(QStringLiteral("Folder management is available only for a connected local environment")),
           describe(world));
    expect(!offered(world, QStringLiteral("create")) && !offered(world, QStringLiteral("rename")), QStringLiteral("folders can still be changed"));
  });
  step(QStringLiteral("the user is looking at a thread in the project at %1").arg(path), [](World& world, const Captures& c, const Table&) {
    registerProject(world, local(world, c[0]));
    stream::lookAtThread(world, QFileInfo(c[0]).fileName());
  });
  step(QStringLiteral("the explorer shows %1").arg(path), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return explorer(world)->property("rootPath").toString() == local(world, c[0]); }, [&] { return describe(world); });
  });

  step(QStringLiteral("the user chooses to manage (the home folder|the filesystem root|a link to another folder|a folder that does not exist)"),
       [](World& world, const Captures& c, const Table&) {
         QString chosen = QDir::homePath();
         if (c[0] == QLatin1String("the filesystem root")) chosen = QDir::rootPath();
         if (c[0] == QLatin1String("a folder that does not exist")) chosen = local(world, QStringLiteral("/home/sam/missing"));
         if (c[0] == QLatin1String("a link to another folder")) {
           chosen = local(world, QStringLiteral("/home/sam/link"));
           expect(QFile::link(folders(world).root, chosen), QStringLiteral("cannot link %1").arg(chosen));
         }
         QMetaObject::invokeMethod(explorer(world), "openRoot", Q_ARG(QVariant, chosen));
       });
  step(QStringLiteral("the user is told to choose an existing local folder other than home or a filesystem root"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderExplorerStatus")).startsWith(QStringLiteral("Choose an existing local folder other than your home or a filesystem root.")) &&
               explorer(world)->property("rootPath").toString().isEmpty(),
           describe(world));
  });

  step(QStringLiteral("the user selects the file %1").arg(q), [](World& world, const Captures& c, const Table&) {
    select(world, resolve(world, c[0]));
  });
  step(QStringLiteral("the user is told files are shown read-only"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderExplorerHint")).startsWith(QStringLiteral("Files are shown read-only.")), describe(world));
    for (const QString& operation : {QStringLiteral("create"), QStringLiteral("rename")}) {
      expect(!offered(world, operation), QStringLiteral("%1 is offered for a file").arg(operation));
    }
  });

  // Creating, renaming and moving.
  step(QStringLiteral("the user creates the folder %1 in %2").arg(q, path), [](World& world, const Captures& c, const Table&) {
    run(world, QStringLiteral("create"), local(world, c[1]), c[0]);
    expectFinished(world);
  });
  step(QStringLiteral("%1 holds %2").arg(path, q), [](World& world, const Captures& c, const Table&) {
    makeFile(local(world, c[0]) + QLatin1Char('/') + c[1]);
  });
  step(QStringLiteral("the user moves %1 into %2").arg(q, path), [](World& world, const Captures& c, const Table&) {
    QDir().mkpath(local(world, c[1]));
    run(world, QStringLiteral("move"), resolve(world, c[0]), local(world, c[1]));
  });
  step(QStringLiteral("%1 exists").arg(path), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return QFileInfo::exists(local(world, c[0])); }, [&] { return QStringLiteral("%1; %2").arg(c[0], describe(world)); });
  });
  step(QStringLiteral("%1 does not exist").arg(path), [](World& world, const Captures& c, const Table&) {
    expect(!QFileInfo::exists(local(world, c[0])), QStringLiteral("%1 is still there").arg(c[0]));
  });
  step(QStringLiteral("%1 still exists").arg(path), [](World& world, const Captures& c, const Table&) {
    expect(QFileInfo(local(world, c[0])).isDir(), QStringLiteral("%1 is gone; %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("the user is told the folder was updated on disk"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderExplorerStatus")) == QLatin1String("Folder updated on disk."), describe(world));
  });
  step(QStringLiteral("the user is told a folder cannot be moved into itself or one of its descendants"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderOperationError")) == QLatin1String("A folder cannot be moved into itself or one of its descendants.") &&
               dialog(world)->property("visible").toBool(),
           describe(world));
  });

  // Names that would overwrite or escape.
  step(QStringLiteral("the user creates a folder using %1").arg(q), [](World& world, const Captures& c, const Table&) {
    run(world, QStringLiteral("create"), folders(world).root, c[0]);
  });
  step(QStringLiteral("the user renames %1 using %1").arg(q), [](World& world, const Captures& c, const Table&) {
    run(world, QStringLiteral("rename"), resolve(world, c[0]), c[1]);
  });
  // The folder moved into already holds one of that name.
  step(QStringLiteral("the user moves %1 into a folder using %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QDir(resolve(world, c[1])).mkpath(c[0]);
    run(world, QStringLiteral("move"), resolve(world, c[0]), resolve(world, c[1]));
  });
  step(QStringLiteral("nothing on disk changes"), [](World& world, const Captures&, const Table&) {
    const QStringList now = listing(folders(world).root);
    expect(now == folders(world).before, QStringLiteral("the disk went from [%1] to [%2]").arg(folders(world).before.join(u", "), now.join(u", ")));
  });

  // Projects keep their place.
  step(QStringLiteral("%1 is a registered project").arg(path), [](World& world, const Captures& c, const Table&) {
    registerProject(world, local(world, c[0]));
  });
  step(QStringLiteral("the user tries to (rename|move to the Trash) %1").arg(path), [](World& world, const Captures& c, const Table&) {
    tryOperation(world, c[0] == QLatin1String("rename") ? c[0] : QStringLiteral("trash"), c[1]);
  });
  step(QStringLiteral("the user is told the location is protected because threads may still use that path"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return text(world, QStringLiteral("folderExplorerHint")).contains(QStringLiteral("Its location is protected because threads may still use that path.")); },
                  [&] { return describe(world); });
    // The entry is there and cannot be chosen.
    QObject* entry = explorer(world)->findChild<QObject*>(folders(world).tried + QStringLiteral("FolderMenuItem"));
    expect(entry != nullptr && !entry->property("enabled").toBool(), QStringLiteral("%1 can be chosen").arg(folders(world).tried));
    expect(listing(folders(world).root) == folders(world).before, QStringLiteral("the disk changed"));
  });

  // The Trash.
  step(QStringLiteral("the user asks to move %1 to the Trash").arg(q), [](World& world, const Captures& c, const Table&) {
    begin(world, QStringLiteral("trash"), resolve(world, c[0]));
  });
  step(QStringLiteral("the user is told it moves the folder to the system Trash and keeps projects and conversations"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->shows(QStringLiteral("This moves the folder and everything inside it to your system Trash. It does not remove a project or "
                                             "its conversations from HAL-C2. Type the folder name to confirm.")),
           describe(world));
  });
  step(QStringLiteral("the Trash cannot be confirmed until the user types %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QQuickItem* button = part(world, QStringLiteral("folderOperationConfirm"));
    expect(!button->isEnabled(), QStringLiteral("the Trash can be confirmed with nothing typed"));
    type(world, c[0] + QStringLiteral("x"));
    expect(!button->isEnabled(), QStringLiteral("the Trash can be confirmed with another name"));
    type(world, c[0]);
    expect(button->isEnabled(), QStringLiteral("the Trash cannot be confirmed with the folder's name"));
  });
  step(QStringLiteral("the user moves %1 to the Trash and confirms with its name").arg(q), [](World& world, const Captures& c, const Table&) {
    run(world, QStringLiteral("trash"), resolve(world, c[0]), c[0]);
  });
  step(QStringLiteral("%1 is in the system Trash").arg(path), [](World& world, const Captures& c, const Table&) {
    expectFinished(world);
    expect(!QFileInfo::exists(local(world, c[0])) && QFileInfo(QDir(folders(world).trash).filePath(QFileInfo(c[0]).fileName())).isDir(),
           QStringLiteral("the Trash holds [%1]; %2").arg(listing(folders(world).trash).join(u", "), describe(world)));
  });
  step(QStringLiteral("the user is told the folder moved to the system Trash"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderExplorerStatus")) == QLatin1String("Folder moved to system Trash."), describe(world));
  });
  step(QStringLiteral("the system Trash is unavailable"), [](World& world, const Captures&, const Table&) {
    folders(world).trashUnavailable = true;
  });
  step(QStringLiteral("the user is told it could not be moved and was not permanently deleted"), [](World& world, const Captures&, const Table&) {
    expect(text(world, QStringLiteral("folderOperationError")) ==
               QLatin1String("The folder could not be moved to the system trash. It has not been permanently deleted."),
           describe(world));
  });
  step(QStringLiteral("the user starts renaming %1 and cancels").arg(q), [](World& world, const Captures& c, const Table&) {
    begin(world, QStringLiteral("rename"), resolve(world, c[0]));
    type(world, QStringLiteral("renamed"));
    world.brick->click(QStringLiteral("folderOperationCancel"));
    expectFinished(world);
    expect(listing(folders(world).root) == folders(world).before, QStringLiteral("the disk changed"));
  });

  step(QStringLiteral("%1 is replaced by a link to another folder").arg(path), [](World& world, const Captures& c, const Table&) {
    const QString root = local(world, c[0]);
    const QString moved = root + QStringLiteral("-moved");
    expect(QDir().rename(root, moved) && QFile::link(moved, root), QStringLiteral("cannot replace %1 by a link").arg(root));
  });
  step(QStringLiteral("the user is told the selected root is no longer a plain local folder"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return text(world, QStringLiteral("folderExplorerStatus")) == QLatin1String("The selected root is no longer a plain local folder."); },
                  [&] { return describe(world); });
    expect(explorer(world)->property("rootPath").toString().isEmpty() && !offered(world, QStringLiteral("create")), describe(world));
  });

  step(QStringLiteral("the user opens %1 as a project").arg(path), [](World& world, const Captures& c, const Table&) {
    const QString folder = local(world, c[0]);
    QDir().mkpath(folder);
    select(world, folder);
    QObject* entry = explorer(world)->findChild<QObject*>(QStringLiteral("openFolderProjectMenuItem"));
    expect(entry != nullptr && entry->property("enabled").toBool(), QStringLiteral("the folder cannot be opened as a project; %1").arg(describe(world)));
    QMetaObject::invokeMethod(entry, "triggered");
  });
  step(QStringLiteral("the project %1 is listed").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto names = [&] {
      QStringList found;
      for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList()) {
        found.append(project.toMap().value(QStringLiteral("displayName")).toString());
      }
      return found;
    };
    world.waitFor([&] { return names().contains(c[0]); }, [&] { return QStringLiteral("%1; the sidebar lists %2").arg(c[0], names().join(u", ")); });
  });

  // Dragging over the window.
  step(QStringLiteral("the user drags the folder %1 over the window").arg(path), [](World& world, const Captures& c, const Table&) {
    QDir().mkpath(local(world, c[0]));
    drag(world, {QUrl::fromLocalFile(local(world, c[0]))});
  });
  step(QStringLiteral("the user drags (a file|two folders|a link to a remote location|a local folder) over the window"), [](World& world, const Captures& c, const Table&) {
    const QString one = local(world, QStringLiteral("/home/sam/one"));
    const QString two = local(world, QStringLiteral("/home/sam/two"));
    QDir().mkpath(one);
    QDir().mkpath(two);
    makeFile(one + QStringLiteral("/notes.txt"));
    QList<QUrl> urls{QUrl::fromLocalFile(one)};
    if (c[0] == QLatin1String("a file")) urls = {QUrl::fromLocalFile(one + QStringLiteral("/notes.txt"))};
    if (c[0] == QLatin1String("two folders")) urls.append(QUrl::fromLocalFile(two));
    if (c[0] == QLatin1String("a link to a remote location")) urls = {QUrl(QStringLiteral("https://example.com/shop"))};
    drag(world, urls);
  });
  step(QStringLiteral("the user is told the folder opens as a project"), [](World& world, const Captures&, const Table&) {
    const QQuickItem* drop = world.brick->item(QStringLiteral("folderDrop"));
    const QString folder = drop->property("directoryPath").toString();
    expect(folders(world).dragAccepted && !folder.isEmpty() &&
               world.brick->shows(QStringLiteral("Open folder as a project\n%1\nNo files will be moved or deleted.").arg(folder)),
           QStringLiteral("the drag was %1 for \"%2\"").arg(folders(world).dragAccepted ? u"taken" : u"refused", folder));
  });
  step(QStringLiteral("the user is told no files will be moved or deleted"), [](World& world, const Captures&, const Table&) {
    const QString folder = world.brick->item(QStringLiteral("folderDrop"))->property("directoryPath").toString();
    expect(world.brick->shows(QStringLiteral("Open folder as a project\n%1\nNo files will be moved or deleted.").arg(folder)),
           QStringLiteral("the window does not say files are kept"));
  });
  step(QStringLiteral("the drop is refused"), [](World& world, const Captures&, const Table&) {
    const QQuickItem* drop = world.brick->item(QStringLiteral("folderDrop"));
    expect(!folders(world).dragAccepted && drop->property("directoryPath").toString().isEmpty(),
           QStringLiteral("the drag was taken for \"%1\"").arg(drop->property("directoryPath").toString()));
    world.sync();
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      expect(rpc.method != QLatin1String("projects.mutate"), QStringLiteral("a project was changed"));
    }
  });
});

}  // namespace
