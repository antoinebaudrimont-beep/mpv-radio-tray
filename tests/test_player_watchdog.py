import importlib.machinery
import importlib.util
import os
import pathlib
import select
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "mpv-radio-tray"
LOADER = importlib.machinery.SourceFileLoader(
    "mpv_radio_tray_watchdog",
    str(SCRIPT),
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class FakePlayer:
    pid = 1234

    def __init__(self, returncode=None):
        self.returncode = returncode

    def poll(self):
        return self.returncode


class PlayerLaunchTest(unittest.TestCase):
    def tearDown(self):
        APP.player = None
        APP.selected_audio_device = None

    def test_uses_radio_specific_cache_limits(self):
        process = FakePlayer()

        with (
            mock.patch.object(APP, "remove_ipc_socket"),
            mock.patch.object(APP, "new_ipc_path", return_value="/tmp/radio.sock"),
            mock.patch.object(APP.subprocess, "Popen", return_value=process) as popen,
        ):
            APP.start_player("Station", "https://example.test/radio")

        command = popen.call_args.args[0]
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(pathlib.Path(command[1]), SCRIPT)
        self.assertEqual(command[2], APP.MPV_CHILD_MODE)
        self.assertEqual(command[3], str(os.getpid()))
        self.assertIn("--network-timeout=15", command)
        self.assertIn("--cache=yes", command)
        self.assertIn("--demuxer-max-bytes=16M", command)
        self.assertIn("--demuxer-max-back-bytes=1M", command)
        self.assertIn("--demuxer-readahead-secs=10", command)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])


@unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux prctl")
class ParentDeathSignalTest(unittest.TestCase):
    def test_parent_race_guard_exits_before_exec(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                APP.MPV_CHILD_MODE,
                "0",
                sys.executable,
                "-c",
                "raise SystemExit(42)",
            ],
            timeout=5,
        )

        self.assertEqual(result.returncode, 1)

    def test_sigkill_of_parent_terminates_child(self):
        parent_code = "\n".join(
            [
                "import os, subprocess, sys, time",
                "child = subprocess.Popen([",
                f"    sys.executable, {str(SCRIPT)!r}, {APP.MPV_CHILD_MODE!r},",
                "    str(os.getpid()), sys.executable, '-c', 'import time; time.sleep(30)',",
                "], start_new_session=True)",
                "print(child.pid, flush=True)",
                "time.sleep(30)",
            ]
        )
        parent = subprocess.Popen(
            [sys.executable, "-c", parent_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        child_pid = None

        try:
            readable, _, _ = select.select([parent.stdout], [], [], 5)
            self.assertTrue(readable, "launcher parent did not report its child PID")
            child_pid = int(parent.stdout.readline())

            os.kill(parent.pid, signal.SIGKILL)
            parent.wait(timeout=5)

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and self.process_is_alive(child_pid):
                time.sleep(0.05)

            self.assertFalse(self.process_is_alive(child_pid))
        finally:
            if parent.poll() is None:
                os.kill(parent.pid, signal.SIGKILL)
                parent.wait(timeout=5)
            if child_pid is not None and self.process_is_alive(child_pid):
                os.killpg(child_pid, signal.SIGKILL)
            parent.stdout.close()
            parent.stderr.close()

    @staticmethod
    def process_is_alive(pid):
        try:
            state = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2]
        except FileNotFoundError:
            return False
        return state != "Z"


class ShutdownTest(unittest.TestCase):
    def tearDown(self):
        APP.player = None

    def test_stop_player_terminates_and_reaps_process_group_leader(self):
        process = mock.Mock(pid=1234)
        process.poll.return_value = None
        APP.player = process

        with mock.patch.object(APP.os, "killpg") as killpg:
            APP.stop_player()

        killpg.assert_called_once_with(process.pid, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=2)
        self.assertIsNone(APP.player)

    def test_quit_stops_player_before_leaving_gtk_loop(self):
        with (
            mock.patch.object(APP, "stop_player") as stop_player,
            mock.patch.object(APP.Gtk, "main_quit") as main_quit,
        ):
            result = APP.quit_app()

        stop_player.assert_called_once_with()
        main_quit.assert_called_once_with()
        self.assertFalse(result)

    def test_main_registers_logout_signals_and_cleans_up_when_gtk_exits(self):
        tray = object()

        with (
            mock.patch.object(APP, "start_indicator", return_value=tray),
            mock.patch.object(APP.GLib, "unix_signal_add") as unix_signal_add,
            mock.patch.object(APP.GLib, "timeout_add_seconds"),
            mock.patch.object(APP.Gtk, "main"),
            mock.patch.object(APP, "stop_player") as stop_player,
        ):
            result = APP.main()

        self.assertEqual(
            unix_signal_add.call_args_list,
            [
                mock.call(APP.GLib.PRIORITY_DEFAULT, APP.signal.SIGTERM, APP.quit_app),
                mock.call(APP.GLib.PRIORITY_DEFAULT, APP.signal.SIGHUP, APP.quit_app),
                mock.call(APP.GLib.PRIORITY_DEFAULT, APP.signal.SIGINT, APP.quit_app),
            ],
        )
        stop_player.assert_called_once_with()
        self.assertIs(result, tray)


class WatchdogTest(unittest.TestCase):
    def setUp(self):
        self.player = FakePlayer()
        self.socket_path = "/tmp/radio.sock"
        APP.player = self.player
        APP.current_station = ("Station", "https://example.test/radio")
        APP.ipc_path = self.socket_path
        APP.started_at = 0
        APP.last_restart_at = None
        APP.last_ipc_ok_at = 0
        APP.last_time_pos = None
        APP.last_time_pos_changed_at = 0
        APP.time_pos_has_moved = False
        APP.buffering_since = None
        APP.watchdog_check_in_progress = False

    def tearDown(self):
        APP.player = None
        APP.current_station = None
        APP.ipc_path = None
        APP.last_restart_at = None
        APP.watchdog_check_in_progress = False

    def status(self, paused=False, time_pos=None, eof=False, ipc_ok=True):
        return {
            "ipc_ok": ipc_ok,
            "paused_for_cache": paused,
            "time_pos": time_pos,
            "eof_reached": eof,
        }

    def test_tick_collects_status_in_background(self):
        with (
            mock.patch.object(APP.time, "monotonic", return_value=20),
            mock.patch.object(APP, "run_in_background") as run_in_background,
        ):
            self.assertTrue(APP.watchdog_tick())

        run_in_background.assert_called_once_with(
            APP.check_watchdog_status,
            self.player,
            self.socket_path,
            True,
        )
        self.assertTrue(APP.watchdog_check_in_progress)

    def test_unexpected_status_error_clears_in_progress_state(self):
        APP.watchdog_check_in_progress = True

        with (
            mock.patch.object(
                APP,
                "read_watchdog_status",
                side_effect=RuntimeError("unexpected"),
            ),
            mock.patch.object(APP.GLib, "idle_add") as idle_add,
        ):
            APP.check_watchdog_status(self.player, self.socket_path, True)

        callback, monitored_player, monitored_ipc_path, status = (
            idle_add.call_args.args
        )
        self.assertIs(callback, APP.apply_watchdog_status)
        self.assertIsNone(status)

        callback(monitored_player, monitored_ipc_path, status)
        self.assertFalse(APP.watchdog_check_in_progress)

    def test_idle_callback_error_clears_in_progress_state(self):
        APP.watchdog_check_in_progress = True

        with (
            mock.patch.object(APP, "read_watchdog_status", return_value={}),
            mock.patch.object(
                APP.GLib,
                "idle_add",
                side_effect=RuntimeError("GTK loop unavailable"),
            ),
        ):
            APP.check_watchdog_status(self.player, self.socket_path, True)

        self.assertFalse(APP.watchdog_check_in_progress)

    def test_continuous_buffering_restarts_only_after_threshold(self):
        with (
            mock.patch.object(
                APP.time,
                "monotonic",
                side_effect=[100, 124, 125],
            ),
            mock.patch.object(APP, "restart_current_station") as restart,
        ):
            APP.apply_watchdog_status(
                self.player,
                self.socket_path,
                self.status(paused=True),
            )
            APP.apply_watchdog_status(
                self.player,
                self.socket_path,
                self.status(paused=True),
            )
            restart.assert_not_called()

            APP.apply_watchdog_status(
                self.player,
                self.socket_path,
                self.status(paused=True),
            )

        restart.assert_called_once_with("buffering too long")

    def test_playback_resume_clears_buffering_state(self):
        APP.buffering_since = 10

        with mock.patch.object(APP.time, "monotonic", return_value=20):
            APP.apply_watchdog_status(
                self.player,
                self.socket_path,
                self.status(paused=False),
            )

        self.assertIsNone(APP.buffering_since)

    def test_stalled_playback_time_restarts_after_threshold(self):
        APP.last_time_pos = 42
        APP.last_time_pos_changed_at = 100
        APP.time_pos_has_moved = True

        with (
            mock.patch.object(APP.time, "monotonic", return_value=130),
            mock.patch.object(APP, "restart_current_station") as restart,
        ):
            APP.apply_watchdog_status(
                self.player,
                self.socket_path,
                self.status(time_pos=42),
            )

        restart.assert_called_once_with("playback time stalled")

    def test_restart_cooldown_prevents_rapid_restarts(self):
        APP.last_restart_at = 100

        with (
            mock.patch.object(APP.time, "monotonic", side_effect=[120, 130]),
            mock.patch.object(APP, "stop_player") as stop_player,
            mock.patch.object(APP, "start_player") as start_player,
        ):
            APP.restart_current_station("first check")
            stop_player.assert_not_called()

            APP.restart_current_station("after cooldown")

        stop_player.assert_called_once_with()
        start_player.assert_called_once_with(*APP.current_station)

    def test_stale_status_from_previous_player_is_ignored(self):
        previous_player = FakePlayer()
        APP.buffering_since = 10

        with (
            mock.patch.object(APP.time, "monotonic") as monotonic,
            mock.patch.object(APP, "restart_current_station") as restart,
        ):
            APP.apply_watchdog_status(
                previous_player,
                self.socket_path,
                self.status(paused=True),
            )

        monotonic.assert_not_called()
        restart.assert_not_called()
        self.assertEqual(APP.buffering_since, 10)

    def test_unexpected_player_exit_restarts_without_ipc_check(self):
        self.player.returncode = 1

        with (
            mock.patch.object(APP, "restart_current_station") as restart,
            mock.patch.object(APP, "run_in_background") as run_in_background,
        ):
            self.assertTrue(APP.watchdog_tick())

        restart.assert_called_once_with("mpv exited")
        run_in_background.assert_not_called()

    def test_reads_only_buffering_time_and_eof_properties(self):
        with (
            mock.patch.object(
                APP,
                "mpv_command",
                return_value={"error": "success", "data": True},
            ) as mpv_command,
            mock.patch.object(
                APP,
                "mpv_property",
                side_effect=[12.5, False],
            ) as mpv_property,
        ):
            status = APP.read_watchdog_status(self.socket_path, True)

        mpv_command.assert_called_once_with(
            ["get_property", "paused-for-cache"],
            self.socket_path,
        )
        self.assertEqual(
            mpv_property.call_args_list,
            [
                mock.call("time-pos", self.socket_path),
                mock.call("eof-reached", self.socket_path),
            ],
        )
        self.assertEqual(
            status,
            {
                "ipc_ok": True,
                "paused_for_cache": True,
                "time_pos": 12.5,
                "eof_reached": False,
            },
        )


if __name__ == "__main__":
    unittest.main()
