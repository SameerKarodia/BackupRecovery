#!/bin/bash
integrity_file_location=/home/$USER/backup_integrities.md5 #location where logs of backup integrities is stored
backups_file_location=/home/$USER/backups.log #location where backup configurations is stored

#option flags
backup=false
compress=false
encrypt=false
restore=false
verify=false
retention=false
retention_days=0
automate=false
delete=false

#error function 
function error() {
    echo "Error: $1" >&2
    exit 1
}

#takes source directory as $1, destination directory as $2
function backupWithoutCompression { #creates a .tar file in destination directory
	tar -cf ${2}.tar $1 #create archive of source directory in destination directory
}

function backupWithCompression { #creates a .tar.gz file in destination directory
	tar -czf ${2}.tar.gz $1 #compress directory with gzip and move it to dest_directory
}

function encryptDirectory { #creates either a .tar.gpg file (uncompressed) or .tar.gz.gpg file (compressed) in destination directory
	gpg -c $1 #encrypts dest_directory
	rm $1 #delete unencrypted directory
}

function decryptDirectory {
	decrypted_file=$1
	decrypted_file=${decrypted_file%.*}
	echo $decrypted_file
	if [[ $1 =~ ".gz" ]]; then
		gpg --output $decrypted_file --decrypt $1 #decrypts compressed, encrypted backup and sends it to ${source_directory}.tar
	else	
		gpg --output $decrypted_file --decrypt $1 #decrypts uncompressed, encrypted backup and sends it to ${source_directory}.tar.gz
	fi
	
	rm $1 #remove encrypted backup
}

function restoreBackup { #takes destination_directory, checks if it is in log and its source_directory, then copies it over
	while IFS='' read -r line; do
		if [[ $line == "$1",* ]]; then #if it is, find the line where it is and replace the line
			dest="$(echo $line | grep -o '.*,' | tr -d ',')"
			source="$(echo "$line" | grep -oP ',\K.*')"

			if [[ $line =~ ".gpg" ]]; then #check if directory is encrypted
				decryptDirectory $source
				source="${source%.*}" #removes .gpg extension
			fi

			if [[ $source =~ ".gz" ]]; then #check if directory had been compressed
				tar -xzf $source $dest
			else
				tar -xf $source $dest
			fi
			
			break
		fi
	done < $backups_file_location
}

function logBackup { #logs the source_directory and dest_directory in a file
	integrity_log=($(md5sum ${2}))
	integrity_log="${integrity_log},${2},${1}"
	backup_log="${1},${2}"
	
	if [ ! -s $backups_file_location ]; then #checks if log file is empty
		echo "$integrity_log" >> $integrity_file_location
		echo "$backup_log" >> $backups_file_location #if it is, write source_directory and dest_directory to it and return
		return
	fi
		
	#replace dest_directory if user tries to backup source_directory more than once
	count=1
	while IFS='' read -r line; do #loop through log file to check if file being saved is already in the log
		if [[ $line == "$1",* ]]; then #if it is, find the line where it is and replace the line
			dest="$(echo "$line" | grep -oP ',\K.*')"
			rm $dest
			backup_found=true
			break
		fi
		count=$((count+1))
	done < $backups_file_location
	
	if [[ "$backup_found" = true ]]; then
		sed -i "${count} s|.*|${integrity_log}|" $integrity_file_location
		sed -i "${count} s|.*|${backup_log}|" $backups_file_location
	else
		echo "$integrity_log" >> $integrity_file_location
		echo "$backup_log" >> $backups_file_location #if not, write new backup to log file
	fi
}

function verifyIntegrity {
	count=1
	backup_found=false
	while IFS='' read -r line; do #loop through log file to check if file being saved is already in the log
		if [[ $line == *,"$1" ]]; then
			source="$(echo $line | cut -d"," -f2)"
			checksum="$(echo $line | cut -d"," -f1)"
			backup_found=true
			break
		fi
		count=$((count+1))
	done < $integrity_file_location
	
	if [[ "$backup_found" = true ]]; then
		if [[ $checksum == $(md5sum $source | cut -d" " -f1) ]]; then
			echo "No issues detected"
		else
			echo "Checksums are different. Data may be corrupted."
		fi
	else
		echo "Backup not found."
	fi
}

function enforceRetention {
    # if retention is not enabled or days <= 0, do nothing
    if [[ "$retention" = false || "$retention_days" -le 0 ]]; then
        return
    fi

    # if there is no log yet, nothing to do
    if [ ! -f "$backups_file_location" ] || [ ! -f "$integrity_file_location" ]; then
        return
    fi

    tmp_backups=$(mktemp)
    tmp_integrities=$(mktemp)

    now=$(date +%s)

    # read backups.log and backup_integrities.md5 in parallel
    while IFS='' read -r backup_line && IFS='' read -r integrity_line <&3; do
        dest="$(echo "$backup_line" | grep -oP ',\K.*')"

        # if file exists, check age; if not, just drop the entry
        if [ -f "$dest" ]; then
            # try GNU stat, then BSD/macOS stat
            file_mtime=$(stat -c %Y "$dest" 2>/dev/null || stat -f %m "$dest" 2>/dev/null)
            if [ -n "$file_mtime" ]; then
                age_days=$(( (now - file_mtime) / 86400 ))
                if [ "$age_days" -gt "$retention_days" ]; then
                    # delete old backup and skip writing it back to logs
                    rm -f "$dest"
                    continue
                fi
            fi
            # still valid: keep in logs
            echo "$backup_line" >> "$tmp_backups"
            echo "$integrity_line" >> "$tmp_integrities"
        fi
        # if dest does not exist, silently drop the entry from logs
    done < "$backups_file_location" 3<"$integrity_file_location"

    mv "$tmp_backups" "$backups_file_location"
    mv "$tmp_integrities" "$integrity_file_location"
}

function deleteBackup {
	count=1
	while IFS='' read -r line; do
		if [[ $line == "$1",* ]]; then #if it is, find the line where it is and replace the line
			dest="$(echo $line | grep -o '.*,' | tr -d ',')"
			source="$(echo "$line" | grep -oP ',\K.*')"

			if [[ $line =~ ".gpg" ]]; then #check if directory is encrypted
				decryptDirectory $source
				source="${source%.*}" #removes .gpg extension
			fi

			if [[ $source =~ ".gz" ]]; then #check if directory had been compressed
				tar -xzf $source $dest
			else
				tar -xf $source $dest
			fi
			
			rm $source #remove backup
			backup_found=true
			break
		fi
		count=$((count+1)) #track which line to delete
	done < $backups_file_location
	
	if [[ "$backup_found" = true ]]; then #if backup is found, delete it from log files
		sed -i "${count}d" $integrity_file_location
		sed -i "${count}d" $backups_file_location
		crontab -l | grep -v ".*$1.*"  | crontab - #delete cronjob from crontab
	fi
}

function addCronjob {
	error_flag=false
	
	line="$@" #get entire command line
	schedule="$(echo "$line" | grep -o "\-a.*" | tr -d "\-a" | sed 's/^ *//')" #get everything after -a, which is the schedule for the cronjob
	command="$(echo "$line" | grep -o ".*\-a" | sed 's/-a//')" #get everything before -a, which is the command to be executed
	
	minute="$(echo "$schedule" | cut -d" " -f1)"
	if [[ "$minute" =~ ^[0-9]+$ ]]; then #check if minute is a number
		if [[ "$minute" < 0 || "$minute" > 60 ]]; then
			echo "Invalid minute! It must be a number between 1 and 59"
			error_flag=true
		fi
	elif [[ "$minute" != "*" ]]; then #check if minute is a *
		echo "Input must be a number or *!"
		error_flag=true
	fi
	
	hour="$(echo "$schedule" | cut -d" " -f2)"
	if [[ "$hour" =~ ^[0-9]+$ ]]; then
		if [[ "$hour" < 0 || "$hour" > 24 ]]; then
			echo "Invalid hour! It must be a number between 0 and 23"
			error_flag=true
		fi
	elif [[ "$hour" != "*" ]]; then
		echo "Input must be a number or *!"
		error_flag=true
	fi
	
	day_of_month="$(echo "$schedule" | cut -d" " -f3)"
	if [[ "$day_of_month" =~ ^[0-9]+$ ]]; then
		if [[ "$day_of_month" < 1 || "$day_of_month" > 31 ]]; then
			echo "Invalid day of month! It must be a number between 1 and 31."
			error_flag=true
		fi
	elif [[ "$day_of_month" != "*" ]]; then
		echo "Input must be a number or *!"
		error_flag=true
	fi
	
	month="$(echo "$schedule" | cut -d" " -f4)"
	if [[ "$month" =~ ^[0-9]+$ ]]; then
		if [[ "$month" < 1 || "$month" > 12 ]]; then
			echo "Invalid month! It must be a number between 1 and 12."
			error_flag=true
		fi
	elif [[ "$month" != "*" ]]; then
		echo "Input must be a number or *!"
		error_flag=true
	fi
	
	day_of_week="$(echo "$schedule" | cut -d" " -f5)"
	if [[ "$day_of_week" =~ ^[0-9]+$ ]]; then
		if [[ "$day_of_week" < 0 || "$day_of_week" > 7 ]]; then
			echo "Invalid day of the week! It must be a number between 0 and 7."
			error_flag=true
		fi
	elif [[ "$day_of_week" != "*" ]]; then
		echo "Input must be a number or *!"
		error_flag=true
	fi
	
	if [[ "$error_flag" = true ]]; then
		error "Invalid argument(s)."
	fi
	
	new_cronjob=(""$minute" "$hour" "$day_of_month" "$month" "$day_of_week"") #create cronjob string
	new_cronjob+=" bash backup.sh"
	new_cronjob+=" $command"
	(crontab -l ; echo "$new_cronjob") | sort - | uniq - | crontab - #create new cronjob
}

function checkDependencies() {
    for cmd in tar gpg md5sum stat sed; do
        command -v "$cmd" >/dev/null 2>&1 || error "Required command '$cmd' not found in PATH."
    done
}
#check for dependency issues or errors
checkDependencies

while getopts "b:cer:v:k:a:d:h" opt; do
	
	case $opt in
	b ) arguments=("$OPTARG") #getopts doesn't support multiple arguments per option, so have to do this
		until [[ $(eval "echo \${$OPTIND}") =~ ^-.* ]] || [ -z $(eval "echo \${$OPTIND}") ]; do
                arguments+=($(eval "echo \${$OPTIND}"))
                OPTIND=$((OPTIND + 1))
		done
		
		source_directory=${arguments[0]}
		dest_directory=${arguments[1]}
		
		backup=true ;;
		
	c ) compress=true ;;
		
	e ) encrypt=true ;;
		
	r ) source_directory=$OPTARG
		restore=true ;;
		
	v ) source_directory=$OPTARG
		verify=true ;;
	
	k)  retention=true
		retention_days=$OPTARG ;;
		
	a ) automate=true ;;
	
	d ) source_directory=$OPTARG
		delete=true ;;
	
	h ) echo "Options: -b (create a backup), -c (compress backup), -e (encrypt backup), -r (restore backup), -v (verify integrity), -k <days> (retention policy: keep backups for N days), -a (automate backups), -d (delete a backup)."
		echo "To backup a directory: backup.sh -b path/source_directory path/destination_directory."
		echo "When using -b, -c and/or -e can be added to compress and/or encrypt the backup."
		echo "To restore a backup: backup.sh -r path/source_directory, where source_directory is the same source_directory that was used to create the backup."
		echo "To delete a backup: backup.sh -d path/source_directory, where source_directory is the same source_directory that was used to create the backup. This will also delete the backup from the crontab file (if applicable) and backup and integrity logs."
		echo "To verify the integrity of a backup: backup.sh -v path/source_directory, where source_directory is the same source_directory that was used to create the backup."
		echo "To apply a retention policy, add -k <days> when creating a backup. Any backups older than <days> will be deleted and removed from the logs."
		echo "To automate a backup, use -a at the end of the command (it must be the last option) ensure that the times are encapsulated by double quotation marks in the format (each number can be substituted with a *): minutes (0-59) hour (0-23) day of month (1-31) month (1-12) day of week (0-7)."
		echo "When a backup is created, this script will create a log file in this directory: /home/$USER/backups.log. This file is used to track which options were used to create the backup so the script can appropriately uncompress and/or decrypt the backup before restoration."
		echo "An .md5 file is also created in this directory: /home/$USER/backup_integrities.md5. This file is used to track each backup's md5 checksum, calculated immediately after each backup is created, to compare with the backup's current md5 checksum. Entries in the file are removed once the respective backup is deleted."
		exit 0 ;;
		
	* ) echo "Invalid option(s)!" 
		exit 1 
	esac
done

#Error Handling Below
#Ensure at least one main action is chosen
if [[ "$backup" != true && "$restore" != true && "$verify" != true && "$delete" != true ]]; then
    error "No action specified. Use -b (backup), -r (restore), -v (verify), or -d (delete). Use -h for help."
fi

#Validate backup mode arguments
if [[ "$backup" = true ]]; then
    # Must have a source and destination base
    [ -n "$source_directory" ] || error "No source directory provided for backup (-b)."
    [ -n "$dest_directory" ]   || error "No destination base path provided for backup (-b)."

    # Source directory must exist
    [ -d "$source_directory" ] || error "Source directory '$source_directory' does not exist."

    # Parent directory of destination must exist
    dest_parent=$(dirname "$dest_directory")
    [ -d "$dest_parent" ] || error "Destination directory '$dest_parent' does not exist."
fi

#Validate restore mode arguments
if [[ "$restore" = true ]]; then
    [ -n "$source_directory" ] || error "Please provide the original source directory with -r."
    [ -f "$backups_file_location" ] || error "Backups log '$backups_file_location' not found. Nothing to restore."
    [ -f "$integrity_file_location" ] || error "Integrity log '$integrity_file_location' not found. Cannot safely restore."
fi

#Validate verify mode arguments
if [[ "$verify" = true ]]; then
    [ -n "$source_directory" ] || error "Please provide the original source directory with -v."
    [ -f "$integrity_file_location" ] || error "Integrity log '$integrity_file_location' not found. Cannot verify backups."
fi

if [[ "$delete" = true ]]; then
    [ -n "$source_directory" ] || error "Please provide the original source directory with -d."
	[ -f "$backups_file_location" ] || error "Backups log '$backups_file_location' not found. Nothing to restore."
    [ -f "$integrity_file_location" ] || error "Integrity log '$integrity_file_location' not found."
fi

#Validate retention (-k) argument if used
if [[ "$retention" = true ]]; then
    [[ "$retention_days" =~ ^[0-9]+$ ]] || error "Retention days (-k) must be a non-negative integer."
fi

#check if options are valid
if [[ "$backup" = true && ( "$verify" = true || "$restore" = true ) ]]; then
	echo "Cannot backup and verify/restore at the same time."
	exit 1

elif [[ "$backup" = true && "$compress" = false && "$encrypt" = false ]]; then #backup without compression
	backupWithoutCompression $source_directory $dest_directory
	logBackup $source_directory ${dest_directory}.tar
	enforceRetention
	
	if [[ "$automate" = true ]]; then
		addCronjob "$@"
	fi

elif [[ "$backup" = true && "$compress" = true && "$encrypt" = false ]]; then #backup with compression	
	backupWithCompression $source_directory $dest_directory
	logBackup $source_directory ${dest_directory}.tar.gz
	enforceRetention
	
	if [[ "$automate" = true ]]; then
		addCronjob "$@"
	fi
	
elif [[ "$backup" = true && "$encrypt" = true ]]; then
	if [[ "$compress" = false ]]; then #encrypt uncompressed backup
		backupWithoutCompression $source_directory $dest_directory
		encryptDirectory ${dest_directory}.tar
		logBackup $source_directory ${dest_directory}.tar.gpg
		enforceRetention

	elif [[ "$compress" = true ]]; then #encrypt compressed backup
		backupWithCompression $source_directory $dest_directory
		encryptDirectory ${dest_directory}.tar.gz
		logBackup $source_directory ${dest_directory}.tar.gz.gpg
		enforceRetention
	fi
	
	if [[ "$automate" = true ]]; then
		addCronjob "$@"
	fi
	
elif [[ "$restore" = true ]]; then
	restoreBackup $source_directory
	
elif [[ "$verify" = true ]]; then
	verifyIntegrity $source_directory
	
elif [[ "$delete" = true ]]; then
	deleteBackup $source_directory
	
fi