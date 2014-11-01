#!/bin/bash
#set -x

# main configuration
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
config_file="$script_dir/main.cfg"

# remote and local directories
db_dir="$script_dir/db"
backupdirsingle=db

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

# copy file with rsync to server
function rsync_server {
   filefrom="$1"
   dirto="$2"
   #nice -n 19 rsync -rle "ssh -i $keyfile" "$filefrom" "$userserver:$dirto"
   # limit the bandwith
   nice -n 19 rsync --bwlimit=100000 -rle "ssh -i $keyfile" "$filefrom" "$userserver:$dirto"
   ret=$?
   if [ $ret -ne 0 ]
   then
      echo "problem in rsync: $filefrom"
   fi
}

# general section from main config
source_section "$config_file" "general"

# change folder for temporary storage
cd "$db_dir"

# get all databases
databases=$(nice -n 19 mysql -u root -N -e "show databases;" | grep -v "^information_schema$" | grep -v "^mysql$" | grep -v "^performance_schema$")

# handle each database
for database in $databases
do
   # dump and gzip database
   nice -n 19 mysqldump -u root "$database" > "$database.sql"
   nice -n 19 gzip "$database.sql"

   # mount for renaming
   sshfs $userserver:$backupdir $backupdir_local -o IdentityFile=$keyfile -o IdentitiesOnly=yes

   # rotate old backups
   for count in `seq 7 -1 2`
   do
      count_last=$(expr $count - 1)
      rm -f "$backupdir_local/$backupdirsingle/$database.sql.gz.$count"
      mv -f "$backupdir_local/$backupdirsingle/$database.sql.gz.$count_last" "$backupdir_local/$backupdirsingle/$database.sql.gz.$count" > /dev/null 2>&1
   done
   rm -f "$backupdir_local/$backupdirsingle/$database.sql.gz.1"
   mv -f "$backupdir_local/$backupdirsingle/$database.sql.gz" "$backupdir_local/$backupdirsingle/$database.sql.gz.1" > /dev/null 2>&1

   # unmount
   umount $backupdir_local

   rsync_server "$database.sql.gz" "$backupdir/$backupdirsingle/"

   # delete temporary file
   rm -f "$database.sql.gz"
done # for database in $databases
