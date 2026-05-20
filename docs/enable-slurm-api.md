# Enable Slurm REST API (`slurmrestd`)

本文件說明如何在已透過 `make slurm-up` 安裝的 Slurm 叢集（Rocky Linux 9）上，手動啟用 `slurmrestd` REST API 服務。

## 環境資訊

| 項目 | 值 |
|------|-----|
| OS | Rocky Linux 9 |
| Slurm 版本 | 22.05.9 |
| API Port | `6820` |
| API 版本 | `v0.0.38` |
| Auth 方式 | JWT (`auth/jwt`) |

---

## 步驟一：安裝 `slurm-slurmrestd` 套件

```bash
sudo dnf install -y slurm-slurmrestd
```

> `slurm-slurmrestd` 與系統已安裝的 `slurm-22.05.9` 同版本，位於 EPEL repo，直接安裝即可。

---

## 步驟二：產生 JWT Secret Key

```bash
sudo dd if=/dev/random bs=32 count=1 2>/dev/null \
  | openssl enc -base64 | tr -d '\n/+=' | cut -c1-32 \
  > /etc/slurm/jwt_hs256.key

sudo chown slurm:slurm /etc/slurm/jwt_hs256.key
sudo chmod 0600 /etc/slurm/jwt_hs256.key
```

---

## 步驟三：更新 `/etc/slurm/slurm.conf`

在 `slurm.conf` 末尾加入以下兩行，啟用 JWT 驗證：

```bash
sudo bash -c 'cat >> /etc/slurm/slurm.conf <<EOF
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key
EOF'
```

確認已寫入：

```bash
grep AuthAlt /etc/slurm/slurm.conf
```

---

## 步驟四：設定 slurmrestd systemd service

建立 `/etc/sysconfig/slurmrestd`，指定 auth plugin：

```bash
sudo bash -c 'cat > /etc/sysconfig/slurmrestd <<EOF
SLURMRESTD_OPTIONS="-a rest_auth/jwt"
EOF'
```

建立 systemd drop-in override，修正執行使用者與 socket 路徑（預設的 `/var/lib/slurmrestd.socket` 會有 Permission denied）：

```bash
sudo mkdir -p /etc/systemd/system/slurmrestd.service.d

sudo bash -c 'cat > /etc/systemd/system/slurmrestd.service.d/override.conf <<EOF
[Service]
User=slurm
Group=slurm
ExecStart=
ExecStart=/usr/sbin/slurmrestd \$SLURMRESTD_OPTIONS unix:/run/slurmrestd/slurmrestd.socket 0.0.0.0:6820
RuntimeDirectory=slurmrestd
RuntimeDirectoryMode=0755
EOF'

sudo systemctl daemon-reload
```

> **注意**：`ExecStart=` 空行是必要的，用來清除上層 unit 的原始值後再重新賦值。

---

## 步驟五：重啟 slurmctld，啟動 slurmrestd

```bash
# 重啟 slurmctld 以載入 JWT auth 設定
sudo systemctl restart slurmctld

# 啟用並啟動 slurmrestd
sudo systemctl enable --now slurmrestd

# 確認狀態
sudo systemctl status slurmrestd
```

預期輸出（Active 為 running）：

```
● slurmrestd.service - Slurm REST daemon
     Active: active (running) since ...
   Main PID: XXXX (slurmrestd)
```

---

## 步驟六：手動驗證 Slurm REST API

以下步驟對應 Terraform 中 `null_resource.test_slurm_api` 的自動化驗證流程，可在 headnode 上逐步手動執行。

---

### 步驟 6-1：取得 JWT Token

以有 sudo 權限的使用者在 headnode 執行：

```bash
TOKEN=$(sudo scontrol token username=$(whoami) lifespan=3600 | sed -n 's/^SLURM_JWT=//p')
echo "Token acquired: ${TOKEN:0:20}..."
```

> 若 token 為空，表示 `slurmctld` 尚未載入 JWT auth，請確認步驟三～五已完成。

---

### 步驟 6-2：Ping slurmrestd

```bash
curl -s http://localhost:6820/slurm/v0.0.38/ping \
  -H "X-SLURM-USER-NAME: $(whoami)" \
  -H "X-SLURM-USER-TOKEN: $TOKEN"
```

預期回傳包含 `"pings"` 陣列，`"pinged"` 值為 `true`。

---

### 步驟 6-3：透過 REST API 投遞測試 Job

先建立 JSON payload：

```bash
cat > /tmp/api_test_job.json << 'EOF'
{
  "script": "#!/bin/bash\nhostname\necho slurm-api-test-ok",
  "job": {
    "current_working_directory": "/tmp",
    "environment": {
      "PATH": "/bin:/usr/bin:/usr/local/bin"
    }
  }
}
EOF
```

投遞 job：

```bash
JOB_SUBMIT_RESULT=$(curl -s -X POST http://localhost:6820/slurm/v0.0.38/job/submit \
  -H "Content-Type: application/json" \
  -H "X-SLURM-USER-NAME: $(whoami)" \
  -H "X-SLURM-USER-TOKEN: $TOKEN" \
  -d @/tmp/api_test_job.json)
echo "$JOB_SUBMIT_RESULT"

# 取出 job_id
JOB_ID=$(echo "$JOB_SUBMIT_RESULT" | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
echo "Submitted job ID: $JOB_ID"
```

---

### 步驟 6-4：等待 Job 完成並確認狀態

```bash
# 輪詢最多 60 秒（每 5 秒查一次）
for i in $(seq 1 12); do
  STATE=$(sacct -j "$JOB_ID" --noheader -o State%20 2>/dev/null | head -1 | xargs)
  echo "  Job $JOB_ID state: $STATE (attempt $i)"
  echo "$STATE" | grep -qiE "COMPLETED|FAILED|CANCELLED|TIMEOUT" && break
  sleep 5
done
```

---

### 步驟 6-5：顯示 Job 詳細資訊

```bash
sacct -j "$JOB_ID" -o JobID,JobName%20,User%12,State%12,ExitCode,Start,End
```

預期 `State` 欄位為 `COMPLETED`，`ExitCode` 為 `0:0`。

---

### 其他常用查詢

```bash
# 列出所有 jobs
curl -s \
  -H "X-SLURM-USER-NAME: $(whoami)" \
  -H "X-SLURM-USER-TOKEN: $TOKEN" \
  http://localhost:6820/slurm/v0.0.38/jobs

# 列出所有 nodes
curl -s \
  -H "X-SLURM-USER-NAME: $(whoami)" \
  -H "X-SLURM-USER-TOKEN: $TOKEN" \
  http://localhost:6820/slurm/v0.0.38/nodes

# 取得 OpenAPI spec
curl -s \
  -H "X-SLURM-USER-NAME: $(whoami)" \
  -H "X-SLURM-USER-TOKEN: $TOKEN" \
  curl -s http://localhost:6820/openapi/v3
```

---

## 檔案總覽

| 檔案 | 用途 |
|------|------|
| `/etc/slurm/jwt_hs256.key` | JWT secret key，供 slurmctld 與 slurmrestd 使用 |
| `/etc/slurm/slurm.conf` | 新增 `AuthAltTypes` 與 `AuthAltParameters` |
| `/etc/sysconfig/slurmrestd` | slurmrestd 啟動參數（auth plugin） |
| `/etc/systemd/system/slurmrestd.service.d/override.conf` | 覆寫 User、socket 路徑、RuntimeDirectory |

---

## 常見問題

### `Permission denied` on socket

預設 unit 的 socket 路徑為 `/var/lib/slurmrestd.socket`，`slurm` 使用者無法在 `/var/lib` 建立檔案。
解法：使用 `RuntimeDirectory=slurmrestd` 讓 systemd 在 `/run/slurmrestd/` 建立目錄，並覆寫 `ExecStart` 改用 `unix:/run/slurmrestd/slurmrestd.socket`。

### slurmctld 未載入 JWT

確認 `slurm.conf` 中 `AuthAltTypes=auth/jwt` 已存在，並在修改後執行 `sudo systemctl restart slurmctld`。

### Token 產生失敗

`scontrol token` 需要以具有 slurm 管理員權限的使用者執行（通常需 `sudo`）。
