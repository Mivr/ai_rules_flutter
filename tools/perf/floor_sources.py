"""Dart sources before and after a bench edit, for the floor's recompile.

The resident compiler must see the pre-edit program for its untimed first
compile and the edited one for the timed recompile. The bench applies the
edit before it builds, so a snapshot of the sources is taken before the
edit; ``to_old`` puts the pre-edit bytes of the changed files back and
``to_new`` restores the edited bytes (identical to what Bazel built, so no
later build sees a difference).
"""

import os
import pathlib


class SourceSwap:
    """Swaps changed Dart files between their pre-edit and edited bytes."""

    def __init__(self, before):
        self.before = dict(before)
        self.after = {}

    @classmethod
    def snapshot(cls, root):
        """Pre-edit bytes of every .dart file under root (no bazel-*)."""
        files = {}
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if not d.startswith(("bazel-", "."))]
            for name in filenames:
                if name.endswith(".dart"):
                    path = os.path.join(dirpath, name)
                    with open(path, "rb") as fh:
                        files[path] = fh.read()
        return cls(files)

    def changed(self):
        """Paths whose current bytes differ from the snapshot."""
        paths = []
        for path, old in sorted(self.before.items()):
            with open(path, "rb") as fh:
                if fh.read() != old:
                    paths.append(path)
        return paths

    def to_old(self):
        """Writes the pre-edit bytes of the changed files."""
        for path in self.changed():
            with open(path, "rb") as fh:
                self.after[path] = fh.read()
            with open(path, "wb") as fh:
                fh.write(self.before[path])

    def to_new(self):
        """Restores the edited bytes written over by ``to_old``."""
        for path, data in self.after.items():
            with open(path, "wb") as fh:
                fh.write(data)

    def invalidated(self):
        """file:// URIs of the edited files."""
        return [pathlib.Path(p).resolve().as_uri() for p in self.after]
