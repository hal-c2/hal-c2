// The options of the chosen model as the composer's controls show them: the
// provider's default marked, and an effort the prompt carries
// (features/composer/model-and-mode.feature).

#include <QQuickItem>
#include <QStringList>

#include "Brick.h"
#include "ComposerBrick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // Choosing another effort takes Ultrathink off the prompt.
  step(QStringLiteral("the draft reads %1 without %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return composerEditor(world)->property("text").toString() == c[0]; },
                  [&] { return QStringLiteral("the draft to read \"%1\"; it reads \"%2\"").arg(c[0], composerEditor(world)->property("text").toString()); });
    expect(!composerEditor(world)->property("text").toString().contains(c[1]), QStringLiteral("the draft still holds \"%1\"").arg(c[1]));
  });

  // The provider's default.
  step(QStringLiteral("the user opens the model's options"), [](World& world, const Captures&, const Table&) { openModelControl(world); });
  step(QStringLiteral("the provider's default effort is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("Default"), QStringLiteral("the model control marks the default \"Default\", not \"%1\"").arg(c[0]));
    QList<QQuickItem*> rows;
    world.waitFor([&] { return !(rows = modelControlEfforts(world)).isEmpty(); }, QStringLiteral("the model control to list the efforts"));
    QStringList marked, offered;
    for (QQuickItem* row : rows) {
      const QString id = row->objectName().section(u':', 1);
      offered.append(id);
      if (row->property("isDefault").toBool()) marked.append(id);
    }
    expect(marked == QStringList{QStringLiteral("medium")}, QStringLiteral("only medium marked \"%1\"; %2 are, of %3").arg(c[0], marked.join(u", "), offered.join(u", ")));
  });
});

}  // namespace
