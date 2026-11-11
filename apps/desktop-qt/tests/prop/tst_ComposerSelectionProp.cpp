// What the composer shows is what runs (ComposerController::sendTurn,
// forgetTakenPicks, dispatchAll), against a fake MC that counts selection
// revisions as the MC does (lib/hal_c2/orchestration): a command based on a
// revision the thread has moved past is refused when what it sets differs, and
// any change to the model, access or interaction mode moves the revision.
//
// The property: a send carries exactly what the composer showed, and never a
// choice the user did not make against the current revision. Picks, sends,
// this client's own access changes, changes made on another client, held and
// reordered answers, rows that come before or after an answer, refusals and
// reconnects are interleaved. Three MCs: one whose answers name the revision
// they moved to, one whose answers name none (the client counts its own
// changes), and one from before revisions (a pick is saved to the thread
// before the send, and nothing carries a base).

#include <QJsonArray>
#include <QJsonObject>

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace prop = halc2::prop;

namespace {

enum class Mc { Named, Unnamed, Old };

const QString kThread = QStringLiteral("t1");
const QString kKey = QStringLiteral("env-a:t1");
// (instance, model) the picker offers.
const QList<std::pair<QString, QString>> kModels{{QStringLiteral("codex"), QStringLiteral("gpt-a")},
                                                 {QStringLiteral("codex"), QStringLiteral("gpt-b")},
                                                 {QStringLiteral("claudeAgent"), QStringLiteral("claude-a")}};
// The access this client picks, and the access another client picks: never
// the same, so a change from elsewhere always moves the thread.
const QStringList kOwnAccess{QStringLiteral("approval-required"), QStringLiteral("full-access")};
const QStringList kOtherAccess{QStringLiteral("auto-accept-edits"), QStringLiteral("auto")};
const QStringList kInteractions{QStringLiteral("default"), QStringLiteral("plan")};

QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QJsonObject selectionOf(const QString& instance, const QString& model) {
  return {{QStringLiteral("instanceId"), instance}, {QStringLiteral("model"), model}};
}

QString nameOf(const QJsonObject& selection) {
  return selection.value(QLatin1String("instanceId")).toString() + u'/' + selection.value(QLatin1String("model")).toString();
}

QJsonArray providers() {
  QJsonArray list;
  for (const QString& instance : {QStringLiteral("codex"), QStringLiteral("claudeAgent")}) {
    QJsonArray models;
    for (const auto& [owner, slug] : kModels) {
      if (owner == instance) models.append(QJsonObject{{QStringLiteral("slug"), slug}, {QStringLiteral("name"), slug}});
    }
    list.append(QJsonObject{{QStringLiteral("instanceId"), instance},
                            {QStringLiteral("driver"), instance},
                            {QStringLiteral("enabled"), true},
                            {QStringLiteral("installed"), true},
                            {QStringLiteral("status"), QStringLiteral("ready")},
                            {QStringLiteral("models"), models}});
  }
  return list;
}

struct Model {
  Mc mc = Mc::Named;
  bool holding = false;
  bool lagging = false;
  bool sending = false;  // a send on its way, its answer held
};

// A send the composer made: what it showed and what it knew then.
struct Submission {
  QString text;
  QString shown;      // instance/model the composer showed
  QString row;        // the thread's model as this client had it
  bool current = true;  // whether this client had the MC's latest selection
  qsizetype foreign = 0;  // changes made elsewhere by then
  bool refused = false;
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-selection-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  Mc kind;

  // The MC's thread.
  QJsonObject selection = selectionOf(QStringLiteral("codex"), QStringLiteral("gpt-a"));
  QString runtime = QStringLiteral("full-access");
  QString interaction = QStringLiteral("default");
  qint64 revision = 1;
  QList<qint64> foreign;  // the revisions made elsewhere, in order

  bool ackFirst = true;  // the answer to a change reaches the client before its row
  // What the user picked, by field, and the revision this client had then.
  QHash<QString, qint64> pickedAt;
  std::optional<Submission> submission;
  QStringList violations;
  int named = 0;  // answers that named a revision

  explicit Sut(Mc mc_) : kind(mc_) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(kThread, row());
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers()}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), QJsonArray()}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 0},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    mc.onRpc(QStringLiteral("orchestration.dispatchCommand"), [this](const FakeMc::Rpc& rpc) {
      mc.commands.append(rpc.payload);
      mc.commandEnvironments.append(rpc.environment);
      // A held answer is decided when it is answered: what reached the
      // thread in between (a change elsewhere) is decided first.
      if (mc.holding(QStringLiteral("answers"))) return mc.defer([this, rpc] { decide(rpc); });
      decide(rpc);
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    RC_ASSERT(native->controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return online(); }));
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), kKey}});
    RC_ASSERT(prop::until([this] { return shown().value(QStringLiteral("target")).toString() == kKey && shownModel() == nameOf(selection); }));
    // Until an MC that names revisions has named one, a change of this
    // client's that moved nothing cannot be told from one that did
    // (ComposerController::ownAnswered): one access change shows which it is.
    if (kind == Mc::Named) {
      bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), kOwnAccess.first()}});
      RC_ASSERT(prop::until([this] { return named > 0; }));
      barrier();
    }
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  bool online() const { return native->isActive() && native->client()->isReady() && mc.connected() && native->store()->threadOnline(kKey); }

  QJsonObject row() const {
    QJsonObject thread{{QStringLiteral("id"), kThread},
                       {QStringLiteral("projectId"), QStringLiteral("p1")},
                       {QStringLiteral("title"), QStringLiteral("Tax line")},
                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                       {QStringLiteral("modelSelection"), selection},
                       {QStringLiteral("runtimeMode"), runtime},
                       {QStringLiteral("interactionMode"), interaction}};
    if (kind != Mc::Old) thread.insert(QStringLiteral("selectionRevision"), double(revision));
    return thread;
  }

  void publish() {
    mc.threads.insert(kThread, row());
    mc.sendRow(kThread, row());
  }

  QVariantMap shown() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }
  QString shownModel() const {
    const QVariantMap composer = shown();
    return composer.value(QStringLiteral("selectedInstanceId")).toString() + u'/' + composer.value(QStringLiteral("selectedModel")).toString();
  }
  // The revision of the thread this client holds; -1 for an MC without them.
  qint64 seen() const {
    const auto thread = native->store()->thread(kKey);
    return thread && thread->selectionRevision ? *thread->selectionRevision : -1;
  }
  QString seenModel() const {
    const auto thread = native->store()->thread(kKey);
    return thread ? nameOf(thread->modelSelection) : QString();
  }

  bool foreignWithin(qint64 after, qint64 upTo) const {
    return std::any_of(foreign.cbegin(), foreign.cend(), [&](qint64 f) { return f > after && f <= upTo; });
  }

  void violate(const QString& what) { violations.append(what); }

  // The MC decides a command: refuses one based on a revision the thread has
  // moved past when what it sets differs, else takes it.
  void decide(const FakeMc::Rpc& rpc) {
    const QJsonObject& command = rpc.payload;
    const QString type = command.value(QLatin1String("type")).toString();
    std::optional<QJsonObject> model;
    std::optional<QString> access;
    std::optional<QString> mode;
    if (type == QLatin1String("thread.runtime-mode.set")) access = command.value(QLatin1String("runtimeMode")).toString();
    if (type == QLatin1String("thread.interaction-mode.set")) mode = command.value(QLatin1String("interactionMode")).toString();
    if (type == QLatin1String("provider.switch") || type == QLatin1String("thread.model-selection.set")) {
      model = command.value(QLatin1String("modelSelection")).toObject();
    }
    // Today's MC runs a plain send on the message's model but keeps the thread's.
    if (type == QLatin1String("message.dispatch") && kind != Mc::Old && command.contains(QLatin1String("modelSelection"))) {
      model = command.value(QLatin1String("modelSelection")).toObject();
    }
    const bool movesModel = model && nameOf(*model) != nameOf(selection);
    const bool movesAccess = access && *access != runtime;
    const bool movesMode = mode && *mode != interaction;
    const bool moves = movesModel || movesAccess || movesMode;
    const bool based = command.contains(QLatin1String("selectionBase"));
    const qint64 base = qint64(command.value(QLatin1String("selectionBase")).toDouble());
    if (based && kind == Mc::Old) violate(QStringLiteral("%1 carries a base to an MC without revisions").arg(type));
    if (type == QLatin1String("thread.model-selection.set") && kind != Mc::Old) {
      violate(QStringLiteral("a model saved apart from the send to an MC that counts revisions"));
    }
    if (based && base != revision && moves) {
      // Only a change made elsewhere makes a pick stale.
      if (!foreignWithin(base, revision)) violate(QStringLiteral("%1 on %2 refused at %3 for changes of this client's own").arg(type).arg(base).arg(revision));
      if (submission) submission->refused = true;
      mc.refuse(rpc, QStringLiteral("The thread's selection changed"),
                {{QStringLiteral("code"), QStringLiteral("selection-stale")},
                 {QStringLiteral("selectionRevision"), double(revision)},
                 {QStringLiteral("modelSelection"), selection},
                 {QStringLiteral("providerInstanceId"), selection.value(QLatin1String("instanceId"))},
                 {QStringLiteral("runtimeMode"), runtime},
                 {QStringLiteral("interactionMode"), interaction}});
      return;
    }
    // A choice that moves the thread is the user's, made against what they saw.
    const auto made = [&](const QString& field, bool movesIt) {
      if (!movesIt || kind == Mc::Old || type == QLatin1String("thread.runtime-mode.set")) return;
      if (!pickedAt.contains(field)) return violate(QStringLiteral("%1 sets the %2 the user never picked").arg(type, field));
      if (foreignWithin(pickedAt.value(field), revision)) {
        violate(QStringLiteral("%1 sets the %2 picked at %3 over a change made elsewhere by %4").arg(type, field).arg(pickedAt.value(field)).arg(revision));
      }
    };
    made(QStringLiteral("model"), movesModel);
    made(QStringLiteral("interaction"), movesMode);
    if (movesModel) selection = selectionOf(model->value(QLatin1String("instanceId")).toString(), model->value(QLatin1String("model")).toString());
    if (movesAccess) runtime = *access;
    if (movesMode) interaction = *mode;
    if (moves) ++revision;
    if (type == QLatin1String("message.dispatch")) took(command);
    QJsonObject answer{{QStringLiteral("sequence"), mc.commands.size()}};
    if (kind == Mc::Named && moves) {
      answer.insert(QStringLiteral("selectionRevision"), double(revision));
      ++named;
    }
    if (!moves) return mc.reply(rpc, answer);
    if (ackFirst) {
      mc.reply(rpc, answer);
      publish();
    } else {
      publish();
      mc.reply(rpc, answer);
    }
  }

  // The thread took a message: it runs what the composer showed.
  void took(const QJsonObject& command) {
    if (!submission) return violate(QStringLiteral("a message nobody sent, or one sent again after a refusal"));
    const Submission sent = *std::exchange(submission, std::nullopt);
    const bool carried = command.contains(QLatin1String("modelSelection"));
    if (carried && nameOf(command.value(QLatin1String("modelSelection")).toObject()) != sent.shown) {
      violate(QStringLiteral("the composer showed %1 and sent %2").arg(sent.shown, nameOf(command.value(QLatin1String("modelSelection")).toObject())));
    }
    if (!carried && sent.shown != sent.row) violate(QStringLiteral("the composer showed %1 and sent no model on %2").arg(sent.shown, sent.row));
    // A send with no pick runs on what the thread holds, a change from
    // elsewhere included; an MC without revisions cannot keep a send's pick
    // from one made elsewhere while it was on its way.
    const bool elsewhere = foreign.size() > sent.foreign || !sent.current;
    if (nameOf(selection) != sent.shown && !((!carried || kind == Mc::Old) && elsewhere)) {
      violate(QStringLiteral("the composer showed %1 and the thread runs %2").arg(sent.shown, nameOf(selection)));
    }
  }

  // Another client changes the thread.
  void elsewhere(const QString& field, const QString& value) {
    if (field == QLatin1String("model")) {
      const auto [instance, model] = kModels.at(value.toInt());
      selection = selectionOf(instance, model);
    } else if (field == QLatin1String("access")) {
      runtime = value;
    } else {
      interaction = value;
    }
    foreign.append(++revision);
    publish();
  }

  // A round trip, so what the client sent has been answered.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
  }

  // The send has reached the thread or been refused, and the client has
  // what the MC answered.
  void settle() {
    RC_ASSERT(prop::until([&] { return !submission || submission->refused; }));
    barrier();
    if (submission && submission->refused) {
      const QString text = submission->text;
      submission.reset();
      checkRefused(text);
    }
    barrier();
  }

  // A refused send comes back to the composer with a toast, and nothing goes on its own.
  void checkRefused(const QString& text) {
    const auto toasted = [&] {
      for (const QVariant& toast : bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        const QVariantMap item = toast.toMap();
        if (item.value(QStringLiteral("title")) == QLatin1String("Message not sent") &&
            item.value(QStringLiteral("description")).toString().endsWith(QLatin1String("elsewhere. Check it and send again."))) {
          return true;
        }
      }
      return false;
    };
    if (!prop::until([&] { return shown().value(QStringLiteral("text")).toString() == text && toasted(); })) {
      violate(QStringLiteral("a refused send left the composer with \"%1\" (sent \"%2\"), toasted %3")
                  .arg(shown().value(QStringLiteral("text")).toString(), text)
                  .arg(toasted()));
    }
  }
};

void verify(Sut& sut) {
  if (!sut.violations.isEmpty()) {
    qWarning().noquote() << sut.violations.join(QStringLiteral("\n"));
    RC_FAIL(sut.violations.first().toStdString());
  }
}

using Command = rc::state::Command<Model, Sut>;

struct PickModel : Command {
  int index = *rc::gen::inRange(0, int(kModels.size()));
  void run(const Model&, Sut& sut) const override {
    const auto [instance, model] = kModels.at(index);
    sut.pickedAt.insert(QStringLiteral("model"), sut.seen());
    sut.bridge->dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), instance}, {QStringLiteral("model"), model}});
    RC_ASSERT(prop::until([&] { return sut.shownModel() == instance + u'/' + model; }));
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "PickModel(" << kModels.at(index).second.toStdString() << ")"; }
};

struct PickInteraction : Command {
  QString mode = pick(kInteractions);
  void run(const Model&, Sut& sut) const override {
    sut.pickedAt.insert(QStringLiteral("interaction"), sut.seen());
    sut.bridge->dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    RC_ASSERT(prop::until([&] { return sut.shown().value(QStringLiteral("interactionMode")).toString() == mode; }));
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "PickInteraction(" << mode.toStdString() << ")"; }
};

// This client's own access change goes out at once, and moves the revision.
struct PickAccess : Command {
  QString mode = pick(kOwnAccess);
  bool ackFirst = *rc::gen::arbitrary<bool>();
  void run(const Model& m0, Sut& sut) const override {
    sut.ackFirst = ackFirst;
    sut.bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    if (!m0.holding) sut.barrier();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "PickAccess(" << mode.toStdString() << ", " << (ackFirst ? "answer first" : "row first") << ")"; }
};

// Another client changes the model, the access or the interaction mode.
struct Elsewhere : Command {
  QString field = pick({QStringLiteral("model"), QStringLiteral("access"), QStringLiteral("interaction")});
  int index = *rc::gen::inRange(0, int(kModels.size()));
  QString access = pick(kOtherAccess);
  void checkPreconditions(const Model& m) const override {
    // Without named revisions a change of this client's that moved nothing
    // looks like one that did, so a change elsewhere to the same value would
    // pass for it (ComposerController::pastOwn); access elsewhere never is.
    if (m.mc == Mc::Unnamed) RC_PRE(field == QLatin1String("access"));
  }
  void run(const Model&, Sut& sut) const override {
    QString value;
    if (field == QLatin1String("model")) {
      int next = index;
      if (nameOf(selectionOf(kModels.at(next).first, kModels.at(next).second)) == nameOf(sut.selection)) next = (next + 1) % int(kModels.size());
      value = QString::number(next);
    } else if (field == QLatin1String("access")) {
      value = access == sut.runtime ? kOtherAccess.at(1 - kOtherAccess.indexOf(access)) : access;
    } else {
      value = sut.interaction == QLatin1String("plan") ? QStringLiteral("default") : QStringLiteral("plan");
    }
    sut.elsewhere(field, value);
    sut.barrier();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "Elsewhere(" << field.toStdString() << ")"; }
};

struct Submit : Command {
  bool ackFirst = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.sending); }
  void apply(Model& m) const override { m.sending = m.holding; }
  void run(const Model& m0, Sut& sut) const override {
    static int sent = 0;
    const QString text = QStringLiteral("go %1").arg(++sent);
    sut.ackFirst = ackFirst;
    sut.submission = Submission{text, sut.shownModel(), sut.seenModel(), nameOf(sut.selection) == sut.seenModel(), sut.foreign.size()};
    sut.bridge->dispatch(QStringLiteral("composer.submit"),
                         QVariantMap{{QStringLiteral("text"), text}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    if (!m0.holding) sut.settle();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "Submit(" << (ackFirst ? "answer first" : "row first") << ")"; }
};

struct Hold : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.holding); }
  void apply(Model& m) const override { m.holding = true; }
  void run(const Model&, Sut& sut) const override { sut.mc.hold(QStringLiteral("answers")); }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The held answers go, in the order their commands came.
struct AnswerHeld : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.holding); }
  void apply(Model& m) const override {
    m.holding = false;
    m.sending = false;
  }
  void run(const Model&, Sut& sut) const override {
    sut.mc.answerHeld();
    sut.settle();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "AnswerHeld"; }
};

// Rows wait while answers go: an answer reaches the client before its row.
struct Lag : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.mc != Mc::Unnamed);
    RC_PRE(!m.lagging);
  }
  void apply(Model& m) const override { m.lagging = true; }
  void run(const Model&, Sut& sut) const override { sut.mc.lagRows = true; }
  void show(std::ostream& os) const override { os << "Lag"; }
};

struct CatchUp : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.lagging); }
  void apply(Model& m) const override { m.lagging = false; }
  void run(const Model&, Sut& sut) const override {
    sut.mc.catchUp();
    sut.barrier();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "CatchUp"; }
};

// The connection drops with nothing on its way, and the client connects again.
struct Reconnect : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.holding && !m.lagging && !m.sending); }
  void run(const Model&, Sut& sut) const override {
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return !sut.native->client()->isReady(); }));
    RC_ASSERT(prop::until([&] { return sut.online(); }));
    sut.barrier();
    verify(sut);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

void check(Mc kind) {
  Sut sut(kind);
  Model model;
  model.mc = kind;
  const auto commands = *rc::gen::scale(
      0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<PickModel, PickModel, PickInteraction, PickAccess, PickAccess, Elsewhere,
                                                                              Elsewhere, Submit, Submit, Submit, Hold, AnswerHeld, Lag, CatchUp, Reconnect>()));
  rc::state::runAll(commands, model, sut);
  // Whatever was held goes, and still holds.
  if (sut.mc.holding(QStringLiteral("answers"))) {
    sut.mc.answerHeld();
    sut.settle();
  }
  if (sut.mc.lagRows) sut.mc.catchUp();
  sut.barrier();
  verify(sut);
}

}  // namespace

class ComposerSelectionProp : public QObject {
  Q_OBJECT

private slots:
  void namedRevisions() {
    QVERIFY(rc::check("the send carries what the composer showed, and no choice the user did not make against the current revision (answers name revisions)",
                      [] { check(Mc::Named); }));
  }
  void countedRevisions() {
    QVERIFY(rc::check("the send carries what the composer showed, and no choice the user did not make against the current revision (answers name none)",
                      [] { check(Mc::Unnamed); }));
  }
  void noRevisions() {
    QVERIFY(rc::check("the send carries what the composer showed, to an MC without revisions", [] { check(Mc::Old); }));
  }
};

HAL_C2_PROP_MAIN(ComposerSelectionProp)
#include "tst_ComposerSelectionProp.moc"
