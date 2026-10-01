// The native Open source licenses page (LicensesController, the
// OpenSourceLicenses brick): the @desktop scenarios of
// features/settings/licenses.feature. The manifest is a fixture written to
// the scenario's home, shaped as scripts/lib/third-party-licenses.ts writes it.

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "LicensesController.h"
#include "World.h"

namespace {

struct Notice {
  const char* name;
  const char* version;
  const char* license;
  QStringList bundles;
};

// Enough to tell the fields apart: no name, version or license holds another
// field's query.
const QList<Notice> kNotices{
    {"react", "19.1.0", "MIT", {QStringLiteral("web")}},
    {"effect", "4.0.0-beta.1", "MIT", {QStringLiteral("web"), QStringLiteral("server")}},
    {"@effect/platform-node", "4.0.0-beta.1", "MIT", {QStringLiteral("server")}},
    {"yaml", "2.8.1", "ISC", {QStringLiteral("web")}},
    {"Qt", "", "LGPL-3.0-only", {QStringLiteral("desktop-qt")}},
    {"MesloLGS NF", "", "Apache-2.0", {QStringLiteral("android"), QStringLiteral("assets"), QStringLiteral("mobile")}},
    {"agent-device", "0.21.7", "MIT", {QStringLiteral("device-tools")}},
    {"expo-device-hub", "0.10.1", "MIT AND Apache-2.0 AND BSD-3-Clause", {QStringLiteral("device-tools")}},
};

QString noticeText(const Notice& notice) {
  return QStringLiteral("%1 license text for %2.").arg(QLatin1String(notice.license), QLatin1String(notice.name));
}

QString manifestPath(World& world) {
  return world.homeDir() + QStringLiteral("/third-party-licenses.json");
}

void writeManifest(World& world) {
  QJsonArray entries;
  for (const Notice& notice : kNotices) {
    QJsonObject entry{{QStringLiteral("kind"), notice.bundles.contains(QStringLiteral("device-tools")) || QLatin1String(notice.version).isEmpty()
                                                   ? QStringLiteral("custom") : QStringLiteral("package")},
                      {QStringLiteral("name"), QLatin1String(notice.name)},
                      {QStringLiteral("license"), QLatin1String(notice.license)},
                      {QStringLiteral("bundles"), QJsonArray::fromStringList(notice.bundles)},
                      {QStringLiteral("noticeText"), noticeText(notice)}};
    if (!QLatin1String(notice.version).isEmpty()) entry.insert(QStringLiteral("version"), QLatin1String(notice.version));
    entries.append(entry);
  }
  QFile file(manifestPath(world));
  expect(file.open(QIODevice::WriteOnly), QStringLiteral("cannot write %1").arg(file.fileName()));
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("entries"), entries}}).toJson());
}

// Whether the scenario's manifest is missing ("the license list cannot be
// loaded"), kept on the scenario's MC.
struct Fixture {
  bool broken = false;
  bool written = false;
};

Fixture& fixture(World& world) {
  return world.mc.part<Fixture>();
}

QVariantMap licenses(World& world) {
  return world.state(QStringLiteral("licenses")).toMap();
}

QVariantList listed(World& world) {
  return licenses(world).value(QStringLiteral("entries")).toList();
}

// The page as the desktop draws it.
Brick& page(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nOpenSourceLicenses {}\n", QSize(760, 4000));
  }
  return *world.brick;
}

QString textOf(World& world, const QString& objectName) {
  page(world).grab();  // lays the list out
  return page(world).item(objectName)->property("text").toString();
}

void open(World& world) {
  LicensesController::setManifestPath(manifestPath(world));
  if (!fixture(world).broken && !fixture(world).written) {
    writeManifest(world);
    fixture(world).written = true;
  }
  if (world.shellSubscriptions() == 0) {
    // The shell starts once an MC has answered, even one since gone.
    world.connect();
    world.sync();
  }
  world.bridge().dispatch(QStringLiteral("settings.open"), {});
  world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), LicensesController::kSection}});
  world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == LicensesController::kSection; },
                [&] { return QStringLiteral("the licenses page to open; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  page(world);
}

void shown(World& world) {
  world.waitFor([&] { return licenses(world).value(QStringLiteral("status")) == QLatin1String("ready"); },
                [&] { return QStringLiteral("the notices to load; they are %1").arg(show(licenses(world))); });
  expect(listed(world).size() == kNotices.size(), QStringLiteral("%1 notices are listed").arg(listed(world).size()));
  page(world).grab();
  expect(page(world).item(QStringLiteral("license:react"))->isVisible(), QStringLiteral("react is not drawn"));
}

// The item named `name` inside `item`.
QQuickItem* child(QQuickItem* item, const QString& name) {
  for (QQuickItem* inner : item->childItems()) {
    if (inner->objectName() == name) return inner;
    if (QQuickItem* found = child(inner, name)) return found;
  }
  return nullptr;
}

QQuickItem* inside(QQuickItem* item, const QString& name) {
  QQuickItem* found = child(item, name);
  expect(found != nullptr, QStringLiteral("%1 has no %2").arg(item->objectName(), name));
  return found;
}

void search(World& world, const QString& query) {
  world.bridge().dispatch(QStringLiteral("licenses.search"), QVariantMap{{QStringLiteral("query"), query}});
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user (?:has opened|opens|views) the open source licenses"), [](World& world, const Captures&, const Table&) {
    open(world);
  });
  step(QStringLiteral("the license list cannot be loaded"), [](World& world, const Captures&, const Table&) {
    fixture(world).broken = true;
  });
  step(QStringLiteral("the list of third-party notices is shown"), [](World& world, const Captures&, const Table&) {
    shown(world);
  });
  step(QStringLiteral("\"General\" stays marked as the current section"), [](World& world, const Captures&, const Table&) {
    // What the settings navigation marks for the route (SettingsNav.currentSection).
    Brick marked(world,
                 "import QtQuick\nimport HalC2.Shell\nimport \"qrc:/hal-c2/settings/settingsPages.js\" as Pages\n"
                 "Item { property string current: Pages.current(Shell.state.route.section) }\n",
                 QSize(10, 10));
    const QString current = marked.root()->property("current").toString();
    expect(current == QLatin1String("/settings/general"), QStringLiteral("the navigation marks %1").arg(current));
  });

  step(QStringLiteral("each entry shows its version when known, its license identifier and the parts of HAL-C2 that use it"),
       [](World& world, const Captures&, const Table&) {
         shown(world);
         for (const Notice& notice : kNotices) {
           QQuickItem* row = page(world).item(QStringLiteral("license:") + QLatin1String(notice.name));
           const QVariantMap entry = row->property("modelData").toMap();
           const QString version = QLatin1String(notice.version);
           expect(version.isEmpty() ? entry.value(QStringLiteral("version")).isNull() : entry.value(QStringLiteral("version")) == version,
                  QStringLiteral("%1's version is %2").arg(QLatin1String(notice.name), show(entry)));
           expect(entry.value(QStringLiteral("license")) == QLatin1String(notice.license), show(entry));
         }
         const QVariantMap meslo = page(world).item(QStringLiteral("license:MesloLGS NF"))->property("modelData").toMap();
         expect(meslo.value(QStringLiteral("where")) == QLatin1String("Android, Assets, Mobile"), show(meslo));
         const QVariantMap qt = page(world).item(QStringLiteral("license:Qt"))->property("modelData").toMap();
         expect(qt.value(QStringLiteral("where")) == QLatin1String("Qt desktop"), show(qt));
       });

  step(QStringLiteral("the user opens the entry %1").arg(q), [](World& world, const Captures& c, const Table&) {
    shown(world);
    QQuickItem* toggle = inside(page(world).item(QStringLiteral("license:") + c[0]), QStringLiteral("toggle"));
    QTest::mouseClick(&page(world).window(), Qt::LeftButton, Qt::NoModifier, page(world).at(toggle));
    world.sync();
  });
  step(QStringLiteral("the complete notice text for %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto notice = std::find_if(kNotices.begin(), kNotices.end(), [&](const Notice& n) { return c[0] == QLatin1String(n.name); });
    world.waitFor([&] { return licenses(world).value(QStringLiteral("noticeText")) == noticeText(*notice); },
                  [&] { return QStringLiteral("the notice to open; the page is %1").arg(show(licenses(world))); });
    page(world).grab();
    QQuickItem* text = inside(page(world).item(QStringLiteral("license:") + c[0]), QStringLiteral("noticeText"));
    expect(text->isVisible() && text->property("text") == noticeText(*notice), QStringLiteral("the notice text is not drawn"));
  });

  step(QStringLiteral("the user searches the licenses for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    shown(world);
    search(world, c[0]);
  });
  step(QStringLiteral("only entries whose (package name|license|app component) matches %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString query = c[1].toLower();
    const auto field = [&](const QVariantMap& entry) {
      if (c[0] == QLatin1String("package name")) return entry.value(QStringLiteral("name")).toString();
      if (c[0] == QLatin1String("license")) return entry.value(QStringLiteral("license")).toString();
      return entry.value(QStringLiteral("where")).toString();
    };
    world.waitFor([&] { return licenses(world).value(QStringLiteral("query")) == c[1]; }, QStringLiteral("the search to apply"));
    const QVariantList entries = listed(world);
    expect(!entries.isEmpty() && entries.size() < kNotices.size(), QStringLiteral("%1 entries are listed").arg(entries.size()));
    for (const QVariant& entry : entries) {
      expect(field(entry.toMap()).toLower().contains(query), QStringLiteral("%1 is listed").arg(show(entry)));
    }
  });
  step(QStringLiteral("the page shows how many of the notices match"), [](World& world, const Captures&, const Table&) {
    const QString count = textOf(world, QStringLiteral("licenseCount"));
    expect(count == QStringLiteral("%1 of %2").arg(listed(world).size()).arg(kNotices.size()), QStringLiteral("the count reads %1").arg(count));
  });
  step(QStringLiteral("the user is told no licenses match that search"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return listed(world).isEmpty(); }, [&] { return show(licenses(world)); });
    page(world).grab();
    QQuickItem* none = page(world).item(QStringLiteral("noLicenseMatch"));
    expect(none->isVisible() && none->property("text") == QLatin1String("No licenses match that search."), QStringLiteral("no match is not said"));
  });

  step(QStringLiteral("the device tools HAL-C2 installs on demand are listed"), [](World& world, const Captures&, const Table&) {
    shown(world);
    for (const char* name : {"agent-device", "expo-device-hub"}) {
      const QVariantMap entry = page(world).item(QStringLiteral("license:") + QLatin1String(name))->property("modelData").toMap();
      expect(entry.value(QStringLiteral("where")) == QLatin1String("Device tools"), show(entry));
    }
  });

  step(QStringLiteral("the user is told the open source notices are unavailable"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return licenses(world).value(QStringLiteral("status")) == QLatin1String("error"); },
                  [&] { return show(licenses(world)); });
    page(world).grab();
    expect(page(world).item(QStringLiteral("licensesError"))->isVisible(), QStringLiteral("the failure is not drawn"));
  });
  step(QStringLiteral("the user tries again and the list loads"), [](World& world, const Captures&, const Table&) {
    fixture(world).broken = false;
    writeManifest(world);
    fixture(world).written = true;
    page(world).click(QStringLiteral("licensesRetry"));
    world.sync();
  });
});

}  // namespace
