// The capture helper of KDE Plasma and Hyprland (CaptureHelper) on a fake helper
// in a temporary directory. The user installs, removes, checks and captures, the
// helper starts failing or recovers, a newer build replaces the bundle, and
// something else leaves a link where the helper goes. Files change only when
// install or remove is asked for, and a link is never written through; the state
// says what is on disk and whether the helper answers; and every capture gets
// exactly one answer, even one that arrives while a check is still running.

#include "Prop.h"

#include <QFile>
#include <QFileInfo>
#include <QImage>

#include <memory>

#include "CaptureHelper.h"

namespace prop = halc2::prop;

namespace {

struct Model {
  bool kde = false;
  bool installed = false;
  bool stale = false;
  bool link = false;
  bool failing = false;

  QString status() const {
    if (link) return QStringLiteral("error");
    if (!installed) return QStringLiteral("not-installed");
    if (stale) return QStringLiteral("update-required");
    return failing ? QStringLiteral("error") : QStringLiteral("ready");
  }
};

struct Sut {
  QTemporaryDir root;
  std::unique_ptr<CaptureHelper> helper;
  int builds = 0;
  int captured = 0;
  int failed = 0;
  bool linked = false;

  explicit Sut(bool kde) {
    QImage image(8, 8, QImage::Format_RGB32);
    image.fill(Qt::darkCyan);
    image.save(root.filePath(QStringLiteral("capture.png")), "PNG");
    setFailing(false);
    newBuild();
    QDir().mkpath(root.filePath(QStringLiteral("tools")));
    for (const char* tool : {"kbuildsycoca6", "systemd-run"}) {
      write(root.filePath(QStringLiteral("tools/") + QLatin1String(tool)), "#!/bin/sh\nexit 0\n", true);
    }
    CaptureHelper::setToolPath({root.filePath(QStringLiteral("tools"))});
    const auto kind = kde ? CaptureHelper::Kind::Kde : CaptureHelper::Kind::Hyprland;
    helper = std::make_unique<CaptureHelper>(kind, CaptureHelper::Paths{root.filePath(QStringLiteral("bundle")), root.filePath(QStringLiteral("data"))});
    QObject::connect(helper.get(), &CaptureHelper::captured, helper.get(), [this] { ++captured; });
    QObject::connect(helper.get(), &CaptureHelper::failed, helper.get(), [this] { ++failed; });
  }

  static void write(const QString& path, const QByteArray& bytes, bool executable = false) {
    QFile file(path);
    RC_ASSERT(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(bytes);
    file.close();
    if (executable) file.setPermissions(file.permissions() | QFileDevice::ExeOwner);
  }

  void setFailing(bool on) { write(root.filePath(QStringLiteral("failing")), on ? "1" : "0"); }

  // A build whose helper differs from every one before it.
  void newBuild() {
    write(root.filePath(QStringLiteral("bundle")),
          QStringLiteral(R"sh(#!/bin/sh
# build %1
root='%2'
[ "$(cat "$root/failing")" = 1 ] && exit 1
case "$1" in
  check) echo '{"feedbackAvailable":false}' ;;
  capture) cp "$root/capture.png" "$2/capture.png"; echo '{"window":{"appName":"App","title":"Title"}}' ;;
esac
)sh").arg(++builds).arg(root.path()).toUtf8(),
          true);
  }

  void settle() const {
    RC_ASSERT(prop::until([this] { return !helper->busy(); }));
  }

  void check() {
    helper->check();
    settle();
  }

  void perform(const QString& action) {
    helper->perform(action);
    settle();
  }

  bool agrees(const Model& model) const {
    const QFileInfo file(helper->executable());
    return helper->state().status == model.status() && file.isSymLink() == model.link && (file.exists() || file.isSymLink()) == (model.installed || model.link);
  }
};

using Command = rc::state::Command<Model, Sut>;

// Applies the command to a copy of the model, runs it, and checks what is on disk against the copy.
template <typename Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(sut);
    sut.check();
    RC_ASSERT(sut.agrees(next));
  }
};

struct Check : Step<Check> {
  void apply(Model&) const override {}
  void act(Sut&) const {}
  void show(std::ostream& os) const override { os << "Check"; }
};

struct Install : Step<Install> {
  void apply(Model& model) const override {
    if (model.link) return;
    model.installed = true;
    model.stale = false;
  }
  void act(Sut& sut) const { sut.perform(sut.helper->installAction()); }
  void show(std::ostream& os) const override { os << "Install"; }
};

struct Remove : Step<Remove> {
  void apply(Model& model) const override {
    if (model.link) return;
    model.installed = false;
    model.stale = false;
  }
  void act(Sut& sut) const { sut.perform(sut.helper->removeAction()); }
  void show(std::ostream& os) const override { os << "Remove"; }
};

struct Fail : Step<Fail> {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.failing = on; }
  void act(Sut& sut) const { sut.setFailing(on); }
  void show(std::ostream& os) const override { os << "Failing " << on; }
};

struct NewBuild : Step<NewBuild> {
  void apply(Model& model) const override { model.stale = model.installed; }
  void act(Sut& sut) const { sut.newBuild(); }
  void show(std::ostream& os) const override { os << "NewBuild"; }
};

// Something else puts a link where the helper goes, then takes it away.
struct Link : Step<Link> {
  void apply(Model& model) const override {
    model.link = !model.link;
    model.installed = false;
    model.stale = false;
  }
  void act(Sut& sut) const {
    const QString path = sut.helper->executable();
    QFile::remove(path);
    if (!sut.linked) {
      QDir().mkpath(QFileInfo(path).path());
      RC_ASSERT(QFile::link(sut.root.filePath(QStringLiteral("capture.png")), path));
    }
    sut.linked = !sut.linked;
  }
  void show(std::ostream& os) const override { os << "Link"; }
};

struct Capture : Command {
  // Pressed while a check is still running.
  bool overlap = *rc::gen::arbitrary<bool>();
  void run(const Model& model, Sut& sut) const override {
    if (overlap) sut.helper->check();
    const bool busy = sut.helper->busy();
    const int before = sut.captured + sut.failed;
    const int captured = sut.captured;
    sut.helper->capture();
    RC_ASSERT(prop::until([&] { return sut.captured + sut.failed > before; }));
    sut.settle();
    QCoreApplication::processEvents();
    RC_ASSERT(sut.captured + sut.failed == before + 1);
    RC_ASSERT((sut.captured > captured) == (model.status() == QLatin1String("ready") && !busy));
    sut.check();
    RC_ASSERT(sut.agrees(model));
  }
  void show(std::ostream& os) const override { os << "Capture overlap=" << overlap; }
};

class CaptureHelperProp : public QObject {
  Q_OBJECT

private slots:
  void model() {
    QVERIFY(rc::check("the helper's files and answers follow what the user asked", [] {
      const bool kde = *rc::gen::arbitrary<bool>();
      Model model;
      model.kde = kde;
      Sut sut(kde);
      sut.check();
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Check, Install, Remove, Fail, NewBuild, Link, Capture>());
    }));
  }
};

}  // namespace

HAL_C2_PROP_MAIN(CaptureHelperProp)

#include "tst_CaptureHelperProp.moc"
