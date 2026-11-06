// Saved environments (SavedEnvironmentsController, EnvironmentCatalog,
// McClient's renewal) in features/connections/connection-health.feature: a
// second environment on a connection of its own, records and credentials that
// have gone, and renewing a credential for an HTTP request. Included by the
// desktop's and the phone's ConnectionCatalogSteps.cpp, after the surface's
// World; the desktop's own rows (a damaged record file, a keyring that
// refuses) are in its .cpp.
//
// The saved environment is "studio", served by a FakeMc of its own; the
// World's keyring is a MemorySecretStore (World::secrets).

#pragma once

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QTcpSocket>

#include <memory>
#include <optional>

#include "EnvironmentCatalog.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SavedEnvironmentsController.h"
#include "ShellStore.h"

namespace connection_catalog {

inline const QString kStudio = QStringLiteral("studio");
inline const QString kStudioSession = QStringLiteral("studio-session");

// What one scenario keeps between its steps.
struct Catalog {
  std::unique_ptr<FakeMc> studio;
  qsizetype connectionsBefore = 0;
  int renewals = 0; // renewals the MC was asked for
  int reached = 0;  // requests that reached the MC past their renewal
  bool replied = false;
  QString replyError;
  QByteArray damaged; // what the damaged record file held
};

inline Catalog &catalog(World &world) { return world.mc.part<Catalog>(); }

inline SavedEnvironmentsController &saved(World &world) {
  auto *controller = world.native().shared<SavedEnvironmentsController>();
  if (!controller)
    fail(QStringLiteral("the shell has no saved environments"));
  return *controller;
}

inline QString recordFile(World &world) {
  EnvironmentCatalog *records = saved(world).catalog();
  if (!records)
    fail(QStringLiteral("the saved environments were never read"));
  return records->path();
}

inline QString describeSaved(World &world) {
  return QString::fromUtf8(QJsonDocument::fromVariant(
                               world.state(QStringLiteral("savedEnvironments")))
                               .toJson(QJsonDocument::Compact));
}

inline QVariantList listed(World &world) {
  return world.state(QStringLiteral("savedEnvironments"))
      .toMap()
      .value(QStringLiteral("environments"))
      .toList();
}

inline QString stateOf(World &world, const QString &id) {
  return saved(world).status(id).value(QStringLiteral("state")).toString();
}

inline void waitForState(World &world, const QString &id,
                         const QString &state) {
  world.waitFor([&] { return stateOf(world, id) == state; },
                [&] {
                  return QStringLiteral(
                             "%1 to be %2; saved environments are %3")
                      .arg(id, state, describeSaved(world));
                });
}

inline void respond(QTcpSocket *socket, int status, const QJsonObject &body) {
  const QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) +
                (status < 300 ? " OK" : " Refused") +
                "\r\nContent-Type: application/json\r\nContent-Length: " +
                QByteArray::number(json.size()) +
                "\r\nConnection: close\r\n\r\n" + json);
  socket->disconnectFromHost();
}

// The other environment's MC, "Studio".
inline FakeMc &studio(World &world) {
  std::unique_ptr<FakeMc> &mc = catalog(world).studio;
  if (!mc) {
    mc = std::make_unique<FakeMc>();
    mc->name = QStringLiteral("mc-studio");
    mc->environmentId = kStudio;
    mc->label = QStringLiteral("Studio");
    // It sells a session for its pairing link's token (`/oauth/token`).
    mc->onRaw(QStringLiteral("/oauth/token"), [](QTcpSocket *socket,
                                                 const QByteArray &) {
      const auto exchange = [socket] {
        const QByteArray request = socket->peek(socket->bytesAvailable());
        if (!request.contains("subject_token="))
          return false;
        const bool known = request.contains("subject_token=studio-pairing");
        respond(
            socket, known ? 200 : 400,
            known
                ? QJsonObject{{QStringLiteral("access_token"), kStudioSession},
                              {QStringLiteral("token_type"),
                               QStringLiteral("Bearer")},
                              {QStringLiteral("expires_in"), 30 * 24 * 3600}}
                : QJsonObject{{QStringLiteral("error"),
                               QStringLiteral("invalid_grant")}});
        return true;
      };
      if (!exchange())
        QObject::connect(socket, &QTcpSocket::readyRead, socket, exchange);
    });
  }
  return *mc;
}

inline QString pairingLink(World &world) {
  return studio(world).origin().toString() +
         QStringLiteral("/pair#token=studio-pairing");
}

// Saved as pairing saves it, and connected.
inline void saveStudio(World &world) {
  const SavedEnvironment environment{
      kStudio, QStringLiteral("Studio"), studio(world).origin(), {}};
  if (const auto refused =
          saved(world).catalog()->save(environment, kStudioSession))
    fail(*refused);
  saved(world).connectTo(kStudio);
  waitForState(world, kStudio, QStringLiteral("connected"));
  world.waitFor(
      [&] { return world.native().store()->linkServing(kStudio) != nullptr; },
      [&] {
        return QStringLiteral(
                   "the shell to hear Studio; saved environments are %1")
            .arg(describeSaved(world));
      });
}

// Writes the record file as `environments`, and reads it again as the app does
// when it starts.
inline void writeRecords(World &world, const QJsonArray &environments) {
  QFile file(recordFile(world));
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
    fail(QStringLiteral("cannot write %1").arg(file.fileName()));
  file.write(
      QJsonDocument(QJsonObject{{QStringLiteral("version"), 1},
                                {QStringLiteral("environments"), environments}})
          .toJson());
  file.close();
  saved(world).start(QFileInfo(file).absolutePath());
}

// The client asks something of the MC over HTTP, its credential about to run
// out, and the MC renews it with `renewal` (an HTTP status).
inline void requestWhileExpiring(World &world, int renewal) {
  Catalog &kept = catalog(world);
  McClient *client = world.native().client();
  world.waitFor([&] { return client->isReady(); },
                QStringLiteral("the client to be connected"));
  // Raw: `/api/auth/session` is another domain's.
  world.mc.onRaw(
      QStringLiteral("/api/auth/session/renew"),
      [&kept, renewal](QTcpSocket *socket, const QByteArray &) {
        ++kept.renewals;
        if (renewal >= 300) {
          respond(socket, renewal,
                  {{QStringLiteral("_tag"),
                    QStringLiteral("EnvironmentAuthInvalidError")},
                   {QStringLiteral("reason"), QStringLiteral("auth_invalid")}});
          return;
        }
        respond(socket, renewal,
                {{QStringLiteral("expiresAt"),
                  QDateTime::currentDateTimeUtc().addDays(30).toString(
                      Qt::ISODateWithMs)}});
      });
  world.mc.onHttp(QStringLiteral("/api/catalog/probe"),
                  [&kept](const QJsonObject &, auto answer) {
                    ++kept.reached;
                    answer(200, {{QStringLiteral("ok"), true}});
                  });
  client->setCredentialExpiry(QDateTime::currentDateTimeUtc().addSecs(60));
  kept.connectionsBefore = world.mc.connections.size();
  client->post(
      client, QStringLiteral("/api/catalog/probe"), {},
      [&kept](const QJsonValue &, const std::optional<QString> &error) {
        kept.replied = true;
        kept.replyError = error.value_or(QString());
      });
  world.waitFor([&] { return kept.replied; },
                QStringLiteral("the request to be answered"));
}

// Every file under `dir` that holds `text`.
inline QStringList filesHolding(const QString &dir, const QString &text) {
  QStringList found;
  QDirIterator files(dir, QDir::Files | QDir::Hidden | QDir::System,
                     QDirIterator::Subdirectories);
  while (files.hasNext()) {
    QFile file(files.next());
    if (file.open(QIODevice::ReadOnly) &&
        file.readAll().contains(text.toUtf8()))
      found.append(file.fileName());
  }
  return found;
}

// Whether a saved environment is what a scenario's "the connection is blocked"
// is about, and then that it is: blocked, and not retried.
inline bool savedEnvironmentBlocked(World &world) {
  if (!world.native().shared<SavedEnvironmentsController>() ||
      listed(world).isEmpty())
    return false;
  waitForState(world, kStudio, QStringLiteral("blocked"));
  // Not retried: nothing reached for the environment.
  expect(saved(world).client(kStudio) == nullptr &&
             (!catalog(world).studio ||
              catalog(world).studio->connections.isEmpty()),
         QStringLiteral("the client tried to connect: %1")
             .arg(describeSaved(world)));
  return true;
}

const Steps sharedSteps([] {
  const QString q = kQuoted;

  // Only the environment with the bad credential stops.
  step(QStringLiteral("two paired environments"),
       [](World &world, const Captures &, const Table &) {
         world.waitFor([&] { return world.native().client()->isReady(); },
                       QStringLiteral("the first environment to be connected"));
         saveStudio(world);
       });
  step(QStringLiteral("one of them revoked this client"), [](World &world,
                                                             const Captures &,
                                                             const Table &) {
    // Studio turns its session away, the socket and its ticket alike
    // (router.ex).
    const auto refuse = [](QTcpSocket *socket, const QByteArray &) {
      respond(
          socket, 401,
          {{QStringLiteral("_tag"),
            QStringLiteral("EnvironmentAuthInvalidError")},
           {QStringLiteral("reason"), QStringLiteral("invalid_credential")}});
    };
    studio(world).onRaw(QStringLiteral("/ws?token=") + kStudioSession, refuse);
    studio(world).onRaw(QStringLiteral("/api/auth/websocket-ticket"), refuse);
  });
  step(QStringLiteral("the client connects to both"),
       [](World &world, const Captures &, const Table &) {
         catalog(world).connectionsBefore = world.mc.connections.size();
         world.native().client()->reconnect();
         saved(world).client(kStudio)->reconnect();
         waitForState(world, kStudio, QStringLiteral("refused"));
         world.waitFor(
             [&] {
               return world.native().client()->isReady() &&
                      world.mc.connections.size() >
                          catalog(world).connectionsBefore;
             },
             QStringLiteral("the first environment to connect again"));
       });
  step(QStringLiteral("the other environment stays connected"),
       [](World &world, const Captures &, const Table &) {
         McClient *first = world.native().client();
         // What the shell says of it follows its connection.
         world.waitFor(
             [&] {
               return world.state(QStringLiteral("connection"))
                          .toMap()
                          .value(QStringLiteral("phase")) ==
                      QLatin1String("connected");
             },
             [&] {
               return QStringLiteral("the shell to say the first environment "
                                     "is connected; it says %1")
                   .arg(QString::fromUtf8(
                       QJsonDocument::fromVariant(
                           world.state(QStringLiteral("connection")))
                           .toJson(QJsonDocument::Compact)));
             });
         expect(first->isReady() && first->phase() == McClient::Phase::Ready,
                QStringLiteral("the first environment is %1 (%2)")
                    .arg(int(first->phase()))
                    .arg(first->failureMessage()));
         // Studio stopped on its own: it waits for the user to pair again.
         expect(stateOf(world, kStudio) == QLatin1String("refused") &&
                    saved(world).client(kStudio)->phase() ==
                        McClient::Phase::Refused,
                QStringLiteral("saved environments are %1")
                    .arg(describeSaved(world)));
       });

  // A saved environment whose record or credential has gone.
  step(QStringLiteral("%1 is saved but (its connection record is gone|its "
                      "credential is gone)")
           .arg(q),
       [](World &world, const Captures &c, const Table &) {
         if (c[1].contains(QLatin1String("record"))) {
           // Listed, with nothing to say where it is.
           world.secrets->secrets.insert(c[0], kStudioSession);
           writeRecords(world, {QJsonObject{{QStringLiteral("id"), c[0]},
                                            {QStringLiteral("label"),
                                             QStringLiteral("Studio")}}});
         } else {
           world.secrets->secrets.remove(c[0]);
           writeRecords(
               world,
               {QJsonObject{{QStringLiteral("id"), c[0]},
                            {QStringLiteral("label"), QStringLiteral("Studio")},
                            {QStringLiteral("origin"),
                             studio(world).origin().toString()}}});
         }
       });

  // Renewing a credential for an HTTP request.
  step(QStringLiteral("a connected client whose credential is about to expire"),
       [](World &world, const Captures &, const Table &) {
         world.waitFor([&] { return world.native().client()->isReady(); },
                       QStringLiteral("the client to be connected"));
       });
  step(QStringLiteral("the client renews it for an HTTP request"),
       [](World &world, const Captures &, const Table &) {
         requestWhileExpiring(world, 200);
         const Catalog &kept = catalog(world);
         const QDateTime expiresAt =
             world.native().client()->credentialExpiry();
         expect(kept.renewals == 1 && kept.reached == 1 &&
                    kept.replyError.isEmpty() &&
                    expiresAt > QDateTime::currentDateTimeUtc().addDays(29),
                QStringLiteral("%1 renewals, %2 requests reached the MC, error "
                               "\"%3\", the credential runs out at %4")
                    .arg(kept.renewals)
                    .arg(kept.reached)
                    .arg(kept.replyError, expiresAt.toString(Qt::ISODate)));
       });
  step(QStringLiteral("renewing its credential fails for an HTTP request"),
       [](World &world, const Captures &, const Table &) {
         requestWhileExpiring(world, 401);
       });
  step(QStringLiteral("only that request fails"), [](World &world,
                                                     const Captures &,
                                                     const Table &) {
    const Catalog &kept = catalog(world);
    expect(
        kept.renewals == 1 && kept.reached == 0 &&
            kept.replyError.contains(QLatin1String("could not be renewed")),
        QStringLiteral("%1 renewals, %2 requests reached the MC, error \"%3\"")
            .arg(kept.renewals)
            .arg(kept.reached)
            .arg(kept.replyError));
    // The connection did not take the failure as its own.
    const QVariantMap connection =
        world.state(QStringLiteral("connection")).toMap();
    expect(world.native().client()->failure().isEmpty() &&
               connection.value(QStringLiteral("phase")) ==
                   QLatin1String("connected"),
           QStringLiteral("the connection is %1")
               .arg(QString::fromUtf8(QJsonDocument::fromVariant(connection)
                                          .toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("the connection stays open"), [](World &world,
                                                       const Captures &,
                                                       const Table &) {
    McClient *client = world.native().client();
    expect(client->isReady() && world.mc.connected() &&
               world.mc.connections.size() == catalog(world).connectionsBefore,
           QStringLiteral("the client is %1 with %2 sockets opened (%3 before)")
               .arg(int(client->phase()))
               .arg(world.mc.connections.size())
               .arg(catalog(world).connectionsBefore));
  });
});

} // namespace connection_catalog
