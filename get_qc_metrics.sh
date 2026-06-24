#!/bin/bash

#SBATCH -A sens2024059
#SBATCH -J=qc_c3d
#SBATCH --time=72:00:00



set -euo pipefail

module load c3d/1.4.4
module load fsl/6.0


pathroot="/proj/sens2024059/datasets/A4_LEARN"

list_sid="${pathroot}/raw/code/list_sid_avFTP_fMRI.txt"
output_file="${pathroot}/raw/code/qc_metrics_corr.txt"

mni_img="/proj/sens2024059/templates/templateflow/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-02_T1w.nii.gz"
mni_centroid=$(c3d "${mni_img}" -centroid | awk '/VOX/')

echo "sid session dc dice_masks ncor_epi_t1 ncor_t1_mni mni_centroid epi_centroid t1_centroid cor_gm_t1_epi sd_noise mean_ofc mean_temp mean_put" > "$output_file"

for sid in $(cat "$list_sid"); do
    sub_dir="${pathroot}/derivatives/fmriprep_ses/sub-${sid}"
    
    for session in $(find "${sub_dir}" -maxdepth 1 -name "ses-*" -type d | sed 's/.*ses-//'); do
        
        bold_dc="${sub_dir}/ses-${session}/sub-${sid}/ses-${session}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
        
        if [[ -f "$bold_dc" ]]; then
        	echo "$bold_dc exists"
        	
        	dc="yes"
        	fmriprep_dir="${pathroot}/derivatives/fmriprep_ses/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}"
			mask_func="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
			boldref_img="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
			bold_img="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_acq-dc_space-MNI152NLin2009cAsym_res-2_desc-preproc_bold.nii.gz"
            
        else
            echo "$bold_dc doesnt exist"
            
            dc="no"
            fmriprep_dir="${pathroot}/derivatives/fmriprep_ses_sdc/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}"
			mask_func="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz"
			boldref_img="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_boldref.nii.gz"
			bold_img="${fmriprep_dir}/func/sub-${sid}_ses-${session}_task-rest_space-MNI152NLin2009cAsym_res-2_desc-preproc_bold.nii.gz"
           
        fi
        
        mask_anat=$(find "${fmriprep_dir}/anat" -type f -name "*_space-MNI152NLin2009cAsym_res-2_desc-brain_mask.nii.gz")
        t1_img=$(find "${fmriprep_dir}/anat" -type f -name "*_space-MNI152NLin2009cAsym_res-2_desc-preproc_T1w.nii.gz")

        
        # dice between anat and func mask
        dice_mask=$(c3d -verbose "${mask_anat}" "${mask_func}" -overlap 1 | awk '/Dice/ {print $4}')
        
        # similarity EPI T1w
		ncor_epi_t1=$(c3d "${t1_img}" "${boldref_img}" -ncor | awk '/NCOR/ {print $3}')

		# similarity MNI T1w
		ncor_t1_mni=$(c3d "${t1_img}" "${mni_img}" -ncor | awk '/NCOR/ {print $3}')

		# centroids
		epi_centroid=$(c3d "${boldref_img}" -centroid | awk '/VOX/')
		t1_centroid=$(c3d "${t1_img}" -centroid | awk '/VOX/')
		
		# GM cross-correlation
		mask_gm=$(find "${pathroot}/derivatives/fmriprep_ses/sub-${sid}/ses-${session}/sub-${sid}/ses-${session}/anat" -type f -name "*_space-MNI152NLin2009cAsym_res-2_label-GM_mask_0-3.nii.gz")
		fslmaths "${t1_img}" -mas "${mask_gm}" "${fmriprep_dir}/GM_t1w.nii.gz"
		fslmaths "${boldref_img}" -mas "${mask_gm}" "${fmriprep_dir}/GM_boldref.nii.gz"
		cc_gm=$(c3d "${fmriprep_dir}/GM_boldref.nii.gz" "${fmriprep_dir}/GM_t1w.nii.gz" -ncor | awk '/NCOR/ {print $3}')
		
		# snr 
		atlas="${pathroot}/derivatives/atlases/sub-${sid}/ses-${session}/schaefer_supplemented/atlas-Schaefer200TianS2Cereb/atlas-Schaefer200TianS2Cereb_space-MNI152NLin2009cAsym_res-2_dseg.nii.gz"
		roi_ofc="${pathroot}/derivatives/atlases/sub-${sid}/ses-${session}/ofc.nii.gz"
		roi_temp="${pathroot}/derivatives/atlases/sub-${sid}/ses-${session}/temp_pole.nii.gz"
		put="${pathroot}/derivatives/atlases/sub-${sid}/ses-${session}/putamen.nii.gz"
		
		c3d "${atlas}" -retain-labels 55 56 65 159 160 161 -o "${roi_ofc}"
		c3d "${atlas}" -retain-labels 57 58 59 60 162 163 164 -o "${roi_temp}"
		c3d "${atlas}" -retain-labels 213 214 229 230 -o "${put}"
		
		noise_roi="/proj/sens2024059/nobackup/chauveau/roi_noise.nii.gz"
		mean_ofc=$(fslstats $bold_img -k $roi_ofc -M)
		mean_temp=$(fslstats $bold_img -k $roi_temp -M)
		mean_put=$(fslstats $bold_img -k $put -M)
		sd_noise=$(fslstats $bold_img -k $noise_roi -S)
		
		rm "${fmriprep_dir}/GM_t1w.nii.gz" "${fmriprep_dir}/GM_boldref.nii.gz" $roi_ofc $roi_temp $put

        echo "$sid $session | Dice= $dice_mask | Norm corr= $ncor_epi_t1 $ncor_t1_mni | Centroid= $mni_centroid $epi_centroid $t1_centroid | GM cc= $cc_gm | SNR= $sd_noise $mean_ofc $mean_temp $mean_put"
        echo "$sid $session $dc $dice_mask $ncor_epi_t1 $ncor_t1_mni $mni_centroid $epi_centroid $t1_centroid $cc_gm $sd_noise $mean_ofc $mean_temp $mean_put" >> "$output_file"
        
    done
done