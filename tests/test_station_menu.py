import importlib.util
import importlib.machinery
import pathlib
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "mpv-radio-tray"
LOADER = importlib.machinery.SourceFileLoader("mpv_radio_tray", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class FakeMenuItem:
    def __init__(self, active):
        self.active = active

    def get_active(self):
        return self.active

    def set_active(self, active):
        self.active = active


class StationMenuTest(unittest.TestCase):
    def tearDown(self):
        APP.current_station = None
        APP.station_menu_items = []

    def test_unchecking_station_after_stop_does_not_restart_it(self):
        item = FakeMenuItem(False)
        APP.current_station = None

        with mock.patch.object(APP, "play_station") as play_station:
            APP.activate_station_menu_item(item, "Station", "https://example.test/radio")

        play_station.assert_not_called()

    def test_activating_station_starts_it(self):
        item = FakeMenuItem(True)

        with mock.patch.object(APP, "play_station") as play_station:
            APP.activate_station_menu_item(item, "Station", "https://example.test/radio")

        play_station.assert_called_once_with("Station", "https://example.test/radio")

    def test_active_station_cannot_be_unchecked_without_stopping(self):
        item = FakeMenuItem(False)
        APP.current_station = ("Station", "https://example.test/radio")

        with mock.patch.object(APP, "play_station") as play_station:
            APP.activate_station_menu_item(item, *APP.current_station)

        self.assertTrue(item.get_active())
        play_station.assert_not_called()


class BluetoothOutputTest(unittest.TestCase):
    def test_connects_and_selects_sink_when_it_becomes_available(self):
        sink_name = "bluez_output.11_22_33_44_55_66.1"

        with (
            mock.patch.object(APP, "run_command") as run_command,
            mock.patch.object(
                APP, "bluetooth_sink_name", side_effect=[None, sink_name]
            ),
            mock.patch.object(APP, "set_output_sink") as set_output_sink,
            mock.patch.object(APP.time, "monotonic", side_effect=[0, 0, 0.5]),
            mock.patch.object(APP.time, "sleep") as sleep,
        ):
            APP.select_bluetooth_output("11:22:33:44:55:66")

        run_command.assert_called_once_with(
            ["bluetoothctl", "connect", "11:22:33:44:55:66"],
            timeout=APP.BLUETOOTH_CONNECT_TIMEOUT_SECONDS,
        )
        sleep.assert_called_once_with(0.5)
        set_output_sink.assert_called_once_with(sink_name)

    def test_does_not_change_output_when_connection_times_out(self):
        with (
            mock.patch.object(APP, "run_command") as run_command,
            mock.patch.object(APP, "bluetooth_sink_name") as bluetooth_sink_name,
            mock.patch.object(APP, "set_output_sink") as set_output_sink,
            mock.patch.object(
                APP.time,
                "monotonic",
                side_effect=[0, APP.BLUETOOTH_CONNECT_TIMEOUT_SECONDS],
            ),
        ):
            APP.select_bluetooth_output("11:22:33:44:55:66")

        run_command.assert_called_once()
        bluetooth_sink_name.assert_not_called()
        set_output_sink.assert_not_called()


if __name__ == "__main__":
    unittest.main()
