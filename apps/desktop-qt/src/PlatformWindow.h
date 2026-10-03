#pragma once

class QWindow;

// Set before creating native controls; disabled restores the system preference.
void applyApplicationAppearance(bool enabled, bool dark);

// Whether the system asks apps to reduce motion. macOS says; elsewhere Qt has
// no hint for it, so the app's own "Reduce motion" setting is the way.
bool systemReducedMotion();

// Frosted backdrop behind a transparent window where the platform can draw it
// itself (macOS), optionally using qt-liquid-glass. Elsewhere the compositor
// owns blur (see docs/internals/desktop-qt.md), so this is a no-op.
void applyWindowBlur(QWindow* window, bool enabled, bool dark, bool liquidGlass = false);
