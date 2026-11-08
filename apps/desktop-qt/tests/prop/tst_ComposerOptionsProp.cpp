// The options each model keeps in the composer (ComposerController::selectModel,
// setOption), against a fake MC: the effort a model shows is the last one set or
// sent for it on this device, else the one its thread (or, for a new thread, the
// project) saved with it, else the provider's default, whatever is picked in
// between and however the provider's model list changes. What a thread shows
// never names a model under another provider.

#include <QJsonArray>
#include <QJsonObject>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"

namespace prop = halc2::prop;

namespace {

const QStringList kTargets{QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("draft")};
const QStringList kModels{QStringLiteral("gpt-a"), QStringLiteral("gpt-b"), QStringLiteral("claude-a")};
const QStringList kEfforts{QStringLiteral("low"), QStringLiteral("high")};

QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString instanceOf(const QString& model) {
  return model.startsWith(QLatin1String("claude")) ? QStringLiteral("claudeAgent") : QStringLiteral("codex");
}

QJsonObject selectionOf(const QString& model, const QString& effort) {
  return {{QStringLiteral("instanceId"), instanceOf(model)},
          {QStringLiteral("model"), model},
          {QStringLiteral("options"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("effort")}, {QStringLiteral("value"), effort}}}}};
}

QJsonObject effortDescriptor() {
  QJsonArray choices;
  for (const QString& level : kEfforts) {
    choices.append(QJsonObject{{QStringLiteral("id"), level}, {QStringLiteral("label"), level}, {QStringLiteral("isDefault"), level == kEfforts.first()}});
  }
  return {{QStringLiteral("id"), QStringLiteral("effort")},
          {QStringLiteral("label"), QStringLiteral("Effort")},
          {QStringLiteral("type"), QStringLiteral("select")},
          {QStringLiteral("options"), choices},
          {QStringLiteral("currentValue"), kEfforts.first()}};
}

// Codex's models, then Claude's; `extra` is a Codex model that comes and goes.
QJsonArray providers(bool extra) {
  QJsonArray list;
  for (const QString& instance : {QStringLiteral("codex"), QStringLiteral("claudeAgent")}) {
    QStringList slugs;
    for (const QString& model : kModels) {
      if (instanceOf(model) == instance) slugs.append(model);
    }
    if (extra && instance == QLatin1String("codex")) slugs.prepend(QStringLiteral("gpt-x"));
    QJsonArray models;
    for (const QString& slug : slugs) {
      models.append(QJsonObject{{QStringLiteral("slug"), slug},
                                {QStringLiteral("name"), slug},
                                {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{effortDescriptor()}}}}});
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

// What a target starts with: its thread's saved selection, or the project's default.
struct Base {
  QString model;
  QString effort;
};

struct Model {
  QString open = QStringLiteral("t1");
  QMap<QString, QString> picked;  // by target
  QMap<QString, QString> given;   // the effort last set or sent for a model
  QSet<QString> bare;  // targets showing a model the default alone fills in: nothing is kept for it
  QMap<QString, QString> shownEffort;  // by target, once a pick or a change has set it
  QMap<QString, Base> base;
  Model() {
    base[QStringLiteral("t1")] = {QStringLiteral("gpt-a"), QStringLiteral("high")};
    base[QStringLiteral("t2")] = {QStringLiteral("claude-a"), QStringLiteral("high")};
    base[QStringLiteral("draft")] = {QStringLiteral("gpt-b"), QStringLiteral("high")};
  }
  bool isThread(const QString& target) const { return target != QLatin1String("draft"); }
  QString model(const QString& target) const { return picked.value(target, base.value(target).model); }
  // What choosing `shown` in `target` gives: the effort kept for it, else the target's own, else the default.
  QString chosen(const QString& target, const QString& shown) const {
    if (given.contains(shown)) return given.value(shown);
    return shown == base.value(target).model ? base.value(target).effort : kEfforts.first();
  }
  QString effort(const QString& target) const {
    return shownEffort.contains(target) ? shownEffort.value(target) : base.value(target).effort;
  }
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-options-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString draftId;
  bool extra = false;

  Sut() {
    QJsonObject project{{QStringLiteral("id"), QStringLiteral("p1")},
                        {QStringLiteral("title"), QStringLiteral("Shop")},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("scripts"), QJsonArray()},
                        {QStringLiteral("defaultModelSelection"), selectionOf(QStringLiteral("gpt-b"), QStringLiteral("high"))}};
    mc.projects.insert(QStringLiteral("p1"), project);
    for (const auto& [id, model] : {std::pair{QStringLiteral("t1"), QStringLiteral("gpt-a")}, std::pair{QStringLiteral("t2"), QStringLiteral("claude-a")}}) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("modelSelection"), selectionOf(model, QStringLiteral("high"))}});
    }
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers(extra)}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), QJsonArray()}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 0},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    // A provider change moves the thread, as the MC's projection does.
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("provider.switch")) return;
      const QString thread = command.value(QLatin1String("threadId")).toString();
      QJsonObject row = mc.threads.value(thread);
      row.insert(QStringLiteral("modelSelection"), command.value(QLatin1String("modelSelection")));
      mc.threads.insert(thread, row);
      mc.sendRow(thread, row);
    });
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] {
      return native->isActive() && native->client()->isReady() && mc.connected() &&
             native->store()->threadOnline(QStringLiteral("env-a:t1")) && native->store()->threadOnline(QStringLiteral("env-a:t2"));
    }));
    draftId = native->controller<DraftController>()->start(mc.environmentId, QStringLiteral("p1"));
    open(QStringLiteral("t1"));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  void open(const QString& target) {
    if (target == QLatin1String("draft")) {
      bridge->dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), draftId}});
    } else {
      bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), QStringLiteral("env-a:") + target}});
    }
  }

  QVariantMap shown() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }

  QString effort() const {
    for (const QVariant& option : shown().value(QStringLiteral("options")).toList()) {
      if (option.toMap().value(QStringLiteral("id")) == QLatin1String("effort")) return option.toMap().value(QStringLiteral("value")).toString();
    }
    return {};
  }

  // A round trip, so what the client sent has been answered.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
  }
};

void verify(const Model& m, Sut& sut) {
  const QString key = m.open == QLatin1String("draft") ? sut.draftId : QStringLiteral("env-a:") + m.open;
  RC_ASSERT(prop::until([&] { return sut.shown().value(QStringLiteral("target")).toString() == key; }));
  const bool agrees = prop::until([&] { return sut.shown().value(QStringLiteral("selectedModel")).toString() == m.model(m.open) && sut.effort() == m.effort(m.open); });
  if (!agrees) {
    qWarning().noquote() << "shows" << sut.shown().value(QStringLiteral("selectedModel")).toString() << sut.effort() << "expected" << m.model(m.open) << m.effort(m.open);
  }
  RC_ASSERT(agrees);
  // The instance named is the model's own provider.
  RC_ASSERT(sut.shown().value(QStringLiteral("selectedInstanceId")).toString() == instanceOf(m.model(m.open)));
}

using Command = rc::state::Command<Model, Sut>;

struct Open : Command {
  QString target = pick(kTargets);
  void apply(Model& m) const override { m.open = target; }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(target);
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "Open(" << target.toStdString() << ")"; }
};

struct PickModel : Command {
  QString model = pick(kModels);
  void apply(Model& m) const override {
    m.picked[m.open] = model;
    m.shownEffort[m.open] = m.chosen(m.open, model);
    if (m.given.contains(model) || model == m.base.value(m.open).model) {
      m.bare.remove(m.open);
    } else {
      m.bare.insert(m.open);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.model.select"),
                         QVariantMap{{QStringLiteral("instanceId"), instanceOf(model)}, {QStringLiteral("model"), model}});
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "PickModel(" << model.toStdString() << ")"; }
};

struct SetEffort : Command {
  QString value = pick(kEfforts);
  void apply(Model& m) const override {
    m.given[m.model(m.open)] = value;
    m.shownEffort[m.open] = value;
    m.bare.remove(m.open);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.option.set"), QVariantMap{{QStringLiteral("id"), QStringLiteral("effort")}, {QStringLiteral("value"), value}});
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "SetEffort(" << value.toStdString() << ")"; }
};

// A message from a thread: the model and effort it shows are kept for the model, and
// the MC moves the thread to them when they are another provider's.
struct Send : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.isThread(m.open)); }
  void apply(Model& m) const override {
    const QString shown = m.model(m.open);
    const QString effort = m.effort(m.open);
    if (!m.bare.contains(m.open)) m.given[shown] = effort;
    if (instanceOf(shown) != instanceOf(m.base.value(m.open).model)) m.base[m.open] = {shown, effort};
    m.shownEffort[m.open] = effort;
  }
  void run(const Model& m0, Sut& sut) const override {
    const qsizetype before = sut.mc.commands.size();
    sut.bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("go")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    RC_ASSERT(prop::until([&] {
      return std::any_of(sut.mc.commands.cbegin() + before, sut.mc.commands.cend(), [](const QJsonObject& c) { return c.value(QLatin1String("type")) == QLatin1String("message.dispatch"); });
    }));
    sut.barrier();
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "Send"; }
};

// The provider lists another Codex model, or stops.
struct Relist : Command {
  void apply(Model&) const override {}
  void run(const Model& m0, Sut& sut) const override {
    sut.extra = !sut.extra;
    for (const int id : sut.mc.subscribers(QStringLiteral("config"))) {
      sut.mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers(sut.extra)}});
    }
    sut.barrier();
    verify(m0, sut);
  }
  void show(std::ostream& os) const override { os << "Relist"; }
};

}  // namespace

class ComposerOptionsProp : public QObject {
  Q_OBJECT

private slots:
  void optionsFollowTheModel() {
    QVERIFY(rc::check("a model shows the effort last set or sent for it, else its thread's or project's, else the default", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Open, PickModel, PickModel, SetEffort, SetEffort, Send, Relist>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerOptionsProp)
#include "tst_ComposerOptionsProp.moc"
