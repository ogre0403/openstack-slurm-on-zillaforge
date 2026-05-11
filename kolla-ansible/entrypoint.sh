#!/bin/bash

# 檢查目前執行這個腳本的使用者是不是 root (UID 0)
if [ "$(id -u)" = '0' ]; then
    # ==========================================
    # 這裡是 Docker 情境 (以 root 啟動)
    # ==========================================
    TARGET_UID=${PUID:-666006}
    TARGET_GID=${PGID:-999009}

    groupmod -o -g "$TARGET_GID" kolla 2>/dev/null || true
    usermod -o -u "$TARGET_UID" kolla 2>/dev/null || true

    CURRENT_UID=$(stat -c "%u" /home/kolla)
    if [ "$CURRENT_UID" != "$TARGET_UID" ]; then
        echo "Updating ownership of /home/kolla..."
        chown -R kolla:kolla /home/kolla
    fi

    # ---- Docker socket GID 動態對齊 ----
    # 取得 host 上 /var/run/docker.sock 的 GID，
    # 在容器內建立（或更新）相同 GID 的 docker group，
    # 再把 kolla 加進去，讓 kolla 可以存取 docker CLI。
    if [ -S /var/run/docker.sock ]; then
        DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
        if ! getent group docker > /dev/null 2>&1; then
            groupadd -g "$DOCKER_SOCK_GID" docker
        else
            groupmod -g "$DOCKER_SOCK_GID" docker
        fi
        usermod -aG docker kolla
        echo "docker group GID set to $DOCKER_SOCK_GID, kolla added."
    fi

    export HOME=/home/kolla

    # 用 setpriv 降權並執行指令
    exec setpriv --reuid=kolla --regid=kolla --init-groups "$@"

else
    # ==========================================
    # 這裡是 Singularity 情境 (以普通使用者啟動)
    # ==========================================
    # 因為已經是一般使用者了，不需要（也不能）做 usermod/chown/setpriv
    # 直接用當前身分執行傳入的指令即可

    # 確保 HOME 變數正確指向當前使用者的家目錄
    export HOME=$(eval echo ~$(whoami))

    exec "$@"
fi

