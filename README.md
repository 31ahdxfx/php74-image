# php74-fpm — PHP 7.4.34（php2shell 修复版）镜像

用于替换仍在运行 PHP 7.4 的服务器，修复 **CVE-2026-109618 / CVE-2026-109619**（CVSS 9.2，未认证 RCE）。

## 为什么需要自己构建

PHP 7.4 已于 2022-11 EOL，官方最后版本是 **7.4.33（漏洞版）**：

- 官方**没有**发布 7.4 的安全修复包
- 官方**没有**更新 `php:7.4-fpm` 镜像 —— `docker pull` 拿到的仍是漏洞版
- 修复只以 Git 分支形式存在：`PHP-7.4-CVE-2026-109618-109619`，基线 `php-7.4.33`

所以本仓库的镜像 = **官方 `php:7.4.33-fpm` + 官方回补 patch 重编核心**，等价于发行方打包的 7.4.34。

## 构建方式选型

| 方式 | 可行性 | 耗时 | 说明 |
|---|---|---|---|
| 本地 Mac（Apple Silicon） | ❌ 不可行 | — | arm64 需 QEMU 模拟 x86_64，编译 PHP 7.4 极慢且易失败 |
| 本地 Mac（Intel） | ⚠️ 可行 | 60–90 min | 需装 Docker Desktop，-j1 编译 |
| 生产服务器 | ✅ 可行（兜底） | 60–90 min | 会占用生产 CPU/内存，须 `nice -n 19 make -j1` |
| **GitHub Actions** | ✅ 推荐 | **10–15 min** | x86_64 原生 4 核，不占生产资源，产物可多机复用 |

**推荐 GitHub Actions**，且只需构建一次 —— 产物用 `docker save` 分发到其余机器。

## 用 GitHub Actions 构建

```bash
# 1. 新建仓库并推上去
git init
git add .
git commit -m "PHP 7.4.34 patched image"
git branch -M main
git remote add origin git@github.com:<你的账号>/php74-image.git
git push -u origin main
```

推送后 Actions 自动触发；也可以在 **Actions → Build PHP 7.4.34 → Run workflow** 手动触发。

产物两选一：

| 产物 | 用途 | 取用方式 |
|---|---|---|
| `ghcr.io/<owner>/php74-fpm:7.4.34` | 有外网、能拉 ghcr 的机器 | `docker pull` |
| Actions artifact（tar.gz） | 拉取受限 / 需离线分发 | 页面下载后 `docker load` |

> 注意：ghcr 的包默认是 **private**。要给多台机器拉取，去 GitHub → Packages → 该包 → Settings → Change visibility 改为 public，或每台机 `docker login ghcr.io`。

## 部署到目标机

```bash
# ① 记录现状（回滚依据，必做）
php-config --configure-options > /root/php74-configure.bak
php -m > /root/php74-modules.bak
cp -a /www/server/php/74 /root/php74-backup-$(date +%F)

# ② 载入镜像（二选一）
docker pull ghcr.io/<owner>/php74-fpm:7.4.34
# 或
gunzip -c php74-fpm-7.4.34.tar.gz | docker load

# ③ 确认 nginx 指向哪个 socket
grep -rn "fastcgi_pass" /www/server/panel/vhost/nginx/*.conf

# ④ 起容器（socket 名必须与 ③ 一致）
docker run -d --name php74-fpm --restart=always \
    --network host \
    -v /www/wwwroot:/www/wwwroot \
    -v /pub:/pub \
    -v /tmp:/tmp \
    -w /www/wwwroot \
    php74-fpm:7.4.34

# ⑤ 停宿主 FPM（业务中断开始，通常 < 10 秒）
/etc/init.d/php-fpm-74 stop && systemctl disable php-fpm-74

# ⑥ 验收
ls -l /tmp/php-cgi-74.sock
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: <站点域名>' http://127.0.0.1/
```

### 两个必须注意的挂载点

| 挂载 | 漏掉会怎样 |
|---|---|
| `-v /tmp:/tmp` | nginx 找不到 socket（`fastcgi_pass unix:/tmp/php-cgi-74.sock`），全站 502 |
| `-v /pub:/pub` | NFS 上的书籍资源读不到，报 `file_get_contents(...): No such file or directory` |

### 为什么必须 `--network host`

容器里的 `127.0.0.1` 是容器自己的回环，不是宿主机。目标机上只要有任何"只监听 `127.0.0.1`"的依赖（MeiliSearch、Redis、本地 MySQL），bridge 网络下全部连不上。

**报错特征**：`cURL error 7 ... after 0 ms` —— `0 ms` 表示立即拒绝，不是超时。

## 验证修复是否生效

不要只看版本号。源码回补补丁改的是代码，版本字符串可能不变。用官方补丁新增的 ini 项做指纹：

```bash
docker run --rm php74-fpm:7.4.34 php -r 'var_dump(ini_get("max_multipart_body_parts"));'
```

| 输出 | 含义 |
|---|---|
| `string(2) "-1"` | ✅ 补丁已进二进制 |
| `bool(false)` | ❌ 无此项，漏洞仍在 |

CI 里已经把这一项设为**构建门禁** —— 不通过则构建失败。

## 补丁溯源

| 项 | 值 |
|---|---|
| 来源 | `github.com/php/php-src` 分支 `PHP-7.4-CVE-2026-109618-109619` |
| 生成方式 | `compare/php-7.4.33...PHP-7.4-CVE-2026-109618-109619.diff` |
| 大小 | 41905 B |
| SHA-256 | `5ff312300fa1cbecce2832fe25e5fd25786e670d0138e663085a7f7a017af293` |
| diff 段数 | 19（应用时过滤掉 NEWS / configure.ac 两段，见下） |

### 为什么要过滤掉 2 段

官方回补分支的基线实际是 **7.4.31-dev**，其 `NEWS` 与 `configure.ac` 跟 `php-7.4.33` 发行 tarball 不完全一致，这两个文件的 hunk 会 FAILED：

- `NEWS` —— 更新日志，无功能影响
- `configure.ac` —— 只有 `AC_INIT` 版本号 `7.4.31-dev → 7.4.34-dev`，而发行 tarball 用的是预生成的 `configure`，根本不走 autoconf

`conf/filter-patch.sh` 会剔除这两段，并**强校验剩余段数必须为 17**、关键文件必须齐全，否则直接构建失败。

## 目录结构

```
.
├── Dockerfile                                  # 构建定义
├── conf/
│   ├── 7.4-cve-2026-109618-109619.patch        # 官方回补补丁（已存档）
│   ├── filter-patch.sh                         # 剔除 NEWS/configure.ac 两段 + 强校验
│   ├── zz-www.conf                             # FPM pool（含安全加固项）
│   ├── 99-zz-perf.ini                          # OPcache / realpath 调优
│   └── 99-bt.ini                               # 占位；如需继承宝塔 php.ini 可替换
└── .github/workflows/build-php74.yml           # CI：构建 + 门禁 + 推 ghcr + 导出 artifact
```

## 内置扩展

```
bcmath exif gd gettext intl mysqli opcache pcntl pdo_mysql soap sockets sysvsem shmop zip redis
```

官方镜像自带并保留：`ctype curl date dom fileinfo filter ftp hash iconv json libxml mbstring mysqlnd openssl pcre PDO pdo_sqlite Phar posix readline Reflection session SimpleXML sodium SPL sqlite3 standard tokenizer xml xmlreader xmlwriter zlib`

需要额外扩展时，在 Dockerfile 里追加：

```dockerfile
RUN docker-php-ext-install -j1 <扩展名>
# 或
RUN pecl install <扩展名> && docker-php-ext-enable <扩展名>
```

## 已知副作用

补丁在代码层硬关了 `session.upload_progress`（`ext/session/session.c` 里那处 `|| true`）。带进度条的上传组件**进度条不会动，但文件能正常上传**。这是补丁的预期行为，不是故障。

## 长期建议

7.4 已 EOL 三年多。本次能修是因为官方破例给了 minimal backport，**下一次核心漏洞大概率没有 7.4 补丁**。应把"迁移到 8.3+"作为明确技术债跟踪。
