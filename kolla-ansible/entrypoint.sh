#!/bin/bash

TARGET_UID=${PUID:-1000}
TARGET_GID=${PGID:-1000}

groupmod -o -g "$TARGET_GID" kolla
usermod -o -u "$TARGET_UID" kolla

# 檢查家目錄目前的擁有者 UID
CURRENT_UID=$(stat -c "%u" /home/kolla)

# 如果目前的 UID 不等於目標 UID，才執行耗時的 chown -R
if [ "$CURRENT_UID" != "$TARGET_UID" ]; then
    echo "Updating ownership of /home/kolla to $TARGET_UID:$TARGET_GID. This may take a while..."
    chown -R kolla:kolla /home/kolla
else
    echo "Ownership of /home/kolla is already correct. Skipping chown."
fi

# 【重點】用 setpriv 取代 gosu
# --reuid: 重新設定 User
# --regid: 重新設定 Group
# --init-groups: 初始化該使用者的附加群組 (非常重要，否則可能沒有 docker 或 sudo 權限)
export HOME=/home/kolla
exec setpriv --reuid=kolla --regid=kolla --init-groups "$@"
