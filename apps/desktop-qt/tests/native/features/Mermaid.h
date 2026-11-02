#pragma once
// The Mermaid steps' side (MermaidSteps.cpp) for the timeline's and the file
// viewer's: the diagrams the scenarios write, and what the shown brick draws.

#include <QList>
#include <QString>

class QQuickItem;
class World;

namespace mermaid {

// A flowchart, and one with a bracket left open on its second line.
extern const QString kFlowchart;
extern const QString kBrokenFlowchart;

// The visible items named `objectName` in the shown brick's window.
QList<QQuickItem*> shown(World& world, const QString& objectName);
// The diagrams it shows drawn: visible and loaded.
QList<QQuickItem*> drawn(World& world);
// How often the MC was asked to draw one.
int asked(World& world);

}  // namespace mermaid
