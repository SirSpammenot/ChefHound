#!/bin/sh
 
# If not running effectively as root, it does you no good
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Save off the first CLI option, if there is one
ARG1=$1
 
#***DEFAULT SETTINGS**********

# Debug on screen?  Values: true/false
screen=true

# Where to write our execution logs to...
logfile='/opt/cmuds/bootstrap/last_run.log'


#***FUNCTIONS**********

# Open the log file
function init_log(){
	mkdir -p /opt/cmuds/bootstrap >> /dev/null 2>&1

	# Register server address
	regserver=$(estring 'uggc://pursertvfgre')
	
	cmud=$(estring 'purs')
	cmuds=$(estring 'purs-pyvrag')

	# Make sure the script is in the correct place..
	if [ ! -f '/opt/cmuds/bootstrap/cmuds.sh' ];
		then
		cp ./cmuds.sh /opt/cmuds/bootstrap/cmuds.sh > /dev/null
	fi

	# Did we pass in any args?
	if [ "$ARG1" == "manual" ]
		then
		# manual flag is passed in, enable screen output
		screen=true
		echo "Welcome to cmuds in manual mode" > ${logfile}
	elif [ "$ARG1" == "clean" ]; then
		reset_to_preclient_state
		exit
	else
		# Normal run
		echo "Welcome to cmuds..." > ${logfile}
	fi

	return 0
}

# Install from scratch
function install_from_scratch(){
    got_configs
    cmuds_installer
    cmuds_first_run
    return 0
}

function config_backup(){
	mkdir -p /opt/cmuds >> /dev/null 2>&1

	if [ ! -f '/opt/cmuds/last_good_config.tar.gz' ]; then
		# Make a new tar file!
		tar czf /opt/cmuds/last_good_config.tar.gz /etc/${cmud} >> ${logfile} 2>&1
		if [[ $? != '0' ]]
		then
			echo "[x] Making a backup of the config directory failed!!" | dolog 
		else
			echo "[o] Made a backup of the config directory" | dolog 
		fi
	fi
	return 0
}	

function config_restore() {
	if (( config_dir > backup_file )); then
		# something changed in the directory!  Restore from backup
		echo "[?] something changed in the directory!  Restoring from backup because" | dolog
		echo "    ${config_dir} config timestamp is less than" | dolog
		echo "    ${backup_file} backup timestamp" | dolog
		tar xzf /opt/cmuds/last_good_config.tar.gz -C / >> ${logfile} 2>&1
		if [[ $? != '0' ]]
		then
			echo "[x] Restoring from backup of the configs failed!!" | dolog 
		else
			echo "[o] Restored config directory from backup!!" | dolog 
			need_whoami=false
			chown -R root:root /etc/$cmud >> ${logfile} 2>&1
		fi

	fi	
}


# Test for config files
function got_configs(){
	local need_whoami=true

	# get the mtimes to compare with
	if [ -d "/etc/$cmud" ]; then
		local config_dir=`stat -c %Y /etc/${cmud}`
		local backup_file=`stat -c %Y /opt/cmuds/bootstrap/last_good_config.tar.gz`
	else
		# If the whole config dir is gone... it will be zero and the tar will be newer, so fake it.
		local config_dir=99
		local backup_file=10
	fi
	# config_restore
	
	# make the /var/log dir
	if [ ! -D '/var/log/${cmud}' ]; then
		echo "[x] client log directory missing, fixing.." | dolog 
		mkdir /var/log/${cmud}  >> ${logfile} 2>&1
	fi

	## Make sure the client.rb is in place
	if [ ! -f "/etc/${cmud}/client.rb" ]; then
		echo "[x] client.rb file missing!" | dolog 
		need_whoami=true
		# need_whoami=false
	fi

	## Make sure there is a pem in place
	if [ ! -f '/etc/${cmud}/client.pem' ]; then
		echo "# No Do we have the client pem backup made?"
	fi

	# Pull the current configs if need be
	if [ "$need_whoami" = true ]; then
		echo "[x] Getting current config files from $regserver" | dolog 
		get_whoami	

		# If the server changed, grab the new SSL certs
		if [ ! -D '/etc/${cmud}/trusted_certs' ]; then
			echo "[x] trusted_certs directory missing, fixing.." | dolog 
			fetch_trustedssl
		fi

		# knife may not be available... 
		
	fi

	# Technically we should only make the backup if there is a clean run and changes
	config_backup

	return 0
}


    
function cmuds_installer(){
# Lastest package should be in stock repos
    yum install ${cmud}_avoid >> ${logfile} 2>&1

    if [[ $? != '0' ]]
    then
        # Install failed, fall back to local copy
        echo "Error Installing from repo! Failing back.." | dolog 
		cd /opt/cmuds/bootstrap
        curl --remote-name "${regserver}/${cmud}_client_el${rhelver}.rpm" >> ${logfile}
        rpm -ivh ${cmud}_client_el${rhelver}.rpm >> ${logfile} 2>&1

        if [[ $? != '0' ]] 
        then
            echo "$cmud client install Failed. Throwing up hands!!!"
            echo "Somebody should be told via SENDLOGS()"
            echo "CANNOT install rpm at all :(  Error!!!!!!!! ` cat ${logfile} `"
			echo `rm /tmp/cmuds.pid` | dolog
            exit 99
        fi
    fi

    return 0
}   

function isinstalled(){
    # ALERT! yum_list_installed returns a zero is the package is installed, a zero if NOT installed
    if yum list installed "$@" >> ${logfile} 2>&1; then
        echo " [o] $@ IS installed says YUM" | dolog 2>&1
        return 1
    else
        echo " [x] $@ is NOT installed says YUM" | dolog 2>&1
        return 0
    fi
}

function isrunning(){
    # Test if the named app is running
    if ps -A | grep "$@" >> ${logfile} 2>&1; then
        echo " [x] $@ is NOT running says PS" | dolog 2>&1
        return 0
    else
        echo " [o] $@ IS running says PS" | dolog 2>&1
        return 1
    fi
}

function isnotrunning(){
    # Test if the named app is NOT running, so use opposite-day rule set
    if ps -A | grep "$@" >> ${logfile} 2>&1; then
        echo " [o] $@ IS running says PS" | dolog 2>&1
        return 1
    else
        echo " [x] $@ is NOT running says PS" | dolog 2>&1
        return 0
    fi
}



function get_whoami(){
	echo " [-] getting new config from $regserver" | dolog 2>&1
	cd /opt/cmuds/bootstrap
    curl --remote-name "$regserver/whoami.tar"  >> ${logfile} 2>&1
    tar -xvf whoami.tar -C /  >> ${logfile} 2>&1
	chmod -R 0700 /etc/chef/  >> ${logfile} 2>&1
	chown -R root:root /etc/chef/  >> ${logfile} 2>&1

	# Since we updated the configs, may need new certs
	fetch_trustedssl
	# unrem for prod
	# rm -f /opt/cmuds/bootstrap/whoami.tar
    return 0
}

function fetch_trustedssl(){
	local ssl2srv=`grep server_url /etc/${cmud}/client.rb |awk -F " " '{ print $2 }' |sed s/\"//g` 
	echo " [-] Fetching current SSL from \[$ssl2srv\]" | dolog 2>&1

	knife ssl fetch $ssl2srv  >> ${logfile} 2>&1
    if [[ $? != '0' ]]
    then
        # Couldn't get updated certs, tell world of the error
        echo "[x] Failed to fetch current SSL certs from $ssl2srv"  | dolog 2>&1
        sendlogs
        exit 14
	else
        echo "[o] Successful SSL fetch"  | dolog 2>&1
	fi

	# Blindly make sure it is clean and exists
	rm -rfv /etc/$cmud/trusted_certs/*  >> ${logfile} 2>&1
	mkdir -p /opt/cmuds/bootstrap >> /dev/null 2>&1

	# move all the certs
	mv -uv ~/.$cmud/trusted_certs/* /etc/$cmud/trusted_certs/.  >> ${logfile} 2>&1
	# rm -rf /root/.$cmud
	return 0
}

function cmuds_first_run(){
    echo " [o] First run of client, usually to register. Not daemonized yet" | dolog 2>&1
    ${cmuds} >> /dev/null 2>&1
    if [[ $? != '0' ]]
    then
        # Couldn't start the $cmuds, tell world of the error
        echo "[x] Failed to start the first run of the $cmuds"  | dolog 2>&1
        sendlogs
        sleep 30
	else
        echo "[o] Successful initial run of $cmuds"  | dolog 2>&1
	fi

    echo " [o] Now daemonize the client" | dolog 2>&1
    ${cmuds} --daemon >> /dev/null 2>&1
    if [[ $? != '0' ]]
    then
        # Couldn't start the $cmuds, tell world of the error
        echo "[x] Failed to daemonize $cmuds"  | dolog 2>&1
        sendlogs
        sleep 30
    fi

    return 0
}


function cmuds_start(){
    echo "...Daemonizing the $cmuds"  | dolog 2>&1
    ${cmuds} --daemon >> ${logfile} 2>&1
    if [[ $? != '0' ]]
    then
        # Couldn't start the client, tell world of the error
        echo "[x] Failed to start the $cmuds"  | dolog 2>&1
        sendlogs
        sleep 30
	else
        echo "[o] $cmuds daemonized with a success result"  | dolog 2>&1
	fi
    return 0
}

function connection_ok(){ 
    # check if there is base connectivity
    knife ssl check >> ${logfile} 2>&1
    if [[ $? != '0' ]]
    then
        echo "Knife test says connectivity problem. Errcode: $?" | dolog
        echo "bleah" | dolog
    else
        echo "Connection check OK"  | dolog
    fi
    return 0
}

function estring(){
  local m=$(echo "$*" | tr '[a-m][n-z][A-M][N-Z]' '[n-z][a-m][N-Z][A-M]')
  echo $m
}

function sendlogs(){
    getRPMerror=`cat /tmp/getRpmError`
    if [ $getRPMerror ] && [ $getRPMerror -lt 10 ]; then
        #Logs uploaded less than 10 runs ago. Hold.
        getRPMerror=$((getRPMerror+1))
        echo "$getRPMerror" > /tmp/getRpmError
    elif [ $getRPMerror ] && [ $getRPMerror -gt 9 ]; then
            #Logs sent 10 runs ago, send again.
            curl #the_complete_command_to_send_the_logs#
            getRPMerror=1
            echo "$getRPMerror" > /tmp/getRpmError
    else
        # No errors found.
        echo "Nothing found"
    fi
    return 0
}

function dolog(){
    read TXT_IN     
    if [ "$screen" = true ]; then
        echo "${TXT_IN}"
    fi

    echo "[`date`] ${TXT_IN}" >> ${logfile}
    unset TXT_IN
    return 0
}

function set_rhelver(){
    ver=`cat /etc/redhat-release |awk -F" " '{ print $7 }'`
    ver=`echo $ver |sed 's/[.].*$//'`
    rhelver="$ver"
    echo "[o] Found RHEL major version $rhelver" | dolog
    return 0
}

function init_cmuds(){
	# Am I running a newer version than stored?
	local cmuds_now=`stat -c %Y ./cmuds.sh`
	local cmuds_disk=`stat -c %Y /opt/cmuds/bootstrap/cmuds.sh`
	if (( cmuds_now > cmuds_disk )); then
		# Now copy into place and don't use the default alias that forces 'cp -i'
		echo "[o] Updating cmuds.sh from the running version" | dolog
		/bin/cp -fv ./cmuds.sh /opt/cmuds/bootstrap/cmuds.sh  >> ${logfile} 2>&1
	fi

	# Am I already running somewhere else?
	if [ -f '/tmp/cmuds.pid' ];
	then
		# the PID file exists!  But is the PID in use?
		PID=`cat /tmp/cmuds.pid`
		if [ -d /proc/$PID ];
			then
				echo "Another running copy of cmuds found at PID: $PID. Sleeping 30s and exiting" | dolog
				sleep 30
				exit
			else
				# echo "PID: $PID not found"
				echo "$$" > /tmp/cmuds.pid
				echo "PID file overwritten" | dolog
		fi
	
	else
		echo "$$" > /tmp/cmuds.pid
		echo "PID file created" | dolog
	fi
	
	# What version of RHEL am I? Act accordingly
	if [ "$rhelver" = "5" ];
    then
        #Use sysV init style
        isin=$(grep -xc "cmuds:2345:respawn:/opt/cmuds/bootstrap/cmuds.sh" /etc/inittab)
        if [ "$isin" = "0" ];
			then
                echo "[x] We are not running RHEL5 automatically, set and restart..." | dolog
                echo "entry does not exist.. adding the entry"
                echo "cmuds:2345:respawn:/opt/cmuds/bootstrap/cmuds.sh" >> /etc/inittab;init q
                echo `rm /tmp/cmuds.pid` | dolog
				echo "[o] Exiting PID $$ and running tail for you... [Ctrl]+[C] when you get bored!" | dolog
                tail -f -n 1 ${logfile}
                exit 0
        else
                echo "[o] Init file found. Assuming the best.." | dolog
        fi

	
	elif [ "$rhelver" = "6" ];
		then # Use Upstart /etc/init method
	
		# always check if the init is good to go
		if [ ! -f '/etc/init/cmuds.conf' ];
			then
			engage_init
		fi
		
		# isin=$(initctl status cmuds | grep -ic "stop" )
		if [ `initctl status cmuds | grep -ic "start"` = 0 ];
			then
			echo "[x] We are not running RHEL6 automatically, set and restart..." | dolog
			rm /tmp/cmuds.pid  >/dev/null
			initctl reload-configuration >> ${logfile} 2>&1
			initctl start cmuds >> ${logfile} 2>&1
			echo "[o] Exiting PID $$ and running tail $logfile for you... [Ctrl]+[C] when you get bored!" | dolog
			tail -f -n 1 ${logfile} 
			exit 0
		fi
	
		# derive the parent's parent's parent
		my_ggppid
		if [ "$GGPPID" = "1" ];
			then
			echo "[o] I am Init! go ahead and keep running." | dolog
	
		else
			# init file was found but I am not running from init... so must be run manually.
			if [ "$ARG1" = "manual" ] 
				then
				# manual flag is passed in, ignore and continue
				echo "You, ON PURPOSE, manually ran this script when the automated version is already running. Continuing" | dolog
			else
				# Debug on screen  Values: true/false
				screen=true
				echo "!!!" | dolog
				echo "You are manually running this script when the automated version is available." | dolog
				echo "[o] Exiting PID $$ and running tail for you... [Ctrl]+[C] when you get bored!" | dolog
				echo "!!!" | dolog
	
				# Check if cmuds.sh is in the 'stop' target
				if [ `initctl status cmuds | grep -ic "stop"` = '1' ];
					then
					`initctl start cmuds`
				fi

				tail -f -n 1 ${logfile} 
				exit 0
			fi	
		fi
	
		
	elif [ "$rhelver" = "7" ];
		then
			# Use systemd method
			echo "SystemD coming soon!" | dolog
	
			else
		echo "Cannot match RHEL v$rhelver to any known startup type. Skipping auto-start logic." | dolog
	fi
}

function my_ggppid(){
	# Get the Great-Great-grandparent of the current PPID
	local lev1=`ps -o ppid= $PPID`
	local lev2=`ps -o ppid= $lev1`
	GGPPID="${lev2#"${lev2%%[![:space:]]*}"}"   # remove leading whitespace characters
	# echo " GrandpaIDs go: $PPID -> [$lev1] -> [$GGPPID]" | dolog
	return $GGPPID
}

function engage_init(){
	echo "[x] No init script! Fixing..." | dolog

	# Do we have a local copy?
	if [ ! -f '/opt/cmuds/bootstrap/cmuds.conf' ]; then
		curl "$regserver/cmuds.conf" --output '/opt/cmuds/bootstrap/cmuds.conf' >> ${logfile} 2>&1
	fi

	# Now copy into place and don't use the default alias that forces 'cp -i'
	/bin/cp -fv /opt/cmuds/bootstrap/cmuds.conf /etc/init/.  >> ${logfile} 2>&1

	# reload initctl's config files to see the (maybe) new service
	initctl reload-configuration >> ${logfile} 2>&1

	if [ -f '/etc/init/cmuds.conf' ]; then
		echo "[o] Init script replaced." | dolog
	else
		echo "[X] FAILURE: Init script cannot be set" | dolog
	fi
	return 0
}


function reset_to_preclient_state(){
  echo "[o] Removing $cmud and cmuds" | dolog
  initctl stop cmuds  >> ${logfile} 2>&1
  service ${cmuds} stop  >> ${logfile} 2>&1
  rm -fv /etc/init/cmuds.conf  >> ${logfile} 2>&1
  initctl reload-configuration >> ${logfile} 2>&1
  rm -rfv /etc/${cmud}/  >> ${logfile} 2>&1
  rm -rfv /opt/cmuds  >> ${logfile} 2>&1
  yum -y erase ${cmud}  >> ${logfile} 2>&1
}

#====================================================================
function clean_up(){
	# Things to do if the script ever exits (normally or abnormally) work in 2 parts,
	# (A)this function gets executed becuase it is referenced by a (B)trap statement
	# the trap statement should be right after this function

	rm /tmp/cmuds.pid
}
trap clean_up EXIT
#====================================================================

echo "Beginning Tests as PID $$ (parent = $PPID)" | dolog

init_log
set_rhelver
init_cmuds

# Make sure config file set is complete
got_configs

# Check if the RPM is even installed
if isinstalled "${cmud}"; then
    echo "$cmuds client not found. Install it" | dolog
    install_from_scratch
fi

## Now try to determine health of the client
# 1st check if daemon is running
if isnotrunning "${cmuds}"; then
    cmuds_start
fi


# 2nd check if cmuds has recent successful runs
    #Is cmud is happy, then exit!

# Not happy? Find out why

# check if cmuds has base connectivity

# check if cmuds_server is responding
    # Needs to do a command that shows SQL backend is running OK

	
# Technically we should only make the backup if there is a clean run
config_backup

    
echo "cmuds is sleeping for 90s" | dolog
sleep 90
echo " " | dolog
# End of script