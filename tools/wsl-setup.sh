#!/usr/bin/env bash
# ============================================================================
# wsl-setup.sh —— 在 WSL2 / Linux 里一键准备 lz4kds 编译环境
#
# 用法（在 WSL 终端里执行，不要用 Windows 的 Git Bash）：
#   bash tools/wsl-setup.sh
#   bash tools/wsl-setup.sh --copy      # 顺便把工作区拷到 WSL 家目录
#   bash tools/wsl-setup.sh --mirror tuna
#
# 做四件事：
#   1. 检查宿主是 Linux
#   2. apt 安装内核构建依赖
#   3. 获取 Android clang（走 tools/get-clang.sh，支持镜像）
#   4. （可选）把工作区从 /mnt/d 拷贝到 ~/lz4kds（NTFS 上编译又慢又容易出错）
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIRROR=""
DO_COPY=0
DEST="$HOME/lz4kds"

while [ $# -gt 0 ]; do
  case "$1" in
    --copy)   DO_COPY=1; shift ;;
    --mirror) MIRROR="$2"; shift 2 ;;
    --dest)   DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

log() { echo -e "\033[1;36m[setup]\033[0m $*"; }
die() { echo -e "\033[1;31m[setup] ERROR:\033[0m $*"; exit 1; }

# ── 1. 宿主检查 ──
HOSTSYS=$(uname -s 2>/dev/null || echo unknown)
case "$HOSTSYS" in
  MINGW*|MSYS*|CYGWIN*|Windows*)
    die "你在 Windows 的 Git Bash 里运行。请改用 WSL：
      wsl -d Ubuntu
      bash tools/wsl-setup.sh" ;;
esac
log "宿主: $HOSTSYS ✓"

# 是否在 /mnt（NTFS）上
case "$ROOT" in
  /mnt/*) log "注意：工作区在 Windows 盘（$ROOT），编译会偏慢，建议加 --copy 拷到 Linux 文件系统" ;;
esac

# ── 2. 依赖 ──
log "安装构建依赖（需要输入 sudo 密码）..."
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO apt-get update -qq || die "apt update 失败"
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git make python3 gcc g++ bc bison flex libssl-dev \
  kmod zip unzip xz-utils libelf-dev cpio rsync \
  || die "依赖安装失败（检查网络/源）"
log "依赖安装完成"

# 版本速览
for t in git make python3 gcc; do
  printf '  %-8s %s\n' "$t" "$(command -v $t >/dev/null 2>&1 && $t --version 2>&1 | head -1 || echo '缺失')"
done

# ── 3. 工具链 ──
if [ -x "$ROOT/work/clang" ] || ls -d "$ROOT/work/clang"/clang-r*/bin >/dev/null 2>&1; then
  log "work/clang 下已有工具链，跳过下载"
  CLBIN=$(ls -d "$ROOT/work/clang"/clang-r*/bin 2>/dev/null | sort | tail -1)
else
  log "获取 Android clang..."
  if [ -n "$MIRROR" ]; then
    bash "$ROOT/tools/get-clang.sh" --mirror "$MIRROR"
  else
    bash "$ROOT/tools/get-clang.sh"
  fi
  CLBIN=$(ls -d "$ROOT/work/clang"/clang-r*/bin 2>/dev/null | sort | tail -1)
fi

[ -n "${CLBIN:-}" ] && [ -x "$CLBIN/clang" ] || die "工具链未就绪，请手动运行 tools/get-clang.sh 查看报错"

# 写一个 env 文件，后续 source 即可
ENV_FILE="$ROOT/work/clang.env"
cat > "$ENV_FILE" <<EOF
# 由 wsl-setup.sh 生成 —— 用 source 加载
export ANDROID_CLANG="$CLBIN"
export PATH="$CLBIN:\$PATH"
EOF
log "环境已写入: $ENV_FILE"

# ── 4. 可选拷贝 ──
if [ "$DO_COPY" = "1" ]; then
  case "$ROOT" in
    /mnt/*)
      log "拷贝工作区到 $DEST（排除 work/ 大文件）..."
      mkdir -p "$DEST"
      rsync -a --exclude 'work/' --exclude 'dist/*.zip' "$ROOT"/ "$DEST"/ \
        || die "rsync 失败"
      # 把工具链也带过去（它可能就在 work/clang）
      if [ -d "$ROOT/work/clang" ]; then
        log "同步工具链到 $DEST/work/clang ..."
        mkdir -p "$DEST/work"
        rsync -a "$ROOT/work/clang"/ "$DEST/work/clang"/
      fi
      if [ -n "${CLBIN:-}" ]; then
        NEWBIN="$DEST/work/clang/$(basename "$(dirname "$CLBIN")")/bin"
        cat > "$DEST/work/clang.env" <<EOF2
export ANDROID_CLANG="$NEWBIN"
export PATH="$NEWBIN:\$PATH"
EOF2
      fi
      log "拷贝完成: $DEST"
      ROOT="$DEST"
      ;;
    *) log "工作区已在 Linux 文件系统上，无需拷贝" ;;
  esac
fi

# ── 完成提示 ──
CLBIN=$(ls -d "$ROOT/work/clang"/clang-r*/bin 2>/dev/null | sort | tail -1)
echo
log "========== 准备完成 =========="
echo "  工作区:   $ROOT"
echo "  工具链:   ${CLBIN:-未就绪}"
echo
echo "接下来执行："
echo "  cd $ROOT"
echo "  source work/clang.env          # 加载 ANDROID_CLANG"
echo "  bash pipeline.sh devices/<设备名>"
echo
echo "设备目录里现在有："
ls -1 "$ROOT/devices" 2>/dev/null | sed 's/^/  /'
