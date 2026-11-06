// Two clients as the shell holds them (McClient): its own, and a saved
// environment's ("studio") on a connection of its own, routed to by the first
// (setRoute). Their credentials run out soon, later or never, their MCs renew
// them or refuse to, and the clients make HTTP requests, call either
// environment and reconnect. A request renews a credential about to run out
// first, and fails alone when that is refused; a socket is never opened or
// closed for it; a renewal moves the expiry on; and a call reaches the MC of
// the environment it names.

#include "Prop.h"

#include <QTcpSocket>

#include <array>
#include <memory>

#include "FakeMc.h"
#include "McClient.h"

namespace {

enum class Expiry { Never, Soon, Later };
enum Which { Own = 0, Studio = 1 };

const char* name(Expiry expiry) {
  switch (expiry) {
    case Expiry::Never: return "never";
    case Expiry::Soon: return "soon";
    case Expiry::Later: return "later";
  }
  return "?";
}
const char* name(int which) {
  return which == Own ? "own" : "studio";
}

void respond(QTcpSocket* socket, int status, const QByteArray& body) {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + " Status\r\nContent-Type: application/json\r\nContent-Length: " +
                QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

struct Model {
  std::array<Expiry, 2> expiry{Expiry::Never, Expiry::Never};
  // Whether each MC renews a credential when asked.
  std::array<bool, 2> renews{true, true};
  std::array<int, 2> renewals{0, 0};
  std::array<int, 2> reached{0, 0};  // requests that reached each MC
};

struct Side {
  FakeMc mc;
  std::unique_ptr<McClient> client;
  int renewStatus = 200;
  int renewals = 0;
  int reached = 0;
};

struct Sut {
  std::array<Side, 2> sides;
  QObject context;

  Sut() {
    sides[Studio].mc.name = QStringLiteral("mc-studio");
    sides[Studio].mc.environmentId = QStringLiteral("studio");
    for (Side& side : sides) {
      FakeMc& mc = side.mc;
      mc.onRaw(QStringLiteral("/.well-known/hal-c2/environment"), [&mc](QTcpSocket* socket, const QByteArray&) {
        respond(socket, 200, QJsonDocument(QJsonObject{{QStringLiteral("environmentId"), mc.environmentId}}).toJson(QJsonDocument::Compact));
      });
      mc.onRaw(QStringLiteral("/api/auth/session/renew"), [&side](QTcpSocket* socket, const QByteArray&) {
        ++side.renewals;
        if (side.renewStatus != 200) return respond(socket, side.renewStatus, R"({"reason":"auth_invalid"})");
        const QString expiresAt = QDateTime::currentDateTimeUtc().addDays(30).toString(Qt::ISODateWithMs);
        respond(socket, 200, QJsonDocument(QJsonObject{{QStringLiteral("expiresAt"), expiresAt}}).toJson(QJsonDocument::Compact));
      });
      mc.onHttp(QStringLiteral("/api/prop/probe"), [&side](const QJsonObject&, auto answer) {
        ++side.reached;
        answer(200, {{QStringLiteral("ok"), true}});
      });
      mc.onRpc(QStringLiteral("prop.which"), [&mc](const FakeMc::Rpc& rpc) { mc.reply(rpc, mc.name); });
      side.client = std::make_unique<McClient>();
      side.client->setRetryDelays({20});
      side.client->setSetupTimeout(500);
      side.client->setProbeTimeout(100);
    }
    // The shell's own client hands what is about "studio" to studio's.
    sides[Own].client->setRoute([this](const QString& environment, const QString&) -> McClient* {
      return environment == QLatin1String("studio") ? sides[Studio].client.get() : nullptr;
    });
    for (Side& side : sides) side.client->open(side.mc.origin(), QStringLiteral("token"), side.mc.environmentId);
    for (Side& side : sides) RC_ASSERT(halc2::prop::until([&] { return side.client->isReady(); }));
  }
};

QDateTime at(Expiry expiry) {
  switch (expiry) {
    case Expiry::Never: return {};
    case Expiry::Soon: return QDateTime::currentDateTimeUtc().addSecs(60);
    case Expiry::Later: return QDateTime::currentDateTimeUtc().addDays(7);
  }
  return {};
}

void expectSame(const Model& model, Sut& sut) {
  for (int which : {Own, Studio}) {
    const Side& side = sut.sides[size_t(which)];
    RC_ASSERT(side.renewals == model.renewals[size_t(which)]);
    RC_ASSERT(side.reached == model.reached[size_t(which)]);
    const QDateTime expiresAt = side.client->credentialExpiry();
    switch (model.expiry[size_t(which)]) {
      case Expiry::Never:
        RC_ASSERT(!expiresAt.isValid());
        break;
      case Expiry::Soon:
        RC_ASSERT(expiresAt < QDateTime::currentDateTimeUtc().addDays(1));
        break;
      case Expiry::Later:
        RC_ASSERT(expiresAt > QDateTime::currentDateTimeUtc().addDays(1));
        break;
    }
  }
}

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(model, sut);
    expectSame(next, sut);
  }
};

struct SetExpiry : Step<SetExpiry> {
  int which = *rc::gen::element(int(Own), int(Studio));
  Expiry expiry = *rc::gen::element(Expiry::Never, Expiry::Soon, Expiry::Later);

  explicit SetExpiry(const Model&) {}
  void apply(Model& model) const override { model.expiry[size_t(which)] = expiry; }
  void act(const Model&, Sut& sut) const { sut.sides[size_t(which)].client->setCredentialExpiry(at(expiry)); }
  void show(std::ostream& os) const override { os << "SetExpiry(" << name(which) << ", " << name(expiry) << ")"; }
};

struct SetRenewal : Step<SetRenewal> {
  int which = *rc::gen::element(int(Own), int(Studio));
  bool renews = *rc::gen::arbitrary<bool>();

  explicit SetRenewal(const Model&) {}
  void apply(Model& model) const override { model.renews[size_t(which)] = renews; }
  void act(const Model&, Sut& sut) const { sut.sides[size_t(which)].renewStatus = renews ? 200 : 401; }
  void show(std::ostream& os) const override { os << "SetRenewal(" << name(which) << ", " << (renews ? "renews" : "refuses") << ")"; }
};

// One HTTP request on a client.
struct Post : Step<Post> {
  int which = *rc::gen::element(int(Own), int(Studio));

  explicit Post(const Model&) {}
  static bool fails(const Model& model, int which) { return model.expiry[size_t(which)] == Expiry::Soon && !model.renews[size_t(which)]; }
  void apply(Model& model) const override {
    const size_t i = size_t(which);
    if (!fails(model, which)) ++model.reached[i];
    if (model.expiry[i] == Expiry::Soon) {
      ++model.renewals[i];
      if (model.renews[i]) model.expiry[i] = Expiry::Later;
    }
  }
  void act(const Model& model, Sut& sut) const {
    Side& side = sut.sides[size_t(which)];
    const qsizetype sockets = side.mc.connections.size();
    bool replied = false;
    std::optional<QString> error;
    side.client->post(&sut.context, QStringLiteral("/api/prop/probe"), {}, [&](const QJsonValue&, const std::optional<QString>& why) {
      replied = true;
      error = why;
    });
    RC_ASSERT(halc2::prop::until([&] { return replied; }));
    // It fails alone, and says why.
    RC_ASSERT(error.has_value() == fails(model, which));
    if (error) RC_ASSERT(error->contains(QLatin1String("could not be renewed")));
    RC_ASSERT(side.client->isReady());
    RC_ASSERT(side.client->failure().isEmpty());
    RC_ASSERT(side.mc.connections.size() == sockets);
  }
  void show(std::ostream& os) const override { os << "Post(" << name(which) << ")"; }
};

// The shell's own client calls an environment; it reaches that environment's MC.
struct Call : Step<Call> {
  int target = *rc::gen::element(int(Own), int(Studio));

  explicit Call(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    std::optional<QString> answered;
    const QString environment = sut.sides[size_t(target)].mc.environmentId;
    sut.sides[Own].client->call(&sut.context, environment, QStringLiteral("prop.which"), QJsonObject{},
                                [&](const QJsonValue& result, const std::optional<QString>& error) {
                                  answered = error ? QStringLiteral("error: ") + *error : result.toString();
                                });
    RC_ASSERT(halc2::prop::until([&] { return answered.has_value(); }));
    RC_ASSERT(*answered == sut.sides[size_t(target)].mc.name);
  }
  void show(std::ostream& os) const override { os << "Call(" << name(target) << ")"; }
};

// A client's socket is replaced; a credential about to run out is renewed for
// its ticket first, and a refused renewal does not keep it from connecting.
struct Reconnect : Step<Reconnect> {
  int which = *rc::gen::element(int(Own), int(Studio));

  explicit Reconnect(const Model&) {}
  void apply(Model& model) const override {
    const size_t i = size_t(which);
    if (model.expiry[i] != Expiry::Soon) return;
    ++model.renewals[i];
    if (model.renews[i]) model.expiry[i] = Expiry::Later;
  }
  void act(const Model&, Sut& sut) const {
    Side& side = sut.sides[size_t(which)];
    const qsizetype sockets = side.mc.connections.size();
    side.client->reconnect();
    RC_ASSERT(halc2::prop::until([&] { return side.client->isReady() && side.mc.connections.size() > sockets; }));
    // The other connection did not notice.
    const Side& other = sut.sides[size_t(1 - which)];
    RC_ASSERT(other.client->isReady());
  }
  void show(std::ostream& os) const override { os << "Reconnect(" << name(which) << ")"; }
};

}  // namespace

class McClientRenewalProp : public QObject {
  Q_OBJECT

private slots:
  void renewsAloneAndRoutes() {
    QVERIFY(rc::check("a credential is renewed before the request that needs it, a refused renewal fails only that request, and calls reach their environment", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<SetExpiry, SetExpiry, SetRenewal, Post, Post, Post, Call, Reconnect>());
    }));
  }
};

HAL_C2_PROP_MAIN(McClientRenewalProp)
#include "tst_McClientRenewalProp.moc"
