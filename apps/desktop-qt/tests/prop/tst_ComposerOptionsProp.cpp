// The options each model keeps in the composer (ComposerController::selectModel,
// setOption, selection), against a fake MC: the effort a model shows is the last one
// set or sent for it on this device, else the one its thread (or, for a new thread,
// the project) saved with it, else the provider's default, whatever is picked in
// between and however the provider's model list changes. A thread shows its own
// selection whether or not its account can run a turn. A new thread's account that
// cannot hands what it shows to another account of its driver that lists the model,
// failing that the first provider that can run. What a target shows never names a
// model under another provider.

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
// In the order the composer lists them: Codex's default account, a second Codex
// account, then Claude. The second account stays ready, so some provider always can run.
const QStringList kInstances{QStringLiteral("codex"), QStringLiteral("codexTeam"), QStringLiteral("claudeAgent")};
const QStringList kFlaky{QStringLiteral("codex"), QStringLiteral("claudeAgent")};

QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString driverOf(const QString& instance) { return instance == QLatin1String("claudeAgent") ? instance : QStringLiteral("codex"); }

// What an instance lists: the second account never lists `gpt-x`, the model that comes and goes.
QStringList modelsOf(const QString& instance, bool extra) {
  if (instance == QLatin1String("claudeAgent")) return {QStringLiteral("claude-a")};
  QStringList slugs{QStringLiteral("gpt-a"), QStringLiteral("gpt-b")};
  if (extra && instance == QLatin1String("codex")) slugs.prepend(QStringLiteral("gpt-x"));
  return slugs;
}

QJsonObject selectionOf(const QString& instance, const QString& model, const QString& effort) {
  return {{QStringLiteral("instanceId"), instance},
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

// An instance that is down still lists its models, as one whose sign-in lapsed does.
QJsonArray providers(bool extra, const QSet<QString>& down) {
  QJsonArray list;
  for (const QString& instance : kInstances) {
    QJsonArray models;
    for (const QString& slug : modelsOf(instance, extra)) {
      models.append(QJsonObject{{QStringLiteral("slug"), slug},
                                {QStringLiteral("name"), slug},
                                {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{effortDescriptor()}}}}});
    }
    list.append(QJsonObject{{QStringLiteral("instanceId"), instance},
                            {QStringLiteral("driver"), driverOf(instance)},
                            {QStringLiteral("enabled"), true},
                            {QStringLiteral("installed"), true},
                            {QStringLiteral("status"), down.contains(instance) ? QStringLiteral("error") : QStringLiteral("ready")},
                            {QStringLiteral("models"), models}});
  }
  return list;
}

// A model selection; no effort means it carries no options, so the provider's default shows.
struct Sel {
  QString instance;
  QString model;
  std::optional<QString> effort;
};

struct Model {
  QString open = QStringLiteral("t1");
  QMap<QString, Sel> picked;   // by target, once a pick or a change has set it
  QMap<QString, Sel> base;     // the thread's saved selection, or the project's default
  QMap<QString, QString> kept;  // the effort last set or sent, by instance and model
  QSet<QString> down;           // instances that cannot run a turn
  bool extra = false;
  Model() {
    base[QStringLiteral("t1")] = {QStringLiteral("codex"), QStringLiteral("gpt-a"), QStringLiteral("high")};
    base[QStringLiteral("t2")] = {QStringLiteral("claudeAgent"), QStringLiteral("claude-a"), QStringLiteral("high")};
    base[QStringLiteral("draft")] = {QStringLiteral("codex"), QStringLiteral("gpt-b"), QStringLiteral("high")};
  }
  static QString key(const QString& instance, const QString& model) { return instance + u'\n' + model; }
  bool isThread(const QString& target) const { return target != QLatin1String("draft"); }
  bool lists(const QString& instance, const QString& model) const { return modelsOf(instance, extra).contains(model); }
  std::optional<QString> keptFor(const QString& instance, const QString& model) const {
    const auto found = kept.constFind(key(instance, model));
    return found == kept.cend() ? std::nullopt : std::optional<QString>(*found);
  }
  Sel defaultOf(const QString& instance) const {
    const QString model = modelsOf(instance, extra).first();
    return {instance, model, keptFor(instance, model)};
  }
  // What the target shows. A thread keeps its own. A new thread's account that
  // is down hands its model to another ready account of the same driver that
  // lists it; failing that it starts on the first provider that can run.
  Sel selection(const QString& target) const {
    const Sel chosen = picked.value(target, base.value(target));
    if (isThread(target)) return chosen;
    if (!down.contains(chosen.instance)) {
      if (!lists(chosen.instance, chosen.model)) return defaultOf(chosen.instance);
      return chosen;
    }
    for (const QString& other : kInstances) {
      if (down.contains(other) || other == chosen.instance || driverOf(other) != driverOf(chosen.instance) || !lists(other, chosen.model)) continue;
      const std::optional<QString> own = keptFor(other, chosen.model);
      return {other, chosen.model, own ? own : chosen.effort};
    }
    for (const QString& other : kInstances) {
      if (!down.contains(other)) return defaultOf(other);
    }
    return {};
  }
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-options-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString draftId;
  bool extra = false;
  QSet<QString> down;

  Sut() {
    QJsonObject project{{QStringLiteral("id"), QStringLiteral("p1")},
                        {QStringLiteral("title"), QStringLiteral("Shop")},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("scripts"), QJsonArray()},
                        {QStringLiteral("defaultModelSelection"), selectionOf(QStringLiteral("codex"), QStringLiteral("gpt-b"), QStringLiteral("high"))}};
    mc.projects.insert(QStringLiteral("p1"), project);
    for (const auto& [id, instance, model] : {std::tuple{QStringLiteral("t1"), QStringLiteral("codex"), QStringLiteral("gpt-a")},
                                              std::tuple{QStringLiteral("t2"), QStringLiteral("claudeAgent"), QStringLiteral("claude-a")}}) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("modelSelection"), selectionOf(instance, model, QStringLiteral("high"))}});
    }
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers(extra, down)}, {QStringLiteral("settings"), QJsonObject()}}}});
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

  void republish() {
    for (const int id : mc.subscribers(QStringLiteral("config"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config.providers")}, {QStringLiteral("id"), id}, {QStringLiteral("providers"), providers(extra, down)}});
    }
    barrier();
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
  const Sel want = m.selection(m.open);
  const QString effort = want.effort.value_or(kEfforts.first());
  const auto agrees = [&] {
    const QVariantMap shown = sut.shown();
    return shown.value(QStringLiteral("selectedInstanceId")).toString() == want.instance &&
           shown.value(QStringLiteral("selectedModel")).toString() == want.model && sut.effort() == effort;
  };
  if (!prop::until(agrees)) {
    qWarning().noquote() << "shows" << sut.shown().value(QStringLiteral("selectedInstanceId")).toString()
                         << sut.shown().value(QStringLiteral("selectedModel")).toString() << sut.effort() << "expected" << want.instance
                         << want.model << effort;
    RC_FAIL("the composer shows another selection than the model");
  }
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

// A pick from the picker, which offers only a ready account's own models; any
// other pick is refused and changes nothing.
struct PickModel : Command {
  QString model = pick(kModels);
  QString instance = model.startsWith(QLatin1String("claude")) ? QStringLiteral("claudeAgent") : pick({QStringLiteral("codex"), QStringLiteral("codexTeam")});
  void apply(Model& m) const override {
    if (m.down.contains(instance) || !m.lists(instance, model)) return;
    // Its own effort when it has one, else what the composer shows or the target saved for it.
    std::optional<QString> effort = m.keptFor(instance, model);
    for (const Sel& held : {m.selection(m.open), m.base.value(m.open)}) {
      if (!effort && held.instance == instance && held.model == model) effort = held.effort;
    }
    m.picked[m.open] = {instance, model, effort};
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.model.select"), QVariantMap{{QStringLiteral("instanceId"), instance}, {QStringLiteral("model"), model}});
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "PickModel(" << instance.toStdString() << ", " << model.toStdString() << ")"; }
};

// An effort set on what the composer shows; refused while that account is down.
struct SetEffort : Command {
  QString value = pick(kEfforts);
  void apply(Model& m) const override {
    const Sel shown = m.selection(m.open);
    if (m.down.contains(shown.instance)) return;
    m.kept[Model::key(shown.instance, shown.model)] = value;
    m.picked[m.open] = {shown.instance, shown.model, value};
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.option.set"), QVariantMap{{QStringLiteral("id"), QStringLiteral("effort")}, {QStringLiteral("value"), value}});
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "SetEffort(" << value.toStdString() << ")"; }
};

// A message from a thread whose provider can run it: the effort it shows is kept
// for its model, and the MC moves the thread when it shows another account.
struct Send : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.isThread(m.open));
    RC_PRE(!m.down.contains(m.selection(m.open).instance));
  }
  void apply(Model& m) const override {
    const Sel shown = m.selection(m.open);
    if (shown.effort) m.kept[Model::key(shown.instance, shown.model)] = *shown.effort;
    if (shown.instance != m.base.value(m.open).instance) m.base[m.open] = shown;
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
  void apply(Model& m) const override { m.extra = !m.extra; }
  void run(const Model& m0, Sut& sut) const override {
    sut.extra = !sut.extra;
    sut.republish();
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "Relist"; }
};

// An account stops being able to run a turn (its sign-in lapsed, say), or can again.
struct Readiness : Command {
  QString instance = pick(kFlaky);
  void apply(Model& m) const override {
    if (!m.down.remove(instance)) m.down.insert(instance);
  }
  void run(const Model& m0, Sut& sut) const override {
    if (!sut.down.remove(instance)) sut.down.insert(instance);
    sut.republish();
    Model next = m0;
    apply(next);
    verify(next, sut);
  }
  void show(std::ostream& os) const override { os << "Readiness(" << instance.toStdString() << ")"; }
};

}  // namespace

class ComposerOptionsProp : public QObject {
  Q_OBJECT

private slots:
  void optionsFollowTheModel() {
    QVERIFY(rc::check("a model shows the effort last set or sent for it, else its thread's or project's, else the default, on whichever account can run it", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Open, PickModel, PickModel, SetEffort, SetEffort, Send, Relist, Readiness, Readiness>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerOptionsProp)
#include "tst_ComposerOptionsProp.moc"
