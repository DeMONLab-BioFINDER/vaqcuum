"""shared bids filter and tree helpers"""

import json
import os
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Dict, List, Optional


IGNORED_TOP_LEVEL_DIRS = {
    "sourcedata",
    "freesurfer",
    "log",
    "logs",
    "figures",
    "__MACOSX",
}

IGNORED_METADATA_NAMES = {".DS_Store"}

FILTER_KEY_ALIASES = {
    "sub": "subject",
    "participant": "subject",
    "participant_label": "subject",
    "participant-label": "subject",
    "ses": "session",
    "acquisition": "acq",
    "resolution": "res",
}

FILTER_SECTIONS = {
    "anat": "anat",
    "t1w": "anat",
    "func": "func",
    "bold": "func",
}


# filesystem helpers

def _safe_listdir(path: str) -> List[str]:
    try:
        return os.listdir(path)
    except (PermissionError, FileNotFoundError, NotADirectoryError):
        return []


def _is_dir(path: str) -> bool:
    try:
        return os.path.isdir(path)
    except OSError:
        return False


def _is_file(path: str) -> bool:
    try:
        return os.path.isfile(path)
    except OSError:
        return False


def _is_ignored_path(path_parts: List[str]) -> bool:
    """ignore metadata files and auxiliary trees"""
    return any(
        part in IGNORED_TOP_LEVEL_DIRS
        or part in IGNORED_METADATA_NAMES
        or part.startswith("._")
        for part in path_parts
    )


# bids filter helpers

def _canonical_filter_key(key: str) -> str:
    normalized = str(key).strip().casefold()
    return FILTER_KEY_ALIASES.get(normalized, normalized)


def _canonical_filter_value(
    key: str,
    value: Any,
) -> Optional[str]:
    if value is None or value == "":
        return None

    text = str(value)

    if key == "subject" and text.startswith("sub-"):
        text = text[4:]

    if key == "session" and text.startswith("ses-"):
        text = text[4:]

    if key == "extension":
        text = text.casefold().lstrip(".")

    if key == "datatype":
        text = text.casefold()

    return text


def _normalize_filter_query(
    query: Mapping[str, Any],
) -> Dict[str, Any]:
    return {
        _canonical_filter_key(key): value
        for key, value in query.items()
    }


def _load_bids_filter(
    bids_filter: Optional[Any],
) -> Dict[str, Any]:
    """load a bids filter from json or a mapping"""
    if bids_filter is None:
        return {}

    if isinstance(bids_filter, Mapping):
        loaded = dict(bids_filter)
    else:
        filter_path = Path(bids_filter)

        if not filter_path.is_file():
            raise FileNotFoundError(
                f"BIDS filter does not exist or is not a file: "
                f"{filter_path}"
            )

        try:
            loaded = json.loads(
                filter_path.read_text(encoding="utf-8")
            )
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"Invalid BIDS filter JSON: {filter_path}: {exc}"
            ) from exc

    if not isinstance(loaded, dict):
        raise ValueError(
            "The BIDS filter JSON must contain an object at its top level."
        )

    normalized: Dict[str, Any] = {}

    for raw_key, raw_value in loaded.items():
        key = str(raw_key).strip().casefold()

        if isinstance(raw_value, Mapping):
            if key not in FILTER_SECTIONS:
                raise ValueError(
                    f"Unsupported BIDS filter section: {raw_key}. "
                    f"Supported sections are: "
                    f"{sorted(FILTER_SECTIONS)}"
                )

            normalized[key] = _normalize_filter_query(raw_value)
        else:
            normalized[_canonical_filter_key(key)] = raw_value

    return normalized


def _global_filter_query(
    bids_filter: Mapping[str, Any],
) -> Dict[str, Any]:
    return {
        key: value
        for key, value in bids_filter.items()
        if key not in FILTER_SECTIONS
    }


def _datatype_filter_query(
    bids_filter: Mapping[str, Any],
    datatype: str,
) -> Dict[str, Any]:
    """return the filter query for one datatype"""
    query = dict(_global_filter_query(bids_filter))

    section_names = (
        ("anat", "t1w")
        if datatype == "anat"
        else ("func", "bold")
    )

    for section_name in section_names:
        section_query = bids_filter.get(section_name)

        if isinstance(section_query, Mapping):
            query.update(section_query)

    return query


def _expected_values(value: Any) -> List[Any]:
    if isinstance(value, list):
        return value

    return [value]


def _matches_filter_value(
    key: str,
    actual_value: Any,
    expected_value: Any,
) -> bool:
    actual = _canonical_filter_value(key, actual_value)

    for item in _expected_values(expected_value):
        if isinstance(item, Mapping):
            raise ValueError(
                f"Nested filter expressions are not supported for "
                f"entity {key!r}."
            )

        if item == "*":
            return True

        expected = _canonical_filter_value(key, item)

        if actual == expected:
            return True

    return False


def _filename_suffix_and_extension(
    filename: str,
) -> tuple[str, str]:
    """extract the bids suffix and extension"""
    known_extensions = (
        ".nii.gz",
        ".tsv.gz",
        ".nii",
        ".json",
        ".tsv",
        ".csv",
        ".txt",
    )

    extension = ""

    for candidate in known_extensions:
        if filename.endswith(candidate):
            extension = candidate
            break

    if extension:
        stem = filename[:-len(extension)]
    else:
        extension = Path(filename).suffix
        stem = filename[:-len(extension)] if extension else filename

    suffix = stem.rsplit("_", 1)[-1]

    return suffix, extension


# compact tree used by validate_dataset.py

def visualize_tree(
    base_path: str,
    max_depth: int = 3,
    max_items_per_level: int = 5,
) -> None:
    """print a compact directory tree"""

    def _tree(directory: str, prefix: str = "", depth: int = 0) -> None:
        if depth > max_depth:
            return

        entries = _safe_listdir(directory)
        if not entries:
            return

        dirs = []
        files = []
        for entry in sorted(entries):
            full = os.path.join(directory, entry)
            if any(
                part in IGNORED_TOP_LEVEL_DIRS
                for part in Path(full).parts
            ):
                continue
            if _is_dir(full):
                dirs.append(entry)
            elif _is_file(full):
                files.append(entry)

        for index, filename in enumerate(files[:max_items_per_level]):
            is_last_file = (
                index == len(files) - 1
                and len(dirs) == 0
            )
            marker = "└── " if is_last_file else "├── "
            print(f"{prefix}{marker}{filename}")

        if len(files) > max_items_per_level:
            remaining = len(files) - max_items_per_level
            print(f"{prefix}├── ... ({remaining} more files)")

        for index, dirname in enumerate(dirs[:max_items_per_level]):
            is_last = index == len(dirs) - 1
            path = os.path.join(directory, dirname)
            marker = "└── " if is_last else "├── "
            print(f"{prefix}{marker}{dirname}/")
            extension = "    " if is_last else "│   "
            _tree(path, prefix + extension, depth + 1)

        if len(dirs) > max_items_per_level:
            remaining = len(dirs) - max_items_per_level
            print(f"{prefix}└── ... ({remaining} more directories)")

    print(f"\n{'=' * 60}")
    print(f"FOLDER TREE: {base_path}")
    print(f"{'=' * 60}\n")
    print(f"{base_path}/")
    _tree(base_path)
