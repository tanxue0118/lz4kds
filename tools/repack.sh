#!/usr/bin/env bash
# repack.sh —— 用编译产物打发行 zip（双架构支持）
#
# 用法:
#   ARCH=oplus  bash repack.sh <新编 hybridswap.ko> <zsmalloc.ko> [--allow-reuse KO]
#   ARCH=xiaomi bash repack.sh <新编 zram.ko>
#
# 环境变量:
#   ARCH      oplus | xiaomi   目标架构，默认 oplus
#   ALGO      算法名，默认 lz4kds（写入 preinit.conf，仅 oplus 有效）
#   FRESH_DIR 编译产物目录；指定后强制校验传入 KO 必须来自该目录内
#
# 产物: dist/lz4kds侧载-<架构>-<日期>-<hash>.zip
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH="${ARCH:-oplus}"
ALGO="${ALGO:-lz4kds}"
FRESH_DIR="${FRESH_DIR:-}"

case "$ARCH" in
  oplus|xiaomi) ;;
  *) echo "[repack] FAILED: ARCH 必须是 oplus 或 xiaomi（当前: $ARCH）"; exit 2 ;;
esac

TPL="templates/$ARCH"
[ -d "$TPL" ] || { echo "[repack] FAILED: 缺模板目录 $TPL"; exit 2; }

[ $# -ge 1 ] || { echo "[repack] 用法: ARCH=<oplus|xiaomi> bash repack.sh <ko> [more.ko ...]"; exit 2; }
for ko in "$@"; do
  [ -f "$ko" ] || { echo "[repack] FAILED: KO 不存在: $ko"; exit 2; }
done

# ── 强制新鲜度校验：禁止把仓库里的历史 KO 误打包 ──
# 只校验第 1 个参数（= 本次编译产物）。第 2 个起是设备提供的原厂 KO（如 oplus_bsp_zsmalloc.ko），
# 它们本来就不该来自编译目录。
if [ -n "$FRESH_DIR" ]; then
  FRESH_ABS=$(cd "$FRESH_DIR" 2>/dev/null && pwd) || { echo "[repack] FAILED: FRESH_DIR 不存在: $FRESH_DIR"; exit 2; }
  KO_ABS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  case "$KO_ABS" in
    "$FRESH_ABS"/*) echo "[repack] 新鲜度校验通过（编译产物来自 $FRESH_ABS）" ;;
    *) echo "[repack] FAILED: $1 不在编译产物目录 $FRESH_ABS 内 —— 疑似误用历史 KO"; exit 3 ;;
  esac
  shift_extra=$#
  if [ "$shift_extra" -gt 1 ]; then
    echo "[repack] 另 $((shift_extra - 1)) 个 KO 视为设备提供的原厂件，不做新鲜度校验"
  fi
fi

# ── KO 内容门禁：算法钉死逻辑必须存在（防重编丢失，dali r48 教训）──
if [ "$ARCH" = "oplus" ] && [ "$ALGO" != "off" ]; then
  ALGO_MARK=$(grep -c "zram_algo" "$1" 2>/dev/null || true)
  if strings "$1" 2>/dev/null | grep -qE 'unsupported zram_algo|zram_algo='; then
    echo "[repack] KO 含算法参数处理逻辑 ✓"
  else
    echo "[repack] ⚠ WARNING: KO 中未找到 zram_algo 处理字符串 —— 可能编译了旧版源码"
    echo "[repack]    确认 source/zram_drv.c 的 zram_init() 读取 zram_algo 的逻辑仍在"
  fi
fi

STAGE=$(mktemp -d)
mkdir -p dist

# ── 1. 复制模板 ──
cp -r "$TPL"/. "$STAGE/"

# ── 2. 注入 KO 到正确位置 ──
if [ "$ARCH" = "oplus" ]; then
  mkdir -p "$STAGE/preinit"
  # oplus 需要两个 KO：zsmalloc 先、hybridswap 后
  ZSM_KO=""; HSW_KO=""
  for ko in "$@"; do
    case "$(basename "$ko")" in
      *zsmalloc*) ZSM_KO="$ko" ;;
      *hybridswap*) HSW_KO="$ko" ;;
      *) echo "[repack] WARN: 未识别归属的 KO: $(basename "$ko")，仍放入 preinit/" ;;
    esac
    cp "$ko" "$STAGE/preinit/$(basename "$ko")"
  done
  [ -n "$HSW_KO" ] || { rm -rf "$STAGE"; echo "[repack] FAILED: oplus 架构必须提供 hybridswap KO"; exit 4; }
  if [ -z "$ZSM_KO" ]; then
    echo "[repack] ⚠⚠ WARNING: 未提供 oplus_bsp_zsmalloc.ko"
    echo "[repack]    生成的 preinit.conf 将缺少 zsmalloc 加载行，hybridswap 会因符号缺失加载失败"
    echo "[repack]    若确需如此请确认设备上 zsmalloc 已由其他途径加载，否则必须补上该 KO"
  fi

  # 生成 preinit.conf（顺序不能颠倒：zsmalloc → hybridswap）
  {
    echo "#!/system/bin/sh"
    echo "# 本文件由 repack.sh 自动生成，勿手工修改"
    echo "# 加载顺序固定：zsmalloc 必须先于 hybridswap（后者依赖前者的 zs_*_oplus 导出）"
    echo ""
    [ -n "$ZSM_KO" ] && echo "insmod $(basename "$ZSM_KO")"
    echo "insmod $(basename "$HSW_KO") zram_algo=${ALGO}"
  } > "$STAGE/preinit/preinit.conf"
  echo "[repack] preinit.conf 生成: ${ALGO}（zsmalloc=$(basename "${ZSM_KO:-无}")）"
else
  # xiaomi: zram.ko 必须叫 zram.ko + sha256 指纹
  cp "$1" "$STAGE/zram.ko"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$STAGE/zram.ko" | awk '{print $1}' > "$STAGE/zram.ko.sha256"
  else
    PY_AVAILABLE="$PY"; [ -z "$PY_AVAILABLE" ] && PY_AVAILABLE="python"
    "$PY_AVAILABLE" - "$STAGE/zram.ko" "$STAGE/zram.ko.sha256" <<'PYSHA'
import sys, hashlib
data = open(sys.argv[1],'rb').read()
open(sys.argv[2],'w').write(hashlib.sha256(data).hexdigest() + '\n')
PYSHA
  fi
  echo "[repack] zram.ko 注入 + sha256 指纹记录"

  # 2.1 stock KO 随包（回滚救生索）: 从设备取证目录找原厂 zram.ko
  DEVICE_DIR="${DEVICE_DIR:-}"
  mkdir -p "$STAGE/stock"
  if [ -n "$DEVICE_DIR" ] && [ -d "$DEVICE_DIR" ]; then
    STOCK_FOUND=$(find "$DEVICE_DIR" -name 'zram.ko' 2>/dev/null | grep -v built- | head -1)
    if [ -n "$STOCK_FOUND" ]; then
      cp "$STOCK_FOUND" "$STAGE/stock/zram.ko"
      echo "[repack] stock/zram.ko 随包（回滚救生索）: $STOCK_FOUND"
    else
      echo "[repack] ⚠ WARNING: 设备目录里没找到原厂 zram.ko，stock/ 为空 —— 回滚将依赖系统路径"
    fi
    STOCK_ZSM=$(find "$DEVICE_DIR" -name 'zsmalloc.ko' 2>/dev/null | grep -v built- | head -1)
    [ -n "$STOCK_ZSM" ] && cp "$STOCK_ZSM" "$STAGE/stock/zsmalloc.ko" && \
      echo "[repack] stock/zsmalloc.ko 随包"
  else
    echo "[repack] ⚠ WARNING: 未设 DEVICE_DIR，stock/ 为空 —— 建议传设备取证目录"
  fi

  # 2.2 设备/内核指纹（安装时与运行时双重门禁）
  if [ -n "$DEVICE_DIR" ] && [ -d "$DEVICE_DIR" ]; then
    [ -f "$DEVICE_DIR/device.txt" ] && cp "$DEVICE_DIR/device.txt" "$STAGE/.target_device"
    [ -f "$DEVICE_DIR/uname.txt" ] && \
      head -c 40 "$DEVICE_DIR/uname.txt" | tr -d '\r\n' > "$STAGE/.target_kernel"
    echo "[repack] 设备/内核指纹写入 (.target_device / .target_kernel)"
  fi
fi

# ── 3. 版本号 ──
STAMP=$(date +%Y%m%d)
HASH=$(sha256sum "$1" | cut -c1-8)
sed -i.bak "s/^version=.*/version=1.0-${STAMP}-${HASH}/" "$STAGE/module.prop" 2>/dev/null \
  || sed -i "s/^version=.*/version=1.0-${STAMP}-${HASH}/" "$STAGE/module.prop"
rm -f "$STAGE/module.prop.bak"

# ── 4. 打包 ──
ZIP="dist/lz4kds侧载-${ARCH}-${STAMP}-${HASH}.zip"
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

if command -v zip >/dev/null 2>&1; then
  (cd "$STAGE" && zip -r "$ROOT/$ZIP" . >/dev/null 2>&1) || true
fi
# zip 不可用 / 失败 / 未产出文件 → 回退 python zipfile
if [ ! -f "$ROOT/$ZIP" ] && [ -n "$PY" ]; then
  "$PY" - "$STAGE" "$ROOT/$ZIP" <<'PYEOF' || { rm -rf "$STAGE"; echo "[repack] FAILED: python zip error"; exit 1; }
import sys, os, zipfile
stage, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for fn in files:
            full = os.path.join(root, fn)
            z.write(full, os.path.relpath(full, stage))
print("[repack] packed with python zipfile")
PYEOF
fi
rm -rf "$STAGE"
[ -f "$ROOT/$ZIP" ] || { echo "[repack] FAILED: zip 未生成 $ROOT/$ZIP（zip 与 python 均不可用？）"; exit 1; }

echo "[repack] done: $ZIP"
echo "[repack] 用户侧: KSU Manager -> 模块 -> 从存储安装 -> 重启"
