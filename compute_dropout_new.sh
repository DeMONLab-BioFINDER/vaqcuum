#!/bin/bash
set -euo pipefail

module load c3d/1.4.4
module load fsl/6.0
source ${FSLDIR}/etc/fslconf/fsl.sh

pathroot="/proj/sens2024059/datasets/A4_LEARN"

list_sid="${pathroot}/raw/code/list_sid_avFTP_fMRI.txt"
output_file="${pathroot}/raw/code/dropout10_new.txt"

echo "sid session dc volume_gm nvox_gm intensity_gm volume_dropout nvox_dropout intensity_dropout" > "$output_file"

for sid in $(cat "$list_sid"); do
    sub_dir="${pathroot}/derivatives/fmriprep_ses/sub-${sid}"
    
    for session in $(find "${sub_dir}" -maxdepth 1 -name "ses-*" -type d | sed 's/.*ses-//'); do
        
        bold_dc="${sub_dir}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
        
        if [[ -f "$bold_dc" ]]; then
        	echo "$bold_dc exists"
        	
        	dc="yes"
        	fmriprep_dir="${pathroot}/derivatives/fmriprep_ses/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}"
        	mask_func="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
        	boldref="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
        	boldref_masked="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_boldref_masked.nii.gz"
        	bold="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_desc-preproc_bold.nii.gz"
            
        else
            echo "$bold_dc doesnt exist"
            
            dc="no"
            fmriprep_dir="${pathroot}/derivatives/fmriprep_ses_sdc/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}"
           	mask_func="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
           	boldref="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
           	bold="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_desc-preproc_bold.nii.gz"
           	boldref_masked="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_boldref_masked.nii.gz"
           	
        fi
        
        mask_gm=$(find "${pathroot}/derivatives/fmriprep_ses/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/anat" -type f -name "*_space-MNI152NLin2009cAsym_res-2_label-GM_mask_0-3.nii.gz")
        mask_anat=$(find "${fmriprep_dir}/anat" -type f -name "*_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz")
        new_mask_func="${fmriprep_dir}/func/sub-${sid}_ses-${session}_space-MNI152NLin2009cAsym_res-2_boldref_new-mask.nii.gz"
        mask_dropout="${fmriprep_dir}/func/sub-${sid}_ses-${session}_space-MNI152NLin2009cAsym_res-2_dropout10_mask.nii.gz"
        mask_gm_clean="${fmriprep_dir}/anat/sub-${sid}_ses-${session}_space-MNI152NLin2009cAsym_res-2_GM_wo-dropout_temp.nii.gz"
        mask_merged="${fmriprep_dir}/sub-${sid}_ses-${session}_space-MNI152NLin2009cAsym_res-2_anat-func-masks-merged.nii.gz"
        
        c3d $mask_anat $mask_func -add -replace 2 1 -o $mask_merged
        fslmaths $boldref -mul $mask_merged $boldref_masked
        
		thresh=$(fslstats $boldref_masked -l 0.001 -P 10)
		fslmaths $boldref_masked -thr $thresh -bin $new_mask_func
		
		c3d "${mask_gm}" "${new_mask_func}" -scale -1 -add -o "${mask_dropout}"
		c3d "${mask_dropout}" -replace 1 1 0 0 -1 0 -o "${mask_dropout}"

		vol_dropout=$(c3d "${mask_dropout}" -dup -lstat | awk 'NR==3 {print $7}')
		nvox_dropout=$(c3d "${mask_dropout}" -dup -lstat | awk 'NR==3 {print $6}')

		vol_gm=$(c3d "${mask_gm}" -dup -lstat | awk 'NR==3 {print $7}')
		nvox_gm=$(c3d "${mask_gm}" -dup -lstat | awk 'NR==3 {print $6}')
		
		fslmaths $mask_gm -sub $mask_dropout $mask_gm_clean
		intenisty_gm=$(fslstats $boldref -k $mask_gm_clean -M)
		intenisty_dropout=$(fslstats $boldref -k $mask_dropout -M)

			        
        echo "$sid $session | GM: $vol_gm $intenisty_gm | dropouts: $vol_dropout $intenisty_dropout"
        echo "$sid $session $dc $vol_gm $nvox_gm $intenisty_gm $vol_dropout $nvox_dropout $intenisty_dropout" >> "$output_file"
        
        rm $mask_gm_clean $mask_merged $boldref_masked 
        
    done
done

