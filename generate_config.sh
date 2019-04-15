#!/bin/bash

set -o pipefail

if grep --help 2>&1 | grep -q -i "busybox"; then
  echo "BusybBox grep detected, please install gnu grep, \"apk add --no-cache --upgrade grep\""
  exit 1
fi
if cp --help 2>&1 | grep -q -i "busybox"; then
  echo "BusybBox cp detected, please install coreutils, \"apk add --no-cache --upgrade coreutils\""
  exit 1
fi

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

echo "Press enter to confirm the detected value '[value]' where applicable or enter a custom value."
while [ -z "${OPENEMAIL_HOSTNAME}" ]; do
  read -p "Hostname (FQDN): " -e OPENEMAIL_HOSTNAME
  DOTS=${OPENEMAIL_HOSTNAME//[^.]};
  if [ ${#DOTS} -lt 2 ] && [ ! -z ${OPENEMAIL_HOSTNAME} ]; then
    echo "${OPENEMAIL_HOSTNAME} is not a FQDN"
    OPENEMAIL_HOSTNAME=
  fi
done

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

MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

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

[ ! -f ./data/conf/rspamd/override.d/worker-controller-password.inc ] && echo '# Placeholder' > ./data/conf/rspamd/override.d/worker-controller-password.inc

HOSTNAME=${OPENEMAIL_HOSTNAME}
DOMAIN=$(hostname -d)
SLD=$(echo $(hostname -d) | cut -f1 -d .)
TLD=$(echo $(hostname -d) | cut -f2 -d .)
BASE_DN=dc=$(echo ${SLD}),dc=$(echo ${TLD})
LDAP1=ldap1.${DOMAIN}
LDAP2=ldap2.${DOMAIN}
PUID=$(id -u)
PGID=$(id -g)
ADMINPASS=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 | head -c 28)

cat << EOF > openemail.conf
# ------------------------------
# openemail web ui configuration
# ------------------------------
# example.org is _not_ a valid hostname, use a fqdn here.
# Default admin user is "admin"
# Default password is "moohoo"

OPENEMAIL_HOSTNAME=${OPENEMAIL_HOSTNAME}

PUID=${PUID}
PGID=${PGID}

# The following variables to used by Letsencrypt proxy

SUBDOMAINS=dev,fd,nc,admin 
EXTRA_DOMAINS=
# ------------------------------
# SQL database configuration
# ------------------------------

DBNAME=openemail
DBUSER=openemail

# Please use long, random alphanumeric strings (A-Za-z0-9)

DBPASS=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 | head -c 28)
DBROOT=$(LC_ALL=C </dev/urandom tr -dc A-Za-z0-9 | head -c 28)

# ------------------------------
# HTTP/S Bindings
# ------------------------------

# You should use HTTPS, but in case of SSL offloaded reverse proxies:

HTTP_PORT=80
HTTP_BIND=0.0.0.0

HTTPS_PORT=443
HTTPS_BIND=0.0.0.0

# ------------------------------
# Other bindings
# ------------------------------
# You should leave that alone
# Format: 11.22.33.44:25 or 0.0.0.0:465 etc.
# Do _not_ use IP:PORT in HTTP(S)_BIND or HTTP(S)_PORT

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

# Your timezone

TZ=${OPENEMAIL_TZ}

# Fixed project name

COMPOSE_PROJECT_NAME=openemail

# Set this to "allow" to enable the anyone pseudo user. Disabled by default.
# When enabled, ACL can be created, that apply to "All authenticated users"
# This should probably only be activated on mail hosts, that are used exclusivly by one organisation.
# Otherwise a user might share data with too many other users.
ACL_ANYONE=disallow

# Garbage collector cleanup
# Deleted domains and mailboxes are moved to /var/vmail/_garbage/timestamp_sanitizedstring
# How long should objects remain in the garbage until they are being deleted? (value in minutes)
# Check interval is hourly

MAILDIR_GC_TIME=1440

# Skip ClamAV (clamd-openemail) anti-virus (Rspamd will auto-detect a missing ClamAV container) - y/n

SKIP_CLAMD=${SKIP_CLAMD}

# Skip Solr on low-memory systems or if you do not want to store a readable index of your mails in solr-vol-1.
SKIP_SOLR=${SKIP_SOLR}

# Solr heap size in MB, there is no recommendation, please see Solr docs.
# Solr is a prone to run OOM and should be monitored. Unmonitored Solr setups are not recommended.
SOLR_HEAP=1024

# Enable watchdog (watchdog-openemail) to restart unhealthy containers (experimental)

USE_WATCHDOG=y

# Send notifications by mail (no DKIM signature, sent from watchdog@OPENEMAIL_HOSTNAME)
# Can by multiple rcpts, NO quotation marks

#WATCHDOG_NOTIFYREPLICATION_HOSTS_EMAIL=a@example.com,b@example.com,c@example.com
WATCHDOG_NOTIFY_EMAIL=support@openemail.io

# Max log lines per service to keep in Redis logs

LOG_LINES=9999

# Internal IPv4 /24 subnet, format n.n.n (expands to n.n.n.0/24)

IPV4_NETWORKREPLICATION_HOSTS=172.22.1

# Internal IPv6 subnet in fc00::/7

IPV6_NETWORK=fd4d:6169:6c63:6f77::/64

# Use this IPv4 for outgoing connections (SNAT)

#SNAT_TO_SOURCE=

# Use this IPv6 for outgoing connections (SNAT)

#SNAT6_TO_SOURCE=

# Create or override API key for web uI
# You _must_ define API_ALLOW_FROM, which is a comma separated list of IPs
# API_KEY allowed chars: a-z, A-Z, 0-9, -

#API_KEY=
#API_ALLOW_FROM=127.0.0.1,1.2.3.4

# OpenLDAP FusionDirectory Enviorenment Variables
HOSTNAME=${OPENEMAIL_HOSTNAME}
BACKEND=mdb
LOG_LEVEL=256
DOMAIN=${DOMAIN}
ADMIN_PASS=${ADMINPASS}
CONFIG_PASS=${ADMINPASS}
FUSIONDIRECTORY_ADMIN_USER=fdadmin
FUSIONDIRECTORY_ADMIN_PASS=${ADMINPASS}
ORGANIZATION=(Openemail}
BASE_DN=${BASE_DN}
ENABLE_READONLY_USER=true
READONLY_USER_USER=reader
READONLY_USER_PASS={ADMINPASS}
ENABLE_TLS=true
TLS_CRT_FILENAME=fullchain.pem
TLS_KEY_FILENAME=privkey.pem
TLS_CA_CRT_FILENAME=fullchain.pem
TLS_ENFORCE=false
TLS_CIPHER_SUITE=ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256
TLS_VERIFY_CLIENT=never
SSL_HELPER_PREFIX=ldap
ENABLE_REPLICATION=false
REPLICATION_CONFIG_SYNCPROV=(binddn="cn=admin,cn=config"\ bindmethod=simple\ credentials="openemail"\ searchbase="cn=config"\ type=refreshAndPersist\ retry="60 +"\ timeout=1)
REPLICATION_DB_SYNCPROV=(binddn="cn=admin,${BASE_DN}"\ bindmethod=simple\ credentials="admin"\ searchbase=${BASE_DN}\ type=refreshAndPersist\ interval=00:00:00:10\ retry="60 +"\ timeout=1)
REPLICATION_HOSTS=(ldap://${LDAP1}\ ldap://${LDAP2})
REMOVE_CONFIG_AFTER_SETUP=false

# FusionDirectory Web UI Enviorenment Variables

LDAP1_HOST=openldap-fusiondirectory
LDAP1_BASE_DN=${BASE_DN}
LDAP1_ADMIN_DN=cn=admin,${BASE_DN}
LDAP1_ADMIN_PASS={ADMINPASS}
LDAP1_NAME=Primary

# Openemail Database Docker Container host
DBHOST=mariadb


EOF

mkdir -p data/assets/ssl

# copy but don't overwrite existing certificate
cp -n data/assets/ssl-example/*.pem data/assets/ssl/

ln ./openemail.conf ./.env