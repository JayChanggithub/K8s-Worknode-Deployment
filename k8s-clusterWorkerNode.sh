#!/bin/bash

# define globals variables
NC1='\033[0m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[0;33m'
CWD=$PWD
revision=$(grep 'Rev:' README.md | grep -Po '(\d+\.){2}\d+')
__file__=$(basename $0)
pre_condition=False
work_node=False
reset_node=False

function Usage
{
    echo -en "${YELLOW}"
    more << EOF
Usage: bash $__file__ [option] argv

-h, --help                display how to use this scripts.
-v, --version             display the $__file__ version.
-r, --reset               delete kubernetes cluster cache.
-p, --precondition        pre-condition the kubernates node.
-w, --work                setup the work node configuration.

EOF
    echo -en "${NC1}"
    return 0
}

function checkstatus
{
    case $? in
        "0")
            echo -en "${YELLOW}"
            more << "EOF"

 ________ _           _        __
|_   __  (_)         (_)      [  |
  | |_ \_|_  _ .--.  __  .--.  | |--.
  |  _| [  |[ `.-. |[  |( (`\] | .-. |
 _| |_   | | | | | | | | `'.'. | | | |
|_____| [___|___||__|___|\__) )___]|__]

EOF
            echo -en "${NC1}";;
        "1")
            echo -en "${RED}"
            more << "EOF"
 ______     _ _
 |  ____|  (_) |
 | |__ __ _ _| |
 |  __/ _` | | |
 | | | (_| | | |
 |_|  \__,_|_|_|
EOF
            echo -en "${NC1}";;
    esac
}

function Updatehost
{
    local host=$1
    if [ $(cat /etc/hosts | grep -v '^#' | grep -co "$host") -ne 2 ]; then
        tee -a /etc/hosts << EOF
$host    registry.ipt-gitlab
$host    ipt-gitlab.ies.inventec
EOF
    else
        printf "${BLUE} %s %s %s ${NC1} \n" "config: " "/etc/hosts" "already exist !"
    fi
    return 0
}

function checknet
{
    local count=0
    local network=$1
    local USERNAME='admin'
    local PASSWORD='ZD7EdEpF9qCYpDpu'
    local proxy="http://${USERNAME}:${PASSWORD}@10.99.104.251:8081/"
    while true
    do
        if [ $(rpm -qa | egrep -ico "curl") -eq 0 ]; then
            ping $network -c 1 -q > /dev/null 2>&1
        else
            curl $network -c 1 -q > /dev/null 2>&1
        fi
        case $? in
            0)
                echo -e "network success.\n"
                return 0;;
            *)
                export {https,http}_proxy=$proxy

                # check fail count
                if [ $count -ge 4 ]; then
                    echo -e "network disconnection.\n"
                    exit 1
                fi;;
        esac
        count=$(( count + 1 ))
    done
}

function precondition
{
    # set timezone
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-local-rtc 0

    # disable selinux
    setenforce 0
    sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config

    # disable firewalld
    systemctl disable firewalld
    systemctl stop firewalld

    # enable ipv4 forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # disable swap
    sed -i 's/[^#]\(.*swap.*\)/# \1/g' /etc/fstab
    swapoff --all

    # Some users on RHEL/CentOS 7 have reported issues with traffic
    # being routed incorrectly due to iptables being bypassed
    tee /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 10
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.ip_local_port_range = 1  65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
kernel.pid_max = 1000000
net.ipv4.tcp_max_syn_backlog=1024
net.core.somaxconn = 10240
net.ipv4.tcp_fin_timeout = 30
net.netfilter.nf_conntrack_tcp_be_liberal = 1
net.netfilter.nf_conntrack_tcp_loose = 1
net.netfilter.nf_conntrack_max = 3200000
net.netfilter.nf_conntrack_buckets = 1600512
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.ipv4.tcp_timestamps = 1
kernel.msgmax = 65536
kernel.msgmnb = 163840
EOF
    sysctl --system

    modprobe br_netfilter

    if [ $(cut -f1 -d ' '  /proc/modules \
           | grep -e ip_vs -e nf_conntrack_ipv4 \
           | wc -l) -ne 5 ] || [ $(lsmod | grep -e ip_vs -e nf_conntrack_ipv4 \
           | awk '{print $1}' | grep -ci p_vs) -ne 4 ]; then

        tee /etc/sysconfig/modules/ipvs.modules << EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF
        chmod +x /etc/sysconfig/modules/ipvs.modules
        bash /etc/sysconfig/modules/ipvs.modules
    fi
}

function setrepo
{
    local epelconfig='/etc/yum.repos.d/epel.repo'
    local centos_base='/etc/yum.repos.d/CentOS-Base.repo'

    yum install -y yum-plugin-priorities epel-release

    if [ -f $centos_base ]; then
        sed -i 's/\]$/\]\npriority=1/g' $centos_base
    fi

    if [ -f $epelconfig ]; then
        sed -i 's/\]$/\]\npriority=5/g' $epelconfig
        sed -i 's/enabled=1/enabled=0/g' $epelconfig
    fi
}

function checkpkg
{
    local rigistry_server='http://registry.ipt-gitlab:8081'
    local kube_version='1.15.1'
    local packages=(kubectl
                    kubelet
                    kubeadm
                    docker-ce
                    nc
                    ipvsadm
                    bridge-utils
                    ntpdate
                    tree
                    bash-completion)
        tee /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
exclude=kube*
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
EOF
    yum clean all
    yum makecache
    yum update -y

    if [ "$(command -v kubeadm)" != "" ] &&
       [ "$(kubelet --version | grep -Eo '([0-9]+\.){2}[0-9]+')" != "$kube_version" ]; then
        yum remove -y kubectl kubelet kubeadm
    fi
    for p in "${packages[@]}"
    do
        if [ $(rpm -qa | egrep -ci "$p") -eq 0 ] ||
           [ "$(command -v "$p")" == "" ]; then
            case "$p" in
                "kubectl"|"kubelet"|"kubeadm")
                    yum install -y ${p}-${kube_version} --disableexcludes=kubernetes
                    ;;
                "docker-ce")
                    yum install -y yum-utils \
                        device-mapper-persistent-data lvm2
                    yum-config-manager --add-repo \
                        https://download.docker.com/linux/centos/docker-ce.repo
                    yum-config-manager --enable docker-ce-edge
                    yum makecache fast
                    yum install -y docker-ce
                    if [ $? -ne 0 ]; then
                        yum --enablerepo=epel install $p -y
                    fi
                    ;;
                "nc"|"ipvsadm"|"bridge-utils"|"ntpdate"|"bash-completion")
                    yum install -y $p
                    if [ $? -ne 0 ]; then
                        yum --enablerepo=epel install $p -y
                    fi
                    ;;

                "tree")
                    yum install -y $p || \
                    yum --enablerepo=epel install $p -y
                    ;;
            esac
        else
            printf "%-40s [${YELLOW} %s ${NC1}]\n" \
                   " * package: $p " \
                   " exist "
            continue
        fi
    done


    # setup docker configuration
    tee /etc/docker/daemon.json << EOF
{
    "bip": "172.27.0.1/16",
    "dns": ["10.99.2.59","10.99.6.60"],
    "insecure-registries":["$rigistry_server"],
    "live-restore": true,
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "max-concurrent-downloads": 6,
    "log-opts": {
        "max-size": "10k",
        "max-file": "3"
    }
}
EOF

    # docker service restart
    systemctl enable docker.service
    systemctl start docker.service
}

function modifyConf
{
    local dir_list=('/etc/cni/net.d' '/etc/kubernetes/manifests')
    if [ -f /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf ]; then
        if [ $(cat /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf \
             | egrep -ci 'cgroup-driver') -eq 0 ]; then

            # change the kubernetes cgroup-driver the same as docker
            sed -i \
                "4a\Environment=\"KUBELET_CGROUP_ARGS=--cgroup-driver=systemd\ --runtime-cgroups=\/systemd\/system\.slice\ --kubelet-cgroups=\/systemd\/system.slice\"" \
                /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
        fi
    fi

    # avoid the kubelet warnings flooding systemd logs
    if [ -f /etc/sysconfig/kubelet ]; then
        sed -i "s/^KUBELET_EXTRA_ARGS=.*/KUBELET_EXTRA_ARGS\=--runtime-cgroups=\/systemd\/system.slice\ --kubelet\-cgroups=\/systemd\/system.slice/g" \
            /etc/sysconfig/kubelet
    fi

    # create cni0 configuration folder
    for d in "${dir_list[@]}"
    do
        if [ ! -d "$d" ]; then
            mkdir -p $d
        fi
    done

    systemctl daemon-reload
    systemctl enable kubelet
   
    if [ $(cat /root/.bash_profile | grep -ci '(kubectl completion bash)') -ne 1 ]; then
        echo "source <(kubectl completion bash)" >> ~/.bash_profile
        source ~/.bash_profile 
    fi
}

function syncntp
{
    local ntp_server='ntp.api.bz'

    # show information
    echo -en "${YELLOW}"
    more << EOF
Show NTP synchronized information
`printf '%0.s-' {1..100}; echo`

Before time: $(date '+[%F %T]')
Synchronized info: $(ntpdate -u $ntp_server)
IP Address: $(ip route get 1 | awk '{print $NF;exit}')
Hostname: $(hostname)
After time: $(date '+[%F %T]')

`printf '%0.s-' {1..100}; echo`
EOF
    echo -en "${NC1}"
}

function reset
{
    local count=0
    local f_list=('/etc/kubernetes'
                  '/var/lib/etcd'
                  '/var/lib/kubelet'
                  '/var/lib/cni/'
                  '/etc/cni/net.d/'
                  "$HOME/.kube/")


    if [ "$(kubectl get configmaps kube-proxy -n kube-system -o yaml \
         | awk '/mode/{print $2}' > /dev/null 2>&1)" != "ipvs" ]; then
        iptables -F
        iptables -t nat -F
        iptables -t mangle -F
        iptables -X
    else
        ipvsadm --clear
    fi

    # stop kubelet service
    kubeadm reset --force > /dev/null 2>&1
    systemctl daemon-reload
    systemctl stop kubelet
    systemctl stop docker
    systemctl stop etcd

    # delete network bridge
    if [ -n "$(ifconfig -a | grep -E 'cni0|flannel.1')" ]; then
        ifconfig cni0 down
        ifconfig flannel.1 down
        ip link delete cni0
        ip link delete flannel.1
    fi

    # check whether empty
    for d in ${f_list[@]}
    do
        if [ -n "$(ls $d)" ]; then
            rm -rf ${d}/*
        fi
    done

    systemctl daemon-reload
    systemctl restart docker

    # clean up docker process cache
    if [ $(docker ps -a -q -f "status=exited" | wc -l) -ne 0 ]; then
        printf "%s\t%30s${YELLOW} %s ${NC1}]\n" \
               " Starting clear 'Exited' containers...,   " "[" "okay." \
               | sed -E s',^ ,,'g
        docker rm $(docker ps -a -q -f "status=exited")
    fi

    # clean up the docker images cache
    if [ $(docker images -f "dangling=true" -q | wc -l) -ne 0 ]; then
        printf "%s\t%30s${YELLOW} %s ${NC1}]\n" \
               " Starting clear 'Untagged/Dangling' images...,   " "[" "okay." \
               | sed -E s',^ ,,'g
        docker image rmi $(docker images -f "dangling=true" -q)
    fi

    if [ $? -eq 0 ]; then
        printf "%s\t%30s${YELLOW} %s ${NC1}]\n" \
               " Kubernetes service clean done,   " "[" "okay." \
               | sed -E s',^ ,,'g
        printf "%s\t%30s${YELLOW} %s ${NC1}]\n" \
               " Clear docker cache done,   " "[" "okay." \
               | sed -E s',^ ,,'g
    fi
}

function main
{
    if [ "$pre_condition" == "True" -a "$reset_node" == "True" ]; then
        printf "${RED} %s ${NC1}\n" "arguments conflict, none support the precondition and reset node at same time."         
        exit 3
    fi
   
    if [ "$reset_node" == "True" ]; then
        reset
        return 0
    fi
    
    Updatehost 10.99.104.242

    # prerequisites
    if [ "$pre_condition" == "True" ]; then
        checknet www.google.com
        precondition
        setrepo
        checkpkg
        modifyConf
        syncntp
    fi

    if [ "$work_node" == "True" ]; then
        printf "${BLUE} %s ${NC1} \n" "Please look up add node token in Master Node: $HOME/.kube/k8s.log"
        return 0
    fi
}

echo -en "${BLUE}"
more << "EOF"
  ______   _____ _________   ______   ________ ____   ____ ________ _____      ___   _______
.' ____ \ |_   _|  _   _  | |_   _ `.|_   __  |_  _| |_  _|_   __  |_   _|   .'   `.|_   __ \
| (___ \_|  | | |_/ | | \_|   | | `. \ | |_ \_| \ \   / /   | |_ \_| | |    /  .-.  \ | |__) |
 _.____`.   | |     | |       | |  | | |  _| _   \ \ / /    |  _| _  | |   _| |   | | |  ___/
| \____) | _| |_   _| |_     _| |_.' /_| |__/ |   \ ' /    _| |__/ |_| |__/ \  `-'  /_| |_
 \______.'|_____| |_____|   |______.'|________|    \_/    |________|________|`.___.'|_____|

EOF
echo -en "${NC1}"

if [ "$#" -eq 0 ]; then
    printf "${RED} %s ${NC1}\n" "Invalid arguments, try '-h/--help' for more information."
    exit 1
fi

while [ "$1" != "" ]
do
    case $1 in
        -h|--help)
            Usage
            exit 0
            ;;
        -v|--version)
            printf "${BLUE} %s ${NC1}\n" "$__file__ version: ${revision}"
            exit 0
            ;;
        -p|--precondition)
            pre_condition=True
            ;;
        -w|--work)
            work_node=True
            ;;
        -r|--reset)
            reset_node=True
            ;;
        *)
            printf "${RED} %s ${NC1}\n" "Invalid arguments, try '-h/--help' for more information."
            exit 1
            ;;
    esac
    shift
done

main
