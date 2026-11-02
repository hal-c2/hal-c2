pragma Singleton
import QtQuick

// Mermaid diagrams (MermaidController) as a test sets them: `answers` maps
// theme + "\n" + source to what the MC answered; anything else is still being
// drawn. `asked` counts the asks per key, as the controller would send them.
QtObject {
    property int revision: 0
    property var answers: ({})
    property var asked: ({})
    property var retried: []

    function diagram(source, theme) {
        const key = theme + "\n" + source;
        if (!(key in asked))
            asked[key] = 1;
        return answers[key] ?? { status: "drawing" };
    }

    function retry(source, theme) {
        retried = retried.concat([theme + "\n" + source]);
    }

    // The MC answers `answer` for `source` in `theme`.
    function answer(source, theme, answer) {
        const next = Object.assign({}, answers);
        next[theme + "\n" + source] = answer;
        answers = next;
        revision++;
    }

    function reset() {
        answers = {};
        asked = {};
        retried = [];
        revision++;
    }
}
