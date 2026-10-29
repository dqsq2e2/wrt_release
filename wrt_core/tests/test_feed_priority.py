#!/usr/bin/env python3
"""Run with OPENWRT_SOURCE=/path/to/openwrt python3 test_feed_priority.py.

Use the source tree's real feeds installer with fixture package metadata.
Only the Makefile scanner is replaced, so no toolchain or downloads are needed.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BASE_PATH = Path(__file__).resolve().parents[1]

SCANNER = """\
import os
from pathlib import Path
import sys

directory, output = sys.argv[1:]
records = []
for parent, _, files in os.walk(directory, followlinks=True):
    if "Makefile" not in files:
        continue
    path = Path(parent) / "Makefile"
    record = f"Source-Makefile: {path}\\n" + path.read_text() + "\\n"
    records.append(record)
    if directory == "package":
        info = Path("tmp/info") / (".packageinfo-" + str(path.parent)[8:].replace("/", "_"))
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text(record)
Path(output).write_text("".join(records))
"""


class FeedPriorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = os.environ.get("OPENWRT_SOURCE")
        if not source:
            raise unittest.SkipTest("Set OPENWRT_SOURCE to an OpenWrt source tree")
        cls.source = Path(source).resolve()
        for name in ("feeds", "metadata.pm"):
            if not (cls.source / "scripts" / name).is_file():
                raise RuntimeError(f"Missing scripts/{name} in {cls.source}")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="feed-priority-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("scripts", "include", "package", "feeds", "tmp/info"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in ("feeds", "metadata.pm"):
            target = self.root / "scripts" / name
            target.write_text((self.source / "scripts" / name).read_text())
            target.chmod(0o755)
        (self.root / "scripts/scan.py").write_text(SCANNER)
        (self.root / "Makefile").write_text(
            "prepare-mk:\n\t@:\n"
            "prepare-tmpinfo:\n"
            "\t@python3 scripts/scan.py package tmp/.packageinfo\n"
            "\t@: > tmp/.targetinfo\n"
        )
        (self.root / "include/scan.mk").write_text(
            "all:\n"
            '\t@python3 scripts/scan.py "$(SCAN_DIR)" "$(TMP_DIR)/.$(SCAN_TARGET)"\n'
        )
        (self.root / "feeds.conf").write_text(
            "src-dummy packages\nsrc-dummy custom_feed\n"
        )
        self.package("feeds/packages/net/miniupnpd")
        self.package("feeds/packages/net/shared-plugin")
        self.package("feeds/packages/net/core-plugin")
        self.package("feeds/packages/net/standard-dependency")
        self.package("feeds/packages/net/standard-only")
        self.package(
            "feeds/custom_feed/core-plugin",
            depends="+miniupnpd +shared-plugin +standard-dependency",
        )
        self.package("feeds/custom_feed/shared-plugin")
        self.package("package/network/services/core-plugin")

    def package(self, relative, depends=""):
        directory = self.root / relative
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Makefile").write_text(
            f"Package: {directory.name}\nDepends: {depends}\n"
        )
        return directory

    def shell(self, body):
        result = subprocess.run(
            ["bash", "-euc", body, "feed-test", str(BASE_PATH)],
            cwd=self.root,
            env={**os.environ, "TOPDIR": str(self.root)},
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def install(self):
        self.shell(
            'source <(sed "s/\\r$//" "$1/modules/feeds.sh")\n'
            'source <(sed "s/\\r$//" "$1/modules/custom_feed.sh")\n'
            'network_retry() { "$@"; }\n'
            "install_feeds\n"
        )

    def check_plugin_paths(self):
        for name in ("shared-plugin", "core-plugin"):
            link = self.root / "package/feeds/custom_feed" / name
            self.assertTrue(link.is_symlink(), str(link))
            self.assertEqual(link.resolve(), self.root / "feeds/custom_feed" / name)
            self.assertFalse(
                (self.root / "package/feeds/packages" / name).exists()
            )
        for name in ("standard-dependency", "standard-only"):
            self.assertTrue(
                (self.root / "package/feeds/packages" / name).is_symlink()
            )

    def test_core_miniupnpd_is_preserved(self):
        self.package("package/network/services/miniupnpd")
        self.install()
        self.assertFalse((self.root / "package/feeds/packages/miniupnpd").exists())
        self.check_plugin_paths()

    def test_feed_miniupnpd_is_used_without_core_copy(self):
        self.install()
        link = self.root / "package/feeds/packages/miniupnpd"
        self.assertEqual(link.resolve(), self.root / "feeds/packages/net/miniupnpd")
        self.check_plugin_paths()


if __name__ == "__main__":
    unittest.main()
