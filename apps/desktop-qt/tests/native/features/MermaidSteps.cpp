// Mermaid diagrams (features/timeline/markdown.feature,
// features/files/file-viewer-and-editing.feature) as the desktop draws them:
// the fake MC answers `mermaid.render` the way the MC's renderer does, the
// shell's MermaidController (the `Diagrams` singleton) asks it, and the steps
// read back the MermaidDiagram bricks of whatever brick the scenario shows
// (a reply in the timeline, or the Files tab's rendered view).

#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>

#include "Brick.h"
#include "FakeFiles.h"
#include "FilesWorkspace.h"
#include "Harness.h"
#include "Mermaid.h"
#include "World.h"

namespace {

using namespace filesteps;

// What the fake renderer draws: a box the Image can load.
const QString kSvg = QStringLiteral(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"60\" viewBox=\"0 0 160 60\">"
    "<rect x=\"1\" y=\"1\" width=\"158\" height=\"58\" rx=\"6\" fill=\"none\" stroke=\"#888\"/></svg>");

// packages/contracts mermaid.ts's answers: a bracket opened and not closed is
// the mistake the scenarios make, on the line it is on; anything else is drawn.
const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("mermaid.render"), [&mc](const FakeMc::Rpc& rpc) {
    const QString source = rpc.payload.value(QLatin1String("source")).toString();
    const QString kind = source.section(QRegularExpression(QStringLiteral("\\s")), 0, 0, QString::SectionSkipEmpty);
    const QStringList lines = source.split(QLatin1Char('\n'));
    for (qsizetype at = 0; at < lines.size(); ++at) {
      if (lines.at(at).count(QLatin1Char('[')) > lines.at(at).count(QLatin1Char(']'))) {
        mc.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("invalid")}, {QStringLiteral("kind"), kind},
                                  {QStringLiteral("reason"), QStringLiteral("A bracket is opened and not closed.")},
                                  {QStringLiteral("line"), int(at + 1)}, {QStringLiteral("column"), QJsonValue()}});
        return;
      }
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("drawn")}, {QStringLiteral("kind"), kind},
                              {QStringLiteral("svg"), kSvg}, {QStringLiteral("width"), 160}, {QStringLiteral("height"), 60}});
  });
});

void collectShown(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (!item->isVisible()) return;
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) collectShown(child, name, out);
}

QString describeNotes(World& world) {
  QStringList notes;
  for (QQuickItem* note : mermaid::shown(world, QStringLiteral("mermaidStatus"))) notes.append(note->property("text").toString());
  return QStringLiteral("%1 diagrams drawn, %2 notes [%3]")
      .arg(mermaid::drawn(world).size())
      .arg(notes.size())
      .arg(notes.join(QStringLiteral(", ")));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 holds the file %1 with a flowchart (in it|with an unclosed bracket)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString diagram = c[2] == QLatin1String("in it") ? mermaid::kFlowchart : mermaid::kBrokenFlowchart;
    fakeFiles(world.mc).files.insert(c[1], c[1].endsWith(QLatin1String(".md"))
                                               ? QStringLiteral("# Flow\n\nHow an order is paid:\n\n```mermaid\n%1\n```\n").arg(diagram)
                                               : diagram + QLatin1Char('\n'));
  });
  step(QStringLiteral("on the desktop and the phone the flowchart is drawn"), [](World& world, const Captures&, const Table&) {
    showPanel(world);
    world.waitFor([&] { return files(world).rendered() && mermaid::drawn(world).size() == 1; }, [&] { return describeNotes(world); });
    expect(mermaid::drawn(world).first()->property("width").toReal() > 0, QStringLiteral("the diagram is drawn with no width"));
  });
  step(QStringLiteral("the diagram is drawn"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mermaid::drawn(world).size() == 1; }, [&] { return describeNotes(world); });
  });
  // The terminal's; the desktop draws the diagram.
  step(QStringLiteral("in the terminal the diagram is drawn in characters, or its source is shown, named as a %1 diagram").arg(q), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the user is told where the mistake is"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<QQuickItem*> notes = mermaid::shown(world, QStringLiteral("mermaidStatus"));
      return notes.size() == 1 && notes.first()->property("text") == QLatin1String("Line 2: A bracket is opened and not closed.");
    }, [&] { return describeNotes(world); });
  });
  step(QStringLiteral("nothing claims the diagram is still being drawn"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.brick->shows(QStringLiteral("Drawing the diagram…")) && mermaid::drawn(world).isEmpty(), describeNotes(world));
    expect(mermaid::shown(world, QStringLiteral("mermaidRetry")).isEmpty(), QStringLiteral("a mistake is offered to be drawn again"));
  });
});

}  // namespace

namespace mermaid {

const QString kFlowchart = QStringLiteral("flowchart LR\n  Cart --> Pay");
const QString kBrokenFlowchart = QStringLiteral("flowchart LR\n  Cart[Cart --> Pay");

QList<QQuickItem*> shown(World& world, const QString& objectName) {
  QList<QQuickItem*> out;
  if (world.brick) collectShown(world.brick->window().contentItem(), objectName, out);
  return out;
}

QList<QQuickItem*> drawn(World& world) {
  QList<QQuickItem*> out;
  for (QQuickItem* image : shown(world, QStringLiteral("mermaidImage"))) {
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
