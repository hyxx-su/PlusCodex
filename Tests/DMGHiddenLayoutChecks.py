"""Validate initial-viewport placement without modifying Finder preferences."""
import pathlib
import runpy
import sys
import tempfile
from ds_store import DSStore
from unittest.mock import patch, Mock

project = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="pluscodex-layout-") as directory:
    root = pathlib.Path(directory)
    (root / ".background").mkdir()
    (root / ".background/install.png").touch()
    (root / ".unexpected-resource").mkdir()
    # This unit test checks layout only. Real aliases require the HFS+ image
    # used by package-dmg.sh; APFS inode IDs can exceed the alias format.
    with patch("mac_alias.Alias.for_file", return_value=Mock(to_bytes=lambda: b"layout-test")), patch.object(sys, "argv", ["LayoutDMG.py", str(root)]):
        runpy.run_path(str(project / "LayoutDMG.py"), run_name="__main__")
    with DSStore.open(str(root / ".DS_Store"), "r") as store:
        assert store["PlusCodex.app"]["Iloc"] == (187, 250)
        assert store["Applications"]["Iloc"] == (533, 250)
        for name in [".background", ".DS_Store", ".unexpected-resource", ".Trashes", ".fseventsd"]:
            assert store[name]["Iloc"][1] >= 1000
        assert store["."]["icvp"]["arrangeBy"] == "none"
print("PASS: hidden resources outside installation viewport; visible icons unchanged")
