#!/usr/bin/env python3
"""validate a dataset using the same work item resolver as the main pipeline"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from boldref_manifest import NONE, NO_RESOLUTION, build_rows
from dataset_utils import visualize_tree


def row_summary(rows: list[tuple[str, ...]]) -> dict[str, object]:
    subjects = sorted({row[17] for row in rows})
    sessions = sorted({row[18] for row in rows if row[18] != NONE})
    spaces = sorted({row[4] for row in rows})
    resolutions = sorted({row[5] for row in rows if row[5] != NO_RESOLUTION})

    return {
        "work_items": len(rows),
        "subjects": subjects,
        "sessions": sessions,
        "spaces": spaces,
        "resolutions": resolutions,
    }


def print_report(dataset_root: Path, rows: list[tuple[str, ...]]) -> None:
    summary = row_summary(rows)

    print(f"dataset: {dataset_root}")
    print("status: valid")
    print(f"work items: {summary['work_items']}")
    print(f"subjects: {len(summary['subjects'])}")
    print(f"sessions: {len(summary['sessions'])}")
    print(f"spaces: {', '.join(summary['spaces']) or 'none'}")
    print(f"resolutions: {', '.join(summary['resolutions']) or 'unspecified'}")


def print_verbose_rows(rows: list[tuple[str, ...]]) -> None:
    print("\nresolved work items:")

    for row in rows:
        task = "" if row[1] == NONE else row[1]
        acq = "" if row[2] == NONE else row[2]
        run = "" if row[3] == NONE else row[3]
        resolution = "" if row[5] == NO_RESOLUTION else row[5]
        session = "" if row[18] == NONE else row[18]

        entities = [row[17]]
        if session:
            entities.append(session)
        if task:
            entities.append(f"task-{task}")
        if acq:
            entities.append(f"acq-{acq}")
        if run:
            entities.append(f"run-{run}")
        entities.append(f"space-{row[4]}")
        if resolution:
            entities.append(f"res-{resolution}")

        print(f"  {' '.join(entities)}")
        print(f"    boldref: {row[6]}")
        print(f"    func: {row[20]}")
        print(f"    anat: {row[19]}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="validate a dataset using vaqcuum work item discovery",
    )
    parser.add_argument("dataset_root", help="root directory of the derivatives dataset")
    parser.add_argument(
        "--bids-filter",
        "--bids_filter",
        dest="bids_filter",
        help="optional bids filter json",
    )
    parser.add_argument(
        "--tree",
        action="store_true",
        help="print a compact directory tree",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=3,
        help="tree depth used with --tree",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="show resolved work items",
    )
    args = parser.parse_args()

    dataset_root = Path(args.dataset_root).resolve()
    if not dataset_root.is_dir():
        parser.error(f"dataset directory does not exist: {dataset_root}")

    # use the same discovery and resolution logic as runner.sh
    try:
        rows = build_rows(dataset_root, args.bids_filter)
    except (OSError, ValueError, FileNotFoundError) as exc:
        print(f"dataset: {dataset_root}")
        print("status: invalid")
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if not rows:
        print(f"dataset: {dataset_root}")
        print("status: invalid")
        print("error: no work items were discovered", file=sys.stderr)
        return 1

    print_report(dataset_root, rows)

    if args.verbose:
        print_verbose_rows(rows)

    if args.tree:
        print()
        visualize_tree(str(dataset_root), max_depth=args.depth)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
