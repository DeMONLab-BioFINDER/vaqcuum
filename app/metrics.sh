# Use the runner's colored logger when available. These fallbacks allow this
# file to be sourced independently without producing "command not found".
if ! declare -F log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO ] %s\n' "$*" >&2; }
    log_ok()    { printf '[OK   ] %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN ] %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    log_step()  { printf '[STEP ] %s\n' "$*" >&2; }
    log_debug() { :; }
fi

# ============================================================
# METRIC 1: DICE
# ============================================================

extract_dice_metric() {
    local id_key="$1"
    local anat_mask="$2"
    local func_mask="$3"
    local space="${4:-}"
    local task="${5:-}"
    local acq="${6:-}"

    local intersection
    intersection="$id_tmp_dir/${id_key}_mask_intersection.nii.gz"

    local anat_voxels
    local func_voxels
    local intersection_voxels
    local dice_val
    local metric_file

    metric_file="$dice_dir/${id_key}_dice.csv"

    log_step "Dice: computing anatomical/functional mask overlap"
    echo "  id_key: $id_key" 
    echo "  anat_mask: $anat_mask" 
    echo "  func_mask: $func_mask"
    log_debug "Dice anatomical mask: $anat_mask"
    log_debug "Dice functional mask: $func_mask"

    # !!! if space not MNI, then resample func mask to anat space
    if [[ "$space" != *"MNI"* ]]; then
        local func_mask_resampled
        func_mask_resampled="$id_tmp_dir/${id_key}_func_mask_resampled.nii.gz"
        log_info "Resampling functional mask to anatomical space for Dice calculation"
        antsApplyTransforms \
            -d 3 \
            -i "$func_mask" \
            -r "$anat_mask" \
            -o "$func_mask_resampled" \
            -n NearestNeighbor \
            >&2
        func_mask="$func_mask_resampled"
        log_debug "Resampled functional mask: $func_mask"
    fi

    anat_voxels=$(fslstats "$anat_mask" -V | awk '{print $1}')
    func_voxels=$(fslstats "$func_mask" -V | awk '{print $1}')

    fslmaths "$anat_mask" -mul "$func_mask" "$intersection"

    intersection_voxels=$(fslstats "$intersection" -V | awk '{print $1}')

    dice_val=$(python3 -c \
        "print(round(2 * $intersection_voxels / ($anat_voxels + $func_voxels), 3))")

    rm -f "$intersection"

    {
        echo "id_key,space,task,acq,dice_val"
        echo "$id_key,$space,$task,$acq,$dice_val"
    } > "$metric_file"

    log_ok "Dice complete: value=$dice_val"
    log_debug "Dice CSV: $metric_file"
}

# ============================================================
# METRIC 2: DROPOUT
# ============================================================

extract_dropout_metric() {
    local id_key="$1"
    local gm_seg_file="$2"
    local anat_mask_mni="$3"
    local func_mask_mni="$4"
    local refbold_mni_file="$5"
    local space="${6:-}"
    local task="${7:-}"
    local acq="${8:-}"

    local mask_gm_thr
    local mask_merged
    local refbold_masked
    local new_mask_func
    local new_mask_func_inv
    local mask_dropout
    local mask_gm_thr_clean
    local metric_file

    local thresh
    local vol_dropout
    local nvox_dropout
    local vol_gm
    local nvox_gm
    local intensity_gm
    local intensity_dropout
    local dropout_intensity
    local dropout_size
    local dropout_compo

    metric_file="$dropout_dir/${id_key}_dropout.csv"

    mask_gm_thr="$id_tmp_dir/${id_key}_gm_thr.nii.gz"
    mask_merged="$id_tmp_dir/${id_key}_merged_mask.nii.gz"
    refbold_masked="$id_tmp_dir/${id_key}_desc-mask_boldref.nii.gz"
    new_mask_func="$id_tmp_dir/${id_key}_new_func_mask.nii.gz"
    new_mask_func_inv="$id_tmp_dir/${id_key}_new_func_mask_inv.nii.gz"
    mask_dropout="$id_tmp_dir/${id_key}_dropout_mask.nii.gz"
    mask_gm_thr_clean="$id_tmp_dir/${id_key}_gm_thr_clean.nii.gz"

    log_step "Dropout: thresholding gray matter and BOLD coverage"
    log_debug "Dropout GM segmentation: $gm_seg_file"
    log_debug "Dropout anatomical mask: $anat_mask_mni"
    log_debug "Dropout functional mask: $func_mask_mni"
    log_debug "Dropout BOLD reference: $refbold_mni_file"

    fslmaths "$gm_seg_file" \
        -thr "$gm_threshold" \
        -bin "$mask_gm_thr"

    fslmaths "$anat_mask_mni" \
        -add "$func_mask_mni" \
        -thr 1 \
        -bin "$mask_merged"

    fslmaths "$refbold_mni_file" \
        -mul "$mask_merged" \
        "$refbold_masked"

    thresh=$(fslstats "$refbold_masked" -l 0.001 -P "$dropout_percentile" 2>/dev/null | awk '{print $1}')

    if [[ -z "$thresh" || "$thresh" == "nan" || "$thresh" == "NaN" ]]; then
        log_error "Could not calculate dropout threshold"
        exit 1
    fi

    log_info "Dropout intensity threshold: $thresh"

    fslmaths "$refbold_masked" \
        -thr "$thresh" \
        -bin "$new_mask_func"

    fslmaths "$new_mask_func" \
        -binv "$new_mask_func_inv"

    fslmaths "$mask_gm_thr" \
        -mul "$new_mask_func_inv" \
        "$mask_dropout"

    vol_dropout=$(fslstats "$mask_dropout" -V | awk '{print $2}')
    nvox_dropout=$(fslstats "$mask_dropout" -V | awk '{print $1}')

    vol_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $2}')
    nvox_gm=$(fslstats "$mask_gm_thr" -V | awk '{print $1}')

    fslmaths "$mask_gm_thr" \
        -sub "$mask_dropout" \
        "$mask_gm_thr_clean"

    intensity_gm=$(fslstats "$refbold_mni_file" -k "$mask_gm_thr_clean" -M)
    intensity_dropout=$(fslstats "$refbold_mni_file" -k "$mask_dropout" -M)

    dropout_intensity=$(python3 - "$intensity_dropout" "$intensity_gm" <<'PY'
import sys
import math

numerator = float(sys.argv[1])
denominator = float(sys.argv[2])

if denominator == 0 or math.isnan(denominator):
    print("nan")
else:
    print(numerator / denominator)
PY
)

    dropout_size=$(python3 - "$vol_dropout" "$vol_gm" <<'PY'
import sys
import math

numerator = float(sys.argv[1])
denominator = float(sys.argv[2])

if denominator == 0 or math.isnan(denominator):
    print("nan")
else:
    print(numerator / denominator)
PY
)

    dropout_compo=$(python3 - "$dropout_intensity" "$dropout_size" <<'PY'
import sys
import math

dropout_intensity = float(sys.argv[1])
dropout_size = float(sys.argv[2])

if math.isnan(dropout_intensity) or math.isnan(dropout_size):
    print("nan")
else:
    print((1 - dropout_intensity) + dropout_size)
PY
)

    log_info "Dropout summary: GM volume=$vol_gm, dropout volume=$vol_dropout, intensity ratio=$dropout_intensity"
    log_ok "Dropout complete: composite=$dropout_compo"

    rm -f \
        "$mask_gm_thr_clean" \
        "$mask_merged" \
        "$refbold_masked" \
        "$new_mask_func_inv"

    {
        echo "id_key,space,task,acq,volume_gm,nvox_gm,intensity_gm,volume_dropout,nvox_dropout,intensity_dropout,dropout_intensity,dropout_size,dropout_compo"
        echo "$id_key,$space,$task,$acq,$vol_gm,$nvox_gm,$intensity_gm,$vol_dropout,$nvox_dropout,$intensity_dropout,$dropout_intensity,$dropout_size,$dropout_compo"
    } > "$metric_file"

    log_debug "Dropout CSV: $metric_file"
}

# ============================================================
# METRIC 3: MATTES / ENTROPY
# ============================================================

transform_bold_t1space() {
    local id_key="$1"
    local t1="$2"
    local matrix="$3"
    local refbold_file="$4"

    local bold_t1space

    bold_t1space="${id_tmp_dir}/${id_key}_space-T1w_desc-coreg_boldref.nii.gz"

    log_step "Registration: transforming BOLD reference into T1 space"
    log_debug "Transform input BOLD: $refbold_file"
    log_debug "Transform reference T1: $t1"
    log_debug "Transform matrix: $matrix"

    antsApplyTransforms \
        -d 3 \
        -i "$refbold_file" \
        -r "$t1" \
        -o "$bold_t1space" \
        -t "$matrix" \
        --interpolation LanczosWindowedSinc \
        >&2
    log_ok "BOLD-to-T1 transform complete"
    log_debug "Transformed BOLD reference: $bold_t1space"
    printf '%s\n' "$bold_t1space"
}

extract_nmi_metric() {
    local id_key="$1"
    local t1="$2"
    local t1_mask="$3"
    local refbold_t1space="$4"
    local wt1="$5"
    local mni_template="$6"
    local entropy_mni="$7"
    local mni_mask="$8"
    local space="${9:-}"
    local task="${10:-}"
    local acq="${11:-}"

    local metric_file
    local t1_mask_boldres
    local t1_boldres

    local mattes_t1_bold
    local mattes_wt1_mni

    local entropy_t1
    local entropy_bold
    local entropy_wt1

    metric_file="$nmi_dir/${id_key}_nmi.csv"
    t1_mask_boldres="${id_tmp_dir}/${id_key}_space-bold_desc-brain_T1wmask.nii.gz"
    t1_boldres="${id_tmp_dir}/${id_key}_space-bold_T1w.nii.gz"

    log_step "NMI: validating inputs and computing entropy terms"
    log_debug "NMI T1: $t1"
    log_debug "NMI T1 mask: $t1_mask"
    log_debug "NMI BOLD reference in T1 space: $refbold_t1space"
    log_debug "NMI warped T1: $wt1"
    log_debug "NMI template T1: $mni_template"
    log_debug "NMI template mask: $mni_mask"

    for required_file in \
        "$t1" \
        "$t1_mask" \
        "$refbold_t1space" \
        "$wt1" \
        "$mni_template" \
        "$mni_mask"
    do
        if [[ ! -f "$required_file" ]]; then
            log_error "Missing NMI input file: $required_file"
            return 1
        fi
    done

    log_info "NMI: resampling T1 mask and T1 image into the BOLD-reference grid"
    antsApplyTransforms \
        -d 3 \
        -i "$t1_mask" \
        -r "$refbold_t1space" \
        -o "$t1_mask_boldres" \
        -n NearestNeighbor \
        >&2

    antsApplyTransforms \
        -d 3 \
        -i "$t1" \
        -r "$refbold_t1space" \
        -o "$t1_boldres" \
        -n BSpline \
        >&2

    log_info "NMI: measuring T1/BOLD and warped-T1/template similarity"
    mattes_t1_bold=$(MeasureImageSimilarity \
        -d 3 \
        -m "Mattes[${t1_boldres},${refbold_t1space},1,${mattes_bins}]" \
        -x "$t1_mask_boldres")

    log_info "NMI: calculating image entropy values"
    entropy_t1=$(
        ImageIntensityStatistics \
        3 "$t1_boldres" "$t1_mask_boldres" |
        awk 'NR == 2 {print $6}'
    )

    entropy_bold=$(
        ImageIntensityStatistics \
            3 "$refbold_t1space" "$t1_mask_boldres" |
            awk 'NR == 2 {print $6}'
    )
    # do this only if space contains mni
    if [[ "$space" == *"MNI"* ]]; then
        entropy_wt1=$(
            ImageIntensityStatistics \
                3 "$wt1" "$mni_mask" |
                awk 'NR == 2 {print $6}'
        )
        mattes_wt1_mni=$(MeasureImageSimilarity \
        -d 3 \
        -m "Mattes[${wt1},${mni_template},1,${mattes_bins}]" \
        -x "$mni_mask")
    else
        entropy_wt1="NA"
        mattes_wt1_mni="NA"
    fi
    

    if [[ -z "$mattes_t1_bold" || -z "$mattes_wt1_mni" ]]; then
        log_error "Empty Mattes result"
        return 1
    fi

    if [[ -z "$entropy_t1" || -z "$entropy_bold" || -z "$entropy_wt1" || -z "$entropy_mni" ]]; then
        log_error "Empty entropy result"
        return 1
    fi

    {
        echo "id_key,space,task,acq,mattes_t1_bold,mattes_wt1_mni,entropy_t1,entropy_bold,entropy_wt1,entropy_mni"
        echo "$id_key,$space,$task,$acq,$mattes_t1_bold,$mattes_wt1_mni,$entropy_t1,$entropy_bold,$entropy_wt1,$entropy_mni"
    } > "$metric_file"

    log_info "NMI terms: T1/BOLD=$mattes_t1_bold, warped-T1/template=$mattes_wt1_mni"
    log_ok "NMI inputs complete"
    log_debug "NMI CSV: $metric_file"

    rm -f \
        "$t1_mask_boldres" \
        "$t1_boldres"
}

compute_nmi_merge_metrics() {
    log_step "Merge: loading per-id CSV files and calculating final NMI columns"
    log_debug "Dice directory: $dice_dir"
    log_debug "Dropout directory: $dropout_dir"
    log_debug "NMI directory: $nmi_dir"

    python - \
        "$dice_dir" \
        "$dropout_dir" \
        "$nmi_dir" \
        "$extracted_metrics_file" <<'PY'
import sys
from pathlib import Path
import pandas as pd
import numpy as np

dice_dir, dropout_dir, nmi_dir, output_file = map(Path, sys.argv[1:5])

keys = ["id_key", "space", "task", "acq"]

def read_metric_dir(metric_dir: Path, label: str) -> pd.DataFrame:
    files = sorted(metric_dir.glob("*.csv"))

    if not files:
        raise SystemExit(f"ERROR: No CSV files found for {label}: {metric_dir}")

    frames = []
    for file in files:
        df = pd.read_csv(file)

        if df.empty:
            raise SystemExit(f"ERROR: Empty CSV file for {label}: {file}")

        frames.append(df)

    out = pd.concat(frames, ignore_index=True)

    duplicates = out[out.duplicated(keys, keep=False)]
    if not duplicates.empty:
        raise SystemExit(
            f"ERROR: Duplicate id_key rows found in {label} metrics:\n"
            f"{duplicates.to_string(index=False)}"
        )

    return out


def numeric_col(df: pd.DataFrame, col: str) -> pd.Series:
    if col not in df.columns:
        raise SystemExit(f"ERROR: Missing required NMI column: {col}")

    return pd.to_numeric(df[col], errors="coerce")


def safe_nmi(entropy_a: pd.Series, entropy_b: pd.Series, mattes_term: pd.Series) -> pd.Series:
    out = (round((2*mattes_term) / (entropy_a + entropy_b), 3))
    out = out.replace([np.inf, -np.inf], np.nan)
    out = -1 * out
    return out


dice = read_metric_dir(dice_dir, "dice")
dropout = read_metric_dir(dropout_dir, "dropout")

required_dropout_cols = [
    "intensity_dropout",
    "intensity_gm",
    "volume_dropout",
    "volume_gm",
]

for col in required_dropout_cols:
    if col not in dropout.columns:
        raise SystemExit(f"ERROR: Missing required dropout column: {col}")

for col in required_dropout_cols:
    dropout[col] = pd.to_numeric(dropout[col], errors="coerce")

dropout["dropout_intensity"] = dropout["intensity_dropout"] / dropout["intensity_gm"]
dropout["dropout_size"] = dropout["volume_dropout"] / dropout["volume_gm"]
dropout["dropout_compo"] = (1 - dropout["dropout_intensity"]) + dropout["dropout_size"]

dropout = round(dropout.replace([np.inf, -np.inf], np.nan), 3)

# Keep only this dropout metric in the final merged CSV
dropout = dropout[keys + ["dropout_compo"]].copy()

nmi_raw = read_metric_dir(nmi_dir, "nmi")

nmi = nmi_raw[keys].copy()

nmi["nmi_t1_bold"] = safe_nmi(
    numeric_col(nmi_raw, "entropy_t1"),
    numeric_col(nmi_raw, "entropy_bold"),
    numeric_col(nmi_raw, "mattes_t1_bold"),
)

nmi["nmi_wt1_mni"] = safe_nmi(
    numeric_col(nmi_raw, "entropy_wt1"),
    numeric_col(nmi_raw, "entropy_mni"),
    numeric_col(nmi_raw, "mattes_wt1_mni"),
)

merged = (
    dice
    .merge(dropout, on=keys, how="outer", validate="one_to_one")
    .merge(nmi, on=keys, how="outer", validate="one_to_one")
)

merged = merged.sort_values(keys).reset_index(drop=True)

# Copy the MNI nmi_t1_bold value onto the corresponding T1w row.
mni_space_mask = (
    merged["space"]
    .astype("string")
    .str.contains("MNI", case=False, na=False)
)

t1w_space_masking = merged["space"].eq("T1w")

matching_mni_nmi = (
    merged["nmi_t1_bold"]
    .where(mni_space_mask)
    .groupby(
        [
            merged["id_key"],
            merged["task"],
            merged["acq"],
        ],
        dropna=False,
    )
    .transform("first")
)

rows_to_update = t1w_space_masking & matching_mni_nmi.notna()

merged.loc[rows_to_update, "nmi_t1_bold"] = (
    matching_mni_nmi.loc[rows_to_update]
)

merged.loc[t1w_space_masking, "nmi_wt1_mni"] = np.nan

final_columns = [
    "id_key",
    "space",
    "task",
    "acq",
    "dice_val",
    "dropout_compo",
    "nmi_t1_bold",
    "nmi_wt1_mni",
]

missing_columns = [
    col for col in final_columns
    if col not in merged.columns
]

if missing_columns:
    raise SystemExit(
        f"ERROR: Missing final metric columns: {missing_columns}"
    )

merged = merged[final_columns]
output_file.parent.mkdir(parents=True, exist_ok=True)

# if id_key contains ses-id, we can split it into sub_id and ses_id columns
if merged["id_key"].str.contains("_ses-").any():
    merged[["sub_id", "ses_id"]] = merged["id_key"].str.split("_ses-", n=1, expand=True)
    merged["ses_id"] = "ses-" + merged["ses_id"]
    final_columns = ["sub_id", "ses_id"] + [col for col in final_columns if col != "id_key"]
    merged = merged[final_columns]
merged.to_csv(output_file, index=False)

print(f"Wrote merged metrics to: {output_file}", file=sys.stderr)
PY

    log_ok "Merged metrics CSV written: $extracted_metrics_file"
}