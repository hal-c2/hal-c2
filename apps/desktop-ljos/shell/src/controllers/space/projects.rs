//! The project sections of the Space sidebar, desktop-qt's SpaceProjects:
//! one for each project of the MC with Space files, each holding its files
//! as a tree by folder. A section and each folder start collapsed; which
//! the user expanded the client remembers across restarts.

use std::collections::{HashMap, HashSet};

use serde_json::json;

use super::rows::Row;

fn by_name(a: &str, b: &str) -> std::cmp::Ordering {
    a.to_lowercase()
        .cmp(&b.to_lowercase())
        .then_with(|| a.cmp(b))
}

/// Depth first: at each level a folder's folders come before its files,
/// each by name.
fn tree_order(a: &[String], b: &[String]) -> std::cmp::Ordering {
    for i in 0..a.len().min(b.len()) {
        let a_folder = i < a.len() - 1;
        let b_folder = i < b.len() - 1;
        if a_folder != b_folder {
            return b_folder.cmp(&a_folder);
        }
        let order = by_name(&a[i], &b[i]);
        if order != std::cmp::Ordering::Equal {
            return order;
        }
    }
    a.len().cmp(&b.len())
}

/// Every folder a project's files are in, as "docs" and "docs/api".
fn folders_of(files: &HashMap<String, String>) -> HashSet<String> {
    let mut folders = HashSet::new();
    for path in files.keys() {
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        for i in 1..parts.len() {
            folders.insert(parts[..i].join("/"));
        }
    }
    folders
}

fn parts_of(path: &str) -> Vec<String> {
    path.split('/')
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect()
}

#[derive(Clone, PartialEq, Eq)]
pub struct Project {
    pub id: String,
    pub title: String,
}

#[derive(Default)]
pub struct Projects {
    projects: Vec<Project>,
    files: HashMap<String, HashMap<String, String>>,
    expanded: HashSet<String>,
    folders: HashMap<String, HashSet<String>>,
    /// What to remember changed; the controller writes it and clears.
    pub expanded_changed: bool,
    /// The rows changed; the controller republishes them.
    pub dirty: bool,
}

impl Projects {
    pub fn new() -> Projects {
        Projects::default()
    }

    /// Shown by title, whatever order they come in.
    pub fn set_projects(&mut self, mut projects: Vec<Project>) {
        projects.sort_by(|a, b| by_name(&a.title, &b.title).then_with(|| a.id.cmp(&b.id)));
        if projects == self.projects {
            return;
        }
        self.projects = projects;
        self.dirty = true;
    }

    /// The project's Space files, path to page id, as its
    /// `space.files.list` last said.
    pub fn set_files(&mut self, project_id: &str, pages: HashMap<String, String>) {
        if self.files.get(project_id) == Some(&pages) {
            return;
        }
        self.files.insert(project_id.to_owned(), pages);
        let forgot = self.forget_gone_folders(project_id);
        self.dirty = true;
        if forgot {
            self.expanded_changed = true;
        }
    }

    fn forget_gone_folders(&mut self, project_id: &str) -> bool {
        let Some(held) = self.folders.get(project_id) else {
            return false;
        };
        if self.files.get(project_id).is_none_or(HashMap::is_empty) {
            return false;
        }
        let folders = folders_of(self.files.get(project_id).expect("checked"));
        let before = held.len();
        let held = self.folders.get_mut(project_id).expect("held");
        held.retain(|path| folders.contains(path));
        let forgot = held.len() != before;
        if held.is_empty() {
            self.folders.remove(project_id);
        }
        forgot
    }

    pub fn set_expanded(&mut self, project_id: &str, expanded: bool) {
        if project_id.is_empty() || self.expanded.contains(project_id) == expanded {
            return;
        }
        if expanded {
            self.expanded.insert(project_id.to_owned());
        } else {
            self.expanded.remove(project_id);
        }
        self.dirty = true;
        self.expanded_changed = true;
    }

    pub fn is_expanded(&self, project_id: &str) -> bool {
        self.expanded.contains(project_id)
    }

    /// A folder by its path in the project, as its row says it.
    pub fn set_folder_expanded(&mut self, project_id: &str, path: &str, expanded: bool) {
        if project_id.is_empty()
            || path.is_empty()
            || self
                .folders
                .get(project_id)
                .is_some_and(|f| f.contains(path))
                == expanded
        {
            return;
        }
        if expanded {
            // A folder none of the listed files is in is not one to remember.
            if let Some(files) = self.files.get(project_id)
                && !files.is_empty()
                && !folders_of(files).contains(path)
            {
                return;
            }
            self.folders
                .entry(project_id.to_owned())
                .or_default()
                .insert(path.to_owned());
        } else if let Some(held) = self.folders.get_mut(project_id) {
            held.remove(path);
            if held.is_empty() {
                self.folders.remove(project_id);
            }
        }
        self.dirty = true;
        self.expanded_changed = true;
    }

    /// The section and the folders a file is in, opened so its row shows.
    pub fn reveal(&mut self, project_id: &str, path: &str) {
        if project_id.is_empty() {
            return;
        }
        let mut changed = false;
        if !self.expanded.contains(project_id) {
            self.expanded.insert(project_id.to_owned());
            changed = true;
        }
        let clean = path.strip_prefix("./").unwrap_or(path);
        let parts = parts_of(clean);
        for i in 1..parts.len() {
            let folder = parts[..i].join("/");
            let folders = self.folders.entry(project_id.to_owned()).or_default();
            if !folders.contains(&folder) {
                folders.insert(folder);
                changed = true;
            }
        }
        if self.folders.get(project_id).is_some_and(HashSet::is_empty) {
            self.folders.remove(project_id);
        }
        if changed {
            self.dirty = true;
            self.expanded_changed = true;
        }
    }

    /// Sorted, sections not shown included: a project out of reach keeps
    /// its choice.
    pub fn expanded_projects(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.expanded.iter().cloned().collect();
        ids.sort();
        ids
    }

    /// Project id to its expanded folders' paths, sorted.
    pub fn expanded_folders(&self) -> Row {
        let mut folders = Row::new();
        for (project, held) in &self.folders {
            let mut paths: Vec<String> = held.iter().cloned().collect();
            paths.sort();
            folders.insert(project.clone(), json!(paths));
        }
        folders
    }

    /// What was remembered; says it back only when it forgot folders the
    /// listing lacks.
    pub fn restore_expanded(&mut self, project_ids: Vec<String>, folders: &Row) {
        let expanded: HashSet<String> = project_ids.into_iter().collect();
        let mut paths: HashMap<String, HashSet<String>> = HashMap::new();
        for (key, value) in folders {
            let mut held: HashSet<String> = value
                .as_array()
                .map(|list| {
                    list.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            held.remove("");
            if !key.is_empty() && !held.is_empty() {
                paths.insert(key.clone(), held);
            }
        }
        let listed: Vec<String> = paths.keys().cloned().collect();
        let remembered = std::mem::replace(&mut self.folders, paths);
        let mut forgot = false;
        for project in &listed {
            forgot |= self.forget_gone_folders(project);
        }
        if expanded != self.expanded || remembered != self.folders {
            self.expanded = expanded;
            self.dirty = true;
        }
        if forgot {
            self.expanded_changed = true;
        }
    }

    /// The sidebar's rows: a project's row, then, while it is expanded,
    /// its folders and files depth first.
    pub fn build(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        for project in &self.projects {
            let empty = HashMap::new();
            let pages = self.files.get(&project.id).unwrap_or(&empty);
            if pages.is_empty() {
                continue;
            }
            let expanded = self.expanded.contains(&project.id);
            let mut row = Row::new();
            row.insert("id".into(), json!(format!("project:{}", project.id)));
            row.insert("kind".into(), json!("project"));
            row.insert("projectId".into(), json!(project.id));
            row.insert("path".into(), json!(""));
            row.insert(
                "name".into(),
                json!(if project.title.is_empty() {
                    &project.id
                } else {
                    &project.title
                }),
            );
            row.insert("depth".into(), json!(0));
            row.insert("expanded".into(), json!(expanded));
            row.insert("pageId".into(), json!(""));
            rows.push(row);
            if !expanded {
                continue;
            }
            let mut paths: Vec<Vec<String>> = pages.keys().map(|p| parts_of(p)).collect();
            paths.sort_by(|a, b| tree_order(a, b));
            let open_folders = self.folders.get(&project.id).cloned().unwrap_or_default();
            let mut open: Vec<String> = Vec::new();
            for path in &paths {
                if path.is_empty() {
                    continue;
                }
                let folders = &path[..path.len() - 1];
                let mut common = 0;
                while common < open.len()
                    && common < folders.len()
                    && open[common] == folders[common]
                {
                    common += 1;
                }
                open.clone_from(&folders.to_vec());
                let mut shown = 0;
                let mut inside = true;
                while shown < folders.len() && inside {
                    inside = open_folders.contains(&folders[..=shown].join("/"));
                    shown += 1;
                }
                for i in common..shown {
                    let at = folders[..=i].join("/");
                    let mut row = Row::new();
                    row.insert("id".into(), json!(format!("folder:{}:{}", project.id, at)));
                    row.insert("kind".into(), json!("folder"));
                    row.insert("projectId".into(), json!(project.id));
                    row.insert("path".into(), json!(at.clone()));
                    row.insert("name".into(), json!(folders[i]));
                    row.insert("depth".into(), json!(i as i64 + 1));
                    row.insert("expanded".into(), json!(open_folders.contains(&at)));
                    row.insert("pageId".into(), json!(""));
                    rows.push(row);
                }
                if !inside {
                    continue;
                }
                let relative = path.join("/");
                let mut row = Row::new();
                row.insert(
                    "id".into(),
                    json!(format!("file:{}:{}", project.id, relative)),
                );
                row.insert("kind".into(), json!("file"));
                row.insert("projectId".into(), json!(project.id));
                row.insert("path".into(), json!(relative.clone()));
                row.insert("name".into(), json!(path[path.len() - 1]));
                row.insert("depth".into(), json!(folders.len() as i64 + 1));
                row.insert("expanded".into(), json!(false));
                row.insert(
                    "pageId".into(),
                    json!(pages.get(&relative).cloned().unwrap_or_default()),
                );
                rows.push(row);
            }
        }
        rows
    }
}
