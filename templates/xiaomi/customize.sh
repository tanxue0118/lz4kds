#!/system/bin/sh
# 安装脚本（xiaomi 路线）：设备/内核门禁 + KO 指纹 + stock KO 随包

if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi
fail() { ui_print "! $1"; ui_print "! 安装中止，未做任何更改"; exit 1; }

ui_print "- LZ4KDS 侧载模块（zram.ko 热替换路线）"
ui_print "- 算法: LZ4KD + SDDC"
ui_print "- 安全: sha256 门禁 / safe_mode / 熔断器 / 失败自动还原原厂"

[ -n "${MODPATH:-}" ] || fail "MODPATH 未设置"

arch="${ARCH:-$(uname -m 2>/dev/null)}"
case "$arch" in
  arm64|arm64-v8a|aarch64) ;;
  *) fail "仅支持 arm64（当前 $arch）" ;;
esac

# 设备门禁（打包时由 repack 写入 .target_device）
EXPECT_DEVICE=$(cat "$MODPATH/.target_device" 2>/dev/null | tr -d ' ')
if [ -n "$EXPECT_DEVICE" ]; then
  DEVICE=$(getprop ro.product.device 2>/dev/null | tr -d ' ')
  case "$DEVICE" in
    "$EXPECT_DEVICE"|"$EXPECT_DEVICE"_*) ;;
    *) fail "设备不匹配: 本包仅用于 '$EXPECT_DEVICE'，当前 '$DEVICE'" ;;
  esac
  ui_print "- 设备匹配: $DEVICE"
fi

# 内核门禁（同上）
EXPECT_KERNEL=$(cat "$MODPATH/.target_kernel" 2>/dev/null | tr -d ' ')
if [ -n "$EXPECT_KERNEL" ]; then
  KREL=$(uname -r 2>/dev/null)
  case "$KREL" in
    "$EXPECT_KERNEL"|"$EXPECT_KERNEL"-*) ;;
    *) fail "内核不匹配: 本包要求 '$EXPECT_KERNEL*'，当前 '$KREL'" ;;
  esac
  ui_print "- 内核匹配: $KREL"
fi

# 必需文件
[ -f "$MODPATH/zram.ko" ] || fail "zram.ko 缺失"
[ -f "$MODPATH/stock/zram.ko" ] || fail "stock/zram.ko 缺失（无法保证回滚）"

# KO 指纹
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$MODPATH/zram.ko" | awk '{print $1}' > "$MODPATH/zram.ko.sha256"
  ui_print "- KO sha256 已记录"
fi

ui_print "- 回退: KernelSU 禁用本模块重启即还原原厂"
ui_print "- 容量与算法请在系统侧调整"

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/post-fs-data.sh 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
