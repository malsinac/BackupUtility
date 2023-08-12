#!/bin/bash
set -euo pipefail

log_file="$HOME/backup_$(date --iso-8601).log"
exec > >(tee -a "$log_file") 2>&1

# Program that backups data from that computer
# It uses both restic and borgbackup, and it 
# stores all files in the HDD and on 
# the cloud.

# TODO: Check if enough disk space is available for the recovery
# TODO: Create a mount ofption to mount existing repositories

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

  write_log "Backing up with BorgBackup utility"
  local bk_dir="${1}_borg"

  # Giving info about the repository
  write_log "Info about the repository"
  BORG_PASSPHRASE="$2" borg info "$bk_dir"

  # Making the backup
  write_log "Backing up"
  BORG_PASSPHRASE="$2" borg create --verbose --list --stats --progress --show-rc --compression zlib,6 --exclude-caches \
     "$bk_dir"::'{hostname}-{now}' ${DIRS_TO_BACKUP[*]}

  # Pruning to mantain 7 daily, 4 weekly and 6 montly backups
  write_log "Pruning past backups"
  BORG_PASSPHRASE="$2" borg prune --verbose --list --glob-archives '{hostname}-*' --show-rc --keep-daily=7 --keep-weekly=4 \
    --keep-monthly=6 "$bk_dir"

  # Compacting space in the repository
  write_log "Compacting repository"
  BORG_PASSPHRASE="$2" borg compact "$bk_dir" 

  # Checking integrity of the backup
  write_log "Checking integrity of the repository"
  BORG_PASSPHRASE="$2" borg check --verbose "$bk_dir"
}

make_restic_backup() {
  # Restic can be used to backup either on a HHD and the cloud
  # $1 -> restic repo location
  # $2 -> restic password
  
  write_log "Backing up with Restic utility"
  local bk_dir="${1}_restic"

  # Showing existing snapshots
  write_log "Info about the repository"
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose=2 snapshots
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose=2 stats

  # Backing up
  write_log "Backing up"
  RESTIC_PASSWORD="$2" GOMAXPROCS=6 restic -r "$bk_dir" --verbose=2 backup ${DIRS_TO_BACKUP[*]} \
    --exclude-file=exclude_files.txt --exclude-caches --one-file-system
  write_log "Exit status of the backup: $?"

  # Pruning to mantain 7 daily, 4 weekly and 6 montly
  write_log "Pruning and compacting repository"
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose=2 forget --keep-within-daily 7d --keep-within-weekly 1m --keep-within-monthly 6m\
    --prune

  # Checking integrity of the backup
  write_log "Checking integrity of the repository"
  RESTIC_PASSWORD="$2" restic -r "$bk_dir" --verbose=2 check
}

restore_restic_repository(){
  # Restic can be used to backup either on a HHD and the cloud
  # $1 -> restic repo location
  # $2 -> restic password

  write_log "Restoring lastest Restic repository"

  local recovery_dir="$HOME/Recovery"

  if [ ! -d "$recovery_dir" ]
  then
    mkdir -p "$recovery_dir"
  fi

  local bk_dir="${1}_restic"

  RESTIC_PASSWORD="$2" restic -r "$bk_dir" restore latest --target "$recovery_dir"

  TMPDIR_LOC="$(mktemp -d -t)" || write_log "Temporary directory can't be created, exiting without testing integrity of the directory"

  find "$bk_dir" -print > "${TMPDIR_LOC}/restored_integrity_file.txt"

  grep -vxFf "$recovery_dir/integrity_file.txt" "${TMPDIR_LOC}/restored_integrity_file.txt" > "$recovery_dir"/test_integrity1.txt

  diff -aytiEZbwB --suppress-common-lines "$recovery_dir/integrity_file.txt" "${TMPDIR_LOC}/restored_integrity_file.txt" > "$recovery_dir"/test_integrity2.txt

  rm -r "${TMPDIR_LOC}"

  write_log "Restore done at ${recovery_dir}"

}

restore_borg_repository(){
  # Restic can be used to backup either on a HHD and the cloud
  # $1 -> borg repo location
  # $2 -> borg password

  write_log "Restoring lastest BorgBackup repository"

  local recovery_dir="$HOME/Recovery"

  if [ ! -d "$recovery_dir" ]
  then
    mkdir -p "$recovery_dir"
  fi

  local bk_dir="${1}_borg"

  cd "$recovery_dir"

  BORG_PASSPHRASE="$2" borg list "$1"

  read -rsp "Enter name of the lastest borg archive: " borg_last_archive

  BORG_PASSPHRASE="$2" borg --list extract "$1"::"$borg_last_archive"

  TMPDIR_LOC="$(mktemp -d -t)" || write_log "Temporary directory can't be created, exiting without testing integrity of the directory"

  find "$bk_dir" -print > "${TMPDIR_LOC}/restored_integrity_file.txt"

  grep -vxFf "$recovery_dir/integrity_file.txt" "${TMPDIR_LOC}/restored_integrity_file.txt" > "$recovery_dir"/test_integrity1.txt

  diff -aytiEZbwB --suppress-common-lines "$recovery_dir/integrity_file.txt" "${TMPDIR_LOC}/restored_integrity_file.txt" > "$recovery_dir"/test_integrity2.txt

  rm -r "${TMPDIR_LOC}"

  write_log "Restore done at ${recovery_dir}"

}

mount_restic_repository(){
  
  local tmpdir_loc
  tmpdir_loc="$(mktemp -d -t)"

  write_log "Creating a mounting point at ${tmpdir_loc} for the Restic repository"

  RESTIC_PASSWORD="$2" restic -r "$1" mount "${tmpdir_loc}" &
  local pid_restic="$!"

  read -rsp "Hit 'kill' to terminate the process"

  kill -INT $pid_restic

  rm -r "${tmpdir_loc}"

  write_log "Unmount succesfully done"

}

mount_borg_repository(){

  local tmpdir_loc
  tmpdir_loc="$(mktemp -d -t)"

  write_log "Creating a mounting point at ${tmpdir_loc} for the BorgBackup repository"

  BORG_PASSPHRASE="$2" borg mount -o ignore_permissions  "$1" "$tmpdir_loc"

  read -rsp "Hit 'kill' to terminate the process"

  BORG_PASSPHRASE="$2" borg umount "$tmpdir_loc"

  rm -r "$tmpdir_loc"

  write_log "Unmount succesfully done"

}

clean_files() {
  # Cleaning up the generated files
  for env in ${CONDA_ENVS}; do
    rm -f "$HOME/${env}.yml"
  done

  rm -f "$HOME/installed_packgs.dat" 
  rm -f "$HOME/installed_packages_snap.txt"
  rm -f "$HOME/integrity_file.txt"
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

create_integrity_file(){
  write_log "Creating integrity file"

  rm -f "$HOME/integrity_file.txt"

  for dirs in "${DIRS_TO_BACKUP[@]}"
  do
    find "$dirs" -print >> "$HOME/integrity_file.txt"
  done
  DIRS_TO_BACKUP+=( "$HOME/integrity_file.txt" )
}

show_help(){
  echo "./backup_maker.sh: [-b] [-i] [-e] [-r] [-m]"
  echo "  -b: Perform a backup"
  echo "  -i: Initialize a new repository"
  echo "  -e: Export repository keys"
  echo "  -r: Recover from an specific repository"
  echo "  -m: Mount a repository"
}

################################################################################################
#                                   BODY OF THE PROGRAM                                        #
################################################################################################

write_log "Starting backup process"
while [[ $# -gt 0 ]]
do
  case $1 in
    -b|--backup)
      write_log "Selected option: -b"
      DIRS_TO_BACKUP=()
      EXCLUDE_FIES=()

      if [ ! -f dirs_to_backup.txt ]; then
        write_log "Critical file dirs_to_backup.txt not found on current path, exiting"
        exit 1
      fi

      if [ ! -f repository_dir.txt ]; then
        write_log "Critical file repository_dir.txt not found on current path, exiting"
        exit 1
      fi

      if [ ! -f exclude_files.txt ]; then
        write_log "Critical file rexclude_files.txt not found on current path, exiting"
        exit 1
      fi

      read_dirs_to_backup
      read_files_to_exclude
      
      output_packages_environments
      create_integrity_file

      write_log "Starting copying files"
      count_backup_files
      
      read -rsp "Enter password for repos:   " MINE_PASSW

      write_log "Entering loop to read directories"

      while IFS= read -r repo_dir || [[ -n "$repo_dir" ]]
      do
        write_log "Working on repository location ${repo_dir}"
        make_restic_backup "$repo_dir" "$MINE_PASSW"
        make_borg_backup "$repo_dir" "$MINE_PASSW"

      done < repository_dir.txt

      clean_files

      write_log "Backup done"
      shift
      ;;
    
    -i|--init)
      write_log "Selected option: -i"
      read -rsp "Enter password for repos:   " MINE_PASSW
      
      while IFS= read -r repo_dir || [[ -n "$repo_dir" ]]
      do
    
        init_borg_repo "$repo_dir" "$MINE_PASSW"
        init_restic_repo "$repo_dir" "$MINE_PASSW"

      done < repository_dir.txt

      shift
      ;;
    
    -e|--export)
      write_log "Selected option: -e"
      export_borg_keys
      export_restic_keys
      
      shift
      ;;
    
    -r|--recover)
      write_log "Starting recovery process"
      
      read -rsp "Enter password for repos:               " MINE_PASSW
      read -rsp "Enter recovery tool [(r)estic/(b)org]:  " rec_engine
      read -rsp "Enter the repository location:          " repo_dir

      if [[ "$rec_engine" == "r" ]]
      then
        restore_restic_repository "$repo_dir" "$MINE_PASSW"
      
      elif [[ "$rec_engine" == "r" ]]
      then
        restore_borg_repository "$repo_dir" "$MINE_PASSW"

      else
        write_log "Can't be understood the recovery method"

      fi

      shift
      ;;

    -m|--mount)
      write_log "Starting mounting process"

      read -rsp "Enter password for repos:               " MINE_PASSW
      echo ""
      read -rp "Enter recovery tool [(r)estic/(b)org]:  " rec_engine
      echo ""
      read -rp "Enter the repository location:          " repo_dir

      if [[ "$rec_engine" == "r" ]]
      then
        mount_restic_repository "$repo_dir" "$MINE_PASSW"
      
      elif [[ "$rec_engine" == "b" ]]
      then
        mount_borg_repository "$repo_dir" "$MINE_PASSW"

      else
        write_log "Can't be understood the recovery method"

      fi

      shift
      ;;
    
    -h|--help)
      show_help

      shift
      ;;

    -*)
      echo "Unknown option $1"
      exit 1
      ;;

  esac
done

exit 0
