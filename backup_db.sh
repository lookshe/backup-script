#!/bin/bash
#set -x

# get path to all needed tools
# /bin
echo=$(which echo)
grep=$(which grep)
mktemp=$(which mktemp)
pwd=$(which pwd)
rm=$(which rm)
# /usr/bin
cut=$(which cut)
dirname=$(which dirname)
expr=$(which expr)
head=$(which head)
mysql=$(which mysql)
mysqldump=$(which mysqldump)
nice=$(which nice)
ssh=$(which ssh)
tail=$(which tail)

# check if all needed tools are installed (only the ones not installed under /bin/)
alltoolsinstalled="yes"
test "$cut" = "" && echo "'cut' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$dirname" = "" && echo "'dirname' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$expr" = "" && echo "'expr' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$head" = "" && echo "'head' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$mysql" = "" && echo "'mysql' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$mysqldump" = "" && echo "'mysqldump' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$nice" = "" && echo "'nice' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$ssh" = "" && echo "'ssh' not installed or not found by 'which'" && alltoolsinstalled="no"
test "$tail" = "" && echo "'tail' not installed or not found by 'which'" && alltoolsinstalled="no"

if [ "$alltoolsinstalled" = "no" ]
then
   exit 1
fi

# main configuration
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
config_file="$script_dir/main.cfg"

# remote and local directories
db_dir="$script_dir/db"
usesamerepo="no"
backupdirsingle=db

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
   ret=0
   if [ "$usesamerepo" = "yes" ]
   then
      repo_path="$userserver:$backupdir/$serverdir"
   else
      repo_path="$userserver:$backupdir/$serverdir/$repo"
   fi
   #check if repo exists
   $nice $borg_local_path list "$repo_path" > /dev/null 2>&1
   if [ $? -ne 0 ]
   then
      # create repo if not exists
      $nice $borg_local_path init --encryption "$borg_encryption" "$repo_path"
      if [ $? -ne 0 ]
      then
         $echo "problem in borg init $repo"
         ret=1
      fi
   fi
   return $ret
}

# backup single dir with borg
function backup_db {
   repo="$1"
   serverdir="$2"
   usesamerepo="$3"
   check_borg_repo "$repo" "$serverdir" "$usesamerepo"
   if [ $? -ne 0 ]
   then
      return 1
   fi
   # to get backup.ignore work with relative paths we need to change the directory
   if [ "$usesamerepo" = "yes" ]
   then
      repo_path="$userserver:$backupdir/$serverdir::$repo-{now:$default_timestamp}"
   else
      repo_path="$userserver:$backupdir/$serverdir/$repo::{now:$default_timestamp}"
   fi
   ret=0
   $nice $borg_local_path create --one-file-system --compression "$borg_compression" "$repo_path" .
   ret=$?
   if [ $ret -ne 0 ]
   then
      $echo "problem in borg create $repo"
   fi
}

# general section from main config
source_section "$config_file" "general"

# change folder for temporary storage
cd "$db_dir"

# get all databases
databases=$($nice -n 19 $mysql -u root -N -e "show databases;" | $grep -v "^information_schema$" | $grep -v "^mysql$" | $grep -v "^performance_schema$")

# handle each database
for database in $databases
do
   # dump database
   $nice -n 19 $mysqldump --default-character-set=utf8mb4 -u root "$database" > "$database.sql"

   backup_db "$database" "$backupdirsingle" "$usesamerepo"

   # delete temporary file
   $rm -f "$database.sql"
done # for database in $databases
