#!/bin/bash

declare network_interface=$(grep auto /etc/network/interfaces | tail -1 | cut -d ' ' -f 2)
echo "This is network interface" $network_interface
declare bond=$(cat /etc/network/interfaces | tail -1)
sed -i -e "s/$bond//g" /etc/network/interfaces
sed -i -e "s/$network_interface inet manual/$network_interface inet static\n    address $HOST_IP\n    netmask $NETMASK\n    broadcast $BROAD_IP/g" /etc/network/interfaces
ifdown  $network_interface
ifup  $network_interface

declare host=$HOST_IP
echo "This is network host" $host
#sed -i -e "s/$network_interface inet manual/$network_interface inet static\n    address $HOST_IP\n    netmask 255.255.255.240/g" /etc/network/interfaces
#ifdown  $network_interface
#ifup  $network_interface

declare host=$HOST_IP
echo "This is network host" $host

declare ip=$(($(echo $host | cut -d "." -f 4 | xargs) + 1))
declare nginx_ip="$(echo $host | cut -d "." -f 1).$(echo $host | cut -d "." -f 2).$(echo $host | cut -d "." -f 3).$ip"
echo "This is nginx host" $nginx_ip
sudo ip addr add $nginx_ip/$IP_CIDR dev $network_interface

export NGINX_IP=$nginx_ip

sudo apt update -y
sudo apt-get install -y wget ca-certificates

# export packet variables
export FACILITY="onprem"
export PACKET_API_AUTH_TOKEN="dummy_token"
export PACKET_API_URL=""
export PACKET_CONSUMER_TOKEN="dummy_token"
export PACKET_ENV="onprem"
export PACKET_VERSION="onprem"
export ROLLBAR_TOKEN="###################"
export ROLLBAR_DISABLE=1

# ENVs for CLI
#export TINKERBELL_GRPC_AUTHORITY=127.0.0.1:42113
#export TINKERBELL_CERT_URL=http://127.0.0.1:42114/cert

# Give permission to binaries
chmod +x /usr/local/bin/tinkerbell

#setup git and git lfs
sudo apt install -y git
wget https://github.com/git-lfs/git-lfs/releases/download/v2.9.0/git-lfs-linux-amd64-v2.9.0.tar.gz
tar -C /usr/local/bin -xzf git-lfs-linux-amd64-v2.9.0.tar.gz
rm git-lfs-linux-amd64-v2.9.0.tar.gz
git lfs install

# Get docker and docker-compose
curl -L get.docker.com | bash
curl -L "https://github.com/docker/compose/releases/download/1.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Setup go
wget https://dl.google.com/go/go1.12.13.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.12.13.linux-amd64.tar.gz go/
rm go1.12.13.linux-amd64.tar.gz

# set GOPATH
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
echo 'export GOPATH=$GOPATH:$HOME/go' >> ~/.bashrc
echo 'export PATH=$PATH:$GOPATH' >> ~/.bashrc
source ~/.bashrc

mkdir -p /packet/nginx
cp -r /tmp/workflow/* /packet/nginx
#extract boot files
pushd /packet/nginx ; tar xvzf boot-files.gz ; popd

cd /tmp
curl 'https://packet-osie-uploads.s3.amazonaws.com/osie-v19.10.23.00-n=55,c=be58d67,b=master.tar.gz' -o osie.tar.gz
tar -zxvf osie.tar.gz
cd /tmp/'osie-v19.10.23.00-n=55,c=be58d67,b=master'
cp -r grub /packet/nginx/misc/osie/current
cp modloop-x86_64 /packet/nginx/misc/osie/current

# get the tinkerbell repo
mkdir -p ~/go/src/github.com/packethost
cd ~/go/src/github.com/packethost
git clone --branch setup_provisioner_and_worker https://$GIT_USER:$GIT_PASS@github.com/packethost/tinkerbell.git
cd ~/go/src/github.com/packethost/tinkerbell
sed -i -e "s/localhost\"\,/localhost\"\,\n    \"$host\"\,/g" tls/server-csr.in.json
make

# build the certidicates
docker-compose up --build -d certs
sleep 10
#Update host to trust registry certificate
mkdir -p /etc/docker/certs.d/$host

# docker login to pull images from quay.io 
docker login -u=$DOCKER_USER -p=$DOCKER_PASS quay.io 

#pull the worker image and push into private registry
docker pull quay.io/packet/tinkerbell-worker:workflow
docker tag quay.io/packet/tinkerbell-worker:workflow $host/worker:latest
docker login -u=$TINKERBELL_REGISTRY_USER -p=$TINKERBELL_REGISTRY_PASS $host
docker push $host/worker:latest

# Start the stack
docker-compose up --build -d registry
sleep 5

cd ~/go/src/github.com/packethost/tinkerbell
cp certs/ca.pem /etc/docker/certs.d/$host/ca.crt

#copy certificate in tinkerbell
cp certs/ca.pem /packet/nginx/misc/tinkerbell/workflow/ca.pem

#push worker image into it
docker login -u=$TINKERBELL_REGISTRY_USER -p=$TINKERBELL_REGISTRY_PASS $host
docker push $host/worker:latest

docker-compose up --build -d db
sleep 20
docker-compose up --build -d cserver
sleep 10
docker-compose up --build -d tinkerbell
sleep 20
docker-compose up --build -d boots
sleep 20
docker-compose up --build -d nginx
sleep 5
docker-compose up --build -d hegel

# Update ip tables
iptables -t nat -I POSTROUTING -s $host/$IP_CIDR  -j MASQUERADE
iptables -t nat -I FORWARD -d $host/$IP_CIDR  -j ACCEPT
iptables -t nat -I FORWARD -s $host/$IP_CIDR  -j ACCEPT