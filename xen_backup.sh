#!/bin/sh
#
#   Copyright John Quinn, 2008
#   Copyright Anton Valqkoff, 2010
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see .

#
# xenBackup - Backup Xen Domains
#
#             Version:    1.0:     Created:  John D Quinn, http://www.johnandcailin.com/john
#             Version:    1.1:     Added file/lvm recognition. lvm snapshot:  Anton Valqkoff, http://blog.valqk.com/
#

# initialize our variables
domains="null"                           # the list of domains to backup
allDomains="null"                        # backup all domains?
targetLocation="/root/backup/"           # the default backup target directory
mountPoint="/mnt/xen"                    # the mount point to use to mount disk areas
shutdownDomains=false                    # don't shutdown domains by default
quiet=false                              # keep the chatter down
backupEngine=tar                         # the default backup engine
useSnapshot=true                         # create snampshot of the lvm and use it as backup mount.
rsyncExe=/usr/bin/rsync                  # rsync executable
rdiffbackupExe=/usr/bin/rdiff-backup     # rdiff-backup executable
tarExe=/bin/tar                          # tar executable
xmExe=/usr/sbin/xm                       # xm executable
lvmExe=/sbin/lvm
mountExe=/bin/mount
grepExe=/bin/grep
awkExe=/usr/bin/awk
umountExe=/bin/umount
cutExe=/usr/bin/cut
egrepExe=/bin/egrep
purgeAge="null"                          # age at which to purge increments
globalBackupResult=0                     # success status of overall job
#valqk: xm list --long ns.hostit.biz|grep -A 3 device|grep vbd -A 2|grep uname|grep -v swap|awk '{print $2}'

# settings for logging (syslog)
loggerArgs=""                            # what extra arguments to the logger to use
loggerTag="xenBackup"                    # the tag for our log statements
loggerFacility="local3"                  # the syslog facility to log to

# trap user exit and cleanup
trap 'cleanup;exit 1' 1 2

cleanup()
{
   ${logDebug} "Cleaning up"
   #check if file or lvm.if lvm and -snap remove it.
   mountType=`${mountExe}|${grepExe} ${mountPoint}|${awkExe} '{print $1}'`;
   [ -f ${mountType} ] && mountType="file";
   cd / ; ${umountExe} ${mountPoint}
   if [ "${mountType}" != "file" ] && [ "${useSnapshot}" = "true" ]; then
      #let's make sure we are removing snapshot!
      if [ `${mountExe}|${grepExe} -snap|wc -l` -gt 0 ]; then
         ${lvmExe} lvremove -f ${mountType}
      fi
   fi


   # restart the domain
   if test ${shutdownDomains} = "true"
   then
      ${logDebug} "Restarting domain"
      ${xmExe} create ${domain}.cfg > /dev/null
   fi
}

# function to print a usage message and bail
usageAndBail() {
   cat << EOT
Usage: xenBackup [OPTION]...
Backup xen domains to a target area. different backup engines may be specified to
produce a tarfile, an exact mirror of the disk area or a mirror with incremental backup.

   -d      backup only the specified DOMAINs (comma seperated list)
   -t      target LOCATION for the backup e.g. /tmp or root@www.example.com:/tmp
           (not used for tar engine)
   -a      backup all domains
   -s      shutdown domains before backup (and restart them afterwards)
   -q      run in quiet mode, output still goes to syslog
   -e      backup ENGINE to use, either tar, rsync or rdiff
   -p      purge increments older than TIME_SPEC. this option only applies
           to rdiff, e.g. 3W for 3 weeks. see "man rdiff-backup" for
           more information

Example 1
   Backup all domains to the /tmp directgory
   $ xenBackup -a -t /tmp

Example 2
   Backup domain: "wiki" using rsync to directory /var/xenImages on machine backupServer,
   $ xenBackup -e rsync -d wiki -t root@backupServer:/var/xenImages

Example 3
   Backup domains "domainOne" and "domainTwo" using rdiff purging old increments older than 5 days
   $ xenBackup -e rdiff -d "domainOne, domainTwo" -p 5D

EOT

   exit 1;
}

# parse the command line arguments
while getopts p:e:qsad:t:h o
do     case "$o" in
        q)     quiet="true";;
        s)     shutdownDomains="true";;
        a)     allDomains="true";;
        d)     domains="$OPTARG";;
        t)     targetLocation="$OPTARG";;
        e)     backupEngine="$OPTARG";;
        p)     purgeAge="$OPTARG";;
        h)     usageAndBail;;
        [?])   usageAndBail
       esac
done

# if quiet don't output logging to standard error
if test ${quiet} = "false"
then
   loggerArgs="-s"
fi

# setup logging subsystem. using syslog via logger
logCritical="logger -t ${loggerTag} ${loggerArgs} -p ${loggerFacility}.crit"
logWarning="logger -t ${loggerTag} ${loggerArgs} -p ${loggerFacility}.warning"
logDebug="logger -t ${loggerTag} ${loggerArgs} -p ${loggerFacility}.debug"

# make sure only root can run our script
test $(id -u) = 0 || { ${logCritical} "This script must be run as root"; exit 1; }

# make sure that the guest manager is available
test -x ${xmExe} || { ${logCritical} "xen guest manager (${xmExe}) not found"; exit 1; }

# assemble the list of domains to backup
if test ${allDomains} = "true"
then
   domainList=`${xmExe} list | cut -f1 -d" " | egrep -v "Name|Domain-0"`
else
   # make sure we've got some domains specified
   if test "${domains}" = "null"
   then
      usageAndBail
   fi

   # create the domain list by mapping commas to spaces
   domainList=`echo ${domains} | tr -d " " | tr , " "`
fi

# function to do a "rdiff-backup" of domain
backupDomainUsingrdiff() {
   domain=$1
   test -x ${rdiffbackupExe} || { ${logCritical} "rdiff-backup executable (${rdiffbackupExe}) not found"; exit 1; }

   if test ${quiet} = "false"
   then
      verbosity="3"
   else
      verbosity="0"
   fi

   targetSubDir=${targetLocation}/${domain}.rdiff-backup.mirror

   # make the targetSubDir if it doesn't already exist
   mkdir ${targetSubDir} > /dev/null 2>&1
   ${logDebug} "backing up domain ${domain} to ${targetSubDir} using rdiff-backup"

   # rdiff-backup to the target directory
   ${rdiffbackupExe} --verbosity ${verbosity} ${mountPoint}/ ${targetSubDir}
   backupResult=$?

   # purge old increments
   if test ${purgeAge} != "null"
   then
      # purge old increments
      ${logDebug} "purging increments older than ${purgeAge} from ${targetSubDir}"
      ${rdiffbackupExe} --verbosity ${verbosity} --force --remove-older-than ${purgeAge} ${targetSubDir}
   fi

   return ${backupResult}
}

# function to do a "rsync" backup of domain
backupDomainUsingrsync() {
   domain=$1
   test -x ${rsyncExe} || { ${logCritical} "rsync executable (${rsyncExe}) not found"; exit 1; }

   targetSubDir=${targetLocation}/${domain}.rsync.mirror

   # make the targetSubDir if it doesn't already exist
   mkdir ${targetSubDir} > /dev/null 2>&1
   ${logDebug} "backing up domain ${domain} to ${targetSubDir} using rsync"

   # rsync to the target directory
   ${rsyncExe} -essh -avz --delete ${mountPoint}/ ${targetSubDir}
   backupResult=$?

   return ${backupResult}
}

# function to a "tar" backup of domain
backupDomainUsingtar ()
{
   domain=$1

   # make sure we can write to the target directory
   test -w ${targetLocation} || { ${logCritical} "target directory (${targetLocation}) is not writeable"; exit 1; }

   targetFile=${targetLocation}/${domain}.`date '+%d.%m.%Y'`.$$.tar.gz
   ${logDebug} "backing up domain ${domain} to ${targetFile} using tar"

   # tar to the target directory
   cd ${mountPoint}

   ${tarExe} pcfz ${targetFile} * > /dev/null
   backupResult=$?

   return ${backupResult}
}

# backup the specified domains
for domain in ${domainList}
do
   ${logDebug} "backing up domain: ${domain}"
   [ `${xmExe} list ${domain}|wc -l` -lt 1 ] && { echo "Fatal ERROR!!! ${domain} does not exists or not running! Exiting."; exit 1; }

   # make sure that the domain is shutdown if required
   if test ${shutdownDomains} = "true"
   then
      ${logDebug} "shutting down domain ${domain}"
      ${xmExe} shutdown -w ${domain} > /dev/null
   fi

   # unmount mount point if already mounted
   umount ${mountPoint} > /dev/null 2>&1

   #inspect domain disks per domain. get only -disk or disk.img.
   #if file:// mount the xen disk read-only,umount sfter.
   #if lvm create a snapshot mount/umount/erase it.
   xenDiskStr=`${xmExe} list --long ${domain}|${grepExe} -A 3 device|${grepExe} vbd -A 2|${grepExe} uname|${grepExe} -v swap|${awkExe} '{print $2}'|${egrepExe} 'disk.img|-disk'`
   xenDiskType=`echo ${xenDiskStr}|${cutExe} -f1 -d:`;
   xenDiskDev=`echo ${xenDiskStr}|${cutExe} -f2 -d:|${cutExe} -f1 -d')'`;
   test -r ${xenDiskDev} || { ${logCritical} "xen disk area not readable. are you sure that the domain \"${domain}\" exists?"; exit 1; }
   #valqk: if the domain uses a file.img - mount ro (loop allows mount the file twice. wtf!?)
   if [ "${xenDiskType}" = "file" ]; then
      ${logDebug} "Mounting file://${xenDiskDev} read-only to ${mountPoint}"
      ${mountExe} -oloop ${xenDiskDev} ${mountPoint} || { ${logCritical} "mount failed, does mount point (${mountPoint}) exist?"; exit 1; }
      ${mountExe} -oremount,ro ${mountPoint} || { ${logCritical} "mount failed, does mount point (${mountPoint}) exist?"; exit 1; }
   fi
   if [ "${xenDiskType}" = "phy" ] ; then
      if [ "${useSnapshot}" = "true" ]; then
         vgName=`${lvmExe} lvdisplay -c |${grepExe} ${domain}-disk|${grepExe} disk|${cutExe} -f 2 -d:`;
         lvSize=`${lvmExe} lvdisplay ${xenDiskDev} -c|${cutExe} -f7 -d:`;
         lvSize=$((${lvSize}/2/100*15)); # 15% size of lvm in kilobytes
         ${lvmExe} lvcreate -s -n ${vgName}/${domain}-snap -L ${lvSize}k ${xenDiskDev} || { ${logCritical} "creation of snapshot for ${xenDiskDev} failed. exiting." exit 1; }
         ${mountExe} -r /dev/${vgName}/${domain}-snap ${mountPoint} || { ${logCritical} "mount failed, does mount point (${mountPoint}) exist?"; exit 1; }
      else
         ${mountExe} -r ${xenDiskDev} ${mountPoint}
      fi
   fi

   # do the backup according to the chosen backup engine
   backupDomainUsing${backupEngine} ${domain}

   # make sure that the backup was successful
   if test $? -ne 0
   then
      ${logCritical} "FAILURE: error backing up domain ${domain}"
      globalBackupResult=1
   else
      ${logDebug} "SUCCESS: domain ${domain} backed up"
   fi
     
   # clean up
   cleanup;
done
if test ${globalBackupResult} -eq 0
then
   ${logDebug} "SUCCESS: backup of all domains completed successfully"
else
   ${logCritical} "FAILURE: backup completed with some failures"
fi

exit ${globalBackupResult}

