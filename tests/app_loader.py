"""Load the Linux script for headless unit tests; hardware/GTK need acceptance tests."""
import importlib.machinery
import importlib.util
import pathlib
import types
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "mpv-radio-tray"


def load_app(name):
    gi = types.ModuleType("gi")
    gi.require_version = mock.Mock()
    repository = types.ModuleType("gi.repository")
    repository.GLib = types.SimpleNamespace(
        idle_add=mock.Mock(), unix_signal_add=mock.Mock(),
        timeout_add_seconds=mock.Mock(), PRIORITY_DEFAULT=0,
    )
    repository.Gtk = types.SimpleNamespace(main=mock.Mock(), main_quit=mock.Mock())
    loader = importlib.machinery.SourceFileLoader(name, str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    app = importlib.util.module_from_spec(spec)
    with mock.patch.dict("sys.modules", {"gi": gi, "gi.repository": repository}):
        loader.exec_module(app)
    return app
