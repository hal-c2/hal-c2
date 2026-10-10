.pragma library

// The files a turn changed as a folder tree:
// folders before files, a folder holding only one folder joined with it into
// one row ("src/cart"), and every folder carrying the lines its files added
// and removed.
//
//   ChangedFilesTree.rows(files, false, {})  // the rows to draw, top folders only
//
// A row is {kind: "directory" | "file", name, path, depth, additions,
// deletions, expanded}; a file's path is the one it came with.

function byName(a, b) {
    return a.name.localeCompare(b.name);
}

function nodesOf(directory) {
    const folders = Array.from(directory.directories.values()).sort(byName).map(folder => {
        let node = folder;
        let name = folder.name;
        while (node.files.length === 0 && node.directories.size === 1) {
            node = node.directories.values().next().value;
            name += "/" + node.name;
        }
        return {
            kind: "directory",
            name: name,
            path: node.path,
            additions: node.additions,
            deletions: node.deletions,
            children: nodesOf(node)
        };
    });
    return folders.concat(directory.files.sort(byName));
}

function tree(files) {
    const root = { path: "", directories: new Map(), files: [] };
    for (const file of files) {
        const segments = String(file.path ?? "").replace(/\\/g, "/").split("/").filter(segment => segment.length > 0);
        if (segments.length === 0)
            continue;
        const name = segments.pop();
        const additions = file.additions ?? 0;
        const deletions = file.deletions ?? 0;
        let directory = root;
        for (const segment of segments) {
            let next = directory.directories.get(segment);
            if (!next) {
                next = {
                    name: segment,
                    path: directory.path.length > 0 ? directory.path + "/" + segment : segment,
                    directories: new Map(),
                    files: [],
                    additions: 0,
                    deletions: 0
                };
                directory.directories.set(segment, next);
            }
            next.additions += additions;
            next.deletions += deletions;
            directory = next;
        }
        directory.files.push({ kind: "file", name: name, path: file.path, additions: additions, deletions: deletions });
    }
    return nodesOf(root);
}

// The rows on show: a folder's are under it while it is open. Folders are
// open when `allExpanded`, except those `overrides` (by path) says otherwise.
function rows(files, allExpanded, overrides) {
    const shown = [];
    const walk = (nodes, depth) => {
        for (const node of nodes) {
            const expanded = node.kind === "directory" && (overrides[node.path] ?? allExpanded);
            shown.push({
                kind: node.kind,
                name: node.name,
                path: node.path,
                depth: depth,
                additions: node.additions,
                deletions: node.deletions,
                expanded: expanded
            });
            if (expanded)
                walk(node.children, depth + 1);
        }
    };
    walk(tree(files), 0);
    return shown;
}

function hasFolders(files) {
    return files.some(file => /[/\\]/.test(String(file.path ?? "")));
}
