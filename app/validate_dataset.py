#!/usr/bin/env python3
"""
Dataset validation script for vaqcuum pipeline.

Validates fMRIPrep output dataset structure and reports issues.
Usage: python validate_dataset.py <dataset_root> [--config CONFIG.yml]
"""

import argparse
import sys
import json
from pathlib import Path

# Add the app directory to path to import dataset_utils
sys.path.insert(0, str(Path(__file__).parent))

from dataset_utils import (
    validate_dataset_structure,
    discover_folder_structure,
    extract_dataset_structure,
    visualize_tree,
    get_subject_files
)


def load_config(config_path: str) -> dict:
    """Load YAML config file."""
    try:
        import yaml
        with open(config_path, 'r') as f:
            return yaml.safe_load(f)
    except ImportError:
        print("Warning: PyYAML not installed, using basic config parsing")
        # Fallback: simple parsing for input_dir
        config = {}
        with open(config_path, 'r') as f:
            for line in f:
                if 'input_dir:' in line:
                    config['input_dir'] = line.split(':')[1].strip().strip('"\'')
        return config


def print_validation_report(report: dict) -> None:
    """Pretty print validation report."""
    print("\n" + "=" * 70)
    print("DATASET VALIDATION REPORT")
    print("=" * 70)
    
    # Overall status
    status = "✓ VALID" if report['is_valid'] else "✗ INVALID"
    print(f"\nStatus: {status}")
    print(f"Structure Type: {report['structure_type']}")
    
    # Summary
    if report['summary']:
        print(f"\nSummary:")
        for key, value in report['summary'].items():
            if isinstance(value, dict):
                print(f"  {key}:")
                for k, v in value.items():
                    print(f"    {k}: {v}")
            else:
                print(f"  {key}: {value}")
    
    # Errors
    if report['errors']:
        print(f"\nErrors ({len(report['errors'])}):")
        for error in report['errors']:
            print(f"  ✗ {error}")
    
    # Warnings
    if report['warnings']:
        print(f"\nWarnings ({len(report['warnings'])}):")
        for warning in report['warnings']:
            print(f"  ⚠ {warning}")
    
    if not report['errors'] and not report['warnings']:
        print("\n✓ No issues detected!")
    
    print("\n" + "=" * 70)


def main():
    parser = argparse.ArgumentParser(
        description="Validate fMRIPrep dataset structure for vaqcuum pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python validate_dataset.py /path/to/dataset
  python validate_dataset.py /path/to/dataset --config config.yml --verbose
  python validate_dataset.py /path/to/dataset --tree --depth 2
        """
    )
    
    parser.add_argument(
        'dataset_root',
        help='Root directory of the dataset'
    )
    parser.add_argument(
        '--config', '-c',
        help='Path to config file to validate against'
    )
    parser.add_argument(
        '--subjects',
        nargs='+',
        help='Expected subject IDs (e.g., sub-001 sub-002)'
    )
    parser.add_argument(
        '--datatypes',
        nargs='+',
        default=['anat', 'func'],
        help='Expected data types (default: anat func)'
    )
    parser.add_argument(
        '--tree',
        action='store_true',
        help='Print directory tree visualization'
    )
    parser.add_argument(
        '--depth',
        type=int,
        default=3,
        help='Tree depth when using --tree (default: 3)'
    )
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Verbose output with detailed info'
    )
    parser.add_argument(
        '--flat',
        action='store_true',
        help='Allow flat (sub_ses_fmriprep) structure'
    )
    
    args = parser.parse_args()
    
    dataset_root = args.dataset_root
    
    # Check if dataset exists
    if not Path(dataset_root).exists():
        print(f"Error: Dataset path does not exist: {dataset_root}")
        sys.exit(1)
    
    print(f"Validating dataset: {dataset_root}")
    
    # Load config if provided
    expected_subjects = args.subjects
    if args.config and not args.subjects:
        try:
            config = load_config(args.config)
            print(f"Loaded config: {args.config}")
        except Exception as e:
            print(f"Warning: Could not load config: {e}")
    
    # Run validation
    report = validate_dataset_structure(
        dataset_root,
        expected_subjects=expected_subjects,
        expected_datatypes=args.datatypes,
        require_nested=not args.flat
    )
    
    # Print report
    print_validation_report(report)
    
    # Verbose output
    if args.verbose:
        print("\n" + "=" * 70)
        print("DETAILED STRUCTURE INFORMATION")
        print("=" * 70)
        
        extracted = extract_dataset_structure(dataset_root)
        
        print(f"\nNested Subjects ({len(extracted['valid_subjects'])}):")
        for sub in sorted(extracted['valid_subjects']):
            print(f"  {sub}")
            for ses_dt, files in sorted(extracted['directory_hierarchy'][sub].items()):
                print(f"    {ses_dt}: {len(files)} files")
        
        if extracted['flat_subjects']:
            print(f"\nFlat Subjects ({len(extracted['flat_subjects'])}):")
            for sub in sorted(extracted['flat_subjects']):
                print(f"  {sub}")
        
        print(f"\nFile Inventory by Type:")
        for dtype in sorted(extracted['file_inventory'].keys()):
            files = extracted['file_inventory'][dtype]
            # Show first 3 unique files
            unique_files = sorted(set(f for f in files[:20]))
            print(f"  {dtype}: {len(files)} files total")
            for f in unique_files[:3]:
                print(f"    - {Path(f).name}")
            if len(unique_files) > 3:
                print(f"    ... and {len(unique_files) - 3} more")
    
    # Print tree if requested
    if args.tree:
        visualize_tree(dataset_root, max_depth=args.depth)
    
    # Exit with appropriate code
    sys.exit(0 if report['is_valid'] else 1)


if __name__ == '__main__':
    main()
