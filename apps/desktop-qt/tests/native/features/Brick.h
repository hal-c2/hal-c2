#pragma once

#include <QByteArray>
#include <QImage>
#include <QPointF>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSize>

#include <memory>

class World;

// A brick of qml/HalC2/Bricks loaded into an offscreen window over the
// scenario's shell: its singletons (Shell, Theme, Terminals, Settings) are the world's.
// Steps drive it as the user would, with QTest's mouse and keys on the
// window, and read back what it draws. A brick that outlives a step lives in
// World::brick, which goes before the shell does.
class Brick {
public:
  // `qml` is a document importing HalC2.Bricks, whose root is laid out at `size`.
  Brick(World& world, const QByteArray& qml, const QSize& size);
  ~Brick();
  // Registers the bricks' singletons. Call it from a Steps initialiser, so a
  // brick has them in a run with no ShellRuntime (whose Shell and Theme
  // resolve the same way, from the engine).
  static void registerSingletons();

  QQuickWindow& window() { return m_window; }
  QQuickItem* root() const { return m_root.get(); }
  // The item named `objectName` (fails the step when there is none).
  QQuickItem* item(const QString& objectName) const;
  // `item`'s point at (fx, fy) of its size, in window coordinates.
  QPoint at(const QQuickItem* item, double fx = 0.5, double fy = 0.5);
  void click(const QString& objectName);
  // The window as it is drawn now.
  QImage grab();
  // Whether a visible item shows `text` (a Text or Label's `text`).
  bool shows(const QString& text) const;
  // The scenario's key presses ("the user presses Escape") go to this brick's
  // window, to whatever has its keyboard focus.
  bool takesKeys = false;
  // Presses a key as keybindings.json spells it ("escape", "mod+enter",
  // "shift+tab", "arrowup"): mod is the platform's primary modifier.
  // False when nothing in the window took it.
  bool press(const QString& key);

private:
  QQmlEngine m_engine;
  QQuickWindow m_window;
  std::unique_ptr<QQuickItem> m_root;
};
