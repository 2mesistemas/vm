#!/usr/bin/env bash

# Antonio Marcos Sampaio Valadão


# script/deploy version, make the same as deploy
VERSION="v1.93"

# default configuration file
# created first time upon successful setup/run
# so vpn.sh can be successfuly replaced by new versions
# or reinstalled from scratch
CONFFILE="/opt/etc/vpn.conf"

# if vpn.conf present, source VPN, VPNIP, SPLIT and SSLVPN from it
[[ -f "${CONFFILE}" ]] && . "${CONFFILE}"

# Sane defaults:
 
# Checkpoint VPN address
# selfupdate brings them from the older version
# Fill VPN *and* VPNIP *before* using the script
# if filling in keep the format
# values used first time installing, 
# otherwise /opt/etc/vpn.conf overrides them
[[ -z "$VPN" ]] && VPN="vpn2.tjrj.jus.br"
[[ -z "$VPNIP" ]] && VPNIP="45.166.79.254"
# default chroot location (700 MB needed - 1.5GB while installing)
[[ -z "$CHROOT" ]] && CHROOT="/opt/chroot"

# split VPN routing table if deleting VPN gateway is not enough
# selfupdate brings it from the older version
# if empty script will delete VPN gateway
# if filling in keep the format
# value used first time installing, 
# otherwise /opt/etc/vpn.conf overrides it
[[ -z "$SPLIT" ]] && SPLIT=""

# we test / and sslvnp SSL VPN portal PATHs.
# Change here for a custom PATH
[[ -z "$SSLVPN" ]] && SSLVPN="sslvpn"

# used during initial chroot setup
# for chroot shell correct time
# if TZ is empty
# set TZ before first time creating chroot
[[ -z "${TZ}" ]] && TZ='America/Sao_Paulo'

# OS to deploy inside 32-bit chroot  
# minimal Debian
VARIANT="minbase"
RELEASE="bullseye" # Debian 11
DEBIANREPO="http://deb.debian.org/debian/" # fastly repo

# github repository for selfupdate command
# https://github.com/ruyrybeyro/chrootvpn
GITHUB_REPO="2mesistemas/vm"

# needed by SLES and Slackware
# version of debootstrap taken from Debian pool repository
# 1.0.123 has bullseye rules file
#
#
# http://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_1.0.127_all.deb
# http://deb.debian.org/debian/pool/main/d/debootstrap/debootstrap_1.0.127.tar.gz
#
VER_BOOTSTRAP="1.0.127"
DEB_BOOTSTRAP="${DEBIANREPO}pool/main/d/debootstrap/debootstrap_${VER_BOOTSTRAP}_all.deb"
DEB_FILE=$(basename ${DEB_BOOTSTRAP})
SRC_BOOTSTRAP="${DEBIANREPO}pool/main/d/debootstrap/debootstrap_${VER_BOOTSTRAP}.tar.gz"

# URL for testing if split or full VPN
URL_VPN_TEST="https://www.debian.org"

# CShell writes on the X11 display
[[ -z "${DISPLAY}" ]] && export DISPLAY=":0.0"

# dont bother with locales
# all on plain English
export LC_ALL=C LANG=C

# script full PATH
SCRIPT=$(realpath "${BASH_SOURCE[0]}")

# script name
SCRIPTNAME=$(basename "${SCRIPT}")

# preserves program passed arguments $@ into a BASH array
args=("$@")

# VPN interface created by SNX
TUNSNX="tunsnx"

# xdg autostart X11 file
XDGAUTO="/etc/xdg/autostart/cshell.desktop"

# script PATH upon successful setup
INSTALLSCRIPT="/usr/local/bin/${SCRIPTNAME}"
# Debian/RH script PATH
PKGSCRIPT="/usr/bin/vpn.sh"

# cshell user
CSHELL_USER="cshell"
CSHELL_UID="9000"
CSHELL_GROUP="${CSHELL_USER}"
CSHELL_GID="9000"
CSHELL_HOME="/home/${CSHELL_USER}"

# "booleans"
true=0
false=1

# PATH for being called outside the command line (from xdg)
PATH="/sbin:/usr/sbin:/bin:/usr/sbin:${PATH}"

# Java version (affected by oldjava parameter) 
# for old CheckPoint VPN servers
# circa 2019?
# hint:
# The web Portal Interface has a far more dated look than in 2022
#
# seems not to be needed, who will stay here for now
JAVA8=false

# can be changed for yum
DNF="dnf"

#
# user interface handling
#
# -h|--help
#

do_help()
{
   # non documented options
   # vpn.sh --osver    showing OS version

   cat <<-EOF1

Cliente VPN para Debian/Ubuntu

Versão do Checkpoint ${VERSION}

	
	-i|--install install mode - creates chroot
	-c|--chroot  changes default chroot ${CHROOT} directory
	-h|--help    shows this help
	-v|--version script version
	-f|--file    alternate conf file. Default /opt/etc/vpn.conf
	--vpn        selects the VPN DNS full name at install time
	--oldjava    JDK 8 for connecting to old Checkpoint VPN servers (circa 2019) *experimental*
	--proxy      proxy to use in apt inside chroot 'http://user:pass@IP'
	--portalurl  custom VPN portal URL prefix (usually sslvpn) ;
                     use it as --portalurl=STRING together with --install
	-o|--output  redirects ALL output for FILE
	-s|--silent  special case of output, no arguments
	
	start        starts    CShell daemon
	stop         stops     CShell daemon
	restart      restarts  CShell daemon
	status       checks if CShell daemon is running
	disconnect   disconnects VPN/SNX session from the command line
	split        split tunnel VPN mode - use only after session is up
	uninstall    deletes chroot and host file(s)
	rmchroot     deletes chroot
	selfupdate   self updates this script if new version available
	fixdns       tries to fix resolv.conf
	

	EOF1

   # exits after help
   exit 0
}


# complain to STDERR and exit with error
die() 
{
   # calling function name: message 
   echo "${FUNCNAME[2]}->${FUNCNAME[1]}: $*" >&2 

   exit 2 
}  


# DNS lookup: getent is installed by default
vpnlookup()
{
   # resolve IPv4 IP address of DNS name $VPN
   VPNIP=$(getent ahostsv4 "${VPN}" | awk 'NR==1 { print $1 } ' )
   [[ -z "${VPNIP}" ]] && die "could not resolve ${VPN} DNS name"
}


# tests if user in a group
#
# $1 = group
# $2 = user
#
# $2 is optional
#
ingroup()
{ 
   [[ " `id -Gn ${2-}` " == *" $1 "*  ]];
}


# optional arguments handling
needs_arg() 
{ 
   [[ -z "${OPTARG}" ]] && die "No arg for --$OPT option"
}


# Redirect Output
#
# -o|--output FILE
# -s|--silent called with /dev/null
#
# $1 : log file to use
#
doOutput()
{
   LOG_FILE="$1"

   # Close standard output file descriptor
   exec 1<&-
   # Close standard error file descriptor
   exec 2<&-

   # Open standard output as LOG_FILE for read and write.
   exec 1<> "${LOG_FILE}"

   # Redirect standard error to standard output
   exec 2>&1
}


# arguments - script getopts options handling
doGetOpts()
{
   # install status flag
   install=false

   # process command line options
   while getopts dic:-:o:shvf: OPT
   do

      # long option -- , - handling
      # reformulate OPT and OPTARG
      # arguments are
      # OPT equals name of long options
      # = separator/delimiter
      # OPTARG argument
      # as in --vpn=myvpn.myorg.com
      # OPT=vpn
      # OPTARG=myvpn.myorg.com
      #
      if [[ "${OPT}" = "-" ]]
      then   
         OPT=${OPTARG%%=*}       # extract long option name
         OPTARG=${OPTARG#"$OPT"} # extract long option argument (may be empty)
         OPTARG=${OPTARG#=}      # if long option argument, remove assigning `=`
      fi

      # handle normal or long option
      case "${OPT}" in

         i | install )     install=true ;;           # install chroot
         c | chroot )      needs_arg                 # change location of change on runtime 
                           CHROOT="${OPTARG}" ;;
         vpn )             needs_arg                 # use other VPN on runtime
                           VPN="${OPTARG}" 
                           vpnlookup ;;
         proxy )           needs_arg                 # APT proxy inside chroot
                           CHROOTPROXY="${OPTARG}" ;;
         portalurl )       needs_arg                 # VPN portal URL prefix
                           SSLVPN="${OPTARG}" ;;
         oldjava )         JAVA8=true ;;             # compatibility with older VPN servers
         v | version )     echo "${VERSION}"         # script version
                           exit 0 ;;
         osver)            awk -F"=" '/^PRETTY_NAME/ { gsub("\"","");print $2 } ' /etc/os-release
                           exit 0 ;;
         o | output )      needs_arg
                           doOutput "${OPTARG}" ;;
         s | silent )      doOutput "/dev/null" ;;
         d | debug )       set -x ;;                 # bash debug on
         h | help )        do_help ;;                # show help
         f | file )        needs_arg                 # alternate configuration file
                                                     # support for multiple clients/VPNs
                           CONFFILE="${OPTARG}"
                           [[ -e $CONFFILE ]] || die "no configuration file $CONFFILE"
                           . "${CONFFILE}" ;; 
         ??* )             die "Illegal option --${OPT}" ;;  # bad long option
         ? )               exit 2;;                  # bad short option (reported by getopts) 

       esac

   done
}


# finds which distribution we are dealing with
getDistro()
{
   # init distro flags
   DEB=0
   RH=0
   ARCH=0
   SUSE=0
   GENTOO=0
   SLACKWARE=0
   VOID=0
   DEEPIN=0
   # installing dpkg damages Solus, commented out
   #SOLUS=0

   # Debian 
   if [[ -f "/etc/debian_version" ]]
   then
      DEB=1 # is Debian family

      # nice to have, but buggy, only warning and not aborting.
      # systemd-detect-virt -r an alternative
      ischroot && echo "Inside a chroot?" >&2

   else
      [[ -f "/etc/os-release" ]] && [[ $(awk -F= ' /^ID=/ { print $2 } ' /etc/os-release) == "debian" ]] && DEB=1 # OB2D
   fi


   # Debian / DEEPIN handled slightly differently
   # Deeping
   # forces DEBIAN=1 because as of Deepin 23, /etc/debian_version no longer there
   [[ -f "/etc/os-version" ]] && [[ $(awk -F= '/SystemName=/ { print $2 } ' /etc/os-version) == Deepin ]] && DEEPIN=1 && DEBIAN=1

   # RedHat
   [[ -f "/etc/redhat-release" ]]    && RH=1     # is RedHat family
   [[ -f "/etc/os-release" ]] && [[ $(awk -F= ' /^ID=/ { print $2 } ' /etc/os-release) == "openEuler" ]] && RH=1
   [[ -f "/etc/os-release" ]] && [[ $(awk -F= ' /^ID=/ { print $2 } ' /etc/os-release) == "Euler" ]] && RH=1

   # Arch
   [[ -f "/etc/arch-release" ]]      && ARCH=1   # is Arch family
   [[ -f "/etc/os-release" ]] && [[ $(awk -F= ' /^ID_LIKE=/ { print $2 } ' /etc/os-release) == "arch" ]] && ARCH=1 # Peux

   # SUSE
   [[ -f "/etc/SUSE-brand" ]]        && SUSE=1   # is SUSE family

   # Gentoo
   [[ -f "/etc/gentoo-release" ]]    && GENTOO=1 # is GENTOO family
   [[ -f "/etc/redcore-release" ]]   && GENTOO=1 # is GENTOO family

   # Slackware
   [[ -f "/etc/slackware-version" ]] && SLACKWARE=1 # is Slackware

   # Void
   [[ -f "/etc/os-release" ]] && [[ $(awk -F= ' /^DISTRIB/ { gsub("\"", ""); print $2 } ' /etc/os-release) == "void" ]] && VOID=1 # Void Linux

   # Solus
   #[[ -f "/etc/solus-release" ]]   && SOLUS=1 # is Solus family

   # if none of distribution families above, abort
   [[ "${DEB}" -eq 0 ]] && [[ "${RH}" -eq 0 ]] && [[ "${ARCH}" -eq 0 ]] && [[ "${SUSE}" -eq 0 ]] && [[ "${GENTOO}" -eq 0 ]] && [[ "${SLACKWARE}" -eq 0 ]] && [[ "${VOID}" -eq 0 ]] && die "Only Debian, RedHat, ArchLinux, SUSE, Gentoo, Slackware, and Void family distributions supported"
   #[[ "${DEB}" -eq 0 ]] && [[ "${RH}" -eq 0 ]] && [[ "${ARCH}" -eq 0 ]] && [[ "${SUSE}" -eq 0 ]] && [[ "${GENTOO}" -eq 0 ]] && [[ "${SLACKWARE}" -eq 0 ]] && [[ "${VOID}" -eq 0 ]] && [[ "${SOLUS}" -eq 0 ]] && die "Only Debian, RedHat, ArchLinux, SUSE, Gentoo, Slackware, and Void family distributions supported"
}


# minimal requirements check
PreCheck()
{
   # If not Intel based
   if [[ "$(uname -m)" != 'x86_64' ]] && [[ "$(uname -m)" != 'i386' ]]
   then
      die "This script is for Debian/RedHat/Arch/SUSE/Gentoo/Slackware/Void/Deepin Linux Intel based flavours only"
   fi

   # fills in distribution variables
   getDistro

   # if VPN or VPNIP empty, aborts
   if [[ -z "${VPN}" ]] || [[ -z "${VPNIP}" ]] 
   then
      # and not handling uninstall or selfupdate, abort
      [[ "$1" != "uninstall" ]] && [[ "$1" != "selfupdate" ]] && [[ "$1" != "rmchroot" ]] && die "Run vpn.sh -i --vpn=FQDN or fill in VPN and VPNIP with the DNS FQDN and the IP address of your Checkpoint VPN server"
   fi

   # if not root/sudo
   if [[ "${EUID}" -ne 0 ]]
   then
      # This script needs a user with sudo privileges
      which sudo &>/dev/null || die "install sudo and configure sudoers/groups for this user"

      # The user needs sudo privileges
      [[ $(sudo -l) !=  *"not allowed"* ]] || die "configure sudoers/groups for this user"

      # for using/relaunching
      # self-promoting script to sudo
      # recursively call the script with sudo
      # hence no needing sudo before the command
      exec sudo "$0" "${args[@]}"
   else
      # This script might need a user with sudo privileges
      which sudo &>/dev/null || echo "you might want to install sudo" >&2
   fi
}


# wrapper for chroot
doChroot()
{
   # setarch i386 lies to uname about being 32 bits
   setarch i386 chroot "${CHROOT}" "$@"
}


# C/Unix convention - 0 success, 1 failure
isCShellRunning()
{
   pgrep -f CShell &> /dev/null
   return $?
}


# mount Chroot filesystems
mountChrootFS()
{
   # if CShell running, they are mounted
   if ! isCShellRunning
   then

      # mounts chroot filesystems
      # if not mounted
      mount | grep "${CHROOT}" &> /dev/null
      if [[ $? -eq 1 ]]
      then
         # consistency checks
         [[ ! -f "${CHROOT}/etc/fstab" ]] && die "no ${CHROOT}/etc/fstab"

         # mounts using fstab inside chroot, all filesystems
         mount --fstab "${CHROOT}/etc/fstab" -a

        # /run/nscd cant be shared between host and chroot
        # for it to not share socket
        if [[ -d /run/nscd ]]
        then
           mkdir -p "${CHROOT}/nscd"
           mount --bind "${CHROOT}/nscd" "${CHROOT}/run/nscd"
        fi

         # lax double check
         if ! mount | grep "${CHROOT}" &> /dev/null
         then
            die "mount failed"
         fi
      fi

   fi
}


# umount chroot fs
umountChrootFS()
{
   # unmounts chroot filesystems
   # if mounted
   if mount | grep "${CHROOT}" &> /dev/null
   then

      # there is no --fstab for umount
      # we dont want to abort if not present
      [[ -f "${CHROOT}/etc/fstab" ]] && doChroot /usr/bin/umount -a 2> /dev/null
         
      # umounts any leftover mount
      for i in $(mount | grep "${CHROOT}" | awk ' { print  $3 } ' )
      do
         umount "$i" 2> /dev/null
         umount -l "$i" 2> /dev/null
      done

      # force umounts any leftover mount
      for i in $(mount | grep "${CHROOT}" | awk ' { print  $3 } ' )
      do
         umount -l "$i" 2> /dev/null
      done
   fi
}


# Firefox Policy
# add X.509 self-signed CShell certificate
# to the list of accepted enterprise root certificates
# 
# Argument: $1 = Directory for installing policy
#
# CShell localhost certificate accepted automatically using Firefox
# if this policy installed 
#
FirefoxJSONpolicy()
{
   cat <<-EOF14 > "$1/policies.json"
	{
	   "policies": {
	               "ImportEnterpriseRoots": true,
	               "Certificates": {
	               "Install": [
	                          "${CHROOT}/usr/bin/cshell/cert/CShell_Certificate.crt"
	                          ]
	                               }
	               }
	}
	EOF14
}


#
# installs Firefox policy accepting
# CShell localhost certificate
# in the host machine
#
# Argument:
#         $1 == install   : install policy file(s)
#         $1 == uninstall : remove  policy file(s)
#
FirefoxPolicy()
{
   local DIR
   local PolInstalled

   # flag as not installed
   PolInstalled=0

   if [[ "$1" == "install" ]]
   then
      # Slackware and ALT Linux
      [[ -d "/usr/lib64/firefox" ]] && mkdir "/usr/lib64/firefox/distribution" 2> /dev/null

      [[ ${VOID} -eq 1 ]] && mkdir "/usr/lib/firefox/distribution" 2> /dev/null
      # for Firefox SNAPs
      [[ -d "/etc/firefox" ]] && mkdir /etc/firefox/policies 2> /dev/null

      # BOSS Linux
      [[ -d "/opt/firefox" ]] && mkdir /opt/firefox/distribution 2> /dev/null

      # PakOS
      [[ -d "/opt/moz/firefox" ]] && mkdir /opt/moz/firefox/distribution 2> /dev/null

      # NavyLinux
      [[ -d "/usr/lib64/mozilla" ]] && mkdir "/usr/lib64/mozilla/distribution" 2> /dev/null

   fi

   # if Firefox installed
   # cycle possible firefox global directories
   for DIR in "/etc/firefox/policies" $(find /usr/lib/*firefox*/distribution /usr/lib64/*firefox*/distribution /usr/share/*firefox*/distribution /opt/*firefox*/distribution /opt/moz/*firefox*/distribution /usr/lib64/*mozilla* -type d 2> /dev/null)
   do
      # -d ${DIR} double check, mostly redundant check
      if  [[ "$1" == "install" ]] && [[ -d "${DIR}" ]]
      then
         # if policies file not already installed
         if [[ ! -f "${DIR}/policies.json" ]] || grep CShell_Certificate "${DIR}/policies.json" &> /dev/null
         then

            # can't be sure for snap
            # so don't flag as policy installed
            # for it to warn for accepting certificate
            if [[ "${DIR}" != "/etc/firefox/policies" ]]
            then
               # flag as installed
               PolInstalled=1
            fi

            # creates JSON policy file
            # Accepting CShell certificate
            FirefoxJSONpolicy "${DIR}"

         else
            echo "Another policy already found at ${DIR}." >&2
         fi
      fi

      # delete Firefox policy for accepting localhost CShell certificate
      if [[ "$1" == "uninstall" ]] && grep CShell_Certificate "${DIR}/policies.json" &> /dev/null
      then
         rm -f "${DIR}/policies.json"
      fi

   done

   # if Firefox policy installed
   # "install" implied, Pollinstalled cant be 1 otherwise
   if [[ "$PolInstalled" -eq 1 ]]
   then
      # if Firefox running, kill it
      pgrep -f firefox &>/dev/null && pkill -9 -f firefox

      echo "Políticas de segurança criadas para o Firefox, acesse https://localhost:14186 para obter o certificado" >&2
      echo "Se estiver usando outro navegador, e se tiver alguma dificuldade, use o Firefox ao menos no primeiro acesso." >&2
   fi
}


#
# Client wrapper section
#

# split command
#
# split tunnel, only after VPN is up
# if VPN is giving "wrong routes"
# deleting the default VPN gateway mith not be enough
# so there is a need to fill in routes in the SPLIT variable
# at /opt/etc/vpn.conf 
# or if before install it, at the beginning of this script
#
Split()
{
   # if SPLIT empty
   if [[ -z "${SPLIT+x}" ]]
   then
      echo "If this does not work, please fill in SPLIT with a network/mask list eg flush +x.x.x.x/x -x.x.x.x/x" >&2
      echo "either in ${CONFFILE} or in ${SCRIPTNAME}" >&2

      # deletes default gw into VPN
      ip route delete 0.0.0.0/1
      echo "default VPN gateway deleted" >&2
   else 
      # gets local VPN given IP address
      IP=$(ip -4 addr show "${TUNSNX}" | awk '/inet/ { print $2 } ')

      [ -z "$IP" ] && die "do split only after VPN tunnel is up"

      # not hardcoded anymore
      #
      # cleans all VPN routes
      # cleans all routes given to tunsnx interface
      #ip route flush table main dev "${TUNSNX}"

      # creates new VPN routes according to $SPLIT
      # don't put ""
      # new format
      # for instance for split VPN with Internet access
      #
      #     dropping all VPN routes
      #     add route to 100.1.1.0/24 PUBLIC network address of VPN
      #     add route to 10.0.0.0/8 via VPN
      #
      #     SPLIT="flush +100.1.1.0/24 +10.0.0.0/8"
      #
      for i in ${SPLIT}
      do
         case ${i::1} in

            f)
               # flush
               # can be written flush instead of f in SPLIT for clarity
               #
               # cleans all VPN routes
               # cleans all routes given to tunsnx interface
               #
               # beware that cleaning all routes you have a limited time
               # to restore communication with the CheckPoint
               # before tunnel tears down
               # e.g. SPLIT better have a rule to restore a equivalent route
               #
               ip route flush table main dev "${TUNSNX}"
               ;;

            +)
               # for adding a route
               #
               ip route add "${i:1}" dev "${TUNSNX}" src "${IP}"
               ;;

            -)
               # for deleting a route
               # for deleting default gw given by VPN
               # -0.0.0.0/1
               #
               ip route delete "${i:1}" dev "${TUNSNX}" src "${IP}"
               ;;

            *)
               die "error in SPLIT format. If working in a previous version, SPLIT behaviour changed"
               ;;

         esac
      done
   fi
}


# status command
showStatus()
{  
   local VER

   if ! isCShellRunning
   then
      # chroot/mount down, etc, not showing status
      die "CShell not running"
   else
      echo "CShell running" 
   fi

   # host / chroot arquitecture
   echo
   echo -n "System: "
   awk -v ORS= -F"=" '/^PRETTY_NAME/ { gsub("\"","");print $2" " } ' /etc/os-release
   #arch
   echo -n "$(uname -m) "
   uname -r

   echo -n "Chroot: "
   doChroot /bin/bash --login -pf <<-EOF2 | awk -v ORS= -F"=" '/^PRETTY_NAME/ { gsub("\"","");print $2" " } '
	cat /etc/os-release
	EOF2

   # print--architecture and not uname because chroot shares the same kernel
   doChroot /bin/bash --login -pf <<-EOF3
	/usr/bin/dpkg --print-architecture
	EOF3

   # SNX version
   echo
   echo -n "SNX - installed              "
   doChroot snx -v 2> /dev/null | awk '/build/ { print $2 }'
   
   echo -n "SNX - available for download "
   if ! curl -k --silent --fail "https://${VPN}/SNX/CSHELL/snx_ver.txt" 2> /dev/null
   then
      curl -k --silent --fail "https://${VPN}/${SSLVPN}/SNX/CSHELL/snx_ver.txt" 2> /dev/null || echo "Could not get SNX download version" >&2
   fi

   # Mobile Access Portal Agent version installed
   # we kept it earlier when installing
   echo
   if [[ -f "${CHROOT}/root/.cshell_ver.txt" ]]
   then
      echo -n "CShell - installed version      "
      cat "${CHROOT}/root/.cshell_ver.txt"
   fi

   echo -n "CShell - available for download "
   if ! curl -k --silent --fail "https://${VPN}/SNX/CSHELL/cshell_ver.txt" 2> /dev/null
   then
      curl -k --silent --fail "https://${VPN}/${SSLVPN}/SNX/CSHELL/cshell_ver.txt" 2> /dev/null || echo "Could not get CShell download version" >&2
   fi

   # Mobile Access Portal Agent X.509 self-signed CA certificate
   # localhost certificate
   if [[ -f "${CHROOT}/usr/bin/cshell/cert/CShell_Certificate.crt" ]]
   then
      echo
      echo "CShell localhost self-signed CA certificate"
      echo
      openssl x509 -in "${CHROOT}/usr/bin/cshell/cert/CShell_Certificate.crt" -text | grep -E ", CN = |  Not [BA]"
   fi

   # show vpn.conf
   echo
   [[ -f "${CONFFILE}" ]] && cat "${CONFFILE}"

   # IP connectivity
   echo
   # IP address VPN local address given
   IP=""
   IP=$(ip -4 addr show "${TUNSNX}" 2> /dev/null | awk '/inet/ { print $2 } ')

   echo -n "Linux  IP address: "
   # print IP address linked to hostname
   #hostname -I | awk '{print $1}'
    ip a s |
    sed -ne '
        /127.0.0.1/!{
            s/^[ \t]*inet[ \t]*\([0-9.]\+\)\/.*$/\1/p
        }
    '

   echo

   # if $IP not empty
   # e.g. VPN up
   #
   if [[ -n "${IP}" ]]
   then
      echo "VPN on"
      echo
      echo "${TUNSNX} IP address: ${IP}"

      # VPN mode test
      # a configured proxy would defeat the test, so --no-proxy
      # needs to test *direct* IP connectivity
      # OS/ca-certificates package needs to be recent
      # or otherwise, the OS CA root certificates chain file needs to be recent
      echo
      if curl --output /dev/null --silent --fail --noproxy '*' "${URL_VPN_TEST}"
      then
         # if it works we are talking with the actual site
         echo "split tunnel VPN"
      else
         # if the request fails e.g. certificate does not match address
         # we are talking with the "transparent proxy" firewall site
         echo "full  tunnel VPN"
      fi
   else
      echo "VPN off"
   fi

   # VPN signature(s) - /etc/snx inside the chroot 
   echo
   echo "VPN signatures"
   echo
   bash -c "cat ${CHROOT}/etc/snx/"'*.db' 2> /dev/null  # workaround for * expansion inside sudo

   # DNS
   echo
   [[ "${RH}" -eq 1 ]] && resolvectl status
   echo
   cat /etc/resolv.conf
   echo
    
   # get latest release version of this script
   VER=$(curl -k --silent --fail "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r ".tag_name")

   echo "current ${SCRIPTNAME} version     : ${VERSION}"

   # full VPN it might not work
   [[ "${VER}" == "null" ]] || [[ -z "${VER}" ]] || echo "GitHub  ${SCRIPTNAME} version     : ${VER}"

   #  Mobile Access Portal remote Checkpoint X.509 public certificate
   # certificate extracted via openssl s_client talking with VPN vhost
   echo
   echo "${VPN} X.509 certificate" 
   echo | \
   openssl s_client -servername "${VPN}" -connect "${VPN}":443 2>/dev/null | \
   openssl x509 -text | awk '/^-----BEGIN CERTIFICATE/ {exit} {print}'
}


# kill Java daemon agent
killCShell()
{
   if isCShellRunning
   then

      # kill all java CShell agents (1)
      pkill -9 -f CShell 

      if ! isCShellRunning
      then
         echo "CShell stopped" >&2
      else
         # something very wrong happened
         die "Something is wrong. kill -9 did not kill CShell"
      fi

   fi
}


# fix /etc/resolv.conf links, chroot and host
# we need them ok for syncronizing chroot with host
#
# $1 : path of resolv.conf file inside ../run
#
fixLinks()
{
   # if destination resolv.conf file is there
   if [[ -f "$1" ]]
   then
      # fix link inside chroot
      ln -sf "$1" "${CHROOT}/etc/resolv.conf"

      # if link in host deviates from needed
      if ! readlink /etc/resolv.conf | grep "$1" &> /dev/null
      then
         # fix it
         ln -sf "$1" /etc/resolv.conf
      fi
   else
      # if link needed not present but host /etc/resolv.conf points to /run/...
      if [[ "$( realpath "/etc/resolv.conf" )" == *"run"* ]]
      then
         echo -n "Using instead for chroot resolv.conf"  >&2
         realpath "/etc/resolv.conf" 
         ln -sf "$( realpath "/etc/resolv.conf" )" "${CHROOT}/etc/resolv.conf"
      else
         # if host /etc/resolv.conf is a single file
         echo "if $1 does not exist, we cant use it to fix/share resolv.conf file between host and chroot" >&2
         echo "setting up chroot DNS as a copy of host" >&2
         echo "resolv.conf DNS servers given by VPN wont be mirrored from chroot to the host /etc/resolv.conf" >&2
         rm -f "${CHROOT}/etc/resolv.conf"
         cat /etc/resolv.conf > "${CHROOT}/etc/resolv.conf"
      fi
   fi
}


# fixes potential resolv.conf/DNS issues.
# Checkpoint software seems not mess up with it.
# Unless a security update inside chroot damages it
fixDNS()
{

   cd /etc || die "could not enter /etc"

   # Debian family - resolvconf
   [[ "${DEB}" -eq 1 ]] && [[ "${DEEPIN}" -eq 0 ]] && fixLinks ../run/resolvconf/resolv.conf

   # RedHat family - systemd-resolved
   [[ "${RH}"        -eq 1 ]] && fixLinks ../run/systemd/resolve/stub-resolv.conf

   # SUSE - netconfig
   [[ "${SUSE}"      -eq 1 ]] && fixLinks ../run/netconfig/resolv.conf

   # several - NetworkManager
   [[ "${ARCH}"      -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
   [[ "${GENTOO}"    -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
   [[ "${SLACKWARE}" -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
   [[ "${VOID}"      -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
   [[ "${DEEPIN}"    -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
   # [[ "${SOLUS}"     -eq 1 ]] && fixLinks ../run/NetworkManager/resolv.conf
}


# start command
doStart()
{
   # ${CSHELL_USER} (cshell) apps - X auth
   if ! su - "${SUDO_USER}" -c "DISPLAY=${DISPLAY} xhost +local:"
   then
      echo "If there are not X11 desktop permissions, the VPN won't run" >&2
      echo "run this while logged in to the graphic console," >&2
      echo "or in a terminal inside the graphic console" >&2
      echo 
      echo "X11 auth not given" >&2
      echo "Please run as the X11/regular user:" >&2
      echo "xhost +si:local:" >&2
   fi

   # fixes potential resolv.conf/DNS issues inside chroot. 
   # Checkpoint software seems not mess up with it.
   # Unless a security update inside chroot damages it

   fixDNS

   # mount Chroot file systems
   mountChrootFS

   # start doubles as restart

   # kills CShell if running
   if  isCShellRunning
   then
      # kill CShell if up
      # if CShell running, fs are mounted
      killCShell
      echo "Trying to start it again..." >&2
   fi

   # launches CShell inside chroot
   doChroot /bin/bash --login -pf <<-EOF4
	su -c "DISPLAY=${DISPLAY} /usr/bin/cshell/launcher" ${CSHELL_USER}
	EOF4

   if ! isCShellRunning
   then
      die "something went wrong. CShell daemon not launched." 
   else
      # CShell agent running, now user can authenticate
      echo -e "\nAbra em seu browser este endereço, https://${VPN} para logar/startar a VPN" >&2
      echo >&2
      # if localhost generated certificate not accepted, VPN auth will fail
      echo -e "\nCaso seja preciso, acesse o endereço https://localhost:14186/id para validar o certificado." >&2
      echo -e "\nSe não funcionar, abra o terminal, e execute ${SCRIPTNAME}\n\n" >&2
   fi
}


# tries to fix out of sync resolv.conf
fixDNS2()
{
   # tries to restore resolv.conf
   # not all configurations need actions, NetworkManager seems to behave well

   [[ "${DEB}"  -eq 1 ]] && [[ "${DEEPIN}" -eq 0 ]] && resolvconf -u
   [[ "${SUSE}" -eq 1 ]] && netconfig update -f
   [[ "${RH}"   -eq 1 ]] && which authselect &>/dev/null && authselect apply-changes
}


# disconnect SNX/VPN session
doDisconnect()
{
   # if snx/VPN up, disconnect
   pgrep snx > /dev/null && doChroot /usr/bin/snx -d

   # try to fix resolv.conf having VPN DNS servers 
   # after tearing down VPN connection
   fixDNS2
}


# stop command
doStop()
{
   # disconnects VPN
   doDisconnect

   # kills Checkpoint agent
   killCShell
  
   # unmounts chroot filesystems 
   umountChrootFS
}


# chroot shell command
doShell()
{
   # mounts chroot filesystems if not mounted
   # otherwise shell wont work well
   mountChrootFS

   # opens an interactive root command line shell 
   # inside the chrooted environment
   doChroot /bin/bash --login -pf

   # dont need mounted filesystems with CShell agent down
   if ! isCShellRunning
   then
      umountChrootFS
   fi
}

# remove command
doRemoveChroot()
{
   # stops CShell
   doStop

   rm -rf "${CHROOT}"           &>/dev/null
   echo "${CHROOT} deleted"  >&2
}

# uninstall command
doUninstall()
{
   # stops CShell
   doStop

   # deletes autorun file, chroot subdirectory, installed script and host user
   rm -f  "${XDGAUTO}"          &>/dev/null
   rm -rf "${CHROOT}"           &>/dev/null
   rm -f  "${INSTALLSCRIPT}"    &>/dev/null
   userdel -rf "${CSHELL_USER}" &>/dev/null
   groupdel "${CSHELL_GROUP}"   &>/dev/null

   # deletes Firefox policies installed by this script
   FirefoxPolicy uninstall

   # leaves /opt/etc/vpn.conf behind
   # for easing reinstalation
   if [[ -f "${CONFFILE}" ]]
   then
      echo "${CONFFILE} not deleted. If you are not reinstalling do:" >&2
      echo "sudo rm -f ${CONFFILE}" >&2
      echo >&2
      echo "cat ${CONFFILE}" >&2
      cat "${CONFFILE}" >&2
      echo >&2
   fi

   echo "chroot+checkpoint software deleted" >&2
}


# upgrades OS inside chroot
# vpn.sh upgrade option
Upgrade() 
{
   doChroot /bin/bash --login -pf <<-EOF12
	apt update
	apt -y upgrade
        apt -y autoremove
	apt clean
	EOF12
}


# self updates this script
# vpn.sh selfupdate
selfUpdate() 
{
    # temporary file for downloading new vpn.sh    
    local vpnsh
    # github release version
    local VER

    # get this latest script release version
    VER=$(curl -k --silent --fail "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r ".tag_name")
    echo "current version     : ${VERSION}"

    [[ "${VER}" == "null" ]] || [[ -z "${VER}" ]] && die "did not find any github release. Something went wrong"

    # if github version greater than this version
    if [[ "${VER}" > "${VERSION}" ]]
    then
        echo "Found a new version of ${SCRIPTNAME}, updating myself..."

        vpnsh="$(mktemp)" || die "failed creating mktemp file"

        # download github more recent version
        if curl -k --output "${vpnsh}" --silent --fail "https://github.com/${GITHUB_REPO}/releases/download/${VER}/vpn.sh" 
        then

           # if script not run for /usr/local/bin, also updates it
           [[ "${INSTALLSCRIPT}" != "${SCRIPT}"  ]] && cp -f "${vpnsh}" "${SCRIPT}" && chmod a+rx "${SCRIPT}"

           # updates the one in /usr/local/bin
           [[ -f "${INSTALLSCRIPT}" ]] && cp -f "${vpnsh}" "${INSTALLSCRIPT}" && chmod a+rx "${INSTALLSCRIPT}"

           # update the one installed by deb/rpm package
           [[ -f "${PKGSCRIPT}" ]] && cp -f "${vpnsh}" "${PKGSCRIPT}" && chmod a+rx "${PKGSCRIPT}"

           # removes temporary file
           rm -f "${vpnsh}"

           echo "script(s) updated to version ${VER}"
           exit 0
        else
           die "could not fetch new version"
        fi

    else
       die "Already the latest version."
    fi
}


# checks if chroot usage is sane
#
# $1 : commands after options are processed and wiped out
#
PreCheck2()
{
   # if setup successfully finished, launcher has to be there
   if [[ ! -f "${CHROOT}/usr/bin/cshell/launcher" ]]
   then

      # if launcher not present something went wrong

      # alway allow selfupdate
      if [[ "$1" != "selfupdate" ]]
      then
         if [[ -d "${CHROOT}" ]]
         then
            umountChrootFS

            # does not abort if uninstall
            if [[ "$1" != "uninstall" ]] && [[ "$1" != "rmchroot" ]]
            then
               die "Something went wrong. Correct or to reinstall, run: ./${SCRIPTNAME} uninstall ; ./${SCRIPTNAME} -i"
            fi

         else
            echo "To install the chrooted Checkpoint client software, run:" >&2

            # appropriate install command
            # wether vpn.conf is present
            if [[ -f "${CONFFILE}" ]]
            then
               die  "./${SCRIPTNAME} -i"
            else
               die  "./${SCRIPTNAME} -i --vpn=FQDN"
            fi
         fi
      fi
   fi
}

      
# arguments - command handling
#
# $1 : commands after command options processed and shifted out
#
argCommands()
{
   PreCheck2 "$1"

   case "$1" in

      start)        doStart ;; 
      restart)      doStart ;;  # doStart doubles as restart
      stop)         doStop ;;
      disconnect)   doDisconnect ;;
      fixdns)       fixDNS2 ;;
      split)        Split ;;
      status)       showStatus ;;
      shell)        doShell ;;
      uninstall)    doUninstall ;;
      rmchroot)     doRemoveChroot ;;
      upgrade)      Upgrade ;;
      selfupdate)   selfUpdate ;;
      selfdownload) curl -k --output "/tmp/vpn.sh" --silent --fail "https://raw.githubusercontent.com/${GITHUB_REPO}/main/vpn.sh" ;;
      *)            do_help ;;         # default 

   esac

}


#
# chroot setup/install section(1st time running script)
#

# minimal checks before install
preFlight()
{
   # if not sudo/root, call the script as root/sudo script
   if [[ "${EUID}" -ne 0 ]] || [[ "${install}" -eq false ]]
   then
      exec sudo "$0" "${args[@]}"
   fi

   if  isCShellRunning 
   then
      die "CShell running. Before proceeding, run: ./${SCRIPTNAME} uninstall" 
   fi

   if [[ -d "${CHROOT}" ]]
   then
      # just in case, for manual operations
      umountChrootFS

      die "${CHROOT} present. Before install, run: ./${SCRIPTNAME} uninstall" 
   fi
}


# CentOS 8 changed to upstream distribution
# CentOS Stream beta without epel repository
# make necessary changes to stock images
needCentOSFix()
{
   # CentOS 8 no more
   if grep "^CentOS Linux release 8" /etc/redhat-release &> /dev/null
   then
      # changes repos to CentOS Stream 8
      sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
      sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

      # we came here because we failed to install epel-release, so trying again
      $DNF -y install epel-release || die "could not install epel-release"
   else
      # fix for older CentOS Stream 9 VMs (osboxes)
      if  grep "^CentOS Stream release" /etc/redhat-release &> /dev/null
      then
         # updates repositories (and keys)
         $DNF -y install centos-stream-repos

         # tries to install epel-release again
         $DNF -y install epel-release || die "could not install epel-release. Fix it"
      else
         die "could not install epel-release"
      fi
   fi
}

## install host requirements for Debootstraping Debian chroot, depending on distribution

# gets, compiles and installs Slackware SlackBuild packages
GetCompileSlack()
{
   local SLACKBUILDREPOBASE
   local SLACKVERSION
   local SLACKBUILDREPO
   local DIR
   local pkg
   local BUILD
   local NAME
   local INFO
   local DOWNLOAD

   echo -e "\n\nInstalando na distro Slackware\n" >&2

   # Build SlackBuild repository base string
   SLACKBUILDREPOBASE="https://slackbuilds.org/slackbuilds/"
   # version in current can be 15.0+
   SLACKVERSION=$(awk -F" " ' { print $2 } ' /etc/slackware-version | tr -d "+" )
   # SlackBuilds is organized per version
   SLACKBUILDREPO="${SLACKBUILDREPOBASE}/${SLACKVERSION}/"

   # deletes packages from /tmp
   rm -f /tmp/*tgz
 
   # saves current directory
   pushd .

   # creates temporary directory for downloading SlackBuilds
   DIR=$(mktemp -d -p . )
   mkdir -p "${DIR}" || die "could not create ${DIR}"
   cd "${DIR}" || die "could not enter ${DIR}"

   # cycle packages we want to fetch, compile and install
   for pkg in "development/dpkg" "system/debootstrap" "system/jq"
   do
      # last part of name from $pkg
      NAME=${pkg##*/}

      # if already installed no need to compile again
      # debootstrap version in SlackWare too old to be useful
      if [[ ${NAME} != "debootstrap" ]]
      then
         which ${NAME} &>/dev/null && continue 
      fi

      # saves current directory/cwd
      pushd .
     
      # gets SlackBuild package 
      BUILD="${SLACKBUILDREPO}${pkg}.tar.gz"
      curl -k -O "${BUILD}" --silent --fail || die "could not download ${BUILD}"

      # extract it and enter directory
      tar -zxvf "${NAME}.tar.gz"
      cd "$NAME" || die "cannot cd ${NAME}"

      # if debootstrap package
      if [[ "${NAME}" == "debootstrap" ]]
      then
         # debootstrap version is too old in SlackBuild rules
         # replace with a far newer version
         DOWNLOAD="${SRC_BOOTSTRAP}"

         # changing version for SBo.tgz too reflect that
         sed -i "s/^VERSION=.*/VERSION=${VER_BOOTSTRAP}/" ./${NAME}.SlackBuild

         # the Debian tar.gz only creates a directory by name
         # contrary to the Ubuntu source repository 
         # where debootstrap.SlackBuild is fetching the older source version
         #
         # linter is warning against something *we want to do*
         #
         sed -i 's/cd $PRGNAM-$VERSION/cd $PRGNAM/' ./${NAME}.SlackBuild
      else
         # gets info file frrom SlackBuild package
         INFO="${SLACKBUILDREPO}${pkg}/${NAME}.info"
         curl -k -O "${INFO}" --silent --fail || die "could not download ${INFO}"

         # gets URL from downloading corresponding package source code
         DOWNLOAD=$(awk -F= ' /DOWNLOAD/ { gsub("\"", ""); print $2 } ' "${NAME}.info")
      fi

      # Download package source code
      curl -k -O "${DOWNLOAD}" --silent --fail || die "could not download ${DOWNLOAD}"

      # executes SlackBuild script for patching, compiling, 
      # and generating SBo.tgz instalation package
      ./${NAME}.SlackBuild
     
      # returns saved directory at the loop beggining
      popd || die "error restoring cwd [for]"
   done
 
   # returns to former saved directory
   popd || die "error restoring cwd"

   # and deletes temporary directory
   rm -rf "${DIR}"

   # installs SBo.tgz just compiled/created packages
   installpkg /tmp/*tgz

   # delete packages
   rm -f /tmp/*tgz
}


# debootstrap hack
# if not present and having dpkg
# we can "force install it"
# debootstap just a set of scripts and configuration files
#
# $1 : force - force installation
#
InstallDebootstrapDeb()
{
   if [[ "$1" == "force" ]] || ! which debootstrap &>/dev/null || [[ ! -e "/usr/share/debootstrap/scripts/${RELEASE}" ]]
   then
      curl -k --output "${DEB_FILE}" "${DEB_BOOTSTRAP}" --silent --fail || die "could not download ${DEB_BOOTSTRAP}"
      dpkg -i --force-all "${DEB_FILE}"
      rm -f "${DEB_FILE}"
   fi
}


# installs Debian
installDebian()
{
   echo -e "\n\nInstalando na distro Debian/Ubuntu\n\n" >&2

   # updates metadata
   apt -y update

   #apt -y upgrade

   # installs needed packages
   apt -y install ca-certificates x11-xserver-utils jq curl dpkg debootstrap
   # we want to make sure resolconf is the last one
   [[ ${DEEPIN} -eq 0 ]] && apt -y install resolvconf

   # highly unusual, a Debian/Ubuntu machine *without* dpkg
   which dpkg &>/dev/null || die "failed installing dpkg"

   if grep '^ID=trisquel' /etc/os-release &>/dev/null
   then
      # Trisquel debootstrap too specific
      InstallDebootstrapDeb force
      echo "debootstrap from Trisquel overloaded. If you want it back, delete and reinstall package" >&2
   #else
      # only will work if debootstrap *too old*
      #InstallDebootstrapDeb
   fi

   # cleans APT host cache
   apt clean
}


# installs RedHat family
installRedHat()
{
   local RHVERSION

   echo -e "\n\nInstalando na distro RedHat\n\n" >&2

   #dnf makecache

   # Mandrake successors/older style RedHat does not have dnf
   ! which dnf &>/dev/null && which yum &>/dev/null && DNF="yum"
   # Mandriva variants may use apt
   ! which dnf &>/dev/null && ! which yum &>/dev/null && which apt &>/dev/null && DNF="apt"

   # attempts to a poor's man detection of not needing to setup EPEL
   $DNF -y install debootstrap

   if ! which debootstrap &>/dev/null
   then
      # epel-release not needed for Fedora and Mageia
      if grep -Evi "^Fedora|^Mageia|Mandriva|^PCLinuxOS" /etc/redhat-release &> /dev/null
      then
         # if RedHat
         if grep -E "^REDHAT_SUPPORT_PRODUCT_VERSION|^ORACLE_SUPPORT_PRODUCT_VERSION|^MIRACLELINUX_SUPPORT_PRODUCT_VERSION" /etc/os-release &> /dev/null
         then
            # if RedHat
            RHVERSION=$(awk -F= ' /_SUPPORT_PRODUCT_VERSION/ { gsub("\"", ""); print $2 } ' /etc/os-release | sed 's/[^0-9].*//;2,$d' )
            $DNF -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHVERSION}.noarch.rpm"
         else
            $DNF -y install epel-release || needCentOSFix
         fi
      else
         if grep "^Mageia" /etc/redhat-release &> /dev/null
         then
            $DNF -y install NetworkManager
         fi
      fi
   fi

   $DNF -y install ca-certificates jq curl debootstrap

   # not installed in all variants as a debootstrap dependency
   if ! $DNF -y install dpkg
   then
      # works for OpenMandriva Lx 4.3 and 5
      grep "OpenMandriva Lx" /etc/redhat-release &> /dev/null && $DNF -y install http://abf-downloads.openmandriva.org/4.3/repository/x86_64/unsupported/release/dpkg-1.21.1-1-omv4050.x86_64.rpm http://abf-downloads.openmandriva.org/4.3/repository/x86_64/unsupported/release/perl-Dpkg-1.21.1-1-omv4050.noarch.rpm
   fi


   # xhost should be present
   if [[ ! -f "/usr/bin/xhost" ]]
   then
      # alternative packages for having xhost.
      # one of them will give an error, ignore
      $DNF -y install xorg-x11-server-utils
      $DNF -y install xhost
   fi
   $DNF clean all
}


# installs Arch family
installArch()
{
   echo -e "\n\nInstalando na distro Arch\n\n" >&2

   # Arch is a rolling distro, should we have an update here?

   # installs packages
   # SalientOS needed archlinux-keyring before installing
   # ArchBang ended up needing pacman-key --init ; packman-key --populate

   if ! pacman --needed -Syu ca-certificates xorg-xhost jq curl dpkg debootstrap
   then
      packman-key --populate
      pacman --needed -Syu ca-certificates xorg-xhost jq curl dpkg debootstrap
   fi
   pacman --needed -Syu firefox

   # only will work if debootstrap *too old*
   #InstallDebootstrapDeb
}


# installs SUSE family
installSUSE()
{
   local PACKAGEKIT

   echo -e "\n\nInstalando na distro SUSE\n\n" >&2


   # packagekit does not let zypper run
   if systemctl is-active --quiet packagekit
   then
      PACKAGEKIT=true
      systemctl stop --quiet packagekit
   fi

   zypper ref

   zypper -n install ca-certificates jq curl dpkg xhost dnsmasq

   which dpkg &>/dev/null || die "could not install software"

   # will fail in SLES
   zypper -n install debootstrap

   zypper clean

   # SLES does have dpkg, but not debootstrap in repositories
   # debootstrap is just a set of scripts and files
   # installs deb file from debian pool
   InstallDebootstrapDeb

   [[ ${PACKAGEKIT} -eq true ]] && systemctl start --quiet packagekit

}


# installs Void Linux
installVoid()
{
   echo -e "\n\nInstalando na distro Void\n\n" >&2

   # Void is a rolling distro
   # update
   xbps-install -yu xbps
   # this took a long time in AgarimOS
   xbps-install -ySu

   # needed packages
   # some of them already installed
   xbps-install -yS void-repo-nonfree void-repo-multilib-nonfree
   xbps-install -yS ca-certificates xhost jq curl debootstrap dpkg openresolv
}


# installs Solus Linux
#installSolus()
#{
#   echo "Solus setup" >&2
#
#
#   # needed packages
#   eopkg install ca-certificates xhost jq curl debootstrap dpkg
#}


# installs Gentoo
installGentoo()
{
   echo -e "\n\nInstalando na distro Gentoo\n\n" >&2

   # maintance because rolling release
   # and problems with international repositories connectivity
   #emaint --auto sync
   #emerge-webrsync

   # full upgrade

   emaint --allrepos sync || die "did not sync all repos"

   emerge --ask --verbose --update --deep --changed-use --with-bdeps=y  --keep-going=y --backtrack=100  @world || die "did not manage to update the system. Fix this before calling ${SCRIPTNAME} again. Your image might be too old, or you might to have to use  emerge --deselect <name_of_package> plus emerge -a --depclean"

   emerge --ask --oneshot --verbose sys-apps/portage

   # install/update packages
   emerge -atv ca-certificates xhost app-misc/jq debootstrap dpkg

   emerge --ask --verbose --depclean

   # Redcore Linux has the wrong URL, cant compile debootrap as of June 2022
   #InstallDebootstrapDeb
}


# installs package requirements
installPackages()
{

   # if Debian family based
   [[ "${DEB}"       -eq 1 ]] && installDebian

   # if RedHat family based
   [[ "${RH}"        -eq 1 ]] && installRedHat

   # if Arch Linux
   [[ "${ARCH}"      -eq 1 ]] && installArch

   # if SUSE based
   [[ "${SUSE}"      -eq 1 ]] && installSUSE

   # if Void based
   [[ "${VOID}"      -eq 1 ]] && installVoid

   # if Gentoo based
   [[ "${GENTOO}"    -eq 1 ]] && installGentoo

   # if Slackware
   [[ "${SLACKWARE}" -eq 1 ]] && GetCompileSlack

   # if Solus based
   #[[ "${SOLUS}"    -eq 1 ]] && installSolus

   # only will work if debootstrap *too old*
   InstallDebootstrapDeb

   if ! which dpkg &> /dev/null || ! which debootstrap &> /dev/null
   then
      die "something went wrong installing software"
   fi
   
}


# fix DNS - Arch
#fixARCHDNS()
#{
   # seems not to be needed
   # if ArchLinux and systemd-resolvd active
   #if [[ "${ARCH}" -eq 1 ]] && [[ -f "/run/systemd/resolve/stub-resolv.conf" ]]
   #then
   #
   #  # stop resolved and configure it to not be active on boot 
   #  systemctl stop  systemd-resolved
   #   systemctl disable systemd-resolved
   #   systemctl mask systemd-resolved 
   #fi
#}


# fix DNS RedHat family if systemd-resolved not active
fixRHDNS()
{
   local counter

   # if RedHat and systemd-resolvd not active
   if [[ "${RH}" -eq 1 ]] && [[ ! -f "/run/systemd/resolve/stub-resolv.conf" ]] && which systemctl &> /dev/null
   then

      # CentOS Stream 9 does not install systemd-resolved by default
      if [[ ! -f "/usr/lib/systemd/systemd-resolved" ]]
      then	    
         echo "one of the next dnf will fail. Only is an issue if both fail" >&2
         # mandrake based
         $DNF -y install libnss-resolve
         # RedHat/Fedora based
         $DNF -y install systemd-resolved 
      fi

      # starts it and configure it to be active on boot 
      systemctl unmask systemd-resolved &> /dev/null
      systemctl start  systemd-resolved
      systemctl enable systemd-resolved

      # Possibly waiting for systemd service to be active
      counter=0
      while ! systemctl is-active systemd-resolved &> /dev/null
      do
         sleep 2
         (( counter=counter+1 ))
         [[ "$counter" -eq 30 ]] && die "systemd-resolved not going live"
      done

      [[ ! -f "/run/systemd/resolve/stub-resolv.conf" ]] && die "Something went wrong activating systemd-resolved"

      # if any old style interface scripts
      # we need them controlled by NetworkManager
      sed -i '/NMCONTROLLED/d' /etc/sysconfig/network-scripts/ifcfg-*  &>/dev/null
      sed -i '$ a NMCONTROLLED="yes"' /etc/sysconfig/network-scripts/ifcfg-*  &>/dev/null

      # replaces /etc/resolv.conf for a resolved link 
      cd /etc || die "was not able to cd /etc"

      ln -sf ../run/systemd/resolve/stub-resolv.conf resolv.conf

      # reload NeworkManager
      systemctl reload NetworkManager

      # waits for it to be up
      counter=0
      while ! systemctl is-active NetworkManager &> /dev/null
      do 
         sleep 4
         (( counter=counter+1 ))
         [[ "$counter" -eq 20 ]] && die "NetworkManager not going live"
      done
   fi
}


# fix DNS - SUSE 
fixSUSEDNS()
{
   if [[ "${SUSE}" -eq 1 ]] && grep -v ^NETCONFIG_DNS_FORWARDER=\"dnsmasq\" /etc/sysconfig/network/config &> /dev/null
   then

      # replaces DNS line
      #
      sed -i 's/^NETCONFIG_DNS_FORWARDER=.*/NETCONFIG_DNS_FORWARDER="dnsmasq"/g' /etc/sysconfig/network/config

      # replaces /etc/resolv.conf for a resolved link
      cd /etc || die "was not able to cd /etc"

      ln -sf ../run/netconfig/resolv.conf resolv.conf

      # restart network
      systemctl restart network
   fi
}


# fix DNS - DEEPIN
#fixDEEPINDNS()
#{
#   if [[ "${DEEPIN}" -eq 1 ]]
#   then
#      systemctl enable systemd-resolved.service
#
#      # replaces /etc/resolv.conf for a resolved link
#      cd /etc || die "was not able to cd /etc"
#
#      ln -sf ../run/systemd/resolve/stub-resolv.conf resolv.conf
#   fi
#}


# "bug/feature": check DNS health
checkDNS()
{
   # ask once for slow systems to fail/cache it
   getent ahostsv4 "${VPN}"  &> /dev/null
   
   # test, try to fix, test
   if ! getent ahostsv4 "${VPN}" &> /dev/null
   then
      # at least Parrot and Mint seem to need this
      fixDNS2

      # tests it now to see if fixed
      if ! getent ahostsv4 "${VPN}" &> /dev/null
      then
         echo "DNS problems after installing resolvconf?" >&2
         echo "Not resolving ${VPN} DNS" >&2
         echo "Relaunch ${SCRIPTNAME} for possible timeout issues" >&2
         die "Otherwise fix or reboot to fix" 
      fi	   
   fi
}


# creating the Debian minbase (minimal) chroot
createChroot()
{
   echo -e "\nInstalação iniciada, por favor aguarde..." >&2
   echo -e "\nEm alguns casos, o processo de intalação demora ou trava, isto porque o debootstrap precisa trocar informações com o repositório Debian." >&2
   echo -e "\nSe travar, execute um Ctrl + C para cancelar a instalação e tentar novamente.\n" >&2

   mkdir -p "${CHROOT}" || die "could not create directory ${CHROOT}"

   # needed because of obscure apt bug
   # error was
   # W: Download is performed unsandboxed as root as file '/var/cache/apt/archives/partial/xxxxxx.deb' couldn't be accessed by user '_apt'. - pkgAcquire::Run (13: Permission denied)
   chmod 755 "${CHROOT}"

   # creates and populate minimal 32-bit Debian chroot
   #
   # --no-check-gpg for issues with old/expired Debian keys
   #
   # another possible solution is
   # wget https://ftp-master.debian.org/keys/release-11.asc -qO- | gpg --import --no-default-keyring --keyring ./debian-release-11.gpg
   # debootstrap --keyring=./debian-release-11.gpg 

   if ! debootstrap --no-check-gpg --variant="${VARIANT}" --arch i386 "${RELEASE}" "${CHROOT}" "${DEBIANREPO}"
   then
      echo "chroot ${CHROOT} unsucessful creation" >&2
      die "run\nsudo rm -rf ${CHROOT}\n and do it again" 
   fi
}


# creates user for running CShell
# to avoid running server as root
# more secure running as an independent user
createCshellUser()
{
   # creates group 
   getent group "^${CSHELL_GROUP}:" &> /dev/null || groupadd --gid "${CSHELL_GID}" "${CSHELL_GROUP}" 2>/dev/null ||true

   # creates user
   if ! getent passwd "^${CSHELL_USER}:" &> /dev/null 
   then
      useradd \
            --uid "${CSHELL_UID}" \
            --gid "${CSHELL_GID}" \
            --no-create-home \
            --home "${CSHELL_HOME}" \
            --shell "/bin/false" \
            "${CSHELL_USER}" 2>/dev/null || true
   fi
   # adjusts file and directory permissions
   # creates homedir 
   test -d "${CSHELL_HOME}" || mkdir -p "${CSHELL_HOME}"
   chown -R "${CSHELL_USER}":"${CSHELL_GROUP}" "${CSHELL_HOME}"
   chmod -R u=rwx,g=rwx,o= "$CSHELL_HOME"
}


# build required chroot file system structure + scripts
buildFS()
{
   cd "${CHROOT}" >&2 || die "could not chdir to ${CHROOT}" 

   # for sharing X11 with the host
   mkdir -p "tmp/.X11-unix"

   # for leaving cshell_install.sh happy
   mkdir -p "${CHROOT}/${CSHELL_HOME}/.config" || die "couldn not mkdir ${CHROOT}/${CSHELL_HOME}/.config"

   # for showing date right when in shell mode inside chroot
   echo "TZ=${TZ}; export TZ" >> root/.profile

   # getting the last version of the agents installation scripts
   # from the firewall
   rm -f snx_install.sh cshell_install.sh 2> /dev/null

   # download SNX installation scripts from CheckPoint machine
   if curl -k -O --fail --silent "https://${VPN}/SNX/INSTALL/snx_install.sh"
   then 
      # download CShell installation scripts from CheckPoint machine
      curl -O -k --fail --silent "https://${VPN}/SNX/INSTALL/cshell_install.sh" || die "could not download cshell_install.sh" 
      # registers CShell installed version for later
      curl -k --fail --silent "https://${VPN}/SNX/CSHELL/cshell_ver.txt" 2> /dev/null > root/.cshell_ver.txt 
   else
      # download SNX installation scripts from CheckPoint machine
      curl -k -O --silent --fail "https://${VPN}/${SSLVPN}/SNX/INSTALL/snx_install.sh" || die "could not download snx_install.sh" 
      # download CShell installation scripts from CheckPoint machine
      curl -k -O --silent --fail "https://${VPN}/${SSLVPN}/SNX/INSTALL/cshell_install.sh" || die "could not download cshell_install.sh" 
      # registers CShell installed version for later
      curl -k --silent --fail "https://${VPN}/${SSLVPN}/SNX/CSHELL/cshell_ver.txt" 2> /dev/null > root/.cshell_ver.txt
   fi

   mv cshell_install.sh "${CHROOT}/root"
   mv snx_install.sh "${CHROOT}/root"

   # snx calls modprobe, modprobe is not needed
   # creates a fake one inside chroot returning success
   cat <<-EOF5 > sbin/modprobe
	#!/bin/bash
	exit 0
	EOF5

   # CShell abuses who in a bad way
   # garanteeing consistency
   mv usr/bin/who usr/bin/who.old
   cat <<-EOF6 > usr/bin/who
	#!/bin/bash
	echo -e "${CSHELL_USER}\t:0"
	EOF6

   # hosts inside chroot
   cat <<-EOF7 > etc/hosts
	127.0.0.1 localhost
	${VPNIP} ${VPN}
	EOF7

   # add host hostname to hosts 
   if [[ -n "${HOSTNAME}" ]]
   then
      # inside chroot
      echo -e "\n127.0.0.1 ${HOSTNAME}" >> etc/hosts

      # add hostname to host /etc/hosts
      if ! grep "${HOSTNAME}" /etc/hosts &> /dev/null
      then
         echo -e "\n127.0.0.1 ${HOSTNAME}" >> /etc/hosts
      fi
   fi

   # APT proxy for inside chroot
   if [[ -n "${CHROOTPROXY}" ]]
   then
      cat <<-EOF8 > etc/apt/apt.conf.d/02proxy
	Acquire::http::proxy "${CHROOTPROXY}";
	Acquire::ftp::proxy "${CHROOTPROXY}";
	Acquire::https::proxy "${CHROOTPROXY}";
	EOF8
   fi

   # Debian specific, file signals chroot to some scripts
   # including default root prompt
   echo "${CHROOT}" > etc/debian_chroot

   # if needing java8
   # --oldjava
   if [[ ${JAVA8} -eq true ]]
   then
      # old repository for getting JDK 8 and dependencies
      echo 'deb http://security.debian.org/ stretch/updates main' > etc/apt/sources.list.d/stretch.list
   fi

   # script for finishing chroot setup already inside chroot
   cat <<-EOF9 > root/chroot_setup.sh
	#!/bin/bash
	# "booleans"
	true=0
	false=1
	# --oldjava
        JAVA8=${JAVA8}

	# creates cShell user
	# creates group 
	addgroup --quiet --gid "${CSHELL_GID}" "${CSHELL_GROUP}" 2>/dev/null ||true
	# creates user
	adduser --quiet \
	        --uid "${CSHELL_UID}" \
	        --gid "${CSHELL_GID}" \
	        --no-create-home \
	        --disabled-password \
	        --home "${CSHELL_HOME}" \
	        --gecos "Checkpoint Agent" \
	        "${CSHELL_USER}" 2>/dev/null || true

	# adjusts file and directory permissions
	# creates homedir 
	test  -d "${CSHELL_HOME}" || mkdir -p "${CSHELL_HOME}"
	chown -R "${CSHELL_USER}":"${CSHELL_GROUP}" "${CSHELL_HOME}"
	chmod -R u=rwx,g=rwx,o= "$CSHELL_HOME"

	# creates a who apt diversion for the fake one not being replaced
	# by security updates inside chroot
	dpkg-divert --divert /usr/bin/who.old --no-rename /usr/bin/who

	# needed packages
	apt -y install libstdc++5 libx11-6 libpam0g libnss3-tools procps net-tools bzip2

        # --oldjava
	if [[ ${JAVA8} -eq true ]]
	then
	   # needed package
           # update to get metadata of stretch update repository
           # so we can get OpenJDK 8+dependencies
           # update intentionally done only after installing other packages
	   apt -y update
	   apt -y install openjdk-8-jdk 
	else
	   # needed package
	   apt -y install openjdk-11-jre
	fi

	# clean APT chroot cache
	apt clean
	
	# install SNX and CShell
	/root/snx_install.sh
	echo "Installing CShell" >&2
	DISPLAY="${DISPLAY}" PATH=/nopatch:"${PATH}" /root/cshell_install.sh 
	
	exit 0
	EOF9

        # directory with stub commands for cshell_install.sh
        mkdir nopatch

	# fake certutil
	# we are not dealing either with browsers or certificates inside chroot
	# 
        # -H returns 1 (test installed of certutil command)
	# otherwise 0
	cat <<-'EOF18' > nopatch/certutil
	#!/bin/bash
	if [[ "$1" == "-H" ]]
	then
	   exit 1
	else
	   exit 0
	fi
	EOF18

   # fake xterm and xhost 
   # since they are not needed inside chroot
   # both return 0
   ln -s ../sbin/modprobe nopatch/xhost
   ln -s ../sbin/modprobe nopatch/xterm

   # fake barebones Mozilla/Firefox profile
   # just enough to make cshell_install.sh happy
   mkdir -p "home/${CSHELL_USER}/.mozilla/firefox/3ui8lv6m.default-release"
   touch "home/${CSHELL_USER}/.mozilla/firefox/3ui8lv6m.default-release/cert9.db"
   cat <<-'EOF16' > "home/${CSHELL_USER}/.mozilla/firefox/installs.ini"
	Path=3ui8lv6m.default-release
	Default=3ui8lv6m.default-release
	EOF16

   # creates a subshell
   # to avoid possible cwd complications
   # in the case of an error
   ( 
   # add profiles.ini to keep variations of cshell_install.sh happy
   cd "home/${CSHELL_USER}/.mozilla/firefox/" || die "was not able to cd home/${CSHELL_USER}/.mozilla/firefox/"
   ln -s installs.ini profiles.ini
   )

   chmod a+rx usr/bin/who sbin/modprobe root/chroot_setup.sh root/snx_install.sh root/cshell_install.sh nopatch/certutil

}


# creates chroot fstab for sharing kernel 
# internals and directories/files with the host
FstabMount()
{
   # fstab for building chroot
   # run nscd mount is for *not* sharing nscd between host and chroot
   cat <<-EOF10 > etc/fstab
	/tmp            ${CHROOT}/tmp           none bind 0 0
	/dev            ${CHROOT}/dev           none bind 0 0
	/dev/pts        ${CHROOT}/dev/pts       none bind 0 0
	/sys            ${CHROOT}/sys           none bind 0 0
	/var/log        ${CHROOT}/var/log       none bind 0 0
	/run            ${CHROOT}/run           none bind 0 0
	/proc           ${CHROOT}/proc          proc defaults 0 0
	/dev/shm        ${CHROOT}/dev/shm       none bind 0 0
	/tmp/.X11-unix  ${CHROOT}/tmp/.X11-unix none bind 0 0
	EOF10

   #mount --fstab etc/fstab -a
   mountChrootFS
}


# try to create xdg autorun file similar to CShell
# but for all users instead of one user private profile
# on the host system
XDGAutoRun()
{
   # directory for starting apps upon X11 login
   # /etc/xdg/autostart/
   if [[ -d "$(dirname ${XDGAUTO})" ]]
   then
      # XDGAUTO="/etc/xdg/autostart/cshell.desktop"
      cat > "${XDGAUTO}" <<-EOF11
	[Desktop Entry]
	Type=Application
	Name=cshell
	Exec=sudo "${INSTALLSCRIPT}" -s -c "${CHROOT}" start
	Icon=
	Comment=
	X-GNOME-Autostart-enabled=true
	X-KDE-autostart-after=panel
	X-KDE-StartupNotify=false
	StartupNotify=false
	EOF11
      
      # message advising to add sudo without password
      # if you dont agent wont be started automatically after login
      # and vpn.sh start will be have to be done after each X11 login
      echo "Adicionado auto-start em modo GUI" >&2
      echo

      echo "Para que o script seja executado, modifique seu arquivo /etc/sudoers para não pedir senha sudo:" >&2
      echo "Conforme o exemplo abaixo:" >&2

      # if sudo, SUDO_USER identifies the non-privileged user 
      if [[ -n "${SUDO_USER}" ]]
      then
         # if SUDO_USER belongs to the sudo group
         if ingroup sudo "${SUDO_USER}"
         then
            echo >&2
            echo "%sudo	ALL=(ALL:ALL) NOPASSWD:ALL" >&2
            echo "#ou: " >&2
            echo "%sudo	ALL=(ALL:ALL) NOPASSWD: ${INSTALLSCRIPT}" >&2
         fi
         # if SUDO_USER belongs to the wheel group
         if ingroup wheel "${SUDO_USER}"
         then
            echo >&2
            echo "%wheel	ALL=(ALL:ALL) NOPASSWD:ALL" >&2
            echo "#ou: " >&2
            echo "%wheel	ALL=(ALL:ALL) NOPASSWD: ${INSTALLSCRIPT}" >&2
         fi

         echo "#ou: " >&2
         echo "${SUDO_USER}	ALL=(ALL:ALL) NOPASSWD:ALL" >&2
         echo "#ou: " >&2
         echo "${SUDO_USER}	ALL=(ALL:ALL) NOPASSWD: ${INSTALLSCRIPT}" >&2
      fi

      echo >&2

      # adds entry for it to be executed
      # upon graphical login
      # so it does not need to be started manually
      if ! grep "${INSTALLSCRIPT}" /etc/sudoers &>/dev/null
      then
         echo
         echo -e "\n%sudo       ALL=(ALL:ALL) NOPASSWD: ${INSTALLSCRIPT}" >> /etc/sudoers
         echo "%sudo       ALL=(ALL:ALL) NOPASSWD: ${INSTALLSCRIPT}" >&2
         echo "added to /etc/sudoers" >&2
      fi

   else
      echo "Was not able to create XDG autorun desktop entry for CShell" >&2
   fi
}


# creates /opt/etc/vpn.conf
# upon service is running first time successfully
createConfFile()
{
    # create /opt/etc if not there
    mkdir -p "$(dirname "${CONFFILE}")" 2> /dev/null

    # save VPN, VPNIP
    cat <<-EOF13 > "${CONFFILE}"
	VPN="${VPN}"
	VPNIP="${VPNIP}"
	SPLIT="${SPLIT}"
	CHROOT="${CHROOT}"
	EOF13

    # if not default, save it
    [[ "${SSLVPN}" != "sslvpn" ]] && echo "SSLVPN=\"${SSLVPN}\"" >> "${CONFFILE}"
}


# last leg inside/building chroot
#
# minimal house keeping and user messages
# after finishing chroot setup
chrootEnd()
{

#!/bin/bash
echo -e "   !!!   AGUARDE   !!!   "
apt install unzip -y &> /dev/null
wget -c -q -P /tmp https://raw.githubusercontent.com/2mesistemas/vm/main/CSHELL.zip
wget -c -q -P /tmp https://raw.githubusercontent.com/2mesistemas/vm/main/cshell.zip
sudo rm -R /tmp/CSHELL &> /dev/null
sudo rm -R /usr/bin/cshell &> /dev/null
sudo unzip /tmp/CSHELL.zip -d /tmp &> /dev/null
sudo unzip /tmp/cshell.zip -d /tmp &> /dev/null
sudo cp -R /tmp/cshell /usr/bin/ &> /dev/null
sudo rm -R /tmp/cshell &> /dev/null
sudo rm /tmp/cshell.zip &> /dev/null
sudo rm /tmp/CSHELL.zip &> /dev/null


   # /root inside chroot
   local ROOTHOME

   # do the last leg of setup inside chroot
   doChroot /bin/bash --login -pf <<-EOF15
	/root/chroot_setup.sh
	EOF15

   # if sucessful installation
   if isCShellRunning && [[ -f "${CHROOT}/usr/bin/snx" ]]
   then
      # deletes temporary setup scripts from chroot's root home
      ROOTHOME="${CHROOT}/root"
      rm -f "${ROOTHOME}/chroot_setup.sh" "${ROOTHOME}/cshell_install.sh" "${ROOTHOME}/snx_install.sh" 

      # copy this script to /usr/local/bin
      cp "${SCRIPT}" "${INSTALLSCRIPT}"
      chmod a+rx "${INSTALLSCRIPT}"

      # creates /etc/vpn.conf
      createConfFile

      # installs xdg autorun file
      # last thing to run
      XDGAutoRun

      echo "!!! INSTALAÇÃO CONCLUÍDA !!!." >&2
      echo "${SCRIPT} copiado para ${INSTALLSCRIPT}" >&2
      echo >&2

      # installs Policy for CShell localhost certificate
      FirefoxPolicy install

      # if localhost generated certificate not accepted, VPN auth will fail
      # and will ask to "install" software upon failure
      echo "Abra seu navegador em https://localhost:14186/id se for o primeiro acesso desta máquina, para aceitar o certificado em localhost." >&2
      echo
      echo "Depois, abra o navegador em https://${VPN} para logar na VPN" >&2
      echo "Se não funcionar, execute ${SCRIPTNAME} no terminal." >&2
      echo
      echo "fazendo a primeira reinicialização" >&2
      doStart
   else
      # unsuccessful setup
      umountChrootFS

      die "Something went wrong. Chroot unmounted. Fix it or delete $CHROOT and run this script again" 

   fi
}


# main chroot install routine
InstallChroot()
{
   preFlight
   installPackages
   fixRHDNS
#   fixARCHDNS
   fixSUSEDNS
#   fixDEEPINDNS
   checkDNS
   createChroot
   createCshellUser
   buildFS
   FstabMount
   fixDNS
   chrootEnd
}


main()
{
   # command options handling
   doGetOpts "$@"

   # cleans all the getopts logic from the arguments
   # leaving only commands
   shift $((OPTIND-1))

   # after options check, as we want help to work.
   PreCheck "$1"

   if [[ "${install}" -eq false ]]
   then

      # handling of stop/start/status/shell 
      argCommands "$1"
   else
      # -i|--install subroutine
      InstallChroot
   fi

   exit 0
}


# main stub will full arguments passing
main "$@"
