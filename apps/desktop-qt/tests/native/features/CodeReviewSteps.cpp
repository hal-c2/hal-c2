// The code-review plugin's own UI (features/source-control/agent-code-review.feature):
// its real package from plugins/code-review, drawn by the desktop against a fake
// of its MC part that publishes `reviews` and `threads` as the MC part does and
// answers the calls the UI makes.

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQuickItem>

#include "Harness.h"
#include "Plugins.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("code-review");
const QString kRepository = QStringLiteral("acme/api");

QString package() { return QDir(QStringLiteral(HAL_C2_FEATURES_DIR "/../plugins/code-review")).absolutePath(); }

// The MC part's state: what it watches and its reviews, by key.
struct FakeCodeReview {
  QJsonObject settings;
  QJsonArray watching;
  QString activation = QStringLiteral("selective");
  QStringList order;
  QHash<QString, QJsonObject> reviews;
};

FakeCodeReview& state(World& world) { return world.mc.part<FakeCodeReview>(); }

QString key(int number) { return QStringLiteral("%1#%2").arg(kRepository).arg(number); }

// What the MC part publishes: `reviews` for the page, and `threads`, each review
// thread's review, for the header and the row mark.
void publish(World& world) {
  FakeCodeReview& fake = state(world);
  QJsonArray reviews;
  QJsonObject threads;
  for (const QString& each : std::as_const(fake.order)) {
    const QJsonObject review = fake.reviews.value(each);
    reviews.append(review);
    const QString thread = review.value(QLatin1String("threadId")).toString();
    if (thread.isEmpty()) continue;
    QJsonObject fields;
    for (const char* field : {"key", "repository", "number", "title", "url", "headBranch", "baseBranch", "status", "verdict", "error", "publishError"}) {
      if (review.contains(QLatin1String(field))) fields.insert(QLatin1String(field), review.value(QLatin1String(field)));
    }
    threads.insert(thread, fields);
  }
  FakePluginPart& part = fakePluginPart(world, kId);
  part.topics.insert(QStringLiteral("reviews"), QJsonObject{{QStringLiteral("reviews"), reviews},
                                                           {QStringLiteral("problem"), QJsonValue::Null},
                                                           {QStringLiteral("unwatched"), QJsonArray()},
                                                           {QStringLiteral("watching"), fake.watching},
                                                           {QStringLiteral("activation"), fake.activation},
                                                           {QStringLiteral("checkedAt"), QStringLiteral("2026-10-07T09:00:00Z")}});
  part.topics.insert(QStringLiteral("threads"), threads);
  publishTopic(world, kId, QStringLiteral("reviews"));
  publishTopic(world, kId, QStringLiteral("threads"));
}

QJsonObject& add(World& world, int number, const QString& status, const QString& title = QStringLiteral("Add rate limits")) {
  FakeCodeReview& fake = state(world);
  const QString at = key(number);
  if (!fake.order.contains(at)) fake.order.append(at);
  QJsonObject& review = fake.reviews[at];
  review = {{QStringLiteral("key"), at},
            {QStringLiteral("repository"), kRepository},
            {QStringLiteral("number"), number},
            {QStringLiteral("title"), title},
            {QStringLiteral("author"), QStringLiteral("octocat")},
            {QStringLiteral("url"), QStringLiteral("https://github.com/%1/pull/%2").arg(kRepository).arg(number)},
            {QStringLiteral("headBranch"), QStringLiteral("feature/%1").arg(number)},
            {QStringLiteral("baseBranch"), QStringLiteral("main")},
            {QStringLiteral("headSha"), QStringLiteral("abc%1").arg(number)},
            {QStringLiteral("status"), status},
            {QStringLiteral("comments"), QJsonArray()}};
  if (status == QLatin1String("failed")) review.insert(QStringLiteral("error"), QStringLiteral("The agent gave no findings."));
  return review;
}

QJsonObject comment(const QString& id, int line, const QString& body) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("path"), QStringLiteral("src/limits.ts")}, {QStringLiteral("line"), line},
          {QStringLiteral("side"), QStringLiteral("new")}, {QStringLiteral("body"), body}, {QStringLiteral("dismissed"), false}};
}

// A finished review with a verdict, a summary and two comments.
void finish(QJsonObject& review, const QString& status, const QString& verdict) {
  review.insert(QStringLiteral("status"), status);
  review.insert(QStringLiteral("verdict"), verdict);
  review.insert(QStringLiteral("summary"), QStringLiteral("The limits are not checked per user."));
  review.insert(QStringLiteral("comments"), QJsonArray{comment(QStringLiteral("c1"), 12, QStringLiteral("This counts every user together.")),
                                                       comment(QStringLiteral("c2"), 30, QStringLiteral("The window never resets."))});
}

// A review with a thread of its own, in the thread list unless the reviews are
// only shown on the page.
void giveThread(World& world, QJsonObject& review, bool listed) {
  const QString thread = QStringLiteral("t-review-%1").arg(review.value(QLatin1String("number")).toInt());
  review.insert(QStringLiteral("threadId"), thread);
  addPluginThread(world, thread, QStringLiteral("Review %1").arg(review.value(QLatin1String("key")).toString()),
                  {{QStringLiteral("id"), kId}, {QStringLiteral("kind"), QStringLiteral("review")}, {QStringLiteral("listed"), listed}});
}

QJsonObject manifest() {
  QFile file(QDir(package()).filePath(QStringLiteral("plugin.json")));
  expect(file.open(QIODevice::ReadOnly), QStringLiteral("%1 cannot be read").arg(file.fileName()));
  return QJsonDocument::fromJson(file.readAll()).object();
}

// The plugin as the MC lists it: its manifest, running with its permissions granted.
QJsonObject entry(const QJsonObject& manifest, const QJsonObject& settings) {
  QJsonArray permissions;
  for (const QJsonValue& each : manifest.value(QLatin1String("permissions")).toArray()) {
    QJsonObject permission = each.toObject();
    permission.insert(QStringLiteral("label"), permission.value(QLatin1String("id")));
    permission.insert(QStringLiteral("granted"), true);
    permissions.append(permission);
  }
  return {{QStringLiteral("id"), kId},
          {QStringLiteral("name"), manifest.value(QLatin1String("name"))},
          {QStringLiteral("version"), manifest.value(QLatin1String("version"))},
          {QStringLiteral("description"), manifest.value(QLatin1String("description"))},
          {QStringLiteral("author"), manifest.value(QLatin1String("author")).toObject().value(QLatin1String("name"))},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("error"), QJsonValue::Null},
          {QStringLiteral("lastError"), QJsonValue::Null},
          {QStringLiteral("revision"), QStringLiteral("1")},
          {QStringLiteral("runsCode"), true},
          {QStringLiteral("permissions"), permissions},
          {QStringLiteral("settingsSchema"), manifest.value(QLatin1String("settings"))},
          {QStringLiteral("settings"), settings},
          {QStringLiteral("contributes"), manifest.value(QLatin1String("contributes"))}};
}

// The calls the UI makes, answered as the MC part answers them.
void answer(World& world, const FakeMc::Rpc& rpc) {
  FakeCodeReview& fake = state(world);
  const QString method = rpc.payload.value(QLatin1String("method")).toString();
  const QJsonObject input = rpc.payload.value(QLatin1String("input")).toObject();
  const QString at = input.value(QLatin1String("key")).toString();
  if (method == QLatin1String("settings")) {
    return world.mc.reply(rpc, QJsonObject{{QStringLiteral("settings"), fake.settings},
                                           {QStringLiteral("providers"), QJsonArray{QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
                                                                                                {QStringLiteral("name"), QStringLiteral("Claude")},
                                                                                                {QStringLiteral("models"), QJsonArray()}}}},
                                           {QStringLiteral("repositories"), QJsonArray{kRepository}}});
  }
  if (method == QLatin1String("start")) {
    QJsonObject& review = add(world, input.value(QLatin1String("number")).toInt(), QStringLiteral("running"));
    review.insert(QStringLiteral("repository"), input.value(QLatin1String("repository")));
    world.mc.reply(rpc, QJsonValue::Null);
    return publish(world);
  }
  if (!fake.reviews.contains(at)) return world.mc.refuse(rpc, QStringLiteral("no review %1").arg(at));
  QJsonObject& review = fake.reviews[at];
  if (method == QLatin1String("dismiss")) {
    QJsonArray comments = review.value(QLatin1String("comments")).toArray();
    for (QJsonValueRef each : comments) {
      QJsonObject comment = each.toObject();
      if (comment.value(QLatin1String("id")) == input.value(QLatin1String("commentId"))) comment.insert(QStringLiteral("dismissed"), input.value(QLatin1String("dismissed")));
      each = comment;
    }
    review.insert(QStringLiteral("comments"), comments);
  } else if (method == QLatin1String("publish")) {
    review.insert(QStringLiteral("status"), QStringLiteral("published"));
    review.insert(QStringLiteral("publishedAt"), QStringLiteral("2026-10-07T09:30:00Z"));
  } else {
    return world.mc.refuse(rpc, QStringLiteral("no such call"));
  }
  world.mc.reply(rpc, QJsonValue::Null);
  publish(world);
}

// The calls of `method` the UI made, with their input.
QList<QJsonObject> asked(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("plugins.call") && rpc.payload.value(QLatin1String("method")) == method) found.append(rpc.payload.value(QLatin1String("input")).toObject());
  }
  return found;
}

// The review's row on the page.
QQuickItem* row(World& world, int number) { return waitShownNamed(world, QStringLiteral("codeReview:") + key(number)); }

QString textOf(World& world, const QString& objectName) { return waitShownNamed(world, objectName)->property("text").toString(); }

void waitText(World& world, const QString& objectName, const QString& text) {
  world.waitFor([&] { return textOf(world, objectName) == text; },
                [&] { return QStringLiteral("%1 to say %2, not %3").arg(objectName, text, textOf(world, objectName)); });
}

void click(World& world, QQuickItem* item) {
  world.waitFor([&] { return item->isEnabled(); }, QStringLiteral("%1 to be enabled").arg(item->objectName()));
  clickItem(world, item);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("an MC running the plugin %1 with GitHub as its host").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kId, QStringLiteral("only %1 is faked").arg(kId));
    const QJsonObject read = manifest();
    QJsonObject settings;
    for (const QJsonValue& each : read.value(QLatin1String("settings")).toArray()) {
      settings.insert(each.toObject().value(QLatin1String("key")).toString(), each.toObject().value(QLatin1String("default")));
    }
    settings.insert(QStringLiteral("host"), QStringLiteral("github"));
    state(world).settings = settings;
    FakePluginPart part;
    part.package = package();
    part.call = [&world](const FakeMc::Rpc& rpc) { answer(world, rpc); };
    runFakePlugin(world, entry(read, settings), part);
    publish(world);
  });
  // The MC part finds the repository's project itself; the client sees only what it watches.
  step(QStringLiteral("the project %1 whose remote is %1 on GitHub").arg(q), [](World&, const Captures&, const Table&) {});

  step(QStringLiteral("reviews of #(\\d+) running, #(\\d+) waiting to be published and #(\\d+) failed"), [](World& world, const Captures& c, const Table&) {
    add(world, c[0].toInt(), QStringLiteral("running"));
    finish(add(world, c[1].toInt(), QStringLiteral("waiting"), QStringLiteral("Cache the session")), QStringLiteral("waiting"), QStringLiteral("comment"));
    add(world, c[2].toInt(), QStringLiteral("failed"), QStringLiteral("Bump the parser"));
    publish(world);
  });
  step(QStringLiteral("#(\\d+), #(\\d+) and #(\\d+) are listed with their states"), [](World& world, const Captures& c, const Table&) {
    const QStringList states{QStringLiteral("Reviewing"), QStringLiteral("Waiting to publish"), QStringLiteral("Failed")};
    qreal above = -1;
    for (int i = 0; i < 3; ++i) {
      QQuickItem* listed = row(world, c[i].toInt());
      // Each state's first review names it, above the review.
      expect(drawsText(listed->parentItem(), states[i]), QStringLiteral("#%1 is not under %2").arg(c[i], states[i]));
      const qreal y = listed->mapToScene(QPointF()).y();
      expect(y > above, QStringLiteral("#%1 is listed out of order").arg(c[i]));
      above = y;
    }
  });

  step(QStringLiteral("the review of #(\\d+) is waiting with two comments"), [](World& world, const Captures& c, const Table&) {
    finish(add(world, c[0].toInt(), QStringLiteral("waiting")), QStringLiteral("waiting"), QStringLiteral("request-changes"));
    publish(world);
  });
  step(QStringLiteral("the user opens the review of #(\\d+) on the %1 page").arg(q), [](World& world, const Captures& c, const Table&) {
    switchToTab(world, c[1]);
    click(world, row(world, c[0].toInt()));
    waitText(world, QStringLiteral("codeReviewTitle"), QStringLiteral("#%1  Add rate limits").arg(c[0]));
  });
  step(QStringLiteral("its verdict, summary and comments are shown"), [](World& world, const Captures&, const Table&) {
    waitText(world, QStringLiteral("codeReviewVerdict"), QStringLiteral("Request changes"));
    const QString summary = textOf(world, QStringLiteral("codeReviewSummary"));
    expect(summary.contains(QLatin1String("not checked per user")), QStringLiteral("the summary says %1").arg(summary));
    for (const auto& [id, where] : {std::pair{QStringLiteral("c1"), QStringLiteral("src/limits.ts:12")}, std::pair{QStringLiteral("c2"), QStringLiteral("src/limits.ts:30")}}) {
      expect(drawsText(waitShownNamed(world, QStringLiteral("codeReviewComment:") + id), where), QStringLiteral("comment %1 is not on %2").arg(id, where));
    }
  });
  step(QStringLiteral("the user can publish it or dismiss comments"), [](World& world, const Captures&, const Table&) {
    // A changed review draws its comments again.
    const auto dismiss = [&] { return findNamed(waitShownNamed(world, QStringLiteral("codeReviewComment:c1")), QStringLiteral("codeReviewDismiss")); };
    click(world, dismiss());
    world.waitFor([&] { return dismiss()->property("text") == QStringLiteral("Keep"); }, QStringLiteral("the comment to be dismissed"));
    const QJsonObject dismissed = asked(world, QStringLiteral("dismiss")).value(0);
    expect(dismissed == QJsonObject{{QStringLiteral("key"), key(13)}, {QStringLiteral("commentId"), QStringLiteral("c1")}, {QStringLiteral("dismissed"), true}},
           QStringLiteral("the MC was asked %1").arg(show(dismissed)));

    click(world, waitShownNamed(world, QStringLiteral("codeReviewPublish")));
    world.waitFor([&] { return textOf(world, QStringLiteral("codeReviewStatus")).startsWith(QLatin1String("Published")); },
                  [&] { return textOf(world, QStringLiteral("codeReviewStatus")); });
    expect(asked(world, QStringLiteral("publish")) == QList<QJsonObject>{{{QStringLiteral("key"), key(13)}}}, QStringLiteral("the review was not published once"));
  });

  step(QStringLiteral("the review of #(\\d+) finished with the verdict %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[1] == QLatin1String("approved"), QStringLiteral("no verdict %1").arg(c[1]));
    QJsonObject& review = add(world, c[0].toInt(), QStringLiteral("waiting"), QStringLiteral("Cache the session"));
    finish(review, QStringLiteral("waiting"), QStringLiteral("approve"));
    giveThread(world, review, true);
    publish(world);
  });
  step(QStringLiteral("the user opens the review's thread"), [](World& world, const Captures&, const Table&) {
    openPluginThread(world, state(world).reviews.value(state(world).order.last()).value(QLatin1String("threadId")).toString());
  });
  step(QStringLiteral("the pull request, the verdict and the publish action are shown above the conversation"), [](World& world, const Captures&, const Table&) {
    QQuickItem* header = waitShownNamed(world, QStringLiteral("codeReviewHeader"));
    expect(findNamed(waitShownNamed(world, QStringLiteral("pluginThreadHeader")), QStringLiteral("codeReviewHeader")) == header,
           QStringLiteral("the header is not the thread's"));
    world.waitFor([&] { return findNamed(header, QStringLiteral("codeReviewPullRequest"))->property("text") == QStringLiteral("Review of #13 Cache the session"); },
                  [&] { return findNamed(header, QStringLiteral("codeReviewPullRequest"))->property("text").toString(); });
    expect(findNamed(header, QStringLiteral("codeReviewVerdict"))->property("text") == QStringLiteral("Approve"), QStringLiteral("the verdict is not shown"));
    expect(findNamed(header, QStringLiteral("codeReviewPublish"))->isVisible(), QStringLiteral("the review cannot be published"));
  });

  step(QStringLiteral("%1 shows reviews as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    state(world).settings.insert(QStringLiteral("display"), c[1]);
  });
  step(QStringLiteral("#(\\d+) is reviewed"), [](World& world, const Captures& c, const Table&) {
    QJsonObject& review = add(world, c[0].toInt(), QStringLiteral("running"));
    giveThread(world, review, state(world).settings.value(QLatin1String("display")) != QLatin1String("page"));
    publish(world);
  });
  step(QStringLiteral("its thread is listed with the review mark and the state of the review"), [](World& world, const Captures&, const Table&) {
    const auto marked = [&](const QString& text) {
      QQuickItem* mark = nullptr;
      world.waitFor([&] {
        QQuickItem* host = waitShownNamed(world, QStringLiteral("pluginRowMark"));
        return (mark = findNamed(host, QStringLiteral("codeReviewRowMark"))) && drawsText(mark, text);
      }, [&] { return QStringLiteral("the row mark to say %1").arg(text); });
    };
    marked(QStringLiteral("Reviewing"));
    // The mark follows the review.
    finish(state(world).reviews[state(world).order.last()], QStringLiteral("waiting"), QStringLiteral("approve"));
    publish(world);
    marked(QStringLiteral("Approve"));
  });

  step(QStringLiteral("%1 watches %1 selectively").arg(q), [](World& world, const Captures& c, const Table&) {
    state(world).watching = QJsonArray{c[1]};
    state(world).activation = QStringLiteral("selective");
    publish(world);
  });
  step(QStringLiteral("the user starts a review of #(\\d+) from the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    switchToTab(world, c[1]);
    QQuickItem* number = waitShownNamed(world, QStringLiteral("codeReviewStartNumber"));
    number->setProperty("text", c[0]);
    click(world, waitShownNamed(world, QStringLiteral("codeReviewStart")));
  });
  step(QStringLiteral("the review of #(\\d+) is listed as running"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject started{{QStringLiteral("repository"), kRepository}, {QStringLiteral("number"), c[0].toInt()}};
    world.waitFor([&] { return asked(world, QStringLiteral("start")) == QList<QJsonObject>{started}; },
                  [&] { return QStringLiteral("a review of #%1 to be started, not %2").arg(c[0], show(QJsonArray{asked(world, QStringLiteral("start")).value(0)})); });
    expect(drawsText(row(world, c[0].toInt())->parentItem(), QStringLiteral("Reviewing")), QStringLiteral("#%1 is not listed as running").arg(c[0]));
    waitText(world, QStringLiteral("codeReviewTitle"), QStringLiteral("#%1  Add rate limits").arg(c[0]));
  });

  step(QStringLiteral("GitHub, GitLab, Forgejo, Bitbucket and Azure DevOps are offered as hosts"), [](World& world, const Captures&, const Table&) {
    QQuickItem* hosts = waitShownNamed(world, QStringLiteral("codeReviewHosts"));
    for (const auto& [value, label] : {std::pair{QStringLiteral("github"), QStringLiteral("GitHub")}, std::pair{QStringLiteral("gitlab"), QStringLiteral("GitLab (coming later)")},
                                       std::pair{QStringLiteral("forgejo"), QStringLiteral("Forgejo (coming later)")},
                                       std::pair{QStringLiteral("bitbucket"), QStringLiteral("Bitbucket (coming later)")},
                                       std::pair{QStringLiteral("azure-devops"), QStringLiteral("Azure DevOps (coming later)")}}) {
      QQuickItem* option = findNamed(hosts, QStringLiteral("choice:") + value);
      expect(option && drawsText(option, label), QStringLiteral("%1 is not offered").arg(label));
    }
  });
  step(QStringLiteral("only GitHub can be chosen today"), [](World& world, const Captures&, const Table&) {
    QQuickItem* settings = waitShownNamed(world, QStringLiteral("codeReviewSettings"));
    QQuickItem* hosts = waitShownNamed(world, QStringLiteral("codeReviewHosts"));
    clickItem(world, findNamed(hosts, QStringLiteral("choice:gitlab")));
    world.sync();
    expect(settings->property("values").toMap().value(QStringLiteral("host")) == QStringLiteral("github") && !settings->property("dirty").toBool(),
           QStringLiteral("GitLab was chosen"));
    expect(findNamed(hosts, QStringLiteral("choice:github"))->property("chosen").toBool(), QStringLiteral("GitHub is not the host"));
  });
});

}  // namespace
