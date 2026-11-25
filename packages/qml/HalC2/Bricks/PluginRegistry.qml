pragma Singleton
import QtQuick
import HalC2.Shell

// The UI plugins loaded into this QML engine: every file the shell's plugin
// controller lists (`Shell.state.plugins.files`, each with its text) is made
// here and kept until its file goes or is turned off. A file saved again
// replaces its plugin in place, and one that no longer loads leaves the
// version already running. What loaded and what did not goes back as
// `plugins.report`. PluginSlots read `contributionsFor(name)` and follow
// `revision`, which also counts the slot parts MC plugins add
// (`Shell.state.mcPlugins.slots`), each made as a PluginPart.
QtObject {
    id: registry

    readonly property var wanted: Shell.state.plugins?.files ?? []
    readonly property var mcSlots: Shell.state.mcPlugins?.slots ?? []
    property string mcSlotsSeen: "[]"
    // By file: {object, revision, id}.
    property var loaded: ({})
    // What a slot could not draw: {id, file, message}, by "id\nslot".
    property var renderProblems: ({})
    property int revision: 0
    // The last report sent; with no plugin and no problem there is nothing to say.
    property string reported: "[[],[]]"
    // How many PluginSlots of each name the shell has on screen.
    property var mounted: ({})

    function mount(name, by) {
        if (name.length === 0)
            return;
        const next = Object.assign({}, registry.mounted);
        next[name] = (next[name] ?? 0) + by;
        registry.mounted = next;
        registry.report();
    }

    // A plugin file may import the terminal client's module; here its types
    // are QtQuick's and this module's, with `Text` the themed one in plugin/.
    readonly property string pluginTypes: Qt.resolvedUrl("plugin")

    function source(text) {
        return text.replace(/^[ \t]*import[ \t]+OpenTUI\b.*$/m, "import QtQuick; import HalC2.Bricks; import \"" + registry.pluginTypes + "\"");
    }

    function baseName(file) {
        return file.replace(/^.*[\\/]/, "").replace(/\.qml$/, "");
    }

    function describe(error) {
        const first = error.qmlErrors !== undefined && error.qmlErrors.length > 0 ? error.qmlErrors[0] : null;
        return first !== null ? qsTr("line %1: %2").arg(first.lineNumber).arg(first.message) : String(error.message ?? error);
    }

    readonly property Component mcPart: Component {
        PluginPart {}
    }

    // The contributions to a slot, by plugin order and then load order, one
    // per plugin, MC plugins' after this device's: [{pluginId, file,
    // delegate, given (its initial properties), mc}].
    function contributionsFor(name) {
        const found = [];
        registry.wanted.forEach((entry, index) => {
            const plugin = registry.loaded[entry.file];
            if (plugin === undefined)
                return;
            for (const contribution of plugin.object.contributions) {
                if (contribution instanceof Contribution && contribution.slot === name && contribution.delegate !== null) {
                    found.push({ pluginId: plugin.id, file: entry.file, order: plugin.object.order, index: index, delegate: contribution.delegate });
                    break;
                }
            }
        });
        found.sort((a, b) => (a.order - b.order) || (a.index - b.index));
        const mc = registry.mcSlots.filter(part => part.slot === name).sort((a, b) => a.order - b.order);
        for (const part of mc)
            found.push({ pluginId: part.pluginId, file: part.url, delegate: registry.mcPart, mc: true,
                         given: { url: part.url, pluginId: part.pluginId, environments: [part.environment] } });
        return found;
    }

    // A slot says what it could not draw (message "" once it can).
    function noteRender(pluginId, file, slotName, message) {
        const key = pluginId + "\n" + slotName;
        if ((registry.renderProblems[key]?.message ?? "") === message)
            return;
        const next = Object.assign({}, registry.renderProblems);
        if (message.length > 0)
            next[key] = { id: pluginId, file: file, message: qsTr("%1: %2").arg(slotName).arg(message) };
        else
            delete next[key];
        registry.renderProblems = next;
        registry.report();
    }

    // Files that did not load, by file: {revision, id, message}. A revision
    // that failed is not tried again until the file changes.
    property var failures: ({})

    function sync() {
        const next = {};
        const failed = {};
        const ids = {};
        let changed = false;
        for (const entry of registry.wanted) {
            const running = registry.loaded[entry.file];
            const failure = registry.failures[entry.file];
            const current = running !== undefined && running.revision === entry.revision;
            if (current || (failure !== undefined && failure.revision === entry.revision)) {
                if (running !== undefined) {
                    next[entry.file] = running;
                    ids[running.id] = true;
                }
                if (!current)
                    failed[entry.file] = failure;
                continue;
            }
            let made = null;
            let problem = "";
            try {
                made = Qt.createQmlObject(registry.source(entry.source), registry, entry.file);
            } catch (error) {
                problem = registry.describe(error);
            }
            if (made !== null && !(made instanceof Plugin)) {
                made.destroy();
                made = null;
                problem = qsTr("the file's root object is not a Plugin");
            }
            const id = made !== null && made.pluginId.length > 0 ? made.pluginId : registry.baseName(entry.file);
            if (made !== null && ids[id] === true && (running === undefined || running.id !== id)) {
                made.destroy();
                made = null;
                problem = qsTr("another plugin is already loaded as \"%1\"").arg(id);
            }
            if (made === null) {
                // The version that was running keeps running.
                failed[entry.file] = {
                    revision: entry.revision,
                    id: running !== undefined ? running.id : id,
                    message: running !== undefined ? qsTr("%1 (the last working version keeps running)").arg(problem) : problem
                };
                if (running !== undefined) {
                    next[entry.file] = running;
                    ids[running.id] = true;
                }
                continue;
            }
            if (running !== undefined)
                running.object.destroy();
            next[entry.file] = { object: made, revision: entry.revision, id: id };
            ids[id] = true;
            changed = true;
        }
        for (const file in registry.loaded) {
            if (next[file] === undefined) {
                registry.loaded[file].object.destroy();
                changed = true;
            }
        }
        registry.loaded = next;
        registry.failures = failed;
        if (changed)
            registry.revision += 1;
        registry.report();
    }

    function report() {
        const plugins = [];
        for (const entry of registry.wanted) {
            const plugin = registry.loaded[entry.file];
            if (plugin === undefined)
                continue;
            const slots = [];
            for (const contribution of plugin.object.contributions) {
                if (contribution instanceof Contribution && slots.indexOf(contribution.slot) < 0)
                    slots.push(contribution.slot);
            }
            // `shown`: the slots it contributes to that this shell has.
            plugins.push({ id: plugin.id, file: entry.file, order: plugin.object.order, description: plugin.object.description, slots: slots,
                           shown: slots.filter(name => (registry.mounted[name] ?? 0) > 0) });
        }
        const problems = Object.keys(registry.failures).map(file => ({ id: registry.failures[file].id, file: file, message: registry.failures[file].message }))
            .concat(Object.keys(registry.renderProblems).map(key => registry.renderProblems[key]));
        const said = JSON.stringify([plugins, problems]);
        if (said === registry.reported)
            return;
        registry.reported = said;
        registry.pending = { plugins: plugins, problems: problems };
        // Not from inside the change that asked for it: the answer changes `wanted`.
        Qt.callLater(registry.send);
    }

    property var pending: null

    function send() {
        if (registry.pending === null)
            return;
        const report = registry.pending;
        registry.pending = null;
        Shell.dispatch("plugins.report", report);
    }

    onWantedChanged: sync()
    onMcSlotsChanged: {
        const seen = JSON.stringify(registry.mcSlots);
        if (seen === registry.mcSlotsSeen)
            return;
        registry.mcSlotsSeen = seen;
        registry.revision += 1;
    }
    Component.onCompleted: sync()
}
