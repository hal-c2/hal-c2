#pragma once
// What another steps file needs from BrowserSteps.cpp: a thread's browser tab
// on a real page, served by the dev server there.

#include <QList>
#include <QString>
#include <QVariant>

#include <functional>

class BrowserPage;
class QQuickWindow;
class World;

namespace webtab {

// The dev server's page at `path`: a document titled `title` with `body`.
void servePage(World& world, const QString& path, const QString& title, const QString& body = {});
QString serverUrl(World& world, const QString& path = QStringLiteral("/"));
// The thread has one browser tab, drawn, showing the dev server's `path`.
void showTab(World& world, const QString& path = QStringLiteral("/"));
// The thread's pages show in browser tabs here, as the desktop's do.
void embed(World& world);
// The thread shown with its pages in browser tabs here and the side panel drawn, as the desktop does.
void drawEmbedded(World& world);
// Waits for a browser tab to show, the one the scenario is about from now on.
void waitForTab(World& world);
// The page of the tab the scenario is about.
BrowserPage* page(World& world);
QString tabId(World& world);
// Runs `script` in the tab's page and waits for its value.
QVariant evaluate(World& world, const QString& script);
// Waits on Chromium, which runs in its own processes, with a longer bound.
void waitForEngine(World& world, const std::function<bool()>& condition, const std::function<QString()>& what);
// The popup windows the page opened.
QList<QQuickWindow*> popups(World& world);

}  // namespace webtab
