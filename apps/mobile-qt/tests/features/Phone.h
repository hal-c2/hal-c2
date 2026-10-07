#pragma once
// What the steps files share of the phone: the screens every scenario passes
// through on its way to its own (PairingSteps.cpp, ThreadSteps.cpp).

#include <QString>

class QQuickItem;
class World;

// The pairing the phone publishes (`Shell.state.pairing`): its phase.
QString pairingPhase(World& world);
// The user enters `link` on the pairing screen and asks to pair; returns once
// the phone has an answer.
void enterPairingLink(World& world, const QString& link);
// The device, paired with the environment through the pairing screen and
// showing its threads.
void pairWithEnvironment(World& world);

// The thread list on screen, in the layout the window has room for: the phone
// layout's home screen or the desktop layout's sidebar. Waited for.
QQuickItem* threadList(World& world);
// The title of the thread on screen, "" when there is none: the phone
// layout's thread screen's, or the desktop layout's header's.
QString shownThread(World& world);

// The environment has a thread titled `title` in "shop": its id.
QString haveThread(World& world, const QString& title);
// The row of the thread list titled `title`, waited for.
QQuickItem* threadRow(World& world, const QString& title);
// The user taps the thread's row in the thread list and the thread comes.
void openThread(World& world, const QString& title);
