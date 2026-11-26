pragma Singleton
import QtQuick
import HalC2.Shell

// The one listener to McPlugins for every PluginContext: a topic's value or a
// call's answer goes to the callback that asked for it and nowhere else. Each
// handler of a signal gets the value made anew for it, so a listener per plugin
// part (a row mark per sidebar row, headers, pages) made a large value (the
// code-review plugin's `reviews`) once per part on every publish.
QtObject {
    id: channel

    // Callbacks by request and by watch; neither is bound to, so they change in place.
    property var answers: ({})
    property var watches: ({})

    function expect(request, done) {
        channel.answers[request] = done;
    }

    function follow(watch, onValue) {
        channel.watches[watch] = onValue;
    }

    function forget(watch) {
        delete channel.watches[watch];
    }

    function drop(request) {
        delete channel.answers[request];
    }

    readonly property Connections link: Connections {
        target: McPlugins

        function onAnswered(request, result, error) {
            const done = channel.answers[request];
            if (done === undefined)
                return;
            delete channel.answers[request];
            done(result, error.length > 0 ? error : null);
        }

        function onPublished(watch, value) {
            const onValue = channel.watches[watch];
            if (onValue !== undefined)
                onValue(value);
        }
    }
}
