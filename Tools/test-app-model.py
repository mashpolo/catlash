#!/usr/bin/env python3
"""Run App coordination regressions against real LibraryModel sources on macOS.

Run `swift test` first to build PacketBridge, then invoke this script. The harness
replaces only system VPN and filesystem observation; it never operates a device.
"""

import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build" / "debug"
SOURCES = [
    "LibraryModel.swift", "LibraryModel+Subscriptions.swift", "LibraryModel+Sync.swift",
    "LibraryModel+Nodes.swift", "LibraryModel+Resources.swift",
    "LibraryModel+ResourceRefresh.swift", "LibraryModel+Configuration.swift", "LibraryModel+Rules.swift",
]

if not (BUILD / "PacketBridge.o").is_file():
    raise SystemExit("PacketBridge build is missing. Run swift test before this script.")

with tempfile.TemporaryDirectory(prefix="flclash-app-model-") as temporary:
    work = pathlib.Path(temporary)
    sources = []
    for name in SOURCES:
        source = work / name
        source.write_text("import PacketBridge\n" + (ROOT / "ProbeApp" / name).read_text())
        sources.append(str(source))
    executable = work / "app-model-tests"
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-I", str(BUILD),
        "-I", str(ROOT / ".build/checkouts/Yams/Sources/CYaml/include"),
        "-F", str(BUILD),
        *[str(BUILD / (name + ".o")) for name in ["PacketBridge", "Yams", "CYaml"]],
        "-framework", "MihomoBridge", "-lresolv",
        *sources, str(ROOT / "Tools" / "AppModelTests.swift"), "-o", str(executable),
    ]
    compiled = subprocess.run(command)
    if compiled.returncode:
        sys.exit(compiled.returncode)
    sys.exit(subprocess.run([str(executable)]).returncode)
