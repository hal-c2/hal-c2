// Project favicons (IdentityController) against a fake MC that signs each
// favicon URL for half an hour or more, or refuses to while it is told to.
// Time passes in jumps; the renewal timer runs at each deadline the model
// says it has. Whatever the order, a favicon URL the shell shows has not run
// out while the MC signs, and the MC is asked once per renewal, no more:
// the MC answers a URL that ran out with Forbidden.

#include "Prop.h"

#include <QDateTime>

#include <memory>

#include "FakeMc.h"
#include "IdentityController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

// IdentityController's: asked again a minute early, again after 30s when refused.
const qint64 kMarginMs = 60'000;
const qint64 kRetryMs = 30'000;
const qint64 kMinuteMs = 60'000;
const QStringList kProjects{QStringLiteral("p1"), QStringLiteral("p2")};

QString rootOf(const QString& project) { return QStringLiteral("/work/") + project; }

struct Favicon {
  qint64 expiresAt = 0;  // when the controller asks again, plus the margin
  int asks = 1;          // the first ask comes as the shell starts
  bool served = true;    // the last ask was signed
};

struct Model {
  qint64 now = 0;
  qint64 ttl = 30 * kMinuteMs;
  bool refusing = false;
  QMap<QString, Favicon> favicons;

  std::optional<qint64> nextDue() const {
    std::optional<qint64> due;
    for (const Favicon& favicon : favicons) due = qMin(due.value_or(favicon.expiresAt - kMarginMs), favicon.expiresAt - kMarginMs);
    return due;
  }

  // The renewal timer at `now`: every favicon due is asked for again.
  void renew() {
    for (Favicon& favicon : favicons) {
      if (favicon.expiresAt - kMarginMs > now) continue;
      ++favicon.asks;
      favicon.served = !refusing;
      favicon.expiresAt = refusing ? now + kMarginMs + kRetryMs : now + ttl;
    }
  }
};

struct Sut {
  QTemporaryDir home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  qint64 now = 0;
  qint64 ttl = 30 * kMinuteMs;
  bool refusing = false;
  int signedCount = 0;
  QMap<QString, int> asks;          // by project
  QMap<QString, QString> latest;    // the URL last signed, by project
  QMap<QString, qint64> expiries;   // by URL

  Sut() {
    for (const QString& project : kProjects) {
      mc.projects.insert(project, QJsonObject{{QStringLiteral("id"), project},
                                              {QStringLiteral("title"), project},
                                              {QStringLiteral("workspaceRoot"), rootOf(project)},
                                              {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                              {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                              {QStringLiteral("scripts"), QJsonArray()}});
    }
    mc.onRpc(QStringLiteral("assets.createUrl"), [this](const FakeMc::Rpc& rpc) {
      const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
      if (resource.value(QLatin1String("_tag")) != QLatin1String("project-favicon")) return mc.refuse(rpc, QStringLiteral("Not here."));
      const QString project = resource.value(QLatin1String("cwd")).toString().section(QLatin1Char('/'), -1);
      ++asks[project];
      if (refusing) return mc.refuse(rpc, QStringLiteral("The MC is busy."));
      const QString relative = QStringLiteral("/api/assets/token-%1/v1-favicon.svg").arg(++signedCount);
      latest[project] = mc.origin().resolved(QUrl(relative)).toString();
      expiries[latest[project]] = now + ttl;
      mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), relative}, {QStringLiteral("expiresAt"), double(now + ttl)}});
    });
    mc.onRpc(QStringLiteral("test.barrier"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });
  }

  IdentityController* identity() const { return native->controller<IdentityController>(); }

  // A fresh shell whose favicons were all signed for `ttl` as it started.
  void reset(qint64 start, qint64 firstTtl) {
    native.reset();
    bridge.reset();
    QDir(home.path()).removeRecursively();
    now = start;
    ttl = firstTtl;
    refusing = false;
    signedCount = 0;
    asks.clear();
    latest.clear();
    expiries.clear();
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    identity()->setClock([this] { return now; });
    if (!prop::until([this] { return native->isActive() && native->store()->synchronized(); })) qFatal("the shell did not start");
    RC_ASSERT(prop::until([this] { return shownAll(); }));
  }

  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

  QString shown(const QString& project) const {
    return bridge->state()->value(QStringLiteral("projectIcons")).toMap().value(mc.environmentId + QLatin1Char(':') + project).toMap().value(QStringLiteral("url")).toString();
  }

  bool shownAll() const {
    for (const QString& project : kProjects) {
      if (shown(project).isEmpty() || shown(project) != latest.value(project)) return false;
    }
    return true;
  }

  // The renewal timer runs: what it asks is answered before the next step.
  void renew() {
    identity()->renewFavicons();
    // Twice: an answer the first brings is published before the second.
    barrier();
    barrier();
  }
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& model, Sut& sut) {
  for (const QString& project : kProjects) {
    const Favicon& favicon = model.favicons[project];
    RC_ASSERT(sut.asks.value(project) == favicon.asks);
    const QString url = sut.shown(project);
    // A refused renewal keeps the last URL showing until the MC signs again.
    RC_ASSERT(url == sut.latest.value(project));
    if (favicon.served) RC_ASSERT(sut.expiries.value(url) > sut.now);
  }
}

struct Advance : Command {
  qint64 ms = *rc::gen::inRange<qint64>(1, 3 * 60) * kMinuteMs;
  void apply(Model& model) const override {
    const qint64 until = model.now + ms;
    while (const auto due = model.nextDue()) {
      if (*due > until) break;
      model.now = qMax(model.now, *due);
      model.renew();
    }
    model.now = until;
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    const qint64 until = next.now + ms;
    while (const auto due = next.nextDue()) {
      if (*due > until) break;
      next.now = qMax(next.now, *due);
      next.renew();
      sut.now = next.now;
      sut.renew();
      check(next, sut);
    }
    // Nothing is due between deadlines: running early asks for nothing.
    next.now = until;
    sut.now = until;
    sut.renew();
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Advance " << ms / kMinuteMs << "min"; }
};

struct SignFor : Command {
  qint64 ttl = *rc::gen::inRange<qint64>(30, 61) * kMinuteMs;
  void apply(Model& model) const override { model.ttl = ttl; }
  void run(const Model&, Sut& sut) const override { sut.ttl = ttl; }
  void show(std::ostream& os) const override { os << "SignFor " << ttl / kMinuteMs << "min"; }
};

struct Refuse : Command {
  bool refusing = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refusing = refusing; }
  void run(const Model&, Sut& sut) const override { sut.refusing = refusing; }
  void show(std::ostream& os) const override { os << (refusing ? "Refuse" : "Sign"); }
};

}  // namespace

class ProjectFaviconProp : public QObject {
  Q_OBJECT

private slots:
  void renewal() {
    Sut sut;
    QVERIFY(rc::check("a shown favicon URL never runs out while the MC signs, and each renewal asks once", [&sut] {
      const qint64 start = QDateTime::currentMSecsSinceEpoch();
      const qint64 ttl = *rc::gen::inRange<qint64>(30, 61) * kMinuteMs;
      sut.reset(start, ttl);
      Model model;
      model.now = start;
      model.ttl = ttl;
      for (const QString& project : kProjects) model.favicons.insert(project, {start + ttl});
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Advance, Advance, SignFor, Refuse>());
    }));
  }
};

HAL_C2_PROP_MAIN(ProjectFaviconProp)
#include "tst_ProjectFaviconProp.moc"
