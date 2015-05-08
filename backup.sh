#!/bin/bash
#set -x

# main configuration
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
config_file="$script_dir/main.cfg"
# timestamps yyyy-mm-dd and unixtime for calculating
backup_stamp=$(date +%F)
backup_time=$(date -d$backup_stamp +%s)
# check if it is the first of the month to do monthly backups
backup_month="no"
if [ "$(echo $backup_stamp | cut -d- -f3)" = "01" ]
then
   backup_month="yes"
fi

# source a specified section from a specified config
function source_section {
   config_name="$1"
   section_name="$2"
   section_start="^\[$section_name\]$"
   section_end="^\[/$section_name\]$"

   line_start=$(grep -n "$section_start" "$config_name" | cut -d: -f1)
   line_end=$(expr $(grep -n "$section_end" "$config_name" | cut -d: -f1) - 1)
   line_diff=$(expr $line_end - $line_start)

   tmp_file=$(mktemp)
   head -n $line_end "$config_name" | tail -n $line_diff > "$tmp_file"
   source "$tmp_file"
   rm -f "$tmp_file"
}

# copy file with rsync to server and save last timestamp to logfile
function rsync_server {
   filefrom="$1"
   dirto="$2"
   logfileentry="$3"
   #nice -n 19 rsync -rle "ssh -i $keyfile" "$filefrom" "$userserver:$dirto"
   # limit the bandwith
   nice -n 19 rsync --bwlimit=100000 -rle "ssh -i $keyfile" "$filefrom" "$userserver:$dirto"
   ret=$?
   if [ $ret -ne 0 ]
   then
      echo "problem in rsync: $filefrom"
   fi
   echo "$filefrom" | grep ".month." > /dev/null 2>&1
   ret2=$?
   # on monthly backups and connection errors there should be no update of logfile
   if [ $ret2 -ne 0 -a $ret -eq 0 ]
   then
      sed -e "s/^$logfileentry .*$/${logfileentry} $backup_time/" "$logfile" > "$logfile.tmp"
      mv -f "$logfile.tmp" "$logfile"
   fi
}

# general section from main config
source_section "$config_file" "general"

# handle all specified configs
for config_single in $configs
do
   # does the configuration file exists?
   config_act="$confdir/$config_single"
   if [ -e "$config_act" ]
   then
      # general section from specific config
      source_section "$config_act" "general"
      # change folder for backup
      pushd "$rootdir" > /dev/null
      # handle all specified folders
      for dir_single in $dirssingle
      do
         # check if folder exists
         if [ -e "$dir_single" ]
         then
            # section for specified folder
            source_section "$config_act" "$dir_single"
            # rotate is done through days, so we have to know the interval in sections
            rotate_stamp=$(expr $time \* 24 \* 60 \* 60)
            # for new configurations that does not have a last timestamp we create a zero one
            grep "^${config_single}_$dir_single " $logfile > /dev/null 2>&1
            if [ $? -ne 0 ]
            then
               echo "${config_single}_$dir_single 0" >> $logfile
            fi
            # add /. to directory for also backing up softlinks
            dir_single_soft_link_path="$dir_single/."
            # get the stamp for the last backup
            last_stamp=$(grep "^${config_single}_$dir_single " $logfile | cut -d" " -f2)
            # get the stamp for the next backup
            now_stamp=$(expr $last_stamp + $rotate_stamp)
            do_backup="no"
            do_monthly="no"
            do_normal="no"
            # check wether it is time to do a backup by time and also month
            if [ $now_stamp -le $backup_time ]
            then
               do_backup="yes"
               if [ "$rotate" != "inc" ]
               then
                  do_normal="yes"
               fi
            fi
            if [ "$backup_month" = "yes" -a "$monthly" = "yes" ]
            then
               do_backup="yes"
               do_monthly="yes"
            fi
            # now we are sure to do a backup
            if [ "$do_backup" = "yes" ]
            then
               # we want an incremental backup since last one
               if [ "$rotate" = "inc" ]
               then
                  # tar is not able to handle unix-timestamps, so we calculate the required one
                  tar_stamp=$(date -d "1970-01-01 $last_stamp sec" +%F)
                  # only changed files since last modification in backup
                  if [ -f "$dir_single_soft_link_path/backup.ignore" ]
                  then
                     nice -n 19 tar czf "$dir_single.$backup_stamp.tar.gz" --warning=none --exclude-from="$dir_single_soft_link_path/backup.ignore" -N "$tar_stamp" "$dir_single_soft_link_path"
                  else
                     nice -n 19 tar czf "$dir_single.$backup_stamp.tar.gz" --warning=none -N "$tar_stamp" "$dir_single_soft_link_path"
                  fi
                  rsync_server "$dir_single.$backup_stamp.tar.gz" "$backupdir/$backupdirsingle/" "${config_single}_$dir_single"
                  # delete backups from local
                  rm -f "$dir_single.$backup_stamp.tar.gz"
               fi # if [ "$rotate" = "inc" ]
               # we want a full backup
               if [ "$do_monthly" = "yes" -o "$do_normal" = "yes" ]
               then
                  # backup everything
                  if [ -f "$dir_single_soft_link_path/backup.ignore" ]
                  then
                     nice -n 19 tar czf "$dir_single.tar.gz" --warning=none --exclude-from="$dir_single_soft_link_path/backup.ignore" "$dir_single_soft_link_path"
                  else
                     nice -n 19 tar czf "$dir_single.tar.gz" --warning=none "$dir_single_soft_link_path"
                  fi
                  # check wether we should rotate
                  if [ "$rotate" != "inc" -a "$do_normal" = "yes" ]
                  then

                     # mount for renaming
                     sshfs $userserver:$backupdir $backupdir_local -o IdentityFile=$keyfile -o IdentitiesOnly=yes

                     # rotate old backups
                     for count in `seq $rotate -1 2`
                     do
                        count_last=$(expr $count - 1)
                        rm -f "$backupdir_local/$backupdirsingle/$dir_single.tar.gz.$count"
                        mv -f "$backupdir_local/$backupdirsingle/$dir_single.tar.gz.$count_last" "$backupdir_local/$backupdirsingle/$dir_single.tar.gz.$count" > /dev/null 2>&1
                     done
                     rm -f "$backupdir_local/$backupdirsingle/$dir_single.tar.gz.1"
                     mv -f "$backupdir_local/$backupdirsingle/$dir_single.tar.gz" "$backupdir_local/$backupdirsingle/$dir_single.tar.gz.1" > /dev/null 2>&1

                     # unmount
                     umount $backupdir_local

                  fi # if [ "$rotate" != "inc" -a "$do_normal" = "yes" ]
                  # copy new backups
                  if [ "$do_normal" = "yes" ]
                  then
                     rsync_server "$dir_single.tar.gz" "$backupdir/$backupdirsingle/" "${config_single}_$dir_single"
                  fi
                  if [ "$do_monthly" = "yes" ]
                  then
                     #TODO: check why move sometimes causes problems
                     nice -n 19 cp "$dir_single.tar.gz" "$dir_single.$backup_stamp.month.tar.gz"
                     rsync_server "$dir_single.$backup_stamp.month.tar.gz" "$backupdir/$backupdirsingle/" "${config_single}_$dir_single"
                  fi
                  # delete backups from local
                  rm -f "$dir_single.$backup_stamp.month.tar.gz"
                  rm -f "$dir_single.tar.gz"
               fi # if [ "$do_monthly" = "yes" -o "$do_normal" = "yes" ]
            fi # if [ "$do_backup" = "yes" ]
         fi # if [ -e "$dir_single" ]
      done # for dir_single in $dirssingle
      # go back
      popd > /dev/null
   fi # if [ -e "$config_act" ]
done # for config_single in $configs
