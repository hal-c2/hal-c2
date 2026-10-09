// What a row of the thread list does besides opening: telling the MC a
// thread was read, the preview on hover, the jump keys while the modifier is
// held, and files dropped on it (features/threads/unread-and-status.feature,
// threads/sidebar-list.feature, threads/pinning-and-order.feature).

#include <QDir>
#include <QFile>
#include <QJsonObject>
#include <QUrl>

#include "ComposerController.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "ThreadList.h"
#include "World.h"

namespace {

struct RowScene {
  QString subject;
};

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QVariantList rows(World& world) {
  const QVariantMap sidebar = world.state(QStringLiteral("sidebar")).toMap();
  return sidebar.value(QStringLiteral("pinned")).toList() + sidebar.value(QStringLiteral("active")).toList() +
         sidebar.value(QStringLiteral("snoozed")).toList() + sidebar.value(QStringLiteral("settled")).toList();
}

QVariantMap rowOf(World& world, const QString& key) {
  for (const QVariant& row : rows(world)) {
    if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
  }
  return {};
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the environment is told %1 was seen up to its latest work").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(threadKeyOf(world, c[0]));
    const QString updatedAt = world.mc.threads.value(id).value(QLatin1String("updatedAt")).toString();
    world.waitFor([&] {
      for (const QJsonObject& command : std::as_const(world.mc.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("thread.visit") && command.value(QLatin1String("threadId")) == id &&
            command.value(QLatin1String("visitedAt")) == updatedAt) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("a visit up to %1; the MC has %2").arg(updatedAt, world.describeCommands()); });
  });

  // Threads from the first version.
  step(QStringLiteral("threads were migrated from the first version"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : {QStringLiteral("Legacy work"), QStringLiteral("Older legacy work")}) {
      const QString id = QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
      world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), QStringLiteral("legacy")},
                                   {QStringLiteral("historyOrigin"), QStringLiteral("v1_import")},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    }
    world.connect();
  });
  step(QStringLiteral("the user is told the threads were brought over"), [](World& world, const Captures&, const Table&) {
    const auto told = [&] {
      QVariantList matching;
      for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")) == QLatin1String("Your threads were brought over")) matching.append(item);
      }
      return matching;
    };
    world.waitFor([&] { return !told().isEmpty(); }, [&] { return QStringLiteral("the notice; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
    expect(told().size() == 1 && told().first().toMap().value(QStringLiteral("description")).toString().startsWith(QLatin1String("2 threads")),
           QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
    // Once: the next start says nothing.
    world.restart();
    world.connect();
    world.sync();
    expect(told().isEmpty(), QStringLiteral("the notice is shown again"));
  });

  // The age.
  step(QStringLiteral("the last message in %1 was 3 hours ago").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString at = world.now().addSecs(-3 * 3600).toUTC().toString(Qt::ISODate);
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&at](QJsonObject& row) {
      row.insert(QStringLiteral("latestUserMessageAt"), at);
      row.insert(QStringLiteral("updatedAt"), at);
    });
  });
  step(QStringLiteral("the environment records that %1 was pinned just now").arg(q), [](World& world, const Captures& c, const Table&) {
    // As the MC's row after a pin: the update time moves with it.
    const QString at = world.now().toUTC().toString(Qt::ISODate);
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&at](QJsonObject& row) {
      row.insert(QStringLiteral("pinnedAt"), at);
      row.insert(QStringLiteral("updatedAt"), at);
    });
  });
  step(QStringLiteral("the row for %1 counts its age from that message").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString key = threadKeyOf(world, c[0]);
    const QVariantMap row = rowOf(world, key);
    expect(row.value(QStringLiteral("pinned")).toBool() &&
               row.value(QStringLiteral("timeAt")) == world.mc.threads.value(idOf(key)).value(QLatin1String("latestUserMessageAt")).toString(),
           QStringLiteral("the row is %1").arg(show(row)));
  });

  // The preview.
  step(QStringLiteral("the user rests the pointer on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    world.mc.part<RowScene>().subject = key;
    // A thread at work on a branch, so the preview has one to show.
    updateThreadRow(world, idOf(key), [](QJsonObject& row) { row.insert(QStringLiteral("branch"), QStringLiteral("feature/search")); });
  });
  step(QStringLiteral("a preview shows the thread's project, branch and latest activity"), [](World& world, const Captures&, const Table&) {
    // SidebarThreadRow.qml shows these lines after the pointer rests on the row.
    const QVariantMap row = rowOf(world, world.mc.part<RowScene>().subject);
    const QVariantMap preview = row.value(QStringLiteral("preview")).toMap();
    const QString project = world.mc.threads.value(idOf(world.mc.part<RowScene>().subject)).value(QLatin1String("projectId")).toString();
    expect(preview.value(QStringLiteral("project")) == project && preview.value(QStringLiteral("branch")) == QLatin1String("feature/search") &&
               preview.value(QStringLiteral("activity")).toString().startsWith(QLatin1String("Active ")),
           QStringLiteral("the row is %1").arg(show(row)));
  });

  // Jump hints.
  step(QStringLiteral("the user holds the thread jump modifier"), [](World& world, const Captures&, const Table&) {
    // Ten threads, so one is past the ninth.
    const QString project = world.mc.projects.firstKey();
    for (int index = 0; index < 10; ++index) {
      const QString id = QStringLiteral("t-jump-%1").arg(index);
      const QString at = QStringLiteral("2026-09-23T09:%1:00Z").arg(10 + index);
      const QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Jump %1").arg(index)}, {QStringLiteral("projectId"), project},
                            {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}};
      world.mc.threads.insert(id, row);
      world.mc.sendRow(id, row);
    }
    world.sync();
    for (const QVariant& row : rows(world)) {
      expect(row.toMap().value(QStringLiteral("jumpLabel")).typeId() != QMetaType::QString, QStringLiteral("a hint shows before the modifier is held"));
    }
    world.native().controller<KeybindingController>()->setJumpModifierHeld(true);
    // Not at once: a quick shortcut shows nothing.
    expect(rows(world).first().toMap().value(QStringLiteral("jumpLabel")).typeId() != QMetaType::QString, QStringLiteral("the hints show without a delay"));
  });
  step(QStringLiteral("the first nine threads show their jump numbers after a short delay"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return rows(world).first().toMap().value(QStringLiteral("jumpLabel")).typeId() == QMetaType::QString; },
                  QStringLiteral("the jump hints"));
    const QVariantList listed = rows(world);
    expect(listed.size() >= 10, QStringLiteral("only %1 threads are listed").arg(listed.size()));
    for (qsizetype index = 0; index < listed.size(); ++index) {
      const QVariant label = listed.at(index).toMap().value(QStringLiteral("jumpLabel"));
      if (index < 9) {
        expect(label.toString().endsWith(QString::number(index + 1)), QStringLiteral("row %1 shows \"%2\"").arg(index + 1).arg(label.toString()));
      } else {
        expect(label.typeId() != QMetaType::QString, QStringLiteral("row %1 shows \"%2\"").arg(index + 1).arg(label.toString()));
      }
    }
    // Letting go hides them.
    world.native().controller<KeybindingController>()->setJumpModifierHeld(false);
    expect(rows(world).first().toMap().value(QStringLiteral("jumpLabel")).typeId() != QMetaType::QString, QStringLiteral("the hints stay"));
  });

  // Files dropped on a row.
  step(QStringLiteral("the user drops two files onto %1 in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    QList<QUrl> urls;
    for (const QString& name : {QStringLiteral("cart.png"), QStringLiteral("totals.png")}) {
      QFile file(QDir(world.homeDir()).filePath(name));
      expect(file.open(QIODevice::WriteOnly), QStringLiteral("cannot write %1").arg(name));
      file.write("\x89PNG\r\n\x1a\n", 8);
      urls.append(QUrl::fromLocalFile(file.fileName()));
    }
    // As Sidebar.qml: the composer's own reader, with its limits.
    world.bridge().dispatch(QStringLiteral("thread.attachFiles"),
                            QVariantMap{{QStringLiteral("key"), threadKeyOf(world, c[0])}, {QStringLiteral("files"), world.bridge().readImageFiles(urls)}});
    world.mc.part<RowScene>().subject = threadKeyOf(world, c[0]);
  });
  step(QStringLiteral("the files are attached to its composer with the usual attachment limits"), [](World& world, const Captures&, const Table&) {
    const QVariantList attached = world.native().controller<ComposerController>()->attachments(world.mc.part<RowScene>().subject);
    QStringList names;
    for (const QVariant& attachment : attached) names.append(attachment.toMap().value(QStringLiteral("name")).toString());
    expect(names == QStringList{QStringLiteral("cart.png"), QStringLiteral("totals.png")}, QStringLiteral("the composer holds %1").arg(names.join(QStringLiteral(", "))));
    // The limits are the reader's: what is not an image is left out.
    QFile notes(QDir(world.homeDir()).filePath(QStringLiteral("notes.txt")));
    expect(notes.open(QIODevice::WriteOnly), QStringLiteral("cannot write notes.txt"));
    notes.write("plain text");
    notes.close();
    expect(world.bridge().readImageFiles({QUrl::fromLocalFile(notes.fileName())}).isEmpty(), QStringLiteral("a text file was read as an image"));
  });
});

}  // namespace
