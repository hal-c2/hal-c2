// AttachmentViewerController opening a sent attachment against a fake MC that
// holds every signature and every download and answers them in any order, while
// the user opens other attachments, retries, saves and closes.
//
// What the user is promised: the viewer only ever shows what they last opened,
// loading until the latest fetch is answered; an answer to an older request,
// however late, changes nothing; a closed viewer stays closed; and a save lands
// in its folder whatever the viewer does meanwhile, and disturbs nothing.

#include "AttachmentViewerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"

#include <QPointer>
#include <QQmlPropertyMap>
#include <QTcpSocket>

namespace prop = halc2::prop;

namespace {

const QStringList kIds{QStringLiteral("a"), QStringLiteral("b")};
const QString kThread = QStringLiteral("env-a:t1");
const QString kUnavailable = QStringLiteral("The attachment is unavailable.");

QString contentsOf(const QString& id) { return QStringLiteral("the contents of ") + id; }

// A request: which fetch of the viewer it belongs to, for which attachment.
struct Held {
  int request = 0;
  QString id;
  bool save = false;
};

struct Model {
  QString open;
  // "loading", "text" or "failed", while something is open.
  QString kind;
  int request = 0;
  QList<Held> signatures;
  QList<Held> downloads;
  int saved = 0;
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/attachment-viewer-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QList<FakeMc::Rpc> signatures;
  QList<QPointer<QTcpSocket>> downloads;
  int asked = 0;
  // Addresses in the order they were signed: HTTP may bring them in any other.
  int signedCount = 0;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("t1")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    mc.onRpc(QStringLiteral("assets.createUrl"), [this](const FakeMc::Rpc& rpc) {
      // The shell asks for other pictures (the MC's avatar) on its own.
      if (rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("_tag")) != QLatin1String("attachment")) return mc.refuse(rpc, QStringLiteral("Not here."));
      signatures.append(rpc);
    });
    mc.onRaw(QStringLiteral("/api/assets/attachment/"), [this](QTcpSocket* socket, const QByteArray& head) {
      socket->read(head.size());
      const QString path = QString::fromUtf8(head.left(head.indexOf('\r')).split(' ').value(1));
      socket->setProperty("attachment", contentsOf(path.section(QLatin1Char('/'), 4, 4).section(QLatin1Char('?'), 0, 0)));
      socket->setProperty("signed", path.section(QStringLiteral("n="), 1).toInt());
      qsizetype at = downloads.size();
      while (at > 0 && downloads.at(at - 1)->property("signed").toInt() > socket->property("signed").toInt()) --at;
      downloads.insert(at, socket);
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->isActive() && native->client()->isReady() && native->store()->threadOnline(kThread); }));
    native->controller<AttachmentViewerController>()->setSaveFolder(home.filePath(QStringLiteral("saved")));
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), kThread}});
    RC_ASSERT(prop::until([this] { return native->controller<ThreadStore>()->activeThread() == kThread; }));
  }
  ~Sut() {
    native.reset();
    bridge.reset();
  }

  int saved() const { return int(QDir(home.filePath(QStringLiteral("saved"))).entryList(QDir::Files).size()); }
  QVariantMap shown() const { return bridge->state()->value(QStringLiteral("attachmentViewer")).toMap(); }
};

// Whatever was just asked or answered has landed, then what shows is the model's.
void check(const Model& expected, Sut& sut) {
  RC_ASSERT(prop::until([&] { return sut.signatures.size() == expected.signatures.size() && sut.downloads.size() == expected.downloads.size(); }));
  RC_ASSERT(prop::until([&] { return sut.shown().value(QStringLiteral("kind")).toString() == expected.kind; }));
  RC_ASSERT(prop::until([&] { return sut.saved() == expected.saved; }));
  const QVariantMap shown = sut.shown();
  if (expected.open.isEmpty()) {
    RC_ASSERT(shown.isEmpty());
    return;
  }
  RC_ASSERT(shown.value(QStringLiteral("id")).toString() == expected.open);
  if (expected.kind == QLatin1String("text")) RC_ASSERT(shown.value(QStringLiteral("text")).toString() == contentsOf(expected.open));
  if (expected.kind == QLatin1String("failed")) RC_ASSERT(shown.value(QStringLiteral("problem")).toString() == kUnavailable);
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(sut);
    check(expected, sut);
  }
};

void fetching(Model& model, const QString& id) {
  model.open = id;
  model.kind = QStringLiteral("loading");
  model.signatures.append({++model.request, id});
}

struct View : Step<View> {
  QString id = *rc::gen::elementOf(std::vector<QString>(kIds.cbegin(), kIds.cend()));
  explicit View(const Model&) {}
  void apply(Model& model) const override { fetching(model, id); }
  void act(Sut& sut) const {
    sut.bridge->dispatch(QStringLiteral("attachment.sent.view"),
                         QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("name"), id + QStringLiteral(".txt")}, {QStringLiteral("mimeType"), QStringLiteral("text/plain")}});
  }
  void show(std::ostream& os) const override { os << "view " << id.toStdString(); }
};

struct Retry : Step<Retry> {
  explicit Retry(const Model& model) { RC_PRE(!model.open.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.open.isEmpty()); }
  void apply(Model& model) const override { fetching(model, model.open); }
  void act(Sut& sut) const { sut.bridge->dispatch(QStringLiteral("attachment.viewer.retry")); }
  void show(std::ostream& os) const override { os << "retry"; }
};

struct Save : Step<Save> {
  explicit Save(const Model& model) { RC_PRE(!model.open.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.open.isEmpty()); }
  void apply(Model& model) const override { model.signatures.append({0, model.open, true}); }
  void act(Sut& sut) const { sut.bridge->dispatch(QStringLiteral("attachment.viewer.save")); }
  void show(std::ostream& os) const override { os << "save"; }
};

struct Close : Step<Close> {
  explicit Close(const Model&) {}
  void apply(Model& model) const override {
    model.open.clear();
    model.kind.clear();
    ++model.request;
  }
  void act(Sut& sut) const { sut.bridge->dispatch(QStringLiteral("attachment.viewer.close")); }
  void show(std::ostream& os) const override { os << "close"; }
};

// The MC signs a held address, or refuses to. Only the latest fetch goes on to
// download it; an older one's answer is dropped.
struct AnswerSignature : Step<AnswerSignature> {
  int index;
  bool refuse = *rc::gen::arbitrary<bool>();
  explicit AnswerSignature(const Model& model) : index(*rc::gen::inRange<int>(0, std::max<int>(1, model.signatures.size()))) { RC_PRE(!model.signatures.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(index < model.signatures.size()); }
  void apply(Model& model) const override {
    const Held held = model.signatures.takeAt(index);
    if (!held.save && held.request != model.request) return;
    if (!refuse) model.downloads.append(held);
    else if (!held.save) model.kind = QStringLiteral("failed");
  }
  void act(Sut& sut) const {
    const FakeMc::Rpc rpc = sut.signatures.takeAt(index);
    if (refuse) return sut.mc.refuse(rpc, QStringLiteral("No such attachment."));
    const QString id = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("attachmentId")).toString();
    sut.mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/attachment/%1?n=%2").arg(id).arg(sut.signedCount++)},
                                  {QStringLiteral("expiresAt"), 4102444800000.0}});
  }
  void show(std::ostream& os) const override { os << "answer signature " << index << (refuse ? " refused" : ""); }
};

// The MC serves a held download of the latest fetch: the attachment, or nothing.
struct AnswerDownload : Step<AnswerDownload> {
  int index;
  bool gone = *rc::gen::arbitrary<bool>();
  explicit AnswerDownload(const Model& model) : index(*rc::gen::inRange<int>(0, std::max<int>(1, model.downloads.size()))) { RC_PRE(!model.downloads.isEmpty()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(index < model.downloads.size()); }
  void apply(Model& model) const override {
    const Held held = model.downloads.takeAt(index);
    if (held.save) model.saved += gone ? 0 : 1;
    else if (held.request == model.request) model.kind = gone ? QStringLiteral("failed") : QStringLiteral("text");
  }
  void act(Sut& sut) const {
    const QPointer<QTcpSocket> socket = sut.downloads.takeAt(index);
    RC_ASSERT(socket != nullptr);
    if (gone) {
      socket->write("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    } else {
      const QByteArray body = socket->property("attachment").toString().toUtf8();
      socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    }
    socket->disconnectFromHost();
  }
  void show(std::ostream& os) const override { os << "answer download " << index << (gone ? " gone" : ""); }
};

}  // namespace

class AttachmentViewerProp : public QObject {
  Q_OBJECT

private slots:
  void latestRequestWins() {
    QVERIFY(rc::check("the viewer shows only what was last opened", [] {
      Sut sut;
      Model model;
      const auto commands = *rc::gen::scale(0.5, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<View, View, Retry, Save, Close, AnswerSignature, AnswerSignature, AnswerDownload, AnswerDownload>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(AttachmentViewerProp)
#include "tst_AttachmentViewerProp.moc"
