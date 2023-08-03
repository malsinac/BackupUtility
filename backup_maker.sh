#!/bin/bash
set -euo pipefail

log_file="$HOME/backup_$(date --iso-8601).log"
exec > >(tee "$log_file") 2>&1

# Program that backups data from that computer
# It uses both restic and borgbackup, and it 
# stores all files in the HDD and on 
# the cloud.

write_log(){
  echo "[$(date)]  $1"
}

init_restic_repo(){
  local bk_dir="{$1}_restic"
  
  write_log "Initializing Restic repository"
  RESTIC_PASSWORD="$2" restic init --repo "$bk_dir"
}

init_borg_repo(){
  # Initialize a repository for BorgBackup
  # $1 is the repository location
  # $2 is the password of the repository
  # $3 is the location to where to store the key

  local bk_dir="{$1}_borg"

  write_log "Initializing BorgBackup repository"
  BORG_PASSPHRASE=$2 borg init --encryption=repokey-blake2 "$bk_dir"

}

export_restic_keys(){
  echo "Not implemented"
}

export_borg_keys(){
  echo "Not implemented"
}

make_borg_backup() {
  # Borg can be used only for writing data on HDD drive, since cryptography is bad
  # $1 -> Borg repository direction
  # $2 is the repository passphrase

  local bk_dir="${1}_borg"

  # Giving info about the repository
  BORG_PASSPHRASE="$2" borg info "$bk_dir"

  # Making the backup
  BORG_PASSPHRASE="$2" borg create --verbose --list --stats --progress --show-rc --compression zlib,6 --exclude-caches \
     "$bk_dir"::'{hostname}-{now}' ${DIRS_TO_BACKUP[*]}

  # Pruning to mantain 7 daily, 4 weekly and 6 montly backups
  BORG_PASSPHRASE="$2" borg prune --verbose --list --glob-archives '{hostname}-*' --show-rc --keep-daily 7 --keep-weekly 4 \
    --keep-montly 6 "$bk_dir"

  # Compacting space in the repository
  BORG_PASSPHRASE="$2" borg compact "$bk_dir" 

  # Checking integrity of the backup
  BORG_PASSPHRASE="$2" borg check --verbose --max-duration=3600 "$bk_dir"
}

make_restic_backup() {
  # Restic can be used to backup either on a HHD and the cloud
  # $1 -> restic repo location
  
  local bk_dir="${1}_restic"

  # Showing existing snapshots
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" snapshots
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" stats -v

  # Backing up
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose backup ${DIRS_TO_BACKUP[*]} \
    --exclude ${EXCLUDE_FIES[*]} --exclude-caches

  # Pruning to mantain 7 daily, 4 weekly and 6 montly
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose forget --keep-within-daily 7d --keep-within-weekly 1m --keep-within-monthly 6m\
    --prune

  # Checking integrity of the backup
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" check
}

clean_files() {
  # Cleaning up the generated files
  for env in ${CONDA_ENVS}; do
    rm -f "$HOME/${env}.yml"
  done


  rm -f "$HOME/installed_packgs.dat" 
  rm -f "$HOME/installed_packages_snap.txt"
}

count_backup_files() {
  local num_files="0"
  for backup_dir in "${DIRS_TO_BACKUP[@]}"; do
      if [[ -f $backup_dir ]]; then
          num_files_dir="1"
      else
          num_files_dir=$(find "${backup_dir}" -type f 2> /dev/null | wc -l)
      fi

    num_files="$(echo "$num_files + $num_files_dir" | bc -l)"
  done
  write_log "Number of files inside the backup direcotries: ${num_files}"
}

read_dirs_to_backup() {
  while IFS= read -r target_dir || [[ -n "$target_dir" ]]
  do
    DIRS_TO_BACKUP+=( "$target_dir" )
  done < dirs_to_backup.txt
}

read_files_to_exclude() {
  while IFS= read -r target_dir || [[ -n "$target_dir" ]]
  do
    EXCLUDE_FIES+=( "$target_dir" )
  done < exclude_files.txt
}

output_packages_environments() {
  source "$HOME"/miniconda3/etc/profile.d/conda.sh 

  # Read conda environments packages to be able to install in the future
  CONDA_ENVS="$(conda env list | tail -n +3 | awk '{print $1}')"

  write_log "Retrived conda environments, exporting them"

  for env in "${CONDA_ENVS[@]}"; do
    if [[ "$env" =~ base ]]
    then
      continue
    fi
    conda activate "$env"
    conda env export > "$HOME"/"${env}".yml
    DIRS_TO_BACKUP+=( "$HOME/${env}.yml" )
    conda deactivate
  done

  write_log "Exported conda environments"

  # Outputting installed packages
  apt list > "$HOME"/installed_packgs.dat
  DIRS_TO_BACKUP+=( "$HOME/installed_packgs.dat" )

  snap list > "$HOME"/installed_packages_snap.txt
  DIRS_TO_BACKUP+=( "$HOME/installed_packages_snap.txt" )

  write_log "Exported apt packages"
}

################################################################################################
#                                   BODY OF THE PROGRAM                                        #
################################################################################################

write_log "Starting backup process"
while [[ $# -gt 0 ]]
do
  case $1 in
    -b|--backup)
      DIRS_TO_BACKUP=()
      EXCLUDE_FIES=()
      read_dirs_to_backup
      read_files_to_exclude
      
      output_packages_environments
      
      write_log "Starting copying files"
      count_backup_files
      
      read -rsp "Enter password for repos:   " MINE_PASSW

      write_log "Entering loop to read directories"

      while IFS= read -r repo_dir || [[ -n "$repo_dir" ]]
      do

        make_restic_backup "$repo_dir" "$MINE_PASSW"
        make_borg_backup "$repo_dir" "$MINE_PASSW"

      done < repository_dir.txt

      clean_files

      write_log "Backup done"
      shift
      ;;
    
    -i|--init)
      read -rp "Enter password for Borg repository:   " "${BORG_PASSW:-}"
      
      while read repo_dir
        do
    
          init_borg_repo "$repo_dir" "$BORG_PASSW"
          init_restic_repo "$repo_dir" "$RESTIC_PASSW"

      done < repository_dir.txt

      shift
      ;;
    
    -e|--export)
      export_borg_keys
      export_restic_keys
      shift
      ;;

    -*)
      echo "Unknown option $1"
      exit 1
      ;;

  esac
done

exit 0
