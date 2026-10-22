#!/bin/bash
# ============================================================
# docker-install.sh —— 一键安装 Docker（以 CentOS 7 为主要目标）
#
# 已经把这台机器上踩过的 5 个坑都固化进来了：
#   1. 公网源太慢导致包下载不完整 → 默认走阿里云内网源
#   2. GPG 公钥交互阻塞（yum 卡住不动）→ 导入 key + --nogpgcheck
#   3. sort -V 被 epoch 前缀干扰 → 明确指定版本号，不靠排序
#   4. 多 yum 进程抢锁 → 先清理残留进程与锁
#   5. 缓存包损坏 → 装前用 rpm -K 逐个校验，坏的删掉
#
# 用法：
#   bash docker-install.sh              # 默认装 docker-ce 24.0.9
#   bash docker-install.sh 26.1.4       # 指定版本
#   FORCE_REINSTALL=1 bash docker-install.sh   # 强制重装
#
# 幂等：已安装且服务正常时只做配置校验，不重复安装。
# ============================================================

set -u
VER="${1:-24.0.9}"
DAEMON_JSON=/etc/docker/daemon.json

log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
die()  { echo -e "\033[31m[x]\033[0m $*"; exit 1; }

echo "=================================================="
echo " Docker 安装脚本   目标版本: $VER"
echo " 主机: $(hostname)   时间: $(date '+%F %T')"
echo "=================================================="

# ---------- 0. 操作系统识别 ----------
if [ -f /etc/redhat-release ]; then
    OS=rhel
    OSVER=$(rpm -q --qf '%{VERSION}' centos-release 2>/dev/null || echo 7)
    log "系统: $(cat /etc/redhat-release) (rhel 分支, major=$OSVER)"
elif [ -f /etc/debian_version ]; then
    OS=debian
    . /etc/os-release
    log "系统: $PRETTY_NAME (debian 分支)"
else
    die "不认识的操作系统"
fi

# ---------- 1. 已安装检查（幂等） ----------
if command -v docker >/dev/null 2>&1 && [ "${FORCE_REINSTALL:-0}" != "1" ]; then
    CUR=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ACTIVE=$(systemctl is-active docker 2>/dev/null || echo unknown)
    log "已安装 Docker $CUR，服务状态: $ACTIVE"
    if [ "$ACTIVE" = "active" ]; then
        log "服务正常运行，跳过安装，仅做配置校验"
        SKIP_INSTALL=1
    else
        warn "服务未运行，尝试启动"
        systemctl start docker 2>&1 | tail -3
        SKIP_INSTALL=1
    fi
else
    SKIP_INSTALL=0
fi

# ---------- 2. 安装 ----------
if [ "$SKIP_INSTALL" != "1" ]; then

if [ "$OS" = "rhel" ]; then
    # ===== CentOS / RHEL =====
    log "清理残留 yum 进程与锁"
    for p in $(ps -eo pid,args 2>/dev/null | grep -E '[y]um (install|update)' | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null && warn "  终止残留 yum 进程 $p"
    done
    sleep 1
    rm -f /var/run/yum.pid

    log "备份并写入 docker-ce 源（阿里云内网优先，公网兜底）"
    mkdir -p /etc/yum.repos.d/bak-docker
    [ -f /etc/yum.repos.d/docker-ce.repo ] && cp -a /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/bak-docker/ 2>/dev/null

    # 内网源速度约公网的 10 倍，实测 100KB/s -> 数 MB/s
    INNER=http://mirrors.cloud.aliyuncs.com/docker-ce/linux/centos
    OUTER=https://mirrors.aliyun.com/docker-ce/linux/centos
    if curl -s -o /dev/null -m 6 -w '%{http_code}' "$INNER/7/x86_64/stable/repodata/repomd.xml" 2>/dev/null | grep -q 200; then
        BASE="$INNER/7/\$basearch/stable"
        log "  使用内网源"
    else
        BASE="$OUTER/7/\$basearch/stable"
        warn "  内网源不可达，改用公网源（较慢）"
    fi

    cat > /etc/yum.repos.d/docker-ce.repo <<REPO
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=$BASE
enabled=1
gpgcheck=0
REPO

    log "导入 GPG 公钥（gpgcheck=0 已关闭校验，此处仅作备用）"
    rpm --import "$OUTER/gpg" 2>/dev/null || warn "  公钥导入失败（不影响，已关闭校验）"

    log "清理缓存并重建元数据"
    yum clean all >/dev/null 2>&1
    yum makecache fast 2>&1 | tail -2

    # 校验缓存里已有的包，坏包一律删掉（否则会报 Package does not match intended download）
    PKGDIR=/var/cache/yum/x86_64/7/docker-ce-stable/packages
    if [ -d "$PKGDIR" ]; then
        for f in "$PKGDIR"/*.rpm; do
            [ -f "$f" ] || continue
            if rpm -K "$f" >/dev/null 2>&1; then
                : # 完整，保留
            else
                warn "  缓存包损坏，已删除: $(basename "$f")"
                rm -f "$f"
            fi
        done
    fi

    log "安装 docker-ce $VER（--nogpgcheck 避免公钥确认卡住）"
    if ! yum -y install "docker-ce-$VER" "docker-ce-cli-$VER" containerd.io \
            --nogpgcheck --setopt=obsoletes=0 2>&1 | tail -25; then
        warn "指定版本 $VER 安装失败，回退到仓库默认版本"
        yum -y install docker-ce containerd.io --nogpgcheck --setopt=obsoletes=0 2>&1 | tail -25
    fi

else
    # ===== Debian / Ubuntu =====
    log "安装 apt 依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    log "添加 Docker 官方 GPG key 与源（阿里云镜像）"
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null \
            || curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian $VERSION_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq

    log "安装 docker-ce"
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null
fi

fi  # SKIP_INSTALL

# ---------- 3. daemon.json ----------
RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)
CFG_OK=0
if [ -f "$DAEMON_JSON" ] \
   && grep -q 'max-size' "$DAEMON_JSON" 2>/dev/null \
   && grep -q 'storage-driver' "$DAEMON_JSON" 2>/dev/null \
   && systemctl is-active docker >/dev/null 2>&1; then
    CFG_OK=1
fi

if [ "$CFG_OK" = "1" ]; then
    log "daemon.json 已包含必需配置，保持不动（不影响 $RUNNING_CONTAINERS 个运行中的容器）"
else
    log "写入 $DAEMON_JSON（日志限额，防止撑爆磁盘）"
    mkdir -p /etc/docker
    [ -f "$DAEMON_JSON" ] && cp -a "$DAEMON_JSON" "$DAEMON_JSON.bak-$(date +%s)" 2>/dev/null
    cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF
    cat "$DAEMON_JSON"
fi

# ---------- 4. 启动 ----------
if [ "$CFG_OK" = "1" ]; then
    systemctl enable docker >/dev/null 2>&1 || true
else
    if [ "${RUNNING_CONTAINERS:-0}" -gt 0 ]; then
        warn "配置需要生效，将重启 docker —— 影响 $RUNNING_CONTAINERS 个运行中的容器"
        warn "  设了 --restart=always 的容器会自动拉起"
    fi
    log "启动并设置开机自启"
    systemctl daemon-reload
    systemctl enable docker 2>&1 | tail -1
    systemctl restart docker 2>/dev/null || systemctl start docker
    sleep 5
fi

ACTIVE=$(systemctl is-active docker)
[ "$ACTIVE" = "active" ] || { journalctl -u docker --no-pager -n 20 2>/dev/null; die "docker 启动失败"; }
log "docker: $ACTIVE / $(systemctl is-enabled docker)"

# ---------- 5. 验证 ----------
echo
echo "=== 安装结果 ==="
docker --version
docker info 2>&1 | grep -E "Server Version|Storage Driver|Docker Root Dir|Cgroup Driver|Cgroup Version|Kernel Version|Total Memory" | sed 's/^/  /'

echo
echo "=== 冒烟测试（跑一个容器）==="
if timeout 120 docker run --rm hello-world >/dev/null 2>&1; then
    log "hello-world 运行成功"
else
    warn "hello-world 失败（可能是网络问题，不影响本地镜像使用）"
    warn "  如需拉取公网镜像，可在 daemon.json 里加 registry-mirrors"
fi

echo
echo "=== 现有业务是否受影响 ==="
for s in nginx httpd mysqld php-fpm redis-server; do
    n=$(pgrep -c -f "$s" 2>/dev/null || true)
    [ "${n:-0}" -gt 0 ] && echo "  $s: $n 进程"
done
if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep -E ':(80|443)\b' | head -3 | sed 's/^/  /'
fi

echo
echo "=================================================="
echo " 完成"
echo "=================================================="
echo " 版本  : $(docker --version)"
echo " 数据目录: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
echo " 日志上限: 50MB × 3 个文件"
echo
echo " 常用命令："
echo "   systemctl status docker      # 状态"
echo "   docker ps -a                 # 容器列表"
echo "   docker logs -f <name>        # 容器日志"
echo "=================================================="
