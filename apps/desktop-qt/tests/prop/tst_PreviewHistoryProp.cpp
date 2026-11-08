// The pages a new browser tab suggests (src/native/PreviewHistory), over any
// order of visits, removals and the device saving and reading them back: each
// project lists every tidy address once, the newest first, a visit no newer
// than what is kept changes nothing, a page taken off comes back only with a
// later visit, a tab only showing a page it loaded before neither moves nor
// retimes it, the pages kept before visits were timed sit below every visit,
// a project keeps its fifty newest pages and the device the twenty projects
// used last, and what is saved reads back as it was.

#include "Prop.h"

#include <algorithm>
#include <string>
#include <tuple>
#include <vector>

#include "PreviewHistory.h"

namespace {

// An address as a tab reports it, and the one it is kept under.
struct Address {
  std::string url;
  std::string tidy;
};

std::vector<Address> addresses() {
  std::vector<Address> all;
  const std::vector<std::pair<std::string, std::string>> hosts{
      {"localhost", "localhost"}, {"127.0.0.1", "localhost"}, {"example.com", "example.com"}, {"user:secret@example.com", "example.com"}};
  const std::vector<std::pair<std::string, std::string>> paths{{"", ""}, {"/", ""}, {"/docs", "/docs"}, {"/docs?page=2", "/docs?page=2"}};
  for (const std::string scheme : {"http", "https"}) {
    for (const auto& [host, tidyHost] : hosts) {
      for (const std::string port : {"", ":5173"}) {
        for (const auto& [path, tidyPath] : paths) {
          all.push_back({scheme + "://" + host + port + path, scheme + "://" + tidyHost + port + tidyPath});
        }
      }
    }
  }
  // Not a page a tab is kept for.
  all.push_back({"ftp://example.com/docs", ""});
  all.push_back({"about:blank", ""});
  return all;
}

const std::vector<Address> kAddresses = addresses();

std::string projectKey(int n) {
  return "env-a:project-" + std::to_string(n);
}

struct Entry {
  std::string url;
  std::string title;
  qint64 at = 0;
  qint64 titled = 0;  // when the title was reported
  bool removed = false;
  long seq = 0;  // when it was put in place
};

struct Project {
  std::string key;
  qint64 used = 0;
  long seq = 0;
  std::vector<Entry> entries;
};

struct Model {
  std::vector<Project> projects;  // the one used last first
  qint64 now = PreviewHistory::timedSince + 1000;  // pages kept untimed are older
  long seq = 0;

  Project* find(const std::string& key) {
    for (Project& project : projects) {
      if (project.key == key) return &project;
    }
    return nullptr;
  }

  // Newest first, the last put in place first on a tie; the newest fifty
  // pages, fifty pages taken off, and none taken off before a full list's oldest.
  static void order(Project& project) {
    std::sort(project.entries.begin(), project.entries.end(),
              [](const Entry& a, const Entry& b) { return a.at != b.at ? a.at > b.at : a.seq > b.seq; });
    std::vector<Entry> kept;
    int pages = 0;
    int removed = 0;
    for (const Entry& entry : project.entries) {
      if (!entry.removed ? pages++ < PreviewHistory::pagesPerProject : removed++ < PreviewHistory::pagesPerProject) kept.push_back(entry);
    }
    if (pages >= PreviewHistory::pagesPerProject) {
      qint64 oldest = 0;
      int seen = 0;
      for (const Entry& entry : kept) {
        if (!entry.removed && ++seen == PreviewHistory::pagesPerProject) oldest = entry.at;
      }
      std::erase_if(kept, [&](const Entry& entry) { return entry.removed && entry.at < oldest; });
    }
    project.entries = kept;
  }

  void put(Project& project, Entry entry) {
    std::erase_if(project.entries, [&](const Entry& kept) { return kept.url == entry.url; });
    entry.seq = ++seq;
    project.entries.push_back(entry);
    order(project);
  }

  void visit(const std::string& key, const Address& address, const std::string& title, qint64 at) {
    if (address.tidy.empty()) return;
    Project project = find(key) ? *find(key) : Project{key, at, 0, {}};
    Entry entry{address.tidy, title, at, at, false, 0};
    for (const Entry& known : project.entries) {
      if (known.url != address.tidy) continue;
      if (at < known.at || (known.removed && at == known.at)) return;
      if (title.empty() && !known.removed) entry.title = known.title;
    }
    put(project, entry);
    project.used = std::max(project.used, at);
    project.seq = ++seq;
    std::erase_if(projects, [&](const Project& kept) { return kept.key == key; });
    projects.push_back(project);
    std::sort(projects.begin(), projects.end(), [](const Project& a, const Project& b) { return a.used != b.used ? a.used > b.used : a.seq > b.seq; });
    if (projects.size() > size_t(PreviewHistory::projectsKept)) projects.resize(PreviewHistory::projectsKept);
  }

  void seen(const std::string& key, const Address& address, const std::string& title, qint64 at) {
    if (address.tidy.empty()) return;
    if (Project* project = find(key)) {
      for (Entry& known : project->entries) {
        if (known.url != address.tidy) continue;
        if (!known.removed && !title.empty() && title != known.title && at >= known.titled) {
          known.title = title;
          known.titled = at;
        }
        return;
      }
    }
    visit(key, address, title, at);
  }

  void remove(const std::string& key, const Address& address, qint64 at) {
    Project* project = find(key);
    if (!project || address.tidy.empty()) return;
    for (const Entry& known : project->entries) {
      if (known.url == address.tidy && !known.removed) {
        put(*project, Entry{address.tidy, "", std::max(at, known.at), std::max(at, known.at), true, 0});
        return;
      }
    }
  }
};

struct Sut {
  PreviewHistory history;
};

using Command = rc::state::Command<Model, Sut>;

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

void check(const Model& model, const Sut& sut) {
  QStringList keys;
  for (const Project& project : model.projects) keys.append(q(project.key));
  RC_ASSERT(sut.history.projects() == keys);
  for (const Project& project : model.projects) {
    QStringList expected;
    for (const Entry& entry : project.entries) {
      if (!entry.removed) expected.append(QStringLiteral("%1 %2 %3").arg(q(entry.url), q(entry.title)).arg(entry.at));
    }
    QStringList kept;
    for (const PreviewHistory::Page& page : sut.history.pages(q(project.key))) kept.append(QStringLiteral("%1 %2 %3").arg(page.url, page.title).arg(page.at));
    RC_ASSERT(kept == expected);
  }
  // Pages of a project not kept are forgotten.
  RC_ASSERT(sut.history.pages(q(projectKey(99))).isEmpty());
}

// A tab of a project loads a page, some time around the last.
struct Visit : Command {
  int project = *rc::gen::inRange(0, 23);
  Address address = *rc::gen::elementOf(kAddresses);
  std::string title = *rc::gen::element(std::string(), std::string("Docs"), std::string("Home"));
  qint64 delta = *rc::gen::inRange(-3, 4);

  explicit Visit(const Model&) {}

  void apply(Model& model) const override {
    const qint64 at = model.now + delta;
    model.now = std::max(model.now, at);
    model.visit(projectKey(project), address, title, at);
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    const bool changed = sut.history.visit(q(projectKey(project)), q(address.url), q(title), model.now + delta);
    if (address.tidy.empty()) RC_ASSERT(!changed);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Visit(" << project << ", " << address.url << ", \"" << title << "\", " << delta << ")"; }
};

// A tab shows a page it loaded before: listed again, resized, or its back and forward changed.
struct Seen : Command {
  int project = *rc::gen::inRange(0, 23);
  Address address = *rc::gen::elementOf(kAddresses);
  std::string title = *rc::gen::element(std::string(), std::string("Docs"), std::string("Home"));
  qint64 delta = *rc::gen::inRange(-3, 4);

  // Mostly a page the model keeps, as a tab shows what it loaded.
  explicit Seen(const Model& model) {
    std::vector<std::pair<int, Address>> kept;
    for (int n = 0; n < 24; ++n) {
      for (const Project& known : model.projects) {
        if (known.key != projectKey(n)) continue;
        for (const Entry& entry : known.entries) {
          for (const Address& candidate : kAddresses) {
            if (candidate.tidy == entry.url) kept.emplace_back(n, candidate);
          }
        }
      }
    }
    if (!kept.empty() && *rc::gen::inRange(0, 4) > 0) std::tie(project, address) = *rc::gen::elementOf(kept);
  }

  void apply(Model& model) const override {
    const qint64 at = model.now + delta;
    model.now = std::max(model.now, at);
    model.seen(projectKey(project), address, title, at);
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    const QString key = q(projectKey(project));
    const auto places = [&] {
      QStringList list;
      for (const PreviewHistory::Page& page : sut.history.pages(key)) list.append(QStringLiteral("%1 %2").arg(page.url).arg(page.at));
      return list;
    };
    const QStringList before = places();
    const QStringList projects = sut.history.projects();
    sut.history.seen(key, q(address.url), q(title), model.now + delta);
    // A page kept, or taken off, keeps its time and its place, and so does its project.
    const bool known = std::ranges::any_of(model.projects, [&](const Project& kept) {
      return kept.key == projectKey(project) && std::ranges::any_of(kept.entries, [&](const Entry& entry) { return entry.url == address.tidy; });
    });
    if (known) {
      RC_ASSERT(places() == before);
      RC_ASSERT(sut.history.projects() == projects);
    }
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Seen(" << project << ", " << address.url << ", \"" << title << "\", " << delta << ")"; }
};

// The device kept recent pages before it kept them per project: the first project shown takes them.
struct Untimed : Command {
  int project = *rc::gen::inRange(0, 23);
  std::vector<Address> pages = *rc::gen::container<std::vector<Address>>(*rc::gen::inRange(0, 11), rc::gen::elementOf(kAddresses));

  explicit Untimed(const Model&) {}

  void apply(Model& model) const override {
    for (size_t at = pages.size(); at-- > 0;) model.visit(projectKey(project), pages[at], "", qint64(pages.size() - at));
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    QStringList urls;
    for (const Address& page : pages) urls.append(q(page.url));
    sut.history.keepUntimed(q(projectKey(project)), urls);
    // Below every page visited since visits were timed.
    bool untimed = false;
    for (const PreviewHistory::Page& page : sut.history.pages(q(projectKey(project)))) {
      if (page.at < PreviewHistory::timedSince) untimed = true;
      else RC_ASSERT(!untimed);
    }
    check(expected, sut);
  }

  void show(std::ostream& os) const override {
    os << "Untimed(" << project;
    for (const Address& page : pages) os << ", " << page.url;
    os << ")";
  }
};

// The user takes a page off a project's list.
struct Remove : Command {
  int project = *rc::gen::inRange(0, 23);
  Address address = *rc::gen::elementOf(kAddresses);
  qint64 delta = *rc::gen::inRange(-3, 2);

  explicit Remove(const Model&) {}

  void apply(Model& model) const override { model.remove(projectKey(project), address, model.now + delta); }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.history.remove(q(projectKey(project)), q(address.url), model.now + delta);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Remove(" << project << ", " << address.url << ", " << delta << ")"; }
};

// A project's tab goes through many pages, one a tick.
struct Browse : Command {
  int project = *rc::gen::inRange(0, 23);
  int pages = *rc::gen::inRange(1, 60);

  explicit Browse(const Model&) {}

  Address page(int n) const {
    const std::string url = "http://localhost:5173/p" + std::to_string(n);
    return {url, url};
  }

  void apply(Model& model) const override {
    for (int n = 0; n < pages; ++n) model.visit(projectKey(project), page(n), "", ++model.now);
  }

  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    qint64 now = model.now;
    for (int n = 0; n < pages; ++n) sut.history.visit(q(projectKey(project)), q(page(n).url), QString(), ++now);
    check(expected, sut);
  }

  void show(std::ostream& os) const override { os << "Browse(" << project << ", " << pages << ")"; }
};

// The device saves the history and reads it back, as a restart does.
struct Reload : Command {
  explicit Reload(const Model&) {}

  void apply(Model&) const override {}

  void run(const Model& model, Sut& sut) const override {
    const QVariant saved = sut.history.toVariant();
    sut.history = PreviewHistory::fromVariant(saved);
    RC_ASSERT(sut.history.toVariant() == saved);
    check(model, sut);
  }

  void show(std::ostream& os) const override { os << "Reload"; }
};

}  // namespace

class PreviewHistoryProp : public QObject {
  Q_OBJECT

private slots:
  void tidy() {
    QVERIFY(rc::check("an address is kept under its tidy form", [] {
      const Address address = *rc::gen::elementOf(kAddresses);
      RC_ASSERT(PreviewHistory::tidy(q(address.url)) == q(address.tidy));
      RC_ASSERT(PreviewHistory::tidy(PreviewHistory::tidy(q(address.url))) == q(address.tidy));
    }));
  }

  void history() {
    QVERIFY(rc::check("the history follows its model", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut, rc::state::gen::execOneOfWithArgs<Visit, Visit, Visit, Seen, Seen, Remove, Browse, Reload, Untimed>());
    }));
  }
};

HAL_C2_PROP_MAIN(PreviewHistoryProp)
#include "tst_PreviewHistoryProp.moc"
