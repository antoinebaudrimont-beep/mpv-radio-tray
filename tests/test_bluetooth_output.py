import json
import pathlib
import tempfile
import unittest
from unittest import mock

from app_loader import load_app


ADDRESS = "11:22:33:AA:BB:CC"
OLD_SINK = "bluez_output.11_22_33_AA_BB_CC.1"
NEW_SINK = "bluez_output.11_22_33_AA_BB_CC.7"
STATION = ("Station", "https://example.test/radio")


class Clock:
    now = 0.0

    def monotonic(self):
        return self.now


class Cancellation:
    def __init__(self, clock):
        self.clock = clock
        self.cancelled = False

    def set(self):
        self.cancelled = True

    def is_set(self):
        return self.cancelled

    def wait(self, seconds):
        if not self.cancelled:
            self.clock.now += seconds
        return self.cancelled


class Process:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.returncode = 0


class MenuItem:
    def __init__(self):
        self.active = False

    def get_active(self):
        return self.active

    def set_active(self, value):
        self.active = value


class BluetoothOutputTest(unittest.TestCase):
    def setUp(self):
        self.app = load_app("radio_bluetooth_test")
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app.OUTPUT_FILE = pathlib.Path(self.directory.name) / "output.json"
        self.clock = Clock()
        self.workers = []
        self.callbacks = []
        self.processes = []
        self.commands = []
        self.connected = True
        self.sink = NEW_SINK
        self.actual_sink_index = 42
        self.actual_pid = None
        self.patch(self.app.time, "monotonic", side_effect=self.clock.monotonic)
        self.patch(self.app.threading, "Event", side_effect=lambda: Cancellation(self.clock))
        self.patch(self.app, "run_in_background", side_effect=lambda *job: self.workers.append(job))
        self.patch(self.app.GLib, "idle_add", side_effect=lambda *job: self.callbacks.append(job))
        self.patch(self.app, "remove_ipc_socket")
        self.patch(self.app.os, "killpg")
        self.popen = self.patch(self.app.subprocess, "Popen", side_effect=self.spawn)
        self.run = self.patch(self.app, "run_command", side_effect=self.command)
        self.ipc = self.patch(self.app, "mpv_command", return_value={"error": "success"})

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        result = patcher.start()
        self.addCleanup(patcher.stop)
        return result

    def spawn(self, command, **kwargs):
        process = Process(1000 + len(self.processes))
        self.processes.append(process)
        self.commands.append(command)
        return process

    def command(self, command, timeout=3):
        if command[:2] == ["bluetoothctl", "info"]:
            return "Connected: " + ("yes" if self.connected else "no")
        if command[:2] == ["bluetoothctl", "connect"]:
            self.connected = True
            return "Connection successful"
        if command == ["pactl", "-f", "json", "list", "sinks"]:
            return json.dumps([{"name": self.sink, "index": 42}] if self.sink else [])
        if command == ["pactl", "-f", "json", "list", "sink-inputs"]:
            return json.dumps([{
                "sink": self.actual_sink_index,
                "properties": {"application.process.id": str(
                    self.actual_pid if self.actual_pid is not None else self.processes[-1].pid)},
            }])
        if command == ["pactl", "get-default-sink"]:
            return "alsa_output.laptop"
        self.fail(f"Unexpected command: {command}")

    def worker(self):
        function, *args = self.workers.pop(0)
        function(*args)

    def callback(self):
        function, *args = self.callbacks.pop(0)
        self.assertFalse(function(*args))

    def prepare(self):
        self.worker()
        self.callback()

    def verify(self):
        self.worker()
        self.callback()

    def remember(self):
        self.app.OUTPUT_FILE.write_text(json.dumps({"output": ADDRESS.lower()}))
        self.app.load_output_preference()

    def test_preference_survives_a_fresh_application_instance_without_sink_id(self):
        self.app.select_bluetooth_output(ADDRESS)
        self.assertEqual(json.loads(self.app.OUTPUT_FILE.read_text()), {"output": ADDRESS})
        fresh = load_app("radio_relaunched_test")
        fresh.OUTPUT_FILE = self.app.OUTPUT_FILE
        fresh.load_output_preference()
        self.assertEqual(fresh.requested_output, ADDRESS)
        self.assertIsNone(fresh.selected_audio_device)
        self.assertIsNone(fresh.player)

    def test_startup_loads_preference_before_building_tray(self):
        self.remember()
        self.app.requested_output = None
        def tray():
            self.assertEqual(self.app.requested_output, ADDRESS)
            self.assertIsNone(self.app.player)
        self.patch(self.app, "start_indicator", side_effect=tray)
        self.app.main()
        self.popen.assert_not_called()

    def test_saved_target_is_resolved_before_mpv_then_verified_before_unmute(self):
        self.remember()
        self.app.selected_audio_device = "pulse/" + OLD_SINK
        self.app.play_station(*STATION)
        self.popen.assert_not_called()
        self.run.assert_not_called()  # Bluetooth work is queued, not on GTK's thread.
        self.prepare()
        command = self.commands[-1]
        self.assertIn("--audio-device=pulse/" + NEW_SINK, command)
        self.assertNotIn("--audio-device=pulse/" + OLD_SINK, command)
        self.assertIn("--mute=yes", command)
        self.assertIn("--audio-fallback-to-null=no", command)
        self.ipc.assert_not_called()
        self.assertEqual(self.app.output_phase, "verifying")
        socket_path = self.app.ipc_path
        self.verify()
        self.ipc.assert_called_once_with(["set_property", "mute", False], socket_path)
        self.assertEqual(self.app.output_status, "Bluetooth audio routed")
        self.assertEqual(self.app.output_phase, "ready")

    def test_connected_target_still_resolves_sink_without_reconnecting(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        calls = [call.args[0] for call in self.run.call_args_list]
        self.assertIn(["bluetoothctl", "info", ADDRESS], calls)
        self.assertNotIn(["bluetoothctl", "connect", ADDRESS], calls)
        self.assertIn(["pactl", "-f", "json", "list", "sinks"], calls)

    def test_disconnected_target_connects_before_playback(self):
        self.connected = False
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.run.assert_any_call(["bluetoothctl", "connect", ADDRESS],
                                 timeout=self.app.BLUETOOTH_CONNECT_TIMEOUT_SECONDS)
        self.assertIn("--mute=yes", self.commands[-1])

    def test_delayed_sink_is_awaited_and_fresh_name_used(self):
        self.connected = False
        self.remember()
        lookup = self.patch(self.app, "bluetooth_sink_name", side_effect=[None, None, NEW_SINK])
        self.app.play_station(*STATION)
        self.prepare()
        self.assertEqual(lookup.call_count, 3)
        self.assertEqual(self.clock.now, 1)
        self.assertIn("--audio-device=pulse/" + NEW_SINK, self.commands[-1])

    def test_connect_timeout_can_still_be_followed_by_a_usable_sink(self):
        self.connected = False
        original = self.command
        def timed_out_connect(command, timeout=3):
            result = original(command, timeout)
            return None if command[:2] == ["bluetoothctl", "connect"] else result
        self.run.side_effect = timed_out_connect
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.assertEqual(len(self.commands), 1)

    def test_sink_timeout_preserves_preference_and_stays_silent_until_retry(self):
        self.sink = None
        self.connected = False
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.popen.assert_not_called()
        self.assertEqual(self.app.output_phase, "unavailable")
        self.assertEqual(self.app.requested_output, ADDRESS)
        self.assertIsNone(self.app.selected_audio_device)
        self.assertEqual(self.clock.now, self.app.BLUETOOTH_SINK_TIMEOUT_SECONDS)
        for _ in range(4):
            self.app.watchdog_tick()
        self.assertFalse(self.workers)
        self.sink = NEW_SINK
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.assertEqual(self.app.output_phase, "ready")

    def test_clicking_checked_station_after_timeout_retries_exactly_once(self):
        self.remember()
        self.app.current_station = STATION
        self.app.output_phase = "unavailable"
        item = MenuItem()  # GTK has just toggled the clicked, checked item off.
        original = item.set_active
        def reactive_set_active(value):
            original(value)
            self.app.activate_station_menu_item(item, *STATION)
        item.set_active = reactive_set_active
        self.app.station_menu_items = [(item, *STATION)]
        self.app.activate_station_menu_item(item, *STATION)
        self.assertTrue(item.active)
        self.assertEqual(len(self.workers), 1)
        self.assertEqual(self.app.output_phase, "preparing")

    def test_programmatic_station_checkmark_does_not_launch_again(self):
        self.remember()
        item = MenuItem()
        original = item.set_active
        def reactive_set_active(value):
            original(value)
            self.app.activate_station_menu_item(item, *STATION)
        item.set_active = reactive_set_active
        self.app.station_menu_items = [(item, *STATION)]
        self.app.play_station(*STATION)
        self.assertTrue(item.active)
        self.assertEqual(len(self.workers), 1)

    def test_wrong_actual_sink_never_unmutes_or_reports_success(self):
        self.actual_sink_index = 1
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.ipc.assert_not_called()
        self.assertEqual(self.app.output_phase, "unavailable")
        self.assertIsNone(self.app.player)
        self.assertEqual(self.app.requested_output, ADDRESS)
        self.assertGreaterEqual(self.clock.now, self.app.OUTPUT_START_TIMEOUT_SECONDS)

    def test_another_process_on_target_sink_does_not_verify_mpv(self):
        self.actual_pid = 9999
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.ipc.assert_not_called()
        self.assertEqual(self.app.output_phase, "unavailable")

    def test_ipc_failure_does_not_report_success(self):
        self.ipc.return_value = {"error": "failure"}
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.assertEqual(self.app.output_phase, "unavailable")
        self.assertIsNone(self.app.player)

    def test_manual_reselection_of_checked_device_reapplies_route(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.sink = OLD_SINK
        self.app.select_bluetooth_output(ADDRESS)
        self.prepare()
        self.verify()
        self.assertEqual(len(self.commands), 2)
        self.assertIn("--audio-device=pulse/" + OLD_SINK, self.commands[-1])
        self.assertEqual(self.app.output_phase, "ready")

    def test_watchdog_restart_resolves_changed_sink_and_keeps_bluetooth(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.processes[-1].returncode = 1
        self.sink = OLD_SINK
        self.app.watchdog_tick()
        self.assertEqual(self.app.output_phase, "preparing")
        self.prepare()
        self.verify()
        self.assertIn("--audio-device=pulse/" + OLD_SINK, self.commands[-1])
        self.assertEqual(self.app.requested_output, ADDRESS)

    def test_watchdog_does_not_race_output_preparation_or_verification(self):
        self.remember()
        self.app.play_station(*STATION)
        self.app.watchdog_tick()
        self.assertEqual(len(self.workers), 1)
        self.prepare()
        self.app.watchdog_tick()
        self.assertEqual(len(self.workers), 1)

    def test_stop_discards_resolved_but_not_yet_applied_output(self):
        self.remember()
        self.app.play_station(*STATION)
        self.worker()
        self.app.stop_current_station()
        self.callback()
        self.popen.assert_not_called()
        self.assertIsNone(self.app.current_station)

    def test_station_switch_discards_old_preparation(self):
        self.remember()
        self.app.play_station(*STATION)
        self.worker()
        switched = ("Second station", "https://example.test/second")
        self.app.play_station(*switched)
        self.callback()
        self.popen.assert_not_called()
        self.prepare()
        self.assertEqual(self.commands[-1][-1], switched[1])

    def test_choosing_system_default_discards_old_bluetooth_callback(self):
        self.remember()
        self.app.play_station(*STATION)
        self.worker()
        self.app.choose_output(None)
        self.callback()
        self.assertEqual(len(self.commands), 1)
        self.assertFalse(any(arg.startswith("--audio-device=") for arg in self.commands[-1]))
        self.assertNotIn("--mute=yes", self.commands[-1])

    def test_quit_cancels_worker_without_late_connect_or_launch(self):
        self.remember()
        self.app.play_station(*STATION)
        self.app.quit_app()
        self.worker()
        self.run.assert_not_called()
        self.popen.assert_not_called()
        self.assertFalse(self.callbacks)

    def test_cancelled_verifier_cannot_unmute_new_player(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        old_socket = self.app.ipc_path
        self.app.choose_output(None)
        self.assertNotEqual(self.app.ipc_path, old_socket)
        self.worker()
        self.ipc.assert_not_called()
        self.assertFalse(self.callbacks)

    def test_late_verification_callback_cannot_stop_new_player(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        old = self.app.player
        generation = self.app.output_generation
        self.app.choose_output(None)
        new = self.app.player
        self.app.finish_bluetooth_playback(generation, old, False)
        self.assertIs(self.app.player, new)

    def test_checkmark_is_requested_preference_not_default_or_live_sink(self):
        self.remember()
        local, bluetooth = MenuItem(), MenuItem()
        self.app.output_menu_items = [(local, None), (bluetooth, ADDRESS)]
        self.app.selected_audio_device = None
        self.app.output_phase = "unavailable"
        self.app.update_output_menu_state()
        self.assertFalse(local.active)
        self.assertTrue(bluetooth.active)
        self.run.assert_not_called()

    def test_default_output_still_starts_without_overrides_or_bluetooth_commands(self):
        self.app.load_output_preference()  # No prior file.
        self.app.play_station(*STATION)
        self.assertFalse(any(arg.startswith("--audio-device=") for arg in self.commands[-1]))
        self.assertNotIn("--mute=yes", self.commands[-1])
        self.assertFalse(self.workers)
        self.run.assert_not_called()

    def test_computer_selection_resolves_local_sink_and_never_connects_bluetooth(self):
        self.app.current_station = STATION
        self.app.select_computer_output()
        self.prepare()
        self.assertIn("--audio-device=pulse/alsa_output.laptop", self.commands[-1])
        self.assertNotIn("--mute=yes", self.commands[-1])
        self.assertEqual(json.loads(self.app.OUTPUT_FILE.read_text()), {"output": "computer"})
        self.assertEqual([call.args[0] for call in self.run.call_args_list], [["pactl", "get-default-sink"]])

    def test_malformed_preference_fails_closed_until_user_chooses_output(self):
        for text in ('{', '{}', '{"output": "pulse/stale"}', '{"output": []}'):
            with self.subTest(text=text):
                self.app.OUTPUT_FILE.write_text(text)
                self.app.load_output_preference()
                self.app.play_station(*STATION)
                self.popen.assert_not_called()
                self.assertEqual(self.app.output_phase, "unavailable")
        self.app.choose_output(None)
        self.assertEqual(len(self.commands), 1)

    def test_selection_without_station_never_starts_radio(self):
        self.app.select_bluetooth_output(ADDRESS)
        self.prepare()
        self.popen.assert_not_called()
        self.assertEqual(self.app.output_status, "Output ready")

    def test_bluetooth_launch_error_is_reported_and_preserves_preference(self):
        self.popen.side_effect = OSError("mpv missing")
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.assertEqual(self.app.output_phase, "unavailable")
        self.assertIsNone(self.app.selected_audio_device)
        self.assertEqual(self.app.requested_output, ADDRESS)

    def test_sink_names_cover_pulseaudio_pipewire_and_case_changes(self):
        for name in (NEW_SINK, "bluez_sink.11_22_33_AA_BB_CC.a2dp_sink", NEW_SINK.lower()):
            with self.subTest(name=name):
                self.sink = name
                self.assertEqual(self.app.bluetooth_sink_name(ADDRESS), name)

    def test_sink_matching_uses_address_properties_and_prefers_a2dp(self):
        records = [
            {"name": "other", "properties": {"device.string": "22:22:33:AA:BB:CC"}},
            {"name": "headset", "properties": {"device.string": ADDRESS}},
            {"name": "renamed", "properties": {"api.bluez5.address": ADDRESS.lower(), "api.bluez5.profile": "a2dp-sink"}},
        ]
        self.run.return_value = json.dumps(records)
        self.run.side_effect = None
        self.assertEqual(self.app.bluetooth_sink_name(ADDRESS), "renamed")

    def test_old_pactl_text_fallback_preserves_sink_indices_and_process_identity(self):
        self.run.side_effect = [None, "42\t" + NEW_SINK + "\tmodule-bluez5-device.c\n",
                               None, 'Sink Input #8\n    Sink: 42\n    Properties:\n        application.process.id = "1234"\n']
        self.assertTrue(self.app.mpv_stream_uses_sink(1234, NEW_SINK))

    def test_missing_sink_index_or_process_metadata_cannot_verify_route(self):
        self.patch(self.app, "pactl_sinks", return_value=[{"name": NEW_SINK}])
        self.assertFalse(self.app.mpv_stream_uses_sink(1234, NEW_SINK))

    def test_bluetooth_worker_exception_becomes_unavailable(self):
        self.patch(self.app, "resolve_bluetooth_output", side_effect=RuntimeError("backend unavailable"))
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.assertEqual(self.app.output_phase, "unavailable")
        self.popen.assert_not_called()

    def test_stale_sink_with_failed_connection_does_not_start_mpv(self):
        self.connected = False
        original = self.command
        self.run.side_effect = lambda command, timeout=3: (
            None if command[:2] == ["bluetoothctl", "connect"] else original(command, timeout))
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.popen.assert_not_called()
        self.assertEqual(self.app.output_phase, "unavailable")

    def test_lost_route_is_muted_and_stopped_without_losing_preference(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        socket_path = self.app.ipc_path
        self.actual_sink_index = 1
        self.app.watchdog_tick()
        self.worker()
        self.callback()
        self.ipc.assert_any_call(["set_property", "mute", True], socket_path)
        self.assertEqual(self.app.output_phase, "unavailable")
        self.assertIsNone(self.app.player)
        self.assertEqual(self.app.requested_output, ADDRESS)

    def test_stream_eof_still_restarts_instead_of_being_mistaken_for_route_loss(self):
        self.remember()
        self.app.play_station(*STATION)
        self.prepare()
        self.verify()
        self.clock.now = self.app.STARTUP_GRACE_SECONDS + 1
        self.patch(self.app, "read_watchdog_status", return_value={
            "ipc_ok": True, "paused_for_cache": False, "eof_reached": True, "time_pos": 5,
        })
        self.app.watchdog_tick()
        self.worker()
        self.callback()
        self.assertEqual(self.app.output_phase, "preparing")
        self.prepare()
        self.assertEqual(len(self.commands), 2)
        self.assertIn("--audio-device=pulse/" + NEW_SINK, self.commands[-1])


class CommandDeadlineTest(unittest.TestCase):
    def test_ipc_events_without_a_response_do_not_extend_deadline_forever(self):
        app = load_app("radio_ipc_deadline_test")
        clock = Clock()
        sock = mock.MagicMock()
        sock.__enter__.return_value = sock
        def event(_size):
            clock.now += 0.6
            return b'{"event":"property-change"}\n'
        sock.recv.side_effect = event
        with (mock.patch.object(app.time, "monotonic", side_effect=clock.monotonic),
              mock.patch.object(app.socket, "socket", return_value=sock)):
            self.assertIsNone(app.mpv_command(["get_property", "mute"], "/tmp/unused.sock"))
        self.assertEqual(sock.recv.call_count, 2)

    def test_missing_command_and_command_timeout_fail_without_raising(self):
        app = load_app("radio_subprocess_test")
        for error in (FileNotFoundError(), app.subprocess.TimeoutExpired("bluetoothctl", 3)):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(app.subprocess, "run", side_effect=error):
                    self.assertIsNone(app.run_command(["bluetoothctl", "info", ADDRESS]))


if __name__ == "__main__":
    unittest.main()
