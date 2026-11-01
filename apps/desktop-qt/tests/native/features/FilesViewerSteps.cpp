// The file viewer beyond reading (features/files/file-viewer-and-editing.feature):
// rendered files and their source, the path trail, opening in an editor, and
// editing with its saves, on the Files tab as the right panel draws it.
// PanelSteps.cpp has opening, wrapping and retrying. The MC's
// `projects.writeFile` is faked here.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "CommandRegistry.h"
#include "FilesViewer.h"
#include "FilesWorkspace.h"
#include "KeybindingController.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Space.h"

namespace {

using namespace filesteps;

struct Viewer {
  // Paths the MC refuses to write.
  QSet<QString> unwritable;
  // The session lacks terminal:operate, so the MC refuses writes by full path.
  bool noTerminal = false;
  // The file the scenario edits, and what the user typed into it.
  QString edited;
  QString typed;
  // The file opened by a description ("a file larger than one megabyte").
  QString described;
  // How many times the MC had been asked to open an editor before the step under test.
  qsizetype editorCallsBefore = 0;
  // What the path trail's folder is to be when it is opened: empty, gone or partial.
  QString trailState;
  // What a file went through after an older read was let go.
  QStringList seen;
  QString rewritten;
  bool savedEarly = false;
  qsizetype signingsBefore = 0;
};

Viewer& viewer(World& world) {
  return world.mc.part<Viewer>();
}

void answerWrite(FakeMc& mc, const FakeMc::Rpc& rpc);

const FakeMc::Extension extension([](FakeMc& mc) {
  // As apps/server-ex lib/hal_c2/workspace.ex write_file: the file's new contents.
  mc.onRpc(QStringLiteral("projects.writeFile"), [&mc](const FakeMc::Rpc& rpc) {
    if (mc.holding(QStringLiteral("write"))) {
      mc.defer([&mc, rpc] { answerWrite(mc, rpc); });
    } else {
      answerWrite(mc, rpc);
    }
  });
});

void answerWrite(FakeMc& mc, const FakeMc::Rpc& rpc) {
    const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
    if (mc.part<Viewer>().unwritable.contains(path)) {
      mc.refuse(rpc, QStringLiteral("Could not write %1.").arg(path));
      return;
    }
    FakeFiles& fake = fakeFiles(mc);
    const QString contents = rpc.payload.value(QLatin1String("contents")).toString();
    if (path.startsWith(QLatin1Char('/')) && mc.part<Viewer>().noTerminal) {
      // As apps/server-ex lib/hal_c2/rpc.ex required_scope/2, checked by the socket.
      mc.refuse(rpc, QStringLiteral("terminal:operate is required"),
                QJsonObject{{QStringLiteral("_tag"), QStringLiteral("EnvironmentScopeRequiredError")},
                            {QStringLiteral("requiredScope"), QStringLiteral("terminal:operate")}});
      return;
    }
    if (!path.startsWith(QLatin1Char('/'))) {
      fake.files.insert(path, contents);
    } else if (fake.outside.contains(path)) {
      // By its full path, only a file that is already there.
      fake.outside.insert(path, contents);
    } else {
      mc.refuse(rpc, QStringLiteral("'%1' is outside the workspace, where only a file that is already there can be saved.").arg(path));
      return;
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativePath"), path}});
}

QList<QJsonObject> writes(World& world) {
  QList<QJsonObject> calls;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("projects.writeFile")) calls.append(rpc.payload);
  }
  return calls;
}

QString describeViewer(World& world) {
  return QStringLiteral("the viewer has \"%1\" (%2, %3%4%5), note \"%6\"")
      .arg(files(world).openPath(), files(world).fileStatus(), files(world).renderKind().isEmpty() ? QStringLiteral("text") : files(world).renderKind(),
           files(world).rendered() ? QStringLiteral(", rendered") : QString(), files(world).editing() ? QStringLiteral(", editing") : QString(),
           files(world).saveProblem().isEmpty() ? files(world).readOnlyReason() : files(world).saveProblem());
}

// Whether the panel draws its part named `objectName` (one a Loader makes may not be there yet).
bool shown(World& world, const QString& objectName) {
  const std::function<const QQuickItem*(const QQuickItem*)> find = [&](const QQuickItem* item) -> const QQuickItem* {
    if (item->objectName() == objectName) return item;
    for (const QQuickItem* child : item->childItems()) {
      if (const QQuickItem* found = find(child)) return found;
    }
    return nullptr;
  };
  const QQuickItem* found = find(world.brick->window().contentItem());
  return found && found->isVisible();
}

// Whether the shell shows copying's "File contents copied" toast, saying `description`.
bool toldCopied(World& world, const QString& description) {
  for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
    if (at(toast, QStringLiteral("type")) == QLatin1String("success") && at(toast, QStringLiteral("title")) == QLatin1String("File contents copied") &&
        at(toast, QStringLiteral("description")).toString() == description) {
      return true;
    }
  }
  return false;
}

// The file in the viewer, with the panel on screen.
void view(World& world, const QString& path) {
  ensureViewerFile(world, path);
  showPanel(world);
  openFile(world, path);
  waitForTree(world);
}

void startEditing(World& world, const QString& path) {
  view(world, path);
  // A rendered file is edited as its source.
  world.brick->click(QStringLiteral("fileEdit"));
  world.waitFor([&] { return files(world).editing() && shown(world, QStringLiteral("fileEditor")); }, [&] { return describeViewer(world); });
  viewer(world).edited = path;
}

// Types into the editor as the user does.
void typeChange(World& world) {
  const QString typed = QStringLiteral("edited by hand ");
  world.brick->click(QStringLiteral("fileEditorView"));
  QQuickItem* editor = world.brick->item(QStringLiteral("fileEditor"));
  expect(editor->hasActiveFocus(), QStringLiteral("the editor did not take the keyboard"));
  for (const QChar character : typed) QTest::keyClick(&world.brick->window(), character.toLatin1());
  viewer(world).typed = typed;
  expect(files(world).text().contains(typed), describeViewer(world));
}

// The link of the task named `task` in what the rendered view draws.
QString taskLink(World& world, const QString& task) {
  static const QRegularExpression link(QStringLiteral("\\[[☐☑]\\]\\((task:\\d+)\\) ([^\\n]*)"));
  for (auto it = link.globalMatch(files(world).renderedText()); it.hasNext();) {
    const QRegularExpressionMatch match = it.next();
    if (match.captured(2).trimmed() == task) return match.captured(1);
  }
  fail(QStringLiteral("the rendered file has no task \"%1\": %2").arg(task, files(world).renderedText()));
}

// Where the box of the task named `task` is drawn, in window coordinates: the
// prose of the rendered view that has it, and the box's place in that prose.
QPoint taskBox(World& world, const QString& task) {
  const QRegularExpression box(QStringLiteral("[☐☑] ") + QRegularExpression::escape(task) + QStringLiteral("(?:[\\s\\x{2028}\\x{2029}]|$)"));
  QList<QQuickItem*> pending{world.brick->item(QStringLiteral("fileRenderedMarkdown"))};
  QStringList seen;
  while (!pending.isEmpty()) {
    QQuickItem* item = pending.takeFirst();
    pending.append(item->childItems());
    if (item->objectName() != QLatin1String("markdownProse")) continue;
    QString drawn;
    QMetaObject::invokeMethod(item, "getText", Q_RETURN_ARG(QString, drawn), Q_ARG(int, 0), Q_ARG(int, item->property("length").toInt()));
    seen.append(drawn);
    const QRegularExpressionMatch match = box.match(drawn);
    if (!match.hasMatch()) continue;
    QRectF place;
    QMetaObject::invokeMethod(item, "positionToRectangle", Q_RETURN_ARG(QRectF, place), Q_ARG(int, int(match.capturedStart())));
    const QPoint point = item->mapToScene(QPointF(place.x() + 4, place.center().y())).toPoint();
    expect(QRect(QPoint(0, 0), world.brick->window().size()).contains(point), QStringLiteral("the box of \"%1\" is drawn out of the window at %2,%3").arg(task).arg(point.x()).arg(point.y()));
    return point;
  }
  fail(QStringLiteral("the rendered view draws no box for the task \"%1\": %2").arg(task, seen.join(QLatin1String(" | "))));
}

// Clicks the task's box, as the user does.
void tick(World& world, const QString& task) {
  const QPoint point = taskBox(world, task);
  const qsizetype before = writes(world).size();
  QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, point);
  world.waitFor([&] { return writes(world).size() > before; }, QStringLiteral("the file to be written"));
  world.sync();
}

}  // namespace

bool fileOpened(World& world, const QString& path) {
  static const QRegularExpression file(QStringLiteral("^[^\\s:]+\\.[a-z]+$"));
  if (!file.match(path).hasMatch() || !path.contains(QLatin1Char('/'))) return false;
  world.waitFor([&] { return files(world).openPath() == path && files(world).fileStatus() == QLatin1String("ready"); }, [&] { return describeViewer(world); });
  return true;
}

bool removeViewedAttachment(World& world) {
  if (world.state(QStringLiteral("attachmentViewer")).isNull()) return false;
  world.brick->click(QStringLiteral("attachmentViewerRemove"));
  world.sync();
  return true;
}

bool lookAtFile(World& world, const QString& path) {
  static const QRegularExpression file(QStringLiteral("^[^\\s:]+\\.[a-z]+$"));
  if (!file.match(path).hasMatch() || !path.contains(QLatin1Char('/'))) return false;
  view(world, path);
  return true;
}

namespace filesteps {

void ensureViewerFile(World& world, const QString& path) {
  FakeFiles& fake = fakeFiles(world.mc);
  if (fake.files.contains(path)) return;
  const QString extension = path.section(QLatin1Char('.'), -1).toLower();
  QString contents = QStringLiteral("export const value = 1;\nexport const other = 2;\n");
  if (extension == QLatin1String("md")) contents = QStringLiteral("# Guide\n\nHow the **cart** adds up.\n\n- one\n- two\n");
  if (extension == QLatin1String("csv")) contents = QStringLiteral("order,total\n1001,12.50\n1002,\"7,25\"\n");
  if (extension == QLatin1String("html")) contents = QStringLiteral("<html><body><h1>Shop</h1><p>Open <b>daily</b>.</p></body></html>\n");
  fake.files.insert(path, contents);
}

}  // namespace filesteps

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // Rendered and source.
  step(QStringLiteral("the file is shown rendered"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.waitFor([&] { return files(world).rendered() && shown(world, QStringLiteral("fileRendered")); }, [&] { return describeViewer(world); });
    expect(!shown(world, QStringLiteral("fileLines")), QStringLiteral("the source shows too"));
    // What it draws: a page's markup as text, a table for CSV, Markdown as it reads.
    const QString kind = files(world).renderKind();
    if (kind == QLatin1String("html")) {
      expect(shown(world, QStringLiteral("fileRenderedPage")) &&
                 world.brick->item(QStringLiteral("fileRenderedPage"))->property("text").toString() == files(world).text(),
             QStringLiteral("the page is not drawn"));
    } else {
      const QString drawn = world.brick->item(QStringLiteral("fileRenderedMarkdown"))->property("text").toString();
      expect(kind == QLatin1String("csv") ? drawn.startsWith(QStringLiteral("| order | total |\n| --- | --- |\n| 1001 | 12.50 |\n| 1002 | 7,25 |")) : drawn == files(world).text(),
             QStringLiteral("the rendered view draws \"%1\"").arg(drawn));
    }
  });
  step(QStringLiteral("the user switches to the source"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("fileRender"));
  });
  step(QStringLiteral("the file's text is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !files(world).rendered() && shown(world, QStringLiteral("fileLines")); }, [&] { return describeViewer(world); });
    expect(!shown(world, QStringLiteral("fileRendered")) &&
               files(world).lines()->rowCount() == fakeFiles(world.mc).files.value(files(world).openPath()).count(QLatin1Char('\n')),
           QStringLiteral("the viewer shows %1 lines").arg(files(world).lines()->rowCount()));
  });
  step(QStringLiteral("the user switches back"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("fileRender"));
  });
  step(QStringLiteral("the user chose to see Markdown source"), [](World& world, const Captures&, const Table&) {
    view(world, QStringLiteral("README.md"));
    expect(files(world).rendered(), describeViewer(world));
    world.brick->click(QStringLiteral("fileRender"));
    expect(!files(world).rendered(), describeViewer(world));
    files(world).closeFile();
  });
  step(QStringLiteral("the Markdown source is shown"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.waitFor([&] { return files(world).renderKind() == QLatin1String("markdown") && !files(world).rendered() && shown(world, QStringLiteral("fileLines")); },
                  [&] { return describeViewer(world); });
    // Kept on this device.
    const QStringList kept = world.native().controller<SettingsController>()->deviceValue(QStringLiteral("fileSourceKinds")).toStringList();
    expect(kept == QStringList{QStringLiteral("markdown")}, QStringLiteral("the device keeps %1").arg(kept.join(u", ")));
  });

  // The path trail.
  step(QStringLiteral("the user picks %1 from the files in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.brick->click(QStringLiteral("filePathPart-") + c[1]);
    QQuickItem* entry = nullptr;
    world.waitFor([&] { return (entry = menuEntry(world, QStringLiteral("filePathSiblings"), QStringLiteral("filePathSibling-%1/%2").arg(c[1], c[0]))) != nullptr; },
                  [&] { return QStringLiteral("%1 to be listed in %2; %3").arg(c[0], c[1], describeTree(world)); });
    QMetaObject::invokeMethod(entry, "triggered");
  });

  // Editors.
  step(QStringLiteral("the thread runs on this computer, which has the editor %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.platform = {{QStringLiteral("machineId"), kThisMachine}};
    world.mc.announceEnvironment();
    setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{editorId(c[0])}}});
  });
  step(QStringLiteral("the user opens %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    viewer(world).editorCallsBefore = editorCalls(world).size();
    choose(world, c[0], QStringLiteral("fileEntryEditor-") + editorId(c[1]));
  });
  step(QStringLiteral("%1 opens %1 on this computer").arg(q),[](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> calls = editorCalls(world).mid(viewer(world).editorCallsBefore);
    const QJsonObject wanted{{QStringLiteral("cwd"), workspaceRoot(world) + QLatin1Char('/') + c[1]}, {QStringLiteral("editor"), editorId(c[0])}};
    expect(calls.size() == 1 && calls.first() == wanted, QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
  });
  step(QStringLiteral("the user opens the thread's workspace in an editor from the thread's details"), [](World& world, const Captures&, const Table&) {
    viewer(world).editorCallsBefore = editorCalls(world).size();
    if (!panel(world)->detailsOpen()) world.bridge().dispatch(QStringLiteral("threadPanel.toggle"), QVariantMap());
    world.sync();
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                                 "ThreadDetailsPanel { details: Shell.state.panel?.details ?? null }\n",
                                          QSize(280, 800));
    world.brick->click(QStringLiteral("threadDetailsOpenEditor"));
  });
  step(QStringLiteral("%1 opens the thread's workspace folder on the environment").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> calls = editorCalls(world).mid(viewer(world).editorCallsBefore);
    const QJsonObject wanted{{QStringLiteral("cwd"), workspaceRoot(world)}, {QStringLiteral("editor"), editorId(c[0])}};
    expect(!workspaceRoot(world).isEmpty() && calls.size() == 1 && calls.first() == wanted, QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
    // The button names the editor it opened.
    expect(world.brick->shows(QStringLiteral("Open in %1").arg(c[0])), QStringLiteral("the details do not name %1").arg(c[0]));
  });
  step(QStringLiteral("%1 stays the preferred editor for next time").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("workspace")), QStringLiteral("preferredEditorId")) == editorId(c[0]) &&
               world.native().controller<SettingsController>()->deviceValue(QStringLiteral("lastEditor")) == editorId(c[0]),
           QStringLiteral("the header shows %1").arg(show(world.state(QStringLiteral("workspace")))));
  });

  // Editing.
  step(QStringLiteral("the user is editing %1").arg(q), [](World& world, const Captures& c, const Table&) { startEditing(world, c[0]); });
  step(QStringLiteral("the user types a change and pauses"), [](World& world, const Captures&, const Table&) {
    typeChange(world);
  });
  step(QStringLiteral("the change is written to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fakeFiles(world.mc).files.value(c[0]).contains(viewer(world).typed); },
                  [&] { return QStringLiteral("%1 to hold the change; it was written %2 time(s); %3").arg(c[0]).arg(writes(world).size()).arg(describeViewer(world)); });
    world.sync();
    const QList<QJsonObject> calls = writes(world);
    expect(!calls.isEmpty() && calls.last().value(QLatin1String("cwd")) == workspaceRoot(world) && calls.last().value(QLatin1String("relativePath")) == c[0] &&
               calls.last().value(QLatin1String("contents")).toString().contains(viewer(world).typed),
           QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
  });
  step(QStringLiteral("the user typed a change in %1 that is not saved yet").arg(q), [](World& world, const Captures& c, const Table&) {
    // The pause that would save it never comes: only closing can write it.
    files(world).setSaveDelay(60 * 60 * 1000);
    startEditing(world, c[0]);
    typeChange(world);
    world.sync();
    expect(files(world).unsaved() && writes(world).isEmpty() && !fakeFiles(world.mc).files.value(c[0]).contains(viewer(world).typed),
           QStringLiteral("the change is already written"));
  });
  step(QStringLiteral("the user opens a file larger than one megabyte"), [](World& world, const Captures&, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    const QString path = QStringLiteral("logs/big.log");
    fake.files.insert(path, QStringLiteral("line\n").repeated(200));
    fake.truncated.insert(path, 3 * 1024 * 1024);
    showPanel(world);
    openFile(world, path);
    viewer(world).described = path;
    expect(files(world).fileStatus() == QLatin1String("ready"), describeViewer(world));
  });
  step(QStringLiteral("the file cannot be edited"), [](World& world, const Captures&, const Table&) {
    const QString path = viewer(world).described;
    const FakeFiles before = fakeFiles(world.mc);
    const qsizetype writesBefore = writes(world).size();
    expect(!files(world).editable() && !files(world).readOnlyReason().isEmpty(), describeViewer(world));
    // The viewer says why (after "Not saved: " when an edit was refused), and its Edit takes no press.
    const QQuickItem* edit = world.brick->item(QStringLiteral("fileEdit"));
    const QQuickItem* note = world.brick->item(QStringLiteral("fileNote"));
    expect(edit->isVisible() && !edit->isEnabled() && note->isVisible() && note->property("text").toString().endsWith(files(world).readOnlyReason()),
           QStringLiteral("the viewer offers to edit; it says \"%1\"").arg(world.brick->item(QStringLiteral("fileNote"))->property("text").toString()));
    files(world).setEditing(true);
    files(world).edit(files(world).text() + QStringLiteral("changed\n"));
    world.sync();
    expect(!path.isEmpty() && !files(world).editing() && writes(world).size() == writesBefore && fakeFiles(world.mc).files == before.files &&
               fakeFiles(world.mc).outside == before.outside,
           QStringLiteral("the file was changed"));
  });
  // A file the agent left outside the project, on the thread's machine.
  // "on another machine of the cluster" is FilesMediaSteps' thread on a peer.
  step(QStringLiteral("the thread is on this computer"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the agent wrote %1 outside the project").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).outside.insert(c[0], QStringLiteral("dish,price\nsoup,4.50\n"));
  });
  step(QStringLiteral("this device was paired without terminal access"), [](World& world, const Captures&, const Table&) { viewer(world).noTerminal = true; });
  step(QStringLiteral("the user is told saving outside the project needs terminal access"), [](World& world, const Captures&, const Table&) {
    const QString why = QStringLiteral("Saving a file outside the project needs terminal access, which this device was not paired with.");
    world.waitFor([&] { return files(world).saveProblem() == why; }, [&] { return describeViewer(world); });
    world.sync();
    // Asked once: the refusal is not tried again, and the edit stays on screen to copy.
    expect(writes(world).size() == 1 && !files(world).editing() && files(world).text().contains(viewer(world).typed) &&
               world.brick->shows(QStringLiteral("Not saved: %1").arg(why)),
           QStringLiteral("%1 after %2 write(s)").arg(describeViewer(world)).arg(writes(world).size()));
    viewer(world).described = viewer(world).edited;
  });
  step(QStringLiteral("the user opens %1 and edits it").arg(q), [](World& world, const Captures& c, const Table&) {
    showPanel(world);
    openFile(world, c[0]);
    expect(files(world).fileStatus() == QLatin1String("ready") && files(world).editable() && world.brick->item(QStringLiteral("fileEdit"))->isEnabled(),
           describeViewer(world));
    world.brick->click(QStringLiteral("fileEdit"));
    world.waitFor([&] { return files(world).editing() && shown(world, QStringLiteral("fileEditor")); }, [&] { return describeViewer(world); });
    viewer(world).edited = c[0];
    typeChange(world);
  });
  step(QStringLiteral("the change is written to %1 on the thread's machine").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fakeFiles(world.mc).outside.value(c[0]).contains(viewer(world).typed); },
                  [&] { return QStringLiteral("%1 to hold the change; it was written %2 time(s); %3").arg(c[0]).arg(writes(world).size()).arg(describeViewer(world)); });
    world.sync();
    const FakeMc::Rpc* last = nullptr;
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      if (rpc.method == QLatin1String("projects.writeFile")) last = &rpc;
    }
    // Asked of the MC the thread runs on, by the file's full path.
    const QString machine = files(world).environment();
    const bool there = last && (last->environment == machine || (last->environment.isEmpty() && machine == world.mc.environmentId));
    expect(there && last->payload.value(QLatin1String("cwd")) == workspaceRoot(world) && last->payload.value(QLatin1String("relativePath")) == c[0],
           QStringLiteral("the MC was asked %1").arg(last ? QStringLiteral("%1 on \"%2\"").arg(show(last->payload.toVariantMap()), last->environment) : QStringLiteral("nothing")));
    expect(files(world).saveProblem().isEmpty() && !fakeFiles(world.mc).files.contains(c[0]), describeViewer(world));
  });

  // Copying the open file.
  step(QStringLiteral("the user is reading %1 in the viewer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    view(world, c[0]);
    expect(files(world).fileStatus() == QLatin1String("ready"), describeViewer(world));
  });
  step(QStringLiteral("the user copies the file's text from the (viewer|command palette)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("viewer")) {
      world.brick->click(QStringLiteral("fileCopy"));
      return;
    }
    CommandRegistry* commands = world.native().controller<KeybindingController>()->commands();
    const QString command = QStringLiteral("files.copyContents");
    QModelIndex row;
    for (int index = 0; index < commands->rowCount(); ++index) {
      if (commands->index(index).data(CommandRegistry::CommandRole) == command) row = commands->index(index);
    }
    expect(row.isValid() && row.data(CommandRegistry::ListedRole).toBool() && row.data(CommandRegistry::EnabledRole).toBool() &&
               row.data(CommandRegistry::TitleRole) == QLatin1String("Copy file contents"),
           QStringLiteral("the palette does not offer \"Copy file contents\""));
    commands->run(command);
  });
  step(QStringLiteral("the whole of %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = fakeFiles(world.mc).files.value(c[0]);
    world.sync();
    expect(!wanted.isEmpty() && world.clipboard == wanted, QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the user is told the file's text was copied"), [](World& world, const Captures&, const Table&) {
    expect(toldCopied(world, files(world).openPath()), QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  // The MC sends a file's first 1 MB, marked truncated (PanelSteps' "is 3 MB").
  step(QStringLiteral("the first megabyte of %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = fakeFiles(world.mc).files.value(c[0]);
    world.sync();
    expect(fakeFiles(world.mc).truncated.contains(c[0]) && !wanted.isEmpty() && world.clipboard == wanted,
           QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the user is told only the first 1 MB of %1 was copied").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(toldCopied(world, QStringLiteral("Only the first 1 MB of %1.").arg(c[0])),
           QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });

  step(QStringLiteral("%1 has the unticked task %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("# To do\n\n- [x] Draft the plan\n- [ ] %1\n- [ ] Tell everyone\n").arg(c[1]));
  });
  step(QStringLiteral("the user ticks %1 in the rendered view").arg(q), [](World& world, const Captures& c, const Table&) {
    viewer(world).edited = QStringLiteral("TODO.md");
    view(world, viewer(world).edited);
    world.waitFor([&] { return files(world).rendered() && shown(world, QStringLiteral("fileRenderedMarkdown")); }, [&] { return describeViewer(world); });
    tick(world, c[0]);
  });
  // A Space page's checklist item is unticked the same way (Space.h).
  step(QStringLiteral("the user unticks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!spaceTick(world, c[0], false)) tick(world, c[0]);
  });
  step(QStringLiteral("%1 records %1 as (done|open)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = QStringLiteral("# To do\n\n- [x] Draft the plan\n- [%1] %2\n- [ ] Tell everyone\n").arg(c[2] == QLatin1String("done") ? u"x" : u" ", c[1]);
    expect(fakeFiles(world.mc).files.value(c[0]) == wanted, QStringLiteral("%1 holds \"%2\"").arg(c[0], fakeFiles(world.mc).files.value(c[0])));
    // The rendered view follows.
    expect(files(world).renderedText().contains(QStringLiteral("[%1](").arg(c[2] == QLatin1String("done") ? u"☑" : u"☐") + taskLink(world, c[1])),
           QStringLiteral("the view draws %1").arg(files(world).renderedText()));
  });
  // A draft's attachment, opened from its chip in the composer.
  step(QStringLiteral("the user is viewing an attachment of a draft"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.attach"),
                            QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{{QStringLiteral("name"), QStringLiteral("receipt.png")},
                                                                                           {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                                           {QStringLiteral("base64"), QStringLiteral("iVBORw0KGgo=")}}}}});
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n",
                                          QSize(900, 700));
    world.brick->click(QStringLiteral("attachmentOpen:receipt.png"));
    const auto viewed = [&] { return world.state(QStringLiteral("attachmentViewer")).toMap(); };
    world.waitFor([&] { return viewed().value(QStringLiteral("name")) == QLatin1String("receipt.png") && shown(world, QStringLiteral("attachmentViewerImage")); },
                  [&] { return QStringLiteral("the attachment to open; the viewer is %1").arg(show(viewed())); });
    expect(viewed().value(QStringLiteral("kind")) == QLatin1String("image") && viewed().value(QStringLiteral("origin")) == QLatin1String("Draft"), show(viewed()));
  });
  step(QStringLiteral("the viewer closes and the attachment leaves the draft"), [](World& world, const Captures&, const Table&) {
    const QVariantList left = world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("attachments")).toList();
    expect(world.state(QStringLiteral("attachmentViewer")).isNull() && left.isEmpty(),
           QStringLiteral("the viewer is %1 and the draft carries %2").arg(show(world.state(QStringLiteral("attachmentViewer"))), show(left)));
    world.waitFor([&] { return !world.brick->root()->findChild<QObject*>(QStringLiteral("attachmentViewer"))->property("visible").toBool(); },
                  QStringLiteral("the viewer to close"));
  });
  step(QStringLiteral("writing %1 fails").arg(q), [](World& world, const Captures& c, const Table&) { viewer(world).unwritable.insert(c[0]); });
  step(QStringLiteral("the user edits %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startEditing(world, c[0]);
    typeChange(world);
    world.waitFor([&] { return !writes(world).isEmpty() && !files(world).saveProblem().isEmpty(); },
                  [&] { return QStringLiteral("the save to be answered; %1").arg(describeViewer(world)); });
  });
  step(QStringLiteral("the user is told the file could not be saved"), [](World& world, const Captures&, const Table&) {
    const QString path = viewer(world).edited;
    expect(files(world).saveProblem() == QStringLiteral("Could not write %1.").arg(path) &&
               world.brick->shows(QStringLiteral("Not saved: Could not write %1.").arg(path)),
           describeViewer(world));
    bool told = false;
    for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
      told = told || (at(toast, QStringLiteral("type")) == QLatin1String("error") && at(toast, QStringLiteral("title")) == QStringLiteral("Could not save %1").arg(path));
    }
    expect(told, QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("the edit is still in the editor"), [](World& world, const Captures&, const Table&) {
    const QString typed = viewer(world).typed;
    expect(files(world).editing() && files(world).unsaved() && files(world).text().contains(typed) &&
               world.brick->item(QStringLiteral("fileEditor"))->property("text").toString().contains(typed) &&
               !fakeFiles(world.mc).files.value(viewer(world).edited).contains(typed),
           describeViewer(world));
  });
});

qsizetype signings(World& world) {
  qsizetype count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) count += rpc.method == QLatin1String("assets.createUrl");
  return count;
}

void agentChanged(World& world, const QString& path) {
  stream::startRun(world);
  stream::addItem(world, QStringLiteral("file_change"), {{QStringLiteral("changes"), QJsonArray{QJsonObject{{QStringLiteral("path"), path}}}}});
}

QRectF placeOf(World& world, const QString& objectName) {
  showPanel(world);
  world.sync();
  QQuickItem* item = world.brick->item(objectName);
  expect(item != nullptr, objectName + QStringLiteral(" is not drawn"));
  return QRectF(item->mapToScene(QPointF(0, 0)), item->size());
}

// The folder of the open file's path named `name`.
QString trailFolderNamed(World& world, const QString& name) {
  QString folder;
  for (const QString& part : files(world).openPath().split(QLatin1Char('/'))) {
    folder += (folder.isEmpty() ? QString() : QStringLiteral("/")) + part;
    if (part == name) return folder;
  }
  fail(QStringLiteral("\"%1\" is not on the path \"%2\"").arg(name, files(world).openPath()));
}

const Steps backlogSteps([] {
  const QString q = kQuoted;

  // Files that are not text.
  step(QStringLiteral("%1 in %1 (contains null bytes|is written in a non-UTF-8 text encoding)").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    fake.files.insert(c[0], QString());
    fake.unreadable.insert(c[0], c[2] == QLatin1String("contains null bytes") ? QStringLiteral("binary_file") : QStringLiteral("not_utf8"));
    showPanel(world);
  });
  step(QStringLiteral("the file is not shown as text"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return files(world).fileStatus() == QLatin1String("error"); }, [&] { return describeViewer(world); });
    expect(!shown(world, QStringLiteral("fileLines")) && shown(world, QStringLiteral("fileMessage")), describeViewer(world));
  });

  // Tables.
  step(QStringLiteral("the user opens %1 rendered").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, c[0]);
    world.waitFor([&] { return files(world).rendered() && shown(world, QStringLiteral("fileRendered")); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("%1 has more than 100 rows and more than 30 columns").arg(q), [](World& world, const Captures& c, const Table&) {
    QString contents;
    for (int row = 0; row < 120; ++row) {
      QStringList cells;
      for (int column = 0; column < 35; ++column) cells.append(QStringLiteral("r%1c%2").arg(row).arg(column));
      contents += cells.join(u',') + u'\n';
    }
    fakeFiles(world.mc).files.insert(c[0], contents);
  });
  step(QStringLiteral("the first 100 rows and 30 columns are shown"), [](World& world, const Captures&, const Table&) {
    const QString table = files(world).renderedText();
    expect(table.contains(QStringLiteral("r99c29")) && !table.contains(QStringLiteral("r100c0")) && !table.contains(QStringLiteral("r0c30")), table.left(400));
  });
  step(QStringLiteral("the user is told the table is limited and that the source shows the rest"), [](World& world, const Captures&, const Table&) {
    expect(files(world).renderedText().endsWith(QStringLiteral("Table limited to the first 100 rows and 30 columns; the source shows the rest.\n")), files(world).renderedText().right(200));
  });
  step(QStringLiteral("%1 has a cell reading %1 and a cell holding two lines").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("﻿name,note\n\"%1\",\"first\nsecond\"\n\"say \"\"hi\"\"\",x\n").arg(c[1]));
  });
  step(QStringLiteral("each of those is shown as a single cell"), [](World& world, const Captures&, const Table&) {
    const QString table = files(world).renderedText();
    expect(table.contains(QStringLiteral("| Smith, Jane | first second |\n")) && table.contains(QStringLiteral("| say \"hi\" | x |\n")), table);
  });
  step(QStringLiteral("a leading byte order mark is not shown as text"), [](World& world, const Captures&, const Table&) {
    expect(files(world).renderedText().startsWith(QStringLiteral("| name | note |\n")), files(world).renderedText());
  });
  step(QStringLiteral("%1 ends with a row whose only cell is an empty quoted value and no line ending").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("name\nAlice\n\"\""));
  });
  step(QStringLiteral("that empty row is shown after the last data row"), [](World& world, const Captures&, const Table&) {
    expect(files(world).renderedText() == QStringLiteral("| name |\n| --- |\n| Alice |\n|  |\n"), files(world).renderedText());
  });

  // Following the agent.
  step(QStringLiteral("the user is reading %1 with no edits of their own").arg(q), [](World& world, const Captures& c, const Table&) { view(world, c[0]); });
  step(QStringLiteral("the agent changes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("export const changed = true;\n"));
    agentChanged(world, c[0]);
  });
  step(QStringLiteral("the viewer shows the new contents"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return files(world).text() == QLatin1String("export const changed = true;\n"); }, [&] { return describeViewer(world); });
    expect(files(world).fileStatus() == QLatin1String("ready"), describeViewer(world));
  });
  step(QStringLiteral("an image the agent rewrites is shown as it is now, not from a cached copy"), [](World& world, const Captures&, const Table&) {
    const QString image = QStringLiteral("assets/logo.png");
    fakeFiles(world.mc).files.insert(image, QStringLiteral("png"));
    openFile(world, image);
    world.waitFor([&] { return !files(world).mediaUrl().isEmpty(); }, [&] { return describeViewer(world); });
    const QUrl before = files(world).mediaUrl();
    agentChanged(world, image);
    world.waitFor([&] { return !files(world).mediaUrl().isEmpty() && files(world).mediaUrl() != before; }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the user is previewing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("png"));
    showPanel(world);
    openFile(world, c[0]);
    world.waitFor([&] { return !files(world).mediaUrl().isEmpty(); }, [&] { return describeViewer(world); });
    viewer(world).signingsBefore = signings(world);
  });
  step(QStringLiteral("the agent changes another file"), [](World& world, const Captures&, const Table&) {
    agentChanged(world, QStringLiteral("src/other.ts"));
    world.sync();
  });
  step(QStringLiteral("%1 is not fetched again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(files(world).openPath() == c[0] && signings(world) == viewer(world).signingsBefore && files(world).fileStatus() == QLatin1String("ready"),
           QStringLiteral("%1 signings since; %2").arg(signings(world) - viewer(world).signingsBefore).arg(describeViewer(world)));
  });
  step(QStringLiteral("the user opened %1").arg(q), [](World& world, const Captures& c, const Table&) { view(world, c[0]); });
  step(QStringLiteral("the user opened %1 and it is a folder").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0] + QStringLiteral("/out.txt"), QStringLiteral("out\n"));
    showPanel(world);
    openFile(world, c[0]);
    world.waitFor([&] { return files(world).fileStatus() == QLatin1String("error"); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the agent replaces the folder %1 with a file").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    fake.files.remove(c[0] + QStringLiteral("/out.txt"));
    fake.files.insert(c[0], QStringLiteral("built\n"));
    agentChanged(world, c[0]);
  });
  step(QStringLiteral("the viewer shows the file's contents"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return files(world).fileStatus() == QLatin1String("ready") && files(world).text() == QLatin1String("built\n"); }, [&] { return describeViewer(world); });
  });

  // Opening at a line.
  step(QStringLiteral("the user prefers the rendered Markdown view"), [](World& world, const Captures&, const Table&) {
    QString lines;
    for (int line = 1; line <= 300; ++line) lines += QStringLiteral("line %1\n").arg(line);
    fakeFiles(world.mc).files.insert(QStringLiteral("docs/guide.md"), lines);
    showPanel(world);
  });
  step(QStringLiteral("the Markdown source is shown with line (\\d+) in view"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !files(world).rendered() && shown(world, QStringLiteral("fileLines")); }, [&] { return describeViewer(world); });
    expect(files(world).revealLine() == c[0].toInt(), QStringLiteral("line %1 is revealed").arg(files(world).revealLine()));
    world.sync();
    QQuickItem* lines = world.brick->item(QStringLiteral("fileLines"));
    QQuickItem* line = nullptr;
    QMetaObject::invokeMethod(lines, "itemAtIndex", Q_RETURN_ARG(QQuickItem*, line), Q_ARG(int, c[0].toInt() - 1));
    expect(line != nullptr, QStringLiteral("the line is not drawn"));
    // Not a preference: the next open file is rendered as before.
    expect(!world.native().controller<SettingsController>()->deviceValue(QStringLiteral("fileSourceKinds")).toStringList().contains(QStringLiteral("markdown")),
           QStringLiteral("the device now prefers the source"));
  });

  // Selecting lines.
  step(QStringLiteral("the user (selected lines|is writing a comment on lines) (\\d+) to (\\d+) of %1(?: and left the comment form closed)?").arg(q),
       [](World& world, const Captures& c, const Table&) {
         QString lines;
         for (int line = 1; line <= 40; ++line) lines += QStringLiteral("line %1\n").arg(line);
         fakeFiles(world.mc).files.insert(c[3], lines);
         view(world, c[3]);
         QQuickItem* list = world.brick->item(QStringLiteral("fileLines"));
         const auto gutter = [&](int line) {
           QQuickItem* row = nullptr;
           QMetaObject::invokeMethod(list, "itemAtIndex", Q_RETURN_ARG(QQuickItem*, row), Q_ARG(int, line - 1));
           expect(row != nullptr, QStringLiteral("line %1 is not drawn").arg(line));
           return row->mapToScene(QPointF(4, 4)).toPoint();
         };
         world.sync();
         QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, gutter(c[1].toInt()));
         QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::ShiftModifier, gutter(c[2].toInt()));
         world.sync();
         expect(list->property("selectionFirst").toInt() == c[1].toInt() && list->property("selectionLast").toInt() == c[2].toInt(),
                QStringLiteral("lines %1 to %2 are selected").arg(list->property("selectionFirst").toInt()).arg(list->property("selectionLast").toInt()));
         if (c[0] == QLatin1String("is writing a comment on lines")) {
           world.brick->click(QStringLiteral("fileLineComment"));
           world.sync();
           for (const QChar character : QStringLiteral("why")) QTest::keyClick(&world.brick->window(), character.toLatin1());
           expect(world.brick->item(QStringLiteral("fileCommentText"))->property("text") == QLatin1String("why"), QStringLiteral("the comment did not take the keys"));
         }
       });
  step(QStringLiteral("the user clicks outside the file"), [](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, placeOf(world, QStringLiteral("filesExplorer")).center().toPoint());
    world.sync();
  });
  step(QStringLiteral("the user presses Escape while the file's text is focused"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->item(QStringLiteral("fileLines"))->hasActiveFocus(), QStringLiteral("the file's text does not have the keyboard"));
    QTest::keyClick(&world.brick->window(), Qt::Key_Escape);
    world.sync();
  });
  step(QStringLiteral("the lines are no longer selected"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->item(QStringLiteral("fileLines"))->property("selectionStart").toInt() == 0, QStringLiteral("the lines are still selected"));
  });
  step(QStringLiteral("the comment form and its text are still there"), [](World& world, const Captures&, const Table&) {
    expect(shown(world, QStringLiteral("fileCommentForm")) && world.brick->item(QStringLiteral("fileCommentText"))->property("text") == QLatin1String("why") &&
               world.brick->item(QStringLiteral("fileLines"))->property("selectionStart").toInt() > 0,
           QStringLiteral("the comment is gone"));
  });

  // The tree beside a file, and the layout.
  step(QStringLiteral("the user chose to (show|hide) the file tree"), [](World& world, const Captures& c, const Table&) {
    showPanel(world);
    world.brick->root()->setProperty("explorerOpen", c[0] == QLatin1String("show"));
  });
  step(QStringLiteral("the user opens a file outside the project on the host"), [](World& world, const Captures&, const Table&) {
    const QString path = QStringLiteral("/home/sam/notes.txt");
    fakeFiles(world.mc).outside.insert(path, QStringLiteral("notes\n"));
    openFile(world, path);
    world.waitFor([&] { return files(world).fileStatus() == QLatin1String("ready"); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the user opens an attachment"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.attach"),
                            QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{{QStringLiteral("name"), QStringLiteral("notes.md")},
                                                                                           {QStringLiteral("mimeType"), QStringLiteral("text/markdown")},
                                                                                           {QStringLiteral("base64"), QStringLiteral("IyBOb3Rlcwo=")}}}}});
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n",
                                          QSize(900, 700));
    world.sync();
    world.brick->click(QStringLiteral("attachmentOpen:notes.md"));
    world.waitFor([&] { return world.state(QStringLiteral("attachmentViewer")).toMap().value(QStringLiteral("name")) == QLatin1String("notes.md"); }, QStringLiteral("the attachment to open"));
  });
  step(QStringLiteral("the file tree is (shown|hidden)"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(shown(world, QStringLiteral("filesExplorer")) == (c[0] == QLatin1String("shown")), QStringLiteral("the tree is otherwise; %1").arg(describeViewer(world)));
  });
  step(QStringLiteral("the file viewer takes the height of the Files tab"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.sync();
    expect(qFuzzyCompare(placeOf(world, QStringLiteral("fileViewer")).height(), world.brick->root()->height()), QStringLiteral("the viewer is shorter than the tab"));
  });
  step(QStringLiteral("the file tree is a column beside (?:it|the file)"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.sync();
    const QRectF file = placeOf(world, QStringLiteral("fileViewer"));
    const QRectF tree = placeOf(world, QStringLiteral("filesExplorer"));
    expect(shown(world, QStringLiteral("filesExplorer")) && tree.left() >= file.right() && tree.width() > 0 && qFuzzyCompare(tree.height(), file.height()),
           QStringLiteral("the tree is not beside the file"));
  });
  step(QStringLiteral("the user (hides|shows) the file explorer"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.brick->click(QStringLiteral("fileExplorerToggle"));
    world.sync();
  });
  step(QStringLiteral("the file viewer takes the whole Files tab"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    expect(!shown(world, QStringLiteral("filesExplorer")) && qFuzzyCompare(placeOf(world, QStringLiteral("fileViewer")).width(), world.brick->root()->width()),
           QStringLiteral("the viewer is narrower than the tab"));
  });
  step(QStringLiteral("the file tree takes the whole Files tab"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.sync();
    expect(!shown(world, QStringLiteral("fileViewer")) && qFuzzyCompare(placeOf(world, QStringLiteral("filesExplorer")).width(), world.brick->root()->width()),
           QStringLiteral("the tree is narrower than the tab"));
  });
  step(QStringLiteral("the file tree stays hidden while the file is open"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.sync();
    expect(!shown(world, QStringLiteral("filesExplorer")), QStringLiteral("the tree came back"));
  });
  step(QStringLiteral("the Files tab is as narrow as a phone"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.brick->window().resize(300, 700);
    world.brick->root()->setWidth(300);
    world.sync();
  });
  step(QStringLiteral("every button above the file is inside the file's column"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.sync();
    const QRectF file = placeOf(world, QStringLiteral("fileViewer"));
    for (const QString& button : {QStringLiteral("fileRender"), QStringLiteral("fileEdit"), QStringLiteral("fileCopy"), QStringLiteral("fileClose")}) {
      const QRectF place = placeOf(world, button);
      expect(place.right() <= file.right() + 0.5, QStringLiteral("%1 ends at %2, the file at %3").arg(button).arg(place.right()).arg(file.right()));
    }
  });
  step(QStringLiteral("the file tree gives way before the buttons do"), [](World& world, const Captures&, const Table&) {
    expect(!shown(world, QStringLiteral("filesExplorer")), QStringLiteral("the tree still takes room"));
  });
  step(QStringLiteral("a tab too narrow to leave the tree room for ten characters of a name at the user's font size shows the file alone"), [](World& world, const Captures&, const Table&) {
    QObject* root = world.brick->root();
    expect(root->property("explorerShare").toReal() < root->property("explorerMinimum").toReal() && !shown(world, QStringLiteral("filesExplorer")) && shown(world, QStringLiteral("fileViewer")),
           QStringLiteral("the tree has %1 of %2").arg(root->property("explorerShare").toReal()).arg(root->property("explorerMinimum").toReal()));
  });

  // The path trail.
  step(QStringLiteral("%1 is empty").arg(q), [](World& world, const Captures&, const Table&) { viewer(world).trailState = QStringLiteral("empty"); });
  step(QStringLiteral("%1 was deleted after the file was opened").arg(q), [](World& world, const Captures&, const Table&) { viewer(world).trailState = QStringLiteral("gone"); });
  step(QStringLiteral("the project index is partial and has nothing in %1").arg(q), [](World& world, const Captures&, const Table&) { viewer(world).trailState = QStringLiteral("partial"); });
  step(QStringLiteral("the user opens the folder %1 in the path trail").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    fake.files.insert(QStringLiteral("src/lib/util/round.ts"), QStringLiteral("round\n"));
    fake.files.insert(QStringLiteral("src/lib/tax.ts"), QStringLiteral("tax\n"));
    const bool failing = fake.failOnce.remove(c[0]);
    if (files(world).openPath().isEmpty()) view(world, QStringLiteral("src/lib/cart.ts"));
    const QString folder = trailFolderNamed(world, c[0]);
    if (failing) fake.failOnce.insert(folder);
    const QString state = viewer(world).trailState;
    if (state == QLatin1String("empty")) fake.emptyFolders.insert(folder);
    if (state == QLatin1String("gone")) fake.goneFolders.insert(folder);
    if (state == QLatin1String("partial")) fake.partialFolders.insert(folder);
    world.brick->click(QStringLiteral("filePathPart-") + folder);
    world.waitFor([&] { return files(world).trailFolder() == folder && files(world).trailStatus() != QLatin1String("loading"); }, QStringLiteral("the folder to be listed"));
    world.sync();
  });
  step(QStringLiteral("the files and folders of %1 are listed, folders first").arg(q), [](World& world, const Captures&, const Table&) {
    QStringList names;
    for (const QVariant& entry : files(world).trailEntries()) names.append(entry.toMap().value(QStringLiteral("name")).toString());
    expect(names == QStringList{QStringLiteral("util"), QStringLiteral("cart.ts"), QStringLiteral("tax.ts")}, names.join(u", "));
    expect(menuEntry(world, QStringLiteral("filePathSiblings"), QStringLiteral("filePathSibling-src/lib/util")) != nullptr, QStringLiteral("the menu does not draw the folder"));
  });
  step(QStringLiteral("the folder that is open is marked"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->item(QStringLiteral("filePathPart-src/lib"))->property("checked").toBool(), QStringLiteral("the trail does not mark the folder"));
    expect(menuEntry(world, QStringLiteral("filePathSiblings"), QStringLiteral("filePathSibling-src/lib/cart.ts"))->property("current").toBool(), QStringLiteral("the list does not mark the open file"));
  });
  step(QStringLiteral("the files of %1 are listed").arg(q), [](World& world, const Captures&, const Table&) {
    expect(files(world).trailStatus() == QLatin1String("ready") && !files(world).trailEntries().isEmpty(), files(world).trailStatus());
    world.waitFor([&] { return menuEntry(world, QStringLiteral("filePathSiblings"), QStringLiteral("filePathSibling-src/lib/cart.ts")) != nullptr; }, QStringLiteral("the menu to list the folder"));
  });

  // The preview browser.
  step(QStringLiteral("the environment can serve %1 to the preview").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("<html></html>\n"));
  });
  step(QStringLiteral("the environment cannot serve %1 to the preview").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    fake.files.insert(c[0], QStringLiteral("<html></html>\n"));
    fake.unsignable = QStringLiteral("The file is too large to serve.");
  });
  step(QStringLiteral("the user opens %1 in the preview browser").arg(q), [](World& world, const Captures& c, const Table&) {
    showPanel(world);
    // A document's preview is itself an address: asked for once it may be served.
    const QString refusal = std::exchange(fakeFiles(world.mc).unsignable, QString());
    openFile(world, c[0]);
    fakeFiles(world.mc).unsignable = refusal;
    world.waitFor([&] { return files(world).openPath() == c[0] && files(world).fileStatus() != QLatin1String("loading"); }, [&] { return describeViewer(world); });
    world.brick->click(QStringLiteral("fileOpenPreview"));
  });
  step(QStringLiteral("%1 is shown in the preview browser").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto opened = [&] {
      for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
        if (rpc.method == QLatin1String("preview.open") && rpc.payload.value(QLatin1String("url")).toString().endsWith(c[0].section(QLatin1Char('/'), -1))) return true;
      }
      return false;
    };
    world.waitFor(opened, QStringLiteral("a browser tab on the file"));
  });
  step(QStringLiteral("the user is told the file could not be opened in the browser with the reason"), [](World& world, const Captures&, const Table&) {
    const auto told = [&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (at(toast, QStringLiteral("title")) == QLatin1String("Could not open the file in the browser") && at(toast, QStringLiteral("description")) == QLatin1String("The file is too large to serve.")) return true;
      }
      return false;
    };
    world.waitFor(told, [&] { return show(world.state(QStringLiteral("toasts"))); });
  });

  // The preferred editor and the reveal label.
  step(QStringLiteral("the user's preferred editor is %1 and it is no longer installed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.native().controller<SettingsController>()->writeDevice(QStringLiteral("lastEditor"), editorId(c[0]));
  });
  step(QStringLiteral("the user opens %1 in the preferred editor").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, c[0]);
    viewer(world).editorCallsBefore = editorCalls(world).size();
    world.brick->click(QStringLiteral("fileOpenInEditor"));
    world.waitFor([&] { return editorCalls(world).size() > viewer(world).editorCallsBefore; }, QStringLiteral("the editor to be asked"));
  });
  step(QStringLiteral("%1 is the preferred editor from then on").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("workspace")), QStringLiteral("preferredEditorId")) == editorId(c[0]), show(world.state(QStringLiteral("workspace"))));
  });
  step(QStringLiteral("the environment's host is (macOS|Windows|Linux where reveal runs through Windows \\(WSL\\)|Linux)"), [](World& world, const Captures& c, const Table&) {
    QJsonObject platform{{QStringLiteral("machineId"), kThisMachine}};
    platform.insert(QStringLiteral("os"), c[0] == QLatin1String("macOS") ? QStringLiteral("darwin") : c[0] == QLatin1String("Windows") ? QStringLiteral("win32") : QStringLiteral("linux"));
    if (c[0].contains(QLatin1String("WSL"))) platform.insert(QStringLiteral("wsl"), true);
    world.mc.platform = platform;
    world.mc.announceEnvironment();
    setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")}}});
  });
  step(QStringLiteral("the user opens the menu of %1").arg(q), [](World& world, const Captures&, const Table&) { showPanel(world); world.sync(); });
  step(QStringLiteral("the reveal action reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return menuEntry(world, QStringLiteral("fileEntryMenu"), QStringLiteral("fileEntryReveal"))->property("text") == c[0]; },
                  [&] { return menuEntry(world, QStringLiteral("fileEntryMenu"), QStringLiteral("fileEntryReveal"))->property("text").toString(); });
  });

  // Saves.
  step(QStringLiteral("writing %1 failed after an edit").arg(q), [](World& world, const Captures& c, const Table&) {
    viewer(world).unwritable.insert(c[0]);
    files(world).setSaveDelay(0);
    startEditing(world, c[0]);
    typeChange(world);
    world.waitFor([&] { return !files(world).saveProblem().isEmpty(); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("writing %1 works again").arg(q), [](World& world, const Captures& c, const Table&) { viewer(world).unwritable.remove(c[0]); });
  step(QStringLiteral("the edit is written to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fakeFiles(world.mc).files.value(c[0]).contains(viewer(world).typed); }, QStringLiteral("the edit to be written"));
  });
  step(QStringLiteral("a save of %1 is being written").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.hold(QStringLiteral("write"));
    files(world).setSaveDelay(0);
    startEditing(world, c[0]);
    typeChange(world);
    world.waitFor([&] { return !writes(world).isEmpty(); }, QStringLiteral("the save to start"));
  });
  step(QStringLiteral("the user makes another edit"), [](World& world, const Captures&, const Table&) {
    QTest::keyClick(&world.brick->window(), 'z');
    world.sync();
    expect(files(world).text().contains(u'z'), describeViewer(world));
  });
  step(QStringLiteral("the file ends up with both edits"), [](World& world, const Captures&, const Table&) {
    const QString path = viewer(world).edited;
    const auto both = [&] {
      const QString written = fakeFiles(world.mc).files.value(path);
      return written.contains(viewer(world).typed.trimmed()) && written.contains(u'z');
    };
    world.mc.answerHeld();
    world.waitFor([&] {
      viewer(world).savedEarly = viewer(world).savedEarly || (!both() && !files(world).unsaved());
      return both();
    }, [&] { return fakeFiles(world.mc).files.value(path); });
  });
  step(QStringLiteral("the file is not shown as saved until the last edit is written"), [](World& world, const Captures&, const Table&) {
    expect(!viewer(world).savedEarly, QStringLiteral("the file was shown as saved early"));
    world.waitFor([&] { return !files(world).unsaved(); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the user saved an edit to %1 while an older read of it was still under way").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, c[0]);
    files(world).setSaveDelay(0);
    world.mc.hold(QStringLiteral("read"));
    viewer(world).rewritten = QStringLiteral("what the older read saw\n");
    fakeFiles(world.mc).files.insert(c[0], viewer(world).rewritten);
    agentChanged(world, c[0]);
    world.sync();
    viewer(world).edited = c[0];
    world.brick->click(QStringLiteral("fileEdit"));
    world.waitFor([&] { return files(world).editing() && shown(world, QStringLiteral("fileEditor")); }, [&] { return describeViewer(world); });
    typeChange(world);
    world.brick->click(QStringLiteral("fileEdit"));
    world.waitFor([&] { return fakeFiles(world.mc).files.value(c[0]).contains(viewer(world).typed) && !files(world).unsaved(); }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the older read finishes"), [](World& world, const Captures&, const Table&) {
    QObject::connect(&files(world), &WorkspaceFiles::textChanged, &files(world), [&world] { viewer(world).seen.append(files(world).text()); });
    // The environment has moved on again: the new read has something of its own to show.
    fakeFiles(world.mc).files[viewer(world).edited] += QStringLiteral("as the environment has it\n");
    world.mc.answerHeld();
  });
  step(QStringLiteral("the viewer keeps showing the saved edit"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!viewer(world).seen.contains(viewer(world).rewritten) && files(world).text().contains(viewer(world).typed), describeViewer(world));
  });
  step(QStringLiteral("it shows the file as the environment has it once the new read arrives"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return files(world).text() == fakeFiles(world.mc).files.value(viewer(world).edited); }, [&] { return files(world).text(); });
    expect(!viewer(world).seen.contains(viewer(world).rewritten), QStringLiteral("the older read was shown"));
  });
  step(QStringLiteral("the user is looking at the rendered view"), [](World& world, const Captures&, const Table&) {
    viewer(world).edited = QStringLiteral("TODO.md");
    view(world, viewer(world).edited);
    world.waitFor([&] { return files(world).rendered() && shown(world, QStringLiteral("fileRenderedMarkdown")); }, [&] { return describeViewer(world); });
    world.sync();
  });
  step(QStringLiteral("the agent has since rewritten %1 so the task moved").arg(q), [](World& world, const Captures& c, const Table&) {
    viewer(world).rewritten = QStringLiteral("# To do\n\n- [ ] Something first\n- [x] Draft the plan\n- [ ] Ship cart\n");
    fakeFiles(world.mc).files.insert(c[0], viewer(world).rewritten);
  });
  step(QStringLiteral("the user ticks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (spaceTick(world, c[0], true)) return;
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, taskBox(world, c[0]));
    world.waitFor([&] { return files(world).text() == viewer(world).rewritten; }, [&] { return describeViewer(world); });
  });
  step(QStringLiteral("the user ticks %1 and %1 before either read is answered").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& task : {c[0], c[1]}) files(world).toggleTask(taskLink(world, task).section(QLatin1Char(':'), 1).toInt());
  });
  step(QStringLiteral("%1 records both tasks as done").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = QStringLiteral("# To do\n\n- [x] Draft the plan\n- [x] Ship cart\n- [x] Tell everyone\n");
    world.waitFor([&] { return fakeFiles(world.mc).files.value(c[0]) == wanted; }, [&] { return QStringLiteral("%1 holds \"%2\"").arg(c[0], fakeFiles(world.mc).files.value(c[0])); });
  });
  step(QStringLiteral("%1 is not changed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(writes(world).isEmpty() && fakeFiles(world.mc).files.value(c[0]) == viewer(world).rewritten, QStringLiteral("%1 was written").arg(c[0]));
  });
});

}  // namespace
