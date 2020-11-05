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
git clone https://github.com/SpringStorm5/arm_azure/
cp ./arm_azure/harbor.service /etc/systemd/system/harbor.service
mkdir -p /opt/linnovate
cp ./arm_azure/post.sh /opt/linnovate/post.sh
chmod 755 /opt/linnovate/post.sh
cp ./arm_azure/linnovate.service /etc/systemd/system/linnovate.service
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



#Install Latest Stable Harbor Release
cd /var/www/
HARBORVERSION=$(curl -s https://github.com/goharbor/harbor/releases/latest/download 2>&1 | grep -Po [0-9]+\.[0-9]+\.[0-9]+)
curl -s https://api.github.com/repos/goharbor/harbor/releases/latest | grep browser_download_url | grep online | cut -d '"' -f 4 | wget -qi -
tar xvf harbor-online-installer-v$HARBORVERSION.tgz
cd harbor
# Create Self-Signed OpenSSL Certs
cd /var/www/harbor/
mkdir -p ./data/secret/cert
cd /var/www/harbor/data/secret/cert
FQDN=$(hostname -I|cut -d" " -f 1)
echo subjectAltName = IP:"$(hostname --ip-address)" > extfile.cnf
openssl req -newkey rsa:4096 -nodes -sha256 -keyout ca.key -x509 -days 3650 -out ca.crt -subj "/C=US/ST=CA/L=San Francisco/O=VMware/OU=IT Department/CN=${FQDN}"
openssl req -newkey rsa:4096 -nodes -sha256 -keyout ${FQDN}.key -out ${FQDN}.csr -subj "/C=US/ST=CA/L=San Francisco/O=VMware/OU=IT Department/CN=${FQDN}"
openssl x509 -req -days 3650 -in ${FQDN}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -extfile extfile.cnf -out ${FQDN}.crt
cd /var/www/harbor/
cat <<\EOF >> prepare.yml
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
#cp ../arm_azure/harbor.yml harbor.yml
#cp ../arm_azure/prepare ./prepare
cp harbor.yml.tmpl harbor.yml
# sed -i "s/reg.mydomain.com/$IPorFQDN/g" harbor.yml
# sed -e '/port: 443$/ s/^#*/#/' -i harbor.yml
# sed -e '/https:$/ s/^#*/#/' -i harbor.yml
#sed -e '/\/your\/certificate\/path$/ s/^#*/#/' -i harbor.yml
#sed -e '/\/your\/private\/key\/path$/ s/^#*/#/' -i harbor.yml
# PASS=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
# sed -i "s/.*harbor_admin_password: Harbor12345*/harbor_admin_password: $PASS/" harbor.yml
./install.sh --with-clair --with-chartmuseum
docker ps
echo -e "Harbor Installation Complete \n\nPlease log out and log in or run the command 'newgrp docker' to use Docker without sudo\n\nLogin to your harbor instance:\n docker login -u admin -p Harbor12345 $IPorFQDN"

