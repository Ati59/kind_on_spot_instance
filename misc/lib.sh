#!/usr/bin/env bash

# TODO ADD THIS:
# sudo sysctl fs.inotify.max_user_instances=1280
# sudo sysctl fs.inotify.max_user_watches=655360

KIND_HOME_DIR=${HOME}/.kube/kind

LIMA_VM_NAME=docker-qemu
LIMA_INET_NAME=lima0
MACOS_INET_IP=192.168.105.1

# Registries variables

LOCALHOST_CACHE_NAME='registry-local'
LOCALHOST_CACHE_PORT='5000'
LOCALHOST_CACHE_DIR=/opt/local_registries/docker-registry-localhost

DOCKERIO_CACHE_NAME='registry-dockerio'
DOCKERIO_CACHE_PORT='5030'
DOCKERIO_CACHE_DIR=/opt/local_registries/docker-registry-dockerio

QUAYIO_CACHE_NAME='registry-quayio'
QUAYIO_CACHE_PORT='5010'
QUAYIO_CACHE_DIR=/opt/local_registries/docker-registry-quayio

GCRIO_CACHE_NAME='registry-gcrio'
GCRIO_CACHE_PORT='5020'
GCRIO_CACHE_DIR=/opt/local_registries/docker-registry-gcrio

function get_variables() {
  # !!! NEED $NAME and $NUMBER to be set !!!
  # TODO: TEST IT :)

  if [[ $(uname -s) == "Darwin" ]]; then
    LIMA_IP_ADDR=$(limactl shell ${LIMA_VM_NAME} -- ip -o -4 a s | grep lima0 | grep -E -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2)
    BRIDGE_INT=$(limactl shell ${LIMA_VM_NAME} -- ifconfig | grep -Eo "br-[0-9a-z]*")
  fi
  IP_KIND=$(docker inspect ${NAME}-control-plane | jq -r '.[0].NetworkSettings.Networks[].IPAddress')
  NETWORK_KIND=$(echo ${IP_KIND} | awk -F. '{ print $1"."$2 }')
  DOCKER_NET="${NETWORK_KIND}.${NUMBER}.0/24"
  # DOCKER_NET=$(limactl shell docker-qemu -- docker network inspect kind | jq -r '.[0]|.IPAM.Config[0].Subnet')
}

function wait_docker_br() (
  while ! limactl shell ${LIMA_VM_NAME} -- ifconfig -a | grep -Eo "br-[0-9a-z]*"; do sleep 2; printf "Waiting for docker bridge\n"; done
)

function configure_network() {
  get_variables

  # Routing 172.XX (docker network) to the VM
  wait_docker_br

  # Add route from mac to docker net
  printf "Adding route to ${DOCKER_NET} via ${LIMA_IP_ADDR}.\nPlease enter MacBook root "
  sudo route -nv add -net ${DOCKER_NET} ${LIMA_IP_ADDR} 2>/dev/null

  # NAT from host IP to docker net
  printf "Authorizing ${MACOS_INET_IP} to access docker net\n"
  limactl shell ${LIMA_VM_NAME} -- sudo iptables -t filter -A FORWARD -4 -p tcp -s ${MACOS_INET_IP} -d ${DOCKER_NET} -j ACCEPT -i ${LIMA_INET_NAME} -o ${BRIDGE_INT}

  # Change docker socket ?
  # printf "Switching docker socket"
  # sudo rm -f /var/run/docker.sock
  # sudo ln -s ~/.lima/${LIMA_VM_NAME}/docker.sock /var/run/docker.sock
}

function delete_network() {
  get_variables

  printf "Deleting route to ${DOCKER_NET} via ${LIMA_IP_ADDR}.\n Please enter MacBook root password - "
  sudo route -nv delete -net ${DOCKER_NET} ${LIMA_IP_ADDR}

  # NAT from host to docker network
  printf "De-authorizing ${MACOS_INET_IP} to access docker net\n"
  limactl shell ${LIMA_VM_NAME} -- sudo iptables -t filter -D FORWARD -4 -p tcp -s ${MACOS_INET_IP} -d ${DOCKER_NET} -j ACCEPT -i ${LIMA_INET_NAME} -o ${BRIDGE_INT}

  # Deleting docker socket reference ?
  # sudo rm -f /var/run/docker.sock
}

function select_k8s_version() {
  # Kind images v0.1.16 (https://github.com/kubernetes-sigs/kind/releases)
  if [[ -z "${K8S_VERSION}" ]]; then
    K8S_VERSION="1.23"
  fi

  case ${K8S_VERSION} in
    "1.25")
      K8S_IMAGE_URL="kindest/node:v1.25.2@sha256:9be91e9e9cdf116809841fc77ebdb8845443c4c72fe5218f3ae9eb57fdb4bace"
      ;;
    "1.24")
      K8S_IMAGE_URL="kindest/node:v1.24.6@sha256:97e8d00bc37a7598a0b32d1fabd155a96355c49fa0d4d4790aab0f161bf31be1"
      ;;
    "1.23")
      K8S_IMAGE_URL="kindest/node:v1.23.12@sha256:9402cf1330bbd3a0d097d2033fa489b2abe40d479cc5ef47d0b6a6960613148a"
      ;;
    "1.22")
      K8S_IMAGE_URL="kindest/node:v1.22.15@sha256:bfd5eaae36849bfb3c1e3b9442f3da17d730718248939d9d547e86bbac5da586"
      ;;
    "1.21")
      K8S_IMAGE_URL="kindest/node:v1.21.14@sha256:ad5b7446dd8332439f22a1efdac73670f0da158c00f0a70b45716e7ef3fae20b"
      ;;
    "1.20")
      K8S_IMAGE_URL="kindest/node:v1.20.15@sha256:45d0194a8069c46483a0e509088ab9249302af561ebee76a1281a1f08ecb4ed3"
      ;;
    "1.19")
      K8S_IMAGE_URL="kindest/node:v1.19.16@sha256:a146f9819fece706b337d34125bbd5cb8ae4d25558427bf2fa3ee8ad231236f2"
      ;;
    *)
      printf "Unknown version : ${K8S_VERSION}\n"
      exit 1
      ;;
  esac
}

function delete-old-docker() {
  if [ $(docker ps --filter=name=$1 -aq|wc -l) -gt 0 ]; then
    docker rm $1 2>/dev/null
  fi
}

function is_running() {
  # Return 0 if running, 1 neither
  if [[ $(docker inspect -f '{{.State.Running}}' "$1") == "true" ]]; then
    return 0
  fi
  return 1
}

# local registry
function start-local-registry() {
  delete-old-docker "${LOCALHOST_CACHE_NAME}"
  if ! is_running ${LOCALHOST_CACHE_NAME}; then
    mkdir -p ${LOCALHOST_CACHE_DIR}
    printf "Launching local registry\n"
    docker run \
      -d --restart=always \
      -p ${LOCALHOST_CACHE_PORT}:${LOCALHOST_CACHE_PORT} \
      -v ${LOCALHOST_CACHE_DIR}:/var/lib/registry --name "${LOCALHOST_CACHE_NAME}" \
      registry:2
  fi
}

# docker.io mirror
function start-registry-docker() {
  delete-old-docker "${DOCKERIO_CACHE_NAME}"
  if ! is_running ${DOCKERIO_CACHE_NAME}; then
    cat > ${KIND_HOME_DIR}/dockerio-cache-config.yml <<EOF
version: 0.1
proxy:
  remoteurl: https://registry-1.docker.io
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :${DOCKERIO_CACHE_PORT}
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    mkdir -p ${DOCKERIO_CACHE_DIR}
    
    printf "Launching dockerio registry\n"
    docker run \
      -d --restart=always \
      -v ${KIND_HOME_DIR}/dockerio-cache-config.yml:/etc/docker/registry/config.yml \
      -p ${DOCKERIO_CACHE_PORT}:${DOCKERIO_CACHE_PORT} \
      -v ${DOCKERIO_CACHE_DIR}:/var/lib/registry --name "${DOCKERIO_CACHE_NAME}" \
      registry:2
  fi
}

# quay.io mirror
function start-registry-quayio() {
  delete-old-docker "${QUAYIO_CACHE_NAME}"
  if ! is_running ${QUAYIO_CACHE_NAME}; then
    cat > ${KIND_HOME_DIR}/quayio-cache-config.yml <<EOF
version: 0.1
proxy:
  remoteurl: https://quay.io
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :${QUAYIO_CACHE_PORT}
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    mkdir -p ${QUAYIO_CACHE_DIR}
    
    printf "Launching quayio registry\n"
    docker run \
      -d --restart=always \
      -v ${KIND_HOME_DIR}/quayio-cache-config.yml:/etc/docker/registry/config.yml \
      -p ${QUAYIO_CACHE_PORT}:${QUAYIO_CACHE_PORT} \
      -v ${QUAYIO_CACHE_DIR}:/var/lib/registry --name "${QUAYIO_CACHE_NAME}" \
      registry:2
  fi
}

# gcr.io mirror
function start-registry-gcr() {
  delete-old-docker "${GCRIO_CACHE_NAME}"
  if ! is_running ${GCRIO_CACHE_NAME}; then
    cat > ${KIND_HOME_DIR}/gcrio-cache-config.yml <<EOF
version: 0.1
proxy:
  remoteurl: https://gcr.io
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :${GCRIO_CACHE_PORT}
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    mkdir -p ${GCRIO_CACHE_DIR}

    printf "Launching gcr registry\n"
    docker run \
      -d --restart=always -v ${KIND_HOME_DIR}/gcrio-cache-config.yml:/etc/docker/registry/config.yml -p ${GCRIO_CACHE_PORT}:${GCRIO_CACHE_PORT} \
      -v ${GCRIO_CACHE_DIR}:/var/lib/registry --name "${GCRIO_CACHE_NAME}" \
      registry:2
  fi
}

# Installs a single clusters 
function create-kind-cluster() {
  NUMBER=$1
  NAME=$2

  select_k8s_version
  printf "Using kubernetes version : ${K8S_VERSION}\n"
  TWODIGITS=$(printf "%02d\n" ${NUMBER})

  if hostname -I 2>/dev/null; then
    myip=$(hostname -I | awk '{ print $1 }')
  else
    myip=$(ipconfig getifaddr en0)
  fi
  printf "Computer IP used would be : ${myip}\n"

  # STARTING REGISTRIES
  start-local-registry
  start-registry-docker
  start-registry-quayio
  start-registry-gcr

  mkdir -p $HOME/.kube/kind

  echo ${NUMBER} > $HOME/.kube/kind/${NAME}.number

  # KIND CLUSTER
  cat <<EOF > $HOME/.kube/kind/${NAME}-audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
EOF

  if [[ $(uname -s) == "Darwin" ]]; then
    API_SERVER_IP=$(limactl shell ${LIMA_VM_NAME} -- ip -o -4 a s | grep lima0 | grep -E -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2)
  else
    API_SERVER_IP=0.0.0.0
  fi

  cat << EOF > $HOME/.kube/kind/kind-${NAME}.yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
name: ${NAME}
featureGates:
  EphemeralContainers: true
nodes:
- role: control-plane
  image: ${K8S_IMAGE_URL}
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
        extraArgs:
          audit-log-path: /var/log/kubernetes/kube-apiserver-audit.log
          audit-policy-file: /etc/kubernetes/policies/${NAME}-audit-policy.yaml
        extraVolumes:
          - name: audit-policies
            hostPath: /etc/kubernetes/policies
            mountPath: /etc/kubernetes/policies
            readOnly: true
            pathType: "DirectoryOrCreate"
          - name: "audit-logs"
            hostPath: "/var/log/kubernetes"
            mountPath: "/var/log/kubernetes"
            readOnly: false
            pathType: DirectoryOrCreate
  extraMounts:
  - hostPath: $HOME/.kube/kind/${NAME}-audit-policy.yaml
    containerPath: /etc/kubernetes/policies/${NAME}-audit-policy.yaml
    readOnly: true
  # extraPortMappings:
  # - containerPort: 6443
  #   hostPort: 70${TWODIGITS}
# - role: worker
#   image: ${K8S_IMAGE_URL}
networking:
  apiServerAddress: "${API_SERVER_IP}"    # Cross cluster communication
  apiServerPort: 70${TWODIGITS}           # Cross cluster communication
  serviceSubnet: "10.${NUMBER}.0.0/16"
  podSubnet: "10.1${TWODIGITS}.0.0/16"
  # disableDefaultCNI: true               # do not install kindnet
  # kubeProxyMode: none                   # do not run kube-proxy
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${LOCALHOST_CACHE_PORT}"]
    endpoint = ["http://${LOCALHOST_CACHE_NAME}:${LOCALHOST_CACHE_PORT}"]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
    endpoint = ["http://${DOCKERIO_CACHE_NAME}:${DOCKERIO_CACHE_PORT}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io".tls]
    insecure_skip_verify = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
    endpoint = ["http://${QUAYIO_CACHE_NAME}:${QUAYIO_CACHE_PORT}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."quay.io".tls]
    insecure_skip_verify = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
    endpoint = ["http://${GCRIO_CACHE_NAME}:${GCRIO_CACHE_PORT}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."gcr.io".tls]
    insecure_skip_verify = true
EOF

  kind create cluster --name ${NAME} --config $HOME/.kube/kind/kind-${NAME}.yaml

  get_variables

  # kubectl config set-cluster kind-${NAME} --server=https://${myip}:70${TWODIGITS} --insecure-skip-tls-verify=true
  
  kubectl config set-cluster kind-${NAME} --server=https://${API_SERVER_IP}:70${TWODIGITS} --insecure-skip-tls-verify=true

  # NETWORK SETUP FOR DOCKER REGISTRIES
  docker network connect kind ${LOCALHOST_CACHE_NAME} || true
  docker network connect kind ${DOCKERIO_CACHE_NAME} || true
  docker network connect kind ${QUAYIO_CACHE_NAME} || true
  docker network connect kind ${GCRIO_CACHE_NAME} || true

  # METALLB CONFIGURATION FOR LOAD BALANCERS
  kubectl --context=kind-${NAME} apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.5/config/manifests/metallb-native.yaml
  ## kubectl --context=kind-${NAME} create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

  cat << EOF > $HOME/.kube/kind/metallb-${NAME}.yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: config
  namespace: metallb-system
spec:
  ipAddressPools:
  - my-ip-pool
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: my-ip-pool
  namespace: metallb-system
spec:
  addresses:
  - ${NETWORK_KIND}.${NUMBER}.1-${NETWORK_KIND}.${NUMBER}.254
EOF
  printf "Metallb network is ${DOCKER_NET}\n"

  printf "Waiting for metallb to be up before configuring it...\n"
  sleep 15 # Time to wait for cluster to spawn and avoid the "can't find metallb"
  kubectl --context=kind-${NAME} -n metallb-system wait pod --all --for condition=Ready --timeout -1s
  kubectl --context=kind-${NAME} apply -f $HOME/.kube/kind/metallb-${NAME}.yaml

  # See https://kind.sigs.k8s.io/docs/user/local-registry/
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${LOCALHOST_CACHE_PORT}}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

  # Renaming context
  kubectl config rename-context kind-${NAME} ${NAME}

  # Installating metrics-server
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm repo update
  helm upgrade --namespace kube-system --install metrics-server metrics-server/metrics-server --set 'args={"--kubelet-insecure-tls"}'

  # Configuring network (lima on MacOS)
  if [[ $(uname -s) == "Darwin" ]]; then
    configure_network
  fi
}

function delete-kind-cluster() {
  NAME=$1
  NUMBER=$(cat $HOME/.kube/kind/${NAME}.number)

  # Deleting network (lima on MacOS)
  if [[ $(uname -s) == "Darwin" ]]; then
    printf "Deleting metallb network is ${DOCKER_NET}\n"
    delete_network
  fi

  # Delete kind cluster
  kind delete cluster --name ${NAME}
  
  # Delete localhost configuration
  kubectl config delete-context ${NAME} || true

  rm -f $HOME/.kube/kind/kind${NAME}.yaml
  rm -f $HOME/.kube/kind/metallb-${NAME}.yaml
  rm -f $HOME/.kube/kind/${NAME}.number
  rm -f $HOME/.kube/kind/${NAME}-audit-policy.yaml
}
