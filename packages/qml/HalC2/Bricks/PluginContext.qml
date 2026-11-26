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
    // The requests and watches this context has with PluginChannel, which hands
    // each value to the one callback that asked for it; theirs end with it.
    property var answers: ({})
    property var watches: ({})

    function expect(request, done) {
        context.answers[request] = true;
        PluginChannel.expect(request, (result, error) => {
            delete context.answers[request];
            done(result, error);
        });
    }

    function call(method, input, done, environment) {
        const request = McPlugins.call(environment ?? context.environment, context.pluginId, method, input ?? null);
        if (done)
            context.expect(request, done);
        return request;
    }

    function saveSettings(settings, done, environment) {
        const request = McPlugins.saveSettings(environment ?? context.environment, context.pluginId, settings);
        if (done)
            context.expect(request, done);
        return request;
    }

    function watch(topic, onValue, environment) {
        const watch = McPlugins.watch(environment ?? context.environment, context.pluginId, topic);
        if (watch >= 0) {
            context.watches[watch] = true;
            PluginChannel.follow(watch, onValue);
        }
        return watch;
    }

    function unwatch(watch) {
        if (context.watches[watch] === undefined)
            return;
        delete context.watches[watch];
        PluginChannel.forget(watch);
        McPlugins.unwatch(watch);
    }

    function openThread(threadId, environment) {
        Shell.dispatch("thread.open", { key: (environment ?? context.environment) + ":" + threadId });
    }

    Component.onDestruction: {
        for (const request of Object.keys(context.answers))
            PluginChannel.drop(request);
        for (const watch of Object.keys(context.watches)) {
            PluginChannel.forget(watch);
            McPlugins.unwatch(Number(watch));
        }
    }
}
