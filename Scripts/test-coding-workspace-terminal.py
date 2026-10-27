#!/usr/bin/env python3
"""Gate-1 integration proof. Uses only a private Unix socket and synthetic cat agents.

Run: python3 Scripts/test-coding-workspace-terminal.py
No default tmux server, model API, project data, or TCP listener is used.
This validates the attachment design, not the unfinished app transport/rendering.
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest


class TerminalClient:
    def __init__(self, command):
        self.master, slave = pty.openpty()
        self.output = bytearray()
        self.resize(80, 24)
        try:
            self.process = subprocess.Popen(
                command, stdin=slave, stdout=slave, stderr=slave,
                start_new_session=True,
                env={**os.environ, "TERM": "xterm-256color", "TMUX": ""},
            )
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        if hasattr(self, "process") and self.process.poll() is None:
            self.process.send_signal(signal.SIGWINCH)

    def wait_for(self, value):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if value in self.output:
                return
            readable, _, _ = select.select([self.master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as error:
                    raise AssertionError("PTY closed before expected output") from error
                if not chunk:
                    break
                self.output.extend(chunk)
                if len(self.output) > 1024 * 1024:
                    raise AssertionError("Test terminal output exceeded bound")
        raise AssertionError(f"Missing terminal bytes: {value!r}; tail={self.output[-300:]!r}")

    def close(self):
        # Closing the viewer's terminal must never kill its agent pane.
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        os.close(self.master)


@unittest.skipUnless(shutil.which("tmux"), "tmux is required for terminal integration")
class CodingWorkspaceTerminalTests(unittest.TestCase):
    def setUp(self):
        # Short socket path: macOS sockaddr_un has a small path limit.
        self.directory = tempfile.TemporaryDirectory(prefix="lt-pty-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        os.chmod(self.directory.name, 0o700)
        self.socket = str(Path(self.directory.name) / "s")
        self.base = [shutil.which("tmux"), "-S", self.socket, "-f", "/dev/null"]
        self.addCleanup(self.kill_test_server)
        self.tmux("new-session", "-d", "-s", "agent", "-x", "80", "-y", "24",
                  "/usr/bin/env", "--", "/bin/cat")
        self.pane = self.tmux("display-message", "-p", "-t", "agent:0", "#{pane_id}")
        self.window = self.tmux("display-message", "-p", "-t", "agent:0", "#{window_id}")

    def tmux(self, *arguments):
        result = subprocess.run(self.base + list(arguments), capture_output=True,
                                timeout=5, env={**os.environ, "TMUX": ""})
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout.decode().strip()

    def kill_test_server(self):
        # Explicit private socket is mandatory, including cleanup.
        result = subprocess.run(self.base + ["kill-server"], capture_output=True, timeout=5)
        if result.returncode != 0 and Path(self.socket).exists():
            raise AssertionError(result.stderr.decode(errors="replace"))

    def viewer(self, name):
        self.tmux("new-session", "-d", "-s", name, "/usr/bin/env", "--", "/bin/sleep", "120")
        placeholder = self.tmux("display-message", "-p", "-t", name, "#{window_id}")
        self.tmux("link-window", "-s", self.window, "-t", name + ":1")
        # Only remove the new placeholder, NEVER the shared agent window.
        self.tmux("kill-window", "-t", placeholder)
        self.tmux("select-window", "-t", name + ":1")
        client = TerminalClient(self.base + ["attach-session", "-t", name])
        self.addCleanup(client.close)
        return client

    def test_interactive_unicode_resize_detach_and_reconnect(self):
        first = self.viewer("viewer")
        os.write(first.master, "hello 日本語\r".encode())
        first.wait_for("hello 日本語".encode())
        first.resize(103, 31)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            size = self.tmux("list-clients", "-t", "viewer", "-F", "#{client_width}x#{client_height}")
            if size == "103x31":
                break
            time.sleep(0.05)
        self.assertEqual(size, "103x31")
        self.tmux("kill-session", "-t", "viewer")
        self.assertEqual(self.tmux("display-message", "-p", "-t", self.pane, "#{pane_dead}"), "0")
        second = self.viewer("reconnected")
        os.write(second.master, b"after-reconnect\r")
        second.wait_for(b"after-reconnect")

    def test_independent_viewers_do_not_switch_external_session(self):
        self.tmux("new-window", "-t", "agent:1", "/usr/bin/env", "--", "/bin/cat")
        self.tmux("select-window", "-t", "agent:1")
        selected = self.tmux("display-message", "-p", "-t", "agent", "#{window_id}")
        external = TerminalClient(self.base + ["attach-session", "-t", "agent"])
        self.addCleanup(external.close)
        one = self.viewer("one")
        two = self.viewer("two")
        os.write(one.master, b"shared-pane\r")
        two.wait_for(b"shared-pane")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "agent", "#{window_id}"), selected)
        self.tmux("kill-session", "-t", "one")
        self.tmux("kill-session", "-t", "two")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "agent", "#{window_id}"), selected)
        os.write(external.master, b"external-still-usable\r")
        external.wait_for(b"external-still-usable")

    def test_explicit_stop_targets_agent_not_unrelated_window(self):
        self.tmux("new-window", "-t", "agent:1", "/usr/bin/env", "--", "/bin/cat")
        other = self.tmux("display-message", "-p", "-t", "agent:1", "#{pane_id}")
        self.viewer("viewer")
        self.tmux("kill-pane", "-t", self.pane)
        panes = self.tmux("list-panes", "-a", "-F", "#{pane_id}").splitlines()
        self.assertNotIn(self.pane, panes)
        self.assertIn(other, panes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
