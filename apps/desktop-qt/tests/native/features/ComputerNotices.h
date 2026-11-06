#pragma once

#include <QList>
#include <QString>

class QQuickItem;
class QQuickWindow;
class World;

// The desktop's real window and the thread notice about a cluster member,
// as ConnectionNoticeSteps drives them, for the steps of other files.
namespace computerNotices {

// The window, drawn by DefaultShell from the source tree's bricks.
QQuickWindow* window(World& world);
QList<QQuickItem*> shownNamed(QQuickWindow* window, const QString& name);
// The cluster member `name`, with a thread of it open in the window.
void lookAt(World& world, const QString& name);
// `name`'s MC goes down or comes back, as the shell is told.
void setOnline(World& world, const QString& name, bool online);
// What the thread's notice is and what the window shows, for failures.
QString describe(World& world);

}  // namespace computerNotices
