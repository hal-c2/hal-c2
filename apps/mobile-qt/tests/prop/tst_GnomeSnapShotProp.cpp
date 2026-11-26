// Snap Shot on GNOME (GnomeSnapShot) on a fake GNOME Shell and a scratch
// XDG_DATA_HOME. GNOME answers late and out of order, and the user asks for
// setup steps and captures meanwhile. Only the newest answer counts; setup
// reports checking exactly while it waits on something the user asked for;
// the extension's files change only by an install the user chose in a status
// that allows it, and whatever was replaced is kept; one capture at a time.

#include "Prop.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <algorithm>
#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <vector>

#include "GnomeSnapShot.h"

namespace {

constexpr double kBundled = 2;

QByteArray metadataJson(double version) {
  return QJsonDocument(QJsonObject{{QStringLiteral("uuid"), GnomeSnapShot::kUuid},
                                   {QStringLiteral("version"), version},
                                   {QStringLiteral("shell-version"), QJsonArray{QStringLiteral("47")}}})
      .toJson();
}

GnomeSnapShot::Metadata bundledMetadata() {
  return {GnomeSnapShot::kUuid, kBundled, {QStringLiteral("47")}};
}

class FakePortal : public SnapShotBackend {
public:
  using SnapShotBackend::SnapShotBackend;
  Session session() const override {
    Session session;
    session.ready = true;
    session.mode = QStringLiteral("portal");
    session.backend = QStringLiteral("picker");
    session.desktop = QStringLiteral("gnome");
    return session;
  }
  void capture() override { ++captures; }
  int captures = 0;
};

class FakeShell : public GnomeShell {
public:
  void inspect(std::function<void(const Extension&)> done) override { inspects.push_back(std::move(done)); }
  void setEnabled(bool on, std::function<void(const QString& error)> done) override {
    Q_UNUSED(on);
    enables.push_back(std::move(done));
  }
  void capture(const QString& busName, bool flash, std::function<void(const Capture&)> done) override {
    Q_UNUSED(busName);
    flashes.push_back(flash);
    captures.push_back(std::move(done));
  }
  std::deque<std::function<void(const Extension&)>> inspects;
  std::deque<std::function<void(const QString&)>> enables;
  std::deque<std::function<void(const Capture&)>> captures;
  std::vector<bool> flashes;
};

struct Sut {
  std::unique_ptr<QTemporaryDir> home;
  std::unique_ptr<QTemporaryDir> bundle;
  std::unique_ptr<GnomeSnapShot> gnome;
  FakePortal* portal = nullptr;
  FakeShell* shell = nullptr;
  int captured = 0;
  int failed = 0;
  int setupFailed = 0;
  QByteArray png;

  void reset() {
    gnome.reset();
    captured = failed = setupFailed = 0;
    home = std::make_unique<QTemporaryDir>();
    bundle = std::make_unique<QTemporaryDir>();
    write(bundle->filePath(QStringLiteral("metadata.json")), metadataJson(kBundled));
    write(bundle->filePath(QStringLiteral("extension.js")), "// extension");
    write(bundle->filePath(QStringLiteral("bundle.json")),
          QJsonDocument(QJsonObject{{QStringLiteral("files"), QJsonArray{QStringLiteral("metadata.json"), QStringLiteral("extension.js")}}}).toJson());
    portal = new FakePortal;
    shell = new FakeShell;
    gnome = std::make_unique<GnomeSnapShot>(portal, shell, GnomeSnapShot::Paths{bundle->path(), home->path(), {}}, nullptr);
    QObject::connect(gnome.get(), &SnapShotBackend::captured, gnome.get(), [this] { ++captured; });
    QObject::connect(gnome.get(), &SnapShotBackend::failed, gnome.get(), [this] { ++failed; });
    QObject::connect(gnome.get(), &SnapShotBackend::setupFailed, gnome.get(), [this] { ++setupFailed; });
    if (png.isEmpty()) {
      QImage image(4, 4, QImage::Format_RGB32);
      image.fill(Qt::red);
      QBuffer buffer(&png);
      buffer.open(QIODevice::WriteOnly);
      image.save(&buffer, "PNG");
    }
    gnome->probe();
  }

  QString target() const { return home->path() + QStringLiteral("/gnome-shell/extensions/") + GnomeSnapShot::kUuid; }

  static void write(const QString& path, const QByteArray& content) {
    QFile file(path);
    RC_ASSERT(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(content);
  }

  void setInstalled(double version) {
    if (QFile::exists(target())) QDir(target()).removeRecursively();
    QDir().mkpath(target());
    write(target() + QStringLiteral("/metadata.json"), metadataJson(version));
  }

  double installed() const {
    const auto found = GnomeSnapShot::metadata(target());
    return found ? found->version : 0;
  }

  int backups() const {
    return QDir(home->path() + QStringLiteral("/hal-c2/extension-backups")).entryList({QStringLiteral("capture-*")}, QDir::Dirs).size();
  }
};

struct Model {
  // What GNOME has yet to answer, by the order they were asked; each one's id.
  std::vector<int> inspects{0};
  int newest = 0;
  std::optional<GnomeShell::Extension> extension;
  std::optional<GnomeSnapShot::Status> status;
  // A step the user chose, waiting for the newest answer or for GNOME.
  QString action;
  bool enabling = false;
  bool working = false;
  double installed = 0;
  int backups = 0;
  int setupFailed = 0;
  bool capturing = false;
  int captured = 0;
  int failed = 0;
  int portalCaptures = 0;
  bool flash = false;

  bool answering() const { return extension && (extension->service == 1 || extension->service == 2); }

  void inspect() {
    inspects.push_back(++newest);
  }

  void settled(bool failure) {
    working = false;
    enabling = false;
    action.clear();
    if (failure) ++setupFailed;
    inspect();
  }

  void answered(size_t index, const GnomeShell::Extension& answer) {
    const int id = inspects[index];
    inspects.erase(inspects.begin() + index);
    if (id != newest) return;
    extension = answer;
    status = GnomeSnapShot::status(answer, bundledMetadata(), installed ? std::optional(GnomeSnapShot::Metadata{GnomeSnapShot::kUuid, installed, {QStringLiteral("47")}}) : std::nullopt);
    if (action.isEmpty() || enabling) return;
    if (action == QLatin1String("install-extension")) {
      if (installed > kBundled) return settled(true);
      if (status->status != QLatin1String("not-installed") && status->status != QLatin1String("update-required")) return settled(true);
      if (installed) ++backups;
      installed = kBundled;
      return settled(false);
    }
    if (action == QLatin1String("enable-extension") && status->status != QLatin1String("disabled")) return settled(true);
    enabling = true;
  }
};

void verify(const Model& model, const Sut& sut) {
  const SnapShotBackend::Session session = sut.gnome->session();
  RC_ASSERT(sut.shell->inspects.size() == model.inspects.size());
  RC_ASSERT(session.ready == model.status.has_value());
  RC_ASSERT(session.checking == (model.working || (model.status.has_value() && std::find(model.inspects.begin(), model.inspects.end(), model.newest) != model.inspects.end())));
  RC_ASSERT(sut.installed() == model.installed);
  RC_ASSERT(sut.backups() == model.backups);
  RC_ASSERT(sut.setupFailed == model.setupFailed);
  RC_ASSERT(sut.shell->captures.size() == size_t(model.capturing ? 1 : 0));
  RC_ASSERT(sut.shell->enables.size() == size_t(model.enabling ? 1 : 0));
  RC_ASSERT(sut.portal->captures == model.portalCaptures);
  RC_ASSERT(sut.captured == model.captured);
  RC_ASSERT(sut.failed == model.failed);
  const auto setup = sut.gnome->setup();
  RC_ASSERT(setup.has_value() == model.status.has_value());
  if (setup) {
    const QString& status = model.status->status;
    RC_ASSERT(setup->accessReady == (status == QLatin1String("unsupported") || (status == QLatin1String("enabled") && model.answering())));
  }
}

using Command = rc::state::Command<Model, Sut>;

struct Refresh : Command {
  void apply(Model& model) const override {
    if (!model.working) model.inspect();
  }
  void run(const Model& model, Sut& sut) const override {
    sut.gnome->refresh();
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

struct Answer : Command {
  size_t index = 0;
  GnomeShell::Extension extension;
  explicit Answer(const Model& model) {
    RC_PRE(!model.inspects.empty());
    index = *rc::gen::inRange<size_t>(0, model.inspects.size());
    extension.shellVersion = *rc::gen::element(QStringLiteral("47.2"), QStringLiteral("47.2"), QStringLiteral("44.1"));
    extension.failure = *rc::gen::element(QString(), QString(), QString(), QStringLiteral("GNOME did not respond."));
    extension.userExtensionsEnabled = *rc::gen::element(true, true, false);
    if (const int state = *rc::gen::inRange(0, 5)) extension.state = state;
    if (const int version = *rc::gen::inRange(0, 4)) extension.version = version;
    extension.service = *rc::gen::inRange(0, 3);
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(index < model.inspects.size()); }
  void apply(Model& model) const override { model.answered(index, extension); }
  void run(const Model& model, Sut& sut) const override {
    auto done = std::move(sut.shell->inspects[index]);
    sut.shell->inspects.erase(sut.shell->inspects.begin() + index);
    done(extension);
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

struct Perform : Command {
  QString action = *rc::gen::element(QStringLiteral("install-extension"), QStringLiteral("enable-extension"), QStringLiteral("disable-extension"),
                                     QStringLiteral("install-kde-helper"));
  void apply(Model& model) const override {
    if (action == QLatin1String("install-kde-helper")) {
      ++model.setupFailed;
      return;
    }
    if (model.working) return;
    model.working = true;
    model.action = action;
    model.inspect();
  }
  void run(const Model& model, Sut& sut) const override {
    sut.gnome->perform(action);
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

struct AnswerEnable : Command {
  bool ok = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.enabling); }
  void apply(Model& model) const override { model.settled(!ok); }
  void run(const Model& model, Sut& sut) const override {
    auto done = std::move(sut.shell->enables.front());
    sut.shell->enables.pop_front();
    done(ok ? QString() : QStringLiteral("GNOME has not loaded the extension."));
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

// Someone else's copy appears in the folder (another HAL-C2, the Extensions app).
struct SetInstalled : Command {
  double version = *rc::gen::element(1.0, 2.0, 3.0);
  void apply(Model& model) const override { model.installed = version; }
  void run(const Model& model, Sut& sut) const override {
    sut.setInstalled(version);
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

struct SetEffects : Command {
  bool flash = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.flash = flash; }
  void run(const Model& model, Sut& sut) const override {
    sut.gnome->setEffects(flash, false);
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

struct Capture : Command {
  void apply(Model& model) const override {
    if (!model.answering()) {
      ++model.portalCaptures;
    } else {
      model.capturing = true;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    const size_t before = sut.shell->flashes.size();
    sut.gnome->capture();
    Model next = model;
    apply(next);
    verify(next, sut);
    // A capture under way is the only one.
    if (model.capturing) RC_ASSERT(sut.shell->flashes.size() == before);
    if (next.capturing && !model.capturing) {
      RC_ASSERT(bool(sut.shell->flashes.back()) == (model.flash && model.extension->service == 2));
    }
  }
};

struct AnswerCapture : Command {
  int outcome = *rc::gen::inRange(0, 3);
  void checkPreconditions(const Model& model) const override { RC_PRE(model.capturing); }
  void apply(Model& model) const override {
    model.capturing = false;
    if (outcome == 0) {
      ++model.captured;
    } else {
      ++model.failed;
    }
  }
  void run(const Model& model, Sut& sut) const override {
    GnomeShell::Capture capture;
    if (outcome == 0) capture.png = sut.png;
    if (outcome == 1) capture.png = "not a png";
    if (outcome == 2) capture.error = QStringLiteral("Another HAL-C2 instance is capturing a window. Try again.");
    auto done = std::move(sut.shell->captures.front());
    sut.shell->captures.pop_front();
    done(capture);
    Model next = model;
    apply(next);
    verify(next, sut);
  }
};

}  // namespace

class GnomeSnapShotProp : public QObject {
  Q_OBJECT

private slots:
  void gnome() {
    Sut sut;
    QVERIFY(rc::check("the newest answer counts, checking follows what is asked, files change only by a chosen install, one capture at a time", [&sut] {
      sut.reset();
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Refresh, Answer, Answer, Answer, Perform, Perform, AnswerEnable, SetInstalled, SetEffects, Capture, AnswerCapture>());
    }));
  }
};

HAL_C2_PROP_MAIN(GnomeSnapShotProp)
#include "tst_GnomeSnapShotProp.moc"
