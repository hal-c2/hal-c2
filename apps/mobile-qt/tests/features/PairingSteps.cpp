// Pairing a phone with an environment (features/mobile/
// pairing-and-environments.feature): the pairing screen, the environment in
// Settings and its way out, as the user taps and types them, against an MC
// that sells sessions for pairing links (PairableMc).

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QNetworkAccessManager>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QUrl>

#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PairingExchange.h"
#include "Phone.h"
#include "ShellStore.h"
#include "World.h"

QString pairingPhase(World& world) {
  return world.state(QStringLiteral("pairing")).toMap().value(QStringLiteral("phase")).toString();
}

void enterPairingLink(World& world, const QString& link) {
  world.tap(QStringLiteral("pairingLink"));
  QQuickItem* field = world.item(QStringLiteral("pairingLink"));
  expect(field->hasActiveFocus(), QStringLiteral("the pairing link field did not take the keyboard"));
  world.type(link);
  expect(field->property("text").toString() == link, QStringLiteral("the field reads %1").arg(field->property("text").toString()));
  world.tap(QStringLiteral("pairingPair"));
  world.waitFor([&] { return pairingPhase(world) != QLatin1String("pairing"); }, QStringLiteral("an answer to the pairing link"));
}

void pairWithEnvironment(World& world) {
  if (pairingPhase(world) == QLatin1String("paired")) return;
  enterPairingLink(world, world.environment.link());
  world.waitFor([&] { return pairingPhase(world) == QLatin1String("paired"); },
                [&] { return QStringLiteral("the phone to pair; it says: %1").arg(world.texts().join(QStringLiteral(" | "))); });
  world.waitFor([&] { return world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("phase")) == QLatin1String("connected"); },
                [&] { return QStringLiteral("the connection; it is %1").arg(show(world.state(QStringLiteral("connection")))); });
  threadList(world);
}

namespace {

QString pairingFile(World& world) {
  return QDir(world.homeDir()).filePath(QStringLiteral("data/pairing.json"));
}

// The text of the item named `objectName`, which must be on screen.
QString shownText(World& world, const QString& objectName) {
  return world.item(objectName)->property("text").toString();
}

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

// What the device keeps of its environment.
QJsonObject keptPairing(World& world) {
  QFile file(pairingFile(world));
  return file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object() : QJsonObject();
}

// The app's own link to a pairing link, as the MC's /pair page offers it.
QString appLinkTo(const QString& link) {
  return QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(link));
}

// The system opens the app with a link to `link`, and the pairing screen comes.
void followPairingLink(World& world, const QString& link) {
  world.link = link;
  world.followLink(appLinkTo(link));
  world.waitFor([&] { return world.find(QStringLiteral("pairingOffer")) != nullptr; },
                [&] { return QStringLiteral("the pairing screen with the link; the phone is %1 and says: %2").arg(show(world.state(QStringLiteral("pairing"))), screenTexts(world)); });
}

// From home, the user opens the environment in Settings, which names it.
void showEnvironment(World& world, const QString& name) {
  if (world.find(QStringLiteral("pairingSettings")) == nullptr) world.tap(QStringLiteral("environment"));
  world.item(QStringLiteral("pairingSettings"));
  world.waitFor([&] { return shownText(world, QStringLiteral("environmentName")) == name; },
                [&] { return QStringLiteral("the settings to name %1; the screen says: %2").arg(name, screenTexts(world)); });
}

// And back out of Settings, a step at a time: its sections, then home.
void leaveEnvironment(World& world) {
  world.back();
  world.item(QStringLiteral("settingsSections"));
  world.back();
  world.item(QStringLiteral("homeScreen"));
}

// From there, the user asks to forget it and is asked whether to.
void askToForget(World& world, const QString& name) {
  world.tap(QStringLiteral("environmentForget"));
  world.awaitPopup(QStringLiteral("confirmDialog"));
  expect(world.shows(QStringLiteral("Forget %1?").arg(name)), QStringLiteral("the question does not name %1; the screen says: %2").arg(name, screenTexts(world)));
}

// From Settings, the user asks to pair with another environment and is at the
// pairing screen, which says what that costs.
void chooseToPairWithAnother(World& world) {
  showEnvironment(world, world.mc.label);
  world.tap(QStringLiteral("environmentPairAnother"));
  world.item(QStringLiteral("pairingScreen"));
  expect(shownText(world, QStringLiteral("pairingTitle")) == QStringLiteral("Pair with another environment"), QStringLiteral("the screen says: %1").arg(screenTexts(world)));
}

void awaitConnection(World& world) {
  world.waitFor([&] { return pairingPhase(world) == QLatin1String("paired"); },
                [&] { return QStringLiteral("the phone to pair; it says: %1").arg(screenTexts(world)); });
  world.waitFor([&] { return world.state(QStringLiteral("connection")).toMap().value(QStringLiteral("phase")) == QLatin1String("connected"); },
                [&] { return QStringLiteral("the connection; it is %1").arg(show(world.state(QStringLiteral("connection")))); });
}

// How many sockets the MC had when the scenario last looked.
struct Seen {
  qsizetype sockets = 0;
};

const Steps steps([] {
  using S = QString;

  step(S("the app has never been paired"), [](World& world, const Captures&, const Table&) {
    expect(!world.isOpen(), S("the app is already open"));
    expect(!QFile::exists(pairingFile(world)), S("the phone already keeps a pairing"));
  });

  step(S("the user opens the app"), [](World& world, const Captures&, const Table&) { world.open(); });

  step(S("the user is told no environments are connected"), [](World& world, const Captures&, const Table&) {
    world.item(S("pairingScreen"));
    expect(shownText(world, S("pairingTitle")) == S("No environment connected"), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user is offered to add an environment"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.item(S("pairingLink"));
    QQuickItem* pair = world.item(S("pairingPair"));
    expect(field->isEnabled(), S("the pairing link cannot be entered"));
    expect(pair->property("text").toString() == S("Pair"), S("the button reads %1").arg(pair->property("text").toString()));
    // Its help says where a link comes from.
    expect(shownText(world, S("pairingHelp")).contains(S("pairing link")), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user enters a pairing link that carries a token"), [](World& world, const Captures&, const Table&) {
    world.link = world.environment.link();
    world.tap(S("pairingLink"));
    world.type(world.link);
    expect(shownText(world, S("pairingLink")) == world.link, S("the field reads %1").arg(shownText(world, S("pairingLink"))));
  });

  step(S("the user adds the environment"), [](World& world, const Captures&, const Table&) { world.tap(S("pairingPair")); });

  step(S("the environment is added to the phone"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return pairingPhase(world) == QLatin1String("paired"); },
                  [&] { return S("the phone to pair; it says: %1").arg(screenTexts(world)); });
    // Home takes the pairing screen's place, with the environment's threads.
    world.item(S("homeScreen"));
    expect(world.find(S("pairingScreen")) == nullptr, S("the pairing screen is still showing"));
    threadRow(world, S("Tax line"));
    // The link's token bought the session the phone is connected with.
    expect(world.environment.sessions.size() == 1 && world.environment.pairingTokens.isEmpty(),
           S("the MC sold %1 sessions").arg(world.environment.sessions.size()));
    world.waitFor([&] { return world.environment.connectedWithTicket(); }, S("the phone to connect with its session"));
    // And the environment is the phone's to show: its name and address, in Settings.
    showEnvironment(world, world.mc.label);
    expect(shownText(world, S("environmentAddress")) == world.mc.origin().toString(), S("its address reads %1").arg(shownText(world, S("environmentAddress"))));
  });

  step(S("the pairing token has already been used"), [](World& world, const Captures&, const Table&) {
    world.link = world.environment.link();
    // Another device spends it.
    QNetworkAccessManager http;
    bool spent = false;
    pairing::exchange(&http, &http, *pairing::readLink(world.link), {S("Another phone"), S("mobile"), {}},
                      [&](const pairing::Result& result) { spent = result.outcome == pairing::Outcome::Paired; });
    world.waitFor([&] { return spent; }, S("another device to spend the token"));
  });

  step(S("the environment at the pairing address is offline"), [](World& world, const Captures&, const Table&) {
    world.link = S("http://") + deadAddress() + S("/?token=abc");
  });

  step(S("the phone has no room to save a session"), [](World& world, const Captures&, const Table&) { world.fillStorage(); });

  step(S("the user is told the session could not be saved"), [](World& world, const Captures&, const Table&) {
    const QString said = shownText(world, S("pairingError"));
    expect(said.contains(S("could not be saved on this device")) && said.contains(S("ask the environment for a fresh one")), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user tries to pair with it"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Seen>().sockets = world.mc.connections.size();
    enterPairingLink(world, world.link);
  });

  step(S("the user is told pairing failed"), [](World& world, const Captures&, const Table&) {
    expect(shownText(world, S("pairingError")).startsWith(S("Pairing failed")), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the pairing form keeps what the user entered"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = world.item(S("pairingLink"));
    expect(field->property("text").toString() == world.link, S("the field reads %1").arg(field->property("text").toString()));
    expect(field->isEnabled(), S("the field cannot be corrected"));
  });

  step(S("the user is told the environment could not be reached"), [](World& world, const Captures&, const Table&) {
    expect(shownText(world, S("pairingError")).contains(S("could not be reached")), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("no environment is added"), [](World& world, const Captures&, const Table&) {
    expect(pairingPhase(world) == QLatin1String("unpaired"), S("the phone is %1").arg(pairingPhase(world)));
    world.item(S("pairingScreen"));
    expect(world.find(S("homeScreen")) == nullptr, S("the home screen is showing"));
    expect(!QFile::exists(pairingFile(world)), S("the phone keeps a pairing"));
    expect(world.native().store()->environments().isEmpty(), S("the phone holds an environment"));
    expect(world.mc.connections.size() == world.mc.part<Seen>().sockets, S("the phone opened a connection"));
  });

  step(S("the phone is paired with %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.label = c[0];
    pairWithEnvironment(world);
    showEnvironment(world, c[0]);
    leaveEnvironment(world);
  });

  // One environment at a time (src/Pairing.h): a second pairing replaces the first.
  step(S("the phone is paired with %1 and %1").arg(kQuoted), [](World&, const Captures& c, const Table&) {
    fail(S("the phone pairs with one environment at a time, so it cannot be paired with both %1 and %2").arg(c[0], c[1]));
  });

  // The phone was paired with it before it moved on to another protocol, and is opened again.
  step(S("an environment runs a server version the app does not support"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    world.close();
    world.environment.protocol = McClient::kProtocol + 1;
    world.mc.part<Seen>().sockets = world.mc.connections.size();
    world.open();
  });

  step(S("the user is told to use compatible versions of the app and server"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("connectionNoticeTitle")) != nullptr; }, [&] { return S("a notice; the screen says: %1").arg(screenTexts(world)); });
    expect(shownText(world, S("connectionNoticeTitle")) == S("This app is too old for %1").arg(world.mc.label) &&
               shownText(world, S("connectionNoticeDetail")) == S("Update HAL-C2 on this device to connect."),
           S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the phone does not keep trying to sync it"), [](World& world, const Captures&, const Table&) {
    expect(world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("blocked"), S("the connection is %1").arg(show(world.state(S("connection")))));
    // No attempt is waiting, and none was made on the MC's socket.
    expect(world.native().client()->phase() == McClient::Phase::Blocked && world.native().client()->retryDelay() == 0,
           S("the phone will try again in %1 ms").arg(world.native().client()->retryDelay()));
    expect(world.mc.connections.size() == world.mc.part<Seen>().sockets, S("the phone opened a connection to it"));
    // What it kept from before may show; none of it passes for the MC's word.
    expect(!world.native().store()->synchronized(), S("the phone takes what it holds for the environment's own"));
  });

  step(S("the user removes %1 and confirms").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    showEnvironment(world, c[0]);
    askToForget(world, c[0]);
    world.tap(S("confirmAccept"));
  });

  // Settings need the connection; beside the notice of a lost one is the other way out.
  step(S("the user removes it from the connection notice and confirms"), [](World& world, const Captures&, const Table&) {
    world.item(S("connectionNoticeTitle"));
    world.tap(S("connectionForget"));
    world.awaitPopup(S("confirmDialog"));
    expect(world.shows(S("Forget %1?").arg(world.mc.label)), S("the question does not name %1; the screen says: %2").arg(world.mc.label, screenTexts(world)));
    world.tap(S("confirmAccept"));
  });

  step(S("the user starts to remove %1 but cancels").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    showEnvironment(world, c[0]);
    askToForget(world, c[0]);
    world.tap(S("confirmCancel"));
  });

  step(S("%1 is no longer listed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return pairingPhase(world) == QLatin1String("unpaired") && world.find(S("pairingScreen")) != nullptr; },
                  [&] { return S("the pairing screen; the phone is %1 and says: %2").arg(pairingPhase(world), screenTexts(world)); });
    world.awaitPopup(S("confirmDialog"), false);
    expect(!world.shows(c[0], false) && world.find(S("homeScreen")) == nullptr, S("%1 is still on screen, which says: %2").arg(c[0], screenTexts(world)));
    expect(!QFile::exists(pairingFile(world)), S("the phone still keeps the pairing"));
  });

  step(S("its cached threads are removed from the phone"), [](World& world, const Captures&, const Table&) {
    expect(world.native().store()->threads().isEmpty() && world.native().store()->projects().isEmpty() && world.native().store()->environments().isEmpty(),
           S("the phone still holds %1 threads").arg(world.native().store()->threads().size()));
    expect(!show(world.state(S("sidebar"))).contains(S("Tax line")), S("the thread list still has them: %1").arg(show(world.state(S("sidebar")))));
    expect(world.native().client()->phase() == McClient::Phase::Closed, S("the connection is still open"));
    // Nothing the phone keeps on disk names them, and a restart shows none.
    const auto kept = [&] {
      QStringList files;
      QDirIterator it(world.homeDir(), QDir::Files, QDirIterator::Subdirectories);
      while (it.hasNext()) {
        QFile file(it.next());
        if (file.open(QIODevice::ReadOnly) && file.readAll().contains("Tax line")) files.append(file.fileName());
      }
      return files;
    };
    expect(kept().isEmpty(), S("the phone keeps them in %1").arg(kept().join(S(", "))));
    const qsizetype sockets = world.mc.connections.size();
    world.close();
    world.open();
    world.item(S("pairingScreen"));
    expect(!world.shows(S("Tax line"), false), S("the restarted app says: %1").arg(screenTexts(world)));
    expect(world.mc.connections.size() == sockets, S("the restarted app connected to the environment"));
  });

  step(S("the user pairs with %1 again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.label == c[0], S("the environment is %1").arg(world.mc.label));
    chooseToPairWithAnother(world);
    enterPairingLink(world, world.environment.link());
    awaitConnection(world);
  });

  step(S("%1 is listed once").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // Back where the user started from, Settings names it, at its address.
    showEnvironment(world, c[0]);
    expect(shownText(world, S("environmentAddress")) == world.mc.origin().toString(), S("its address reads %1").arg(shownText(world, S("environmentAddress"))));
    leaveEnvironment(world);
    // One environment, with its threads once, on the session the second link bought.
    threadRow(world, S("Tax line"));
    expect(world.native().store()->environments() == QStringList{world.mc.environmentId}, S("the phone holds %1").arg(world.native().store()->environments().join(S(", "))));
    expect(show(world.state(S("sidebar"))).count(S("Tax line")) == 1, S("the thread list is %1").arg(show(world.state(S("sidebar")))));
    expect(world.environment.sessions.size() == 2 && world.environment.pairingTokens.isEmpty(), S("the MC sold %1 sessions").arg(world.environment.sessions.size()));
    expect(keptPairing(world).value(QLatin1String("token")).toString() == world.environment.sessions.last(), S("the phone keeps %1").arg(show(keptPairing(world).toVariantMap())));
    world.waitFor([&] { return world.environment.connectedWithTicket(); }, S("the phone to connect with its new session"));
  });

  step(S("the user chooses to pair with another environment"), [](World& world, const Captures&, const Table&) { chooseToPairWithAnother(world); });

  step(S("the user is told that pairing replaces %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString said = shownText(world, S("pairingReplaces"));
    expect(said.contains(S("paired with %1 at %2").arg(c[0], world.mc.origin().toString())) && said.endsWith(S("replaces %1.").arg(c[0])),
           S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user starts to pair with another environment but goes back"), [](World& world, const Captures&, const Table&) {
    chooseToPairWithAnother(world);
    world.tap(S("pairingCancel"));
  });

  step(S("the user pairs with the environment %1 instead").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    PairableMc& other = world.another(c[0]);
    chooseToPairWithAnother(world);
    enterPairingLink(world, other.link());
    awaitConnection(world);
  });

  step(S("the user tries to pair with the environment %1 instead").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    PairableMc& other = world.another(c[0]);
    chooseToPairWithAnother(world);
    world.link = other.link();
    enterPairingLink(world, world.link);
  });

  // As it was before the link was spent: the environment's name and address,
  // the session the device keeps, and the connection that session opened.
  step(S("the phone is still paired with %1 and connected").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariantMap pairing = world.state(S("pairing")).toMap();
    expect(pairing.value(S("phase")) == S("paired") && pairing.value(S("label")) == c[0] && pairing.value(S("origin")) == world.mc.origin().toString(),
           S("the phone is %1").arg(show(pairing)));
    expect(keptPairing(world).value(QLatin1String("token")).toString() == world.environment.sessions.first(),
           S("the phone keeps %1").arg(show(keptPairing(world).toVariantMap())));
    expect(world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected") && world.mc.connections.size() == 1,
           S("the connection is %1, the MC's %2th").arg(show(world.state(S("connection")))).arg(world.mc.connections.size()));
    world.sync();
    expect(show(world.state(S("sidebar"))).contains(S("Tax line")), S("the thread list is %1").arg(show(world.state(S("sidebar")))));
    if (world.hasAnother()) expect(world.another(S("Office Mac")).mc.connections.isEmpty(), S("the phone connected to the other environment"));
    // And the way back from the pairing screen leads to it, in Settings where the user set out.
    world.back();
    world.waitFor([&] { return world.find(S("pairingScreen")) == nullptr; }, [&] { return S("the pairing screen to go; the screen says: %1").arg(screenTexts(world)); });
    expect(shownText(world, S("environmentName")) == c[0], S("the settings do not name %1; the screen says: %2").arg(c[0], screenTexts(world)));
  });

  step(S("%1 is listed in place of %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    PairableMc& other = world.another(c[0]);
    showEnvironment(world, c[0]);
    expect(shownText(world, S("environmentAddress")) == other.mc.origin().toString(), S("its address reads %1").arg(shownText(world, S("environmentAddress"))));
    expect(!world.shows(c[1], false), S("%1 is still on screen, which says: %2").arg(c[1], screenTexts(world)));
    leaveEnvironment(world);
    // The first environment's threads went with it, and the second's came.
    threadRow(world, other.threadTitle());
    expect(world.native().store()->environments() == QStringList{other.mc.environmentId}, S("the phone holds %1").arg(world.native().store()->environments().join(S(", "))));
    expect(!show(world.state(S("sidebar"))).contains(S("Tax line")), S("the thread list is %1").arg(show(world.state(S("sidebar")))));
    expect(keptPairing(world).value(QLatin1String("origin")).toString() == other.mc.origin().toString(), S("the phone keeps %1").arg(show(keptPairing(world).toVariantMap())));
  });

  // A link from outside the app: the system opens the app with it.
  step(S("the user (?:follows|followed) a pairing link from outside the app"), [](World& world, const Captures&, const Table&) {
    followPairingLink(world, world.environment.link());
  });

  step(S("the user (?:follows|followed) a pairing link to another environment from outside the app"), [](World& world, const Captures&, const Table&) {
    followPairingLink(world, world.another(S("Office Mac")).link());
  });

  step(S("the pairing form holds the link"), [](World& world, const Captures&, const Table&) {
    expect(shownText(world, S("pairingLink")) == world.link, S("the field reads %1").arg(shownText(world, S("pairingLink"))));
    expect(world.item(S("pairingPair"))->isEnabled(), S("the link cannot be paired with"));
  });

  step(S("the user is told which address the link would pair with"), [](World& world, const Captures&, const Table&) {
    const QString address = QUrl(world.link).adjusted(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment).toString();
    const QString said = shownText(world, S("pairingOffer"));
    expect(said.contains(S("from outside HAL-C2")) && said.contains(S("the environment at %1.").arg(address)), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the phone stays paired with %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariantMap pairing = world.state(S("pairing")).toMap();
    expect(pairing.value(S("phase")) == S("paired") && pairing.value(S("label")) == c[0] && pairing.value(S("origin")) == world.mc.origin().toString(),
           S("the phone is %1").arg(show(pairing)));
    // On the session it had: nothing was spent, here or anywhere else.
    expect(world.environment.sessions.size() == 1 && keptPairing(world).value(QLatin1String("token")).toString() == world.environment.sessions.first(),
           S("the phone keeps %1 and the MC sold %2 sessions").arg(show(keptPairing(world).toVariantMap())).arg(world.environment.sessions.size()));
    expect(world.environment.exchanges.size() == 1 && world.mc.connections.size() == 1,
           S("the MC saw %1 exchanges and %2 sockets").arg(world.environment.exchanges.size()).arg(world.mc.connections.size()));
    if (world.hasAnother()) {
      PairableMc& other = world.another(S("Office Mac"));
      expect(other.exchanges.isEmpty() && other.mc.connections.isEmpty() && other.pairingTokens.size() == 1, S("the other environment heard from the phone"));
    }
    expect(world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected"), S("the connection is %1").arg(show(world.state(S("connection")))));
  });

  step(S("the user goes back without pairing"), [](World& world, const Captures&, const Table&) {
    world.back();
    // Where the user was: the thread list, with the environment's threads.
    world.waitFor([&] { return world.find(S("pairingScreen")) == nullptr; }, [&] { return S("the pairing screen to go; the screen says: %1").arg(screenTexts(world)); });
    threadRow(world, S("Tax line"));
  });

  step(S("the user follows a link from outside the app that (carries no pairing link|carries something other than a web address|carries another link into the app|leads elsewhere in the app)"),
       [](World& world, const Captures& c, const Table&) {
         const QString inner = world.environment.link();
         world.mc.part<Seen>().sockets = world.mc.connections.size();
         world.followLink(c[0] == QLatin1String("carries no pairing link")                       ? S("hal-c2://pair")
                          : c[0] == QLatin1String("carries something other than a web address") ? appLinkTo(S("javascript:alert(1)//#token=abc"))
                          : c[0] == QLatin1String("carries another link into the app")          ? appLinkTo(appLinkTo(inner))
                                                                                                : S("hal-c2://thread/env-a/tax-line?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(inner)));
       });

  step(S("the user is told the link is not a pairing link"), [](World& world, const Captures&, const Table&) {
    const QString said = S("The link that opened HAL-C2 is not a pairing link. Nothing was changed.");
    world.waitFor([&] { return world.shows(said); }, [&] { return S("the phone to say so; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("%1 is still listed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // The question is gone, and Settings still names the environment.
    world.awaitPopup(S("confirmDialog"), false);
    world.item(S("pairingSettings"));
    expect(shownText(world, S("environmentName")) == c[0], S("the settings do not name %1; the screen says: %2").arg(c[0], screenTexts(world)));
    expect(pairingPhase(world) == QLatin1String("paired"), S("the phone is %1").arg(pairingPhase(world)));
    expect(QFile::exists(pairingFile(world)), S("the phone no longer keeps the pairing"));
    leaveEnvironment(world);
    threadRow(world, S("Tax line"));
    expect(world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected"), S("the connection is %1").arg(show(world.state(S("connection")))));
  });
});

}  // namespace
