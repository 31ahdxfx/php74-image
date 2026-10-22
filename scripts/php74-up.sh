#!/bin/bash
# ============================================================
# php74-up.sh —— 只负责把 PHP 7.4 容器跑起来
#
# 设计原则：
#   · 不动宿主 php-fpm（不 stop、不 disable）
#   · 不改 nginx 配置
#   · socket 名可自由指定，由你手动改 nginx 的 fastcgi_pass 去指
#
# 用法：
#   bash php74-up.sh                        # 默认 /tmp/php-cgi-74.sock
#   bash php74-up.sh /tmp/php-cgi-7499.sock # 自定义 socket 名
#   bash php74-up.sh /tmp/x.sock myphp74    # 自定义 socket + 容器名
#
# 常用后续操作：
#   docker logs -f php74-fpm        # 看日志
#   docker restart php74-fpm        # 重启
#   docker rm -f php74-fpm          # 删除（重建前需要）
# ============================================================

SOCK="${1:-/tmp/php-cgi-74.sock}"
NAME="${2:-php74-fpm}"
IMG="${IMG:-ghcr.io/31ahdxfx/php74-fpm:7.4.34}"
CONFDIR=/etc/docker/php74

set -u

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }

echo "=================================================="
echo " 镜像    : $IMG"
echo " 容器名  : $NAME"
echo " socket  : $SOCK"
echo "=================================================="

# ---- 1. 镜像检查 ----
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "[!] 镜像不存在，尝试拉取..."
    docker pull "$IMG" || { echo "[x] 拉取失败"; exit 1; }
fi

# ---- 2. 同名容器检查（不擅自删除）----
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "[!] 容器 $NAME 已存在，状态: $(docker inspect -f '{{.State.Status}}' "$NAME")"
    echo "    要继续请先执行: docker rm -f $NAME"
    exit 0
fi

# ---- 3. socket 占用检查 ----
if [ -S "$SOCK" ]; then
    OWNER=$(ss -lxp 2>/dev/null | grep -F "$SOCK" | head -1 | grep -oP 'pid=\d+' | head -1 | cut -d= -f2)
    if [ -n "${OWNER:-}" ]; then
        echo "[!] socket $SOCK 已被占用（pid=$OWNER: $(cat /proc/$OWNER/comm 2>/dev/null)）"
        echo "    换个 socket 名即可，例如: bash $0 /tmp/php-cgi-7499.sock"
        exit 1
    fi
    echo "[i] 存在残留 socket 文件但无进程监听，将被复用"
fi

# ---- 4. 生成 pool 配置（只覆盖 listen 等，其余沿用镜像内配置）----
mkdir -p "$CONFDIR"
SOCKDIR=$(dirname "$SOCK")
cat > "$CONFDIR/zz-www.conf" <<EOF
; 由 php74-up.sh 生成 $(date '+%F %T')
; 只为了把 listen 指到指定 socket，其余参数保持镜像默认

[global]
daemonize = no
error_log = /proc/self/fd/2
log_limit = 8192

[www]
listen = $SOCK
listen.owner = www
listen.group = www
listen.mode = 0666

user = www
group = www

pm = dynamic
pm.max_children = 16
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5
pm.max_requests = 500

request_terminate_timeout = 100
catch_workers_output = yes

php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[user_ini.filename] = ""
EOF

echo
echo "[1/4] 配置已写入 $CONFDIR/zz-www.conf"

# ---- 5. 起容器 ----
# 若 socket 不在 /tmp，需要额外把该目录挂进去
EXTRA=""
case "$SOCKDIR" in
    /tmp) ;;
    *) EXTRA="-v $SOCKDIR:$SOCKDIR" ;;
esac

# 额外数据目录：站点代码里常引用 /pub、/novel 这类绝对路径，
# 容器内不存在会直接 file_get_contents 失败（"书籍能列出但点进去打不开"）。
# 这里自动探测，存在才挂；不存在的会在启动完成后提示。
echo
echo "[2/5] 探测额外数据目录..."
EXTRA_DIRS="${EXTRA_DIRS:-/pub /novel /weblog /data /mnt/data}"
DATA_MOUNTS=""
MISSING_DIRS=""
for d in $EXTRA_DIRS; do
    if [ -d "$d" ]; then
        cnt=$(ls -A "$d" 2>/dev/null | wc -l)
        mountpoint -q "$d" 2>/dev/null && MP="挂载点" || MP="普通目录"
        DATA_MOUNTS="$DATA_MOUNTS -v $d:$d"
        printf "   %-12s 存在（%s，%s 项）→ 将挂载\n" "$d" "$MP" "$cnt"
        [ "$cnt" -eq 0 ] && printf "   %-12s ⚠ 目录为空，挂进去也读不到数据，请确认是否漏挂 NFS\n" ""
    else
        MISSING_DIRS="$MISSING_DIRS $d"
        printf "   %-12s 不存在 → 跳过\n" "$d"
    fi
done

echo "[3/5] 启动容器..."
docker run -d --name "$NAME" --restart=always \
    --network host \
    -v /www/wwwroot:/www/wwwroot \
    -v /tmp:/tmp \
    $EXTRA \
    $DATA_MOUNTS \
    -v "$CONFDIR/zz-www.conf:/usr/local/etc/php-fpm.d/zz-www.conf:ro" \
    -w /www/wwwroot \
    "$IMG" >/dev/null 2>&1

# ---- 6. 等 8 秒确认稳定（这一步能抓 daemonize 之类的问题）----
echo "[4/5] 等待 8 秒确认稳定..."
STABLE=0
for i in $(seq 1 16); do
    sleep 0.5
    ST=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
    if [ "$ST" != "running" ]; then
        echo "   第 $i 次检查: $ST —— 未能稳定"
        break
    fi
    [ "$i" -ge 16 ] && STABLE=1
done

if [ "$STABLE" != "1" ]; then
    echo
    echo "[x] 容器未能稳定运行，日志如下："
    docker logs --tail 30 "$NAME" 2>&1
    exit 1
fi
echo "   状态: running ✅"

# ---- 7. socket 与自检 ----
echo "[5/5] 检查 socket 与自检..."
if [ ! -S "$SOCK" ]; then
    echo "   [x] socket 未生成: $SOCK"
    docker logs --tail 20 "$NAME" 2>&1
    exit 1
fi
ls -l "$SOCK"

docker exec "$NAME" php -r '
printf("   版本: %s\n", PHP_VERSION);
printf("   补丁: max_multipart_body_parts = %s\n", ini_get("max_multipart_body_parts"));
printf("   时区: %s (%s)\n", ini_get("date.timezone"), date("T"));
printf("   xmlrpc: %s\n", extension_loaded("xmlrpc") ? "OK" : "MISSING");
' 2>&1

echo
echo "=================================================="
echo " 启动完成"
echo "=================================================="
echo " socket : $SOCK"
echo " 容器   : $NAME ($(docker inspect -f '{{.State.Status}}' "$NAME"))"
echo " 挂载   : /www/wwwroot /tmp$DATA_MOUNTS"
if [ -n "${MISSING_DIRS:-}" ]; then
    echo
    warn "以下目录在宿主机上不存在，未挂载：$MISSING_DIRS"
    warn "  如果站点代码引用了它们，读取会失败，请确认是否需要先创建/挂载"
fi
echo
echo " 要接到 nginx，把对应站点的 fastcgi_pass 改成："
echo "     fastcgi_pass unix:$SOCK;"
echo
echo " 例如："
echo "     sed -i 's|unix:/tmp/php-cgi-74.sock|unix:$SOCK|' /www/server/panel/vhost/nginx/*.conf"
echo "     nginx -t && nginx -s reload"
echo
echo " 回滚：把 fastcgi_pass 改回去，或直接停容器"
echo "     docker stop $NAME"
echo "=================================================="
