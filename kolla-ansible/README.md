# OpenStack 資源建立與跨節點連通驗證

## 資源建立與驗證操作流程
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

