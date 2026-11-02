#pragma once
// The Mermaid steps' side (MermaidSteps.cpp) for the Files screen's and a
// page's (SpaceSteps.cpp): the diagrams the scenarios write, and what the
// screen draws.

#include <QList>
#include <QString>

class QQuickItem;
class World;

namespace mermaid {

// A flowchart, and one with a bracket left open on its second line.
extern const QString kFlowchart;
extern const QString kBrokenFlowchart;

// The visible items named `objectName` on screen.
QList<QQuickItem*> shown(World& world, const QString& objectName);
// The diagrams on screen drawn: visible and loaded.
QList<QQuickItem*> drawn(World& world);
// How often the MC was asked to draw one.
int asked(World& world);

// A page's diagram (SpaceSteps.cpp): whether the scenario's diagram is on a
// page, and a check that it shows the diagram's source and no picture.
bool onPage(World& world);
void expectPageSource(World& world);

}  // namespace mermaid
