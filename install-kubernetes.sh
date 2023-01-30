#!/bin/bash

#
# install-kubernetes.sh
# 
# Script to install Kubernetes on Rocky Linux 9.x
#

# Adapted from https://www.howtoforge.com/how-to-setup-kubernetes-cluster-with-kubeadm-on-rocky-linux/

function usage {
  echo
  echo "setup-k-rocky.sh <master|worker>"
  echo
}

# Periodically pause after executing a command so the user can observe the
# output before either proceeding or stopping
function next_step {
  if [[ $STEP_THROUGH_MODE==true ]]
  then
    echo
    echo "Next Step: $1"
    read -p "PROCEED?" PROCEED
    if [[ $PROCEED != "Y" && $PROCEED != "y" ]]
    then
      exit 0
    fi
  fi
}

# Default to just executing commands, otherwise pause periodically to observe command output
STEP_THROUGH_MODE=false

# Process command line parameters but leave last parameter as 'master' or 'worker' selection
while [[ "$1" != "" ]]
do

  case $1 in

    "-s" | "--step")
    STEP_THROUGH_MODE=true
    shift
    ;;

  esac

done

NODE_TYPE=${1:-"_null"}
if [[ $NODE_TYPE == "_null" ]] || [[ $NODE_TYPE != "master" && $NODE_TYPE != "worker" ]]
then
  if [[ $NODE_TYPE == "_null" ]]
  then
    echo "Error: You must supply a node type of either 'master' or 'worker'"
  elif [[ $NODE_TYPE != "master" && $NODE_TYPE != "worker" ]]
  then
    echo "Error: The node type you specified, $NODE_TYPE, is not 'master' or 'worker'"
  fi
  usage
  exit 1
fi

next_step "Open firewall ports required by Kubernetes on master or worker"

if [[ $NODE_TYPE == "master" ]]
then
  # MASTER node
  sudo firewall-cmd --add-port=6443/tcp --permanent
  sudo firewall-cmd --add-port=2379-2380/tcp --permanent
  sudo firewall-cmd --add-port=10250/tcp --permanent
  sudo firewall-cmd --add-port=10259/tcp --permanent
  sudo firewall-cmd --add-port=10257/tcp --permanent
else
  # WORKER NODE
  sudo firewall-cmd --add-port=10250/tcp --permanent
  sudo firewall-cmd --add-port=30000-32767/tcp --permanent
fi

# Allow traffic to flow from Flannel created subnets within Pod network 10.244.0.0/16
sudo firewall-cmd --zone=trusted --add-source=10.244.0.0/16 --permanent

# Common to Master and Worker nodes, activate all changes above
sudo firewall-cmd --reload
sudo firewall-cmd --list-all

next_step "Disable SELinux by entering Permissive mode"

sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

sestatus
 
next_step "Load modules overlay and br_netfilter"

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

next_step "Configure kernel for Kubernetes friendly bridge network and IPv4 forwarding"

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

next_step "Completely disable Swap"

sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

sudo swapoff -a
free -m

next_step "Configure Docker repository in yum"

sudo dnf -y install dnf-utils

sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

sudo dnf repolist
sudo dnf makecache

next_step "Install containerd.io from Docker repository"

sudo dnf -y install containerd.io

echo 
echo 
echo "WAIT -- CHECK /ETC/CONTAINERD/CONFIG.TOML FOR ONE CHANGE REQUIRED"
echo
echo

next_step "Configure containerd for SystemdCgroups"

sudo mv /etc/containerd/config.toml /etc/containerd/config.toml.orig

# Generate a base containerd config file to tmp file
sudo containerd config default > /tmp/config.toml

# Copy tmp file to target destination. Two steps because: sudo
sudo mv /tmp/config.toml /etc/containerd/config.toml

# Enable handling where systemd is top owner of Cgroups
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

next_step "Start containerd daemon"

sudo systemctl enable --now containerd

sudo systemctl is-enabled containerd
sudo systemctl status containerd

next_step "Configure Kubernetes repository"

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
EOF

sudo dnf repolist
sudo dnf makecache

next_step "Install kubelet kubeadm kubectl"

sudo dnf -y install kubelet kubeadm kubectl --disableexcludes=kubernetes

next_step "Enable kublet on this node"

sudo systemctl enable --now kubelet

next_step "Install CNI plugin: Flannel"

sudo mkdir -p /opt/bin/
sudo curl -fsSLo /opt/bin/flanneld https://github.com/flannel-io/flannel/releases/download/v0.19.0/flanneld-amd64
sudo chmod +x /opt/bin/flanneld

if [[ $NODE_TYPE == "master" ]]
then

  next_step "Ensure br_netfilter module running"

  lsmod | grep br_netfilter

  next_step "Use kubeadm to pull container images for control plane"

  sudo kubeadm config images pull

  next_step "Create the control plane with kubeadm init"

  sudo kubeadm init --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.9.134 \
  --cri-socket=unix:///run/containerd/containerd.sock

  next_step "Setup local $HOME/kube/config for kubectl"

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  next_step "Use kubectl to show cluster info"

  kubectl cluster-info

  next_step "Use kubectl apply to activate flannel network containers"

  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  next_step "Use kubectl to get all pods in all namespaces"
 
  kubectl get pods --all-namespaces

elif [[ $NODE_TYPE == "worker" ]]
then

  echo "NEXT: Manually issue a kubeadm join command to join the cluster."
  echo
  echo "Example:"
  echo
  echo "kubeadm join 192.168.9.134:6443 --token notthe.actualtoken \
  	  --discovery-token-ca-cert-hash sha256:veryrandomlongstringofharshedtokeninformation"
  echo
  echo "You can generate a new cluster join tokent with:"
  echo
  echo "kubeadm token create --print-join-command"
  echo

fi
