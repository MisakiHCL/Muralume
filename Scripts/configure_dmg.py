#!/usr/bin/env python3

"""Create and verify Finder layout metadata without launching Finder."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Dict, List, Mapping, Sequence, Tuple


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
VENDOR_DIRECTORY = SCRIPT_DIRECTORY / "vendor"
sys.path.insert(0, str(VENDOR_DIRECTORY / "ds_store"))
sys.path.insert(0, str(VENDOR_DIRECTORY / "mac_alias"))

from ds_store import DSStore  # noqa: E402
from mac_alias import (  # noqa: E402
    Alias,
    Bookmark,
    kBookmarkPath,
    kBookmarkVolumeName,
)


WINDOW_ORIGIN = (160, 120)
WINDOW_SIZE = (660, 412)
APPLICATION_POSITION = (184, 196)
APPLICATIONS_POSITION = (476, 196)
ICON_SIZE = 128.0
TEXT_SIZE = 14.0
DEFAULT_VIEW = (b"type", b"icnv")


class LayoutValidationError(RuntimeError):
    """Raised when generated Finder metadata differs from the contract."""


def finder_window_settings() -> Dict[str, object]:
    origin_x, origin_y = WINDOW_ORIGIN
    width, height = WINDOW_SIZE
    return {
        "ShowStatusBar": False,
        "WindowBounds": f"{{{{{origin_x}, {origin_y}}}, {{{width}, {height}}}}}",
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }


def icon_view_settings(background_alias: Alias) -> Dict[str, object]:
    return {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": background_alias.to_bytes(),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": TEXT_SIZE,
        "iconSize": ICON_SIZE,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }


def resolve_layout_paths(
    mount_path: str,
    application_name: str,
    background_file_name: str,
) -> Tuple[Path, Path, Path, Path]:
    mount_directory = Path(mount_path).resolve(strict=True)
    if not mount_directory.is_dir():
        raise LayoutValidationError(f"Mount path is not a directory: {mount_directory}")

    if Path(application_name).name != application_name:
        raise LayoutValidationError("Application name must not contain path components.")
    if Path(background_file_name).name != background_file_name:
        raise LayoutValidationError("Background name must not contain path components.")

    application_path = mount_directory / application_name
    background_path = mount_directory / ".background" / background_file_name
    ds_store_path = mount_directory / ".DS_Store"

    if not application_path.is_dir():
        raise LayoutValidationError(f"Application is missing: {application_path}")
    if not background_path.is_file():
        raise LayoutValidationError(f"Background is missing: {background_path}")

    return mount_directory, application_path, background_path, ds_store_path


def configure_layout(
    mount_path: str,
    application_name: str,
    background_file_name: str,
    volume_name: str,
) -> None:
    mount_directory, _, background_path, ds_store_path = resolve_layout_paths(
        mount_path,
        application_name,
        background_file_name,
    )
    background_alias = Alias.for_file(os.fspath(background_path))
    background_bookmark = Bookmark.for_file(os.fspath(background_path))

    with DSStore.open(os.fspath(ds_store_path), "w+") as metadata:
        metadata["."]["vSrn"] = ("long", 1)
        metadata["."]["bwsp"] = finder_window_settings()
        metadata["."]["icvp"] = icon_view_settings(background_alias)
        metadata["."]["pBBk"] = background_bookmark
        metadata["."]["icvl"] = DEFAULT_VIEW
        metadata[application_name]["Iloc"] = APPLICATION_POSITION
        metadata["Applications"]["Iloc"] = APPLICATIONS_POSITION

    verify_layout(
        os.fspath(mount_directory),
        application_name,
        background_file_name,
        volume_name,
    )


def normalized_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


def require_equal(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise LayoutValidationError(
            f"Unexpected {label}: expected {expected!r}, found {actual!r}"
        )


def require_mapping_values(
    label: str,
    actual: Mapping[str, object],
    expected: Mapping[str, object],
) -> None:
    for key, expected_value in expected.items():
        require_equal(f"{label}.{key}", actual.get(key), expected_value)


def verify_background_alias(
    encoded_alias: object,
    background_file_name: str,
    volume_name: str,
) -> None:
    if not isinstance(encoded_alias, (bytes, bytearray)):
        raise LayoutValidationError("Background alias is not binary data.")

    background_alias = Alias.from_bytes(bytes(encoded_alias))
    require_equal(
        "background alias volume",
        normalized_text(background_alias.volume.name),
        volume_name,
    )
    require_equal(
        "background alias filename",
        normalized_text(background_alias.target.filename),
        background_file_name,
    )
    expected_path = f"/.background/{background_file_name}"
    require_equal(
        "background alias path",
        normalized_text(background_alias.target.posix_path),
        expected_path,
    )


def verify_background_bookmark(
    bookmark: object,
    background_file_name: str,
    volume_name: str,
) -> None:
    if not isinstance(bookmark, Bookmark):
        raise LayoutValidationError("Background bookmark has an unexpected type.")

    expected_path: List[str] = [".background", background_file_name]
    require_equal("background bookmark path", bookmark.get(kBookmarkPath), expected_path)
    require_equal(
        "background bookmark volume",
        bookmark.get(kBookmarkVolumeName),
        volume_name,
    )


def verify_layout(
    mount_path: str,
    application_name: str,
    background_file_name: str,
    volume_name: str,
) -> None:
    _, _, _, ds_store_path = resolve_layout_paths(
        mount_path,
        application_name,
        background_file_name,
    )
    if not ds_store_path.is_file():
        raise LayoutValidationError(f"Finder metadata is missing: {ds_store_path}")

    with DSStore.open(os.fspath(ds_store_path), "r") as metadata:
        require_equal("layout version", metadata["."]["vSrn"], (b"long", 1))

        window_settings = metadata["."]["bwsp"]
        if not isinstance(window_settings, Mapping):
            raise LayoutValidationError("Window settings have an unexpected type.")
        require_mapping_values("window settings", window_settings, finder_window_settings())

        view_settings = metadata["."]["icvp"]
        if not isinstance(view_settings, Mapping):
            raise LayoutValidationError("Icon view settings have an unexpected type.")
        expected_view_settings = icon_view_settings(
            Alias.from_bytes(view_settings["backgroundImageAlias"])
        )
        require_mapping_values(
            "icon view settings",
            view_settings,
            {
                key: value
                for key, value in expected_view_settings.items()
                if key != "backgroundImageAlias"
            },
        )
        verify_background_alias(
            view_settings.get("backgroundImageAlias"),
            background_file_name,
            volume_name,
        )

        verify_background_bookmark(
            metadata["."]["pBBk"],
            background_file_name,
            volume_name,
        )
        require_equal("default view", metadata["."]["icvl"], DEFAULT_VIEW)
        require_equal(
            "application icon position",
            metadata[application_name]["Iloc"],
            APPLICATION_POSITION,
        )
        require_equal(
            "Applications icon position",
            metadata["Applications"]["Iloc"],
            APPLICATIONS_POSITION,
        )


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("configure", "verify"))
    parser.add_argument("--mount-path", required=True)
    parser.add_argument("--application-name", required=True)
    parser.add_argument("--background-file-name", required=True)
    parser.add_argument("--volume-name", required=True)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    try:
        if options.action == "configure":
            configure_layout(
                options.mount_path,
                options.application_name,
                options.background_file_name,
                options.volume_name,
            )
        else:
            verify_layout(
                options.mount_path,
                options.application_name,
                options.background_file_name,
                options.volume_name,
            )
    except (KeyError, OSError, ValueError, LayoutValidationError) as error:
        print(f"DMG layout error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
