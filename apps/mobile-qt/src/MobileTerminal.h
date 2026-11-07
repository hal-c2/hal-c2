#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

class NativeShell;
class QQuickItem;
class ShellBridge;

namespace mobileterminal {

// What Control-<first character> is: a-z, @ and [\]^_? by their control codes,
// anything else as it is (upstream T3 Code's accessory row).
QString withControl(const QString& data);
// A pasted text as a shell should get it, with no bracketed-paste markers:
// lines separated by Return, tabs kept, any other control character a space.
QString forPaste(const QString& text);
// A terminal's state in a word, from its MC summary's `status` and whether a
// task runs in it; no status is a terminal not started.
QString statusLabel(const QString& status, bool busy);

constexpr double kDefaultTextSize = 10.5;
constexpr double kMinTextSize = 6;
constexpr double kMaxTextSize = 14;
constexpr double kTextSizeStep = 0.5;
// COMPOSER_CONTEXT_MAX_RECORDS and _TERMINAL_TEXT_MAX_CHARS of packages/contracts.
constexpr qsizetype kMaxContextItems = 200;
constexpr qsizetype kMaxContextChars = 64000;

}  // namespace mobileterminal

// What the phone's terminal screen adds to the desktop's TerminalController,
// which keeps the terminals: the key row's held modifier and paste, the text
// size, the terminal menu's rows, and picking visible lines for the draft.
//
// Publishes `mobileTerminal`:
//   {terminal:  the label of the terminal shown,
//    label:     the state in a word of the terminal shown, or the one opening would show,
//    modifiers: the row's modifier keys for the thread's environment's system,
//    held:      the modifier waiting for a key, "" for none,
//    textSize:  points,
//    context:   {lines, start, end, tooLarge} while choosing lines, or null}
//
// Actions: `mobileTerminal.input {data}` (what the terminal says: the keyboard
// and the row's keys; a held modifier applies to one character or arrow),
// `mobileTerminal.modifier {key}` (holds it, or lets go), `mobileTerminal.paste`,
// `mobileTerminal.clear`, `mobileTerminal.textSize {points}`,
// `mobileTerminal.covered {covered}` (another screen is over the thread's),
// `mobileTerminal.menu {x, y, lines}` (the terminal menu; `lines` are the visible
// ones, none on the thread's screen),
// `mobileTerminal.context.open {lines}`, `.tap {index}`, `.attach` and `.cancel`.
class MobileTerminal : public QObject {
  Q_OBJECT

public:
  MobileTerminal(ShellBridge* bridge, NativeShell* native, const QString& storePath);

private:
  bool handle(const QString& action, const QVariant& payload);
  void input(const QString& data);
  void toggleModifier(const QString& key);
  void paste();
  void clear();
  void openMenu(const QVariantMap& args);
  void setTextSize(double size);
  void openContext(const QStringList& lines);
  void tapContextLine(int index);
  void attachContext();
  void closeContext();
  QString contextText() const;
  // "darwin", "linux", "windows" or "" for the thread's environment.
  QString hostSystem() const;
  QString shownTerminalId() const;
  QVariantMap shownTerminal() const;
  void publish();

  ShellBridge* m_bridge;
  NativeShell* m_native;
  QString m_storePath;
  QString m_held;
  QString m_heldFor;
  double m_textSize = mobileterminal::kDefaultTextSize;
  bool m_choosing = false;
  // The terminal the lines are from, which may be gone before they are attached.
  QVariantMap m_contextTerminal;
  QStringList m_contextLines;
  int m_contextStart = 0;
  int m_contextEnd = 0;
  // The first of two taps, or -1.
  int m_contextAnchor = -1;
};

// Sends a Terminal item the events its own encoders read, so a key the screen
// draws goes out as the program in the shell asked keys to (application cursor
// keys and the like), and a finger scrolls what a wheel would.
class TerminalEvents : public QObject {
  Q_OBJECT

public:
  using QObject::QObject;

  Q_INVOKABLE void key(QQuickItem* item, int key, int modifiers = 0);
  // `pixels` as a wheel has them: positive scrolls towards older output.
  Q_INVOKABLE void wheel(QQuickItem* item, qreal pixels);
  // The left button, in the item's coordinates: "press", "move" or "release".
  Q_INVOKABLE void mouse(QQuickItem* item, const QString& what, qreal x, qreal y, int modifiers = 0);
};
