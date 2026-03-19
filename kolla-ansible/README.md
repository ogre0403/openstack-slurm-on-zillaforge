# Kolla-Ansible

## 容器設定說明

### 設定容器內帳號的 UID/GID

本映像檔的設計目標是完全相容於 Docker 與 Singularity (Apptainer) 兩種執行環境，且在兩種環境下皆能正確處理使用者權限。Docker 與 Singularity 在設計哲學上有著根本的差異：

* Docker 預設為 Root： 容器啟動時預設具有 root 權限，通常會在 entrypoint.sh 中動態修改 UID/GID 並降權（Drop privileges）為一般使用者來執行主程式。

* Singularity 預設為 Host User： 容器啟動時，強制綁定外部主機的當前使用者身分與權限（Non-root）。任何試圖在容器內執行需要 root 權限的操作都會遭遇致命錯誤。

#### 使用Docker Conatiner

`kolla-ansible/docker-compose.yaml` 內可透過環境變數設定容器中 `kolla` 帳號的 UID/GID：

```yaml
environment:
    - PUID=1000
    - PGID=1000
```
如果主機上的開發帳號不是 `1000:1000`，可以直接調整 `PUID` 與 `PGID` 成對應值。
這樣做的目的，是讓容器內的 `kolla` 使用者和主機上的使用者維持相同的 UID/GID，避免 bind mount 進容器的檔案出現權限不一致的問題。
對這個專案來說，`/etc/kolla` 與 `/etc/openstack` 都是從主機掛載進容器


#### 使用 Singularity Conatiner

在Dockerfile裡，將 kolla 的 UID/GID 設定為 666000666 / 999000999 這種一般主機絕對不會使用的超高數值。
如此一來，當 Singularity 以主機一般常用的UID進入容器時，容器內找不到 UID 的紀錄時，Singularity 就會自動在容器記憶體中動態生成正確的user紀錄。
從此 whoami 與 $USER 將完美一致，徹底消滅身分錯亂。

在 `kolla-ansible/docker-compose.yaml`，Singularity 中運行時 (id -u != 0)，腳本偵測到自己沒有 root 權限，主動放棄所有修改系統權限的嘗試，直接以當前主機使用者的原始身分執行命令。


### 為什麼要設定 `ANSIBLE_COLLECTIONS_PATH`

`Dockerfile` 內先設定：

```shell
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections
```

之後再執行：

```shell
kolla-ansible install-deps
```

原因是 `install-deps` 會安裝 `kolla-ansible` 需要的 Ansible collections/roles，而這些 dependency 需要被安裝到一個明確且在執行時也能被 Ansible 找到的位置。把路徑固定在 `ANSIBLE_COLLECTIONS_PATH` 有幾個好處：

* 建置階段與執行階段使用相同搜尋路徑，避免 `ansible-galaxy` 裝好了，但執行 `kolla-ansible` 時找不到 collection
* 不依賴使用者家目錄下的預設路徑，降低因切換使用者或變更 UID/GID 後產生的路徑差異
* 將 dependency 放在系統層路徑，容器重啟後仍維持一致的執行環境

`docker-compose.yaml` 內也保留同樣的 `ANSIBLE_COLLECTIONS_PATH` 設定，目的是確保互動式進入容器或直接執行 `kolla-ansible`/`ansible` 指令時，Ansible 仍然會從同一個位置載入已安裝的 collections。

## Inventory 說明

`kolla-ansible` 的指令目前是以整個 inventory 目錄作為輸入：

```shell
kolla-ansible deploy -i /etc/kolla/inventroy/
```

這代表 Ansible 不是只讀單一檔案，而是會把 `inventroy/` 目錄下的多個 inventory 檔案一起合併成最終的 inventory。這個專案目前有四個檔案：

* `01-controller`
* `05-compute`
* `10-inventory-template`
* `99-vars`

檔名前面的數字是為了表達分層順序：先定義主機，再補 service group 關係，最後再套用共用變數。




## OpenStack 資源建立與驗證操作流程
在透過 Kolla-Ansible 部署好的 OpenStack 環境中，建立兩個分別位於不同 Compute Node 的 CirrOS 虛擬機 (VM)，並驗證兩者可以正常啟動且跨節點進行網路連通。目前無對外網路，僅驗證內網互通。

*(以下 OpenStack 相關指令皆在 `kolla_ansible` 容器中執行，並事先 `source /etc/kolla/admin-openrc.sh`)*

### 步驟一：下載並上傳 Image
```bash
curl -sLo /tmp/cirros.img http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
openstack image create 'cirros' --file /tmp/cirros.img --disk-format qcow2 --container-format bare --public
```

### 步驟二：建立 Flavor
```bash
openstack flavor create --id 1 --ram 256 --disk 1 --vcpus 1 m1.nano
```

### 步驟三：建立虛擬網路 (Network & Subnet)
建立給 VM 內部通訊使用的 Private Network 與 Subnet。
```bash
openstack network create private-net
openstack subnet create --network private-net --subnet-range 192.168.100.0/24 private-subnet
```

### 步驟四：設定安全群組 (Security Group)
修改預設的安全群組，允許 ICMP (Ping) 及所有內部連線進入。
```bash
SEC_GROUP=$(openstack security group list --project admin -f value -c ID | head -n 1)
openstack security group rule create --protocol any --ingress $SEC_GROUP
```

### 步驟五：建立 SSH 金鑰
```bash
ssh-keygen -t rsa -b 2048 -f /tmp/id_rsa -N ''
openstack keypair create --public-key /tmp/id_rsa.pub mykey
```

### 步驟六：準備 Cloud-init 測試腳本
因無 Floating IP 可直接 SSH，我們透過 User-Data 在虛擬機開機時自動執行互相 Ping 對方 Fixed IP 的腳本，並將結果輸出至 Console Log 中。

```bash
cat << 'EOF' > /tmp/userdata_vm1.sh
#!/bin/sh
for i in $(seq 1 30); do
  if ping -c 1 -W 2 192.168.100.22 > /dev/null; then
    echo "PING_SUCCESS_FROM_VM1_TO_VM2" > /dev/console
    break
  fi
  sleep 5
done
EOF

cat << 'EOF' > /tmp/userdata_vm2.sh
#!/bin/sh
for i in $(seq 1 30); do
  if ping -c 1 -W 2 192.168.100.11 > /dev/null; then
    echo "PING_SUCCESS_FROM_VM2_TO_VM1" > /dev/console
    break
  fi
  sleep 5
done
EOF
```

### 步驟七：將 VM 部署至不同 Compute Node
利用 `--availability-zone nova:<host>` 強制指定部署的 Compute Node，並配置指定的 Fixed IP。
```bash
# 在 opsk-02-compute-tf 部署 vm1 (IP: 192.168.100.11)
openstack server create --image cirros --flavor m1.nano \
  --nic net-id=private-net,v4-fixed-ip=192.168.100.11 --key-name mykey \
  --availability-zone nova:opsk-02-compute-tf.novalocal \
  --user-data /tmp/userdata_vm1.sh vm1

# 在 opsk-03-compute-tf 部署 vm2 (IP: 192.168.100.22)
openstack server create --image cirros --flavor m1.nano \
  --nic net-id=private-net,v4-fixed-ip=192.168.100.22 --key-name mykey \
  --availability-zone nova:opsk-03-compute-tf.novalocal \
  --user-data /tmp/userdata_vm2.sh vm2
```

### 步驟八：驗證跨節點連通
等待 VM 狀態轉為 ACTIVE 並開機完成後，檢查兩台機器的 Console Log：
```bash
openstack console log show vm1 | grep PING_SUCCESS
# 輸出: PING_SUCCESS_FROM_VM1_TO_VM2

openstack console log show vm2 | grep PING_SUCCESS
# 輸出: PING_SUCCESS_FROM_VM2_TO_VM1
```

