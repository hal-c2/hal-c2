// The phone's pairing (src/Pairing) against a model of what the user did and
// what the MCs answered: links typed, pasted again, and handed in from
// outside, token exchanges answered, refused, held and dropped, a second
// pairing started while one is in flight, adding and cancelling, forgetting,
// and the app started again over what the device kept.

#include "Prop.h"

#include <QDir>
#include <QFile>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QTcpSocket>

#include <array>
#include <map>
#include <memory>
#include <optional>
#include <vector>

#include "McClient.h"
#include "NativeShell.h"
#include "PairableMc.h"
#include "Pairing.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"

namespace {

constexpr int kMcs = 2;
const std::array<const char*, kMcs> kNames{"a", "b"};
const std::array<const char*, kMcs> kLabels{"Mac A", "Mac B"};

// What a link names: a fresh token, one the MC already sold a session for, one
// it never gave out (or let expire), text that is no pairing link, or an
// address nothing answers at.
enum class Kind { Fresh, Reused, Expired, Malformed, Dead };
// How the MC takes the token: answers at once, keeps the request waiting
// (Release answers it later), or drops the connection.
enum class How { Answer, Hold, Drop };
// What the pairing screen says.
enum class Said { Nothing, NotALink, Unreachable, Refused, NotAPairingLink, NotSaved, NotForgotten };

const char* name(Kind kind) {
  switch (kind) {
    case Kind::Fresh: return "fresh";
    case Kind::Reused: return "reused";
    case Kind::Expired: return "expired";
    case Kind::Malformed: return "malformed";
    case Kind::Dead: return "dead";
  }
  return "?";
}
const char* name(How how) {
  switch (how) {
    case How::Answer: return "answer";
    case How::Hold: return "hold";
    case How::Drop: return "drop";
  }
  return "?";
}
const char* name(Said said) {
  switch (said) {
    case Said::Nothing: return "nothing";
    case Said::NotALink: return "not a link";
    case Said::Unreachable: return "unreachable";
    case Said::Refused: return "refused";
    case Said::NotAPairingLink: return "not a pairing link";
    case Said::NotSaved: return "not saved";
    case Said::NotForgotten: return "not forgotten";
  }
  return "?";
}

struct Link {
  Kind kind = Kind::Fresh;
  int mc = 0;
  std::string token;
  int variant = 0;  // which malformed text
  bool operator==(const Link&) const = default;
};

std::ostream& operator<<(std::ostream& os, const Link& link) {
  os << name(link.kind) << "@" << kNames[link.mc];
  if (!link.token.empty()) os << "#" << link.token;
  if (link.kind == Kind::Malformed) os << "~" << link.variant;
  return os;
}

// An exchange the MC keeps waiting.
struct Held {
  int mc = 0;
  std::string token;
  int attempt = 0;
};

struct Model {
  // The paired MC and the session it sold, as the device keeps them.
  std::optional<int> paired;
  std::string session;
  bool pairing = false;
  bool adding = false;
  // Whether the device's storage takes writes.
  bool writable = true;
  std::optional<Link> link;
  std::optional<int> offered;
  Said said = Said::Nothing;
  // The exchange whose answer counts.
  int attempt = 0;
  std::vector<Held> held;
  // Each MC's tokens: given out and not spent, and spent.
  std::array<std::vector<std::string>, kMcs> unspent;
  std::array<std::vector<std::string>, kMcs> spent;
  std::array<int, kMcs> issued{};
  std::array<int, kMcs> sold{};
};

std::string sessionOf(int mc, int sold) {
  return "session-" + std::string(kNames[mc]) + "-" + std::to_string(sold);
}

bool contains(const std::vector<std::string>& list, const std::string& value) {
  return std::find(list.begin(), list.end(), value) != list.end();
}

// The MC spends `token` if it is one it gave out, as /oauth/token does.
bool spend(Model& m, int mc, const std::string& token) {
  auto& unspent = m.unspent[mc];
  const auto it = std::find(unspent.begin(), unspent.end(), token);
  if (it == unspent.end()) return false;
  unspent.erase(it);
  m.spent[mc].push_back(token);
  ++m.sold[mc];
  return true;
}

// An exchange's answer, when it is the one the phone waits for.
void answered(Model& m, int mc, bool paired) {
  m.pairing = false;
  if (!paired) return;
  // The session is on the device first, or the phone is not paired with it.
  if (!m.writable) {
    m.said = Said::NotSaved;
    return;
  }
  m.paired = mc;
  m.session = sessionOf(mc, m.sold[mc]);
  m.adding = false;
  m.link.reset();
  m.offered.reset();
  m.said = Said::Nothing;
}

// An MC a phone pairs with whose answers to `/oauth/token` the test scripts.
class Mc {
public:
  Mc(int index) : pairable(QString::fromLatin1(kNames[index]), QString::fromLatin1(kLabels[index])), m_index(index) {
    pairable.mc.onRaw(QStringLiteral("/oauth/token"), [this](QTcpSocket* socket, const QByteArray& head) {
      static const QRegularExpression contentLength(QStringLiteral("content-length: *(\\d+)"), QRegularExpression::CaseInsensitiveOption);
      const qsizetype length = contentLength.match(QString::fromUtf8(head)).captured(1).toLongLong();
      auto done = std::make_shared<bool>(false);
      const auto take = [this, socket, head, length, done] {
        const QByteArray request = socket->peek(socket->bytesAvailable());
        if (*done || request.size() < head.size() + length) return;
        *done = true;
        const QString token = QUrlQuery(QString::fromUtf8(request.mid(head.size(), length))).queryItemValue(QStringLiteral("subject_token"), QUrl::FullyDecoded);
        ++received;
        switch (how) {
          case How::Answer: return answer(socket, token);
          case How::Hold: held.append({socket, token}); return;
          case How::Drop: socket->abort(); return;
        }
      };
      QObject::connect(socket, &QTcpSocket::readyRead, socket, take);
      take();
    });
  }

  QString origin() const { return pairable.mc.origin().toString(); }
  void answer(QTcpSocket* socket, const QString& token) {
    if (!socket) return;
    if (!pairable.pairingTokens.removeOne(token)) {
      return pairable::answer(socket, 400, pairable::json({{QStringLiteral("error"), QStringLiteral("invalid_grant")}}));
    }
    pairable.sessions.append(QString::fromStdString(sessionOf(m_index, ++sold)));
    pairable::answer(socket, 200, pairable::json({{QStringLiteral("access_token"), pairable.sessions.last()}, {QStringLiteral("token_type"), QStringLiteral("Bearer")}}));
  }

  struct Waiting {
    QPointer<QTcpSocket> socket;
    QString token;
  };
  PairableMc pairable;
  How how = How::Answer;
  QList<Waiting> held;
  int received = 0;
  int sold = 0;

private:
  int m_index;
};

const pairing::Client kPhone{QStringLiteral("HAL-C2 on Test Phone"), QStringLiteral("mobile"), QStringLiteral("Android")};

// The phone as its main.cpp builds it over `home`: the shell, and its pairing, started.
class Phone {
public:
  explicit Phone(const QString& home) : bridge(std::make_unique<ShellBridge>()), shell(std::make_unique<NativeShell>(bridge.get())) {
    const QDir dir(home);
    dir.mkpath(QStringLiteral("config"));
    shell->client()->setRetryDelays({20});
    shell->setStoreDirs(dir.filePath(QStringLiteral("state")), dir.filePath(QStringLiteral("data")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(QStringLiteral("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(QStringLiteral("config")));
    file = dir.filePath(QStringLiteral("data/pairing.json"));
    pairing = std::make_unique<Pairing>(bridge.get(), shell.get(), dir.filePath(QStringLiteral("data")), kPhone);
    pairing->start();
  }
  ~Phone() { pairing.reset(); }

  QVariantMap state() const { return bridge->state()->value(QStringLiteral("pairing")).toMap(); }
  QString phase() const { return state().value(QStringLiteral("phase")).toString(); }
  QNetworkAccessManager* http() const { return pairing->findChild<QNetworkAccessManager*>(); }
  QJsonObject kept() const {
    QFile saved(file);
    return saved.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(saved.readAll()).object() : QJsonObject();
  }

  // Declared in teardown order: the shell goes before the bridge it intercepts.
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  QString file;
  std::unique_ptr<Pairing> pairing;
};

struct Sut {
  Sut() : home(QDir::homePath() + QStringLiteral("/phone-XXXXXX")) {
    for (int i = 0; i < kMcs; ++i) mcs.push_back(std::make_unique<Mc>(i));
    // Once the MCs listen, so that none of them comes to answer there.
    dead = pairable::deadAddress();
    phone = std::make_unique<Phone>(home.path());
  }
  ~Sut() {
    writable(true);
    phone.reset();
    halc2::prop::settle();
  }

  QString text(const Link& link) const {
    const QString token = QString::fromStdString(link.token);
    switch (link.kind) {
      case Kind::Fresh:
      case Kind::Reused:
      case Kind::Expired:
        return mcs[link.mc]->origin() + QStringLiteral("/?token=") + token;
      case Kind::Dead:
        return QStringLiteral("http://") + dead + QStringLiteral("/?token=") + token;
      case Kind::Malformed:
        switch (link.variant) {
          case 0: return QStringLiteral("pair me please");
          case 1: return mcs[link.mc]->origin() + QStringLiteral("/");
          default: return QStringLiteral("ftp://127.0.0.1/?token=") + token;
        }
    }
    return {};
  }

  QString error(Said said) const {
    switch (said) {
      case Said::Nothing: return {};
      case Said::NotALink: return QStringLiteral("That is not a pairing link.");
      case Said::Unreachable: return QStringLiteral("could not be reached");
      case Said::Refused: return QStringLiteral("Pairing failed: the link was already used or has expired.");
      case Said::NotAPairingLink: return QStringLiteral("The link that opened HAL-C2 is not a pairing link.");
      case Said::NotSaved: return QStringLiteral("its session could not be saved on this device");
      case Said::NotForgotten: return QStringLiteral("could not be forgotten");
    }
    return {};
  }

  void writable(bool writable) const {
    const QString data = QDir(home.path()).filePath(QStringLiteral("data"));
    QDir().mkpath(data);
    QFile::setPermissions(data, writable ? QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner : QFile::ReadOwner | QFile::ExeOwner);
  }

  // What the phone shows and keeps agrees with the model.
  void check(const Model& m) const {
    const QVariantMap state = phone->state();
    const QString phase = m.pairing ? QStringLiteral("pairing") : m.paired ? QStringLiteral("paired") : QStringLiteral("unpaired");
    RC_ASSERT(state.value(QStringLiteral("phase")).toString() == phase);
    const QString error = state.value(QStringLiteral("error")).toString();
    if (m.said == Said::Nothing) {
      RC_ASSERT(error.isEmpty());
    } else {
      RC_ASSERT(error.contains(this->error(m.said)));
    }
    RC_ASSERT(state.value(QStringLiteral("link")).toString() == (m.link ? text(*m.link) : QString()));
    RC_ASSERT(state.value(QStringLiteral("offered")).toString() == (m.offered ? mcs[*m.offered]->origin() : QString()));
    RC_ASSERT(state.value(QStringLiteral("adding")).toBool() == m.adding);
    RC_ASSERT(state.value(QStringLiteral("origin")).toString() == (m.paired ? mcs[*m.paired]->origin() : QString()));
    RC_ASSERT(state.value(QStringLiteral("label")).toString() == (m.paired ? QString::fromLatin1(kLabels[*m.paired]) : QString()));
    if (m.paired) {
      const QJsonObject kept{{QStringLiteral("origin"), mcs[*m.paired]->origin()},
                             {QStringLiteral("token"), QString::fromStdString(m.session)},
                             {QStringLiteral("label"), QString::fromLatin1(kLabels[*m.paired])},
                             {QStringLiteral("environmentId"), QStringLiteral("env-") + QString::fromLatin1(kNames[*m.paired])}};
      RC_ASSERT(phone->kept() == kept);
      RC_ASSERT(phone->shell->client()->phase() != McClient::Phase::Closed);
    } else {
      RC_ASSERT(!QFile::exists(phone->file));
      RC_ASSERT(phone->shell->client()->phase() == McClient::Phase::Closed);
    }
    for (int i = 0; i < kMcs; ++i) RC_ASSERT(mcs[i]->sold == m.sold[i]);
  }

  QTemporaryDir home;
  QString dead;
  std::vector<std::unique_ptr<Mc>> mcs;
  std::unique_ptr<Phone> phone;
};

using Command = rc::state::Command<Model, Sut>;

// The user enters a link, or the one in the field again, and pairs.
struct Pair : Command {
  Kind kind = *rc::gen::element(Kind::Fresh, Kind::Fresh, Kind::Reused, Kind::Expired, Kind::Malformed, Kind::Dead);
  int mc = *rc::gen::inRange(0, kMcs);
  How how = *rc::gen::element(How::Answer, How::Answer, How::Hold, How::Drop);
  int variant = *rc::gen::inRange(0, 3);
  bool again = *rc::gen::element(false, false, true);

  explicit Pair(const Model& m) {
    if (!m.link) again = false;
  }

  Link link(const Model& m) const {
    if (again) return *m.link;
    switch (kind) {
      case Kind::Fresh: return {kind, mc, "tok-" + std::string(kNames[mc]) + "-" + std::to_string(m.issued[mc]), 0};
      // Written as a fresh one is: the text is all that tells links apart.
      case Kind::Reused: return {Kind::Fresh, mc, m.spent[mc].back(), 0};
      case Kind::Expired: return {Kind::Fresh, mc, "expired", 0};
      case Kind::Dead: return {kind, mc, "dead", 0};
      case Kind::Malformed: return {kind, mc, "", variant};
    }
    return {};
  }

  void checkPreconditions(const Model& m) const override {
    if (again) {
      RC_PRE(m.link.has_value());
    } else if (kind == Kind::Reused) {
      RC_PRE(!m.spent[mc].empty());
    }
  }

  void apply(Model& m) const override {
    const Link entered = link(m);
    if (!again && kind == Kind::Fresh) {
      m.unspent[mc].push_back(entered.token);
      ++m.issued[mc];
    }
    // A second pairing while one is in flight is not started.
    if (m.pairing) return;
    if (m.link != entered) m.offered.reset();
    m.link = entered;
    if (entered.kind == Kind::Malformed) {
      m.said = Said::NotALink;
      return;
    }
    m.said = Said::Nothing;
    ++m.attempt;
    if (entered.kind == Kind::Dead || how == How::Drop) {
      m.said = Said::Unreachable;
      return;
    }
    if (how == How::Hold) {
      m.pairing = true;
      m.held.push_back({entered.mc, entered.token, m.attempt});
      return;
    }
    const bool paid = spend(m, entered.mc, entered.token);
    if (!paid) m.said = Said::Refused;
    answered(m, entered.mc, paid);
  }

  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    const Link entered = link(m);
    if (!again && kind == Kind::Fresh) s.mcs[mc]->pairable.pairingTokens.append(QString::fromStdString(entered.token));
    Mc& at = *s.mcs[entered.mc];
    at.how = how;
    const qsizetype held = at.held.size();
    s.phone->bridge->dispatch(QStringLiteral("pairing.pair"), QVariantMap{{QStringLiteral("link"), s.text(entered)}});
    if (!m.pairing && entered.kind != Kind::Malformed) {
      if (next.pairing) {
        RC_ASSERT(halc2::prop::until([&] { return at.held.size() > held; }));
      } else {
        RC_ASSERT(halc2::prop::until([&] { return s.phone->phase() != QLatin1String("pairing"); }));
      }
    }
    at.how = How::Answer;
    s.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Pair(";
    if (again) {
      os << "again";
    } else {
      os << name(kind) << "@" << kNames[mc];
      if (kind == Kind::Malformed) os << "~" << variant;
    }
    os << ", " << name(how) << ")";
  }
};

// The MC answers an exchange it kept waiting, or drops it.
struct Release : Command {
  int index;
  bool drop = *rc::gen::element(false, false, true);

  explicit Release(const Model& m) : index(m.held.empty() ? 0 : *rc::gen::inRange<int>(0, static_cast<int>(m.held.size()))) {}

  void checkPreconditions(const Model& m) const override { RC_PRE(index < static_cast<int>(m.held.size())); }

  void apply(Model& m) const override {
    const Held held = m.held[index];
    m.held.erase(m.held.begin() + index);
    const bool paid = !drop && spend(m, held.mc, held.token);
    // An answer to an exchange the phone gave up on is nobody's.
    if (held.attempt != m.attempt || !m.pairing) return;
    if (drop) {
      m.said = Said::Unreachable;
    } else if (!paid) {
      m.said = Said::Refused;
    }
    answered(m, held.mc, paid);
  }

  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    // The held exchanges are in the same order at the MCs as in the model.
    const Held held = m.held[index];
    int nth = 0;
    for (int i = 0; i < index; ++i) nth += m.held[i].mc == held.mc ? 1 : 0;
    Mc& at = *s.mcs[held.mc];
    const Mc::Waiting waiting = at.held.takeAt(nth);
    RC_ASSERT(waiting.token == QString::fromStdString(held.token));
    QSignalSpy finished(s.phone->http(), &QNetworkAccessManager::finished);
    if (drop) {
      if (waiting.socket) waiting.socket->abort();
    } else {
      at.answer(waiting.socket, waiting.token);
    }
    RC_ASSERT(finished.wait(halc2::test::wait()));
    halc2::prop::settle();
    s.check(next);
  }

  void show(std::ostream& os) const override { os << "Release(" << index << (drop ? ", drop" : "") << ")"; }
};

// A link from outside the app: a QR code's, or another app's.
struct Offer : Command {
  int mc = *rc::gen::inRange(0, kMcs);
  // 0: a pairing link, 1: the app's own link to one, 2: not a pairing link
  int form = *rc::gen::inRange(0, 3);

  explicit Offer(const Model&) {}

  void apply(Model& m) const override {
    const Link offered{Kind::Fresh, mc, "tok-" + std::string(kNames[mc]) + "-" + std::to_string(m.issued[mc]), 0};
    if (form != 2) {
      m.unspent[mc].push_back(offered.token);
      ++m.issued[mc];
    }
    if (m.pairing) return;
    if (form == 2) {
      // Said in a toast when there is no pairing screen to say it on.
      if (!m.paired || m.adding) m.said = Said::NotAPairingLink;
      return;
    }
    m.link = offered;
    m.offered = mc;
    m.adding = m.paired.has_value();
    m.said = Said::Nothing;
  }

  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    QString text = QStringLiteral("https://example.com/menu");
    if (form != 2) {
      const QString token = QStringLiteral("tok-%1-%2").arg(QString::fromLatin1(kNames[mc])).arg(m.issued[mc]);
      s.mcs[mc]->pairable.pairingTokens.append(token);
      text = s.mcs[mc]->origin() + QStringLiteral("/?token=") + token;
      if (form == 1) text = QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(text));
    }
    s.phone->pairing->openLink(QUrl(text));
    halc2::prop::settle();
    s.check(next);
  }

  void show(std::ostream& os) const override { os << "Offer(" << kNames[mc] << ", " << (form == 0 ? "link" : form == 1 ? "app link" : "not a pairing link") << ")"; }
};

struct Add : Command {
  explicit Add(const Model&) {}
  void apply(Model& m) const override {
    if (!m.paired || m.pairing || m.adding) return;
    m.adding = true;
    m.link.reset();
    m.offered.reset();
    m.said = Said::Nothing;
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.phone->bridge->dispatch(QStringLiteral("pairing.add"));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Add"; }
};

struct Cancel : Command {
  explicit Cancel(const Model&) {}
  void apply(Model& m) const override {
    if (!m.adding || m.pairing) return;
    m.adding = false;
    m.link.reset();
    m.offered.reset();
    m.said = Said::Nothing;
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.phone->bridge->dispatch(QStringLiteral("pairing.cancel"));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Cancel"; }
};

struct Forget : Command {
  explicit Forget(const Model&) {}
  void apply(Model& m) const override {
    // The session stays on the device, and so the device stays paired, and
    // a pairing in flight goes on.
    if (m.paired && !m.writable) {
      m.said = Said::NotForgotten;
      return;
    }
    ++m.attempt;
    m.pairing = false;
    m.paired.reset();
    m.session.clear();
    m.adding = false;
    m.link.reset();
    m.offered.reset();
    m.said = Said::Nothing;
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.phone->bridge->dispatch(QStringLiteral("pairing.forget"));
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Forget"; }
};

// The device's storage stops taking writes, or takes them again.
struct Disk : Command {
  bool writable = *rc::gen::arbitrary<bool>();
  explicit Disk(const Model&) {}
  void apply(Model& m) const override { m.writable = writable; }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.writable(writable);
    s.check(next);
  }
  void show(std::ostream& os) const override { os << (writable ? "Disk(writable)" : "Disk(read-only)"); }
};

// The app is closed and started again over what the device kept. What the
// MCs held for the phone that went is let go of.
struct Restart : Command {
  explicit Restart(const Model&) {}
  void apply(Model& m) const override {
    ++m.attempt;
    m.pairing = false;
    m.held.clear();
    m.adding = false;
    m.link.reset();
    m.offered.reset();
    m.said = Said::Nothing;
  }
  void run(const Model& m, Sut& s) const override {
    Model next = m;
    apply(next);
    s.phone.reset();
    for (const auto& mc : s.mcs) {
      for (const Mc::Waiting& waiting : mc->held) {
        if (waiting.socket) waiting.socket->abort();
      }
      mc->held.clear();
    }
    halc2::prop::settle();
    s.phone = std::make_unique<Phone>(s.home.path());
    s.check(next);
  }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class PairingProp : public QObject {
  Q_OBJECT

private slots:
  void pairing() {
    QVERIFY(rc::check("the phone's pairing agrees with the model", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Pair, Pair, Pair, Release, Release, Offer, Add, Cancel, Forget, Disk, Restart>());
    }));
  }
};

HAL_C2_PROP_MAIN(PairingProp)
#include "tst_PairingProp.moc"
