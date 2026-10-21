import unittest
from unittest import mock


from app_loader import load_app

APP = load_app("mpv_radio_tray_menu")


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


if __name__ == "__main__":
    unittest.main()
