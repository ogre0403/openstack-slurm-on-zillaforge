# Slurm pam_slurm_adopt 逐步安裝與設定指南

這是一份詳細的 Step-by-Step 指南，用於在 Slurm (22.05.9) 叢集中安裝並設定 `pam_slurm_adopt` 模組。此模組的目的是限制使用者只能 SSH 登入他們目前有工作 (Job) 正在執行的運算節點，並且將 SSH Session 納入 Slurm 的 Cgroup 資源控管中，同時確保系統管理員 (如 `cloud-user` 或 `root`) 可以無條件登入進行維護。

## 環境假設
- **Headnode (控制節點)**: 192.168.95.91
- **Worker Nodes (運算節點)**: 192.168.95.183, 192.168.95.245, 192.168.95.154
- **作業系統**: RHEL 9 / CentOS Stream 9 (或相容系統)
- **管理員帳號**: `cloud-user`

---

## Step 1: 在所有節點安裝 `slurm-pam_slurm` 套件

`slurm-pam_slurm` 套件包含了我們需要的 `pam_slurm_adopt.so` 模組。這個套件通常需要 EPEL 儲存庫。

請在 **Headnode** 以及**所有 Worker Nodes** 上執行以下指令：

```bash
# 1. 安裝 EPEL 儲存庫 (如果尚未安裝)
sudo dnf install -y epel-release

# 2. 安裝 slurm-pam_slurm
sudo dnf install -y slurm-pam_slurm
```

*(提示：您可以使用 `pdsh` 或撰寫簡單的 `for` 迴圈腳本從 Headnode 一次派送指令到所有 Worker Nodes。)*

---

## Step 2: 修改 Slurm 核心設定 (slurm.conf)

為了讓 `pam_slurm_adopt` 生效，Slurm 必須被設定為在每個工作啟動時建立一個 `extern` step，用來收容這些外部的 SSH 連線。

1. 在 **Headnode** 上編輯 `/etc/slurm/slurm.conf`，確保包含以下兩個設定：

   ```ini
   # 確保啟用了 task/cgroup
   TaskPlugin=task/affinity,task/cgroup
   
   # 啟用 contain 以建立 extern step
   PrologFlags=contain
   ```

2. 將修改後的 `/etc/slurm/slurm.conf` 複製到**所有 Worker Nodes** 的 `/etc/slurm/` 目錄下覆蓋原檔案。

3. 重新啟動所有節點上的 Slurm 服務以套用設定：

   ```bash
   # 在 Headnode 執行：
   sudo systemctl restart slurmctld
   
   # 在所有 Worker Nodes 執行：
   sudo systemctl restart slurmd
   ```

---

## Step 3: 設定節點存取控制 (存取控制清單 access.conf)

為了讓管理員可以不受 `pam_slurm_adopt` 限制，我們需要使用 `pam_access.so` 來建立白名單。

請在**所有 Worker Nodes** 上編輯 `/etc/security/access.conf` 檔案，在檔案**最底部**加入以下規則：

```text
# 允許 root 登入
+:root:ALL
# 允許系統管理員 cloud-user 登入
+:cloud-user:ALL
# 拒絕其他所有人 (交由下一步的 pam_slurm_adopt 處理)
-:ALL:ALL
```

---

## Step 4: 設定 SSH PAM 認證模組 (sshd)

接下來，我們需要告訴 SSH 服務如何結合 `pam_access.so` (管理員白名單) 與 `pam_slurm_adopt.so` (工作檢查)。

請在**所有 Worker Nodes** 上編輯 `/etc/pam.d/sshd` 檔案。

找到包含 `account include password-auth` 的那一行，並在其**下方**加入 `pam_access.so` 與 `pam_slurm_adopt.so` 的設定。修改後應該看起來像這樣：

```text
account    required     pam_nologin.so
account    include      password-auth

# --- 加入以下兩行 ---
# 1. 首先檢查 access.conf，如果是 root 或 cloud-user，直接放行 (sufficient)
account    sufficient   pam_access.so

# 2. 如果被上面的規則拒絕 (一般使用者)，則交由 Slurm 檢查是否有執行中的工作
-account   required     pam_slurm_adopt.so action_adopt_failure=deny action_generic_failure=deny
# --------------------

password   include      password-auth
```

修改完成後，在**所有 Worker Nodes** 上重新啟動 SSH 服務：

```bash
sudo systemctl restart sshd
```

---

## Step 5: 處理 SELinux (重要)

在 RHEL 9 系統中，預設開啟的 SELinux 會阻擋 SSHD 進程讀取 Slurmd 建立的 Unix Socket，導致即使使用者有工作，`pam_slurm_adopt` 也無法確認，從而顯示 `Access denied`。

**暫時解決方案 (快速驗證)**：
在所有 Worker Nodes 上將 SELinux 設為 Permissive：
```bash
sudo setenforce 0
```
*(注意：重開機後會失效，如果要永久設定 permissive，請修改 `/etc/selinux/config` 將 `SELINUX=enforcing` 改為 `SELINUX=permissive`)*

**建議的正式環境解決方案**：
編譯並載入 SELinux 模組以允許 `sshd_t` 存取 Slurm 的 socket。
您可以建立一個 `pam_slurm_adopt.te` 檔案：
```text
module pam_slurm_adopt 1.0;
require {
	type sshd_t;
	type var_spool_t;
	type unconfined_t;
	type initrc_var_run_t;
	class sock_file write;
	class dir { read search };
	class unix_stream_socket connectto;
}
#============= sshd_t ==============
allow sshd_t initrc_var_run_t:dir search;
allow sshd_t initrc_var_run_t:sock_file write;
allow sshd_t unconfined_t:unix_stream_socket connectto;
allow sshd_t var_spool_t:dir read;
allow sshd_t var_spool_t:sock_file write;
```
然後編譯並安裝：
```bash
checkmodule -M -m -o pam_slurm_adopt.mod pam_slurm_adopt.te
semodule_package -o pam_slurm_adopt.pp -m pam_slurm_adopt.mod
sudo semodule -i pam_slurm_adopt.pp
```

---

## Step 6: 驗證功能

我們可以使用一個一般使用者帳號（例如 `testuser`）來驗證設定是否成功。

1. **管理員測試**
   從 Headnode 使用 `cloud-user` 連線到 Worker 節點：
   ```bash
   ssh cloud-user@192.168.95.183
   ```
   **預期結果**：直接登入成功。

2. **無工作的一般使用者測試**
   從 Headnode 使用 `testuser` 連線到 Worker 節點：
   ```bash
   ssh testuser@192.168.95.183
   ```
   **預期結果**：連線被拒絕，並顯示錯誤訊息：
   `Access denied by pam_slurm_adopt: you have no active jobs on this node`

3. **有工作的一般使用者測試**
   在 Headnode 以 `testuser` 身份提交一個會跑到背景睡眠的作業到指定的節點 (例如 `SLURM-03-worker-tf` / 192.168.95.245)：
   ```bash
   sudo -u testuser sbatch --partition=odd --wrap="sleep 600"
   ```
   使用 `squeue` 確認作業正在 `RUNNING`。
   接著，使用 `testuser` 登入該節點：
   ```bash
   ssh testuser@192.168.95.245
   ```
   **預期結果**：登入成功！此時 `testuser` 的 SSH session 已被 Slurm 納管。
