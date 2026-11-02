// The phone's side of the Mermaid scenarios of
// features/files/file-viewer-and-editing.feature (a thread's Files screen
// draws a diagram file, or a Markdown file's diagram) and of a page's in
// features/space/markdown.feature, whose steps are SpaceSteps', with the
// Bricks' MermaidDiagram the desktop uses. The fake MC answers
// `mermaid.render` as the desktop's MermaidSteps.cpp does.

#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>

#include "FakeFiles.h"
#include "Harness.h"
#include "Mermaid.h"
#include "NativeShell.h"
#include "RightPanelController.h"
#include "WorkspaceFiles.h"
#include "World.h"

namespace {

#define S QStringLiteral

const QString kSvg = S(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"60\" viewBox=\"0 0 160 60\">"
    "<rect x=\"1\" y=\"1\" width=\"158\" height=\"58\" rx=\"6\" fill=\"none\" stroke=\"#888\"/></svg>");

// packages/contracts mermaid.ts's answers: a bracket opened and not closed is
// the mistake, on the line it is on; "block-beta" is a type the renderer
// cannot draw (native/mermaid's words); anything else is drawn.
const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(S("mermaid.render"), [&mc](const FakeMc::Rpc& rpc) {
    const QString source = rpc.payload.value(QLatin1String("source")).toString();
    const QString kind = source.section(QRegularExpression(S("\\s")), 0, 0, QString::SectionSkipEmpty);
    if (kind == QLatin1String("block-beta")) {
      mc.reply(rpc, QJsonObject{{S("status"), S("unsupported")}, {S("kind"), kind}, {S("reason"), kind + S(" diagrams cannot be drawn yet.")}});
      return;
    }
    const QStringList lines = source.split(QLatin1Char('\n'));
    for (qsizetype at = 0; at < lines.size(); ++at) {
      if (lines.at(at).count(QLatin1Char('[')) > lines.at(at).count(QLatin1Char(']'))) {
        mc.reply(rpc, QJsonObject{{S("status"), S("invalid")}, {S("kind"), kind}, {S("reason"), S("A bracket is opened and not closed.")},
                                  {S("line"), int(at + 1)}, {S("column"), QJsonValue()}});
        return;
      }
    }
    mc.reply(rpc, QJsonObject{{S("status"), S("drawn")}, {S("kind"), kind}, {S("svg"), kSvg}, {S("width"), 160}, {S("height"), 60}});
  });
});

WorkspaceFiles& files(World& world) { return *world.native().controller<RightPanelController>()->files(); }

void collectShown(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (!item->isVisible()) return;
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) collectShown(child, name, out);
}

using mermaid::drawn;
using mermaid::kBrokenFlowchart;
using mermaid::kFlowchart;
using mermaid::shown;

QString describe(World& world) {
  return S("\"%1\" open %2, %3 diagrams drawn; the screen says: %4")
      .arg(files(world).openPath(), files(world).rendered() ? S("rendered") : S("as source"))
      .arg(drawn(world).size())
      .arg(world.texts().join(S(" | ")));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("%1 holds the file %1 with a flowchart (in it|with an unclosed bracket)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString diagram = c[2] == QLatin1String("in it") ? kFlowchart : kBrokenFlowchart;
    fakeFiles(world.mc).files.insert(c[1], c[1].endsWith(QLatin1String(".md")) ? S("# Flow\n\nHow an order is paid:\n\n```mermaid\n%1\n```\n").arg(diagram)
                                                                              : diagram + QLatin1Char('\n'));
  });
  step(S("on the desktop and the phone the flowchart is drawn"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return files(world).rendered() && drawn(world).size() == 1; }, [&] { return describe(world); });
    const QQuickItem* image = drawn(world).first();
    expect(image->width() > 0 && image->x() + image->width() <= world.window().width(),
           S("the diagram is %1 wide at %2 on a %3 wide screen").arg(image->width()).arg(image->x()).arg(world.window().width()));
  });
  // The terminal's; the phone draws the diagram.
  step(S("in the terminal the diagram is drawn in characters, or its source is shown, named as a %1 diagram").arg(q), [](World&, const Captures&, const Table&) {});
  step(S("the user switches to the source"), [](World& world, const Captures&, const Table&) { world.tap(S("fileRender")); });
  step(S("the diagram's source is shown"), [](World& world, const Captures&, const Table&) {
    if (mermaid::onPage(world)) return mermaid::expectPageSource(world);
    world.waitFor([&] { return !files(world).rendered() && world.find(S("fileLines")) && drawn(world).isEmpty(); }, [&] { return describe(world); });
    expect(files(world).lines()->rowCount() == fakeFiles(world.mc).files.value(files(world).openPath()).count(QLatin1Char('\n')),
           S("the viewer shows %1 lines").arg(files(world).lines()->rowCount()));
  });
  // A diagram file the MC could not draw shows its text where the diagram would be.
  step(S("the file's text is shown"), [](World& world, const Captures&, const Table&) {
    const QString text = fakeFiles(world.mc).files.value(files(world).openPath()).chopped(1);
    QString seen;
    world.waitFor([&] {
      const QList<QQuickItem*> code = shown(world, S("codeText"));
      if (code.size() != 1) return false;
      QMetaObject::invokeMethod(code.first(), "getText", Q_RETURN_ARG(QString, seen), Q_ARG(int, 0), Q_ARG(int, code.first()->property("length").toInt()));
      // Rich text reports a line break as a line separator.
      seen.replace(QChar(0x2028), QLatin1Char('\n'));
      return seen == text && drawn(world).isEmpty();
    }, [&] { return S("the file's text to be shown; it shows \"%1\"; %2").arg(seen, describe(world)); });
  });
  step(S("the user is told where the mistake is"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QQuickItem*> notes = shown(world, S("mermaidStatus"));
      return notes.size() == 1 && notes.first()->property("text") == QLatin1String("Line 2: A bracket is opened and not closed.");
    }, [&] { return describe(world); });
  });
  step(S("nothing claims the diagram is still being drawn"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.shows(S("Drawing the diagram…")) && drawn(world).isEmpty(), S("the screen says: %1").arg(world.texts().join(S(" | "))));
    expect(shown(world, S("mermaidRetry")).isEmpty(), S("a mistake is offered to be drawn again"));
  });
  step(S("the user is told %1 diagrams cannot be drawn yet").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = c[0] + S(" diagrams cannot be drawn yet.");
    world.waitFor([&] {
      const QList<QQuickItem*> notes = shown(world, S("mermaidStatus"));
      return notes.size() == 1 && notes.first()->property("text") == wanted;
    }, [&] { return S("the user to be told \"%1\"; the screen says: %2").arg(wanted, world.texts().join(S(" | "))); });
  });
});

}  // namespace

namespace mermaid {

const QString kFlowchart = S("flowchart LR\n  Cart --> Pay");
const QString kBrokenFlowchart = S("flowchart LR\n  Cart[Cart --> Pay");

QList<QQuickItem*> shown(World& world, const QString& objectName) {
  QList<QQuickItem*> out;
  collectShown(world.window().contentItem(), objectName, out);
  return out;
}

QList<QQuickItem*> drawn(World& world) {
  QList<QQuickItem*> out;
  for (QQuickItem* image : shown(world, S("mermaidImage"))) {
    // QQuickImageBase::Ready.
    if (image->property("status").toInt() == 1) out.append(image);
  }
  return out;
}

int asked(World& world) {
  world.sync();
  int count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) count += rpc.method == QLatin1String("mermaid.render") ? 1 : 0;
  return count;
}

}  // namespace mermaid
