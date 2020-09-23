Kubernetes-Cluster-WorkNode
=========================


 > Introduction: [Kubernetes](https://kubernetes.io/docs/concepts/overview/what-is-kubernetes/)

---

## Version
`Rev: 1.0.3`

---

## Description

  - Kubernetes 是用於自動部署、擴展和管理容器化應用程式的開源系統。 <br />
  - 該系統由 Google 設計並捐贈給 Cloud Native Computing Foundation 來使用。 <br />
  - 它旨在提供「跨主機集群的自動部署、擴展以及運行應用程式容器的平台」。 <br />
  - 它支持一系列容器工具, 包括 Docker 等。

---

##  Usage

  - For more information.

    ```bash
    $ bash k8s-clusterWorkerNode.sh <-h|--help>
    ```

  - Add work node to cluster
    
    ```bash
    # The first time deployment the work node
    $ bash k8s-clusterWorkerNode.sh <-p|--precondition> <-w|--work>
    ```

  - lookup the token in Master node `${HOME}/.kube/k8s.log`

    ```bash
    $ cat ${HOME}/.kube/k8s.log
    $ kubeadm join $vip:8443 \
              --token $token \
              --discovery-token-ca-cert-hash sha256:${hash}
    ```

  - Delete nodes from Master

    ```bash
    $ kubectl drain $Master_node_hostname \
              --delete-local-data \
              --force \
              --ignore-daemonsets > /dev/null 2>&1 || true


    $ kubectl delete node $Master_node_hostname > /dev/null 2>&1 || true
    ```

  - First initial Master nodes via kubeadmin

    ```bash
    $ kubeadm init --pod-network-cidr=10.244.0.0/16 \
             --service-cidr=10.96.0.0/12 \
             --apiserver-advertise-address=$IP  \
             --kubernetes-version="v${kube_revsion}" \
             | tee $log
    ```


---

## Troubleshooting

  - If bridge name `cni0` conflict with another network interface.

    ```bash
    $ ip link del cni0
    $ ip link del flannel.1
    ```

  - Encountered the following info about kubernetes dashboard.

    **`configmaps is forbidden: User "system:serviceaccount:kube-system:kubernetes-dashboard" cannot list configmaps in the namespace "default"`**

    - Method 1

      ```bash
      # create the admin user for dashboard
      $ kubectl create clusterrolebinding add-on-cluster-admin \
                --clusterrole=cluster-admin \
                --serviceaccount=kube-system:kubernetes-dashboard
      ```

    - Method 2

      ```yml
      # kube-dashboard-access.yaml
      apiVersion: rbac.authorization.k8s.io/v1beta1
      kind: ClusterRoleBinding
      metadata:
      name: kubernetes-dashboard
      labels:
        k8s-app: kubernetes-dashboard
      roleRef:
        apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cluster-admin
      subjects:
       - kind: ServiceAccount
         name: kubernetes-dashboard
         namespace: kube-system
      ```

      ```bash
      $ kubectl apply -f kube-dashboard-access.yaml
      ```

  - Encountered the following info about kubernetes network service port.

    **`The Service "my-nginx" is invalid: spec.ports[0].nodePort: Invalid value: 80: provided port is not in the valid range. The range of valid ports is 30000-32767`**

    ```bash
    $ vim /etc/kubernetes/manifests/kube-apiserver.yaml
    ```

    ```yml
    spec:
      containers:
        - command:
          - kube-apiserver
          ...
          ...
          - --service-node-port-range=1-65535
    ```

    ```bash
    $ kubectl apply -f kube-apiserver.yaml
    $ systemctl restart kubelet
    ```

---

## Contact

  - **Author: Jay.Chang**

