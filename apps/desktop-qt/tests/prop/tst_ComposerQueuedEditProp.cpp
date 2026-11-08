// Editing a queued message with its attachments (ComposerController): the
// composer shows the message's own attachments (`sent`) beside any the user
// adds, with the draft's own set aside, and gives those back whichever way the
// edit ends (saved, cancelled, or its run leaving the queue). A save names the
// attachments only when they changed, and then names what the composer showed:
// the ones kept and the ones added. The queue card lists what each queued
// message carries, as the MC holds it. A save the MC refused leaves the edit
// open, and saving again stores none of its images a second time. Saves go
// one at a time, and of those made while one is unanswered only the newest goes.
// Each thread keeps its own edit: going to another thread and back finds it
// open, unless its message left the queue meanwhile.

#include <algorithm>

#include <QBuffer>
#include <QFile>
#include <QFileInfo>
#include <QImage>

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QString kThread = QStringLiteral("t1");
const QString kKey = QStringLiteral("env-a:t1");
const QString kOther = QStringLiteral("t2");
QDateTime fixedClock() { return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC); }

QString png() {
  static const QString encoded = [] {
    QImage picture(4, 4, QImage::Format_RGB32);
    picture.fill(Qt::darkCyan);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, "PNG");
    return QString::fromLatin1(bytes.toBase64());
  }();
  return encoded;
}

struct Queued {
  QString runId;
  QStringList attachments;  // ids, as the MC holds them
};

struct Model {
  QList<Queued> queue;
  int draftImages = 0;  // the thread's own draft attachments
  // The edit, when one is open.
  std::optional<QString> editing;
  QStringList sent;  // the edited message's attachments still on the edit
  bool sentChanged = false;
  // What was added in the composer during the edit, in order: a file's id
  // (file-<n>), an image's id once the MC stored it, kUnstored until then.
  QStringList added;
  int setAside = 0;  // the draft's attachments set aside for it
  int edits = 0;     // queued-run.edit commands the MC got
  int counter = 0;
  int stored = 0;  // images the MC has stored (stored-<n>)
  int files = 0;   // files the MC took (file-<n>)

  static inline const QString kUnstored = QStringLiteral("?");

  // The MC stores the added images not stored yet.
  void storeAdded() {
    for (QString& id : added) {
      if (id == kUnstored) id = QStringLiteral("stored-%1").arg(++stored);
    }
  }

  void end() {
    draftImages = setAside + int(added.size());
    editing.reset();
    sent.clear();
    sentChanged = false;
    added.clear();
    setAside = 0;
  }
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-queued-edit-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QList<QJsonObject> runs;
  QHash<QString, QJsonObject> messages;
  int seq = 0;
  int stored = 0;
  int files = 0;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(kThread, QJsonObject{{QStringLiteral("id"), kThread},
                                           {QStringLiteral("projectId"), QStringLiteral("p1")},
                                           {QStringLiteral("title"), kThread},
                                           {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                           {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    mc.threads.insert(kOther, QJsonObject{{QStringLiteral("id"), kOther},
                                          {QStringLiteral("projectId"), QStringLiteral("p1")},
                                          {QStringLiteral("title"), kOther},
                                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) {
      QJsonArray rows;
      // The other thread has nothing queued.
      if (shape.value(QLatin1String("stream")).toString() == kThread)
        for (const QJsonObject& message : std::as_const(messages)) rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
      if (shape.value(QLatin1String("stream")).toString() == kThread)
        for (const QJsonObject& run : std::as_const(runs)) rows.append(QJsonArray{QStringLiteral("run"), run.value(QLatin1String("id")), run});
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    // The images the MC stores for a message.
    mc.onRpc(QStringLiteral("assets.persistChatAttachments"), [this](const FakeMc::Rpc& rpc) {
      QJsonArray images;
      for (const QJsonValue& value : rpc.payload.value(QLatin1String("attachments")).toArray()) {
        QJsonObject image = value.toObject();
        image.remove(QStringLiteral("dataUrl"));
        image.insert(QStringLiteral("id"), QStringLiteral("stored-%1").arg(++stored));
        images.append(image);
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("attachments"), images}});
    });
    // A file goes up as the MC's upload takes it.
    mc.onRpc(QStringLiteral("attachments.createUploadUrl"), [this](const FakeMc::Rpc& rpc) {
      const QString id = QStringLiteral("file-%1").arg(++files);
      const QString url = QStringLiteral("/api/attachments/upload/%1").arg(id);
      mc.onHttp(url, [](const QJsonObject&, std::function<void(int, const QJsonObject&)> respond) { respond(204, {}); });
      mc.reply(rpc, QJsonObject{{QStringLiteral("attachmentId"), id}, {QStringLiteral("relativeUrl"), url},
                                {QStringLiteral("expiresAt"), 4102444800000.0}});
    });
    // No image is signed here: a thumbnail stays its icon.
    mc.onRpc(QStringLiteral("assets.createUrl"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonObject()); });
    // The MC edits the queued message: its text, and its attachments when named.
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("queued-run.edit")) return;
      for (const QJsonObject& run : std::as_const(runs)) {
        if (run.value(QLatin1String("id")) != command.value(QLatin1String("runId"))) continue;
        QJsonObject& message = messages[run.value(QLatin1String("userMessageId")).toString()];
        message.insert(QStringLiteral("text"), command.value(QLatin1String("text")));
        if (command.contains(QLatin1String("attachments"))) message.insert(QStringLiteral("attachments"), command.value(QLatin1String("attachments")));
        publish(QStringLiteral("message"), message);
      }
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<ToastController>()->setClock(fixedClock);
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return native->client()->isReady() && native->store()->threadOnline(kKey); }));
    open(kKey);
  }

  void open(const QString& key) {
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    barrier();
    RC_ASSERT(prop::until([this, key] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(key);
      return timeline && timeline->status() == QLatin1String("live");
    }));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  void publish(const QString& kind, const QJsonObject& state) {
    ++seq;
    const QString at = fixedClock().addSecs(seq).toString(Qt::ISODateWithMs);
    for (const int sub : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != kThread) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"),
                QJsonArray{QJsonValue(QJsonArray{seq, kind, state.value(QLatin1String("id")), QJsonObject{{QStringLiteral("s"), state}}, at})}}});
    }
  }

  void enqueue(int n, const QStringList& attachments) {
    QJsonArray carried;
    for (const QString& id : attachments) {
      carried.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("image")}, {QStringLiteral("id"), id},
                                 {QStringLiteral("name"), id + QStringLiteral(".png")}, {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                 {QStringLiteral("sizeBytes"), 10}});
    }
    const QString messageId = QStringLiteral("message-%1").arg(n);
    const QJsonObject message{{QStringLiteral("id"), messageId}, {QStringLiteral("role"), QStringLiteral("user")},
                              {QStringLiteral("createdBy"), QStringLiteral("user")},
                              {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00.000Z")},
                              {QStringLiteral("text"), QStringLiteral("queued %1").arg(n)}, {QStringLiteral("attachments"), carried}};
    const QJsonObject run{{QStringLiteral("id"), QStringLiteral("run-%1").arg(n)}, {QStringLiteral("ordinal"), n}, {QStringLiteral("queuePosition"), n},
                          {QStringLiteral("status"), QStringLiteral("queued")}, {QStringLiteral("userMessageId"), messageId},
                          {QStringLiteral("queueHeld"), false}};
    messages.insert(messageId, message);
    runs.append(run);
    publish(QStringLiteral("message"), message);
    publish(QStringLiteral("run"), run);
  }

  void leave(const QString& runId) {
    for (QJsonObject& run : runs) {
      if (run.value(QLatin1String("id")) != runId) continue;
      run.insert(QStringLiteral("status"), QStringLiteral("running"));
      publish(QStringLiteral("run"), run);
    }
  }

  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
  }

  QVariantMap composer() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }
  QVariantList queue() const { return bridge->state()->value(QStringLiteral("turn")).toMap().value(QStringLiteral("queue")).toList(); }

  int revision = 0;
  void type(const QString& text) {
    bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), kKey},
                                                                    {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                                                         {QStringLiteral("revision"), ++revision}}},
                                                                    {QStringLiteral("text"), text},
                                                                    {QStringLiteral("cursor"), text.size()}});
  }

  QList<QJsonObject> edits() const {
    QList<QJsonObject> found;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("queued-run.edit")) found.append(command);
    }
    return found;
  }
};

void verify(const Model& m, Sut& sut) {
  sut.barrier();
  RC_ASSERT(prop::until([&] {
    const QVariantMap composer = sut.composer();
    const QVariant editing = composer.value(QStringLiteral("editingQueuedRunId"));
    if (m.editing ? editing.toString() != *m.editing : !editing.isNull()) return false;
    QStringList sent;
    int own = 0;
    for (const QVariant& value : composer.value(QStringLiteral("attachments")).toList()) {
      const QVariantMap attachment = value.toMap();
      if (attachment.value(QStringLiteral("sent")).toBool()) {
        sent.append(attachment.value(QStringLiteral("id")).toString());
      } else {
        ++own;
      }
    }
    if (sent != m.sent || own != (m.editing ? int(m.added.size()) : m.draftImages)) return false;
    // The queue card lists what each message carries.
    const QVariantList queue = sut.queue();
    if (queue.size() != m.queue.size()) return false;
    for (qsizetype i = 0; i < queue.size(); ++i) {
      QStringList carried;
      for (const QVariant& attachment : queue.at(i).toMap().value(QStringLiteral("attachments")).toList())
        carried.append(attachment.toMap().value(QStringLiteral("id")).toString());
      if (queue.at(i).toMap().value(QStringLiteral("runId")) != m.queue.at(i).runId || carried != m.queue.at(i).attachments) return false;
    }
    return true;
  }));
  RC_ASSERT(sut.edits().size() == m.edits);
  // No image is stored twice.
  RC_ASSERT(sut.stored == m.stored);
}

using Command = rc::state::Command<Model, Sut>;

struct Enqueue : Command {
  int count = *rc::gen::inRange(0, 3);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.queue.size() < 3); }
  QStringList ids(const Model& m) const {
    QStringList made;
    for (int i = 0; i < count; ++i) made.append(QStringLiteral("sent-%1-%2").arg(m.counter + 1).arg(i));
    return made;
  }
  void apply(Model& m) const override {
    m.queue.append({QStringLiteral("run-%1").arg(m.counter + 1), ids(m)});
    ++m.counter;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.enqueue(m0.counter + 1, ids(m0));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Enqueue(" << count << ")"; }
};

struct Attach : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE((m.editing ? int(m.added.size()) : m.draftImages) < 2); }
  void apply(Model& m) const override {
    if (m.editing) {
      m.added.append(Model::kUnstored);
    } else {
      ++m.draftImages;
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.attach"),
                         QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{{QStringLiteral("name"), QStringLiteral("shot.png")},
                                                                                        {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                                        {QStringLiteral("base64"), png()}}}}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Attach"; }
};

// A file added to the edit, uploaded before anything else happens.
struct AttachFile : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing && m.added.size() < 3); }
  void apply(Model& m) const override { m.added.append(QStringLiteral("file-%1").arg(++m.files)); }
  void run(const Model& m0, Sut& sut) const override {
    const QString path = sut.home.filePath(QStringLiteral("notes-%1.md").arg(m0.files + 1));
    QFile file(path);
    RC_ASSERT(file.open(QIODevice::WriteOnly));
    file.write("# notes\n");
    file.close();
    sut.bridge->dispatch(QStringLiteral("composer.attach"),
                         QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{{QStringLiteral("name"), QFileInfo(path).fileName()},
                                                                                        {QStringLiteral("mimeType"), QStringLiteral("text/markdown")},
                                                                                        {QStringLiteral("path"), path}}}}});
    RC_ASSERT(prop::until([&] {
      const QVariantList shown = sut.composer().value(QStringLiteral("attachments")).toList();
      return std::none_of(shown.cbegin(), shown.cend(),
                          [](const QVariant& a) { return a.toMap().value(QStringLiteral("status")) == QLatin1String("uploading"); });
    }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "AttachFile"; }
};

struct Edit : Command {
  int at = *rc::gen::inRange(0, 3);
  void checkPreconditions(const Model& m) const override { RC_PRE(at < m.queue.size()); }
  void apply(Model& m) const override {
    if (!m.editing) {
      m.setAside = m.draftImages;
      m.draftImages = 0;
    } else if (*m.editing != m.queue.at(at).runId) {
      // What was added for the message left goes aside with the draft.
      m.setAside += int(m.added.size());
      m.added.clear();
    }
    m.editing = m.queue.at(at).runId;
    m.sent = m.queue.at(at).attachments;
    m.sentChanged = false;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.queue.edit"), QVariantMap{{QStringLiteral("runId"), m0.queue.at(at).runId}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Edit(" << at << ")"; }
};

struct RemoveSent : Command {
  int at = *rc::gen::inRange(0, 2);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing && at < m.sent.size()); }
  void apply(Model& m) const override {
    m.sent.removeAt(at);
    m.sentChanged = true;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.attachment.remove"), QVariantMap{{QStringLiteral("id"), m0.sent.at(at)}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "RemoveSent(" << at << ")"; }
};

struct Cancel : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing.has_value()); }
  void apply(Model& m) const override { m.end(); }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.queue.edit.cancel"), QVariantMap());
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Cancel"; }
};

// Sending saves the edit; the MC takes it.
struct Save : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing.has_value()); }
  void apply(Model& m) const override {
    ++m.edits;
    for (Queued& queued : m.queue) {
      if (queued.runId != *m.editing || (!m.sentChanged && m.added.isEmpty())) continue;
      m.storeAdded();
      // The added ones, in the order added, follow the kept ones.
      queued.attachments = m.sent + m.added;
    }
    m.added.clear();  // they went with the message
    m.end();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap());
    verify(nextState(m0), sut);
    const QJsonObject edit = sut.edits().constLast();
    RC_ASSERT(edit.value(QLatin1String("runId")).toString() == *m0.editing);
    // Named only when they changed.
    RC_ASSERT(edit.contains(QLatin1String("attachments")) == (m0.sentChanged || !m0.added.isEmpty()));
  }
  void show(std::ostream& os) const override { os << "Save"; }
};

// The MC refuses the save: the edit stays open with what it had, and the
// images stored for it are kept for the next save.
struct SaveRefused : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing.has_value()); }
  void apply(Model& m) const override {
    ++m.edits;
    if (m.sentChanged || !m.added.isEmpty()) m.storeAdded();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.refusals.insert(QStringLiteral("queued-run.edit"), QStringLiteral("The queue changed."));
    sut.bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap());
    // The refusal is sent as the command arrives; the barrier after it reads it.
    RC_ASSERT(prop::until([&] { return sut.edits().size() == m0.edits + 1; }));
    sut.barrier();
    sut.mc.refusals.remove(QStringLiteral("queued-run.edit"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "SaveRefused"; }
};

// Saves made while the first is unanswered (the MC is slow, then answers or
// refuses it): none is sent until it is answered, then only the newest goes,
// and its answer ends the edit.
struct SaveWhileSaving : Command {
  int more = *rc::gen::inRange(1, 3);
  bool refused = *rc::gen::arbitrary<bool>();
  // Text alone: what a save stores is SaveRefused's to prove.
  void checkPreconditions(const Model& m) const override { RC_PRE(m.editing && !m.sentChanged && m.added.isEmpty()); }
  void apply(Model& m) const override {
    m.edits += 2;
    m.end();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.hold(QStringLiteral("answers"));
    if (refused) sut.mc.refusals.insert(QStringLiteral("queued-run.edit"), QStringLiteral("The queue changed."));
    sut.type(QStringLiteral("save 0"));
    sut.bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap());
    RC_ASSERT(prop::until([&] { return sut.edits().size() == m0.edits + 1; }));
    for (int i = 1; i <= more; ++i) {
      sut.type(QStringLiteral("save %1").arg(i));
      sut.bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap());
    }
    sut.barrier();
    // Still one: the rest wait for its answer.
    RC_ASSERT(sut.edits().size() == m0.edits + 1);
    sut.mc.refusals.remove(QStringLiteral("queued-run.edit"));
    sut.mc.answerHeld();
    RC_ASSERT(prop::until([&] { return sut.edits().size() == m0.edits + 2; }));
    verify(nextState(m0), sut);
    RC_ASSERT(sut.edits().constLast().value(QLatin1String("text")).toString() == QStringLiteral("save %1").arg(more));
    RC_ASSERT(sut.edits().constLast().value(QLatin1String("runId")).toString() == *m0.editing);
  }
  void show(std::ostream& os) const override { os << "SaveWhileSaving(" << more << (refused ? ", refused" : "") << ")"; }
};

// The first queued run starts: an edit of it ends, and the composer keeps what was added.
struct Leave : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.queue.isEmpty()); }
  void apply(Model& m) const override {
    const QString runId = m.queue.takeFirst().runId;
    if (m.editing == runId) m.end();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.leave(m0.queue.constFirst().runId);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Leave"; }
};

// The user goes to the other thread and back, and the first queued run may
// start meanwhile: the edit waits for them unless its message left the queue.
struct Away : Command {
  bool starts = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& m) const override { RC_PRE(!starts || !m.queue.isEmpty()); }
  void apply(Model& m) const override {
    if (!starts) return;
    const QString runId = m.queue.takeFirst().runId;
    if (m.editing == runId) m.end();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(sut.mc.environmentId + QLatin1Char(':') + kOther);
    if (starts) sut.leave(m0.queue.constFirst().runId);
    sut.barrier();
    sut.open(kKey);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Away(" << (starts ? "starts" : "") << ")"; }
};

}  // namespace

class ComposerQueuedEditProp : public QObject {
  Q_OBJECT

private slots:
  void queuedEditKeepsAttachments() {
    QVERIFY(rc::check("a queued message's edit shows and saves its attachments, and gives the draft's back", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Enqueue, Enqueue, Attach, AttachFile, Edit, Edit, RemoveSent, Cancel, Save, SaveRefused, SaveWhileSaving, Leave, Away>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerQueuedEditProp)
#include "tst_ComposerQueuedEditProp.moc"
