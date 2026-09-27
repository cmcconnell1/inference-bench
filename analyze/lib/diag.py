"""--debug support bundle for the Python analysis tools (standard library only).

Writes /var/tmp/chr-diag/<tool>-<UTC>/ with manifest.txt, environment.txt,
copies of inputs and outputs, then a .tgz next to it, and prints the two
DEBUG BUNDLE lines last.
"""
from __future__ import annotations

import os
import platform
import re
import shutil
import sys
import tarfile
import time
from pathlib import Path

SECRET = re.compile(r"(TOKEN|SECRET|PASSWORD|KEY|PASS)", re.I)


class Bundle:
    """Collects files and notes into a timestamped directory, then tars it.

    All methods are no-ops when enabled is False so callers need no branching.
    """

    def __init__(self, tool: str, enabled: bool):
        self.enabled = enabled
        self.dir: Path | None = None
        if not enabled:
            return
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        self.dir = Path("/var/tmp/chr-diag") / f"{tool}-{stamp}"
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "environment.txt").write_text(
            "\n".join([
                f"tool: {tool}",
                f"invocation: {' '.join(sys.argv)}",
                f"utc: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
                f"python: {sys.version.split()[0]}",
                f"platform: {platform.platform()}",
                "",
                "env (secrets redacted):",
                *[f"  {k}={'[REDACTED]' if SECRET.search(k) else v}" for k, v in sorted(os.environ.items())],
            ]) + "\n"
        )
        # manifest.txt is written at finish(): one line per file, tab separated.
        self.manifest = ["environment.txt\tinvocation, versions, redacted env"]

    def add(self, path: Path, desc: str) -> None:
        """Copy a file or directory into the bundle and record it."""
        if not self.enabled or not path.exists():
            return
        dest = self.dir / path.name
        if path.is_dir():
            shutil.copytree(path, dest, dirs_exist_ok=True)
        else:
            shutil.copy2(path, dest)
        self.manifest.append(f"{path.name}\t{desc}")

    def text(self, name: str, content: str, desc: str) -> None:
        """Write generated text (for example the rendered report) into the bundle."""
        if not self.enabled:
            return
        (self.dir / name).write_text(content)
        self.manifest.append(f"{name}\t{desc}")

    def finish(self) -> None:
        """Write the manifest, build the .tgz, print the two DEBUG BUNDLE lines last."""
        if not self.enabled:
            return
        (self.dir / "manifest.txt").write_text("\n".join(self.manifest) + "\n")
        tgz = self.dir.with_suffix(".tgz")
        with tarfile.open(tgz, "w:gz") as tar:
            tar.add(self.dir, arcname=self.dir.name)
        print(f"DEBUG BUNDLE: {self.dir}")
        print(f"DEBUG BUNDLE TAR: {tgz}")
