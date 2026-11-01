#!/usr/bin/env python3
"""Discard automatic screen attachments in a generated XCTest specification."""

import os
from pathlib import Path
import plistlib
import sys
import tempfile


def test_targets(specification):
    if "TestConfigurations" in specification:
        return [target for configuration in specification["TestConfigurations"]
                for target in configuration.get("TestTargets", [])]
    return [value for value in specification.values()
            if isinstance(value, dict) and "TestBundlePath" in value]


def main():
    path = Path(sys.argv[1])
    specification = plistlib.loads(path.read_bytes())
    targets = test_targets(specification)
    if not targets:
        raise ValueError("No test targets found; refusing to run without attachment privacy settings")
    for target in targets:
        target["SystemAttachmentLifetime"] = "keepNever"
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary_path = Path(output.name)
            plistlib.dump(specification, output)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    if not all(target.get("SystemAttachmentLifetime") == "keepNever"
               for target in test_targets(plistlib.loads(path.read_bytes()))):
        raise ValueError("Automatic attachment privacy settings could not be verified")


if __name__ == "__main__":
    main()
