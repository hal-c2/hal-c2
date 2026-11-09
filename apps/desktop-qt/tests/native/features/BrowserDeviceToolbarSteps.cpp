// The device toolbar above a browser tab's page (BrowserDeviceToolbar), and
// the edges a device-sized page is resized from (BrowserResizeHandles):
// features/preview/surfaces.feature's "The user shows a device toolbar above
// a tab's page" and the scenarios after it.

#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>

#include <algorithm>
#include <functional>
#include <optional>

#include "Brick.h"
#include "Browser.h"
#include "Browsing.h"
#include "Harness.h"
#include "Preview.h"
#include "RightPanelController.h"
#include "World.h"

namespace {

// The contract's named device sizes, as the toolbar labels them.
const QStringList kPresets{
    QStringLiteral("iPhone SE"),          QStringLiteral("iPhone XR"),          QStringLiteral("iPhone 12 Pro"),
    QStringLiteral("iPhone 14 Pro Max"),  QStringLiteral("Pixel 7"),            QStringLiteral("Samsung Galaxy S8+"),
    QStringLiteral("Samsung Galaxy S20 Ultra"), QStringLiteral("iPad Mini"),     QStringLiteral("iPad Air"),
    QStringLiteral("iPad Pro"),           QStringLiteral("Surface Pro 7"),      QStringLiteral("Surface Duo"),
    QStringLiteral("Galaxy Z Fold 5"),    QStringLiteral("Asus Zenbook Fold"),  QStringLiteral("Samsung Galaxy A51/71"),
    QStringLiteral("Nest Hub"),           QStringLiteral("Nest Hub Max"),
};

// What a toolbar scenario keeps: the tabs it is about, and what was there
// before the user acted.
struct Toolbar {
  QString first;
  QString second;
  QVariantMap before;
  qsizetype resizes = 0;
  // What the width field showed after each key the user typed.
  QStringList shownWhileTyping;
};

Toolbar& toolbar(World& world) {
  return world.mc.part<Toolbar>();
}

void waitFor(World& world, const std::function<bool()>& condition, const std::function<QString()>& what) {
  webtab::waitForEngine(world, condition, what);
}

void collect(QQuickItem* item, const QString& objectName, QList<QQuickItem*>& found) {
  if (item->objectName() == objectName) found.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, objectName, found);
}

// The named item the user can see (a hidden tab's panel has one too), or null.
QQuickItem* shown(World& world, const QString& objectName) {
  if (!world.brick) return nullptr;
  QList<QQuickItem*> found;
  collect(world.brick->window().contentItem(), objectName, found);
  for (QQuickItem* item : std::as_const(found)) {
    if (item->isVisible()) return item;
  }
  return nullptr;
}

QQuickItem* item(World& world, const QString& objectName) {
  QQuickItem* found = shown(world, objectName);
  expect(found != nullptr, QStringLiteral("no %1 shows").arg(objectName));
  return found;
}

void click(World& world, const QString& objectName) {
  QQuickItem* button = item(world, objectName);
  expect(button->isEnabled(), QStringLiteral("%1 cannot be clicked").arg(objectName));
  QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(button));
}

// The menu entry `entry` of the menu `menu` opens, chosen.
void choose(World& world, const QString& menu, const QString& entry) {
  click(world, menu);
  waitFor(world, [&] { return shown(world, entry) != nullptr; }, [&] { return QStringLiteral("%1 to offer %2").arg(menu, entry); });
  click(world, entry);
  waitFor(world, [&] { return shown(world, entry) == nullptr; }, [&] { return QStringLiteral("%1 to close").arg(menu); });
}

// The id of the browser tab showing in the panel.
QString activeTab(World& world) {
  const QString id = at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")).toString();
  return id.startsWith(QLatin1String("browser:")) ? id.mid(8) : QString();
}

BrowserPage* page(World& world) {
  BrowserPage* found = Browser::page(activeTab(world));
  expect(found != nullptr, QStringLiteral("no page shows %1").arg(activeTab(world)));
  return found;
}

QQuickItem* view(World& world) {
  return item(world, QStringLiteral("browserView"));
}

// The tab's size as the MC has it.
QJsonObject mcViewport(World& world, const QString& tabId) {
  for (const QJsonObject& tab : std::as_const(world.mc.part<FakePreviews>().tabs)) {
    if (tab.value(QLatin1String("tabId")) == tabId) return tab.value(QLatin1String("viewport")).toObject();
  }
  return {};
}

qsizetype resizes(World& world) {
  return std::count_if(world.mc.calls.cbegin(), world.mc.calls.cend(), [](const FakeMc::Rpc& rpc) { return rpc.method == QLatin1String("preview.resize"); });
}

QVariant evaluate(World& world, const QString& script) {
  std::optional<QVariant> result;
  page(world)->evaluate(script, [&result](const QVariant& value) { result = value; });
  waitFor(world, [&] { return result.has_value(); }, [&] { return QStringLiteral("the page to run %1").arg(script); });
  return *result;
}

QString innerSize(World& world) {
  return evaluate(world, QStringLiteral("window.innerWidth + 'x' + window.innerHeight")).toString();
}

QString describe(World& world) {
  BrowserPage* current = Browser::page(activeTab(world));
  QQuickItem* shownView = shown(world, QStringLiteral("browserView"));
  return QStringLiteral("the page is %1 (%2), drawn %3x%4 at %5; the MC has %6")
      .arg(current ? show(current->viewport()) : QStringLiteral("not shown"), current && current->resizing() ? QStringLiteral("resizing") : QStringLiteral("settled"))
      .arg(shownView ? shownView->width() : 0)
      .arg(shownView ? shownView->height() : 0)
      .arg(shownView ? shownView->scale() : 0)
      .arg(show(QVariant(mcViewport(world, activeTab(world)).toVariantMap())));
}

// Waits for the MC to have the size the page shows.
void settle(World& world) {
  waitFor(world, [&] { return !page(world)->resizing(); }, [&] { return QStringLiteral("the size to be confirmed; ") + describe(world); });
}

bool isFill(const QVariantMap& viewport) {
  return viewport.isEmpty() || viewport.value(QStringLiteral("_tag")) == QLatin1String("fill");
}

// The page renders at width by height, and the MC keeps that size.
void rendersAt(World& world, int width, int height) {
  waitFor(world, [&] { const QJsonObject kept = mcViewport(world, activeTab(world));
                       return !page(world)->resizing() && kept.value(QLatin1String("width")).toInt() == width && kept.value(QLatin1String("height")).toInt() == height; },
          [&] { return QStringLiteral("the MC to keep %1 by %2; ").arg(width).arg(height) + describe(world); });
  const QString size = QStringLiteral("%1x%2").arg(width).arg(height);
  waitFor(world, [&] { return innerSize(world) == size; }, [&] { return QStringLiteral("the page to render at %1; it is %2").arg(size, innerSize(world)); });
}

// The panel at `size`, as the user sees it.
void resizeWindow(World& world, const QSize& size) {
  world.brick->window().resize(size);
  world.brick->root()->setSize(size);
  world.sync();
}

// The tab's menu shows the device toolbar, at the room the page has.
void showToolbar(World& world) {
  choose(world, QStringLiteral("browserMore"), QStringLiteral("browserDeviceToolbarItem"));
  waitFor(world, [&] { return shown(world, QStringLiteral("browserDeviceToolbar")) != nullptr; }, [&] { return QStringLiteral("the device toolbar to show; ") + describe(world); });
  settle(world);
}

// A browser tab with the device toolbar shown, at width by height when given.
void tabWithToolbar(World& world, int width = 0, int height = 0) {
  webtab::showTab(world);
  // Tall enough for a phone's height unscaled.
  if (height) resizeWindow(world, QSize(900, 1100));
  showToolbar(world);
  if (!width) return;
  page(world)->setViewport({{QStringLiteral("_tag"), QStringLiteral("freeform")}, {QStringLiteral("width"), width}, {QStringLiteral("height"), height}});
  rendersAt(world, width, height);
}

QString text(World& world, const QString& field) {
  return item(world, field)->property("text").toString();
}

// The user replaces what `field` holds with `value`, without leaving it.
void typeInto(World& world, const QString& field, const QString& value) {
  click(world, field);
  QQuickItem* input = item(world, field);
  waitFor(world, [&] { return input->hasActiveFocus(); }, [&] { return field + QStringLiteral(" to take the keyboard"); });
  QMetaObject::invokeMethod(input, "selectAll");
  for (const QChar c : value) QTest::keyClick(&world.brick->window(), c.toLatin1());
  world.sync();
}

// What the user is about to change, kept to compare with.
void remember(World& world) {
  settle(world);
  toolbar(world).before = page(world)->viewport();
  toolbar(world).resizes = resizes(world);
}

void typeSize(World& world, int width, int height) {
  remember(world);
  typeInto(world, QStringLiteral("browserToolbarWidth"), QString::number(width));
  typeInto(world, QStringLiteral("browserToolbarHeight"), QString::number(height));
  QTest::keyClick(&world.brick->window(), Qt::Key_Return);
  world.sync();
}

QQuickItem* edges(World& world) {
  return item(world, QStringLiteral("browserEdges"));
}

// Presses on the page's right edge and moves `by` window pixels right.
void dragRightEdge(World& world, double by, bool release) {
  QQuickItem* edge = item(world, QStringLiteral("browserEdge-right"));
  const QPoint from = world.brick->at(edge);
  const QPoint to = from + QPoint(qRound(by), 0);
  QTest::mousePress(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, from);
  QTest::mouseMove(&world.brick->window(), from + QPoint(qRound(by / 2), 0));
  QTest::mouseMove(&world.brick->window(), to);
  if (release) QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, to);
  world.sync();
}

const QStringList kSizeControls{QStringLiteral("browserToolbarPreset"), QStringLiteral("browserToolbarWidth"), QStringLiteral("browserToolbarHeight"),
                                QStringLiteral("browserToolbarAspect"), QStringLiteral("browserToolbarRotate"), QStringLiteral("browserToolbarClose")};

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user shows the device toolbar from the tab's menu"), [](World& world, const Captures&, const Table&) { showToolbar(world); });
  step(QStringLiteral("the toolbar offers %1 and the named device sizes").arg(q), [](World& world, const Captures& c, const Table&) {
    click(world, QStringLiteral("browserToolbarPreset"));
    QQuickItem* responsive = nullptr;
    waitFor(world, [&] { return (responsive = shown(world, QStringLiteral("browserToolbarPreset-responsive"))) != nullptr; },
            [] { return QStringLiteral("the toolbar's sizes to show"); });
    expect(responsive->property("text") == c[0], responsive->property("text").toString());
    QStringList missing = kPresets;
    for (int i = 0; i < kPresets.size(); ++i) {
      // Each entry is named for its preset's id; its label is what the user reads.
      const QStringList ids{QStringLiteral("iphone-se"), QStringLiteral("iphone-xr"), QStringLiteral("iphone-12-pro"), QStringLiteral("iphone-14-pro-max"),
                            QStringLiteral("pixel-7"), QStringLiteral("samsung-galaxy-s8-plus"), QStringLiteral("samsung-galaxy-s20-ultra"),
                            QStringLiteral("ipad-mini"), QStringLiteral("ipad-air"), QStringLiteral("ipad-pro"), QStringLiteral("surface-pro-7"),
                            QStringLiteral("surface-duo"), QStringLiteral("galaxy-z-fold-5"), QStringLiteral("asus-zenbook-fold"),
                            QStringLiteral("samsung-galaxy-a51-71"), QStringLiteral("nest-hub"), QStringLiteral("nest-hub-max")};
      QQuickItem* entry = shown(world, QStringLiteral("browserToolbarPreset-") + ids.value(i));
      if (entry) missing.removeAll(entry->property("text").toString());
    }
    expect(missing.isEmpty(), QStringLiteral("the toolbar does not offer %1").arg(missing.join(QStringLiteral(", "))));
    QTest::keyClick(&world.brick->window(), Qt::Key_Escape);
    waitFor(world, [&] { return shown(world, QStringLiteral("browserToolbarPreset-responsive")) == nullptr; }, [] { return QStringLiteral("the sizes to close"); });
  });
  step(QStringLiteral("the page keeps the room it has, less the toolbar's"), [](World& world, const Captures&, const Table&) {
    const QVariantMap viewport = page(world)->viewport();
    expect(viewport.value(QStringLiteral("_tag")) == QLatin1String("freeform"), describe(world));
    // Drawn as it is, not scaled down to fit.
    expect(view(world)->scale() == 1.0, describe(world));
    rendersAt(world, viewport.value(QStringLiteral("width")).toInt(), viewport.value(QStringLiteral("height")).toInt());
  });
  step(QStringLiteral("the user hides the device toolbar"), [](World& world, const Captures&, const Table&) {
    settle(world);
    choose(world, QStringLiteral("browserMore"), QStringLiteral("browserDeviceToolbarItem"));
  });
  step(QStringLiteral("the user closes the device toolbar"), [](World& world, const Captures&, const Table&) {
    settle(world);
    click(world, QStringLiteral("browserToolbarClose"));
  });
  step(QStringLiteral("the page fills the tab again"), [](World& world, const Captures&, const Table&) {
    waitFor(world, [&] { return !page(world)->resizing() && isFill(mcViewport(world, activeTab(world)).toVariantMap()) && isFill(page(world)->viewport()); },
            [&] { return QStringLiteral("the page to fill the tab; ") + describe(world); });
    expect(shown(world, QStringLiteral("browserDeviceToolbar")) == nullptr, QStringLiteral("the device toolbar still shows"));
    QQuickItem* shownView = view(world);
    waitFor(world, [&] { return shownView->scale() == 1.0 && shownView->x() == 0 && shownView->width() == shownView->parentItem()->width(); },
            [&] { return QStringLiteral("the page to fill its space; ") + describe(world); });
  });

  // Each tab its own size.
  step(QStringLiteral("the thread has two browser tabs"), [](World& world, const Captures&, const Table&) {
    webtab::showTab(world);
    toolbar(world).first = activeTab(world);
    webtab::servePage(world, QStringLiteral("/second"), QStringLiteral("Second"));
    preview::model(world).openAddress(webtab::serverUrl(world, QStringLiteral("/second")));
    waitFor(world, [&] { return !activeTab(world).isEmpty() && activeTab(world) != toolbar(world).first && Browser::page(activeTab(world)); },
            [&] { return QStringLiteral("a second tab to show; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
    toolbar(world).second = activeTab(world);
  });
  step(QStringLiteral("the user picks the %1 size in the first tab").arg(q), [](World& world, const Captures& c, const Table&) {
    world.native().controller<RightPanelController>()->showTab(QStringLiteral("browser:") + toolbar(world).first);
    waitFor(world, [&] { return activeTab(world) == toolbar(world).first; }, [] { return QStringLiteral("the first tab to show"); });
    const QString id = c[0].toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
    choose(world, QStringLiteral("browserDevice"), QStringLiteral("browserPreset-") + id);
    waitFor(world, [&] { return mcViewport(world, toolbar(world).first).value(QLatin1String("presetId")) == id; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the second tab still fills its space"), [](World& world, const Captures&, const Table&) {
    const QString second = toolbar(world).second;
    expect(isFill(mcViewport(world, second).toVariantMap()), show(QVariant(mcViewport(world, second).toVariantMap())));
    BrowserPage* other = Browser::page(second);
    expect(other && isFill(other->viewport()), QStringLiteral("the second tab's page is %1").arg(other ? show(other->viewport()) : QStringLiteral("gone")));
  });

  // Sizes of the user's own.
  step(QStringLiteral("a browser tab with the device toolbar shown"), [](World& world, const Captures&, const Table&) { tabWithToolbar(world); });
  step(QStringLiteral("a browser tab at (\\d+) by (\\d+) with the device toolbar shown"), [](World& world, const Captures& c, const Table&) {
    tabWithToolbar(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("the user types a width of (\\d+) and a height of (\\d+)"), [](World& world, const Captures& c, const Table&) {
    typeSize(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("the user previews the page at (\\d+) by (\\d+)"), [](World& world, const Captures& c, const Table&) {
    typeSize(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("the page (?:renders|still renders) at (\\d+) by (\\d+)"), [](World& world, const Captures& c, const Table&) {
    rendersAt(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("the page keeps its previous size"), [](World& world, const Captures&, const Table&) {
    const QVariantMap before = toolbar(world).before;
    const QString width = QString::number(before.value(QStringLiteral("width")).toInt());
    const QString height = QString::number(before.value(QStringLiteral("height")).toInt());
    // The fields show the size the page has again.
    waitFor(world, [&] { return text(world, QStringLiteral("browserToolbarWidth")) == width && text(world, QStringLiteral("browserToolbarHeight")) == height; },
            [&] { return QStringLiteral("the toolbar to show %1 by %2; it shows %3 by %4")
                      .arg(width, height, text(world, QStringLiteral("browserToolbarWidth")), text(world, QStringLiteral("browserToolbarHeight"))); });
    expect(resizes(world) == toolbar(world).resizes, QStringLiteral("the desktop asked the MC to resize the page"));
    expect(page(world)->viewport() == before, describe(world));
  });

  // The aspect ratio.
  step(QStringLiteral("the user locks the aspect ratio and changes the width to (\\d+)"), [](World& world, const Captures& c, const Table&) {
    settle(world);
    click(world, QStringLiteral("browserToolbarAspect"));
    waitFor(world, [&] { return item(world, QStringLiteral("browserToolbarAspect"))->property("checked").toBool(); }, [] { return QStringLiteral("the ratio to lock"); });
    typeInto(world, QStringLiteral("browserToolbarWidth"), c[0]);
  });
  step(QStringLiteral("the height becomes (\\d+)"), [](World& world, const Captures& c, const Table&) {
    expect(text(world, QStringLiteral("browserToolbarHeight")) == c[0], QStringLiteral("the height is %1").arg(text(world, QStringLiteral("browserToolbarHeight"))));
    QTest::keyClick(&world.brick->window(), Qt::Key_Return);
    const QString width = text(world, QStringLiteral("browserToolbarWidth"));
    rendersAt(world, width.toInt(), c[0].toInt());
  });
  step(QStringLiteral("the user unlocks the aspect ratio"), [](World& world, const Captures&, const Table&) {
    settle(world);
    click(world, QStringLiteral("browserToolbarAspect"));
    waitFor(world, [&] { return !item(world, QStringLiteral("browserToolbarAspect"))->property("checked").toBool(); }, [] { return QStringLiteral("the ratio to unlock"); });
  });
  step(QStringLiteral("changing the width leaves the height alone"), [](World& world, const Captures&, const Table&) {
    const QString height = text(world, QStringLiteral("browserToolbarHeight"));
    typeInto(world, QStringLiteral("browserToolbarWidth"), QStringLiteral("320"));
    expect(text(world, QStringLiteral("browserToolbarHeight")) == height, QStringLiteral("the height became %1").arg(text(world, QStringLiteral("browserToolbarHeight"))));
  });
  step(QStringLiteral("the user has typed a width of (\\d+)"), [](World& world, const Captures& c, const Table&) {
    typeInto(world, QStringLiteral("browserToolbarWidth"), c[0]);
  });
  step(QStringLiteral("locking the aspect ratio is unavailable"), [](World& world, const Captures&, const Table&) {
    expect(!item(world, QStringLiteral("browserToolbarAspect"))->isEnabled(), QStringLiteral("the aspect ratio can be locked"));
  });
  step(QStringLiteral("the preview is set to a device size of (\\d+) by (\\d+) with the aspect ratio locked"), [](World& world, const Captures& c, const Table&) {
    tabWithToolbar(world, c[0].toInt(), c[1].toInt());
    click(world, QStringLiteral("browserToolbarAspect"));
    waitFor(world, [&] { return item(world, QStringLiteral("browserToolbarAspect"))->property("checked").toBool(); }, [] { return QStringLiteral("the ratio to lock"); });
  });
  step(QStringLiteral("the user types the width (\\d+)"), [](World& world, const Captures& c, const Table&) {
    click(world, QStringLiteral("browserToolbarWidth"));
    QQuickItem* input = item(world, QStringLiteral("browserToolbarWidth"));
    waitFor(world, [&] { return input->hasActiveFocus(); }, [] { return QStringLiteral("the width to take the keyboard"); });
    QMetaObject::invokeMethod(input, "selectAll");
    toolbar(world).shownWhileTyping.clear();
    for (const QChar ch : c[0]) {
      QTest::keyClick(&world.brick->window(), ch.toLatin1());
      world.sync();
      toolbar(world).shownWhileTyping.append(input->property("text").toString());
    }
  });
  step(QStringLiteral("the width field shows (\\d+) while the user types"), [](World& world, const Captures& c, const Table&) {
    QStringList typed;
    for (qsizetype i = 1; i <= c[0].size(); ++i) typed.append(c[0].left(i));
    expect(toolbar(world).shownWhileTyping == typed,
           QStringLiteral("the width field showed %1").arg(toolbar(world).shownWhileTyping.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the preview is set to (\\d+) by (\\d+)"), [](World& world, const Captures& c, const Table&) {
    QTest::keyClick(&world.brick->window(), Qt::Key_Return);
    rendersAt(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("the user rotates the viewport"), [](World& world, const Captures&, const Table&) {
    settle(world);
    click(world, QStringLiteral("browserToolbarRotate"));
  });

  // While a size is applied, and when it cannot be.
  step(QStringLiteral("the user has just picked a device size for a tab"), [](World& world, const Captures&, const Table&) {
    tabWithToolbar(world);
    world.mc.hold(QStringLiteral("preview.resize"));
    choose(world, QStringLiteral("browserToolbarPreset"), QStringLiteral("browserToolbarPreset-iphone-se"));
  });
  step(QStringLiteral("the MC has not confirmed the size yet"), [](World& world, const Captures&, const Table&) {
    waitFor(world, [&] { return world.mc.heldAnswers() > 0; }, [] { return QStringLiteral("the desktop to ask the MC for the size"); });
    expect(page(world)->resizing(), describe(world));
  });
  step(QStringLiteral("the toolbar's size controls cannot be used until it does"), [](World& world, const Captures&, const Table&) {
    for (const QString& control : kSizeControls) expect(!item(world, control)->isEnabled(), QStringLiteral("%1 can be used").arg(control));
    world.mc.answerHeld();
    waitFor(world, [&] { return std::all_of(kSizeControls.cbegin(), kSizeControls.cend(), [&](const QString& control) { return item(world, control)->isEnabled(); }); },
            [&] { return QStringLiteral("the controls to be usable; ") + describe(world); });
  });
  step(QStringLiteral("the user picks another size from the tab's Device size menu"), [](World& world, const Captures&, const Table&) {
    waitFor(world, [&] { return world.mc.heldAnswers() > 0; }, [] { return QStringLiteral("the desktop to ask the MC for the size"); });
    toolbar(world).resizes = resizes(world);
    QMetaObject::invokeMethod(item(world, QStringLiteral("browserDeviceToolbar")), "pick", Q_ARG(QVariant, QStringLiteral("ipad-mini")));
  });
  step(QStringLiteral("the desktop asks the MC for no other size and the tab keeps the first"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    waitFor(world, [&] { return !page(world)->resizing(); }, [&] { return QStringLiteral("the size to be confirmed; ") + describe(world); });
    expect(resizes(world) == toolbar(world).resizes, QStringLiteral("the desktop asked the MC for %1 more sizes").arg(resizes(world) - toolbar(world).resizes));
    expect(page(world)->viewport().value(QStringLiteral("presetId")).toString() == QLatin1String("iphone-se"), describe(world));
  });
  step(QStringLiteral("the desktop cannot resize the page to the size the user picked"), [](World& world, const Captures&, const Table&) {
    remember(world);
    world.mc.refusals.insert(QStringLiteral("preview.resize"), QStringLiteral("The page could not be resized"));
    choose(world, QStringLiteral("browserToolbarPreset"), QStringLiteral("browserToolbarPreset-iphone-se"));
  });
  step(QStringLiteral("the tab returns to its previous size"), [](World& world, const Captures&, const Table&) {
    const QVariantMap before = toolbar(world).before;
    waitFor(world, [&] { return !page(world)->resizing() && page(world)->viewport() == before; }, [&] { return QStringLiteral("the page to be %1 again; ").arg(show(before)) + describe(world); });
    expect(text(world, QStringLiteral("browserToolbarWidth")) == QString::number(before.value(QStringLiteral("width")).toInt()), text(world, QStringLiteral("browserToolbarWidth")));
  });

  // The page's edges.
  step(QStringLiteral("the user drags the page's right edge (\\d+) pixels wider"), [](World& world, const Captures& c, const Table&) {
    settle(world);
    // The page stays centred, so its edge moves half as far as it grows.
    dragRightEdge(world, c[0].toDouble() / 2 * view(world)->scale(), true);
  });
  step(QStringLiteral("the page renders at (\\d+) by (\\d+) and the toolbar shows the new size"), [](World& world, const Captures& c, const Table&) {
    rendersAt(world, c[0].toInt(), c[1].toInt());
    expect(text(world, QStringLiteral("browserToolbarWidth")) == c[0] && text(world, QStringLiteral("browserToolbarHeight")) == c[1],
           QStringLiteral("the toolbar shows %1 by %2").arg(text(world, QStringLiteral("browserToolbarWidth")), text(world, QStringLiteral("browserToolbarHeight"))));
  });
  step(QStringLiteral("the keyboard focus is on the page's right edge"), [](World& world, const Captures&, const Table&) {
    QQuickItem* edge = item(world, QStringLiteral("browserEdge-right"));
    edge->forceActiveFocus(Qt::TabFocusReason);
    waitFor(world, [&] { return edge->hasActiveFocus(); }, [] { return QStringLiteral("the right edge to take the keyboard"); });
  });
  step(QStringLiteral("the user presses (Right arrow|Shift and Right arrow|Left arrow)"), [](World& world, const Captures& c, const Table&) {
    const Qt::Key key = c[0].endsWith(QLatin1String("Left arrow")) ? Qt::Key_Left : Qt::Key_Right;
    QTest::keyClick(&world.brick->window(), key, c[0].startsWith(QLatin1String("Shift")) ? Qt::ShiftModifier : Qt::NoModifier);
  });
  step(QStringLiteral("the page renders at (\\d+) by (\\d+) once the user pauses"), [](World& world, const Captures& c, const Table&) {
    rendersAt(world, c[0].toInt(), c[1].toInt());
  });
  step(QStringLiteral("a browser tab (\\d+) pixels wide and (\\d+) pixels tall with the device toolbar shown"), [](World& world, const Captures& c, const Table&) {
    webtab::showTab(world);
    resizeWindow(world, QSize(c[0].toInt(), c[1].toInt()));
    showToolbar(world);
  });
  step(QStringLiteral("the page is shown smaller, centred and in proportion, so all of it fits in the tab"), [](World& world, const Captures&, const Table&) {
    QQuickItem* shownView = view(world);
    QQuickItem* area = shownView->parentItem();
    const double scale = shownView->scale();
    const QRectF drawn(shownView->x(), shownView->y(), shownView->width() * scale, shownView->height() * scale);
    // One scale for both sides: in proportion.
    expect(scale < 1.0 && drawn.left() >= 0 && drawn.top() >= 0 && drawn.right() <= area->width() && drawn.bottom() <= area->height(),
           QStringLiteral("the page is drawn at %1 in %2x%3; ").arg(scale).arg(area->width()).arg(area->height()) + describe(world));
    expect(qAbs(drawn.center().x() - area->width() / 2) <= 1, QStringLiteral("the page is not centred: %1 wide at x %2 in %3").arg(drawn.width()).arg(drawn.x()).arg(area->width()));
  });
  step(QStringLiteral("the page has no edges to drag or to move with the keyboard"), [](World& world, const Captures&, const Table&) {
    for (const QString& edge : {QStringLiteral("browserEdge-right"), QStringLiteral("browserEdge-bottom"), QStringLiteral("browserEdge-corner")})
      expect(shown(world, edge) == nullptr, QStringLiteral("%1 shows").arg(edge));
  });
  step(QStringLiteral("the user is dragging the edge of a device-sized page"), [](World& world, const Captures&, const Table&) {
    tabWithToolbar(world, 400, 800);
    dragRightEdge(world, 20, false);
    waitFor(world, [&] { return !edges(world)->property("size").isNull(); }, [] { return QStringLiteral("the drag to show a size"); });
  });
  step(QStringLiteral("the page's size is changed from the device toolbar"), [](World& world, const Captures&, const Table&) {
    toolbar(world).resizes = resizes(world);
    QMetaObject::invokeMethod(item(world, QStringLiteral("browserDeviceToolbar")), "pick", Q_ARG(QVariant, QStringLiteral("iphone-se")));
    world.sync();
  });
  step(QStringLiteral("the drag is dropped"), [](World& world, const Captures&, const Table&) {
    expect(edges(world)->property("size").isNull() && edges(world)->property("start").isNull(), QStringLiteral("the drag goes on"));
    // The pointer moves on and lets go: nothing changes.
    QQuickItem* edge = item(world, QStringLiteral("browserEdge-right"));
    const QPoint to = world.brick->at(edge) + QPoint(60, 0);
    QTest::mouseMove(&world.brick->window(), to);
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, to);
    world.sync();
  });
  step(QStringLiteral("the page keeps the size that was chosen"), [](World& world, const Captures&, const Table&) {
    rendersAt(world, 375, 667);
    expect(page(world)->viewport().value(QStringLiteral("presetId")) == QLatin1String("iphone-se"), describe(world));
    expect(resizes(world) == toolbar(world).resizes + 1, QStringLiteral("the desktop asked the MC for %1 sizes").arg(resizes(world) - toolbar(world).resizes));
  });
});

}  // namespace
