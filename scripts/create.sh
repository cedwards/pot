#!/bin/sh

JOCKER_ZFS_ROOT=zroot/carton
JOCKER_FS_ROOT=/opt/carton

# derived entries
JOCKER_ZFS_BASE=${JOCKER_ZFS_ROOT}/bases
JOCKER_ZFS_JAIL=${JOCKER_ZFS_ROOT}/jails
JOCKER_FS_BASE=${JOCKER_FS_ROOT}/bases
JOCKER_FS_JAIL=${JOCKER_FS_ROOT}/jails
JOCKER_FS_COMP=${JOCKER_FS_ROOT}/fscomp

# It check if the root zfs datasets are present
is_zfs_ready()
{
	local _output
	for _dataset in ${JOCKER_ZFS_ROOT} ${JOCKER_ZFS_BASE} ${JOCKER_ZFS_JAIL} ; do
		_output="$(zfs get -H mountpoint ${_dataset} 2>/dev/null)"
		if [ "$?" -ne 0 ]; then
			echo ${_dataset} not existing \[ $_output \]
			return 1 # false
		fi
	done
	_output="$(zfs get -H mountpoint ${JOCKER_ZFS_JAIL} 2>/dev/null)"
	if [ "$( echo $_output | awk '{print $3}')" != "none" ]; then
		echo ${_dataset} has the wrong mountpoint
		return 1 # false
	fi
}

_is_zfs_dataset()
{
	local _dataset _output
	_dataset=$1
	if [ -z "${_dataset}" ]; then
		return 1 # false
	fi
	_output="$(zfs get -H mountpoint ${_dataset} 2>/dev/null)"
	return $?
}

_get_last_zfs_snap()
{
	local _dataset _output
	_dataset=$1
	if [ -z "$_dataset" ]; then
		return
	fi
	_output="$( zfs list -d 1 -H -t snapshot $_dataset | sort -r | cut -d'@' -f2 | cut -f1)"
	if [ -z "$_output" ]; then
		return 1 # false
	else
		echo ${_output}
		return 0 # true
	fi
}

# $1 the jailname
# $2 the FreeBSD base version
create_jail_fs()
{
	local _jailname _jaildir _basever _snap
	_jailname=$1
	_basever=$2
	if [ -z "${_jailname}" ]; then
		return 1 # false
	fi
	if ! is_zfs_ready ; then
		return 1 # false
	fi
	if ! _is_zfs_dataset ${JOCKER_ZFS_JAIL}/${_jailname} ; then
		echo "Creating zfs dataset: ${JOCKER_ZFS_JAIL}/${_jailname}"
		zfs create ${JOCKER_ZFS_JAIL}/${_jailname}
	fi
	_jaildir=${JOCKER_FS_JAIL}/${_jailname}
	if [ ! -d ${_jaildir} ]; then
		mkdir -p ${_jaildir}/m
	fi
	if ! _is_zfs_dataset ${JOCKER_ZFS_JAIL}/${_jailname}/usr.local ; then
		# check if the specific base exists
		if ! _is_zfs_dataset ${JOCKER_ZFS_BASE}/${_basever} ; then
			return 1 # false
		fi
		# looking for the last snapshot
		_snap=$( _get_last_zfs_snap ${JOCKER_ZFS_BASE}/${_basever}/usr.local )
		if [ -z "$_snap" ]; then
			return 1 # false
		fi
		echo "Cloning zfs snapshot: ${JOCKER_ZFS_BASE}/${_basever}/usr.local@${_snap}"
		zfs clone -o mountpoint=${_jaildir}/usr.local ${JOCKER_ZFS_BASE}/${_basever}/usr.local@${_snap} ${JOCKER_ZFS_JAIL}/${_jailname}/usr.local
	fi
	if ! _is_zfs_dataset ${JOCKER_ZFS_JAIL}/${_jailname}/custom ; then
		# check if the specific base exists
		if ! _is_zfs_dataset ${JOCKER_ZFS_BASE}/${_basever} ; then
			return 1 # false
		fi
		# looking for the last snapshot
		_snap=$( _get_last_zfs_snap ${JOCKER_ZFS_BASE}/${_basever}/custom )
		if [ -z "$_snap" ]; then
			return 1 # false
		fi
		echo "Cloning zfs snapshot: ${JOCKER_ZFS_BASE}/${_basever}/custom@${_snap}"
		zfs clone -o mountpoint=${_jaildir}/custom ${JOCKER_ZFS_BASE}/${_basever}/custom@${_snap} ${JOCKER_ZFS_JAIL}/${_jailname}/custom
	fi
	if [ "$JOCKER_APPDATA" != "no" ]; then
		if ! _is_zfs_dataset ${JOCKER_ZFS_JAIL}/${_jailname}/appdata ; then
			# no appdata cloning support yet
			zfs create -o mountpoint=${_jaildir}/appdata ${JOCKER_ZFS_JAIL}/${_jailname}/appdata
		fi
	fi
}

create_jail_conf() {
	local _jailname _jaildir _basever
	_jailname=$1
	_basever=$2
	_ipaddr=$3
	if [ -z "${_jailname}" ]; then
		return 1 # false
	fi
	_jaildir=${JOCKER_FS_JAIL}/${_jailname}
	if [ ! -d ${_jaildir}/conf ]; then
		mkdir -p ${_jaildir}/conf
	fi
	{
		echo "${JOCKER_FS_BASE}/${_basever} ${_jaildir}/m ro"
		echo "${_jaildir}/usr.local ${_jaildir}/m/usr/local"
		echo "${_jaildir}/custom ${_jaildir}/m/opt/custom"
		if [ "${JOCKER_APPDATA}" != "no" ]; then
			echo "${_jaildir}/appdata ${_jaildir}/m/appdata"
		fi
		if [ "${JOCKER_USRPORTS}" != "no" ]; then
			case "${JOCKER_USRPORTS}" in
			git)
				echo "${JOCKER_FS_COMP}/gitport ${_jaildir}/m/usr/ports"
				;;
			svn)
				echo "${JOCKER_FS_COMP}/svnports ${_jaildir}/m/usr/ports"
				;;
			esac
		fi
		if [ "${JOCKER_DISTFILES}" != "no" ]; then
			echo "/opt/distfiles ${_jaildir}/m/usr/ports/distfiles"
		fi
	} > ${_jaildir}/conf/fs.conf
	{
		echo "${_jailname} {"
		echo "  host.hostname = \"${_jailname}.$( hostname )\";"
		echo "  path = ${_jaildir}/m ;"
		echo "  osrelease = \"${_basever}-RELEASE\";"
		echo "  mount.devfs;"
		echo "  allow.set_hostname;"
		echo "  allow.mount;"
		echo "  allow.mount.fdescfs;"
		echo "  allow.raw_sockets;"
		echo "  allow.socket_af;"
		echo "  allow.sysvipc;"
		echo "  exec.start = \"sh /etc/rc\";"
		echo "  exec.stop = \"sh /etc/rc.shutdown\";"
		echo "  persist;"
		echo "  interface = lo1;"
		echo "  ip4.addr = ${_ipaddr};"
		echo "}"
	} > ${_jaildir}/conf/jail.conf
	if [ "${JOCKER_DISTFILES}" != "no" ]; then
		echo "setenv DISTDIR /usr/ports/distfiles" >> "${_jaildir}/custom/root/.cshrc"
	fi
	return 0 # true
}

main()
{
	if ! is_zfs_ready ; then
		echo "The zfs infra is not ready"
	else
		echo "The zfs infra is fine"
	fi

	if create_jail_fs $1 "11.1" ; then
		echo created zfs datasets for jail $1
	fi

	if create_jail_conf $1 "11.1" $2 ; then
		echo created conf for jail $1 with IP address $2
	fi
}

usage()
{
	echo "$(basename ${0}) [-h] [-o optionname] jailname IP-addr"
	echo '    [-m distfiles] [-m usrports=[git|svn]]'
	echo '    -h print this help'
	echo '    -o optionname enable the option optionname'
	echo '       = appdata create a zfs dataset to support /appdata'
	echo '    -m optionname enable the option optionname'
	echo '       => distfiles '
	echo '       => usrports=[git|svn] '
	echo '    jailname the name of the jail'
	echo '    IP-addre the IP address of the jail'
}

args=$( getopt ho:m: $* )

if [ $? -ne 0 ]; then
	usage
	exit 1
fi
set -- $args

JOCKER_APPDATA=no
JOCKER_USRPORTS=no
JOCKER_DISTFILES=no

while true; do
	case "$1" in
	-h)
		usage
		exit 0
		;;
	-o)
		case "$2" in
		appdata)
			JOCKER_APPDATA=yes
			;;
		*)
			echo "option $2 not supported"
			usage
			exit 1
			;;
		esac
		shift; shift
		;;
	-m)
		case "$2" in
		distfiles)
			JOCKER_DISTFILES=yes
			;;
		usrports=*)
			JOCKER_USRPORTS="${2##usrports=}"
			if [ "${JOCKER_USRPORTS}" != git -a \
			     "${JOCKER_USRPORTS}" != svn ]; then
				echo "usrports mountpoint $JOCKER_USRPORTS not supported"
				usage
				exit 1
			fi
			;;
		*)
			echo "mountpoint option $2 not supported"
			usage
			exit 1
			;;
		esac
		shift; shift
		;;
	--)
		shift
		break
		;;
	*)
		usage
		exit 1
	esac
done

if [ -z "$1" -o -z "$2" ]; then
	usage
	exit 1
fi

main $1 $2