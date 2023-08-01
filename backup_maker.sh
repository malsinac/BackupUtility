#!/bin/bash
#set -euo pipefail

# Program that backups data from that computer
# It uses both restic and borgbackup, and it 
# stores all files in the Seagate HDD and on 
# the cloud.

write_log(){
  echo "[$(date)]  $1"
}

make_borg_backup() {
  # Borg can be used only for writing data on HDD drive, since cryptography is bad
  # $1 -> Borg repository direction

  borg create --verbose --list --stats --progress --show-rc --compression zlib,6 --exclude-caches \
    --exclude "${EXCLUDE_FIES[*]}" "$1"::'{hostname}-{now}' "${DIRS_TO_BACKUP[*]}"

  # Pruning to mantain 7 daily, 4 weekly and 6 montly backups
  borg prune --verbose --list --glob-archives '{hostname}-*' --show-rc --keep-daily 7 --keep weekly 4 \
    --keep-montly 6 "$1"

  # Compacting space in the repository
  borg compact "$1" 

  # Checking integrity of the backup
  borg check --verbose --max-duration=3600 "$1"

}

make_restic_backup_local() {
  # Restic can be used to backup either on a HHD and the cloud
  # $1 -> restic repo location

  restic -r "$1" --verbose --compression max backup "${DIRS_TO_BACKUP[*]}" --read-concurrency\
    --exclue "${EXCLUDE_FIES[*]}" --exclude-caches

  # Pruning to mantain 7 daily, 4 weekly and 6 montly
  restic -r "$1" --verbose forget --keep-within-daily 7d --keep-within-weekly 1m --keep-within-montly 6m\
    --prune

  # Checking integrity of the backup
  restic -r "$1" check
}

write_log "Starting backup process"

DIRS_TO_BACKUP=( "/home/malsina/Documents" \
                 "/home/malsina/Downloads" \
                 "/home/malsina/Projects" \
                 "/home/malsina/VirtualBox\ VMs" \
                 "/home/malsina/Zotero" \
                 "/home/malsina/Desktop" \
                 "/home/malsina/Pictures" \
                 "/home/malsina/Videos" \
                 "/home/malsina/.vimrc" \
                 "/home/malsina/.bashrc" \
                 "/home/malsina/.gitconfig" \
                 "/home/malsina/.bash_aliases" \
                 "/home/malsina/.ssh" \
                 "/home/malsina/.gnupg" \
                 "/home/malsina/.password-store" \
                 "/home/malsina/.config/nvim" \
                 "/home/malsina/Scripts/backup_maker.sh"
)

EXCLUDE_FIES=( ".mod" ".o" "*.pyc" )

source /home/malsina/miniconda3/etc/profile.d/conda.sh 

# Read conda environments packages to be able to install in the future
CONDA_ENVS="$(conda env list | tail -n +3 | awk '{print $1}')"

for env in "${CONDA_ENVS[@]}"; do
  conda activate "$env"
  conda env export > /home/malsina/"${env}".yml
  DIRS_TO_BACKUP+=( "/home/malsina/${env}.yml" )
  conda deactivate
done

write_log "Exported conda environments"

# Outputting installed packages
apt list > /home/malsina/installed_packgs.dat
DIRS_TO_BACKUP+=( "/home/malsina/installed_packgs.dat" )

snap list > /home/malsina/installed_packages_snap.txt
DIRS_TO_BACKUP+=( "/home/malsina/installed_packages_snap.txt" )

write_log "Starting copying files"

num_files="0"
for backup_dir in "${DIRS_TO_BACKUP[@]}"; do
    if [[ -f $backup_dir ]]; then
        num_files_dir="1"
    else
        num_files_dir=$(find "${backup_dir}" -type f 2> /dev/null | wc -l)
    fi
    echo "$backup_dir $num_files_dir"
  num_files="$(echo "$num_files + $num_files_dir" | bc -l)"
done
write_log "Number of files inside the backup direcotries: ${num_files}"

#read -rp "Enter password for Borg repository:   " ${BORG_PASSW:-}
#read -rp "Enter password for Restic repository: " ${RESTIC_PASSW:-}


# Cleaning up the generated files
for env in ${CONDA_ENVS}; do
  rm "/home/malsina/${env}.yml"
done


rm "/home/malsina/installed_packgs.dat" 
rm "/home/malsina/installed_packages_snap.txt"
