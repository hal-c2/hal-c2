// Custom models the user saved for a provider, as the MC lists them after
// its own (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QJSValue>
#include <QQuickItem>

#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QString customSlug(int n) {
  return S("custom-model-%1").arg(n);
}

QString customName(int n) {
  return S("Custom Model %1").arg(n);
}

// The names the picker's open list shows.
QStringList listed(World& world) {
  QQuickItem* picker = composerPart(world, S("modelPicker"));
  expect(picker != nullptr, S("the composer has no model picker"));
  QVariant value = picker->property("rows");
  if (value.userType() == qMetaTypeId<QJSValue>()) value = value.value<QJSValue>().toVariant();
  QStringList names;
  for (const QVariant& row : value.toList()) names.append(row.toMap().value(S("model")).toMap().value(S("name")).toString());
  return names;
}

struct Saved {
  int count = 0;
};

const Steps steps([] {
  step(S("the user has saved (\\d+) custom models for Codex"), [](World& world, const Captures& c, const Table&) {
    const int count = c[0].toInt();
    world.mc.part<Saved>().count = count;
    QJsonArray list = fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
    for (qsizetype i = 0; i < list.size(); ++i) {
      QJsonObject entry = list.at(i).toObject();
      if (entry.value(QLatin1String("instanceId")) != QLatin1String("codex")) continue;
      QJsonArray models = entry.value(QLatin1String("models")).toArray();
      for (int n = 1; n <= count; ++n) {
        models.append(QJsonObject{{S("slug"), customSlug(n)}, {S("name"), customName(n)}, {S("isCustom"), true}});
      }
      entry.insert(S("models"), models);
      list.replace(i, entry);
    }
    publishProviders(world.mc, list);
    world.sync();
  });
  step(S("all (\\d+) custom models are offered"), [](World& world, const Captures& c, const Table&) {
    const int count = c[0].toInt();
    world.waitFor([&] {
      const QStringList names = listed(world);
      for (int n = 1; n <= count; ++n) {
        if (!names.contains(customName(n))) return false;
      }
      return true;
    }, [&] { return S("all %1 custom models listed; the picker lists %2").arg(count).arg(listed(world).join(S(", "))); });
    // Each one has a row in the list the picker draws, not only an entry in its model.
    QQuickItem* list = composerPart(world, S("modelPickerRow:codex:%1").arg(customSlug(1)));
    while (list && !list->inherits("QQuickListView")) list = list->parentItem();
    expect(list != nullptr, S("the picker draws no list of Codex's models"));
    expect(list->property("count").toInt() >= count, S("the picker's list holds %1 rows").arg(list->property("count").toInt()));
  });
  step(S("a thread set to the (\\d+)th custom model shows that model as chosen"), [](World& world, const Captures& c, const Table&) {
    const int n = c[0].toInt();
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), customSlug(n)}});
    world.mc.sendRow(kThread, row);
    world.sync();
    QQuickItem* picker = composerPart(world, S("modelPicker"));
    expect(picker != nullptr, S("the composer has no model picker"));
    world.waitFor([&] { return composer(world).value(S("selectedModel")) == customSlug(n) && picker->property("triggerTitle") == customName(n); },
                  [&] { return S("%1 chosen; the composer is on %2 and reads %3").arg(customName(n), composer(world).value(S("selectedModel")).toString(),
                                                                                       picker->property("triggerTitle").toString()); });
  });
});

}  // namespace
