#pragma once
// The composer as the desktop draws it (qml/HalC2/Bricks/Composer.qml) over
// the scenario's shell, kept on screen for the scenario (World::brick) so the
// steps type, press and click as the user does. ComposerBrickSteps.cpp owns it.

#include <QString>

class Brick;
class QQuickItem;
class World;

// The composer on screen with the keyboard in its editor; loaded on first use.
Brick& composerBrick(World& world);
// Whether a step already put the composer on screen.
bool composerBrickShown(World& world);
// The Composer item, its editor (the TextArea) and its ComposerVimKeys.
QQuickItem* composerItem(World& world);
QQuickItem* composerEditor(World& world);
// The editor has what the shell last published and the shell has what the
// editor holds (its debounced text reached the controller).
void settleComposer(World& world);
// Presses `key` ("Enter", "Shift+Tab", "mod+alt+Enter", "w") in the composer.
// False when the key is not the composer's to take: no composer is on screen
// and nothing says the keyboard is in one.
bool pressInComposer(World& world, const QString& key);
// Types `text` into the editor, a key at a time.
void typeInComposer(World& world, const QString& text);
// The item named `objectName` anywhere in the composer's window, popups
// included; null when there is none.
QQuickItem* composerPart(World& world, const QString& objectName);

// "X is listed", "X is not listed" and "X shows Y" are the model picker's
// while the composer is on screen: they check it and return true. False
// leaves the step to its own domain (the palette, previews, terminals).
bool modelPickerLists(World& world, const QString& name, bool listed);
bool modelPickerShows(World& world, const QString& name, const QString& reason);
// "the user chooses X": the row named X of the open model picker.
bool modelPickerChooses(World& world, const QString& name);
// "the user removes X": the attachment X of the draft on screen.
bool removeComposerAttachment(World& world, const QString& name);
