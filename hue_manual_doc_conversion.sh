#!/bin/bash
#Migrates missing doc1 to doc2

#parse command line arguments
parse_arguments()
{
  # Test that we're using compatible getopt version.
  getopt -T > /dev/null
  if [[ $? -ne 4 ]]; then
    echo "Incompatible getopt version."
    exit 1
  fi

  # Parse short and long option parameters.
  OVERRIDE=
  USERNAME=
  ALLOWDUPES=False
  START_QUERY_NAME=
  STARTUSER=
  VERBOSE=
  DESKTOP_DEBUG=false
  GETOPT=`getopt -n $0 -o o,u:,d,q:,s:,v,h \
      -l override,username:,duplicates,startquery:,startuser:,verbose,help \
      -- "$@"`
  eval set -- "$GETOPT"
  while true;
  do
    case "$1" in
    -o|--override)
      OVERRIDE=true
      shift
      ;;
    -u|--username)
      USERNAME=$2
      shift 2
      ;;
    -d|--duplicates)
      ALLOWDUPES=True
      shift
      ;;
    -q|--startquery)
      START_QUERY_NAME=$2
      shift 2
      ;;
    -s|--startuser)
      STARTUSER=$2
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      DESKTOP_DEBUG=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      exit 1
      ;;
    esac
  done

  #
}

usage()
{
cat << EOF
usage: $0 [options]

Migrates missing queries and docs:

OPTIONS
   -o|--override           Allow script to run as non-root, must set HUE_CONF_DIR manually before running
   -u|--username <comma,sep,list>   Comma separated list of users to process
   -d|--duplicates	   Allows duplicate entries to be created.  This will run faster.
   -q|--startquery <queryname> Specify name of query to start at to avoid running through all queries.
   -s|--startuser <username>  User to start at
   -v|--verbose            Verbose logging, off by default
   -h|--help               Show this message.
EOF
}

debug()
{
   if [[ ! -z $VERBOSE ]]
   then
      echo "$1" >> ${LOG_FILE}
   fi
}

main()
{

  parse_arguments "$@"

  SCRIPT_DIR="$( cd -P "$( dirname "$0" )" && pwd )"
  PYTHONPATH=${SCRIPT_DIR}/lib:${PYTHONPATH}
  export SCRIPT_DIR PYTHONPATH

  #SET IMPORTANT ENV VARS
  if [[ -z ${HUE_CONF_DIR} ]]
  then
    if [ -d "/var/run/cloudera-scm-agent/process" ]
    then
      HUE_CONF_DIR="/var/run/cloudera-scm-agent/process/`ls -1 /var/run/cloudera-scm-agent/process | grep HUE_SERVER | sort -n | tail -1 `"
      HUE_SUPERVISOR_CONF=$(echo ${HUE_CONF_DIR} | sed "s/process/supervisor\/include/g").conf
    else
      HUE_CONF_DIR="/etc/hue/conf"
    fi
    export HUE_CONF_DIR HUE_SUPERVISOR_CONF
  fi

  if [[ ! ${USER} =~ .*root* ]]
  then
    if [[ -z ${OVERRIDE} ]]
    then
      echo "Script must be run as root: exiting"
      exit 1
    fi
  else
    if [[ $(ps -ef | grep [r]unc) ]]
    then
      DESKTOP_LOG_DIR=$(strings /proc/$(ps -ef | grep [r]unc | awk '{print $2}')/environ | grep DESKTOP_LOG_DIR | awk -F\= '{print $2}')
    fi
  fi

  if [[ -z ${DESKTOP_LOG_DIR} ]]
  then
    DESKTOP_LOG_DIR=${HUE_CONF_DIR}/logs
  fi
  if [[ ! -f ${DESKTOP_LOG_DIR} ]]
  then
    mkdir -p ${DESKTOP_LOG_DIR}
  fi
  LOG_FILE=${DESKTOP_LOG_DIR}/`basename "$0" | awk -F\. '{print $1}'`.log
  LOG_ROTATE_SIZE=10 #MB before rotating, size in MB before rotating log to .1
  LOG_ROTATE_COUNT=5 #number of log files, so 20MB max
  
  export $(sed "s/,/\\n/g" ${HUE_SUPERVISOR_CONF} | grep PARCELS_ROOT | sed "s/'//g")
  PARCEL_DIR=${PARCELS_ROOT}/CDH
  if [ ! -d "/usr/lib/hadoop" ]
  then
    CDH_HOME=$PARCEL_DIR
  else
    CDH_HOME=/usr
  fi

  if [ -d "${CDH_HOME}/lib/hue/build/env/bin" ]
  then
    COMMAND="${CDH_HOME}/lib/hue/build/env/bin/hue shell"
    TEST_COMMAND="${CDH_HOME}/lib/hue/build/env/bin/hue dbshell"
  else
    COMMAND="${CDH_HOME}/share/hue/build/env/bin/hue shell"
    TEST_COMMAND="${CDH_HOME}/share/hue/build/env/bin/hue dbshell"
  fi

  ORACLE_ENGINE_CHECK=$(grep engine ${HUE_CONF_DIR}/hue* | grep -i oracle)
  if [[ ! -z ${ORACLE_ENGINE_CHECK} ]]
  then
    if [[ -z ${ORACLE_HOME} ]]
    then
      ORACLE_PARCEL=/opt/cloudera/parcels/ORACLE_INSTANT_CLIENT/instantclient_11_2
      if [[ -d ${ORACLE_PARCEL} ]]
      then
        ORACLE_HOME=${ORACLE_PARCEL}
        LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${ORACLE_HOME}
        export LD_LIBRARY_PATH ORACLE_HOME
      fi
    fi
    if [[ -z ${ORACLE_HOME} ]]
    then
      echo "It looks like you are using Oracle as your backend"
      echo "ORACLE_HOME must be set to the correct Oracle client"
      echo "before running this script"
      exit 1
    fi
  fi

  HUE_IGNORE_PASSWORD_SCRIPT_ERRORS=1
  if [[ -z ${HUE_DATABASE_PASSWORD} ]]
  then
    echo "CDH 5.5 and above requires that you set the environment variable:"
    echo "HUE_DATABASE_PASSWORD=<dbpassword>"
    exit 1
  fi
  PGPASSWORD=${HUE_DATABASE_PASSWORD}
  export CDH_HOME COMMAND HUE_IGNORE_PASSWORD_SCRIPT_ERRORS PGPASSWORD

  debug "Validating DB connectivity"
#  echo "COMMAND: echo \"from django.db import connection; cursor = connection.cursor(); cursor.execute('select count(*) from auth_user')\" | ${TEST_COMMAND}" | tee -a ${LOG_FILE}
#  echo "from django.db import connection; cursor = connection.cursor(); cursor.execute('select count(*) from auth_user')" | ${TEST_COMMAND} | tee -a ${LOG_FILE}

  QUIT_COMMAND="quit"
  PG_ENGINE_CHECK=$(grep engine ${HUE_CONF_DIR}/hue* | grep -i postgres)
  if [[ ! -z ${PG_ENGINE_CHECK} ]]
  then
    QUIT_COMMAND='\q'
  fi

#  echo "Running echo ${QUIT_COMMAND} | ${TEST_COMMAND}"
#  echo ${QUIT_COMMAND} | ${TEST_COMMAND}
  if [[ $? -ne 0 ]]
  then
    echo "HUE_DATABASE_PASSWORD is incorrect.  Please check CM: http://${HOSTNAME}:7180/api/v5/cm/deployment and search for HUE_SERVER and database to find correct password"
    exit 1
  fi

  ${COMMAND} >> /dev/null 2>&1 <<EOF
usernames = "${USERNAME}"
startqueryname = "${START_QUERY_NAME}"
startuser = "${STARTUSER}"
allowdupes = ${ALLOWDUPES}
LOGFILE = "${LOG_FILE}"
logrotatesize=${LOG_ROTATE_SIZE}
backupcount=${LOG_ROTATE_COUNT}

import time
import logging
import logging.handlers
import desktop.conf
from conversion_runner import DocumentConversionRunner

LOG = logging.getLogger()
format = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
fh = logging.handlers.RotatingFileHandler(LOGFILE, maxBytes = (1048576*logrotatesize), backupCount = backupcount)
fh.setFormatter(format)
LOG.addHandler(fh)
LOG.setLevel(logging.INFO)
LOG.info('HUE_CONF_DIR: ${HUE_CONF_DIR}')
LOG.info("DB Engine: %s" % desktop.conf.DATABASE.ENGINE.get())
LOG.info("DB Name: %s" % desktop.conf.DATABASE.NAME.get())
LOG.info("DB User: %s" % desktop.conf.DATABASE.USER.get())
LOG.info("DB Host: %s" % desktop.conf.DATABASE.HOST.get())
LOG.info("DB Port: %s" % str(desktop.conf.DATABASE.PORT.get()))

overallstart = time.time()
conversionrunner = DocumentConversionRunner(usernames=usernames, allowdupes = allowdupes, startqueryname = startqueryname, startuser = startuser)
conversionrunner.runconversions()
overallend = time.time()
elapsed = (overallend - overallstart) / 60
LOG.info("Time elapsed (minutes): %.2f" % elapsed)


EOF

echo ""
echo "Logs can be found in ${DESKTOP_LOG_DIR}"

unset PGPASSWORD

}

main "$@"
