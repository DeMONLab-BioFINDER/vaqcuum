"""Dataset structure discovery and analysis utilities for vaqcuum.

This module provides functions to:
- Discover folder hierarchies
- Classify BIDS dataset structure as flat, nested, or mixed
- Extract and map dataset structure
- Find available BIDS entity strings (space-*, task-*, acq-*)
- Validate dataset against expected patterns
- Visualize directory trees
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Optional, Set, Any


BIDS_DATATYPES = {"anat", "func"}
IGNORED_TOP_LEVEL_DIRS = {"sourcedata", "freesurfer", "log", "logs", "figures"}
ENTITY_PATTERNS = {
    "space": re.compile(r"(?:^|_)space-([A-Za-z0-9]+)(?:_|\.)"),
    "task": re.compile(r"(?:^|_)task-([A-Za-z0-9]+)(?:_|\.)"),
    "acq": re.compile(r"(?:^|_)acq-([A-Za-z0-9]+)(?:_|\.)"),
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


def _extract_entities_from_filename(filename: str) -> Dict[str, Optional[str]]:
    """Extract space/task/acq entity values from a BIDS filename.

    Returns None for missing entities.
    space values starting with fs are ignored.
    """
    out = {"space": None, "task": None, "acq": None}
    for key, pattern in ENTITY_PATTERNS.items():
        m = pattern.search(filename)
        if not m:
            continue
        value = m.group(1)
        if key == "space" and value.startswith("fs"):
            continue
        out[key] = value
    return out


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
    - entity_strings: available space/task/acq strings in anat and func
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
            "anat": {"space": None, "task": None, "acq": None},
            "func": {"space": None, "task": None, "acq": None},
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
        for key in ("space", "task", "acq"):
            values = structure["entity_strings"][dtype].get(key)
            if values:
                structure["entity_strings"][dtype][key] = sorted(values)
            else:
                structure["entity_strings"][dtype][key] = None

    return structure


def find_bids_entities(base_path: str, max_depth: int = 6) -> Dict[str, Dict[str, Optional[List[str]]]]:
    """Find all available space/task/acq strings in anat and func directories.

    - space excludes fs* labels
    - returns None when no values are found for a given entity/type
    """
    found = {
        "anat": {"space": set(), "task": set(), "acq": set()},
        "func": {"space": set(), "task": set(), "acq": set()},
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
                if key == "space" and value.startswith("fs"):
                    continue
                found[current_dtype][key].add(value)

    result: Dict[str, Dict[str, Optional[List[str]]]] = {"anat": {}, "func": {}}
    for dtype in ("anat", "func"):
        for key in ("space", "task", "acq"):
            values = sorted(found[dtype][key])
            result[dtype][key] = values if values else None
    return result


def extract_dataset_structure(base_path: str) -> Dict[str, Any]:
    """Extract comprehensive dataset structure information with hierarchical breakdown.

    Summary is organized per session. Nuisance folders are ignored.
    """
    structure: Dict[str, Any] = {
        "structure_type": "unknown",
        "valid_subjects": [],
        "flat_subjects": [],
        "mixed": False,
        #"directory_hierarchy": defaultdict(lambda: defaultdict(list)),
        "missing_data_types": {},
        #"file_inventory": defaultdict(list),
        "entities": {
            "anat": {"space": None, "task": None, "acq": None},
            "func": {"space": None, "task": None, "acq": None},
        },
        "session_summary": {},
    }

    if not os.path.exists(base_path):
        return structure

    # Top-level scan only keeps sub-* folders.
    subject_roots = _find_subject_roots(base_path)

    for subject_path in subject_roots:
        subject_name = os.path.basename(subject_path)
        kind = _classify_subject_root(subject_name)

        if kind == "nested":
            structure["valid_subjects"].append(subject_name)
        elif kind == "flat":
            structure["flat_subjects"].append(subject_name)

    structure["valid_subjects"] = sorted(set(structure["valid_subjects"]))
    structure["flat_subjects"] = sorted(set(structure["flat_subjects"]))

    structure["mixed"] = bool(structure["valid_subjects"] and structure["flat_subjects"])
    structure["structure_type"] = (
        "mixed"
        if structure["mixed"]
        else "nested"
        if structure["valid_subjects"]
        else "flat"
        if structure["flat_subjects"]
        else "unknown"
    )

    session_summary: Dict[str, Any] = {}

    for subject_root in subject_roots:

        subject_name = os.path.basename(subject_root)

        if _classify_subject_root(subject_name) == "nested":
            # sub-001/ses-01/...
            session_dirs = [
                os.path.join(subject_root, d)
                for d in _safe_listdir(subject_root)
                if d.startswith("ses-")
                and _is_dir(os.path.join(subject_root, d))
            ]

        else:
            # flat: sub-001_ses-01_fmriprep...
            session_dirs = [subject_root]

        for session_dir in session_dirs:

            if _classify_subject_root(subject_name) == "nested":
                sub_id = subject_name
                ses_id = os.path.basename(session_dir)
                anat_dir = os.path.join(session_dir, "anat")
                func_dir = os.path.join(session_dir, "func")

            else:
                m = re.match(r"(sub-[^_]+)_(ses-[^_]+)", subject_name)
                if m is None:
                    continue

                sub_id = m.group(1)
                ses_id = m.group(2)

                anat_dir = None
                func_dir = None

                for root, dirs, _ in os.walk(session_dir):
                    if os.path.basename(root) == "anat":
                        anat_dir = root
                    elif os.path.basename(root) == "func":
                        func_dir = root

        
            session_key = f"{sub_id}_{ses_id}"

            session_summary.setdefault(
                session_key,
                {
                    "subject": sub_id,
                    "session": ses_id,
                    "anat": {
                        "path": None,
                        "space": None,
                        "task": None,
                        "acq": None,
                        "files_total": 0,
                    },
                    "func": {
                        "path": None,
                        "space": None,
                        "task": None,
                        "acq": None,
                        "files_total": 0,
                    },
                },
            )

            session_summary[session_key]["anat"]["path"] = anat_dir
            session_summary[session_key]["func"]["path"] = func_dir

            for datatype, datatype_path in (("anat", anat_dir), ("func", func_dir)):

                if datatype_path is None or not _is_dir(datatype_path):
                    continue

                entity_sets = {
                    "space": set(),
                    "task": set(),
                    "acq": set(),
                }

                files_total = 0

                for f in _safe_listdir(datatype_path):

                    if (
                        not _is_file(os.path.join(datatype_path, f))
                        or f.endswith("_xfm.txt")
                    ):
                        continue

                    files_total += 1

                    entities = _extract_entities_from_filename(f)

                    for entity_name, entity_value in entities.items():
                        if entity_value is None:
                            continue

                        if entity_name == "space" and entity_value.startswith("fs"):
                            continue

                        entity_sets[entity_name].add(entity_value)

                session_summary[session_key][datatype]["space"] = (
                    sorted(entity_sets["space"]) if entity_sets["space"] else None
                )

                session_summary[session_key][datatype]["task"] = (
                    sorted(entity_sets["task"]) if entity_sets["task"] else None
                )

                session_summary[session_key][datatype]["acq"] = (
                    sorted(entity_sets["acq"]) if entity_sets["acq"] else None
                )

                session_summary[session_key][datatype]["files_total"] = files_total

    structure["session_summary"] = session_summary
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
    import json
    import sys

    if len(sys.argv) < 2:
        print("Usage: python bids_dataset_structure_utils.py <base_path>")
        raise SystemExit(1)

    base = sys.argv[1]
    result = extract_dataset_structure(base)
    print(json.dumps(result, indent=2, default=list))
