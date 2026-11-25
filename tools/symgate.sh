#!/usr/bin/env bash
# symgate.sh —— 符号闸门: 检查 KO 的全部未定义符号是否存在于设备 kallsyms
# 用法:
#   bash symgate.sh <模块.ko> <设备kallsyms.txt>
# kallsyms.txt 格式: recon.sh 生成 (符号名 + 类型, 地址已置零)
#   原始 /proc/kallsyms 也可以直接用
set -euo pipefail

KO="$1"; KSYMS="$2"

# 0. KO 有效性检查（防编译失败产出空文件/非 ELF 被误判 PASS）
[ -f "$KO" ] || { echo "[symgate] FAIL: 文件不存在 $KO"; exit 1; }
SZ=$(wc -c < "$KO" 2>/dev/null | tr -d ' ')
[ "${SZ:-0}" -gt 1024 ] || { echo "[symgate] FAIL: $KO 只有 ${SZ:-0} 字节 —— 编译未产出有效 KO"; exit 1; }
MAGIC=$(head -c 4 "$KO" 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "7f454c46" ] || { echo "[symgate] FAIL: $KO 不是 ELF（magic=$MAGIC）"; exit 1; }

# 1. 抽取 KO 的未定义符号 (nm -u; nm 不可用时退回 readelf)
UNDEFS=$(nm -u "$KO" 2>/dev/null | awk '{print $NF}' || true)
if [ -z "$UNDEFS" ]; then
  UNDEFS=$(readelf -sW "$KO" 2>/dev/null | awk '$7=="UND" && $8!="" {print $8}' | sort -u)
fi

# 过滤内核模块可解析的通配/本地符号
UNDEFS=$(echo "$UNDEFS" | grep -vE '^(__this_module|_MODULE|\.L|__UNIQUE_ID)' | sort -u || true)

TOTAL=$(echo "$UNDEFS" | grep -c . || true)
echo "[symgate] $KO: $TOTAL undefined symbols"

MISSING=0
while read -r sym; do
  [ -n "$sym" ] || continue
  # kallsyms 行尾是符号名; recon.sh 生成的格式 "类型 名字"
  if grep -qE "(^|[[:space:]])${sym}\$" "$KSYMS"; then
    :
  else
    echo "  MISSING: $sym"
    MISSING=$((MISSING + 1))
  fi
done <<< "$UNDEFS"

if [ "$MISSING" -eq 0 ]; then
  echo "[symgate] PASS: all $TOTAL symbols present in device kallsyms"
  exit 0
else
  echo "[symgate] FAIL: $MISSING symbol(s) missing -> KO 无法在此设备加载"
  echo "          处理: 换内核源码树 / 补 CONFIG / 从 config.gz 核对内核是否编译该功能"
  exit 1
fi
