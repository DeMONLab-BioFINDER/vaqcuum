#!/bin/bash
set -euo pipefail

# https://github.com/ANTsX/ANTs/discussions/1706

path_fmriprep="/proj/sens2024059/datasets/A4_LEARN/derivatives/fmriprep_ses"
container="/proj/sens2024059/sif/fmriprep_v25.1.1.sif"
nmi_file="/proj/sens2024059/datasets/A4_LEARN/raw/code/nmi_masked.txt"
list_sid="/proj/sens2024059/datasets/A4_LEARN/raw/code/list_sid_avFTP_fMRI.txt"
mni="/proj/sens2024059/templates/templateflow/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-02_T1w.nii.gz"
mni_mask="/proj/sens2024059/templates/templateflow/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-02_desc-brain_mask.nii.gz"

entropy_mni=$(apptainer exec "$container" ImageIntensityStatistics 3 "$mni" "$mni_mask" | awk 'NR==2 {print $6}')

echo "sid session dc mattes_t1_bold mattes_wt1_mni mattes_wbold_mni entropy_t1 entropy_bold entropy_wt1 entropy_wbold entropy_mni" > "$nmi_file"

for sid in $(cat "$list_sid"); do
    sub_dir="${path_fmriprep}/sub-${sid}"

    for session in $(find "${sub_dir}" -maxdepth 1 -name "ses-*" -type d | sed 's/.*ses-//'); do

        refbold_dc="${sub_dir}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-T1w_boldref.nii.gz"

        if [[ -f "$refbold_dc" ]]; then
            echo "$refbold_dc exists"
            dc="yes"
            refbold="$refbold_dc"
            refbold_mni="${sub_dir}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
            anat_dir="/proj/sens2024059/datasets/A4_LEARN/derivatives/fmriprep_ses/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/anat"
        else
            echo "$refbold_dc doesnt exist"
            dc="no"
            refbold="/proj/sens2024059/datasets/A4_LEARN/derivatives/fmriprep_ses_sdc/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_space-T1w_boldref.nii.gz"
            refbold_mni="/proj/sens2024059/datasets/A4_LEARN/derivatives/fmriprep_ses_sdc/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
            anat_dir="/proj/sens2024059/datasets/A4_LEARN/derivatives/fmriprep_ses_sdc/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/anat"
        fi

        t1=$(find "$anat_dir" -type f -name "*_desc-preproc_T1w.nii.gz" | grep -v "space-MNI152NLin2009cAsym_res-2")
        t1_mask=$(find "$anat_dir" -type f -name "*_desc-brain_mask.nii.gz" | grep -v "space-MNI152NLin2009cAsym_res-2")
        wt1=$(find "$anat_dir" -type f -name "*_space-MNI152NLin2009cAsym_res-2_desc-preproc_T1w.nii.gz")

        t1_mask_bold_space="/tmp/mask_${sid}_${session}_bold_space.nii.gz"
        t1_resampled="/tmp/t1_${sid}_${session}_bold_space.nii.gz"

		# need masks to be in the same resolution for calculating entropy + then resample t1 to make it homogeneous
        apptainer exec "$container" antsApplyTransforms -d 3 -i "$t1_mask" -r "$refbold" -o "$t1_mask_bold_space" -n NearestNeighbor
        apptainer exec "$container" antsApplyTransforms -d 3 -i "$t1" -r "$refbold" -o "$t1_resampled" -n BSpline

		# Mattes
        mattes_t1_bold=$(apptainer exec "$container" MeasureImageSimilarity -d 3 -m Mattes["$t1_resampled","$refbold",1,64] -x "$t1_mask_bold_space")
        mattes_wt1_mni=$(apptainer exec "$container" MeasureImageSimilarity -d 3 -m Mattes["$wt1","$mni",1,64] -x "$mni_mask")
        mattes_wbold_mni=$(apptainer exec "$container" MeasureImageSimilarity -d 3 -m Mattes["$refbold_mni","$mni",1,64] -x "$mni_mask")

        # Entropies
        entropy_t1=$(apptainer exec "$container" ImageIntensityStatistics 3 "$t1_resampled" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
        entropy_bold=$(apptainer exec "$container" ImageIntensityStatistics 3 "$refbold" "$t1_mask_bold_space" | awk 'NR==2 {print $6}')
        entropy_wt1=$(apptainer exec "$container" ImageIntensityStatistics 3 "$wt1" "$mni_mask" | awk 'NR==2 {print $6}')
        entropy_wbold=$(apptainer exec "$container" ImageIntensityStatistics 3 "$refbold_mni" "$mni_mask" | awk 'NR==2 {print $6}')

        echo "$sid $session $mattes_t1_bold $mattes_wt1_mni $mattes_wbold_mni"
        echo "$sid $session $dc $mattes_t1_bold $mattes_wt1_mni $mattes_wbold_mni $entropy_t1 $entropy_bold $entropy_wt1 $entropy_wbold $entropy_mni" >> "$nmi_file"

        rm -f "$t1_mask_bold_space" "$t1_resampled"
    done
done