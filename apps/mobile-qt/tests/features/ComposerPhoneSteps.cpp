// The phone twist of the composer (features/mobile/composer.feature): a
// usage limit explained over the composer, a held queue of the agent's own
// wakes, and attachments taken off and retried by touch. The composer's own
// steps are ComposerSteps.cpp; these reuse its fake stream and config.

#include <QBuffer>
#include <QElapsedTimer>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

#define S QStringLiteral

const QString kNow = S("2026-09-23T10:00:00Z");

// `attachments.createUploadUrl` and the upload it hands out, as the MC's
// (apps/server-ex lib/hal_c2/attachments.ex); `refuse` fails the upload.
struct FakePhoneUploads {
  QStringList asked;
  QStringList stored;
  bool refuse = false;
  bool hold = false;
};

const FakeMc::Extension phoneUploads([](FakeMc& mc) {
  mc.onRpc(S("attachments.createUploadUrl"), [&mc](const FakeMc::Rpc& rpc) {
    FakePhoneUploads& fake = mc.part<FakePhoneUploads>();
    const QString name = rpc.payload.value(QLatin1String("name")).toString();
    fake.asked.append(name);
    const QString id = S("pending-%1").arg(fake.asked.size());
    const QString url = S("/api/attachments/upload/phone-%1").arg(fake.asked.size());
    mc.onHttp(url, [&mc, id](const QJsonObject&, std::function<void(int, const QJsonObject&)> respond) {
      FakePhoneUploads& fake = mc.part<FakePhoneUploads>();
      if (fake.refuse) {
        respond(502, {{S("message"), S("upload refused")}});
        return;
      }
      fake.stored.append(id);
      respond(204, {});
    });
    const auto answer = [&mc, rpc, id, url] {
      mc.reply(rpc, QJsonObject{{S("attachmentId"), id}, {S("relativeUrl"), url}, {S("expiresAt"), 4102444800000.0}});
    };
    if (fake.hold) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
});

QVariantList attachmentsOf(World& world) {
  return world.state(S("composer")).toMap().value(S("attachments")).toList();
}

QVariantMap attachmentNamed(World& world, const QString& name) {
  for (const QVariant& entry : attachmentsOf(world)) {
    if (entry.toMap().value(S("name")).toString() == name) return entry.toMap();
  }
  return {};
}

QByteArray photoBytes() {
  QImage image(8, 6, QImage::Format_RGB32);
  image.fill(Qt::darkMagenta);
  QByteArray bytes;
  QBuffer buffer(&bytes);
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return bytes;
}

// A file on the phone, as picked from its files, attached to the open draft.
void attachFile(World& world, const QString& name, const QByteArray& bytes, const QString& mimeType) {
  const QString path = world.homeDir() + QLatin1Char('/') + name;
  QFile file(path);
  expect(file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size(), S("could not write %1").arg(path));
  file.close();
  world.bridge().dispatch(S("composer.attach"),
                          QVariantMap{{S("files"), QVariantList{QVariantMap{{S("name"), name}, {S("mimeType"), mimeType}, {S("path"), path}}}}});
  world.sync();
}

void attachPhoto(World& world, const QString& name) {
  world.bridge().dispatch(
      S("composer.attach"),
      QVariantMap{{S("files"), QVariantList{QVariantMap{{S("name"), name},
                                                        {S("mimeType"), S("image/png")},
                                                        {S("base64"), QString::fromLatin1(photoBytes().toBase64())}}}}});
  world.sync();
}

const Steps phoneSteps([] {
  // A usage limit over the composer (LimitRecoveryController reads the
  // thread row: a failed runtime whose last error is the limit, and when it
  // resets).
  step(S("the provider has hit its usage limit for the thread"), [](World& world, const Captures&, const Table&) {
    updateRow(world.mc, world.thread,
              {{S("latestRunId"), S("run-1")},
               {S("status"), S("failed")},
               {S("activityRunStatus"), S("failed")},
               {S("lastErrorClass"), S("usage_limit")},
               {S("usageLimitResetAt"), S("2027-01-01T10:00:00Z")},
               {S("latestRunRequestedAt"), kNow},
               {S("latestRunStartedAt"), kNow},
               {S("latestRunCompletedAt"), kNow}});
    world.sync();
  });
  step(S("the user is told when the limit resets"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("limitRecovery")) != nullptr; },
                  [&] { return S("the limit banner; the screen says: %1").arg(world.texts().join(S(" | "))); });
    QQuickItem* description = world.item(S("limitRecoveryDescription"));
    world.waitFor([&] { return description->property("text").toString().startsWith(S("Resets")); },
                  [&] { return S("the reset; the banner says %1").arg(description->property("text").toString()); });
  });
  step(S("the user is offered to snooze the thread until the reset"), [](World& world, const Captures&, const Table&) {
    QQuickItem* snooze = world.item(S("limitRecoverySnooze"));
    expect(snooze->isVisible(), S("no snooze is offered"));
  });

  // A held queue carrying only a delegated task's result.
  step(S("the user stopped a turn while a delegated task result was queued in the thread"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    const int ordinal = ++fake.ordinal;
    const QString run = S("run-%1").arg(ordinal);
    setEntity(world.mc, world.thread, S("message"), S("message:") + run,
              {{S("id"), S("message:") + run},
               {S("role"), S("user")},
               {S("text"), S("<delegated_task_result taskId=\"task:1\" title=\"Tax tests\" status=\"completed\" childThreadId=\"thread-9\">\ndone\n</delegated_task_result>")},
               {S("createdBy"), S("system")},
               {S("delegatedCompletion"), QJsonObject{{S("taskId"), S("task:1")}, {S("status"), S("completed")}}},
               {S("notification"), QJsonObject{{S("summary"), S("Tax tests finished")}, {S("outcome"), S("completed")}}}});
    setEntity(world.mc, world.thread, S("run"), run,
              {{S("id"), run}, {S("ordinal"), ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ordinal},
               {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}, {S("queueHeld"), true}});
    world.sync();
  });
  step(S("no message of the user's is queued"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.state(S("turn")).toMap().value(S("waiting")).toList().isEmpty(); },
                  [&] { return S("the wake to wait; the turn is %1").arg(show(world.state(S("turn")).toMap())); });
    expect(world.state(S("turn")).toMap().value(S("queue")).toList().isEmpty(),
           S("the user's queue is %1").arg(show(world.state(S("turn")).toMap())));
  });
  step(S("the composer offers to resume the queue"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("queueResume")) != nullptr; },
                  [&] { return S("the resume; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the turn carrying the task result starts"), [](World& world, const Captures&, const Table&) {
    world.sync();
    bool resumed = false;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      resumed = resumed || (command.value(QLatin1String("type")) == QLatin1String("queue.resume") &&
                            command.value(QLatin1String("threadId")) == world.thread);
    }
    expect(resumed, S("the MC has no queue.resume for the thread"));
  });

  // Attachments by touch: opened from the draft and taken off, and a failed
  // upload retried from its chip.
  step(S("the draft has a photo attached"), [](World& world, const Captures&, const Table&) {
    attachPhoto(world, S("photo.png"));
    world.waitFor([&] { return attachmentsOf(world).size() == 1; },
                  [&] { return S("the photo; the composer is %1").arg(show(world.state(S("composer")))); });
  });
  step(S("the user opens the photo and removes it from the draft"), [](World& world, const Captures&, const Table&) {
    world.tap(S("attachmentOpen:photo.png"));
    world.waitFor([&] { return world.state(S("attachmentViewer")).toMap().value(S("name")) == QLatin1String("photo.png"); },
                  S("the photo to open"));
    world.tap(S("attachmentViewerRemove"));
    world.sync();
  });
  step(S("the draft has no attachments"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return attachmentsOf(world).isEmpty(); },
                  [&] { return S("no attachments; the composer is %1").arg(show(world.state(S("composer")))); });
  });
  step(S("an attachment failed to upload"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakePhoneUploads>().refuse = true;
    attachFile(world, S("report.pdf"), QByteArrayLiteral("%PDF-fake"), S("application/pdf"));
    world.waitFor([&] { return attachmentNamed(world, S("report.pdf")).value(S("status")).toString() == QLatin1String("failed"); },
                  [&] { return S("the failed upload; the composer is %1").arg(show(world.state(S("composer")))); });
  });
  step(S("the user retries the upload"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakePhoneUploads>().refuse = false;
    world.tap(S("attachmentRetry:report.pdf"));
    world.sync();
  });
  // Sending during a turn: a provider that cannot steer, and restarting.
  step(S("the agent's provider cannot steer a running turn"), [](World& world, const Captures&, const Table&) {
    setEntity(world.mc, world.thread, S("provider-session"), S("session-1"),
              {{S("id"), S("session-1")},
               {S("status"), S("ready")},
               {S("capabilities"), QJsonObject{{S("turns"), QJsonObject{{S("supportsActiveSteering"), false}}}}}});
    world.sync();
  });
  step(S("the follow-up setting is steer"), [](World& world, const Captures&, const Table&) {
    saveOwnSetting(world.mc, S("followUpBehavior"), S("steer"));
    world.native().controller<SettingsController>()->writeDevice(S("followUpBehavior"), S("steer"));
    world.sync();
  });
  step(S("the user is not offered another way to send the follow-up"), [](World& world, const Captures&, const Table&) {
    QQuickItem* action = world.item(S("primaryAction"));
    expect(!action->property("sendModesOffered").toBool(), S("the send control still offers other ways"));
    bool offered = false;
    QElapsedTimer held;
    held.start();
    world.hold(action,
               [&] {
                 QQuickItem* restart = world.find(S("sendModeRestart"));
                 offered = offered || (restart != nullptr && restart->isVisible());
                 return held.elapsed() > 1200;
               },
               S("a long press on the send control"));
    expect(!offered, S("a long press offered another way to send"));
  });
  step(S("the user sends %1 to restart the turn").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* input = world.item(S("input"));
    world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
    world.tap(input);
    world.type(c[0]);
    expect(input->property("text").toString() == c[0], S("the composer reads %1").arg(input->property("text").toString()));
    QQuickItem* action = world.item(S("primaryAction"));
    world.hold(action,
               [&] {
                 QQuickItem* restart = world.find(S("sendModeRestart"));
                 return restart != nullptr && restart->isVisible();
               },
               S("the restart way to send"));
    world.tap(S("sendModeRestart"));
    world.sync();
  });
  step(S("the current turn stops and a new one starts"), [](World& world, const Captures&, const Table&) {
    world.waitFor(
        [&] {
          for (const QJsonObject& command : std::as_const(world.mc.commands)) {
            if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch") &&
                command.value(QLatin1String("deliveryIntent")) == QLatin1String("restart") &&
                command.value(QLatin1String("threadId")) == world.thread)
              return true;
          }
          return false;
        },
        S("the MC to be told to restart the turn with the message"));
  });

  step(S("the attachment uploads to %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor(
        [&] {
          return !world.mc.part<FakePhoneUploads>().stored.isEmpty() &&
                 attachmentNamed(world, S("report.pdf")).value(S("status")).toString().isEmpty();
        },
        [&] { return S("the upload to %1; the composer is %2").arg(c[0], show(world.state(S("composer")))); });
  });
});

}  // namespace
