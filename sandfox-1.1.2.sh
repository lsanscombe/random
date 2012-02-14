#!/bin/bash
# Script Name: sandfox    http://igurublog.wordpress.com/downloads/script-sandfox/ 
# Requires: inotify-tools
# License: GNU GENERAL PUBLIC LICENSE Version 3 http://www.gnu.org/licenses/gpl-3.0.txt

help ()
{
cat << EOF
sandfox version 1.1.2
Usage: sandfox [OPTIONS] [COMMAND [ARG]...]
Runs COMMAND as a normal user within a chroot jail sandbox with limited
access to the filesystem.  Supports profiles for apps and includes a default
Firefox profile. Must be run as root when creating sandbox.  Examples:  
 sudo sandfox firefox     # Runs Firefox in a sandbox
 sudo sandfox bash        # Shell to explore a sandbox
OPTIONS:
--bindro TARGET           Include TARGET (a file or folder) in the sandbox
                            bind-mounting it as a read-only filesystem
--bind TARGET             Include TARGET (a file or folder) in the sandbox 
                            with same ownership and permissions when possible
--copy TARGET             Place a disposable copy of TARGET (a file or folder)
                            in the sandbox
--hide TARGET             Include TARGET (a file or folder) in the sandbox
                            by bind-mounting an empty file or folder onto it
                            Effectively hides the real TARGET from the sandbox
                            Also provides a writable dummy folder
--profile PROFILE         Load PROFILE (a profile name or pathname).  By 
                            default profiles are stored in $defaultprofolder
--make                    Force creation or update of a sandbox (make is
                            implied if you specify binds or profiles)
--sandbox NAME            Specify name of sandbox to use, create, or update
--close NAME              Unmount and remove sandbox NAME
--closeall                Unmount and remove ALL sandboxes
--status                  Show the status of all current sandboxes
--shell                   Run COMMAND in a shell and wait.  Requires root.
                            (bash is always run in a shell)
--user USERNAME           Run command as USER in the sandbox - useful if
                            auto-detection does not work or to override
--profilefolder FOLDER    Use FOLDER instead of the default profile folder
                            IMPORTANT: should be root owned & write-protected
--logfile LOGFILE         Also append messages to LOGFILE.  sandfox daemons
                            will also update this file provided it is
                            accessible from within the sandbox.
--verbose                 Provide detailed feedback
--quiet                   Minimize output messages
NOTES: OPTIONS must precede COMMAND; you can also use OPTION=VALUE; binds are
processed in this order: bindro bind copy hide; missing binds are ignored; if
a profile for COMMAND exists it will be automatically loaded; default profile
is always loaded; profiles may contain any options valid on the command line;
if COMMAND is omitted, a sandbox will be created for use.
Instructions and updates:
http://igurublog.wordpress.com/downloads/script-sandfox/

EOF
    exit 0
}

log () {
    output=0
    if (( optquiet == 1 )) && [ "$2" = "quiet" ]; then
        output=1
    elif (( optverbose == 1 )) && [ "$2" = "verb" ]; then
        output=1
    elif (( optquiet == 0 )) && [ "$2" != "verb" ]; then
        output=1
    fi
    if (( output == 1 )); then
        if (( optdaemon == 1 )); then
            d="sandfox-daemon($(basename "${watchs[0]}")): "
        else
            d=""
        fi
        echo "$1"
        if [ "$logfile" != "" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): $d$1" >> "$logfile"
        fi
    fi
}

processopt () {   # $1 $2
    # Process a command line or profile option
    opt="$1"
    opt2="$2"
    shifts=2
    if [ "${opt:0:2}" = "--" ]; then
        opt="${opt:2}"
    fi  
    case "$opt" in
        help | -help | -h )
            help
            exit
            ;;
        bind | bindrw | bindro | hide | copy | watch )
            if [ "${opt2:0:1}" != "/" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires an absolute path" "quiet"
                exit 1
            fi
            if [ "$opt" = "bindrw" ]; then
                opt="bind"
            fi
            eval $opt\s[\$$opt\scnt]=\"\$opt2\"
            eval \(\( $opt\scnt += 1 \)\)
            ;;
        profile )
            if [ "${opt2:0:1}" = "-" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires a profile name or file" "quiet"
                exit 1
            fi
            prof[$profcnt]="$opt2"
            (( profcnt += 1 ))
            ;;
        profilefolder )
            if [ "$profolder" != "" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Multiple profile folders not permitted" "quiet"
                exit 1
            elif [ "${opt2:0:1}" != "/" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires an absolute path" "quiet"
                exit 1
            fi
            profolder="$opt2"
            ;;
        sandbox )
            if [ "$sandbox" != "" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Multiple sandbox names not permitted" "quiet"
                exit 1
            fi
            opt2base=`basename "$opt2"`
            if [ "${opt2:0:1}" = "-" ] || [ "$opt2" = "" ] || [ "$opt2" != "$opt2base" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires a sandbox name" "quiet"
                exit 1
            fi
            sandbox="$opt2"
            ;;
        close )
            opt2base=`basename "$opt2"`
            if [ "${opt2:0:1}" = "-" ] || [ "$opt2" = "" ] || [ "$opt2" != "$opt2base" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires a sandbox name" "quiet"
                exit 1
            fi
            closename[$closecnt]="$2"
            (( closecnt += 1 ))
            ;;
        logfile )
            if [ "${opt2:0:1}" != "/" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires an absolute path" "quiet"
                exit 1
            fi
            if [ "$logfile" != "" ]; then
                log "$curprofile: Warning: Multiple log files ignored" "quiet"
            else
                logfile="$opt2"
                if (( optdaemon == 0 )); then
                    echo "=======================================================================" >> "$logfile"
                    echo "sandfox started $(date +%Y-%m-%d' '%H:%M:%S) on $HOSTNAME" >> "$logfile"
                    echo "$logcl" >> "$logfile"
                else
                    log "Started >>> $logcl"
                fi
                chmod go+rw "$logfile" 2> /dev/null
            fi
            ;;
        make | verbose | quiet | keepsand | clean | closeall | status | daemon | shell )
            eval opt$opt=1
            if (( optquiet + optverbose == 2 )); then
                optquiet=0
            fi
            shifts=1
            ;;
        user )
            if [ "${opt2:0:1}" = "-" ]; then
                log "$curprofile: Option $opt $opt2" "verb"
                log "$curprofile: Error: Option $opt requires a username" "quiet"
                exit 1
            fi
            if [ "$curprofile" = "commandline" ]; then
                user="$opt2"
            else
                log "$curprofile: Warning: Option $opt ignored in profile"
            fi
            ;;
        * )
            log "$curprofile: Option $opt $opt2" "verb"
            log "$curprofile: Error: Unknown option $opt" "quiet"
            exit 1
            ;;
    esac
    if (( shifts == 2 )); then
        log "$curprofile: Option $opt $opt2" "verb"
    else
        log "$curprofile: Option $opt" "verb"
    fi
    return $shifts
}

loadprofile () {   # $1=profile name or path
    p="$1"
    # exists?
    if [ "${p:0:1}" != "/" ]; then
        test1=`basename "$p"`
        test2=`basename "$p" "profile"`
        if [ "$test1" = "$test2" ]; then
            p="$profolder/$p.profile"
        else
            p="$profolder/$p"
        fi
    fi
    if [ ! -e "$p" ]; then
        log "sandfox: Error: Missing profile $p" "quiet"
        exit 3
    fi
    # already loaded?
    loadedprofidx=0
    load=1
    while (( loadedprofidx < loadedprofcnt )); do
        if [ "$p" = "${loadedprof[$loadedprofidx]}" ]; then
            load=0
            break
        fi
        (( loadedprofidx += 1 ))
    done
    if (( load == 1 )); then
        curprofile="$p" # global var
        loadedprof[$loadedprofcnt]="$p"
        (( loadedprofcnt += 1 ))
        # read profile
        log "Loading profile \"$1\""
        IFS=$'\n'
        loadedopts=`grep -v -e "^[[:blank:]]*#" "$p"`
        for l in $loadedopts ; do
            lorg="$l"
            if [ "$l" != "" ]; then
                l2=${l#*=}
                if [ "$l" != "$l2" ]; then
                    # split = into two opts
                    l=${l%%=*}
                else
                    l2=""
                fi
                # remove whitespace and comments
                while [[ $"${l:0:1}" =~ [[:blank:]] ]]; do
                    l="${l:1}"
                done
                l=${l%%#*}
                lenl=${#l}
                (( lenl -= 1 ))
                while [[ $"${l:lenl:1}" =~ [[:blank:]] ]]; do
                    l="${l:0:lenl}"
                    lenl=${#l}
                    (( lenl -= 1 ))
                done
                l=${l%%[[:blank:]]}
                while [[ $"${l2:0:1}" =~ [[:blank:]] ]]; do
                    l2="${l2:1}"
                done
                l2=${l2%%#*}
                lenl2=${#l2}
                (( lenl2 -= 1 ))
                while [[ $"${l2:lenl2:1}" =~ [[:blank:]] ]]; do
                    l2="${l2:0:lenl2}"
                    lenl2=${#l2}
                    (( lenl2 -= 1 ))
                done
                # process
                if [ "$l" != "" ]; then
                    processopt "$l" "$l2"
                elif [ "$l2" != "" ]; then
                    log "sandfox: Syntax error in profile $p" "quiet"
                    log "       Line: $lorg" "quiet"
                    exit 3
                fi
            fi
        done
        IFS=" "
    fi
}

randhex4()  # generate a four digit random hex number
{
    rand1=$RANDOM
    rand2=$RANDOM
    (( rand = rand1 + rand2 ))
    let "rand %= 65536"
    randhex=`printf "%04X" $rand | tr A-Z a-z`
    if [ "$randhex" = "" ]; then
        randhex=$RANDOM  # failsafe
    fi
}

rmbox () {   # $1=mnt folder to remove
    if [ "$1" = "" ]; then 
        return
    elif [ ! -d "$1" ]; then
        return
    fi
    cleanpath="$1"
    IFS=$'\n'
    
    # find dbus daemon(s) running in sandbox(s)
    # If DBUS_SESSION_BUS_ADDRESS is not provided, firefox will
    # launch a dbus session inside the sandbox.  This needs to be killed
    # for the sandbox to be closed.
    if [ "$cleanpath" != "$mnt" ]; then
        # single sandbox
        dbuspids=`lsof -w 2> /dev/null | grep $cleanpath/usr/bin/dbus-launch$ | awk '{print $2}'`
    else
        # all sandboxes
        dbuspids=`lsof -w 2> /dev/null | grep $cleanpath/.*/usr/bin/dbus-launch$ | awk '{print $2}'`
    fi
    # kill dbus-launch in sandbox(s)
    for dpid in $dbuspids ; do
        log ">>> kill $dpid  # kill dbus-launch in sandbox" "verb"
        kill $dpid
        sleep 1
        tries=0
        while (( tries < 20 )) && [ "$(ps -o pid= -p $dpid)" != "" ]; do
            if (( tries == 0 )); then
                log "Waiting for dbus-launch ($dpid) to terminate..."
            fi
            sleep .5
            (( tries++ ))
        done
    done

    # get mount points in reverse order
    mname="$cleanpath"
    mname=${mname//\//\\\/} # convert slashes
    mtab=`mount | grep " on $cleanpath\/" | sed "s/.* on \($mname.*\) type .*/\1/" | tac`
    if [ "$mtab" != "" ]; then
        # umount in reverse order
        for m in $mtab ; do
            log ">>> umount \"$m\"" "verb"
            test=`umount "$m" 2>&1`
            if [ "$?" != "0" ]; then
                log "$test"
                log "sandfox: Error: Closure incomplete - mounts may still exist on" "quiet"
                log "         $cleanpath  Close programs running in" "quiet"
                log "         the sandbox and try again.  If problem persists see output of:" "quiet"
                log "         lsof -w | grep $cleanpath"
                exit 4
            fi
        done
        # do safety checks then remove folder
        mounts=`mount | grep " on $cleanpath\/" | sed "s/.* on \($mname.*\) type .*/\1/"`
        f1=`find "$cleanpath" -xdev -type f | wc -l 2> /dev/null`
        f2=`find "$cleanpath" -type f | wc -l 2> /dev/null`
        if [ "$f1" != "$f2" ] && [ "$mounts" = "" ]; then
            log "sandfox: Error: Not all files could be safely removed from $cleanpath" "quiet"
            log "         This may indicate a hidden bind mount still exists.  It is" "quiet"
            log "         recommended that you reboot or backup original folders, then" "quiet"
            log "         manually remove $cleanpath as root." "quiet"
            exit 4
        elif (( f1 > 50 )) && [ "$mounts" = "" ]; then
            log "sandfox: Error: Not all files could be safely removed from $cleanpath" "quiet"
            log "         because the number of files remaining exceeds the safety limit" "quiet"
            log "         of 50.  It is recommended that you reboot or backup original" "quiet"
            log "         folders, then manually remove $cleanpath as root." "quiet"
            exit 4
        elif [ "$mounts" != "" ]; then
            log "sandfox: Error: Closure incomplete - mounts still exist on" "quiet"
            log "         $cleanpath  Close programs running in" "quiet"
            log "         the sandbox and try again.  Mounts:" "quiet"
            log "$mounts" "quiet"
            exit 4
        else
            log "Removing $cleanpath" "verb"
            log ">>> find \"$cleanpath\" -xdev | sort -r" "verb"
            f1=`find "$cleanpath" -xdev | sort -r 2> /dev/null`
            if [ "$f1" != "" ]; then
                for f in $f1 ; do
                    if [ -d "$f" ]; then
                        rmdir "$f"
                    else
                        rm "$f"
                    fi
                done
            fi
            if [ -e "$cleanpath" ]; then
                log "sandfox: Error: Not all files could be safely removed from $cleanpath" "quiet"
                log "         This may indicate a hidden bind mount.  It is recommended" "quiet"
                log "         that you reboot or backup original folders before" "quiet"
                log "         manually removing $cleanpath as root." "quiet"
                exit 4
            fi
        fi
    fi
    IFS=" "
}

mkmount () {   # $1=original folder
    # make mount point
    odir="$1"
    fdir="$sand$1"
    mkdir -p "$fdir" 2> /dev/null
    # recursively copy original folder ownership & permissions
    while [ "$odir" != "" ]; do
        if [ -e "$odir" ]; then
            chmod --reference="$odir" "$fdir" 2> /dev/null
            chown --reference="$odir" "$fdir" 2> /dev/null
        else
            chmod ugo+rwx "$fdir" 2> /dev/null
            chown $user:$user "$fdir" 2> /dev/null
        fi
        odir=${odir%/*}
        fdir=${fdir%/*}
    done
}

sandmount () {    # $1=type  $2=source  $3=target
    case "$1" in
        bind | bindro )
            if [ -d "$2" ]; then
                mkmount "$2"
            elif [ ! -e "$3" ]; then
                mdir=`dirname "$2"`
                mkmount "$mdir"
                touch "$3"
            fi
            log ">>> mount --bind \"$2\" \"$3\"" "verb"
            mount --bind "$2" "$3"
            merr1=$?
            if [ "$2" != "/dev/random" ] && [ "$2" != "/dev/urandom" ]; then
                # remount
                if [ "$1" = "bindro" ]; then
                    if [ "$2" = "/tmp" ]; then
                        log "sandfox: Warning: You are mounting /tmp read-only - your programs"
                        log "                  may not work properly in this sandbox"
                    fi
                    mopt="remount,bind,noatime,nosuid,ro"
                else
                    mopt="remount,bind,noatime,nosuid"
                fi
                log ">>> mount -o $mopt \"$3\"" "verb"
                mount -o $mopt "$3"
                merr2=$?
            else
                # don't remount /dev/random - causes hang
                merr2=0
                if [ "$1" = "bindro" ]; then
                    log "sandfox: Warning: $2 cannot be mounted ro - mounted rw"
                fi
            fi  
            test=`mount | grep " on $3 type "`
            if [ "$test" = "" ] || (( merr1 + merr2 != 0 )); then
                log "sandfox: Error: $1 mount failed on $3" "quiet"
                if (( newsand == 1 )); then
                    rmbox "$sand"
                fi
                exit 4
            fi
            ;;
        tmpfs )
            mkmount "$2"
            if [ -d "$3" ]; then
                log ">>> mount -t tmpfs -o noatime,nosuid,size=$tmpfslimit tmpfs \"$3\"" "verb"
                mount -t tmpfs -o noatime,nosuid,size=$tmpfslimit tmpfs "$3"
                merr1=$?
                test=`mount | grep "^tmpfs on $3 type tmpfs"`
                if [ "$test" = "" ] || (( merr1 != 0 )); then
                    log "sandfox: Error: tmpfs mount failed on $3" "quiet"
                    if (( newsand == 1 )); then
                        rmbox "$sand"
                    fi
                    exit 4
                fi
            else
                log "sandfox: Warning: Could not hide $2"
            fi
            ;;
    esac
}

boxstatus () {    # $1 =box name OR "" for all
    if [ "$1" = "" ]; then
        boxes=`find $mnt -maxdepth 1 -mindepth 1 -type d 2> /dev/null`
    else
        boxes="$1"
    fi
    IFS=$'\n'
    log
    if [ "$boxes" = "" ]; then
        log "  No sandboxes exist"
    else
        for b in $boxes ; do
            bname="$(basename "$b")"
            testdaemons=`ps -eo user,cmd | grep -v -e "grep" -e " /bin/su " | grep -c "sandfox .*--daemon.*$eventsfolder/$bname[[:blank:]]*$"`
            testfolders=`find "$b" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort`
            testfolders="${testfolders//$IFS/ }"
            testmounts=`mount | grep -c " on $b/"`
            if [ "$testfolders" != "" ] || [ "$testdaemons" != "" ] || (( testmounts > 0 )); then
                makemsg=" (remake this sandbox to use it)"
                if (( testdaemons < 1 )) || [ ! -d "$eventsfolder/$bname" ]; then
                    testdaemons="disabled$makemsg"
                    makemsg=""
                else
                    testuser=`ps -eo "%U %a" | grep -v -e "grep" -e " /bin/su " \
                      | grep -m 1 "sandfox .*--daemon.*$eventsfolder/$bname[[:blank:]]*$" \
                      | sed 's/\([a-zA-Z0-9]*\) .*/\1/'`
                    testdaemons="running ($testuser)"
                fi
                if (( testmounts < 1 )); then
                    testmounts="none$makemsg"
                    makemsg=""
                else
                    testmounts="$testmounts   $mnt/$bname/"
                fi
                if [ testfolders = "" ]; then
                    testfolders="none$makemsg"
                fi
                log "Sandbox:     $bname"
                log "  Daemon:    $testdaemons"
                log "  Mounts:    $testmounts"
                log "  Root Dirs: $testfolders"
                log
            fi
        done
    fi
    IFS=" "
}

mkprofiles () { 
    # profile folder
    if [ "$profolder" = "" ]; then
        profolder="$defaultprofolder"
    fi
    mkdir -p "$profolder"
    if [ ! -d "$profolder" ]; then
        log "sandfox: Error: Could not create profile folder $profolder" "quiet"
        exit 3
    fi
    if [ ! -e "$profolder/default.profile" ]; then
        cat << EOF > "$profolder/default.profile"
# Sandfox Default Profile
#
# WARNING: This default profile is loaded for all sandboxes and should only
#          contain the minimum folders required by all apps.  If you do not at
#          least bind /bin /lib and /etc then the chroot command may not succeed.
#
# For instructions consult http://igurublog.wordpress.com/downloads/script-sandfox/
# OPTION
# or
# OPTION=VALUE   (Do not use quotes)
#
# To include another profile in this profile:
# profile=PROFILENAME


# root folders and files
bindro=/bin     # required by chroot su - do not remove
bindro=/etc     # required by chroot su - do not remove
bindro=/lib     # required by chroot su - do not remove


# recommended to keep apps happy
bind=/dev/null
bind=/dev/urandom
bind=/dev/random
bind=/dev/nvidia0
bind=/dev/nvidiactl
bindro=/lib32
bindro=/lib64
bindro=/opt/lib32
bind=/tmp
bindro=/usr
bindro=/var/lib
hide=/var/lib/mlocate   # security


# home folders and files
# probably better to bind most home folders and files in another profile
copy=/home/\$user/.bashrc           # provides a disposable copy
copy=/home/\$user/.bash_profile     # provides a disposable copy


# other folders and files
# probably better to put these in another profile



# Lockdown X Access  (experimental)
# These hides, disabled by default, MAY HELP to lockdown X access - for
# example to discourage sandboxed apps from taking screen snapshots or
# doing keylogging.  If you enable these, be sure to close all sandboxes
# before updating your system.  Your package manager won't be able to
# update these files while they are mounted in a sandbox.
#
# hide=/usr/bin/import
# hide=/usr/bin/xauth
# hide=/usr/bin/xev
# hide=/usr/bin/xhost
# hide=/usr/bin/xwd
# hide=/usr/bin/xscreensaver
# hide=/usr/bin/xscreensaver-command
# hide=/usr/bin/xscreensaver-demo
# hide=/usr/bin/xscreensaver-getimage
# hide=/usr/bin/xscreensaver-getimage-file
# hide=/usr/bin/xscreensaver-getimage-video
# hide=/usr/bin/Xorg
# hide=/etc/X11
# hide=/usr/lib/X11


EOF
    fi
    if [ ! -e "$profolder/firefox.profile" ]; then
        cat << EOF > "$profolder/firefox.profile"
# Sandfox Firefox Profile
#
# Note that default.profile is always loaded in addition to other profiles 
#
# For instructions consult http://igurublog.wordpress.com/downloads/script-sandfox/
# OPTION
# or
# OPTION=VALUE   (Do not use quotes)
#
# To include another profile in this profile:
# profile=PROFILENAME


# root folders and files required by firefox
bindro=/bin
bindro=/opt/firefox     # sometimes firefox is installed here
bind=/dev/null
bind=/dev/urandom       # used by Firefox for security purposes
bind=/dev/random        # used by Firefox for printing
bind=/dev/nvidia0
bind=/dev/nvidiactl
bindro=/etc
bindro=/lib
bindro=/lib32
bindro=/lib64
bindro=/opt/lib32
bind=/tmp
bindro=/usr
bindro=/var/lib
hide=/var/lib/mlocate

# required by alsa for Flash sound
bindro=/dev/snd

# required by Java
bindro=/opt/java
bindro=/proc

# required by Cups printing in Firefox
bind=/var/cache/cups        # Firefox starts faster
bind=/var/cache/fontconfig  # Firefox starts faster
bind=/var/run               # Firefox shows Cups printers

# home folders and files
# You may need to add additional binds to your home folders and files in order
# for every aspect of Firefox to work as you want.  Or you can share your
# entire /home/\$user folder (this would reduce security)
bind=/home/\$user/.mozilla
bind=/home/\$user/.esd_auth
bind=/home/\$user/.java

# Needed for KDE and Gnome themes in Firefox   (may be incomplete for gnome)
# To find out what other binds you may need, run 'env' in a shell as user
#       and examine the values of GTK2_RC_FILES and GTK_RC_FILES and XCURSOR_THEME
# Note: The bind for kdeglobals below is a limited privacy risk, as KDE4 stores
#       recent file and folder names in this file.  You can clean this file with 
#       kscrubber:  http://igurublog.wordpress.com/downloads/script-kscrubber/
#       or don't bind it, but your theme may not work in Firefox
bind=/home/\$user/.config/gtk-2.0
bindro=/home/\$user/.fontconfig
bindro=/home/\$user/.fonts
bind=/home/\$user/.gtkrc-2.0
bind=/home/\$user/.gtkrc-2.0-kde4
bind=/home/\$user/.kde/share/config/gtkrc
bind=/home/\$user/.kde/share/config/gtkrc-2.0      
bindro=/home/\$user/.kde/share/config/kdeglobals
bind=/home/\$user/.kde4/share/config/gtkrc
bind=/home/\$user/.kde4/share/config/gtkrc-2.0      
bindro=/home/\$user/.kde4/share/config/kdeglobals
bindro=/home/\$user/.gtkrc-2.0-kde
bind=/home/\$user/.kde3/share/config/gtkrc
bind=/home/\$user/.kde3/share/config/gtkrc-2.0      
bindro=/home/\$user/.kde3/share/config/kdeglobals
bindro=/home/\$user/.Xdefaults  # for cursor theme
bindro=/home/\$user/.Xauthority
#bindro=/etc/gtk-2.0/gtkrc      # used but already binded all of /etc


# Required by flash player for persisent LSOs
# Hide will store the cookies in ram and destroy them on exit.  If you need
# LSOs to be permanent, use bind= instead.
# http://www.wired.com/epicenter/2009/08/you-deleted-your-cookies-think-again/
hide=/home/\$user/.adobe            # creates a dummy folder
hide=/home/\$user/.macromedia   # creates a dummy folder


# other folders and files
# You may want to bind your Downloads or other data folders below so you
# can easily save and upload files from within Firefox.

EOF
    fi
    if [ ! -e "$profolder/skype.profile" ]; then
        cat << EOF > "$profolder/skype.profile"
# Sandfox Skype Profile
#
# Note that default.profile is always loaded in addition to other profiles 
#
# For instructions consult http://igurublog.wordpress.com/downloads/script-sandfox/
# OPTION
# or
# OPTION=VALUE   (Do not use quotes)
#
# To include another profile in this profile:
# profile=PROFILENAME

# Set this to your Skype video device
# Note: /dev/video probably won't work
bind=/dev/video0

bind=/dev/shm
bind=/dev/snd
bind=/dev/nvidia0
bind=/dev/nvidiactl
# bind=/sys/devices/system/cpu      # ???
# bindro=/etc/pulse/client.conf     # only needed if /etc not bound
bindro=/proc/interrupts
bindro=/var/cache/libx11/compose
bind=/tmp
bindro=/usr
bind=/usr/share/skype  # Gentoo users may need to disable this bind
bind=/opt/skype

# Following only needed if all of /tmp not bound above
# copy=/tmp/.ICE-unix           
# copy=/tmp/.X11-unix/X0
# bind=/tmp/pulse-*/native

# Following only needed if all of /usr not bound above
# copy=/usr/bin/skype
# bindro=/usr/lib/qt4/plugins/iconengines
# bindro=/usr/lib/qt4/plugins/imageformats
# bindro=/usr/lib/qt4/plugins/imageformats
# bindro=/usr/lib/qt4/plugins/inputmethods
# bindro=/usr/share/X11/locale
# bindro=/usr/share/icons
# bindro=/usr/share/fonts

bind=/home/\$user/.Skype
bindro=/home/\$user/.ICEauthority
bindro=/home/\$user/.Xauthority
bindro=/home/\$user/.config/Trolltech.conf
bindro=/home/\$user/.fontconfig


EOF
    fi
    if [ ! -e "$profolder/google-earth.profile" ]; then
        cat << EOF > "$profolder/google-earth.profile"
# Sandfox Google-Earth Profile
#
# Note that default.profile is always loaded in addition to other profiles 
#
# For instructions consult http://igurublog.wordpress.com/downloads/script-sandfox/
# OPTION
# or
# OPTION=VALUE   (Do not use quotes)
#
# To include another profile in this profile:
# profile=PROFILENAME


# root folders and files
bindro=/bin
bind=/dev/null
bind=/dev/urandom
bind=/dev/random
bind=/dev/nvidia0
bind=/dev/nvidiactl
bindro=/etc
bindro=/lib
bindro=/lib32
bindro=/lib64
bindro=/opt/lib32
bind=/tmp
bindro=/usr
bindro=/var/lib
hide=/var/lib/mlocate
bindro=/opt/google/earth
bindro=/opt/google-earth

# required by Cups printing
bind=/var/cache/cups
bind=/var/cache/fontconfig
bind=/var/run

# home folders and files
# You may need to add additional binds to your home folders and files in order
# for every aspect of Google-Earth to work as you want.  Or you can share your
# entire /home/\$user folder (this would reduce security)
bind=/home/\$user/.googleearth
bind=/home/\$user/.config/Google
bind=/home/\$user/.esd_auth
bindro=/home/\$user/.config/Trolltech.conf

# Themes
bindro=/home/\$user/.Xdefaults
bindro=/home/\$user/.Xauthority
bindro=/home/\$user/.fontconfig
bindro=/home/\$user/.fonts

# other folders and files
# You may want to bind your Downloads or other data folders below so you
# can easily save and upload files from within Google-Earth.


EOF
    fi
    if [ ! -e "$profolder/default.profile" ] || \
       [ ! -e "$profolder/firefox.profile" ] || \
       [ ! -e "$profolder/google-earth.profile" ] || \
       [ ! -e "$profolder/skype.profile" ]; then
        log "sandfox: Error: Could not create default profiles in $profolder" "quiet"
        exit 3
    fi
}


######################################################################################
# pre-init
defaultprofolder="/etc/sandfox"
# BE CAREFUL if you change $mnt - folder will be removed
mnt="/mnt/sandfox"
# eventsfolder cannot contain spaces and must be a bind
eventsfolder="/tmp/sandfox-events"
# maximum size of copy/hide folders
tmpfslimit="100M"
index=0
bindscnt=0
bindroscnt=0
hidescnt=0
copyscnt=0
watchscnt=0
closecnt=0
prof[0]="default"
profcnt=1
profolder=""
sandbox=""
logfile=""
logcl="$0 $*"
curprofile="commandline"

# parse command line
if [ "$1" = "" ]; then
    help
    exit
fi
while [ "$1" != "" ]; do
    if [ "${1:0:1}" = "-" ]; then
        o2=${1#*=}
        if [ "$1" != "$o2" ]; then
            # split = into two opts
            o1=${1%%=*}
            noshift=1
        else
            o1="$1"
            o2="$2"
            noshift=0
        fi
        processopt "$o1" "$o2"
        if [ "$?" = "2" ] && (( noshift == 0 )); then
            shift
        fi
    else
        bcmd="$*"
        bprog="${bcmd%% *}"
        bprog="$(basename $bprog)"
        if [ "$bprog" = "" ]; then
            log "sandfox: Error: Could not determine sandbox program" "quiet"
            exit 1
        fi
        break
    fi
    shift
done

# daemon mode
# Note: Daemon mode is run internally as non-root user by sandfox to start
#       an events monitor which starts programs in the sandbox for the user
#       Daemon mode is not intended for direct use by the user
if (( optdaemon == 1 )); then
    if (( watchscnt < 1 )); then
        log "sandfox-daemon: Error: Invalid daemon call - no watches" "quiet"
        exit 9
    fi
    watchx=0
    watchlist=""
    while (( watchx < watchscnt )); do
        watchlist="$watchlist \"${watchs[$watchx]}\""
        (( watchx += 1 ))
    done

    # start watching
    user=`whoami`
    IFS=$'\n'
    while [ 1 ]; do
        log ">>> inotifywait -eq modify $watchlist" "verb"
        fnotify=`eval /usr/bin/inotifywait -q -e modify -e moved_to -e create $watchlist`
        if [ "$?" != "0" ]; then
            log "Quitting - watch stopped"
            exit 0
        fi
        # watch folders still exist?
        watchx=0
        while (( watchx < watchscnt )); do
            if [ ! -d "${watchs[$watchx]}" ]; then
                log "Quitting - ${watchs[$watchx]} deleted"
                exit 0
            fi
            (( watchx += 1 ))
        done
        # run
        f1=`echo "$fnotify" | grep -e " MODIFY " -e " CREATE " -e " MOVED_TO "`
        f1="${f1/ CREATE / MODIFY }"
        f1="${f1/ MOVED_TO / MODIFY }"
        if [ "$f1" != "" ]; then
            for fx in $f1 ; do
                fdir=${fx%% MODIFY *}
                f="$fdir${fx#* MODIFY }"
                ftest1=`basename "$f"`
                ftest2=`basename "$f" "desktop"`
                if [ "$ftest1" != "$ftest2" ]; then
                    desktop=1
                else
                    desktop=0
                fi
                if [ -f "$f" ] && [ -O "$f" ]; then
                    if [ -x "$f" ] && (( desktop == 0)); then
                        log "Executing $f..."
                        $f &
                        log "Deleting $f..." "verb"
                        ( sleep 5 && rm -f "$f" ) &
                    elif (( desktop == 1 )); then
                        wcmd=`cat "$f" | grep -m 1 "^Exec="`
                        if [ "$wcmd" != "" ]; then
                            wcmd="${wcmd:5}"
                            if [ "$wcmd" != "" ]; then
                                log "Executing $wcmd ($f)..."
                                eval $wcmd &
                                log "Deleting $f..." "verb"
                                ( sleep 5 && rm -f "$f" ) &
                            else
                                log "Could not execute $f"
                            fi
                        fi
                    fi
                fi
            done
        fi
    done
    exit 12
fi

# determine sandbox user
runuser=`whoami`
if [ "$user" = "" ]; then
    if [ "$runuser" = "root" ]; then
        # based on env
        if [ "$SUDO_USER$LOGNAME$USER" != "" ]; then
            for u in $SUDO_USER $LOGNAME $USER ; do
                if [ "$u" != "root" ] && [ "$u" != "" ] && [ -e "/home/$u" ]; then
                    user="$u"
                    break
                fi
            done
        fi
        # based on Xauthority
        if [ "$user" = "" ] && [ "$XAUTHORITY" != "" ]; then
            user=`echo "$XAUTHORITY" | grep "^\/home\/.*\/\.Xauthority$" \
                               | sed 's/\/home\/\(.*\)\/.*/\1/'`
            if [ "$user" = "root" ]; then
                user=""
            fi
        fi
        # based on /home and ps
        if [ "$user" = "" ]; then
            IFS=" "
            ucnt=0
            keepu=""
            for d in /home/* ; do
                u=`basename $d`
                if [ "$u" != "" ] && [ "$u" != "/home/*" ]; then
                    test=`ps h -u $u -o "%U %c" 2> /dev/null`
                    if [ "$test" != "" ]; then
                        keepu="$u"
                        (( ucnt += 1 ))
                    fi
                fi
            done
            if (( ucnt == 1 )) && [ "$keepu" != "root" ]; then
                user="$keepu"
            fi
        fi
        # based on pwd
        if [ "$user" = "" ]; then
            if [ "${PWD:0:6}" = "/home/" ]; then
                u=`echo "$PWD" | sed 's/^\/home\/\([a-z0-9]*\).*/\1/'`
                if [ "$u" != "" ] && [ "$u" != "root" ] && [ -e "/home/$u" ] ; then
                    user="$u"
                fi
            fi
        fi
    else
        user="$runuser"
    fi
fi
if [ "$user" = "root" ]; then
    log "sandfox: Warning: Running root in the sandbox is not recommended!" "quiet"
elif [ "$user" = "" ]; then
    log "sandfox: Error: Could not determine sandbox user" "quiet"
    log "                Please specify --user USERNAME" "quiet"
    exit 2
fi

# close
if (( optcloseall + closecnt != 0 )); then
    if [ "$runuser" != "root" ]; then
        log "sandfox: Error: Closing a sandbox requires root" "quiet"
        exit 2
    fi
    if (( optcloseall == 1 )); then
        if [ "$eventsfolder" != "" ]; then
            log ">>> rm -rf $eventsfolder/*" "verb"
            rm -rf $eventsfolder/*  # this also stops daemons
            sync
            mkdir -p "$eventsfolder/tmp"
            chmod ugo+rwx,+t "$eventsfolder/tmp" 2> /dev/null
        fi
        rmbox "$mnt"
    else
        closex=0
        while (( closex < closecnt )); do
            c="${closename[$closex]}"
            # sandbox exists?
            testdaemons=`ps -eo user,cmd | grep -v "grep" | grep "sandfox .*--daemon.*$eventsfolder/$c[[:blank:]]*$"`
            testmounts=`mount | grep " on $mnt/$c " | wc -l`
            if [ -e "$mnt/$c" ] || [ "$testdaemons" != "" ] || (( testmounts > 0 )); then
                if [ "$eventsfolder" != "" ]; then
                    rm -rf "$eventsfolder/$c"
                fi
                rmbox "$mnt/$c"
            else
                log "sandfox: Warning: No such sandbox \"$c\"" "quiet"
            fi
            (( closex += 1 ))
        done
    fi
fi

# assume make
if (( bindscnt + bindroscnt + copyscnt + hidescnt != 0 )) || (( profcnt > 1 )); then
    optmake=1
elif [ "$sandbox" != "" ] && [ "$bcmd" = "" ]; then
    optmake=1
fi

# count usable daemons and assume make
if (( optmake == 0 )) && [ "$bcmd" != "" ]; then
    if [ "$sandbox" = "" ]; then
        daemoncnt=`ps -u $user -o "%U %a" | grep -v "grep" | grep -c " .*sandfox .*--daemon"`
    else
        daemoncnt=`ps -u $user -o "%U %a" | grep -v "grep" | grep -c "sandfox .*--daemon.*/$sandbox[[:blank:]]*$"`
    fi
    if (( daemoncnt == 0 )); then
        log "There are no usable sandbox daemons running for $user - make has been enabled"
        optmake=1
    fi
fi

# need root?
if [ "$runuser" != "root" ] && (( optmake + optcloseall + closecnt + optshell != 0 )); then
    log "sandfox: Error: action requires root; run with sudo or --help for info" "quiet"
    exit 2
fi

# SECTION BELOW IS ROOT-ONLY
if (( optmake == 1 )) && [ "$runuser" = "root" ]; then
    # create default profiles
    mkprofiles

    # load profiles
    profidx=0
    loadedprofcnt=0
    if [ "$bprog" != "" ] && [ -e "$profolder/$bprog.profile" ]; then
        prof[$profcnt]="$bprog"
        (( profcnt += 1 ))
    fi
    while (( profidx < profcnt )); do
        # Note: prof[] may grow as profiles are read
        loadprofile "${prof[$profidx]}"
        (( profidx += 1 ))
    done

    # sand
    newsand=0
    if [ "$sandbox" != "" ]; then
        # sandbox exists?
        filecount=`find "$mnt/$sandbox" -mindepth 1 2> /dev/null | wc -l`
        testdaemons=`ps -eo user,cmd | grep -v "grep" | grep "sandfox .*--daemon.*/$sandbox[[:blank:]]*$"`
        testmounts=`mount | grep " on $mnt/$sandbox" | wc -l`
        if (( filecount > 0 )) || [ "$testdaemons" != "" ] || (( testmounts > 0 )); then
            newsand=0
        else
            newsand=1
        fi
        sandname="$sandbox"
    else
        if [ "$bprog" = "" ]; then
            p="${prof[1]}"
            if [ "${p:0:1}" = "/" ]; then
                p=`basename "$p" ".profile"`
            fi
            if [ "$p" != "" ]; then
                sandname="$p"
            else
                sandname="default"
            fi
        else
            sandname="$bprog"
        fi
        sandnametmp="$sandname"
        while [ -e "$mnt/$sandname" ]; do
            randhex4
            sandname="$sandnametmp-$randhex"
        done
        newsand=1
    fi
    if (( newsand == 1 )); then
        log "Creating new sandbox \"$sandname\""
    else
        log
        log "Updating sandbox $sandname"
    fi
    sand="$mnt/$sandname"

    # default folders
    mkdir -p "$mnt"
    chown root:root "$mnt"
    chmod go+rx,go-w "$mnt" 
    mkdir "$sand"
    chown root:root "$sand"
    chmod go+rx,go-w "$sand"
    if [ ! -d "$sand" ]; then
        log "sandfox: Error: Could not create sand folder $sand" "quiet"
        exit 3
    fi

    # check for required binds 
    bindtmp=0
    bindbin=0
    bindetc=0
    bindlib=0
    bindusrlib=0
    bindusrbin=0
    binddev=0
    bidx=0
    while (( bidx < bindscnt )); do
        case "${binds[$bidx]}" in
            /tmp )
                bindtmp=1
                ;;
            /dev )
                binddev=1
                ;;
            /bin )
                bindbin=1
                ;;
            /etc )
                bindetc=1
                ;;
            /lib )
                bindlib=1
                ;;
            /usr )
                bindusrbin=1
                bindusrlib=1
                ;;
            /usr/bin )
                bindusrbin=1
                ;;
            /usr/lib )
                bindusrlib=1
                ;;
        esac
        (( bidx += 1 ))
    done
    bidx=0
    while (( bidx < bindroscnt )); do
        case "${bindros[$bidx]}" in
            /tmp )
                bindtmp=1
                ;;
            /dev )
                binddev=1
                ;;
            /bin )
                bindbin=1
                ;;
            /etc )
                bindetc=1
                ;;
            /lib )
                bindlib=1
                ;;
            /usr )
                bindusrbin=1
                bindusrlib=1
                ;;
            /usr/bin )
                bindusrbin=1
                ;;
            /usr/lib )
                bindusrlib=1
                ;;
        esac
        (( bidx += 1 ))
    done
    if (( bindtmp == 0 )); then
        if [ "${eventsfolder:0:4}" = "/tmp" ]; then
            binds[$bindscnt]="$eventsfolder"
            (( bindscnt += 1 ))
        fi
        log "sandfox: Warning: Not binding /tmp may cause some programs to fail or hang"
    fi
    if (( binddev == 0 )); then
        binds[$bindscnt]="/dev/null"
        (( bindscnt += 1 ))
    fi
    if (( bindusrbin == 0 )); then
        bindros[$bindroscnt]="/usr/bin/inotifywait"
        (( bindroscnt += 1 ))
        bindros[$bindroscnt]="/usr/bin/whoami"
        (( bindroscnt += 1 ))
        bindros[$bindroscnt]="/usr/bin/basename"
        (( bindroscnt += 1 ))
    fi
    if (( bindusrlib == 0 )); then
        f1=`find /usr/lib -maxdepth 1 -xtype f -name "libinotifytools*.so*" 2> /dev/null`
        if [ "$f1" != "" ]; then
            IFS=$'\n'
            for f in $f1 ; do
                bindros[$bindroscnt]="$f"
                (( bindroscnt += 1 ))
            done
            IFS=" "
        fi
    fi
    if (( bindbin + bindlib + bindetc != 3 )); then
        log "sandfox: Warning: Not binding /bin /etc and /lib may not allow"
        log "                  the chroot or su commands to run"
    fi
    if [ ! -e "/usr/bin/inotifywait" ]; then
        log "sandfox: Error: /usr/bin/inotifywait not found" "quiet"
        log "         Arch use:    pacman -S inotify-tools" "quiet"
        log "         Ubuntu use:  apt-get install inotify-tools" "quiet"
        exit 3
    fi

    # binds
    for b in bindro bind copy hide ; do
        # step through list of binds to be processed
        bidx=0
        eval bcnt=$b\scnt
        while (( bidx < bcnt )); do
            eval curb=\"\${$b\s[$bidx]}\"   # current bind item
            curb=${curb//\$user/$user}
            log "Processing $b $curb" "verb"
            if [ -e "$curb" ] || [ "$b" = "hide" ]; then
                # check for duplicates
                dupefound=0
                (( dupeidx = bidx - 1 ))
                while (( dupeidx > -1 )); do
                    eval dupeb=\"\${$b\s[$dupeidx]}\"   # possible duplicate item
                    dupeb=${dupeb//\$user/$user}
                    if [ "$dupeb" = "$curb" ]; then
                        dupefound=1
                        break
                    fi
                    (( dupeidx -= 1 ))
                done
                # process
                if (( dupefound == 0 )); then
                    test=`mount | grep " $sand$curb "`
                    if [ "$test" != "" ]; then
                        log "$b $sand$curb: already mounted" "verb"
                    else
                        case "$b" in
                            bindro | bind )
                                # create mount point and recursively copy permissions
                                # bind mount file or folder
                                sandmount $b "$curb" "$sand$curb"
                                ;;
                            copy | hide )
                                if [ -d "$curb" ] || [ ! -e "$curb" ]; then
                                    # folder copy/hide
                                    # mount on tmpfs
                                    sandmount tmpfs "$curb" "$sand$curb"
                                    if [ -e "$curb" ]; then
                                        chmod --reference="$curb" "$sand$curb" 2> /dev/null
                                        chown --reference="$curb" "$sand$curb" 2> /dev/null
                                    else
                                        # non-existent hide permissions
                                        chmod ugo+rwx "$sand$curb" 2> /dev/null
                                        chown $user:$user "$sand$curb" 2> /dev/null
                                    fi
                                    if [ "$b" = "copy" ]; then
                                        log ">>> cp -ax \"$curb/.\" \"$sand$curb/.\"" "verb"
                                        cp -ax "$curb/." "$sand$curb/."
                                        if [ "$?" != "0" ]; then
                                            log "sandfox: Warning: cp reported an error copying $curb" "quiet"
                                        fi
                                    fi
                                else
                                    # file copy/hide
                                    if [ "$b" = "copy" ]; then
                                        # copy
                                        if [ ! -e "$sand$curb" ]; then                              
                                            mdir=`dirname "$curb"`
                                            mkmount "$mdir"
                                            log ">>> cp -a \"$curb\" \"$sand$curb\"" "verb"
                                            cp -a "$curb" "$sand$curb"
                                            if [ "$?" != "0" ]; then
                                                log "sandfox: Warning: cp reported an error copying $curb" "quiet"
                                            fi
                                        else
                                            log "Cannot create copy of $curb" "verb"
                                            log "  because it already exists in sandbox" "verb"
                                        fi
                                    else
                                        # hide
                                        sandmount bind "/dev/null" "$sand$curb"
                                    fi
                                fi
                                ;;
                        esac
                    fi
                fi
            fi
            (( bidx += 1 ))
        done
    done
    sync

    # daemon running for user?
    test=`ps -u $user -o "%U %a" | grep -v "grep" \
          | grep " .*sandfox .*--daemon .*$eventsfolder/$sandname[[:blank:]]*$"`
    if [ "$test" = "" ]; then
        # start daemon
        if [ "$logfile" != "" ]; then
            dlog="--logfile $logfile"
        else
            dlog=""
        fi
        if (( optverbose == 1 )); then
            verb="--verbose"
        else
            verb=""
        fi      
        mkdir -p "$eventsfolder"
        chown root:root "$eventsfolder" 2> /dev/null
        chmod ugo+rwx,+t "$eventsfolder" 2> /dev/null
        if [ ! -d "$eventsfolder" ]; then
            log "sandfox: Error: Could not create events folder $eventsfolder" "quiet"
            exit 3
        fi
        mkdir -p "$eventsfolder/tmp"
        chmod ugo+rwx,+t "$eventsfolder/tmp" 2> /dev/null
        cp "$0" "$eventsfolder/tmp/sandfox"
        chmod ugo+rx,go-w "$eventsfolder/tmp/sandfox"
        mkdir -p "$eventsfolder/$sandname"
        chmod ugo+rwx,+t "$eventsfolder/$sandname"
        log "Starting daemon as $user for sandbox \"$sandname\"..." "verb"
        log ">>> chroot $sand /bin/su $user -c \"$eventsfolder/tmp/sandfox --daemon $dlog $verb --watch $eventsfolder/$sandname\"" "verb"
        if (( optverbose == 1 )); then
            chroot $sand /bin/su $user -c "$eventsfolder/tmp/sandfox --daemon $dlog $verb --watch $eventsfolder/$sandname" &
        else
            chroot $sand /bin/su $user -c "$eventsfolder/tmp/sandfox --daemon $dlog $verb --watch $eventsfolder/$sandname" 2> /dev/null > /dev/null &
        fi
        sleep .5
        test=`ps -u $user -o "%U %a" | grep -v "grep" \
              | grep " .*sandfox .*--daemon .*$eventsfolder/$sandname[[:blank:]]*$"`
        if [ "$test" = "" ]; then
            log "sandfox: Warning: Could not start daemon - you may not be able" "quiet"
            log "                  to run additional programs in this sandbox" "quiet"
        fi
    fi
fi

# run command in sandbox
if [ "$bcmd" != "" ]; then
    if [ "$sandname" = "" ]; then
        # check/set sandbox name
        if [ "$sandbox" != "" ]; then
            sandname="$sandbox"
        else
            # find a sandbox daemon to run bcmd
            IFS=" "
            dtotal=0
            dprefer=""
            dgood=""
            for d in $eventsfolder/* ; do
                if [ "$d" != "$eventsfolder/*" ] && [ "$d" != "" ] && [ -d "$d" ] \
                     && [ "$d" != "$eventsfolder/tmp" ] ; then
                    dname=`basename "$d"`
                    test=`ps -u $user -o "%U %a" | grep -v "grep" \
                          | grep " .*sandfox .*--daemon .*$d[[:blank:]]*$"`
                    if [ "$test" != "" ]; then 
                        examples="$examples  sandfox --sandbox $dname $bcmd\n"
                        dgood="$dname"
                        if [ "$dname" = "$bprog" ]; then
                            dprefer="$dname"
                        fi
                        (( dtotal += 1 ))
                    fi
                fi
            done
            if (( dtotal == 0 )); then
                log "sandfox: Error: There is no open sandbox to run $bprog" "quiet"
                exit 5
            elif (( dtotal > 1 )); then
                log "sandfox: Warning: There is more than one sandbox open"
                log "                  To specify a sandbox:"
                echo -e "$examples"
                if [ "$dprefer" != "" ]; then
                    sandname="$dprefer"
                else
                    sandname="$dgood"
                fi
            else
                sandname="$dgood"
            fi
        fi
    fi
    
    # Check if firefox already running
    if [ "${bcmd%% *}" = "firefox" ]; then
        testrunning=`ps -u $user -o "%U %a" | grep -v "grep" | grep -v "sandfox" \
                     | grep -e " *${bcmd%% *}$" -e " *${bcmd%% *} "`
        if [ "$testrunning" != "" ]; then
            log "sandfox: Warning: An instance of ${bcmd%% *} is already running"
        fi
    fi
        
    if [ "$runuser" = "root" ]; then
        # start directly
        if (( optshell == 1 )) || [ "$bprog" = "bash" ]; then
            log
            if [ "$bprog" = "bash" ]; then
                p=""
            else
                p=" running $bprog"
            fi
            log ">>> shell - you are $user$p in sandbox \"$sandname\" <<<"
            log ">>> chroot $mnt/$sandname /bin/su $user -c \"$bcmd\"" "verb"
            if [ "$SUDO_USER" != "" ]; then
                ruser="$SUDO_USER"
            else
                ruser="ROOT"
            fi
            chroot $mnt/$sandname /bin/su $user -c "$bcmd"
            log
            log "<<< exit - you are $ruser out of the sandbox >>>"
        else
            log "Starting $bprog as $user in sandbox \"$sandname\"..."
            log ">>> chroot $mnt/$sandname /bin/su $user -c \"$bcmd\" &" "verb"
            if (( verbose == 1 )); then
                chroot $mnt/$sandname /bin/su $user -c "$bcmd" &
            else
                chroot $mnt/$sandname /bin/su $user -c "$bcmd" 2> /dev/null > /dev/null &
            fi
        fi
    else
        log "Starting $bprog as $user in sandbox \"$sandname\"..."
        # start via daemon
        # get env of caller
        e=`env | grep -v "'" | sed "s/\([A-Z_]*=\)\(.*\)/\1\\\'\2\\\'/"`
        if [ "$e" != "" ]; then
            e="env -i ${e//$'\n'/ }"
        else
            e=""
        fi
        # build start script
        randhex4
        cscript="$bprog-$randhex.sh"
        while [ -e "$eventsfolder/tmp/$cscript" ]; do
            randhex4
            cscript="$bprog-$randhex.sh"
        done
        cat << EOF > "$eventsfolder/tmp/$cscript"
#!/bin/bash
# sandfox automatic start script
# It is safe to delete this file

$e $bcmd &
EOF
        chmod u+x,go-rwx "$eventsfolder/tmp/$cscript"
        # move start script to events folder
        mv -f "$eventsfolder/tmp/$cscript" "$eventsfolder/$sandname"
        log "Wrote start script $cscript ($bcmd)" "verb"
    fi
fi

if (( optstatus == 1 )); then
    boxstatus
fi

exit

# CHANGELOG:
# 1.1.2:  accomodate change to remount bind usage
#         accomodate change to mtab bind mounts showing type
#         added /dev/nvidia0 & /dev/nvidiactl binds to default profiles
#         added bindro=/opt/firefox to default firefox profile
#         improved detection for 'firefox already running' warning
# 1.1.1:  accomodate recent change to ps line endings
# 1.1.0:  kills dbus-launch inside sandboxes before closing (lsof required)
# 1.0.10: use tmpfs instead of none for mount source (due to new util-linux)
#         skype profile adds /opt/skype and disable note for Gentoo users
# 1.0.9:  permissions on mnt folders
#         removed uuidgen dependency
#         determine sandbox user with Xauthority
#         added default google-earth profile
# 1.0.8:  modification of daemon detection for non-standard ps
#         non-existent --sandbox triggers make
#         corrected --status mount count
# 1.0.7:  added /dev/video0 to skype profile (replaces /dev/video)
#         added disabled Lockdown X Access section to default profile
# 1.0.6:  added firefox bindro for ~/.Xauthority
#         added warning if firefox already running
# 1.0.5:  modification of daemon detection for non-standard ps
# 1.0.4:  corrected detection of running daemon with --verbose and --logfile
# 1.0.3:  corrected problems with sandboxes with similar names
# 1.0.2:  hide non-existent folder corrected
# 1.0.0:  handle /dev/urandom like /dev/random to prevent hangs
# 0.9.6:  Changed tmpfslimit to 100M
#         now allows successful bind=/dev/random for Firefox printing
#         added user-contributed skype profile  (experimental)
