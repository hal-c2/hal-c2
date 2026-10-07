import QtQuick
import HalC2.Shell

// What an MC plugin's UI part is handed as `plugin`: its id, the environments
// that run it, and the way to its MC part there.
//
//   plugin.call("reviews", {}, (result, error) => ..., environment)
//   plugin.watch("reviews", value => ..., environment)
//   plugin.openThread(threadId, environment)
//   plugin.saveSettings({ repos: [...] }, (result, error) => ..., environment)
//
// `environment` may be left out for the first environment. Watches end with
// the UI part.
QtObject {
    id: context

    property string pluginId: ""
    property var environments: []
    readonly property string environment: environments.length > 0 ? environments[0] : ""
    // Callbacks by request and by watch; neither is bound to, so they change in place.
    property var answers: ({})
    property var watches: ({})

    function call(method, input, done, environment) {
        const request = McPlugins.call(environment ?? context.environment, context.pluginId, method, input ?? null);
        if (done)
            context.answers[request] = done;
        return request;
    }

    function saveSettings(settings, done, environment) {
        const request = McPlugins.saveSettings(environment ?? context.environment, context.pluginId, settings);
        if (done)
            context.answers[request] = done;
        return request;
    }

    function watch(topic, onValue, environment) {
        const watch = McPlugins.watch(environment ?? context.environment, context.pluginId, topic);
        if (watch >= 0)
            context.watches[watch] = onValue;
        return watch;
    }

    function unwatch(watch) {
        if (context.watches[watch] === undefined)
            return;
        delete context.watches[watch];
        McPlugins.unwatch(watch);
    }

    function openThread(threadId, environment) {
        Shell.dispatch("thread.open", { key: (environment ?? context.environment) + ":" + threadId });
    }

    readonly property Connections link: Connections {
        target: McPlugins

        function onAnswered(request, result, error) {
            const done = context.answers[request];
            if (done === undefined)
                return;
            delete context.answers[request];
            done(result, error.length > 0 ? error : null);
        }

        function onPublished(watch, value) {
            const onValue = context.watches[watch];
            if (onValue !== undefined)
                onValue(value);
        }
    }

    Component.onDestruction: {
        for (const watch of Object.keys(context.watches))
            McPlugins.unwatch(Number(watch));
    }
}
