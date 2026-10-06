#pragma once

#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QUrl>
#include <QVariant>

#include <functional>
#include <memory>

#include "MobileApp.h"
#include "PairableMc.h"

class NativeShell;
class QQuickItem;
class QQuickWindow;
class ShellBridge;

// A phone and the environment it can pair with. The phone is the app as
// main.cpp builds it (MobileApp), its real root (MobileShell.qml) in a window
// the steps tap and type into; the environment is the desktop harness's fake
// MC with the HTTP side of pairing. One per scenario.
class World {
public:
  World();
  ~World();

  // The environment ("My MacBook" unless a step renames it) and its MC, with
  // the project "shop" and one thread in it.
  PairableMc environment;
  FakeMc& mc;
  bool checking = false;  // the running step is an outcome (Step::outcome)
  // The pairing link the scenario is about: what the user enters.
  QString link;
  // The thread the user is in (its id on the MC), and its running turn.
  QString thread;
  QString run;
  // The addresses the app asked the system to open and what it copied,
  // recorded instead of reaching the system's browser and clipboard.
  QList<QUrl> openedUrls;
  QString clipboard;

  // The user opens the app; nothing when it is open.
  void open();
  // The app is closed: its process goes, its files stay.
  void close();
  bool isOpen() const { return m_app != nullptr; }
  // The app, opened on first use.
  MobileApp& app();
  ShellBridge& bridge();
  NativeShell& native();
  QQuickWindow& window();
  QVariant state(const QString& key);
  // Where the phone keeps its files, across restarts.
  QString homeDir() const { return m_home.path(); }

  // What is on screen. An item counts when it is visible, so an objectName
  // two screens share is the one of the screen showing.
  QQuickItem* find(const QString& objectName);
  // The same, waited for; fails the step when it does not come.
  QQuickItem* item(const QString& objectName);
  // The visible item for which `matches` holds, or null.
  QQuickItem* findWhere(const std::function<bool(QQuickItem*)>& matches);
  // Whether the sheet, dialog or menu named `objectName` is on screen, on its
  // way in or out included. A popup is not an item.
  bool popupShowing(const QString& objectName);
  // Waits for it to be up, its way in finished, or (`open` false) to be gone
  // from the screen.
  void awaitPopup(const QString& objectName, bool open = true);
  // Every text a visible item shows, for a failure to quote.
  QStringList texts();
  // Whether a visible item's text is `text`, or has it in it.
  bool shows(const QString& text, bool whole = true);

  // A finger on the item's middle: a touch press and release, which must
  // land inside the window. The item is waited for until it can be tapped.
  void tap(QQuickItem* item);
  void tap(const QString& objectName);
  // A finger held on the item's middle until `until` holds (a long press's
  // menu is up), then lifted.
  void hold(QQuickItem* item, const std::function<bool()>& until, const QString& what);
  // Keys into whatever has the keyboard.
  void type(const QString& text);
  // Android's Back.
  void back();

  // `what` is read on timeout, so it can describe the state the wait gave up on.
  void waitFor(const std::function<bool()>& condition, const std::function<QString()>& what);
  void waitFor(const std::function<bool()>& condition, const QString& what);
  // A round trip through the MC: everything the MC sent before, and every
  // answer to a call sent before, has been handled once it returns.
  void sync();

private:
  // Where a finger lands on `item`: its middle, which must be on the screen.
  QPoint middleOf(QQuickItem* item);

  QTemporaryDir m_home;
  std::unique_ptr<MobileApp> m_app;
};
