"""Dataset structure discovery and analysis utilities for vaqcuum.

This module provides functions to:
- Discover folder hierarchies
- Classify BIDS dataset structure as flat, nested, or mixed
- Extract and map dataset structure
- Find available BIDS entity strings (space-*, task-*, acq-*, res-*, run-*)
- Validate dataset against expected patterns
- Visualize directory trees
"""

import argparse
import json
import os
import re

from collections import defaultdict
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Dict, List, Optional, Set


BIDS_DATATYPES = {"anat", "func"}
IGNORED_TOP_LEVEL_DIRS = {
    "sourcedata",
    "freesurfer",
    "log",
    "logs",
    "figures",
}

ENTITY_NAMES = ("space", "task", "acq", "run", "res")

ENTITY_PATTERNS = {
    "space": re.compile(r"(?:^|_)space-([A-Za-z0-9]+)(?:_|\.)"),
    "task": re.compile(r"(?:^|_)task-([A-Za-z0-9]+)(?:_|\.)"),
    "acq": re.compile(r"(?:^|_)acq-([A-Za-z0-9]+)(?:_|\.)"),
    "run": re.compile(r"(?:^|_)run-([A-Za-z0-9]+)(?:_|\.)"),
    "res": re.compile(r"(?:^|_)res-([A-Za-z0-9]+)(?:_|\.)"),
}

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


# ------------------------------------------------------------
# small helpers
# ------------------------------------------------------------

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
    return any(part in IGNORED_TOP_LEVEL_DIRS for part in path_parts)

def _classify_subject_root(entry_name: str) -> Optional[str]:
    """Classify a top-level subject-like directory.

    Only folders starting with sub-* are considered.
    Anything else is ignored.
    """
    if not entry_name.startswith("sub-"):
        return None

    if re.search(r"_ses-[^_]+", entry_name) or "_fmriprep" in entry_name:
        return "flat"
    return "nested"


def _is_allowed_space(value: str) -> bool:
    """Return True only for supported image spaces."""
    return value == "T1w" or "MNI" in value


def _is_acq_source_file(filename: str) -> bool:
    """Return True for files allowed to contribute acquisition labels."""
    return filename.endswith(("bold.nii.gz", "T1w.nii.gz"))


def _extract_entities_from_filename(
    filename: str,
) -> Dict[str, Optional[str]]:
    """Extract supported BIDS entity values from a filename.

    Space is restricted to:
    - T1w
    - Values containing "MNI"

    Acquisition labels are extracted only from files ending in:
    - bold.nii.gz
    - T1w.nii.gz
    """
    out: Dict[str, Optional[str]] = {
        entity: None
        for entity in ENTITY_NAMES
    }

    for key, pattern in ENTITY_PATTERNS.items():
        match = pattern.search(filename)

        if match is None:
            continue

        value = match.group(1)

        if key == "space" and not _is_allowed_space(value):
            continue

        if key == "acq" and not _is_acq_source_file(filename):
            continue

        out[key] = value

    return out

def _empty_entity_values() -> Dict[str, None]:
    return {entity: None for entity in ENTITY_NAMES}


def _empty_entity_sets() -> Dict[str, Set[str]]:
    return {entity: set() for entity in ENTITY_NAMES}


def _natural_sort_key(value: str) -> tuple:
    """Sort values naturally, so ses-2 precedes ses-10."""
    parts = re.split(r"(\d+)", str(value))

    return tuple(
        (0, int(part)) if part.isdigit() else (1, part.casefold())
        for part in parts
        if part != ""
    )


def _natural_sorted(values) -> List[str]:
    return sorted(values, key=_natural_sort_key)


def _canonical_filter_key(key: str) -> str:
    normalized = str(key).strip().casefold()
    return FILTER_KEY_ALIASES.get(normalized, normalized)


def _canonical_filter_value(
    key: str,
    value: Any,
) -> Optional[str]:
    """Normalize values before comparing them with filter values."""
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
    """Load a BIDS filter from a JSON path or mapping."""
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
    """Return non-sectioned top-level filter constraints."""
    return {
        key: value
        for key, value in bids_filter.items()
        if key not in FILTER_SECTIONS
    }


def _datatype_filter_query(
    bids_filter: Mapping[str, Any],
    datatype: str,
) -> Dict[str, Any]:
    """Return the complete query applicable to one datatype."""
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


def _has_filter_sections(
    bids_filter: Mapping[str, Any],
) -> bool:
    return any(
        key in bids_filter
        for key in FILTER_SECTIONS
    )


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
    """Extract the final BIDS suffix and complete extension."""
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


def _extract_all_filename_entities(
    filename: str,
) -> Dict[str, str]:
    """Extract arbitrary key-value BIDS entities for filter matching."""
    return {
        match.group(1).casefold(): match.group(2)
        for match in re.finditer(
            r"(?:^|_)([A-Za-z0-9]+)-([^_.]+)",
            filename,
        )
    }


def _file_matches_bids_filter(
    *,
    filename: str,
    datatype: str,
    subject: str,
    session: str,
    query: Mapping[str, Any],
) -> bool:
    """Return whether one file matches the supplied BIDS query."""
    if not query:
        return True

    suffix, extension = _filename_suffix_and_extension(filename)

    actual_values: Dict[str, Any] = (
        _extract_all_filename_entities(filename)
    )

    actual_values.update(
        {
            "subject": subject,
            "session": session or None,
            "datatype": datatype,
            "suffix": suffix,
            "extension": extension,
        }
    )

    for key, expected in query.items():
        actual = actual_values.get(key)

        if not _matches_filter_value(key, actual, expected):
            return False

    return True


def _file_matches_explicit_section(
    *,
    filename: str,
    datatype: str,
    subject: str,
    session: str,
    bids_filter: Mapping[str, Any],
) -> bool:
    """Check whether a file satisfies an explicitly supplied section.

    A bold section must be represented by a file whose suffix is bold.
    A t1w section must be represented by a file whose suffix is T1w.
    Datatype-level anat/func sections may match any file in that datatype.
    """
    suffix, _ = _filename_suffix_and_extension(filename)
    suffix_lower = suffix.casefold()
    global_query = _global_filter_query(bids_filter)

    if datatype == "anat":
        applicable_sections = ("anat", "t1w")
    else:
        applicable_sections = ("func", "bold")

    for section_name in applicable_sections:
        section_query = bids_filter.get(section_name)

        if not isinstance(section_query, Mapping):
            continue

        if section_name == "bold" and suffix_lower != "bold":
            continue

        if section_name == "t1w" and suffix_lower != "t1w":
            continue

        query = dict(global_query)
        query.update(section_query)

        if _file_matches_bids_filter(
            filename=filename,
            datatype=datatype,
            subject=subject,
            session=session,
            query=query,
        ):
            return True

    return False

def _datatype_has_filter_section(
    bids_filter: Mapping[str, Any],
    datatype: str,
) -> bool:
    section_names = (
        ("anat", "t1w")
        if datatype == "anat"
        else ("func", "bold")
    )

    return any(
        isinstance(
            bids_filter.get(section_name),
            Mapping,
        )
        for section_name in section_names
    )

# ------------------------------------------------------------
# structure discovery
# ------------------------------------------------------------
def _find_subject_roots(base_path: str, max_depth: int = 6) -> List[str]:
    """Return all directories under base_path whose basename starts with sub-.

    This allows layouts like:
      input_dir/fmriprep/sub-001/ses-01/...
    while ignoring non-sub-* folders at depth 1.
    """
    subject_roots = []

    for root, dirs, files in os.walk(base_path):
        rel_path = os.path.relpath(root, base_path)
        depth = root.replace(base_path, "").count(os.sep)

        if _is_ignored_path(list(Path(root).parts)):
            dirs[:] = []
            continue

        if depth > max_depth:
            dirs[:] = []
            continue

        # Only accept actual directories named sub-*
        if os.path.basename(root).startswith("sub-"):
            subject_roots.append(root)

        # Keep walking until we find sub-* folders deeper down.
        # Do not prune here, because sub-* may live inside an intermediary folder.
        # But once we hit a subject root, normal traversal continues below it.

    return sorted(set(subject_roots))

def discover_folder_structure(base_path: str, max_depth: int = 4) -> Dict[str, Any]:
    """Recursively discover folder structure and summarize dataset layout.

    Returns a dictionary with:
    - structure_type: flat | nested | mixed | unknown
    - subjects: nested subject summaries
    - flat_subjects: flat subject-like top-level folders
    - sessions: per-subject session sets
    - data_types: counts of anat/func dirs
    - file_types: counts of file extensions
    - entity_strings: available space/task/acq/res strings in anat and func
    - session_summary: per-session summary of entities and counts
    """
    structure: Dict[str, Any] = {
        "structure_type": "unknown",
        "subjects": {},
        "flat_subjects": [],
        "sessions": defaultdict(set),
        "data_types": defaultdict(int),
        "file_types": defaultdict(int),
        "entity_strings": {
            "anat": _empty_entity_values(),
            "func": _empty_entity_values(),
        },
        "session_summary": {},
        "depth_map": {},
    }

    nested_subjects: Set[str] = set()
    flat_subjects: Set[str] = set()

    # Only look at top-level folders that start with sub-*
    for entry in _safe_listdir(base_path):
        entry_path = os.path.join(base_path, entry)
        if not _is_dir(entry_path):
            continue
        classification = _classify_subject_root(entry)
        if classification == "nested":
            nested_subjects.add(entry)
        elif classification == "flat":
            flat_subjects.add(entry)

    # Prune any non-sub-* folders at depth 1 before traversal.
    # os.walk mutates `dirs`, so the root-level prune prevents descending into
    # sibling folders such as sourcedata/, figures/, etc.
    for root, dirs, files in os.walk(base_path):
        if os.path.abspath(root) == os.path.abspath(base_path):
            dirs[:] = [d for d in dirs if d.startswith("sub-")]

        rel_path = os.path.relpath(root, base_path)
        path_parts = Path(root).parts
        depth = root.replace(base_path, "").count(os.sep)
        rel_path = os.path.relpath(root, base_path)
        path_parts = Path(root).parts
        depth = root.replace(base_path, "").count(os.sep)

        if _is_ignored_path(list(path_parts)):
            dirs[:] = []
            continue

        if depth > max_depth:
            dirs[:] = []
            continue

        structure["depth_map"][rel_path] = depth

        subject_id = next((p for p in path_parts if p.startswith("sub-")), None)
        session_id = next((p for p in path_parts if p.startswith("ses-")), None)

        if subject_id:
            subj = structure["subjects"].setdefault(subject_id, {"sessions": set(), "paths": []})
            subj["paths"].append(rel_path)
            if session_id:
                subj["sessions"].add(session_id)
                structure["sessions"][(subject_id, session_id)].add(rel_path)

        for d in dirs:
            if d in BIDS_DATATYPES:
                structure["data_types"][d] += 1

        current_dtype = None
        if "anat" in path_parts:
            current_dtype = "anat"
        elif "func" in path_parts:
            current_dtype = "func"

        for f in files:
            if f.endswith("_xfm.txt"):
                continue

            ext = os.path.splitext(f)[1]
            if ext:
                structure["file_types"][ext] += 1

            if current_dtype in {"anat", "func"}:
                entities = _extract_entities_from_filename(f)
                for key, value in entities.items():
                    if value is None:
                        continue
                    if structure["entity_strings"][current_dtype].get(key) is None:
                        structure["entity_strings"][current_dtype][key] = []
                    if value not in structure["entity_strings"][current_dtype][key]:
                        structure["entity_strings"][current_dtype][key].append(value)

    if nested_subjects and flat_subjects:
        structure["structure_type"] = "mixed"
    elif nested_subjects:
        structure["structure_type"] = "nested"
    elif flat_subjects:
        structure["structure_type"] = "flat"

    structure["subjects"] = {
        k: {"sessions": sorted(list(v["sessions"])), "num_paths": len(v["paths"])}
        for k, v in structure["subjects"].items()
    }
    structure["sessions"] = {
        f"{sub}::{ses}": sorted(list(paths)) for (sub, ses), paths in structure["sessions"].items()
    }

    for dtype in ("anat", "func"):
        for key in ENTITY_NAMES:
            values = structure["entity_strings"][dtype].get(key)
            if values:
                structure["entity_strings"][dtype][key] = sorted(values)
            else:
                structure["entity_strings"][dtype][key] = None

    return structure


def find_bids_entities(base_path: str, max_depth: int = 6) -> Dict[str, Dict[str, Optional[List[str]]]]:
    """Find all available space/task/acq/res strings in anat and func directories.

    - space excludes fs* labels
    - returns None when no values are found for a given entity/type
    """
    found = {
        "anat": _empty_entity_sets(),
        "func": _empty_entity_sets(),
    }

    for root, dirs, files in os.walk(base_path):
        rel_parts = Path(root).parts
        depth = root.replace(base_path, "").count(os.sep)

        if _is_ignored_path(list(rel_parts)):
            dirs[:] = []
            continue

        if depth > max_depth:
            dirs[:] = []
            continue

        current_dtype = None
        if "anat" in rel_parts:
            current_dtype = "anat"
        elif "func" in rel_parts:
            current_dtype = "func"

        if current_dtype not in {"anat", "func"}:
            continue

        for f in files:
            if f.endswith("_xfm.txt"):
                continue

            entities = _extract_entities_from_filename(f)
            for key, value in entities.items():
                if value is None:
                    continue
                found[current_dtype][key].add(value)

    result: Dict[str, Dict[str, Optional[List[str]]]] = {
        "anat": {},
        "func": {},
    }

    for datatype in ("anat", "func"):
        for entity_name in ENTITY_NAMES:
            values = _natural_sorted(
                found[datatype][entity_name]
            )
            result[datatype][entity_name] = (
                values if values else None
            )


def extract_dataset_structure(
    base_path: str,
    bids_filter: Optional[Any] = None,
) -> Dict[str, Any]:
    """Extract comprehensive dataset structure information.

    The BIDS filter is applied while files are discovered, before they
    contribute to session_summary or the global entity lists.

    Anatomical and functional files are both filtered.

    Summary is organized per session for longitudinal datasets and per
    subject for cross-sectional datasets.
    """

    def normalize_selected_resolution(value: Any) -> str:
        """Normalize resolution values such as '02' to '2'."""
        if value in (None, ""):
            return ""

        text = str(value)

        try:
            return str(int(text, 10))
        except ValueError:
            return text

    structure: Dict[str, Any] = {
        "dataset_type": "unknown",
        "anat_outside_ses": None,
        "structure_type": "unknown",
        "valid_subjects": [],
        "flat_subjects": [],
        "mixed": False,
        "missing_data_types": {},
        "entities": {
            "anat": _empty_entity_values(),
            "func": _empty_entity_values(),
        },
        "session_summary": {},
    }

    if not os.path.exists(base_path):
        return structure

    filter_data = _load_bids_filter(bids_filter)
    filter_is_active = bool(filter_data)
    filter_has_sections = _has_filter_sections(filter_data)

    subject_roots = _find_subject_roots(base_path)

    session_summary: Dict[str, Any] = {}

    global_entity_sets = {
        "anat": _empty_entity_sets(),
        "func": _empty_entity_sets(),
    }

    retained_nested_subjects: Set[str] = set()
    retained_flat_subjects: Set[str] = set()
    retained_session_entity = False

    # Track whether any genuinely multi-session subject needs a shared T1w
    # image from sub-*/anat. A subject with exactly one ses-* directory is
    # treated as session-anatomy only, matching fMRIPrep's single-session
    # longitudinal layout. This check uses the physical dataset layout and is
    # independent of any BIDS filter applied to the session summary.
    anat_outside_ses_required = False

    def directory_has_t1w(anat_path: Optional[str]) -> bool:
        """Return whether an anat directory directly contains a T1w NIfTI."""
        if not anat_path or not _is_dir(anat_path):
            return False

        return any(
            filename.endswith("_T1w.nii.gz")
            and _is_file(os.path.join(anat_path, filename))
            for filename in _safe_listdir(anat_path)
        )

    for subject_root in subject_roots:
        subject_name = os.path.basename(subject_root)
        subject_kind = _classify_subject_root(subject_name)

        if subject_kind == "nested":
            named_session_dirs = [
                os.path.join(subject_root, directory_name)
                for directory_name in _safe_listdir(subject_root)
                if (
                    directory_name.startswith("ses-")
                    and _is_dir(
                        os.path.join(
                            subject_root,
                            directory_name,
                        )
                    )
                )
            ]

            named_session_dirs = sorted(
                named_session_dirs,
                key=lambda path: _natural_sort_key(
                    os.path.basename(path)
                ),
            )

            if named_session_dirs:
                session_dirs = named_session_dirs

                # Shared subject-level anatomy applies only when the subject
                # has multiple sessions. A one-session subject must keep its
                # T1w anatomy inside that ses-* directory.
                if len(named_session_dirs) > 1:
                    all_sessions_have_t1w = all(
                        directory_has_t1w(
                            os.path.join(session_dir, "anat")
                        )
                        for session_dir in named_session_dirs
                    )

                    if (
                        not all_sessions_have_t1w
                        and directory_has_t1w(
                            os.path.join(subject_root, "anat")
                        )
                    ):
                        anat_outside_ses_required = True
            else:
                # Cross-sectional nested layout:
                # sub-*/anat and sub-*/func.
                session_dirs = [subject_root]

        else:
            # Flat layout, for example:
            # sub-001_ses-01_fmriprep/...
            match = re.match(
                r"(sub-[^_]+)(?:_(ses-[^_]+))?",
                subject_name,
            )

            if match is None:
                continue

            session_dirs = [subject_root]

        for session_dir in session_dirs:
            if subject_kind == "nested":
                sub_id = subject_name
                session_name = os.path.basename(session_dir)

                if session_name.startswith("ses-"):
                    ses_id = session_name
                else:
                    ses_id = ""

                anat_dir = os.path.join(session_dir, "anat")
                func_dir = os.path.join(session_dir, "func")

            else:
                match = re.match(
                    r"(sub-[^_]+)(?:_(ses-[^_]+))?",
                    subject_name,
                )

                if match is None:
                    continue

                sub_id = match.group(1)
                ses_id = match.group(2) or ""

                anat_dir = None
                func_dir = None

                for root, dirs, _ in os.walk(session_dir):
                    if _is_ignored_path(list(Path(root).parts)):
                        dirs[:] = []
                        continue

                    root_name = os.path.basename(root)

                    if root_name == "anat":
                        anat_dir = root
                    elif root_name == "func":
                        func_dir = root

            session_key = (
                f"{sub_id}_{ses_id}"
                if ses_id
                else sub_id
            )

            entry: Dict[str, Any] = {
                "subject": sub_id,
                "session": ses_id,
                "anat": {
                    "path": anat_dir,
                    **_empty_entity_values(),
                    "files_total": 0,
                    "selected_combinations": [],
                },
                "func": {
                    "path": func_dir,
                    **_empty_entity_values(),
                    "files_total": 0,
                    "selected_combinations": [],
                },
            }

            # Preserve the relationships between task, acquisition, run,
            # space, and resolution instead of storing only independent lists.
            selected_combinations: Dict[
                str,
                Set[tuple[str, str, str, str, str]],
            ] = {
                "anat": set(),
                "func": set(),
            }

            matched_any_filtered_file = False
            matched_explicit_section = False

            for datatype, datatype_path in (
                ("anat", anat_dir),
                ("func", func_dir),
            ):
                if (
                    datatype_path is None
                    or not _is_dir(datatype_path)
                ):
                    continue

                # This includes global filters plus the filter section
                # applicable to the current datatype.
                query = _datatype_filter_query(
                    filter_data,
                    datatype,
                )

                entity_sets = _empty_entity_sets()
                files_total = 0

                filenames = _natural_sorted(
                    _safe_listdir(datatype_path)
                )

                for filename in filenames:
                    file_path = os.path.join(
                        datatype_path,
                        filename,
                    )

                    if not _is_file(file_path):
                        continue

                    if filename.endswith("_xfm.txt"):
                        continue

                    # Apply the BIDS filter before the file contributes to
                    # counts, entities, or selected combinations.
                    if not _file_matches_bids_filter(
                        filename=filename,
                        datatype=datatype,
                        subject=sub_id,
                        session=ses_id,
                        query=query,
                    ):
                        continue
                    if (
                        _datatype_has_filter_section(
                            filter_data,
                            datatype,
                        )
                        and not _file_matches_explicit_section(
                            filename=filename,
                            datatype=datatype,
                            subject=sub_id,
                            session=ses_id,
                            bids_filter=filter_data,
                        )
                    ):
                        continue
                    
                    files_total += 1
                    matched_any_filtered_file = True

                    if (
                        filter_has_sections
                        and _file_matches_explicit_section(
                            filename=filename,
                            datatype=datatype,
                            subject=sub_id,
                            session=ses_id,
                            bids_filter=filter_data,
                        )
                    ):
                        matched_explicit_section = True

                    all_entities = (
                        _extract_all_filename_entities(filename)
                    )

                    suffix, _ = _filename_suffix_and_extension(
                        filename
                    )
                    suffix_lower = suffix.casefold()

                    # Functional combinations come from BOLD files.
                    # Anatomical combinations come from T1w files.
                    is_combination_source = (
                        datatype == "func"
                        and suffix_lower == "bold"
                    ) or (
                        datatype == "anat"
                        and suffix_lower == "t1w"
                    )

                    if is_combination_source:
                        selected_space = all_entities.get(
                            "space",
                            "",
                        )
                        # desc-coreg_boldref represents an implicit T1w-space result.
                        if (
                            datatype == "func"
                            and suffix_lower == "boldref"
                            and not selected_space
                            and filename.endswith(
                                "desc-coreg_boldref.nii.gz"
                            )
                        ):
                            selected_space = "T1w"
                        # Native anatomical T1w files normally do not have
                        # an explicit space-T1w entity.
                        if datatype == "anat" and not selected_space:
                            selected_space = "T1w"

                        if (
                            selected_space
                            and _is_allowed_space(selected_space)
                        ):
                            normalized_space = (
                                "T1w"
                                if selected_space.casefold() == "t1w"
                                else selected_space
                            )

                            selected_combinations[datatype].add(
                                (
                                    all_entities.get("task", ""),
                                    all_entities.get("acq", ""),
                                    all_entities.get("run", ""),
                                    normalized_space,
                                    normalize_selected_resolution(
                                        all_entities.get("res", "")
                                    ),
                                )
                            )

                    entities = _extract_entities_from_filename(
                        filename
                    )

                    # A native anatomical T1w file commonly lacks an
                    # explicit space-T1w entity. Record its logical space.
                    if (
                        datatype == "anat"
                        and suffix_lower == "t1w"
                        and entities.get("space") is None
                    ):
                        entity_sets["space"].add("T1w")

                    for entity_name, entity_value in (
                        entities.items()
                    ):
                        if entity_value is not None:
                            entity_sets[entity_name].add(
                                entity_value
                            )

                for entity_name in ENTITY_NAMES:
                    entity_values = entity_sets[entity_name]

                    entry[datatype][entity_name] = (
                        _natural_sorted(entity_values)
                        if entity_values
                        else None
                    )

                entry[datatype]["files_total"] = files_total

            # Store selected combinations for both anat and func.
            for datatype in ("anat", "func"):
                entry[datatype]["selected_combinations"] = [
                    {
                        "task": task or None,
                        "acq": acq or None,
                        "run": run or None,
                        "space": space or None,
                        "res": resolution or None,
                    }
                    for (
                        task,
                        acq,
                        run,
                        space,
                        resolution,
                    ) in sorted(
                        selected_combinations[datatype],
                        key=lambda combination: tuple(
                            _natural_sort_key(value)
                            for value in combination
                        ),
                    )
                ]

            if not filter_is_active:
                keep_session = True
            elif filter_has_sections:
                # With a sectioned filter, retain the session only if a
                # file matched an explicitly requested section such as
                # bold, func, T1w, or anat.
                keep_session = matched_explicit_section
            else:
                # With a flat filter, retain the session if any anatomical
                # or functional file matched.
                keep_session = matched_any_filtered_file

            if not keep_session:
                continue

            session_summary[session_key] = entry

            if ses_id:
                retained_session_entity = True

            if subject_kind == "nested":
                retained_nested_subjects.add(sub_id)
            else:
                retained_flat_subjects.add(subject_name)

            # Aggregate entities only from retained, filtered sessions.
            for datatype in ("anat", "func"):
                for entity_name in ENTITY_NAMES:
                    entity_values = entry[datatype][entity_name]

                    if entity_values:
                        global_entity_sets[datatype][
                            entity_name
                        ].update(entity_values)

    structure["valid_subjects"] = _natural_sorted(
        retained_nested_subjects
    )

    structure["flat_subjects"] = _natural_sorted(
        retained_flat_subjects
    )

    structure["mixed"] = bool(
        structure["valid_subjects"]
        and structure["flat_subjects"]
    )

    structure["structure_type"] = (
        "mixed"
        if structure["mixed"]
        else "nested"
        if structure["valid_subjects"]
        else "flat"
        if structure["flat_subjects"]
        else "unknown"
    )

    if session_summary:
        structure["dataset_type"] = (
            "longitudinal"
            if retained_session_entity
            else "cross_sectional"
        )

    if structure["dataset_type"] == "longitudinal":
        # Keep the JSON shape consistent with the other discovered values,
        # but emit exactly one dataset-level status, never both yes and no.
        structure["anat_outside_ses"] = [
            "yes" if anat_outside_ses_required else "no"
        ]

    for datatype in ("anat", "func"):
        for entity_name in ENTITY_NAMES:
            entity_values = global_entity_sets[datatype][
                entity_name
            ]

            structure["entities"][datatype][entity_name] = (
                _natural_sorted(entity_values)
                if entity_values
                else None
            )

    # Deterministic natural ordering:
    # sub-2 before sub-10 and ses-2 before ses-10.
    structure["session_summary"] = dict(
        sorted(
            session_summary.items(),
            key=lambda item: (
                _natural_sort_key(item[1]["subject"]),
                _natural_sort_key(item[1]["session"]),
            ),
        )
    )

    return structure


# ------------------------------------------------------------
# other utilities
# ------------------------------------------------------------

def visualize_tree(base_path: str, max_depth: int = 3, max_items_per_level: int = 5) -> None:
    """Print a visual ASCII tree structure of the directory."""

    def _tree(directory: str, prefix: str = "", depth: int = 0) -> None:
        if depth > max_depth:
            return

        entries = _safe_listdir(directory)
        if not entries:
            return

        dirs = []
        files = []
        for e in sorted(entries):
            full = os.path.join(directory, e)
            if any(part in IGNORED_TOP_LEVEL_DIRS for part in Path(full).parts):
                continue
            if _is_dir(full):
                dirs.append(e)
            elif _is_file(full):
                files.append(e)

        for i, f in enumerate(files[:max_items_per_level]):
            is_last_file = (i == len(files) - 1) and len(dirs) == 0
            print(f"{prefix}{'└── ' if is_last_file else '├── '}{f}")

        if len(files) > max_items_per_level:
            print(f"{prefix}├── ... ({len(files) - max_items_per_level} more files)")

        for i, d in enumerate(dirs[:max_items_per_level]):
            is_last = i == len(dirs) - 1
            path = os.path.join(directory, d)
            print(f"{prefix}{'└── ' if is_last else '├── '}{d}/")
            extension = "    " if is_last else "│   "
            _tree(path, prefix + extension, depth + 1)

        if len(dirs) > max_items_per_level:
            print(f"{prefix}└── ... ({len(dirs) - max_items_per_level} more directories)")

    print(f"\n{'=' * 60}")
    print(f"FOLDER TREE: {base_path}")
    print(f"{'=' * 60}\n")
    print(f"{base_path}/")
    _tree(base_path)


def validate_dataset_structure(
    base_path: str,
    expected_subjects: Optional[List[str]] = None,
    expected_datatypes: Optional[List[str]] = None,
    require_nested: bool = True,
) -> Dict[str, Any]:
    """Validate dataset against expected patterns."""
    report: Dict[str, Any] = {
        "is_valid": True,
        "warnings": [],
        "errors": [],
        "structure_type": None,
        "summary": {},
    }

    if not os.path.exists(base_path):
        report["is_valid"] = False
        report["errors"].append(f"Base path does not exist: {base_path}")
        return report

    extracted = extract_dataset_structure(base_path)
    report["structure_type"] = extracted["structure_type"]

    if extracted["structure_type"] == "mixed":
        report["warnings"].append("Mixed structure detected: both nested and flat subjects found")

    if require_nested and extracted["structure_type"] == "flat":
        report["is_valid"] = False
        report["errors"].append("Expected nested structure but found flat structure")

    if extracted["structure_type"] == "unknown":
        report["is_valid"] = False
        report["errors"].append("No valid BIDS subject directories found (missing sub-* pattern)")
        return report

    if expected_subjects:
        found_subjects = set(extracted["valid_subjects"]) | set(extracted["flat_subjects"])
        missing = set(expected_subjects) - found_subjects
        extra = found_subjects - set(expected_subjects)

        if missing:
            report["errors"].append(f"Missing subjects: {sorted(missing)}")
            report["is_valid"] = False
        if extra:
            report["warnings"].append(f"Unexpected subjects found: {sorted(extra)}")

    # if expected_datatypes:
    #     available_datatypes = set(extracted["file_inventory"].keys())
    #     missing_types = set(expected_datatypes) - available_datatypes
    #     if missing_types:
    #         report["errors"].append(f"Missing data types: {sorted(missing_types)}")
    #         report["is_valid"] = False

    for sub in extracted["valid_subjects"]:
        subject_hierarchy = extracted["directory_hierarchy"].get(sub, {})
        if not subject_hierarchy:
            report["errors"].append(f"Subject {sub} has no data subdirectories")
            report["is_valid"] = False
            continue

        sessions = set()
        datatypes_per_subject = set()
        # for ses_dt_path in subject_hierarchy.keys():
        #     parts = ses_dt_path.split("/")
        #     # if len(parts) == 2:
        #     #     ses_id, datatype = parts
        #     #     sessions.add(ses_id)
        #     #     datatypes_per_subject.add(datatype)

        if not sessions:
            report["errors"].append(f"Subject {sub} has no sessions")
            report["is_valid"] = False

        if expected_datatypes:
            missing = set(expected_datatypes) - datatypes_per_subject
            if missing:
                report["warnings"].append(f"Subject {sub} missing data types: {sorted(missing)}")

    report["summary"] = {
        "nested_subjects": len(extracted["valid_subjects"]),
        "flat_subjects": len(extracted["flat_subjects"]),
        "total_subjects": len(extracted["valid_subjects"]) + len(extracted["flat_subjects"]),
        #"data_types_found": dict(extracted["file_inventory"]),
        #"total_files": sum(len(v) for v in extracted["file_inventory"].values()),
        "sessions": extracted["session_summary"],
    }

    return report


def get_subject_files(
    base_path: str,
    subject_id: str,
    session_id: Optional[str] = None,
    datatype: Optional[str] = None,
    suffix: Optional[str] = None,
) -> List[str]:
    """Get files for a specific subject, optionally filtered by session, datatype, or suffix.

    This helper works on nested BIDS folders.
    For flat structures, use discover_folder_structure / find_bids_entities.
    """
    files: List[str] = []

    subject_path = os.path.join(base_path, subject_id)
    if not os.path.exists(subject_path):
        return files

    if session_id:
        session_path = os.path.join(subject_path, session_id)
        if not os.path.exists(session_path):
            return files

        if datatype:
            datatype_path = os.path.join(session_path, datatype)
            if os.path.exists(datatype_path):
                for f in _safe_listdir(datatype_path):
                    if f.endswith("_xfm.txt"):
                        continue
                    if _is_file(os.path.join(datatype_path, f)) and (suffix is None or f.endswith(suffix)):
                        files.append(os.path.join(datatype_path, f))
        else:
            for d in _safe_listdir(session_path):
                if d in BIDS_DATATYPES:
                    datatype_path = os.path.join(session_path, d)
                    if os.path.isdir(datatype_path):
                        for f in _safe_listdir(datatype_path):
                            if f.endswith("_xfm.txt"):
                                continue
                            if _is_file(os.path.join(datatype_path, f)) and (suffix is None or f.endswith(suffix)):
                                files.append(os.path.join(datatype_path, f))
    else:
        for entry in _safe_listdir(subject_path):
            if entry.startswith("ses-"):
                session_path = os.path.join(subject_path, entry)
                if datatype:
                    datatype_path = os.path.join(session_path, datatype)
                    if os.path.exists(datatype_path):
                        for f in _safe_listdir(datatype_path):
                            if f.endswith("_xfm.txt"):
                                continue
                            if _is_file(os.path.join(datatype_path, f)) and (suffix is None or f.endswith(suffix)):
                                files.append(os.path.join(datatype_path, f))
                else:
                    for d in _safe_listdir(session_path):
                        if d in BIDS_DATATYPES:
                            datatype_path = os.path.join(session_path, d)
                            if os.path.isdir(datatype_path):
                                for f in _safe_listdir(datatype_path):
                                    if f.endswith("_xfm.txt"):
                                        continue
                                    if _is_file(os.path.join(datatype_path, f)) and (suffix is None or f.endswith(suffix)):
                                        files.append(os.path.join(datatype_path, f))

    return sorted(files)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Discover and summarize a BIDS dataset structure."
    )

    parser.add_argument(
        "base_path",
        help="Path to the BIDS or derivatives dataset.",
    )

    parser.add_argument(
        "--bids-filter",
        "--bids_filter",
        dest="bids_filter",
        default=None,
        help="Optional BIDS filter JSON file.",
    )

    args = parser.parse_args()

    result = extract_dataset_structure(
        args.base_path,
        bids_filter=args.bids_filter,
    )

    print(
        json.dumps(
            result,
            indent=2,
            default=list,
        )
    )