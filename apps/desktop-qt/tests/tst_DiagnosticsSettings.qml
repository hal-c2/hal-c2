import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/diagnostics.feature: the Diagnostics page draws what
// DiagnosticsController publishes and hands signals, windows and the logs
// folder back.
Item {
    id: root
    width: 900
    height: 900

    Component {
        id: pageComponent
        DiagnosticsSettings {
            width: 880
            height: 880
        }
    }

    function state(overrides) {
        return Object.assign({
            processes: { loading: false, error: null, serverPid: "4000", count: "1", cpu: "2.5%", memory: "50 MB",
                         rows: [{ pid: 4102, name: "codex", command: "codex app-server", cpu: "2.5%", memory: "50 MB",
                                  type: "Agent", depth: 0, signaling: false }] },
            history: { loading: false, error: null, windowMs: 900000,
                       windows: [{ label: "5m", windowMs: 300000 }, { label: "15m", windowMs: 900000 }],
                       cpuTime: "0s", samples: "0", interval: "5s", count: "0", rows: [] },
            traces: { loading: false, error: null, spans: "0", failures: "0", slowSpans: "0", parseErrors: "0",
                      latestFailures: [], commonFailures: [], slowestSpans: [] },
            logs: { available: true, error: null }
        }, overrides);
    }

    TestCase {
        name: "DiagnosticsSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_process_row_signals_its_process() {
            Shell.state = { diagnostics: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "stat:Server PID").text, "4000");
            const row = findChild(page, "process:4102");
            mouseClick(findChild(row, "sigkill"));
            compare(Shell.dispatchedActions[0].action, "diagnostics.signal");
            compare(Shell.dispatchedActions[0].payload.pid, 4102);
            compare(Shell.dispatchedActions[0].payload.signal, "SIGKILL");
        }

        function test_a_window_is_chosen_and_the_logs_folder_opens() {
            Shell.state = { diagnostics: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            mouseClick(findChild(page, "window:5m"));
            compare(Shell.dispatchedActions[0].action, "diagnostics.window");
            compare(Shell.dispatchedActions[0].payload.windowMs, 300000);
            mouseClick(findChild(page, "openLogs"));
            compare(Shell.dispatchedActions[1].action, "diagnostics.openLogs");
        }

        function test_no_editor_is_said() {
            Shell.state = { diagnostics: root.state({ logs: { available: true, error: "No available editors found." } }) };
            const page = createTemporaryObject(pageComponent, root);
            const error = findChild(page, "logsError");
            verify(error.visible);
            compare(error.text, "No available editors found.");
        }
    }
}
