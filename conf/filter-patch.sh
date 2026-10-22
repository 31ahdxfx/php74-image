#!/bin/sh
# 从官方 compare diff 中剔除"仅涉及文档与版本字符串"的 diff 段。
#
# 原因：官方回补分支 PHP-7.4-CVE-2026-109618-109619 的基线实际是 7.4.31-dev，
#       其 NEWS / configure.ac 与 php-7.4.33 发行 tarball 的内容不完全一致，
#       这两个文件的 hunk 会 FAILED（实测各 1 个 hunk），但并不影响任何功能代码：
#         - NEWS         : 更新日志
#         - configure.ac : 仅 AC_INIT 版本号 7.4.31-dev -> 7.4.34-dev
#       版本号我们另外用 sed 改 main/php_version.h，所以这里直接剔除。
#
# 其余 17 个文件（Zend/*、main/*、ext/session/*）是漏洞修复本体，必须全部应用成功。

set -e

IN="$1"
OUT="$2"

if [ -z "$IN" ] || [ -z "$OUT" ]; then
    echo "用法: $0 <输入patch> <输出patch>"
    exit 2
fi

awk '
/^diff --git / {
    keep = ($0 !~ / a\/NEWS / && $0 !~ / a\/configure\.ac /)
}
keep { print }
' "$IN" > "$OUT"

in_cnt=$(grep -c '^diff --git' "$IN" || true)
out_cnt=$(grep -c '^diff --git' "$OUT" || true)

echo "原始 diff 段: $in_cnt"
echo "过滤后 diff 段: $out_cnt  (应为 17)"
echo "剔除的文件: NEWS, configure.ac"

if [ "$out_cnt" -ne 17 ]; then
    echo "[FATAL] 过滤后段数不是 17，patch 可能已变更，请人工复核"
    exit 1
fi

# 关键文件必须在
for f in "Zend/zend_alloc.c" "main/rfc1867.c" "ext/session/session.c" "main/main.c"; do
    grep -q "a/$f b/$f" "$OUT" || { echo "[FATAL] 缺少关键文件 $f"; exit 1; }
done

echo "过滤完成，关键文件齐全"
