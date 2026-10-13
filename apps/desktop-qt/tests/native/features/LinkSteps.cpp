// A link's menu and what following a link opened, shared by the terminal's
// links (TerminalMenu, terminal/links-and-graphics.feature) and a reply's
// (Markdown's link.menu, timeline/scrolling-and-links.feature).

#include <QQuickItem>

#include "Brick.h"
#include "Harness.h"
#include "World.h"

namespace {

// The shell's menu (MenuController) a reply's link opened; empty for none.
QVariantList shellMenuItems(World& world) {
  return at(world.state(QStringLiteral("menu")), QStringLiteral("items")).toList();
}

// The open menu's entries: the shell's, else the terminal's link entries.
QStringList offered(World& world) {
  QStringList labels;
  for (const QVariant& item : shellMenuItems(world)) labels.append(item.toMap().value(QStringLiteral("label")).toString());
  if (!labels.isEmpty() || !world.brick) return labels;
  for (const QString& name : {QStringLiteral("terminalOpenLink"), QStringLiteral("terminalCopyLink")}) {
    QQuickItem* item = world.brick->item(name);
    if (item->isVisible() && item->height() > 0) labels.append(item->property("text").toString());
  }
  return labels;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the menu offers %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList labels = offered(world);
    expect(labels.contains(c[0]) && labels.contains(c[1]), QStringLiteral("the menu offers %1").arg(labels.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user chooses %1 from the link's menu").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    for (const QVariant& item : shellMenuItems(world)) {
      if (item.toMap().value(QStringLiteral("label")) == c[0]) {
        world.bridge().dispatch(QStringLiteral("menu.select"),
                                QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), item.toMap().value(QStringLiteral("id"))}});
        world.sync();
        return;
      }
    }
    for (const QString& name : {QStringLiteral("terminalOpenLink"), QStringLiteral("terminalCopyLink")}) {
      if (world.brick->item(name)->property("text") == c[0]) {
        world.brick->click(name);
        world.sync();
        return;
      }
    }
    fail(QStringLiteral("the menu offers %1").arg(offered(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("nothing is opened"), [](World& world, const Captures&, const Table&) {
    QStringList opened;
    for (const QUrl& url : std::as_const(world.openedUrls)) opened.append(url.toString());
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      if (rpc.method == QLatin1String("shell.openInEditor")) opened.append(QStringLiteral("the editor"));
    }
    // A reply's links, as the timeline brick records them (MarkdownSteps).
    if (world.brick) {
      for (const QVariant& link : world.brick->root()->property("activated").toList()) opened.append(link.toString());
    }
    expect(opened.isEmpty(), QStringLiteral("%1 was opened").arg(opened.join(QStringLiteral(", "))));
  });
});

}  // namespace
