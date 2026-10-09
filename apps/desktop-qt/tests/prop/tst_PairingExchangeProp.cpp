// Pairing from a link (src/native/PairingExchange): the links themselves,
// printed and read back, wrapped in the app's own link, and made hostile; and
// the exchange against MCs a model scripts, that describe themselves or not,
// speak another protocol, take a token, turn it down, hang up or hold on, with
// addresses ahead of them that nothing answers at, several exchanges at once,
// and some left behind by the screen that started them.

#include "Prop.h"

#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUrlQuery>

#include <deque>
#include <memory>
#include <optional>
#include <vector>

#include "FakeMc.h"
#include "McClient.h"
#include "PairingExchange.h"

namespace {

// ---- Links -----------------------------------------------------------------

struct Printed {
  QString scheme;
  QString host;
  int port = -1;
  QString path;
  QString token;
  // The token in the fragment, as an MC's QR code has it, or in the query.
  bool inFragment = true;

  QUrl origin() const {
    QUrl url;
    url.setScheme(scheme);
    url.setHost(host);
    url.setPort(port);
    return url;
  }
  QString address() const {
    QString text = host;
    if (port != -1) text += QLatin1Char(':') + QString::number(port);
    return text;
  }
  QString print(bool withScheme = true) const {
    const QString carried = QStringLiteral("token=") + QString::fromUtf8(QUrl::toPercentEncoding(token));
    return (withScheme ? scheme + QStringLiteral("://") : QString()) + address() + path + (inFragment ? QStringLiteral("#") : QStringLiteral("?")) + carried;
  }
};

void showValue(const Printed& printed, std::ostream& os) { os << printed.print().toStdString(); }

rc::Gen<QString> token() {
  // What `mix hal_c2.pair` makes, and what an MC may yet: base64 of either
  // kind, and characters a link has to escape.
  static const QString alphabet = QStringLiteral("abcXYZ0129-_+/=~.&#%?é ");
  return rc::gen::map(rc::gen::nonEmpty(rc::gen::container<std::vector<int>>(rc::gen::inRange<int>(0, alphabet.size()))), [](const std::vector<int>& picks) {
    QString text;
    for (int pick : picks) text += alphabet.at(pick);
    // A token is read trimmed.
    text = text.trimmed();
    return text.isEmpty() ? QStringLiteral("t") : text;
  });
}

rc::Gen<Printed> printed() {
  return rc::gen::build<Printed>(
      rc::gen::set(&Printed::scheme, rc::gen::element(QStringLiteral("http"), QStringLiteral("https"))),
      rc::gen::set(&Printed::host, rc::gen::element(QStringLiteral("127.0.0.1"), QStringLiteral("devbox.tailnet.ts.net"), QStringLiteral("localhost"),
                                                   QStringLiteral("mc.example"), QStringLiteral("bücher.example"), QStringLiteral("[::1]"))),
      rc::gen::set(&Printed::port, rc::gen::element(-1, 80, 443, 3797, 65535)),
      rc::gen::set(&Printed::path, rc::gen::element(QStringLiteral("/"), QStringLiteral("/pair"), QString())),
      rc::gen::set(&Printed::token, token()), rc::gen::set(&Printed::inFragment, rc::gen::arbitrary<bool>()));
}

// The app's own link to `link`.
QString wrapped(const QString& link) { return QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(link)); }

bool same(const std::optional<pairing::Invitation>& a, const std::optional<pairing::Invitation>& b) {
  if (a.has_value() != b.has_value()) return false;
  return !a || (a->link == b->link && a->address == b->address);
}

// ---- The exchange ----------------------------------------------------------

// Where a link's origin leads.
enum class At { McA, McB, Nothing, HangsUp, WebServer };
constexpr int kMcs = 2;

// How an MC answers who it is.
enum class Describes { Mc, NotFound, NoEnvironment, ProtocolAsText, OtherProtocol };
// How it answers a token.
enum class Takes { Spends, Refuses, NoSession, HangsUp, Holds };

const char* name(At at) {
  switch (at) {
    case At::McA: return "a";
    case At::McB: return "b";
    case At::Nothing: return "nothing";
    case At::HangsUp: return "hangs up";
    case At::WebServer: return "web server";
  }
  return "?";
}
const char* name(Describes describes) {
  switch (describes) {
    case Describes::Mc: return "an MC";
    case Describes::NotFound: return "404";
    case Describes::NoEnvironment: return "no environment";
    case Describes::ProtocolAsText: return "protocol as text";
    case Describes::OtherProtocol: return "another protocol";
  }
  return "?";
}
const char* name(Takes takes) {
  switch (takes) {
    case Takes::Spends: return "spends";
    case Takes::Refuses: return "refuses";
    case Takes::NoSession: return "200 without a session";
    case Takes::HangsUp: return "hangs up";
    case Takes::Holds: return "holds";
  }
  return "?";
}
const char* name(pairing::Outcome outcome) {
  switch (outcome) {
    case pairing::Outcome::Paired: return "paired";
    case pairing::Outcome::Unreachable: return "unreachable";
    case pairing::Outcome::NotMc: return "not an MC";
    case pairing::Outcome::Incompatible: return "incompatible";
    case pairing::Outcome::Refused: return "refused";
  }
  return "?";
}

int mcOf(At at) { return at == At::McA ? 0 : at == At::McB ? 1 : -1; }

// What an exchange came to, or will.
struct Expected {
  pairing::Outcome outcome = pairing::Outcome::Unreachable;
  At origin = At::Nothing;
  int session = 0;  // the MC's nth session sold, when paired
};

struct Exchange {
  std::vector<At> origins;
  QString token;
  // Waiting on the MC's answer to its token, at `mc`.
  bool held = false;
  int mc = -1;
  // The screen that started it is gone.
  bool left = false;
  std::optional<Expected> done;
};

struct McModel {
  Describes describes = Describes::Mc;
  Takes takes = Takes::Spends;
  QStringList unspent;
  int issued = 0;
  int sold = 0;
  // Every token it was sent.
  int sent = 0;
  // Exchanges it holds, oldest first.
  std::vector<int> held;
};

struct Model {
  McModel mcs[kMcs];
  std::vector<Exchange> exchanges;

  int heldCount() const {
    int count = 0;
    for (const McModel& mc : mcs) count += int(mc.held.size());
    return count;
  }
};

// The answer to a token the MC takes: a session if it was its own and unspent.
Expected spent(McModel& mc, int at, const QString& token) {
  if (!mc.unspent.removeOne(token)) return {pairing::Outcome::Refused, At(at)};
  return {pairing::Outcome::Paired, At(at), ++mc.sold};
}

// Runs an exchange through the origins as describe() does, up to its answer or
// the MC holding on to its token.
void start(Model& m, int index) {
  Exchange& exchange = m.exchanges[index];
  for (At at : exchange.origins) {
    if (at == At::Nothing || at == At::HangsUp) continue;
    if (at == At::WebServer) {
      exchange.done = Expected{pairing::Outcome::NotMc, at};
      return;
    }
    McModel& mc = m.mcs[mcOf(at)];
    switch (mc.describes) {
      case Describes::Mc: break;
      case Describes::OtherProtocol: exchange.done = Expected{pairing::Outcome::Incompatible, at}; return;
      default: exchange.done = Expected{pairing::Outcome::NotMc, at}; return;
    }
    ++mc.sent;
    switch (mc.takes) {
      case Takes::Spends: exchange.done = spent(mc, int(at), exchange.token); return;
      case Takes::Refuses: exchange.done = Expected{pairing::Outcome::Refused, at}; return;
      case Takes::NoSession:
        // The MC spends it, and gives nothing for it.
        mc.unspent.removeOne(exchange.token);
        exchange.done = Expected{pairing::Outcome::Refused, at};
        return;
      case Takes::HangsUp: exchange.done = Expected{pairing::Outcome::Unreachable, at}; return;
      case Takes::Holds:
        exchange.held = true;
        exchange.mc = mcOf(at);
        mc.held.push_back(index);
        return;
    }
  }
  exchange.done = Expected{pairing::Outcome::Unreachable, exchange.origins.front()};
}

// ---- The MCs ---------------------------------------------------------------

void respond(QTcpSocket* socket, int status, const QByteArray& body, const QByteArray& type = "application/json") {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + (status < 300 ? " OK" : " Refused") + "\r\nContent-Type: " + type +
                "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

QByteArray json(const QJsonObject& object) { return QJsonDocument(object).toJson(QJsonDocument::Compact); }

// An MC whose answers the model sets, on the fake MC's listener.
struct Mc {
  struct Held {
    QPointer<QTcpSocket> socket;
    QString token;
  };

  explicit Mc(const QString& name) : environmentId(QStringLiteral("env-") + name) {
    mc.onRaw(QStringLiteral("/.well-known/hal-c2/environment"), [this](QTcpSocket* socket, const QByteArray&) {
      QJsonObject descriptor{{QStringLiteral("environmentId"), environmentId},
                             {QStringLiteral("label"), QStringLiteral("Mac ") + environmentId},
                             {QStringLiteral("orchestrationProtocolVersion"), McClient::kProtocol}};
      switch (describes) {
        case Describes::Mc: break;
        case Describes::NotFound: return respond(socket, 404, "<html>Not found</html>", "text/html");
        case Describes::NoEnvironment: descriptor.remove(QStringLiteral("environmentId")); break;
        case Describes::ProtocolAsText: descriptor.insert(QStringLiteral("orchestrationProtocolVersion"), QString::number(McClient::kProtocol)); break;
        case Describes::OtherProtocol: descriptor.insert(QStringLiteral("orchestrationProtocolVersion"), McClient::kProtocol + 1); break;
      }
      respond(socket, 200, json(descriptor));
    });
    mc.onRaw(QStringLiteral("/oauth/token"), [this](QTcpSocket* socket, const QByteArray& head) {
      static const QRegularExpression contentLength(QStringLiteral("content-length: *(\\d+)"), QRegularExpression::CaseInsensitiveOption);
      const qsizetype length = contentLength.match(QString::fromUtf8(head)).captured(1).toLongLong();
      auto read = std::make_shared<bool>(false);
      // The form may come after its headers.
      const auto exchange = [this, socket, head, length, read] {
        const QByteArray request = socket->peek(socket->bytesAvailable());
        if (*read || request.size() < head.size() + length) return;
        *read = true;
        const QUrlQuery form(QString::fromUtf8(request.mid(head.size(), length)));
        forms.append(form);
        const QString token = form.queryItemValue(QStringLiteral("subject_token"), QUrl::FullyDecoded);
        switch (takes) {
          case Takes::Spends: return answer(socket, token);
          case Takes::Refuses: return respond(socket, 400, json({{QStringLiteral("error"), QStringLiteral("invalid_grant")}}));
          case Takes::NoSession:
            unspent.removeOne(token);
            return respond(socket, 200, json({{QStringLiteral("token_type"), QStringLiteral("Bearer")}}));
          case Takes::HangsUp: return socket->abort();
          case Takes::Holds: held.append({socket, token}); return;
        }
      };
      QObject::connect(socket, &QTcpSocket::readyRead, socket, exchange);
      exchange();
    });
  }
  ~Mc() {
    for (const Held& waiting : held) {
      if (waiting.socket) waiting.socket->abort();
    }
  }

  QString session(int n) const { return QStringLiteral("session-%1-%2").arg(environmentId).arg(n); }
  // Spends `token` on a session, if it is one of ours and unspent.
  void answer(QTcpSocket* socket, const QString& token) {
    if (!unspent.removeOne(token)) return respond(socket, 400, json({{QStringLiteral("error"), QStringLiteral("invalid_grant")}}));
    respond(socket, 200, json({{QStringLiteral("access_token"), session(++sold)}, {QStringLiteral("token_type"), QStringLiteral("Bearer")}}));
  }
  QString issue() {
    unspent.append(QStringLiteral("pair-%1-%2").arg(environmentId).arg(++issued));
    return unspent.last();
  }

  FakeMc mc;
  QString environmentId;
  Describes describes = Describes::Mc;
  Takes takes = Takes::Spends;
  QStringList unspent;
  int issued = 0;
  int sold = 0;
  QList<QUrlQuery> forms;
  QList<Held> held;
};

QUrl deadOrigin() {
  QTcpServer server;
  if (!server.listen(QHostAddress::LocalHost)) qFatal("cannot listen");
  return QUrl(QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort()));
}

struct Started {
  std::unique_ptr<QObject> context = std::make_unique<QObject>();
  QList<pairing::Result> results;
};

const pairing::Client kClient{QStringLiteral("HAL-C2 desktop"), QStringLiteral("desktop"), QStringLiteral("linux")};

struct Sut {
  Sut() : a(QStringLiteral("a")), b(QStringLiteral("b")) {
    // Once the others listen, so that none of them comes to answer there.
    nothing = deadOrigin();
    hangsUp.onRaw(QStringLiteral("/"), [](QTcpSocket* socket, const QByteArray&) { socket->abort(); });
    web.onRaw(QStringLiteral("/"), [](QTcpSocket* socket, const QByteArray&) { respond(socket, 404, "<html>Not found</html>", "text/html"); });
  }
  ~Sut() {
    started.clear();
    halc2::prop::settle();
  }

  Mc& mc(int index) { return index == 0 ? a : b; }
  QUrl origin(At at) const {
    switch (at) {
      case At::McA: return a.mc.origin();
      case At::McB: return b.mc.origin();
      case At::Nothing: return nothing;
      case At::HangsUp: return hangsUp.origin();
      case At::WebServer: return web.origin();
    }
    return {};
  }

  void check(const Model& m) {
    for (int i = 0; i < kMcs; ++i) {
      const McModel& model = m.mcs[i];
      const Mc& real = mc(i);
      RC_ASSERT(real.unspent == model.unspent);
      RC_ASSERT(real.sold == model.sold);
      // The token goes only to an MC this client speaks to.
      RC_ASSERT(int(real.forms.size()) == model.sent);
      for (const QUrlQuery& form : real.forms) {
        RC_ASSERT(form.queryItemValue(QStringLiteral("client_label"), QUrl::FullyDecoded) == kClient.label);
        RC_ASSERT(form.queryItemValue(QStringLiteral("client_device_type")) == kClient.deviceType);
        RC_ASSERT(form.queryItemValue(QStringLiteral("client_os")) == kClient.os);
      }
      RC_ASSERT(int(real.held.size()) == int(model.held.size()));
    }
    RC_ASSERT(started.size() == m.exchanges.size());
    for (size_t i = 0; i < started.size(); ++i) {
      const Exchange& exchange = m.exchanges[i];
      const QList<pairing::Result>& results = started[i].results;
      // Once, and never for a screen that is gone.
      if (!exchange.done || exchange.left) {
        RC_ASSERT(results.isEmpty());
        continue;
      }
      RC_ASSERT(results.size() == 1);
      const pairing::Result& result = results.first();
      const Expected& expected = *exchange.done;
      RC_ASSERT(std::string(name(result.outcome)) == name(expected.outcome));
      RC_ASSERT(result.origin == origin(expected.origin));
      const int at = mcOf(expected.origin);
      RC_ASSERT(result.token == (expected.outcome == pairing::Outcome::Paired ? mc(at).session(expected.session) : QString()));
      const bool described = at >= 0 && expected.outcome != pairing::Outcome::NotMc;
      RC_ASSERT(result.descriptor.value(QLatin1String("environmentId")).toString() == (described ? mc(at).environmentId : QString()));
    }
  }

  Mc a;
  Mc b;
  QUrl nothing;
  FakeMc hangsUp;
  FakeMc web;
  QNetworkAccessManager http;
  // A deque: what an exchange answers goes where it was started, as more start.
  std::deque<Started> started;
};

using Command = rc::state::Command<Model, Sut>;

// The MC answers from now on as set.
struct Set : Command {
  int mc = *rc::gen::inRange(0, kMcs);
  Describes describes = *rc::gen::element(Describes::Mc, Describes::Mc, Describes::Mc, Describes::NotFound, Describes::NoEnvironment,
                                          Describes::ProtocolAsText, Describes::OtherProtocol);
  Takes takes = *rc::gen::element(Takes::Spends, Takes::Spends, Takes::Refuses, Takes::NoSession, Takes::HangsUp, Takes::Holds, Takes::Holds);

  explicit Set(const Model&) {}
  void apply(Model& m) const override {
    m.mcs[mc].describes = describes;
    m.mcs[mc].takes = takes;
  }
  void run(const Model&, Sut& s) const override {
    s.mc(mc).describes = describes;
    s.mc(mc).takes = takes;
  }
  void show(std::ostream& os) const override { os << "Set(" << (mc == 0 ? "a" : "b") << ": " << name(describes) << ", " << name(takes) << ")"; }
};

// An exchange from a link whose origins are tried in order, with a token one
// of the MCs issued for it, an old one, or one nobody did.
struct Start : Command {
  std::vector<At> origins = *rc::gen::container<std::vector<At>>(
      *rc::gen::inRange(1, 4), rc::gen::element(At::McA, At::McA, At::McB, At::Nothing, At::HangsUp, At::WebServer));
  // 0: a fresh one of a's, 1: of b's, 2: the last a issued, 3: one nobody issued
  int token = *rc::gen::element(0, 0, 1, 2, 3);

  explicit Start(const Model&) {}
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.exchanges.size() < 12);
    // Held on to, an exchange runs into its transfer timeout in time.
    RC_PRE(m.heldCount() < 3);
  }
  QString tokenFor(int issued) const {
    if (token == 3) return QStringLiteral("forged");
    return QStringLiteral("pair-env-%1-%2").arg(token == 1 ? QLatin1String("b") : QLatin1String("a")).arg(issued);
  }
  void apply(Model& m) const override {
    Exchange exchange;
    exchange.origins = origins;
    if (token == 0 || token == 1) {
      McModel& issuer = m.mcs[token];
      ++issuer.issued;
      exchange.token = tokenFor(issuer.issued);
      issuer.unspent.append(exchange.token);
    } else if (token == 2) {
      exchange.token = tokenFor(m.mcs[0].issued);
    } else {
      exchange.token = tokenFor(0);
    }
    m.exchanges.push_back(exchange);
    start(m, int(m.exchanges.size()) - 1);
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    const Exchange& expected = next.exchanges.back();
    if (token == 0 || token == 1) s.mc(token).issue();
    pairing::Link link;
    for (At at : origins) link.origins.append(s.origin(at));
    link.token = expected.token;
    s.started.emplace_back();
    Started& started = s.started.back();
    const int heldBefore = expected.held ? int(s.mc(expected.mc).held.size()) : 0;
    pairing::exchange(&s.http, started.context.get(), link, kClient, [&results = started.results](const pairing::Result& result) { results.append(result); });
    if (expected.held) {
      RC_ASSERT(halc2::prop::until([&] { return int(s.mc(expected.mc).held.size()) > heldBefore; }));
    } else {
      RC_ASSERT(halc2::prop::until([&] { return !started.results.isEmpty(); }));
    }
    halc2::prop::settle();
    s.check(next);
  }
  void show(std::ostream& os) const override {
    os << "Start([";
    for (size_t i = 0; i < origins.size(); ++i) os << (i ? ", " : "") << name(origins[i]);
    static const char* tokens[] = {"fresh of a", "fresh of b", "a's last", "forged"};
    os << "], " << tokens[token] << ")";
  }
};

// The MC answers the nth token it holds, or hangs up on it.
struct Release : Command {
  int mc = *rc::gen::inRange(0, kMcs);
  int nth = *rc::gen::inRange(0, 3);
  bool hangUp = *rc::gen::element(false, false, true);

  explicit Release(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(nth < int(m.mcs[mc].held.size())); }
  void apply(Model& m) const override {
    McModel& model = m.mcs[mc];
    Exchange& exchange = m.exchanges[model.held[nth]];
    model.held.erase(model.held.begin() + nth);
    exchange.held = false;
    exchange.done = hangUp ? Expected{pairing::Outcome::Unreachable, At(mc)} : spent(model, mc, exchange.token);
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    Mc& real = s.mc(mc);
    const Mc::Held waiting = real.held.takeAt(nth);
    RC_ASSERT(!waiting.socket.isNull());
    QSignalSpy finished(&s.http, &QNetworkAccessManager::finished);
    if (hangUp) {
      waiting.socket->abort();
    } else {
      real.answer(waiting.socket, waiting.token);
    }
    RC_ASSERT(finished.wait(halc2::test::wait()));
    halc2::prop::settle();
    s.check(next);
  }
  void show(std::ostream& os) const override { os << (hangUp ? "HangUp(" : "Release(") << (mc == 0 ? "a" : "b") << ", " << nth << ")"; }
};

// The screen that started an exchange goes, answered or not.
struct Leave : Command {
  int nth = *rc::gen::inRange(0, 12);

  explicit Leave(const Model&) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(nth < int(m.exchanges.size()));
    RC_PRE(!m.exchanges[nth].left); }
  void apply(Model& m) const override { m.exchanges[nth].left = true; }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.started[nth].context.reset();
    // What it had is forgotten with it.
    s.started[nth].results.clear();
    halc2::prop::settle();
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Leave(" << nth << ")"; }
};

}  // namespace

class PairingExchangeProp : public QObject {
  Q_OBJECT

private slots:
  // Laws of the links: what is printed is read back.
  void linksReadBack() {
    QVERIFY(rc::check("a printed link reads back to its origin and token", [] {
      const Printed link = *printed();
      const auto read = pairing::readLink(link.print());
      RC_ASSERT(read.has_value());
      RC_ASSERT(read->token == link.token);
      RC_ASSERT(read->origins == QList<QUrl>{link.origin()});
      // As the user may paste it.
      const auto pasted = pairing::readLink(QStringLiteral("  ") + link.print() + QStringLiteral("\n"));
      RC_ASSERT(pasted.has_value());
      RC_ASSERT(pasted->token == link.token);
      RC_ASSERT(pasted->origins == read->origins);
    }));
    QVERIFY(rc::check("a link typed without its scheme is tried over HTTPS, then HTTP", [] {
      const Printed link = *printed();
      const auto read = pairing::readLink(link.print(false));
      RC_ASSERT(read.has_value());
      RC_ASSERT(read->token == link.token);
      Printed secure = link;
      secure.scheme = QStringLiteral("https");
      Printed plain = link;
      plain.scheme = QStringLiteral("http");
      RC_ASSERT(read->origins == (QList<QUrl>{secure.origin(), plain.origin()}));
    }));
  }

  void invitationsReadBack() {
    QVERIFY(rc::check("an invitation is its link, read back the same, wrapped or not", [] {
      const Printed link = *printed();
      const auto invitation = pairing::readInvitation(link.print());
      RC_ASSERT(invitation.has_value());
      RC_ASSERT(invitation->link == link.print());
      RC_ASSERT(invitation->address == link.origin().toString(QUrl::FullyEncoded));
      // The address is ASCII, whatever the host looks like.
      for (QChar c : invitation->address) RC_ASSERT(c.unicode() < 0x80);
      RC_ASSERT(same(pairing::readInvitation(invitation->link), invitation));
      RC_ASSERT(same(pairing::readInvitation(wrapped(link.print())), invitation));
      // And readLink pairs with the address it showed.
      const auto read = pairing::readLink(invitation->link);
      RC_ASSERT(read.has_value());
      RC_ASSERT(read->origins.size() == 1);
      RC_ASSERT(read->origins.first().toString(QUrl::FullyEncoded) == invitation->address);
      RC_ASSERT(read->token == link.token);
    }));
  }

  void hostileTextIsNoInvitation() {
    QVERIFY(rc::check("text nobody chose is no invitation unless it is a plain pairing link", [] {
      const Printed link = *printed();
      const QString plain = link.print();
      const QString hostile = *rc::gen::element(
          // A user name before the host, to make it read as another.
          link.scheme + QStringLiteral("://") + link.origin().host() + QStringLiteral("@evil.example/#token=") + link.token,
          link.scheme + QStringLiteral("://user:pw@") + link.address() + link.path + QStringLiteral("#token=x"),
          // Schemes other than the web's.
          QStringLiteral("ftp://") + link.address() + QStringLiteral("/#token=x"), QStringLiteral("javascript:alert(1)//#token=x"),
          QStringLiteral("file:///etc/passwd#token=x"),
          // A guessed scheme.
          link.print(false),
          // No token.
          link.scheme + QStringLiteral("://") + link.address() + QStringLiteral("/pair"),
          link.scheme + QStringLiteral("://") + link.address() + QStringLiteral("/pair#token="),
          // The app's link, bent.
          wrapped(plain) + QStringLiteral("&pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(plain)), wrapped(wrapped(plain)),
          QStringLiteral("hal-c2://unpair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(plain)),
          QStringLiteral("hal-c2://pair/more?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(plain)),
          QStringLiteral("hal-c2://pair:1?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(plain)), QStringLiteral("hal-c2://pair"),
          // Too long for a QR code's link.
          plain + QString(2048, QLatin1Char('a')));
      RC_ASSERT(!pairing::readInvitation(hostile).has_value());
    }));
  }

  void exchange() {
    QVERIFY(rc::check("exchanges agree with the model of the MCs they meet", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Set, Start, Start, Start, Release, Release, Leave>());
    }));
  }
};

HAL_C2_PROP_MAIN(PairingExchangeProp)
#include "tst_PairingExchangeProp.moc"
