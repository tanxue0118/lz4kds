#!/usr/bin/env bash
# ============================================================================
# get-clang.sh —— 获取 Android clang 工具链（供本工作区 kbuild 用）
#
# 为什么需要它：
#   pipeline 阶段4 需要 Android clang（含 ld.lld / llvm-ar / llvm-nm 等）。
#   完整 git clone prebuilts/clang 约 2GB，国内网络常卡死。
#   本脚本优先用 gitiles 归档接口只拉**单个 clang 版本**（约 400-600MB），
#   失败再回退浅克隆，并支持镜像。
#
# ⚠ Windows NDK 的 clang.exe 不能替代：
#   - Linux 内核 kbuild 需要 Linux ELF 宿主工具（modpost、scripts/* 会被编译成宿主程序）
#   - Windows 上无法完成 host 工具构建，且路径/符号链接/fork 语义不同
#   - 必须在 WSL2 / 原生 Linux / 容器里跑
#
# 用法:
#   bash tools/get-clang.sh                       # 默认分支 main + 归档下载
#   bash tools/get-clang.sh --ver clang-r536225   # 指定版本
#   bash tools/get-clang.sh --mirror tuna         # 用清华镜像（国内推荐）
#   bash tools/get-clang.sh --git                 # 强制用 git 浅克隆
#   bash tools/get-clang.sh --dest /opt/clang     # 指定目标目录（默认 work/clang）
#
# 完成后输出一行 export，可直接复制进 shell。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/work/clang"
VER=""
BRANCH="refs/heads/main"
USE_GIT=0
MIRROR=""
TIMEOUT=1800

while [ $# -gt 0 ]; do
  case "$1" in
    --ver)    VER="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --dest)   DEST="$2"; shift 2 ;;
    --mirror) MIRROR="$2"; shift 2 ;;
    --git)    USE_GIT=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

log() { echo "[get-clang] $*"; }
die() { echo "[get-clang] ERROR: $*"; exit 1; }

# 平台检查
HOSTSYS=$(uname -s 2>/dev/null || echo unknown)
case "$HOSTSYS" in
  MINGW*|MSYS*|CYGWIN*|Windows*)
    die "当前是 Windows 宿主（$HOSTSYS）。请改用 WSL2：
      wsl -d Ubuntu -- bash /mnt/d/.../lz4kds/tools/get-clang.sh
    Windows NDK clang 不能用于 Linux 内核 kbuild。" ;;
esac
log "宿主: $HOSTSYS"

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
  || die "需要 curl 或 wget"
command -v tar >/dev/null 2>&1 || die "需要 tar"

# 选择下载源
case "$MIRROR" in
  tuna|tsinghua) BASE="https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/prebuilts/clang/host/linux-x86" ;;
  ustc)          BASE="https://mirrors.ustc.edu.cn/aosp/platform/prebuilts/clang/host/linux-x86" ;;
  ""|google|aosp) BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" ;;
  *) die "未知镜像: $MIRROR（支持 tuna / ustc / google）" ;;
esac
log "源: $BASE"

fetch() { # fetch <url> <outfile>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 3 --connect-timeout 30 \
      --max-time "$TIMEOUT" -o "$out" "$url"
  else
    wget -c --tries=3 --timeout=30 -O "$out" "$url"
  fi
}

mkdir -p "$DEST"
log "目标目录: $DEST"

ok=0

# 方式1：gitiles 归档接口，只拉单个 clang 版本（体积小得多）
if [ "$USE_GIT" = "0" ]; then
  if [ -z "$VER" ]; then
    # 未指定就用 main 分支下的最新默认版本（gitiles archive 支持目录）
    VER="clang-r536225"
    log "未指定 --ver，使用默认 $VER（如失败请用 --ver 指定版本）"
  fi
  TMP="$DEST/.archive.tar.gz"
  URL="$BASE/+archive/$BRANCH/$VER.tar.gz"
  log "方式1: gitiles 归档下载 $URL"
  if fetch "$URL" "$TMP"; then
    SZ=$(du -h "$TMP" 2>/dev/null | cut -f1)
    log "下载完成 ($SZ)，解包..."
    mkdir -p "$DEST/$VER"
    if tar xzf "$TMP" -C "$DEST/$VER" 2>>"$DEST/.tar.log"; then
      rm -f "$TMP"
      [ -x "$DEST/$VER/bin/clang" ] && ok=1
    else
      log "解包失败，见 $DEST/.tar.log"
      rm -f "$TMP"
    fi
  else
    log "归档下载失败（该版本/分支可能不存在，或网络受限）"
    rm -f "$TMP"
  fi
fi

# 方式2：git 浅克隆（兜底，体积大）
if [ "$ok" = "0" ]; then
  log "方式2: git 浅克隆（约 2GB，超时 ${TIMEOUT}s）"
  rm -rf "$DEST/.git-clone"
  if timeout "$TIMEOUT" git clone --depth=1 -b main "$BASE" "$DEST/.git-clone" 2>&1 | tail -5; then
    FOUND=$(ls -d "$DEST/.git-clone"/clang-r*/bin 2>/dev/null | sort | tail -1)
    if [ -n "$FOUND" ]; then
      VER=$(basename "$(dirname "$FOUND")")
      mv "$DEST/.git-clone/$VER" "$DEST/$VER" 2>/dev/null
      rm -rf "$DEST/.git-clone"
      [ -x "$DEST/$VER/bin/clang" ] && ok=1
    fi
  else
    log "git 克隆失败/超时"
    rm -rf "$DEST/.git-clone"
  fi
fi

[ "$ok" = "1" ] || die "未能获取工具链。可选：从已有 AOSP 源码树复制 prebuilts/clang/host/linux-x86/clang-* 到 $DEST，或直接用 build.conf 的 clang_dir 指向它"

BIN="$DEST/$VER/bin"
log "成功: $BIN"
"$BIN/clang" --version 2>/dev/null | head -2
echo
echo "使用方法（二选一）："
echo "  export ANDROID_CLANG=\"$BIN\""
echo "  或在 build.conf 里写: clang_dir = $BIN"
