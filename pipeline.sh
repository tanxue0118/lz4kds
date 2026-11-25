#!/usr/bin/env bash
# ============================================================================
# pipeline.sh —— lz4kds 侧载模块 per-device KO 自动编译流水线（双架构）
#
# 用法:
#   bash pipeline.sh devices/<设备名>
#   bash pipeline.sh <设备名>              # 自动补全 devices/ 前缀
#
# 架构由 devices/<设备>/build.conf 的 [arch] type 决定:
#   oplus  → OPPO/realme，替换 oplus_bsp_hybridswap_zram.ko + zsmalloc
#   xiaomi → 小米/标准，替换 system_dlkm 的 zram.ko
#
# 阶段: 0环境 → 1校验 → 2抽CRC → 3取树 → 4配置 → 5编译 → 6符号闸门 → 7CRC闸门 → 8打包
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

DEVARG="${1:-}"
[ -z "$DEVARG" ] && { echo "用法: bash pipeline.sh devices/<设备名>"; exit 2; }

if   [ -d "$ROOT/$DEVARG" ]; then DEVDIR="$ROOT/$DEVARG";
elif [ -d "$ROOT/devices/$DEVARG" ]; then DEVDIR="$ROOT/devices/$DEVARG";
else echo "[pipeline] 设备目录不存在: $DEVARG"; exit 2; fi

DEVNAME=$(basename "$DEVDIR")
BUILD_CONF="$DEVDIR/build.conf"
WORK="$ROOT/work/$DEVNAME"
DIST="$ROOT/dist"
LOG="$WORK/build.log"
RESULT="$DEVDIR/RESULT.md"
mkdir -p "$WORK" "$DIST"
: > "$LOG"

STAGE=""; STATUS="FAILED"; ARTIFACT=""; REASON=""; KO_SAVED=""

log()  { echo "[pipeline] $*" | tee -a "$LOG"; }
stage(){ STAGE="$1"; log "======== Stage $STAGE ========"; }

write_result() {
  local next
  if [ "$STATUS" = "SUCCESS" ]; then
    next="dist zip 发给用户刷入; 用户侧验证命令见 AGENTS.md"
  else
    next="查 work/$DEVNAME/build.log 定位报错行, 对照 AGENTS.md 第 5 节失败决策表处理后重跑"
  fi
  cat > "$RESULT" <<EOF
# RESULT — $DEVNAME

- 状态: **$STATUS**
- 架构: ${ARCH:-未定}
- 停止阶段: ${STAGE:-无}
- 产物: ${ARTIFACT:-无}
- 原因: $REASON
- 时间: $(date '+%F %T')
- 日志: work/$DEVNAME/build.log
- KO 留档: ${KO_SAVED:-无}

## 下一步
$next
EOF
}

die() { REASON="$1"; log "FAILED @[$STAGE]: $1"; STATUS="FAILED"; write_result; exit 1; }
trap 'if [ "$STATUS" != "SUCCESS" ]; then [ -n "$REASON" ] || REASON="脚本异常退出 (见日志末尾)"; STATUS="FAILED"; write_result; fi' EXIT

# ---------- build.conf 解析 ----------
conf_get() {
  awk -v s="$1" -v k="$2" '
    BEGIN { insec = 0 }
    {
      line = $0
      sub(/[;#].*$/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      if (line ~ /^\[/) {
        cur = line; sub(/^\[/, "", cur); sub(/\]$/, "", cur)
        insec = (cur == s); next
      }
      if (!insec) next
      eq = index(line, "=")
      if (eq == 0) next
      key = substr(line, 1, eq - 1); val = substr(line, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key == k) { print val; exit }
    }' "$BUILD_CONF"
}

# ============================================================================
stage "0-环境"
log "lz4kds 侧载流水线 | 设备: $DEVNAME"

# 0.1 必须是 Linux 环境（Windows 原生 / MSYS / Cygwin 跑不了 kbuild）
HOSTSYS=$(uname -s 2>/dev/null || echo unknown)
case "$HOSTSYS" in
  MINGW*|MSYS*|CYGWIN*|Windows*)
    die "检测到 Windows 宿主（$HOSTSYS）。Linux 内核 kbuild 不支持 Windows 原生构建：
     - 请在 WSL2 里运行：wsl -d Ubuntu -- bash /mnt/d/.../pipeline.sh ...
     - 或使用原生 Linux 机器 / 容器
     - Windows NDK 里的 clang.exe 不能替代（modpost/host 工具需要 Linux ELF 可执行文件）"
    ;;
esac
log "宿主: $HOSTSYS ✓"

# 0.1b WSL 版本识别：WSL2 是真实 Linux 内核（可编译）；WSL1 是 syscall 翻译层（不可靠）
KREL_ENV=$(uname -r 2>/dev/null || echo "")
case "$KREL_ENV" in
  *[Mm]icrosoft*)
    case "$KREL_ENV" in
      4.4.*)
        die "检测到 WSL1（内核 $KREL_ENV）。WSL1 是系统调用翻译层、没有真实 Linux 内核，
    kbuild 在上面不可靠。请升级到 WSL2：
       wsl --set-version <发行版名> 2
       # 或在 PowerShell 里：wsl --install -d Ubuntu（默认装 WSL2）" ;;
      *)
        log "检测到 WSL2（$KREL_ENV）—— 真实 Linux 内核，可正常编译 ✓" ;;
    esac
    ;;
  *) : ;;
esac

# 0.1c 在 /mnt/* 上构建的内核包会很慢（DrvFs 大小写不敏感 + 无真实符号链接）
case "$ROOT" in
  /mnt/*)
    log "WARN: 工作区在 Windows 盘（$ROOT）"
    log "      kbuild 建议放 Linux 文件系统，例如： bash tools/wsl-setup.sh --copy"
    ;;
esac

# 0.2 基础依赖
MISS=""
for c in git make python3 awk gcc; do
  command -v "$c" >/dev/null 2>&1 || MISS="$MISS $c"
done
[ -n "$MISS" ] && die "主机缺依赖:$MISS (Ubuntu: apt install -y git make python3 kmod zip binutils build-essential bc bison flex libssl-dev)"
log "依赖检查通过"

# 0.3 提前解析工具链（避免阶段4才发现要下 2GB）
CLANG_HINT=""
for cand in \
    "${ANDROID_CLANG:-}" \
    "${CLANG_BIN:-}" \
    "$ROOT/work/clang" \
    "$HOME/android-clang" \
    "$HOME/kernel/prebuilts/clang/host/linux-x86" \
    "/opt/android-clang" \
    "/usr/lib/llvm" ; do
  [ -n "$cand" ] || continue
  if [ -x "$cand/clang" ]; then CLANG_HINT="$cand"; break; fi
  if [ -d "$cand" ]; then
    FOUND=$(ls -d "$cand"/clang-r*/bin 2>/dev/null | sort | tail -1)
    if [ -n "$FOUND" ] && [ -x "$FOUND/clang" ]; then CLANG_HINT="$FOUND"; break; fi
  fi
done
if [ -n "$CLANG_HINT" ]; then
  log "工具链已就绪: $CLANG_HINT"
else
  log "WARN: 未发现 Android clang 工具链（阶段4需要）"
  log "     可选方案："
  log "       1) build.conf 填 clang_dir=/path/to/clang-r*/bin"
  log "       2) 环境变量 export ANDROID_CLANG=/path/to/clang-r*/bin"
  log "       3) 首次自动下载：ALLOW_CLANG_DOWNLOAD=1 bash pipeline.sh ...（约 2GB，需好网络）"
  log "       4) 手动下载：bash tools/get-clang.sh"
fi

[ -f "$BUILD_CONF" ] || die "缺 $DEVDIR/build.conf —— 从 devices/TEMPLATE/build.conf 复制并按 AGENTS.md 第 3 节填写"

# ============================================================================
stage "1-校验"
# ── 1.0 架构自动判定（看取证包里实际有什么 KO，不靠猜）──
if [ -z "$(conf_get arch type | tr -d ' ')" ] || [ "$(conf_get arch type)" = "auto" ]; then
  HAS_HSW=$(find "$DEVDIR" -name 'oplus_bsp_hybridswap_zram.ko' 2>/dev/null | head -1)
  HAS_ZRAM=$(find "$DEVDIR" -name 'zram.ko' 2>/dev/null | head -1)
  if [ -n "$HAS_HSW" ]; then
    ARCH=oplus
    log "自动判定: 发现 oplus_bsp_hybridswap_zram.ko → oplus 路线"
  elif [ -n "$HAS_ZRAM" ]; then
    ARCH=xiaomi
    log "自动判定: 发现标准 zram.ko（无 oplus 私有驱动）→ xiaomi 路线"
  else
    die "取证包里既无 oplus_bsp_hybridswap_zram.ko 也无 zram.ko —— 无法判定架构，请人工确认设备形态"
  fi
else
  ARCH=$(conf_get arch type)
fi
case "$ARCH" in
  oplus|xiaomi) log "架构: $ARCH" ;;
  *) die "[arch] type=$ARCH 无效（必须是 oplus / xiaomi / auto / 留空）" ;;
esac
[ -d "$ROOT/templates/$ARCH" ] || die "缺模板目录 templates/$ARCH"

# 1.1 页大小
PS=$(tr -d '[:space:]' < "$DEVDIR/page_size.txt" 2>/dev/null || echo "")
[ "$PS" = "4096" ] || die "PAGE_SIZE=${PS:-未知}, lz4kds 仅支持 4096 页设备"
log "PAGE_SIZE=4096 OK"

# 1.2 架构专属前置检查
if [ "$ARCH" = "oplus" ]; then
  # OPPO: 必须 CONFIG_ZRAM=m 且原厂有 hybridswap KO
  ZR=$(grep -E '^[[:space:]]*CONFIG_ZRAM=' "$DEVDIR/config.txt" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
  case "$ZR" in
    m) log "CONFIG_ZRAM=m ✓" ;;
    y) die "CONFIG_ZRAM=y → 形态C 无 KO 挂点，该设备只能刷内核" ;;
    "") die "config.txt 缺 CONFIG_ZRAM，取证不完整" ;;
    *) die "CONFIG_ZRAM=$ZR 无法识别" ;;
  esac
  CRCREF="$DEVDIR/$(conf_get build crc_ref_ko)"
  if [ ! -f "$CRCREF" ]; then
    CRCREF=$(find "$DEVDIR" -name 'oplus_bsp_hybridswap_zram.ko' 2>/dev/null | head -1)
    [ -n "$CRCREF" ] || die "找不到 CRC 参照 KO（原厂 oplus_bsp_hybridswap_zram.ko）"
  fi
  log "CRC 参照: $CRCREF"
  ZSM_SRC=$(find "$DEVDIR" -name 'oplus_bsp_zsmalloc.ko' 2>/dev/null | head -1)
  [ -n "$ZSM_SRC" ] || die "取证包缺 oplus_bsp_zsmalloc.ko —— oplus 架构必需（先于 hybridswap 加载）"
  log "device zsmalloc: $ZSM_SRC"
else
  # 小米: CONFIG_ZRAM 应为 m（可替换），原厂 zram.ko 存在
  ZR=$(grep -E '^[[:space:]]*CONFIG_ZRAM=' "$DEVDIR/config.txt" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
  case "$ZR" in
    m) log "CONFIG_ZRAM=m ✓（zram 可替换）" ;;
    y) die "CONFIG_ZRAM=y → zram 编进内核，无法替换 zram.ko" ;;
    "") log "WARN: config.txt 缺 CONFIG_ZRAM，继续（xiaomi 路线按存在 zram.ko 判断）" ;;
    *) log "WARN: CONFIG_ZRAM=$ZR" ;;
  esac
  CRCREF=$(find "$DEVDIR" -name 'zram.ko' 2>/dev/null | head -1)
  [ -n "$CRCREF" ] || log "WARN: 未找到原厂 zram.ko，CRC 对齐将跳过"
  [ -n "$CRCREF" ] && log "CRC 参照: $CRCREF"
fi

# 1.3 必要文件
for f in uname.txt config.txt; do
  [ -s "$DEVDIR/$f" ] || die "缺少 $DEVDIR/$f"
done

# kallsyms 缺失时降级为"仅验证能否编过"模式（CI manual 构建用）
SKIP_SYMGATE=0
if [ -s "$DEVDIR/kallsyms.txt" ] && [ "$(grep -c . "$DEVDIR/kallsyms.txt" 2>/dev/null)" -gt 100 ]; then
  log "kallsyms: $(grep -c . "$DEVDIR/kallsyms.txt") 行，符号闸门将启用"
else
  SKIP_SYMGATE=1
  log "WARN: kallsyms.txt 缺失或过小 → 降级为「仅验证可编译」模式"
  log "      KO 是否能在真机加载无法验证，产物仅供技术验证，请勿直接刷入"
fi

KREL=$(tr -d '[:space:]' < "$DEVDIR/uname.txt")
[ -n "$KREL" ] || die "uname.txt 为空"
log "kernel_release = $KREL"

MODVER=$(grep -E '^[[:space:]]*CONFIG_MODVERSIONS=' "$DEVDIR/config.txt" | head -1 | cut -d= -f2 | tr -d ' ')
log "CONFIG_MODVERSIONS=${MODVER:-未配置}"

# ============================================================================
stage "2-抽CRC"
SYM_PREFIX="$WORK/$DEVNAME"
CRC_SRC_DIR="$DEVDIR"
python3 "$ROOT/tools/extract_crcs.py" "$CRC_SRC_DIR" "$SYM_PREFIX" 2>&1 | tee -a "$LOG"
SYMV="$SYM_PREFIX.Module.symvers"
[ -f "$SYMV" ] || die "Module.symvers 未生成"
NSYM=$(wc -l < "$SYMV" | tr -d ' ')
[ "$NSYM" -lt 100 ] && die "Module.symvers 仅 $NSYM 个符号 —— vendor KO 可能被 strip"
log "符号总数: $NSYM"

# ============================================================================
stage "3-取内核树"
KT="$WORK/kernel"
REPO=$(conf_get kernel repo)
BRANCH=$(conf_get kernel branch)
LOCAL_TREE=$(conf_get kernel local_tree)
DEPTH=$(conf_get kernel depth); DEPTH=${DEPTH:-1}

if [ -f "$KT/Makefile" ] || [ -f "$KT/common/Makefile" ]; then
  log "复用已有树: $KT"
elif [ -n "$LOCAL_TREE" ] && [ -d "$LOCAL_TREE" ]; then
  log "复制本地树 $LOCAL_TREE → $KT ..."
  rm -rf "$KT"; cp -a "$LOCAL_TREE" "$KT" >>"$LOG" 2>&1 || die "复制本地树失败"
elif [ -n "$REPO" ]; then
  log "克隆 $REPO (branch=${BRANCH:-default} depth=$DEPTH)..."
  rm -rf "$KT"
  CLONE="git clone --depth=$DEPTH"
  [ -n "$BRANCH" ] && CLONE="$CLONE -b $BRANCH"
  $CLONE "$REPO" "$KT" >>"$LOG" 2>&1 || die "git clone 失败: repo=$REPO branch=${BRANCH:-default}（核对 AGENTS.md 第 6 节）"
else
  die "build.conf [kernel] 既无 repo 也无 local_tree"
fi

if [ ! -f "$KT/Makefile" ]; then
  for sub in common kernel private/msm-google; do
    [ -f "$KT/$sub/Makefile" ] && { KT="$KT/$sub"; log "内核树实际位置: $KT"; break; }
  done
fi
[ -f "$KT/Makefile" ] || die "找不到内核 Makefile（仓库结构异常，人工检查 $WORK/kernel）"

# ============================================================================
stage "4-配置"
CLANG_DIR=$(conf_get build clang_dir)
CLBIN=""
if [ -n "$CLANG_DIR" ] && [ -x "$CLANG_DIR/clang" ]; then
  CLBIN="$CLANG_DIR"
  log "使用 build.conf 指定的 clang_dir"
elif [ -n "$CLANG_HINT" ]; then
  CLBIN="$CLANG_HINT"
  log "使用阶段0解析到的工具链"
else
  # 未找到工具链：默认「快速失败」，不擅自下载 2GB
  if [ "${ALLOW_CLANG_DOWNLOAD:-0}" != "1" ]; then
    die "未找到 Android clang 工具链，已停止（不自动下载 2GB）。
    请任选其一后重跑：
      1) build.conf:  clang_dir=/path/to/clang-r*/bin
      2) export ANDROID_CLANG=/path/to/clang-r*/bin
      3) 手动获取:    bash tools/get-clang.sh [--mirror]
      4) 允许自动下载: ALLOW_CLANG_DOWNLOAD=1 bash pipeline.sh ...
    注意：必须 Linux/WSL 环境；Windows NDK 的 clang 不能用于 kbuild。"
  fi
  log "ALLOW_CLANG_DOWNLOAD=1，开始下载 Android clang（~2GB，超时 30 分钟）..."
  mkdir -p "$ROOT/work"
  timeout 1800 git clone --depth=1 \
    https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
    "$ROOT/work/clang" >>"$LOG" 2>&1 \
    || die "clang 克隆失败/超时 —— 网络受限时改用 tools/get-clang.sh 或手动指定 clang_dir"
  CLBIN=$(ls -d "$ROOT/work/clang/"clang-r*/bin 2>/dev/null | sort | tail -1)
fi
[ -n "$CLBIN" ] && [ -x "$CLBIN/clang" ] || die "找不到可用 clang（CLBIN='${CLBIN}'）—— 检查 clang_dir / ANDROID_CLANG"
CC="$CLBIN/clang"
log "工具链: $CLBIN"

MAKEARGS="ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=$CC LD=$CLBIN/ld.lld AR=$CLBIN/llvm-ar NM=$CLBIN/llvm-nm OBJCOPY=$CLBIN/llvm-objcopy OBJDUMP=$CLBIN/llvm-objdump STRIP=$CLBIN/llvm-strip HOSTCC=$CC HOSTCXX=$CLBIN/clang++"

cp "$DEVDIR/config.txt" "$KT/.config"
( cd "$KT" && make $MAKEARGS olddefconfig ) >>"$LOG" 2>&1 || die "olddefconfig 失败 —— 内核树与设备 config 不匹配，换树"
( cd "$KT" && make $MAKEARGS prepare ) >>"$LOG" 2>&1 || die "prepare 失败 —— 查日志（resolve_btfids 报错可忽略后重跑）"

printf '#define UTS_RELEASE "%s"\n' "$KREL" > "$KT/include/generated/utsrelease.h"
printf '%s\n' "$KREL" > "$KT/include/config/kernel.release"
log "UTS_RELEASE = $KREL"

# ============================================================================
stage "5-编译"
# ── 5.0 按架构确定：源码目录 / 放置路径 / KO 名 / CONFIG 门 ──
# 原则：默认值由 ARCH 强制决定，build.conf 只在显式填写时覆盖，且覆盖值与架构不符则报错
if [ "$ARCH" = "oplus" ]; then
  DEF_SRC="source-oplus"
  DEF_MP="vendor/oplus/kernel/mm/hybridswap_zram"
  DEF_KO="oplus_bsp_hybridswap_zram.ko"
  CFG_PINS="CONFIG_HYBRIDSWAP_ZRAM=m CONFIG_HYBRIDSWAP=y CONFIG_HYBRIDSWAP_CORE=y CONFIG_HYBRIDSWAP_SWAPD=y"
else
  DEF_SRC="source-xiaomi"
  DEF_MP="drivers/block/zram"
  DEF_KO="zram.ko"
  CFG_PINS="CONFIG_CRYSTAL_HYBRIDSWAP=m CONFIG_CRYSTAL_HYBRIDSWAP_SDDC=y CONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD=y"
fi

SRCDIR=$(conf_get build source_dir);       SRCDIR=${SRCDIR:-$DEF_SRC}
MP=$(conf_get build module_path);          MP=${MP:-$DEF_MP}
KONAME=$(conf_get build ko_name);          KONAME=${KONAME:-$DEF_KO}
EXTRA=$(conf_get build extra_make_flags)

# 5.1 覆盖值一致性校验（防 build.conf 残留另一架构的值）
FAILED_OVERRIDE=0
case "$ARCH" in
  xiaomi)
    case "$KONAME" in *oplus*) log "ERROR: [build] ko_name=$KONAME 是 oplus 的 KO 名，与 arch=xiaomi 冲突"; FAILED_OVERRIDE=1 ;; esac
    case "$MP" in *oplus*)     log "ERROR: [build] module_path=$MP 是 oplus 的路径，与 arch=xiaomi 冲突"; FAILED_OVERRIDE=1 ;; esac
    case "$SRCDIR" in *oplus*) log "ERROR: [build] source_dir=$SRCDIR 是 oplus 源码，与 arch=xiaomi 冲突"; FAILED_OVERRIDE=1 ;; esac
    ;;
  oplus)
    case "$MP" in *drivers/block/zram*) log "ERROR: [build] module_path=$MP 是标准 zram 路径，与 arch=oplus 冲突"; FAILED_OVERRIDE=1 ;; esac
    ;;
esac
[ "$FAILED_OVERRIDE" = "1" ] && die "build.conf 的 [build] 段与架构 $ARCH 冲突 —— 把这些项留空让 pipeline 自动填"

log "架构=$ARCH 源码=$SRCDIR 路径=$MP KO=$KONAME"
[ -d "$ROOT/$SRCDIR" ] || die "源码目录不存在: $SRCDIR"

# ── 5.2 放源码：两种模式 ──
# oplus  : 树内编译（源码必须放到厂商树的 vendor/oplus/kernel/mm/hybridswap_zram）
# xiaomi : 树外编译（make M=<源码目录>，不污染内核树的 drivers/block/zram）
if [ "$ARCH" = "xiaomi" ]; then
  # 树外编译：源码留原处，只把 Module.symvers 交给内核树
  MP_ABS="$ROOT/$SRCDIR"
  cp "$SYMV" "$KT/Module.symvers"
  log "树外编译模式：M=$MP_ABS（不覆盖内核树 drivers/block/zram）"
else
  mkdir -p "$KT/$MP"
  rm -rf "${KT:?}/$MP"/*
  cp -r "$ROOT/$SRCDIR/." "$KT/$MP/"
  cp "$SYMV" "$KT/Module.symvers"
  MP_ABS="$KT/$MP"
  log "树内编译模式：源码已放入 $MP"
fi

# ── 5.3 CONFIG 注入 ──
# xiaomi 路线靠 Makefile 里的 ccflags 直接定义，不需要改 .config
# oplus 路线仍需要 CONFIG_* 开关（树内 obj-$(CONFIG_xxx) 求值）
if [ "$ARCH" = "oplus" ]; then
  for pin in $CFG_PINS; do
    key=${pin%%=*}
    sed -i "/^${key}=/d" "$KT/.config" 2>/dev/null
    echo "$pin" >> "$KT/.config"
  done
  ( cd "$KT" && make $MAKEARGS olddefconfig ) >>"$LOG" 2>&1 \
    || log "WARN: 注入 CONFIG 后 olddefconfig 失败，继续尝试构建"
  log "CONFIG 注入: $CFG_PINS"
else
  log "CONFIG 由 Makefile ccflags 注入（SDDC + LZ4KD 默认启用），不改 .config"
fi

log "make M=$MP_ABS modules ..."
( cd "$KT" && make $MAKEARGS $EXTRA M="$MP_ABS" KBUILD_MODPOST_WARN=1 modules ) >>"$LOG" 2>&1 \
  || die "modules 编译失败 —— 查日志末尾 undefined/头文件错误"

KO="$MP_ABS/$KONAME"
[ -f "$KO" ] || { ls "$MP_ABS"/*.ko >>"$LOG" 2>&1; die "编译结束但未找到 $KONAME（实际产物见日志）"; }
BUILD_DIR="$MP_ABS"
log "KO 生成: $KO ($(du -h "$KO" | cut -f1))"

# ============================================================================
stage "6-闸门1符号"
if [ "$SKIP_SYMGATE" = "1" ]; then
  log "符号闸门 SKIP（无 kallsyms，仅验证编译）"
  log "      产物标记为 experimental，不建议直接刷入真机"
  EXPERIMENTAL=1
else
  if bash "$ROOT/tools/symgate.sh" "$KO" "$DEVDIR/kallsyms.txt" 2>&1 | tee -a "$LOG"; then
    log "符号闸门 PASS"
  else
    die "符号闸门 FAIL —— KO 引用了设备内核不存在的符号，换树/补 CONFIG"
  fi
fi

# ============================================================================
stage "7-闸门2CRC"
if [ "$MODVER" = "y" ] && [ -n "$CRCREF" ] && [ -f "$CRCREF" ]; then
  CRCOUT=$(python3 "$ROOT/tools/crc_align.py" "$KO" "$CRCREF" 2>&1); CRCRC=$?
  echo "$CRCOUT" | tee -a "$LOG"
  [ $CRCRC -eq 0 ] || die "crc_align.py 异常退出 (rc=$CRCRC)"
  UNMATCH=$(echo "$CRCOUT" | grep -c 'WARN' || true)
  [ "${UNMATCH:-0}" -gt 20 ] && die "CRC unmatched=${UNMATCH} 过多 —— 参照 KO 与目标内核差异过大"
  log "CRC 对齐完成 (unmatched=${UNMATCH:-0})"
else
  log "跳过 CRC 对齐（MODVERSIONS=${MODVER:-n} 或无参照 KO）"
fi

# ============================================================================
stage "8-打包"
cp "$KO" "$DEVDIR/built-$KONAME"; KO_SAVED="$DEVDIR/built-$KONAME"
PACK_ALGO=$(conf_get pack algo); PACK_ALGO=${PACK_ALGO:-lz4kds}

ARGS=("$KO")
if [ "$ARCH" = "oplus" ]; then
  # 用设备自己的 zsmalloc KO（不能用别的机型的）
  ARGS+=("$ZSM_SRC")
fi

ARCH="$ARCH" ALGO="$PACK_ALGO" FRESH_DIR="$BUILD_DIR" DEVICE_DIR="$DEVDIR" \
  bash "$ROOT/tools/repack.sh" "${ARGS[@]}" 2>&1 | tee -a "$LOG"

ZIP=$(ls -t "$DIST"/lz4kds侧载-"$ARCH"-*.zip 2>/dev/null | head -1)
[ -f "$ZIP" ] || die "repack 后未找到 zip"

# experimental 模式：重命名产物并写警告，避免被误刷
if [ "${EXPERIMENTAL:-0}" = "1" ]; then
  NEWZIP="${ZIP%.zip}-EXPERIMENTAL.zip"
  mv -f "$ZIP" "$NEWZIP" && ZIP="$NEWZIP"
  {
    echo "=============================================================="
    echo "⚠ 此包为 EXPERIMENTAL（未经符号闸门验证）"
    echo "  构建时没有设备的 kallsyms，无法确认 KO 能在真机加载。"
    echo "  仅供技术验证，请勿直接刷入日常使用设备。"
    echo "=============================================================="
  } | tee -a "$LOG"
fi

ARTIFACT="$ZIP"
STATUS="SUCCESS"
if [ "${EXPERIMENTAL:-0}" = "1" ]; then
  REASON="架构=$ARCH，编译通过（无 kallsyms，未做符号验证）"
else
  REASON="架构=$ARCH，9 阶段全部通过"
fi
write_result
log "=============================================================="
log "SUCCESS: $ZIP"
log "架构: $ARCH | 算法: $PACK_ALGO"
log "发给用户: 模块 zip + 回退说明"
log "=============================================================="
exit 0
