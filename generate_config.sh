#!/bin/bash

set -o pipefail

################################################################################
# INSTALL ADDITIONAL TOOLS IN BUSYBOX BASED CONTAINER HOSTS                    #
################################################################################

if grep --help 2>&1 | grep -q -i "busybox"; then
  echo "BusybBox grep detected, please install gnu grep, \"apk add --no-cache --upgrade grep\""
  exit 1
fi

if cp --help 2>&1 | grep -q -i "busybox"; then
  echo "BusybBox cp detected, please install coreutils, \"apk add --no-cache --upgrade coreutils\""
  exit 1
fi

################################################################################
# OPENEMAIL CONF CREATION                                                      #
################################################################################

if [ -f openemail.conf ]; then
  read -r -p "A config file exists and will be overwritten, are you sure you want to contine? [y/N] " response
  case $response in
    [yY][eE][sS]|[yY])
      mv openemail.conf openemail.conf_backup
      rm -f ./.env
    ;;
    *)
      exit 1
    ;;
  esac
fi

################################################################################
# DEFINE OPENEMAIL_HOSTNAME FROM FQDN HOSTNAME ONLY                            #
################################################################################

echo "Press enter to confirm the detected value '[value]' where applicable or enter a custom value."
while [ -z "${OPENEMAIL_HOSTNAME}" ]; do
  read -p "Hostname (FQDN): " -e OPENEMAIL_HOSTNAME
  DOTS=${OPENEMAIL_HOSTNAME//[^.]};
  if [ ${#DOTS} -lt 2 ] && [ ! -z ${OPENEMAIL_HOSTNAME} ]; then
    echo "${OPENEMAIL_HOSTNAME} is not a FQDN"
    OPENEMAIL_HOSTNAME=
  fi
done

################################################################################
# SETUP OPENEMAIL TIME ZONE                                                    #
################################################################################

if [ -a /etc/timezone ]; then
  DETECTED_TZ=$(cat /etc/timezone)
elif [ -a /etc/localtime ]; then
  DETECTED_TZ=$(readlink /etc/localtime|sed -n 's|^.*zoneinfo/||p')
fi

while [ -z "${OPENEMAIL_TZ}" ]; do
  if [ -z "${DETECTED_TZ}" ]; then
    read -p "Timezone: " -e OPENEMAIL_TZ
  else
    read -p "Timezone [${DETECTED_TZ}]: " -e OPENEMAIL_TZ
    [ -z "${OPENEMAIL_TZ}" ] && OPENEMAIL_TZ=${DETECTED_TZ}
  fi
done

################################################################################
# CALCULATE THE TOTAL MEMORY OF THE DOCKER HOST                                #
################################################################################

MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

################################################################################
# SKIP CLAMD CONTAINER IN LOW MEMORY SYSTEMS                                   #
################################################################################

if [ ${MEM_TOTAL} -le "2621440" ]; then
  echo "Installed memory is <= 2.5 GiB. It is recommended to disable ClamAV to prevent out-of-memory situations."
  echo "ClamAV can be re-enabled by setting SKIP_CLAMD=n in openemail.conf."
  read -r -p  "Do you want to disable ClamAV now? [Y/n] " response
  case $response in
    [nN][oO]|[nN])
      SKIP_CLAMD=n
      ;;
    *)
      SKIP_CLAMD=y
    ;;
  esac
else
  SKIP_CLAMD=n
fi

################################################################################
# DISABLE SOLR CONTAINER IN LOW MEMORY SYSTEMS                                 #
################################################################################

if [ ${MEM_TOTAL} -le "2097152" ]; then
  echo "Disabling Solr on low-memory system."
  SKIP_SOLR=y
elif [ ${MEM_TOTAL} -le "3670016" ]; then
  echo "Installed memory is <= 3.5 GiB. It is recommended to disable Solr to prevent out-of-memory situations."
  echo "Solr is a prone to run OOM and should be monitored. The default Solr heap size is 1024 MiB and should be set in openemail.conf according to your expected load."
  echo "Solr can be re-enabled by setting SKIP_SOLR=n in openemail.conf but will refuse to start with less than 2 GB total memory."
  read -r -p  "Do you want to disable Solr now? [Y/n] " response
  case $response in
    [nN][oO]|[nN])
      SKIP_SOLR=n
      ;;
    *)
      SKIP_SOLR=y
    ;;
  esac
else
  SKIP_SOLR=n
fi

[ ! -f ./data/conf/rspamd/override.d/worker-controller-password.inc ] \
&& echo '# Placeholder' > ./data/conf/rspamd/override.d/worker-controller-password.inc

################################################################################
#  SOME CONTAINERS ARE USING PUID AND GUID                                     #
################################################################################

PUID=$(id -u)
PGID=$(id -g)

################################################################################
#  GERNERATE DB USER PASSWORDS                                                 #
################################################################################

OE_DB_USER_PASSWD=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 | head -c 28)
OE_DB_ROOT_PASSWD=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 | head -c 28)

################################################################################
#  GERNERATE OPENEMAIL CONF                                                    #
################################################################################

cat << EOF > openemail.conf

################################################################################
#   OPENEMAIL WEB UI CONFIGURATIONS                                            #
################################################################################

##----------------------------------------------------------------------------##
##  OPENEMAIL FQQN                                                            ##
##----------------------------------------------------------------------------##
##  NOTE:                                                                     ##
##  Please note that "example.org" is not a valid hostname,                   ##
##  You should use a FQDN like "mai.example.org" here.                        ##
##----------------------------------------------------------------------------##

##----------------------------------------------------------------------------##
##  OPENEMAIL GLOBAL ADMIN USER                                               ##
##----------------------------------------------------------------------------##
##  Default admin user is "admin"                                             ##
##  Default password is "openemail"                                           ##
##----------------------------------------------------------------------------##

OPENEMAIL_HOSTNAME=${OPENEMAIL_HOSTNAME}

PUID=${PUID}
PGID=${PGID}

##----------------------------------------------------------------------------##
## SQL DATABASE CONFIGURATION                                                 ##
##----------------------------------------------------------------------------##

DBPASS=${OE_DB_USER_PASSWD}
DBROOT=${OE_DB_ROOT_PASSWD}
DBNAME=openemail
DBUSER=openemail

##----------------------------------------------------------------------------##
##  HTTP/S BINDINGS                                                           ##
##----------------------------------------------------------------------------##
##  While you should use HTTPS, you can skip                                  ##
##  in case of a SSL offloaded reverse proxy                                  ##
##  Do not_use IP:PORT in HTTP(S)_BIND or HTTP(S)_PORT                        ##
##----------------------------------------------------------------------------##

HTTP_PORT=80
HTTP_BIND=0.0.0.0
HTTPS_PORT=443
HTTPS_BIND=0.0.0.0

##----------------------------------------------------------------------------##
##  OTHER IP:PORT BINDINGS                                                    ##
##----------------------------------------------------------------------------##
##  Binding format: IPV4:PORT or 0.0.0.0:PORT                                 ##
##----------------------------------------------------------------------------##

SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
POP_PORT=110
POPS_PORT=995
SIEVE_PORT=4190
DOVEADM_PORT=127.0.0.1:19991
SQL_PORT=127.0.0.1:13306

##----------------------------------------------------------------------------##
## SET OPENEMAIL TIMEZONE                                                     ##
##----------------------------------------------------------------------------##

TZ=${OPENEMAIL_TZ}

##----------------------------------------------------------------------------##
##  OPENEMAIL COMPOSE FIXED PROJECT NAME                                      ##
##----------------------------------------------------------------------------##

COMPOSE_PROJECT_NAME=openemail

##----------------------------------------------------------------------------##
##  DISALLOW ACL FOR ANY USER                                                 ##
##----------------------------------------------------------------------------##
##  Set this to "allow" to enable the anyone pseudo user. Disabled by default.##
##  When enabled, ACL can be created, that apply to "All authenticated users" ##
##  This should probably only be activated on mail hosts, that are used       ##
##  exclusivly by one organisation. Otherwise a user might share data  with   ##
##  with too many other users.                                                ##
##----------------------------------------------------------------------------##

ACL_ANYONE=disallow

##----------------------------------------------------------------------------##
##  GARBAGE COLLECTOR CLEANUP TIMER                                           ##
##----------------------------------------------------------------------------##
##  Deleted domains and mailboxes are moved to                                ##
##  /var/vmail/_garbage/timestamp_sanitizedstring                             ##
##  How long should objects remain in the garbage                             ##
##  until they are being deleted? (value in minutes)                          ##
##  Check interval is hourly                                                  ##
##----------------------------------------------------------------------------##

MAILDIR_GC_TIME=1440

##----------------------------------------------------------------------------##
##  SETUP ADDITIONAL SANS FOR LETSENCRYPT CERTIFICATES                        ##
##----------------------------------------------------------------------------##
##  You can use wildcard records to create specific names for every domain    ##
##  that you add to openemail. You can follow the example below.              ##
##  Example: Add domains "example.com" and "example.net" to openemail.        ##
##  Then change ADDITIONAL_SAN to a value like:                               ##
##  ADDITIONAL_SAN=imap.*,smtp.*                                              ##
##  This will expand the certificates to                                      ##
##  "imap.example.com", "smtp.example.com", "imap.example.net",               ##
##  "imap.example.net"                                                        ##
##  Remember to add every domain you will add in the future.                  ##
##  You can also just add static names like below,                            ##
##  ADDITIONAL_SAN=srv1.example.net                                           ##
##  or combine wildcard and static names like below.                          ##
##  ADDITIONAL_SAN=imap.*,srv1.example.com                                    ##
##----------------------------------------------------------------------------##

##  OPENEMAIL COMPOSE FIXED PROJECT NAME                                      ##
##----------------------------------------------------------------------------##
ADDITIONAL_SAN=

##  TO SKIP RUNNING ACME-OPENEMAIL CONTAINER
##  Available options are: y/n

SKIP_LETS_ENCRYPT=n

## TO SKIP IPV4 CHECK IN ACME-OPENEMAIL CONTAINER
##  Available options are: y/n

SKIP_IP_CHECK=n

##----------------------------------------------------------------------------##
##  SKIP CLAMAV CONTAINER                                                     ##
##----------------------------------------------------------------------------##
##  Skip ClamAV (clamd-openemail) anti-virus container.                       ##
##  Rspamd will auto-detect a missing ClamAV container.                       ##
##  Available options are: y/n                                                ##
##----------------------------------------------------------------------------##

SKIP_CLAMD=${SKIP_CLAMD}

##----------------------------------------------------------------------------##
##  SKIP SOLR CONTAINER                                                       ##
##----------------------------------------------------------------------------##
##  OpenEMAIl uses Apache Solr container for mail discovery                   ##
##  Skip Solr on low-memory systems or if you do not want                     ##
##  to store a readable index of your mails in solr-vol-1.                    ##
##----------------------------------------------------------------------------##

SKIP_SOLR=${SKIP_SOLR}

##----------------------------------------------------------------------------##
##  SET SOLR HEAP SIZE                                                        ##
##----------------------------------------------------------------------------##
##  Solr heap size in MB, there is no recommendation,                         ##
##  Please refer to the solr documentation for more details                   ##
##  Solr is a prone to run OOM and should be monitored.                       ##
##  Unmonitored Solr setups are not recommended.                              ##
##----------------------------------------------------------------------------##

SOLR_HEAP=1024

##----------------------------------------------------------------------------##
##  ENABLE WATCHDOG CONTAINER                                                 ##
##----------------------------------------------------------------------------##
##  OpenEMAIl uses the watchdog-openemail container to                        ##
##  to restart unhealthy containers. Send notifications by mail               ##
##  mail wi DKIM signature, sent from watchdog@OPENEMAIL_HOSTNAME)            ##
##  Can be used multiple recipents or single recipients.                      ##
##----------------------------------------------------------------------------##

USE_WATCHDOG=y

# WATCHDOG_NOTIFYREPLICATION_HOSTS_EMAIL=a@example.com,b@example.com,c@example.com

WATCHDOG_NOTIFY_EMAIL=support@openemail.io

##----------------------------------------------------------------------------##
##  SET MAX LOG LINES STORED IN REDIS                                         ##
##----------------------------------------------------------------------------##
##  Max log lines per service to keep in Redis logs                           ##
##----------------------------------------------------------------------------##

LOG_LINES=9999

##----------------------------------------------------------------------------##
##  SET OPENEMAIL INTERNAL IPV4 SUBNET                                        ##
##----------------------------------------------------------------------------##
## Internal IPv4/24 subnet, format n.n.n which expands to n.n.n.0/24)         ##
##----------------------------------------------------------------------------##

IPV4_NETWORKREPLICATION_HOSTS=172.22.1

##----------------------------------------------------------------------------##
##  SET OPENEMAIL INTERNAL IPV6 SUBNET                                        ##
##----------------------------------------------------------------------------##
##  Internal IPv6 subnet in fc00::/7                                          ##
##----------------------------------------------------------------------------##

IPV6_NETWORK=fd4d:6169:6c63:6f77::/64

##----------------------------------------------------------------------------##
##  SET OPENEMAIL IPV4  OUTGOING SNAT                                         ##
##----------------------------------------------------------------------------##
##  Use the following  IPv4 for outgoing connections SNAT)                    ##
##  Posible options are: y/n. Uncomment the varible to be used                ##
##----------------------------------------------------------------------------##

# SNAT_TO_SOURCE=

##----------------------------------------------------------------------------##
##  SET OPENEMAIL IPV6  OUTGOING SNAT                                         ##
##----------------------------------------------------------------------------##
##  Use the following IPv6 for outgoing connections SNAT)                     ##
##  Posible options are: y/n. Uncomment the varible to be used                ##
##----------------------------------------------------------------------------##

#SNAT6_TO_SOURCE=

##----------------------------------------------------------------------------##
##  CREATE/OVERRIDE API KEY FOR WEB UI                                        ##
##----------------------------------------------------------------------------##
##  Use the following  IPv4 for outgoing connections SNAT)                    ##
##  You _must_ define API_ALLOW_FROM, which is a comma separated list         ##
##  of IPs. Uncomment the varible to be used                                  ##
##----------------------------------------------------------------------------##

#API_KEY=
#API_ALLOW_FROM=127.0.0.1,1.2.3.4

## END of openemail.conf ##
EOF

################################################################################
#  GERNERATE DB CONNECTOR.YAML                                                 #
################################################################################

mkdir -p data/env/common

cat << EOF > data/env/common/mysql_db_connector.yaml
OE_HOSTNAME: ${OPENEMAIL_HOSTNAME}
OE_SQL_SERVER_HOST: mysql-openemail
OE_SQL_SERVER_PORT: 389
OE_DB_BIND_USER: openemail
OE_DB_BIND_PASSWD: ${OE_DB_USER_PASSWD}
OE_DB_NAME: openemail
EOF

################################################################################
#  GENERATE OPENLDAP_CONNECTOR.YAML                                            #
################################################################################

mkdir -p data/env/common

cat << EOF > data/env/common/openldap_connector.yaml
OE_HOSTNAME: ${OPENEMAIL_HOSTNAME}
OE_LDAP_SERVER_HOST: openldap-openemail
OE_LDAP_SERVER_PORT: 389
OE_LDAP_BASE_DN: dc=openemail,dc=io
OE_LDAP_BIND_PASSWD: {SSHA}8taSnDDEB0BVYu3CmF6E8OyDk6ogP/T8
EOF

##  CREATE A DIRTORY TO HOLD SSL CERTIFICATES

mkdir -p data/assets/ssl

## COPY CERTIFICATES WIHTOUT OVERWRINTING EXISTING CERTIFICATES

cp -n data/assets/ssl-example/*.pem data/assets/ssl/

## CREATE A HARDLINK TO .ENV IN COMPOSE PROJECT DIRTORY

ln ./openemail.conf ./.env
