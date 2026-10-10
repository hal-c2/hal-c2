#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>
#include <QUrl>

#include <functional>
#include <optional>

class QNetworkAccessManager;
class QObject;

// Pairing with an MC from a link its operator made (`mix hal_c2.pair`, the
// Connections page), for a client that pairs by itself: what the desktop's
// host does before it starts the shell (host/elixirMc.ts).
// The shell's "pair again" (ConnectionHealthController) and the phone's first
// pairing both go through here.
namespace pairing {

// Where a link says the MC is, in the order to try, and its single-use token.
struct Link {
  QList<QUrl> origins;
  QString token;
};

// Reads what the user entered: an http(s) address whose `token` is in the
// fragment or the query. An address typed without a scheme is tried over
// HTTPS, then over plain HTTP, which is what an MC on the LAN serves
// Nothing when it names no host or no token.
std::optional<Link> readLink(const QString& entered);

// A pairing link the user did not write: what a camera read off a QR code,
// or what another app opened this one with.
struct Invitation {
  // The pairing link itself, as the user would have entered it.
  QString link;
  // The MC it would pair with, to say to the user before anything is sent
  // there: its scheme, host and port, the host in ASCII so that a name made
  // to look like another shows as what it is (`xn--…`).
  QString address;
};

// Reads such a text: a pairing link written out in full
// (`http(s)://<address>/pair#token=…`, what an MC's QR code holds), or the
// app's own link to one, `hal-c2://pair?pairingUrl=<that link,
// percent-encoded>`, which the MC's /pair page offers a phone's browser.
// Stricter than readLink, since nobody chose this text: the scheme is never
// guessed and only http and https pass, the address carries no user name, and
// the app's link holds exactly one `pairingUrl`, decoded once, which is not
// itself an app link. Nothing for anything else.
std::optional<Invitation> readInvitation(const QString& received);

// What the client says about itself in the exchange; the MC lists it among
// its clients (apps/server-ex auth.ex).
struct Client {
  QString label;
  QString deviceType;  // desktop | mobile | tablet
  QString os;          // left out when empty
};

enum class Outcome {
  Paired,
  Unreachable,   // nothing answered at any of the link's origins
  NotMc,         // something answered that does not describe itself as an MC
  Incompatible,  // an MC of another protocol than McClient::kProtocol
  Refused,       // the MC turned the token down: spent, expired, or not its own
};

struct Result {
  Outcome outcome = Outcome::Unreachable;
  // The origin that answered; the first one tried when none did.
  QUrl origin;
  // The new session's access token, when paired.
  QString token;
  // The MC's descriptor (environmentId, label, orchestrationProtocolVersion),
  // once an MC answered.
  QJsonObject descriptor;
};

// Finds the MC among the link's origins by its descriptor
// (`/.well-known/hal-c2/environment`) and spends the token on a session
// there (`/oauth/token`). The token is only sent to an MC this client can
// speak to, so every other outcome leaves it unspent. `done` is called once,
// unless `context` goes first.
void exchange(QNetworkAccessManager* http, QObject* context, const Link& link, const Client& client,
              std::function<void(const Result&)> done);

}  // namespace pairing
