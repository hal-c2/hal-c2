// The hover cards and clicks of pull request links (PullRequestLinkPreviews)
// against an MC whose replies to pullRequests.preview arrive in any order, or
// after the thread moved to another environment. Whatever the order: a link
// has at most one read in flight, a reply from a previous environment changes
// nothing, a click opens the review only once its pull request was read, the
// address in the browser when it could not be, and only the latest click acts.

#include "Prop.h"

#include "PullRequestLinkPreviews.h"

namespace {

const QString kPull = QStringLiteral("https://github.com/acme/shop/pull/42");
const QString kIssue = QStringLiteral("https://github.com/acme/shop/issues/7");
const QString kCommit = QStringLiteral("https://github.com/acme/shop/commit/0a1b2c3");
const QString kLookalike = QStringLiteral("https://github.com.evil.test/acme/shop/pull/42");
const QStringList kEnvironments{QString(), QStringLiteral("env-a"), QStringLiteral("env-b")};

const QList<QJsonObject> kProjects{
    {{QStringLiteral("id"), QStringLiteral("shop")},
     {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}}}}};

enum class Read { Pending, Ready, Failed };

struct Model {
  struct Request {
    quint64 epoch;
    QString url;
  };
  QString environment = kEnvironments.at(1);
  quint64 epoch = 0;
  QList<Request> inFlight;
  QHash<QString, Read> reads;
  QString address;
  QString following;
  QStringList opened;

  bool claims(const QString& url) const { return !environment.isEmpty() && (url == kPull || url == kIssue); }
  static QString keyOf(const QString& url) {
    return url == kPull ? QStringLiteral("github.com/acme/shop#42") : QStringLiteral("github.com/acme/shop#7");
  }
  void read(const QString& url) {
    if (reads.contains(url) && reads.value(url) != Read::Failed) return;
    reads.insert(url, Read::Pending);
    inFlight.append({epoch, url});
  }
  void settle(const QString& url) {
    following.clear();
    opened.append(reads.value(url) == Read::Ready ? QStringLiteral("review ") + keyOf(url) : QStringLiteral("browser ") + url);
  }
  QString status() const {
    if (address.isEmpty() || !reads.contains(address)) return {};
    switch (reads.value(address)) {
      case Read::Pending: return QStringLiteral("loading");
      case Read::Ready: return QStringLiteral("ready");
      case Read::Failed: return QStringLiteral("failed");
    }
    return {};
  }
};

struct Sut {
  struct Request {
    QString environment;
    QString url;
    PullRequestLinkPreviews::Reply reply;
  };
  QList<Request> inFlight;
  QStringList opened;
  PullRequestLinkPreviews previews{
      [this](const QString& environment, const QJsonObject& ref, PullRequestLinkPreviews::Reply reply) {
        const QString url = ref.value(QLatin1String("number")).toInt() == 42 ? kPull : kIssue;
        inFlight.append({environment, url, std::move(reply)});
      },
      [this](const QString& key) { opened.append(QStringLiteral("review ") + key); },
      [this](const QString& url) { opened.append(QStringLiteral("browser ") + url); },
      [this](const QString& url) { opened.append(QStringLiteral("ordinary ") + url); }};

  Sut() { previews.setContext(kEnvironments.at(1), kProjects); }
};

using Command = rc::state::Command<Model, Sut>;

void check(const Model& model, const Sut& sut) {
  RC_ASSERT(sut.opened == model.opened);
  RC_ASSERT(sut.inFlight.size() == model.inFlight.size());
  RC_ASSERT(sut.previews.address() == model.address);
  RC_ASSERT(sut.previews.status() == model.status());
  RC_ASSERT((sut.previews.status() == QLatin1String("ready")) == !sut.previews.card().isEmpty());
  // At most one read of a link in flight in the current environment.
  QSet<QString> current;
  for (const Model::Request& request : model.inFlight) {
    if (request.epoch != model.epoch) continue;
    RC_ASSERT(!current.contains(request.url));
    current.insert(request.url);
  }
}

struct Hover : Command {
  QString url = *rc::gen::element(QString(), kPull, kIssue, kCommit, kLookalike);
  void apply(Model& model) const override {
    if (model.claims(url)) model.read(url);
    model.address = model.claims(url) ? url : QString();
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.previews.hover(url);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Hover " << url.toStdString(); }
};

struct Follow : Command {
  QString url = *rc::gen::element(kPull, kIssue, kCommit, kLookalike);
  bool external = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.following.clear();
    if (external) {
      model.opened.append(QStringLiteral("browser ") + url);
    } else if (!model.claims(url)) {
      model.opened.append(QStringLiteral("ordinary ") + url);
    } else {
      model.read(url);
      model.following = url;
      if (model.reads.value(url) != Read::Pending) model.settle(url);
    }
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.previews.follow(url, external);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Follow " << url.toStdString() << (external ? " external" : ""); }
};

struct Reply : Command {
  int index = *rc::gen::inRange(0, 4);
  bool ok = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(index < model.inFlight.size()); }
  void apply(Model& model) const override {
    const Model::Request request = model.inFlight.takeAt(index);
    if (request.epoch != model.epoch) return;
    model.reads.insert(request.url, ok ? Read::Ready : Read::Failed);
    if (model.following == request.url) model.settle(request.url);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    const Sut::Request request = sut.inFlight.takeAt(index);
    std::optional<QJsonObject> preview;
    if (ok) {
      preview = QJsonObject{{QStringLiteral("repository"), QStringLiteral("acme/shop")},
                            {QStringLiteral("number"), request.url == kPull ? 42 : 7},
                            {QStringLiteral("title"), QStringLiteral("Tax line fix")},
                            {QStringLiteral("state"), QStringLiteral("open")},
                            {QStringLiteral("author"), QJsonObject{{QStringLiteral("login"), QStringLiteral("ada")}}},
                            {QStringLiteral("createdAt"), QStringLiteral("2026-11-01T10:00:00Z")}};
    }
    request.reply(preview);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Reply " << index << (ok ? " ok" : " failed"); }
};

struct Move : Command {
  QString environment = *rc::gen::element(kEnvironments.at(0), kEnvironments.at(1), kEnvironments.at(2));
  void apply(Model& model) const override {
    if (environment == model.environment) return;
    model.environment = environment;
    ++model.epoch;
    model.reads.clear();
    model.address.clear();
    model.following.clear();
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.previews.setContext(environment, environment.isEmpty() ? QList<QJsonObject>() : kProjects);
    check(next, sut);
  }
  void show(std::ostream& os) const override { os << "Move to " << (environment.isEmpty() ? "nowhere" : environment.toStdString()); }
};

}  // namespace

class PullRequestLinkPreviewsProp : public QObject {
  Q_OBJECT

private slots:
  void links() {
    QVERIFY(rc::check("a link is read once at a time and only the latest click acts on what was read", [] {
      Sut sut;
      rc::state::check(Model{}, sut, rc::state::gen::execOneOfWithArgs<Hover, Follow, Follow, Reply, Reply, Move>());
    }));
  }
};

HAL_C2_PROP_MAIN(PullRequestLinkPreviewsProp)
#include "tst_PullRequestLinkPreviewsProp.moc"
