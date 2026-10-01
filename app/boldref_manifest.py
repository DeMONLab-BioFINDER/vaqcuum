#!/usr/bin/env python3
"""build work items from canonical boldref files"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping

from dataset_utils import (
    _datatype_filter_query,
    _filename_suffix_and_extension,
    _is_ignored_path,
    _load_bids_filter,
    _matches_filter_value,
)

NONE = "__NONE__"
NO_RESOLUTION = "__NA__"
NO_PATH = "__NONE__"

ENTITY_RE = re.compile(r"(?:^|_)([A-Za-z0-9]+)-([^_.]+)")


def natural_sort_key(value: Any) -> tuple:
    parts = re.split(r"(\d+)", str(value))
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part.casefold())
        for part in parts
        if part
    )


def normalize_resolution(value: str) -> str:
    if not value:
        return ""
    try:
        return str(int(value, 10))
    except ValueError:
        return value


def normalize_space(value: str) -> str:
    return "T1w" if value.casefold() == "t1w" else value


def allowed_space(value: str) -> bool:
    folded = value.casefold()
    return folded == "t1w" or "mni" in folded


def filename_entities(path: Path) -> dict[str, str]:
    return {
        match.group(1).casefold(): match.group(2)
        for match in ENTITY_RE.finditer(path.name)
    }


def functional_filter_matches(
    entities: Mapping[str, str],
    query: Mapping[str, Any],
) -> bool:
    """apply functional filter constraints to a boldref"""
    if not query:
        return True

    actual: dict[str, Any] = dict(entities)
    actual.update(
        {
            "subject": entities.get("sub"),
            "session": entities.get("ses"),
            "datatype": "func",
            "extension": "nii.gz",
        }
    )

    for key, expected in query.items():
        if key in {"suffix", "desc"}:
            continue
        if not _matches_filter_value(key, actual.get(key), expected):
            return False

    return True


def anatomical_t1_filter_matches(
    path: Path,
    subject_label: str,
    session_label: str,
    query: Mapping[str, Any],
) -> bool:
    """apply anatomical filter constraints to a native t1w candidate"""
    if not query:
        return True

    entities = filename_entities(path)
    suffix, extension = _filename_suffix_and_extension(path.name)
    logical_space = entities.get("space") or ("T1w" if suffix.casefold() == "t1w" else None)

    actual: dict[str, Any] = dict(entities)
    actual.update(
        {
            "subject": subject_label,
            "session": session_label or None,
            "datatype": "anat",
            "suffix": suffix,
            "extension": extension,
            "space": logical_space,
        }
    )

    for key, expected in query.items():
        if key in {"task", "run"}:
            continue
        if not _matches_filter_value(key, actual.get(key), expected):
            return False
    return True


def scan_dataset(base_path: Path) -> tuple[list[Path], list[Path], dict[Path, list[Path]]]:
    """scan once and index boldrefs anatomy dirs and files"""
    boldrefs: list[Path] = []
    anat_dirs: list[Path] = []
    files_by_dir: dict[Path, list[Path]] = {}

    for root, dirs, files in os.walk(base_path):
        root_path = Path(root).resolve()
        if _is_ignored_path(list(root_path.parts)):
            dirs[:] = []
            continue

        dirs[:] = [
            name
            for name in dirs
            if not _is_ignored_path(list((root_path / name).parts))
        ]

        if root_path.name == "anat":
            anat_dirs.append(root_path)

        indexed_files = [
            root_path / name
            for name in files
            if not _is_ignored_path(list((root_path / name).parts))
        ]
        files_by_dir[root_path] = indexed_files

        for path in indexed_files:
            if path.name.endswith("_boldref.nii.gz"):
                boldrefs.append(path)

    return boldrefs, anat_dirs, files_by_dir


def nearest_named_parent(path: Path, name: str) -> Path | None:
    for parent in (path.parent, *path.parents):
        if parent.name == name:
            return parent
    return None


def nearest_subject_root(path: Path, subject: str, base_path: Path) -> Path | None:
    """find the subject scope including older wrapped layouts"""
    parents = (path.parent, *path.parents)
    for parent in parents:
        if parent.name == subject:
            return parent
    for parent in parents:
        if parent.name.startswith(subject + "_") or parent.name.startswith(subject + "-"):
            return parent
        if parent.name.startswith(subject) and ("ses-" in parent.name or "fmriprep" in parent.name.casefold()):
            return parent
        if parent == base_path:
            break
    return None


def nearest_session_root(path: Path, session: str) -> Path | None:
    if not session:
        return None
    exact = nearest_named_parent(path, session)
    if exact is not None:
        return exact
    for parent in (path.parent, *path.parents):
        if session in parent.name:
            return parent
    return None


def nearest_func_dir(path: Path) -> Path:
    parent = nearest_named_parent(path, "func")
    return parent if parent is not None else path.parent


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def has_session_component_between(path: Path, subject_root: Path) -> bool:
    try:
        rel_parts = path.relative_to(subject_root).parts
    except ValueError:
        return False
    return any(part.startswith("ses-") for part in rel_parts)


def candidate_native_t1s(
    anat_dir: Path,
    files_by_dir: Mapping[Path, list[Path]],
    subject_label: str,
    session_label: str,
    anat_query: Mapping[str, Any],
) -> list[Path]:
    out: list[Path] = []
    for path in files_by_dir.get(anat_dir, []):
        if not path.is_file() or not path.name.endswith("desc-preproc_T1w.nii.gz"):
            continue
        entities = filename_entities(path)
        if entities.get("space"):
            continue
        if entities.get("sub") and entities.get("sub") != subject_label:
            continue
        if session_label and entities.get("ses") and entities.get("ses") != session_label:
            continue
        if not anatomical_t1_filter_matches(path, subject_label, session_label, anat_query):
            continue
        out.append(path)
    return out


def resolve_anat_dir(
    *,
    boldref: Path,
    subject_root: Path,
    session_root: Path | None,
    subject_label: str,
    session_label: str,
    anat_dirs: Iterable[Path],
    files_by_dir: Mapping[Path, list[Path]],
    anat_query: Mapping[str, Any],
) -> tuple[Path, Path]:
    """resolve one anatomy directory and its native t1w"""
    dirs = [path for path in anat_dirs if is_relative_to(path, subject_root)]

    scoped_groups: list[tuple[str, list[Path]]] = []
    if session_root is not None:
        scoped_groups.append(
            (
                "session-level",
                [path for path in dirs if is_relative_to(path, session_root)],
            )
        )

    subject_level = [
        path
        for path in dirs
        if not has_session_component_between(path, subject_root)
    ]
    scoped_groups.append(("subject-level/shared", subject_level))

    # allow any subject anatomy when no session scope exists
    if session_root is None:
        scoped_groups.append(("cross-sectional subject", dirs))

    seen_groups: set[tuple[Path, ...]] = set()
    for label, candidates in scoped_groups:
        unique_candidates = tuple(sorted(set(candidates), key=lambda p: natural_sort_key(str(p))))
        if not unique_candidates or unique_candidates in seen_groups:
            continue
        seen_groups.add(unique_candidates)

        usable: list[tuple[Path, Path]] = []
        for anat_dir in unique_candidates:
            native_t1s = candidate_native_t1s(
                anat_dir,
                files_by_dir,
                subject_label,
                session_label,
                anat_query,
            )
            if len(native_t1s) > 1:
                formatted = "\n".join(f"  - {item}" for item in native_t1s)
                raise ValueError(
                    f"Multiple native anatomical T1w files match the anatomical "
                    f"filter in {anat_dir}:\n{formatted}"
                )
            if native_t1s:
                usable.append((anat_dir, native_t1s[0]))

        if len(usable) == 1:
            return usable[0]
        if len(usable) > 1:
            formatted = "\n".join(f"  - {item[0]}" for item in usable)
            raise ValueError(
                f"Multiple usable {label} anatomy directories found for {boldref}:\n{formatted}"
            )

    session_text = f"ses-{session_label}" if session_label else "<no session>"
    raise ValueError(
        f"No usable anatomy containing a filtered native desc-preproc_T1w could "
        f"be resolved for sub-{subject_label}/{session_text} from boldref: {boldref}"
    )


def entity_matches(path: Path, key: str, wanted: str) -> bool:
    if wanted == "__ANY__":
        return True
    actual = filename_entities(path).get(key, "")
    if key == "res":
        actual = normalize_resolution(actual)
        wanted = normalize_resolution(wanted)
    if wanted == NONE:
        return not actual
    return actual == wanted


def matching_files(
    files: Iterable[Path],
    *,
    suffix: str,
    subject_label: str,
    session_label: str,
    task: str = "__ANY__",
    acq: str = "__ANY__",
    run: str = "__ANY__",
    space: str = "__ANY__",
    res: str = "__ANY__",
) -> list[Path]:
    matches: list[Path] = []
    for path in files:
        if _is_ignored_path(list(path.parts)):
            continue
        if not path.is_file() or not path.name.endswith(suffix):
            continue
        entities = filename_entities(path)
        if entities.get("sub") and entities.get("sub") != subject_label:
            continue
        if session_label:
            if entities.get("ses") and entities.get("ses") != session_label:
                continue
        elif entities.get("ses"):
            continue
        if not entity_matches(path, "task", task):
            continue
        if not entity_matches(path, "acq", acq):
            continue
        if not entity_matches(path, "run", run):
            continue
        if not entity_matches(path, "space", space):
            continue
        if not entity_matches(path, "res", res):
            continue
        matches.append(path)
    return sorted(matches, key=lambda p: natural_sort_key(p.name))


def require_one(matches: list[Path], label: str, context: Path) -> Path:
    if len(matches) == 1:
        return matches[0].resolve()
    if not matches:
        raise ValueError(f"No {label} found while resolving work item: {context}")
    formatted = "\n".join(f"  - {item}" for item in matches)
    raise ValueError(f"Multiple files match {label} for {context}:\n{formatted}")


def optional_one(matches: list[Path], label: str, context: Path) -> Path | None:
    if len(matches) == 1:
        return matches[0].resolve()
    if not matches:
        return None
    formatted = "\n".join(f"  - {item}" for item in matches)
    raise ValueError(f"Multiple files match {label} for {context}:\n{formatted}")


def one_with_resolution_fallback(
    files: Iterable[Path],
    *,
    suffix: str,
    label: str,
    context: Path,
    subject_label: str,
    session_label: str,
    task: str = "__ANY__",
    acq: str = "__ANY__",
    run: str = "__ANY__",
    space: str = "__ANY__",
    res: str = "",
    optional: bool = False,
) -> Path | None:
    if res:
        exact = matching_files(
            files,
            suffix=suffix,
            subject_label=subject_label,
            session_label=session_label,
            task=task,
            acq=acq,
            run=run,
            space=space,
            res=res,
        )
        if len(exact) == 1:
            return exact[0].resolve()
        if len(exact) > 1:
            return require_one(exact, label, context)

        no_res = matching_files(
            files,
            suffix=suffix,
            subject_label=subject_label,
            session_label=session_label,
            task=task,
            acq=acq,
            run=run,
            space=space,
            res=NONE,
        )
        return optional_one(no_res, label, context) if optional else require_one(no_res, label, context)

    any_res = matching_files(
        files,
        suffix=suffix,
        subject_label=subject_label,
        session_label=session_label,
        task=task,
        acq=acq,
        run=run,
        space=space,
        res="__ANY__",
    )
    return optional_one(any_res, label, context) if optional else require_one(any_res, label, context)


def infer_missing_mni_resolution(
    boldref: Path,
    entities: Mapping[str, str],
    func_files: Iterable[Path],
) -> str:
    if entities.get("res") or "mni" not in entities.get("space", "").casefold():
        return normalize_resolution(entities.get("res", ""))

    wanted = {key: entities.get(key, "") for key in ("task", "acq", "run", "space")}
    resolutions: set[str] = set()
    for candidate in func_files:
        if not candidate.is_file() or not candidate.name.endswith("_bold.nii.gz"):
            continue
        candidate_entities = filename_entities(candidate)
        if any(candidate_entities.get(key, "") != value for key, value in wanted.items()):
            continue
        resolution = normalize_resolution(candidate_entities.get("res", ""))
        if resolution:
            resolutions.add(resolution)

    if len(resolutions) == 1:
        return next(iter(resolutions))
    if len(resolutions) > 1:
        raise ValueError(
            f"Cannot infer a unique resolution for {boldref}; matching BOLD files "
            f"contain resolutions {sorted(resolutions, key=natural_sort_key)!r}"
        )
    return ""


def resolve_work_item_files(
    *,
    boldref: Path,
    func_dir: Path,
    anat_dir: Path,
    native_t1: Path,
    files_by_dir: Mapping[Path, list[Path]],
    subject_label: str,
    session_label: str,
    task: str,
    acq: str,
    run: str,
    space: str,
    resolution: str,
) -> tuple[str, ...]:
    func_files = files_by_dir.get(func_dir, [])
    anat_files = files_by_dir.get(anat_dir, [])

    task_spec = task or NONE
    func_acq_spec = acq or NONE
    run_spec = run or NONE
    space_spec = space or NONE

    anat_entities = filename_entities(native_t1)
    anat_acq = anat_entities.get("acq", "")
    anat_acq_spec = anat_acq or NONE

    native_mask = require_one(
        matching_files(
            anat_files,
            suffix="desc-brain_mask.nii.gz",
            subject_label=subject_label,
            session_label=session_label,
            acq=anat_acq_spec,
            space=NONE,
        ),
        "native anatomical brain mask",
        boldref,
    )
    native_gm = require_one(
        matching_files(
            anat_files,
            suffix="label-GM_probseg.nii.gz",
            subject_label=subject_label,
            session_label=session_label,
            acq=anat_acq_spec,
            space=NONE,
        ),
        "native anatomical GM probability map",
        boldref,
    )

    func_mask = one_with_resolution_fallback(
        func_files,
        suffix="desc-brain_mask.nii.gz",
        label=f"functional brain mask in {space}",
        context=boldref,
        subject_label=subject_label,
        session_label=session_label,
        task=task_spec,
        acq=func_acq_spec,
        run=run_spec,
        space=space_spec,
        res=resolution,
    )
    assert func_mask is not None

    anat_mni: Path | None = None
    mask_anat_mni: Path | None = None
    gm_mni: Path | None = None
    refbold_t1w: Path | None = None
    refbold_native: Path | None = None
    matrix: Path | None = None

    if "mni" in space.casefold():
        anat_mni = one_with_resolution_fallback(
            anat_files,
            suffix="desc-preproc_T1w.nii.gz",
            label=f"anatomical T1w in {space}",
            context=boldref,
            subject_label=subject_label,
            session_label=session_label,
            acq=anat_acq_spec,
            space=space,
            res=resolution,
        )
        mask_anat_mni = one_with_resolution_fallback(
            anat_files,
            suffix="desc-brain_mask.nii.gz",
            label=f"anatomical brain mask in {space}",
            context=boldref,
            subject_label=subject_label,
            session_label=session_label,
            acq=anat_acq_spec,
            space=space,
            res=resolution,
        )
        gm_mni = one_with_resolution_fallback(
            anat_files,
            suffix="label-GM_probseg.nii.gz",
            label=f"anatomical GM probability map in {space}",
            context=boldref,
            subject_label=subject_label,
            session_label=session_label,
            acq=anat_acq_spec,
            space=space,
            res=resolution,
        )

        refbold_t1w = one_with_resolution_fallback(
            func_files,
            suffix="boldref.nii.gz",
            label="existing BOLD reference in T1w space",
            context=boldref,
            subject_label=subject_label,
            session_label=session_label,
            task=task_spec,
            acq=func_acq_spec,
            run=run_spec,
            space="T1w",
            res=resolution,
            optional=True,
        )

        if refbold_t1w is None:
            refbold_native = optional_one(
                matching_files(
                    func_files,
                    suffix="desc-coreg_boldref.nii.gz",
                    subject_label=subject_label,
                    session_label=session_label,
                    task=task_spec,
                    acq=func_acq_spec,
                    run=run_spec,
                    space=NONE,
                ),
                "native/coregistered BOLD reference",
                boldref,
            )
            if refbold_native is None:
                raise ValueError(
                    f"No T1w-space boldref and no native desc-coreg_boldref were found for {boldref}"
                )

            matrix = optional_one(
                matching_files(
                    func_files,
                    suffix="from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt",
                    subject_label=subject_label,
                    session_label=session_label,
                    task=task_spec,
                    acq=func_acq_spec,
                    run=run_spec,
                    space=NONE,
                ),
                "entity-specific BOLD-to-T1w transform",
                boldref,
            )
            if matrix is None:
                matrix = require_one(
                    matching_files(
                        func_files,
                        suffix="from-boldref_to-T1w_mode-image_desc-coreg_xfm.txt",
                        subject_label=subject_label,
                        session_label=session_label,
                        task="__ANY__",
                        acq="__ANY__",
                        run="__ANY__",
                        space=NONE,
                    ),
                    "BOLD-to-T1w transform",
                    boldref,
                )

    return (
        str(func_mask),
        str(native_t1.resolve()),
        str(native_mask),
        str(native_gm),
        str(anat_mni) if anat_mni else NO_PATH,
        str(mask_anat_mni) if mask_anat_mni else NO_PATH,
        str(gm_mni) if gm_mni else NO_PATH,
        str(refbold_t1w) if refbold_t1w else NO_PATH,
        str(refbold_native) if refbold_native else NO_PATH,
        str(matrix) if matrix else NO_PATH,
    )


def build_rows(base_path: Path, bids_filter: str | None) -> list[tuple[str, ...]]:
    filter_data = _load_bids_filter(bids_filter)
    func_query = _datatype_filter_query(filter_data, "func")
    anat_query = _datatype_filter_query(filter_data, "anat")

    boldrefs, anat_dirs, files_by_dir = scan_dataset(base_path)
    rows: set[tuple[str, ...]] = set()

    for boldref in boldrefs:
        boldref = boldref.resolve()
        entities = filename_entities(boldref)
        subject_label = entities.get("sub", "")
        session_label = entities.get("ses", "")
        space = normalize_space(entities.get("space", ""))

        if not subject_label or not allowed_space(space):
            continue

        subject = f"sub-{subject_label}"
        session = f"ses-{session_label}" if session_label else ""
        id_key = f"{subject}_{session}" if session else subject

        subject_root = nearest_subject_root(boldref, subject, base_path.resolve())
        if subject_root is None:
            raise ValueError(f"Could not locate a subject scope for boldref: {boldref}")
        session_root = nearest_session_root(boldref, session)

        func_dir = nearest_func_dir(boldref).resolve()
        func_files = files_by_dir.get(func_dir, [])
        resolution = infer_missing_mni_resolution(boldref, entities, func_files)

        filter_entities = dict(entities)
        filter_entities["space"] = space
        if resolution:
            filter_entities["res"] = resolution
        if not functional_filter_matches(filter_entities, func_query):
            continue

        anat_dir, native_t1 = resolve_anat_dir(
            boldref=boldref,
            subject_root=subject_root,
            session_root=session_root,
            subject_label=subject_label,
            session_label=session_label,
            anat_dirs=anat_dirs,
            files_by_dir=files_by_dir,
            anat_query=anat_query,
        )

        task = entities.get("task", "")
        acq = entities.get("acq", "")
        run = entities.get("run", "")

        resolved_files = resolve_work_item_files(
            boldref=boldref,
            func_dir=func_dir,
            anat_dir=anat_dir,
            native_t1=native_t1,
            files_by_dir=files_by_dir,
            subject_label=subject_label,
            session_label=session_label,
            task=task,
            acq=acq,
            run=run,
            space=space,
            resolution=resolution,
        )

        rows.add(
            (
                id_key,
                task or NONE,
                acq or NONE,
                run or NONE,
                space,
                resolution or NO_RESOLUTION,
                str(boldref),
                *resolved_files,
                subject,
                session or NONE,
                str(anat_dir),
                str(func_dir),
            )
        )

    return sorted(
        rows,
        key=lambda row: tuple(natural_sort_key(value) for value in row[:6]),
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build fully resolved work items from *_boldref.nii.gz files."
    )
    parser.add_argument("base_path")
    parser.add_argument("--bids-filter", "--bids_filter", dest="bids_filter")
    args = parser.parse_args()

    base_path = Path(args.base_path)
    if not base_path.is_dir():
        parser.error(f"input directory does not exist: {base_path}")

    try:
        rows = build_rows(base_path.resolve(), args.bids_filter)
    except (OSError, ValueError, FileNotFoundError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not rows:
        print(
            "ERROR: No T1w/MNI *_boldref.nii.gz work items were discovered "
            "after applying the functional BIDS filter.",
            file=sys.stderr,
        )
        return 1

    for row in rows:
        print(*row, sep="\t")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
