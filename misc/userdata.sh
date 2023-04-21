#!/usr/bin/env bash

# SSH config
sed -i 's/#PermitRootLogin/PermitRootLogin/' /etc/ssh/sshd_config
sed -i 's/#AllowAgentForwarding/AllowAgentForwarding/' /etc/ssh/sshd_config
sed -i 's/#AllowTcpForwarding/AllowTcpForwarding/' /etc/ssh/sshd_config
sed -i 's/^.*\ ssh-rsa/ssh-rsa/' /root/.ssh/authorized_keys
systemctl restart sshd.service

# Pre-req
apt-get update -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip \
    build-essential

# Docker-ce
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.17.0/kind-linux-amd64
chmod +x ./kind
mv ./kind /usr/local/bin/

# Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f /kubectl
printf "alias k=kubectl\n" >> /root/.bashrc

# Jq
apt-get install -y jq

# Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm -f get_helm.sh

# Env preparation
mkdir -p /.kube/kind
printf "alias ll='ls -all --color'\n" >> /root/.bashrc

# Install my kind lib
aws s3 cp s3://${s3_bucket_name}/${zip_filename} /tmp
unzip /tmp/${zip_filename} -d /tmp
chmod +x /tmp/kind_lib.sh
mv /tmp/kind_lib.sh /usr/local/bin/
source /usr/local/bin/kind_lib.sh
printf "source /usr/local/bin/kind_lib.sh\n" >> /root/.bashrc

# Create kind cluster
create-kind-cluster 16 mgmt
mv /.kube /root
# This is for VM restart
ln -s /root/.kube /.kube 
