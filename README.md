# 資源動態調度


## How To

```shell
# build and launch kolla-ansible via docker compose
make kolla-up

# access kolla-ansible container as kolla user
make kolla-exec

# generate password
kolla-genpwd

# kolla-ansible deploy step
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/
kolla-ansible prechecks         -i /etc/kolla/inventroy/
kolla-ansible pull              -i /etc/kolla/inventroy/
kolla-ansible deploy            -i /etc/kolla/inventroy/
kolla-ansible post-deploy       -i /etc/kolla/inventroy/
```

## 容器設定說明

### 設定容器內帳號的 UID/GID

`kolla-ansible/docker-compose.yaml` 內可透過環境變數設定容器中 `kolla` 帳號的 UID/GID：

```yaml
environment:
    - PUID=1000
    - PGID=1000
```

容器啟動時，`kolla-ansible/entrypoint.sh` 會使用這兩個值執行：

```shell
groupmod -o -g "$PGID" kolla
usermod  -o -u "$PUID" kolla
```

這樣做的目的，是讓容器內的 `kolla` 使用者和主機上的使用者維持相同的 UID/GID，避免 bind mount 進容器的檔案出現權限不一致的問題。對這個專案來說，`/etc/kolla` 與 `/etc/openstack` 都是從主機掛載進容器，若 UID/GID 不一致，常見情況會是：

* 容器內可以看到檔案，但無法修改
* 產生的新檔案在主機上變成其他擁有者
* `kolla-ansible` 執行過程中出現權限錯誤

如果主機上的開發帳號不是 `1000:1000`，可以直接調整 `PUID` 與 `PGID` 成對應值。

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

### 這些檔案如何產生

其中三個檔案是 Terraform 套用後自動產生的，來源在 `infra_openstack/main.tf` 的 `local_file` resource：

* `01-controller` 由 `infra_openstack/templates/01-controller.tpl` 渲染產生
* `05-compute` 由 `infra_openstack/templates/05-compute.tpl` 渲染產生
* `99-vars` 由 `infra_openstack/templates/99-vars.tpl` 渲染產生

也就是說，當 `infra_openstack` 建出 OpenStack 節點後，Terraform 會順手把節點名稱、IP、SSH 帳密等資訊寫到 `kolla-ansible/etc/kolla/inventroy/` 底下。這三個檔案也被列在 `.gitignore`，表示它們屬於環境相關的生成物，不是固定手寫設定。

`10-inventory-template` 則不同。它目前沒有在 Terraform 內被渲染或覆蓋，屬於版本庫中手動維護的靜態 inventory 模板檔，作用是補上 Kolla-Ansible 需要的群組繼承結構。

### 四個 inventory 檔案之間的關連

四個檔案不是彼此獨立，而是一起拼成完整 inventory：

* `01-controller` 定義 controller 節點，同時把同一台主機放進 `control`、`network`、`storage` 等基礎群組，另外保留 `deployment` 的 `localhost`
* `05-compute` 定義 compute 節點，把除了第一台 controller 之外的節點放進 `compute` 群組
* `10-inventory-template` 不放具體主機，而是用 `:children` 把前面定義好的 `control`、`network`、`compute`、`storage`、`monitoring`、`deployment` 組成 Kolla 需要的服務群組，例如 `baremetal`、`common`、`nova`、`neutron`、`mariadb`、`rabbitmq`
* `99-vars` 透過 `[baremetal:vars]` 對前述 baremetal 主機統一套用連線參數，例如 `ansible_user`、`ansible_password`、`ansible_become` 與 SSH 選項

實際上可以把它理解成三層：

* 主機層：`01-controller`、`05-compute`
* 服務拓樸層：`10-inventory-template`
* 共用變數層：`99-vars`

### 逐檔說明

#### `01-controller`

這個檔案來自 `infra_openstack/templates/01-controller.tpl`，由 Terraform 的 `local_file.controller` 產生。內容會使用 `zillaforge_server.nodes[0]` 的名稱與 IP，將第一台節點定義為：

* `control`
* `network`
* `storage`

代表目前部署拓樸是把 controller、network、storage 角色集中在第一台主機上。

此外它還定義：

* `monitoring`：目前為空，表示不部署 monitoring
* `deployment`：固定使用 `localhost ansible_connection=local`

`deployment` 這組不是 OpenStack 節點，而是讓部分需要在部署端本機執行的 Kolla-Ansible 工作有對應的 inventory group。

#### `05-compute`

這個檔案來自 `infra_openstack/templates/05-compute.tpl`，由 Terraform 的 `local_file.compute` 產生。它會從 `zillaforge_server.nodes` 中切掉第一台 controller，將其餘節點全部放進 `compute` 群組。

也就是說：

* 第一台節點進 `01-controller`
* 第二台之後的節點進 `05-compute`

因此 compute 節點數量是跟 Terraform 建出的節點數連動的，不需要手動維護 inventory 主機列表。

#### `10-inventory-template`

這個檔案是 Kolla-Ansible 的群組拓樸模板。它本身不定義主機 IP，而是假設前面幾個檔案已經提供了這些基礎群組：

* `control`
* `network`
* `compute`
* `storage`
* `monitoring`
* `deployment`

接著用 Ansible inventory 的 `:children` 語法，把它們組成更高層的 service group。例如：

* `[baremetal:children]` 會把所有基礎群組併成裸機節點集合
* `[nova:children]` 指向 `control`
* `[neutron:children]` 指向 `network`
* `[mariadb:children]`、`[rabbitmq:children]`、`[keystone:children]` 等都指向 `control`
* `[openvswitch:children]` 同時指向 `network` 與 `compute`

所以 `10-inventory-template` 可以視為「OpenStack 服務要跑在哪些基礎角色上」的宣告層。

#### `99-vars`

這個檔案來自 `infra_openstack/templates/99-vars.tpl`，由 Terraform 的 `local_file.vars` 產生。它目前將 Terraform 變數 `server_password` 寫成：

* `ansible_become_password`
* `ansible_password`

並固定設定：

* `ansible_user=cloud-user`
* `ansible_become=true`
* `ansible_ssh_common_args='-o StrictHostKeyChecking=no'`

因為這些變數掛在 `[baremetal:vars]`，所以只要某台主機屬於 `baremetal`，就會自動繼承這些 SSH/privilege escalation 設定。`baremetal` 本身又是在 `10-inventory-template` 裡由 `control`、`network`、`compute`、`storage`、`monitoring` 組合出來的，因此 controller 與 compute 節點都會套用到這份共用連線設定。

### 整體生成流程

整體流程如下：

1. Terraform 在 `infra_openstack/` 建立 bastion 與 OpenStack 節點。
2. Terraform 依節點資訊渲染 `01-controller`、`05-compute`、`99-vars` 到 `kolla-ansible/etc/kolla/inventroy/`。
3. `10-inventory-template` 保持為靜態模板，提供 Kolla-Ansible 所需的群組繼承結構。
4. 執行 `kolla-ansible -i /etc/kolla/inventroy/ ...` 時，Ansible 會把這四個檔案合併成完整 inventory。

如果只改 Terraform 節點數量或 IP，通常只需要重新套用 Terraform，就會重新生成主機與變數檔；只有當部署角色分工要改，例如要把某些服務從 controller 挪到其他群組時，才需要調整 `10-inventory-template`。


## RoadMap

* [ ] Setup infrastructure from Terraform
    * [x] OpenStack
    * [ ] Slurm

* [ ] Run Kolla-Ansible in Conatiner
    * [x] Docker Container
    * [ ] Singularity Container