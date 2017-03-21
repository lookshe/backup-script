#!/bin/bash
#set -x

# get path to all needed tools
# /bin
date=$(which date)
echo=$(which echo)
grep=$(which grep)
mktemp=$(which mktemp)
mv=$(which mv)
pwd=$(which pwd)
rm=$(which rm)
sed=$(which sed)
# /usr/bin
cut=$(which cut)
dirname=$(which dirname)
expr=$(which expr)
head=$(which head)
nice=$(which nice)
ssh=$(which ssh)
tail=$(which tail)

# check if all needed tools are installed (only the ones not installed under /bin/)
alltoolsinstalled="yes"
test "$cut" = "" && echo "'cut' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$dirname" = "" && echo "'dirname' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$expr" = "" && echo "'expr' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$head" = "" && echo "'head' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$nice" = "" && echo "'nice' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$ssh" = "" && echo "'ssh' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$tail" = "" && echo "'tail' not installed or not found by 'which'" && alltoolsinstalled="no"

if [ "$alltoolsinstalled" = "no" ]
then
   exit 1
fi

# main configuration
script_dir="$( cd "$( $dirname "${BASH_SOURCE[0]}" )" && $pwd )"
config_file="$script_dir/main.cfg"
# timestamps yyyy-mm-dd and unixtime for calculating
backup_stamp=$($date +%F)
backup_time=$($date -d$backup_stamp +%s)

# source a specified section from a specified config
function source_section {
   config_name="$1"
   section_name="$2"
   section_start="^\[$section_name\]$"
   section_end="^\[/$section_name\]$"

   line_start=$($grep -n "$section_start" "$config_name" | $cut -d: -f1)
   line_end=$($expr $($grep -n "$section_end" "$config_name" | $cut -d: -f1) - 1)
   line_diff=$($expr $line_end - $line_start)

   tmp_file=$($mktemp)
   $head -n $line_end "$config_name" | $tail -n $line_diff > "$tmp_file"
   source "$tmp_file"
   $rm -f "$tmp_file"
}

# check if borg repo exists and create if not
function check_borg_repo {
   repo="$1"
   serverdir="$2"
   usesamerepo="$3"
   if [ "$usesamerepo" = "yes" ]
   then
      repo_path="$userserver:$backupdir/$serverdir"
   else
      repo_path="$userserver:$backupdir/$serverdir/$repo"
   fi
   #check if repo exists
   $nice $borg_local_path list --remote-path "$borg_remote_path" --no-files-cache "$repo_path" > /dev/null 2>&1
   if [ $? -ne 0 ]
   then
      # create repo if not exists
      $nice $borg_local_path init --remote-path "$borg_remote_path" --encryption "$borg_encryption" "$repo_path"
   fi
}

# backup single dir with borg
function backup_dir {
   repo="$1"
   serverdir="$2"
   logfileentry="$3"
   usesamerepo="$4"
   check_borg_repo "$repo" "$serverdir" "$usesamerepo" 
   # to get backup.ignore work with relative paths we need to change the directory
   pushd "$repo" > /dev/null
   if [ "$usesamerepo" = "yes" ]
   then
      repo_path="$userserver:$backupdir/$serverdir::$repo-{now:$default_timestamp}"
   else
      repo_path="$userserver:$backupdir/$serverdir/$repo::{now:$default_timestamp}"
   fi
   ret=0
   if [ -f "backup.ignore" ]
   then
      $nice $borg_local_path create --remote-path "$borg_remote_path" --one-file-system --exclude-from "backup.ignore" --compression "$borg_compression" "$repo_path" .
      ret=$?
   else
      $nice $borg_local_path create --remote-path "$borg_remote_path" --one-file-system --compression "$borg_compression" "$repo_path" .
      ret=$?
   fi
   popd > /dev/null
   if [ $ret -eq 0 ]
   then
      $sed -e "s/^$logfileentry .*$/${logfileentry} $backup_time/" "$logfile" > "$logfile.tmp"
      $mv -f "$logfile.tmp" "$logfile"
   else
      $echo "problem in borg create $repo"
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
      # reset default settings
      usesamerepo="no"
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
            rotate_stamp=$($expr $time \* 24 \* 60 \* 60)
            # for new configurations that does not have a last timestamp we create a zero one
            $grep "^${config_single}_$dir_single " $logfile > /dev/null 2>&1
            if [ $? -ne 0 ]
            then
               $echo "${config_single}_$dir_single 0" >> $logfile
            fi
            # get the stamp for the last backup
            last_stamp=$($grep "^${config_single}_$dir_single " $logfile | $cut -d" " -f2)
            # get the stamp for the next backup
            now_stamp=$($expr $last_stamp + $rotate_stamp)
            do_backup="no"
            # check wether it is time to do a backup by time and also month
            if [ $now_stamp -le $backup_time ]
            then
               do_backup="yes"
            fi
            # now we are sure to do a backup
            if [ "$do_backup" = "yes" ]
            then
               # backup everything
               backup_dir "$dir_single" "$backupdirsingle" "${config_single}_$dir_single" "$usesamerepo"
            fi # if [ "$do_backup" = "yes" ]
         fi # if [ -e "$dir_single" ]
      done # for dir_single in $dirssingle
      # go back
      popd > /dev/null
   fi # if [ -e "$config_act" ]
done # for config_single in $configs
