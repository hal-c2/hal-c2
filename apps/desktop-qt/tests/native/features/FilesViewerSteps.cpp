// The file viewer beyond reading (features/files/file-viewer-and-editing.feature):
// rendered files and their source, the path trail, opening in an editor, and
// editing with its saves, on the Files tab as the right panel draws it.
// PanelSteps.cpp has opening, wrapping and retrying. The MC's
// `projects.writeFile` is faked here.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "FilesViewer.h"
#include "FilesWorkspace.h"
#include "SettingsController.h"

namespace {

using namespace filesteps;

struct Viewer {
  // Paths the MC refuses to write.
  QSet<QString> unwritable;
  // The file the scenario edits, and what the user typed into it.
  QString edited;
  QString typed;
  // The file opened by a description ("a file larger than one megabyte").
  QString described;
  // How many times the MC had been asked to open an editor before the step under test.
  qsizetype editorCallsBefore = 0;
};

Viewer& viewer(World& world) {
  return world.mc.part<Viewer>();
}

const FakeMc::Extension extension([](FakeMc& mc) {
  // As apps/server-ex lib/hal_c2/workspace.ex write_file: the file's new contents.
  mc.onRpc(QStringLiteral("projects.writeFile"), [&mc](const FakeMc::Rpc& rpc) {
    const QString path = rpc.payload.value(QLatin1String("relativePath")).toString();
    if (mc.part<Viewer>().unwritable.contains(path)) {
      mc.refuse(rpc, QStringLiteral("Could not write %1.").arg(path));
      return;
    }
    fakeFiles(mc).files.insert(path, rpc.payload.value(QLatin1String("contents")).toString());
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativePath"), path}});
  });
});

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

void tick(World& world, const QString& task) {
  QQuickItem* markdown = world.brick->item(QStringLiteral("fileRenderedMarkdown"));
  const qsizetype before = writes(world).size();
  QMetaObject::invokeMethod(markdown, "linkActivated", Q_ARG(QString, taskLink(world, task)));
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
  step(QStringLiteral("the environment has the editor %1").arg(q), [](World& world, const Captures& c, const Table&) {
    setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{editorId(c[0])}}});
  });
  step(QStringLiteral("the user opens %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    viewer(world).editorCallsBefore = editorCalls(world).size();
    choose(world, c[0], QStringLiteral("fileEntryEditor-") + editorId(c[1]));
  });
  step(QStringLiteral("%1 opens %1 on the environment").arg(q), [](World& world, const Captures& c, const Table&) {
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
  step(QStringLiteral("the user opens (a file larger than one megabyte|a file outside the project on the host)"), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    QString path = QStringLiteral("logs/big.log");
    if (c[0] == QLatin1String("a file larger than one megabyte")) {
      fake.files.insert(path, QStringLiteral("line\n").repeated(200));
      fake.truncated.insert(path, 3 * 1024 * 1024);
    } else {
      // Read by its full path, as the MC reads a file outside the workspace.
      path = QStringLiteral("/home/sam/notes/todo.txt");
      fake.outside.insert(path, QStringLiteral("call the bank\n"));
    }
    showPanel(world);
    openFile(world, path);
    viewer(world).described = path;
    expect(files(world).fileStatus() == QLatin1String("ready"), describeViewer(world));
  });
  step(QStringLiteral("the file cannot be edited"), [](World& world, const Captures&, const Table&) {
    const QString path = viewer(world).described;
    const FakeFiles before = fakeFiles(world.mc);
    expect(!files(world).editable() && !files(world).readOnlyReason().isEmpty(), describeViewer(world));
    // The viewer says why, and its Edit takes no press.
    const QQuickItem* edit = world.brick->item(QStringLiteral("fileEdit"));
    expect(edit->isVisible() && !edit->isEnabled() && world.brick->shows(files(world).readOnlyReason()),
           QStringLiteral("the viewer offers to edit; it says \"%1\"").arg(world.brick->item(QStringLiteral("fileNote"))->property("text").toString()));
    files(world).setEditing(true);
    files(world).edit(files(world).text() + QStringLiteral("changed\n"));
    world.sync();
    expect(!path.isEmpty() && !files(world).editing() && writes(world).isEmpty() && fakeFiles(world.mc).files == before.files &&
               fakeFiles(world.mc).outside == before.outside,
           QStringLiteral("the file was changed"));
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
  step(QStringLiteral("the user unticks %1").arg(q), [](World& world, const Captures& c, const Table&) { tick(world, c[0]); });
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

}  // namespace
