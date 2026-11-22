#!/usr/bin/env python3
"""replace-install.sh, interrupted or failing at each move of the swap and the restore.

Run it with `python3 scripts/lib/replace-install.test.py`. It only writes under TMPDIR.
"""

import os
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from shutil import which

HELPER = Path(__file__).resolve().with_name("replace-install.sh")
SIGNALS = ("HUP", "INT", "TERM")

INSTALL = """set -euo pipefail
source "$HELPER"
staged_install "$INSTALLED"
mkdir "$staging/new"
echo new >"$staging/new/mark"
swap_install "$staging/new"
"""

# A signal as cleanup's first command starts, before it can have ignored any.
AT_CLEANUP = """set -T
trap 'if [[ ${FUNCNAME[0]-} == end_install && -z ${hit-} ]]; then hit=1; kill -s "$CLEANUP" $$; fi' DEBUG
"""

# `shell` signals bash alone while the move runs, and `group` its whole process group. Bash
# mustn't clean up beside a running move, so `shell` gives it a second to do that wrongly: it
# reports through a fifo at once, and then the move and the cleanup are made to collide.
MV = """#!/usr/bin/env bash
case $1 in
"$INSTALLED") how=${OLD-} ;;
*/previous) how=${RESTORE-}; if [[ -e $STATE/moving ]]; then echo >"$STATE/cleanup"; fi ;;
*) how=${NEW-} ;;
esac
case $how in
fail) exit 1 ;;
group:*) kill -s "${how#*:}" 0 ;;
shell:*)
  : >"$STATE/moving"
  kill -s "${how#*:}" "$PPID"
  read -r -t 1 <>"$STATE/cleanup"
  "$REAL_MV" "$@"; status=$?
  echo >"$STATE/moved"
  "$REAL_RM" -f "$STATE/moving"
  exit $status
  ;;
esac
exec "$REAL_MV" "$@"
"""

RM = """#!/usr/bin/env bash
if [[ -e $STATE/moving ]]; then
  echo >"$STATE/cleanup"
  read -r -t 5 <>"$STATE/moved"
fi
exec "$REAL_RM" "$@"
"""


def default_signals():
    for name in SIGNALS:
        signal.signal(getattr(signal, f"SIG{name}"), signal.SIG_DFL)


class ReplaceInstall(unittest.TestCase):
    def install(self, fresh=False, **faults):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            place, shim, state = base / "apps with space", base / "shim", base / "state"
            for directory in (place, shim, state):
                directory.mkdir()
            installed = place / "HAL-C2.app"
            if not fresh:
                installed.mkdir()
                (installed / "mark").write_text("old\n")
            for name, text in (("mv", MV), ("rm", RM)):
                (shim / name).write_text(text)
                (shim / name).chmod(0o755)

            env = dict(
                os.environ,
                HELPER=str(HELPER),
                INSTALLED=str(installed),
                STATE=str(state),
                REAL_MV=which("mv"),
                REAL_RM=which("rm"),
                PATH=f"{shim}:{os.environ['PATH']}",
            )
            for key in ("OLD", "NEW", "RESTORE", "CLEANUP"):
                env.pop(key, None)
            env.update({key.upper(): value for key, value in faults.items()})

            fifos = []
            for name in ("cleanup", "moved"):
                os.mkfifo(state / name)
                fifos.append(os.open(state / name, os.O_RDWR))  # keeps what is written until read
            try:
                script = (AT_CLEANUP if "cleanup" in faults else "") + INSTALL
                # A session of its own, so a group signal stops at the install.
                run = subprocess.run(
                    ["bash", "-c", script],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    start_new_session=True,
                    preexec_fn=default_signals,
                )
            finally:
                for fifo in fifos:
                    os.close(fifo)
            files = {
                str(path.relative_to(place)): path.read_text().strip()
                for path in place.rglob("*")
                if path.is_file()
            }
            left = sorted(path.name for path in place.iterdir() if path.name != installed.name)
            return run, files, left

    def assert_intact(self, result, mark, failed=True):
        run, files, left = result
        self.assertEqual(files, {"HAL-C2.app/mark": mark} if mark else {}, run.stderr)
        self.assertEqual(left, [])
        self.assertEqual(run.returncode != 0, failed, run.stderr)

    def test_installs(self):
        self.assert_intact(self.install(), "new", failed=False)
        self.assert_intact(self.install(fresh=True), "new", failed=False)

    def test_failed_move(self):
        self.assert_intact(self.install(old="fail"), "old")
        self.assert_intact(self.install(new="fail"), "old")
        self.assert_intact(self.install(fresh=True, new="fail"), None)

    def test_signal_to_bash_while_moving_the_old_aside(self):
        for name in SIGNALS:
            with self.subTest(name):
                self.assert_intact(self.install(old=f"shell:{name}"), "old")

    def test_signal_to_bash_while_moving_the_new_in(self):
        for name in SIGNALS:
            with self.subTest(name):
                self.assert_intact(self.install(new=f"shell:{name}"), "new")

    def test_signal_to_the_group_while_moving(self):
        for name in SIGNALS:
            for move in ("old", "new"):
                with self.subTest(f"{name} {move}"):
                    self.assert_intact(self.install(**{move: f"group:{name}"}), "old")

    def test_second_signal_during_the_restore(self):
        for name in SIGNALS:
            for first in ("fail", f"group:{name}"):
                with self.subTest(f"{name} after {first}"):
                    self.assert_intact(self.install(new=first, restore=f"group:{name}"), "old")

    def test_signal_as_cleanup_starts(self):
        for name in SIGNALS:
            for first in ("fail", "group:TERM"):
                with self.subTest(f"{name} after {first}"):
                    self.assert_intact(self.install(new=first, cleanup=name), "old")

    def test_failed_restore_keeps_the_copy_and_says_where(self):
        run, files, left = self.install(new="fail", restore="fail")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(len(left), 1)
        self.assertEqual(files.get(f"{left[0]}/previous/mark"), "old")
        self.assertIn(f"/{left[0]}/previous", run.stderr)


if __name__ == "__main__":
    unittest.main()
