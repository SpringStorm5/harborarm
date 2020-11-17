#!/bin/bash

#Harbor on Ubuntu 18.04

# #Prompt for the user to ask if the install should use the IP Address or Fully Qualified Domain Name of the Harbor Server
# PS3='Would you like to install Harbor based on IP or FQDN? '
# select option in IP FQDN
# do
    case $1 in
        IP)
            IPorFQDN=$(hostname -I|cut -d" " -f 1)
            break;;
        FQDN)
            IPorFQDN=$(hostname -f)
            break;;
     esac
# done

# Housekeeping
mkdir -p /var/www/
cd /var/www/
apt-get install -y git
systemctl daemon-reload
systemctl enable harbor.service
systemctl enable linnovate.service
apt update -y
swapoff --all
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
ufw disable #Do Not Do This In Production
echo "Housekeeping done"

#Install Latest Stable Docker Release
apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update -y
apt-get install -y docker-ce 
tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries" : ["$IPorFQDN:443","$IPorFQDN:80","0.0.0.0/0"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
mkdir -p /etc/systemd/system/docker.service.d
groupadd docker
MAINUSER=$(logname)
sudo usermod -aG docker ${USER}
su - ${USER}
usermod -aG docker $MAINUSER
systemctl daemon-reload
systemctl restart docker
echo "Docker Installation done"

#Install Latest Stable Docker Compose Release
COMPOSEVERSION=$(curl -s https://github.com/docker/compose/releases/latest/download 2>&1 | grep -Po [0-9]+\.[0-9]+\.[0-9]+)
curl -L "https://github.com/docker/compose/releases/download/$COMPOSEVERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
echo "Docker Compose Installation done"


sleep 60
#Install Latest Stable Harbor Release
#cd /var/www/
# HARBORVERSION=$(curl -s https://github.com/goharbor/harbor/releases/latest/download 2>&1 | grep -Po [0-9]+\.[0-9]+\.[0-9]+)
# curl -s https://api.github.com/repos/goharbor/harbor/releases/latest | grep browser_download_url | grep online | cut -d '"' -f 4 | wget -qi -
#cp /var/lib/waagent/custom-script/download/1/harbor-online-installer-v2.1.1.tgz .
#tar xvf harbor-online-installer-v2.1.1
#tar xvf harbor-online-installer-v$HARBORVERSION.tgz
#cd harbor
# Create Self-Signed OpenSSL Certs
#cd /var/www/harbor/

mkdir -p /var/www/harbor/data/secret/cert
cd /var/www/harbor/data/secret/cert
FQDN=$(hostname -I|cut -d" " -f 1)
echo subjectAltName = IP:"$(hostname --ip-address)" > extfile.cnf
openssl req -newkey rsa:4096 -nodes -sha256 -keyout ca.key -x509 -days 3650 -out ca.crt -subj "/C=US/ST=CA/L=San Francisco/O=VMware/OU=IT Department/CN=${FQDN}"
openssl req -newkey rsa:4096 -nodes -sha256 -keyout ${FQDN}.key -out ${FQDN}.csr -subj "/C=US/ST=CA/L=San Francisco/O=VMware/OU=IT Department/CN=${FQDN}"
openssl x509 -req -days 3650 -in ${FQDN}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -extfile extfile.cnf -out ${FQDN}.crt
cd /var/www/harbor/
rm -rf ./prepare
cat <<\EOF >> prepare
#!/bin/bash
set +e

# If compiling source code this dir is harbor's make dir.
# If installing harbor via pacakge, this dir is harbor's root dir.
if [[ -n "$HARBOR_BUNDLE_DIR" ]]; then
    harbor_prepare_path=$HARBOR_BUNDLE_DIR
else
    harbor_prepare_path="$( cd "$(dirname "$0")" ; pwd -P )"
fi
echo "prepare base dir is set to ${harbor_prepare_path}"
data_path=$(grep '^[^#]*data_volume:' ${harbor_prepare_path}/harbor.yml | awk '{print $NF}')

# If previous secretkeys exist, move it to new location
previous_secretkey_path=/data/secretkey
previous_defaultalias_path=/data/defaultalias

if [ -f $previous_secretkey_path ]; then
    mkdir -p $data_path/secret/keys
    mv $previous_secretkey_path $data_path/secret/keys
fi
if [ -f $previous_defaultalias_path ]; then
    mkdir -p $data_path/secret/keys
    mv $previous_defaultalias_path $data_path/secret/keys
fi

# Clean up input dir
rm -rf ${harbor_prepare_path}/input
# Create a input dirs
mkdir -p ${harbor_prepare_path}/input
input_dir=${harbor_prepare_path}/input

set -e

# Copy harbor.yml to input dir
if [[ ! "$1" =~ ^\-\- ]] && [ -f "$1" ]
then
    cp $1 $input_dir/harbor.yml
else
    cp ${harbor_prepare_path}/harbor.yml $input_dir/harbor.yml
fi

# Create secret dir
secret_dir=${data_path}/secret
config_dir=$harbor_prepare_path/common/config
cert_dir=$harbor_prepare_path/data/secret/cert

# Run prepare script
docker run --rm -v $input_dir:/input:z \
                    -v $data_path:/data:z \
                    -v $harbor_prepare_path:/compose_location:z \
                    -v $config_dir:/config:z \
                    -v $secret_dir:/secret:z \
                    -v $cert_dir:/hostfs:z \
                    goharbor/prepare:v1.10.5 $@

echo "Clean up the input dir"
# Clean up input dir
rm -rf ${harbor_prepare_path}/input
EOF
chmod +x ./prepare
cat ./prepare | grep cert_dir

cat <<\EOF >> harbor.yml
# Configuration file of Harbor

# The IP address or hostname to access admin UI and registry service.
# DO NOT use localhost or 127.0.0.1, because Harbor needs to be accessed by external clients.
hostname: 10.0.0.4

# http related config
http:
  # port for http, default is 80. If https enabled, this port will redirect to https port
  port: 80

# https related config
https:
  # https port for harbor, default is 443
  port: 443
  # The path of cert and key files for nginx
  certificate: /ca.crt
  private_key: /ca.key

# Uncomment external_url if you want to enable external proxy
# And when it enabled the hostname will no longer used
# external_url: https://10.0.0.4:8433

# The initial password of Harbor admin
# It only works in first time to install harbor
# Remember Change the admin password from UI after launching Harbor.
harbor_admin_password: Harbor12345

# Harbor DB configuration
database:
  # The password for the root user of Harbor DB. Change this before any production use.
  password: root123
  # The maximum number of connections in the idle connection pool. If it <=0, no idle connections are retained.
  max_idle_conns: 50
  # The maximum number of open connections to the database. If it <= 0, then there is no limit on the number of open connections.
  # Note: the default number of connections is 100 for postgres.
  max_open_conns: 100

# The default data volume
data_volume: /data

# Harbor Storage settings by default is using /data dir on local filesystem
# Uncomment storage_service setting If you want to using external storage
# storage_service:
#   # ca_bundle is the path to the custom root ca certificate, which will be injected into the truststore
#   # of registry's and chart repository's containers.  This is usually needed when the user hosts a internal storage with self signed certificate.
#   ca_bundle:

#   # storage backend, default is filesystem, options include filesystem, azure, gcs, s3, swift and oss
#   # for more info about this configuration please refer https://docs.docker.com/registry/configuration/
#   filesystem:
#     maxthreads: 100
#   # set disable to true when you want to disable registry redirect
#   redirect:
#     disabled: false

# Clair configuration
clair:
  # The interval of clair updaters, the unit is hour, set to 0 to disable the updaters.
  updaters_interval: 12

jobservice:
  # Maximum number of job workers in job service
  max_job_workers: 10

notification:
  # Maximum retry count for webhook job
  webhook_job_max_retry: 10

chart:
  # Change the value of absolute_url to enabled can enable absolute url in chart
  absolute_url: disabled

# Log configurations
log:
  # options are debug, info, warning, error, fatal
  level: info
  # configs for logs in local storage
  local:
    # Log files are rotated log_rotate_count times before being removed. If count is 0, old versions are removed rather than rotated.
    rotate_count: 50
    # Log files are rotated only if they grow bigger than log_rotate_size bytes. If size is followed by k, the size is assumed to be in kilobytes.
    # If the M is used, the size is in megabytes, and if G is used, the size is in gigabytes. So size 100, size 100k, size 100M and size 100G
    # are all valid.
    rotate_size: 200M
    # The directory on your host that store log
    location: /var/log/harbor

  # Uncomment following lines to enable external syslog endpoint.
  # external_endpoint:
  #   # protocol used to transmit log to external endpoint, options is tcp or udp
  #   protocol: tcp
  #   # The host of external endpoint
  #   host: localhost
  #   # Port of external endpoint
  #   port: 5140

#This attribute is for migrator to detect the version of the .cfg file, DO NOT MODIFY!
_version: 1.10.0

# Uncomment external_database if using external database.
# external_database:
#   harbor:
#     host: harbor_db_host
#     port: harbor_db_port
#     db_name: harbor_db_name
#     username: harbor_db_username
#     password: harbor_db_password
#     ssl_mode: disable
#     max_idle_conns: 2
#     max_open_conns: 0
#   clair:
#     host: clair_db_host
#     port: clair_db_port
#     db_name: clair_db_name
#     username: clair_db_username
#     password: clair_db_password
#     ssl_mode: disable
#   notary_signer:
#     host: notary_signer_db_host
#     port: notary_signer_db_port
#     db_name: notary_signer_db_name
#     username: notary_signer_db_username
#     password: notary_signer_db_password
#     ssl_mode: disable
#   notary_server:
#     host: notary_server_db_host
#     port: notary_server_db_port
#     db_name: notary_server_db_name
#     username: notary_server_db_username
#     password: notary_server_db_password
#     ssl_mode: disable

# Uncomment external_redis if using external Redis server
# external_redis:
#   host: redis
#   port: 6379
#   password:
#   # db_index 0 is for core, it's unchangeable
#   registry_db_index: 1
#   jobservice_db_index: 2
#   chartmuseum_db_index: 3
#   clair_db_index: 4

# Uncomment uaa for trusting the certificate of uaa instance that is hosted via self-signed cert.
# uaa:
#   ca_file: /path/to/ca

# Global proxy
# Config http proxy for components, e.g. http://my.proxy.com:3128
# Components doesn't need to connect to each others via http proxy.
# Remove component from `components` array if want disable proxy
# for it. If you want use proxy for replication, MUST enable proxy
# for core and jobservice, and set `http_proxy` and `https_proxy`.
# Add domain to the `no_proxy` field, when you want disable proxy
# for some special registry.
proxy:
  http_proxy:
  https_proxy:
  # no_proxy endpoints will appended to 127.0.0.1,localhost,.local,.internal,log,db,redis,nginx,core,portal,postgresql,jobservice,registry,registryctl,clair,chartmuseum,notary-server
  no_proxy:
  components:
    - core
    - jobservice
    - clair
EOF

#cp harbor.yml.tmpl harbor.yml
#sed -i "s/reg.mydomain.com/$IPorFQDN/g" harbor.yml
# sed -e '/port: 443$/ s/^#*/#/' -i harbor.yml
# sed -e '/https:$/ s/^#*/#/' -i harbor.yml
#sed -e '/\/your\/certificate\/path$/ s/^#*/#/' -i harbor.yml
#sed -e '/\/your\/private\/key\/path$/ s/^#*/#/' -i harbor.yml
# PASS=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
# sed -i "s/.*harbor_admin_password: Harbor12345*/harbor_admin_password: $PASS/" harbor.yml

cd /var/www/harbor/
pwd
ls
sleep 120
./install.sh --with-clair --with-chartmuseum
docker ps
echo -e "Harbor Installation Complete \n\nPlease log out and log in or run the command 'newgrp docker' to use Docker without sudo\n\nLogin to your harbor instance:\n docker login -u admin -p Harbor12345 $IPorFQDN"

