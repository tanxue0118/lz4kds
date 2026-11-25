#!/system/bin/sh
# lz4kds 设备取证脚本 —— 用户侧执行
# 用法: 推到手机, root 执行, 回传 /sdcard/lz4kds_recon_*.tgz 给适配者
#   adb push recon.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/recon.sh'
#   adb pull /sdcard/lz4kds_recon_<机型>.tgz
#
# 全程只读: 除 /sdcard 外不写任何位置, 不接触 boot/persist/modem/tz/vbmeta 等分区

OUT=/sdcard/lz4kds_recon
MODEL=$(getprop ro.product.model 2>/dev/null | tr -d ' ')
[ -z "$MODEL" ] && MODEL=unknown
rm -rf "$OUT"
mkdir -p "$OUT"

log() { echo "[recon] $*"; }

# ── 1. 版本与设备信息 ──────────────────────────────
uname -r                          > "$OUT/uname.txt" 2>&1
cat /proc/version                 > "$OUT/proc_version.txt" 2>&1
getprop ro.product.model          > "$OUT/model.txt" 2>&1
getprop ro.product.brand          > "$OUT/brand.txt" 2>&1
getprop ro.product.device         > "$OUT/device.txt" 2>&1
getprop ro.board.platform         > "$OUT/soc.txt" 2>&1
getprop ro.build.version.release  > "$OUT/android_ver.txt" 2>&1
getprop ro.build.version.incremental > "$OUT/build_id.txt" 2>&1
getconf PAGE_SIZE                 > "$OUT/page_size.txt" 2>&1

# ── 2. 内核完整配置 ────────────────────────────────
if [ -r /proc/config.gz ]; then
  zcat /proc/config.gz > "$OUT/config.txt" 2>/dev/null \
    || su -c 'gzip -d < /proc/config.gz' > "$OUT/config.txt" 2>/dev/null \
    || echo "extract failed" > "$OUT/config.txt"
  log "config.gz OK ($(wc -l < "$OUT/config.txt") lines)"
else
  echo "NO /proc/config.gz (CONFIG_IKCONFIG_PROC off)" > "$OUT/config.txt"
  log "config.gz MISSING"
fi

# ── 3. vendor/system/dlkm 全部 KO ─────────────────
log "collecting modules..."
for d in /vendor/lib/modules /system/lib/modules \
         /vendor_dlkm/lib/modules /odm/lib/modules \
         /system_dlkm/lib/modules /system_dlkm/flatten/lib/modules \
         /lib/modules; do
  if [ -d "$d" ]; then
    DST="$OUT/modules_$(echo "$d" | tr '/' '_')"
    mkdir -p "$DST"
    cp "$d"/*.ko "$DST/" 2>/dev/null
    log "  $d -> $(ls "$DST" 2>/dev/null | wc -l) files"
  fi
done

# ── 4. kallsyms（符号名+类型, 地址置零减体积）──────
if [ -r /proc/kallsyms ]; then
  if [ -s /proc/kallsyms ] && [ "$(head -1 /proc/kallsyms | awk '{print $1}')" != "0000000000000000" ]; then
    awk '{print $2, $3}' /proc/kallsyms > "$OUT/kallsyms.txt" 2>/dev/null
  else
    # 地址被 kptr_restrict 置零, 仍可用 root 读符号名
    su -c 'cat /proc/kallsyms' 2>/dev/null | awk '{print $2, $3}' > "$OUT/kallsyms.txt"
  fi
fi
log "kallsyms: $(wc -l < "$OUT/kallsyms.txt" 2>/dev/null) symbols"

# ── 5. 原厂 zram / swap 状态（供回退参考）─────────
cat /sys/block/zram0/disksize       > "$OUT/zram_disksize.txt" 2>/dev/null
cat /sys/block/zram0/comp_algorithm > "$OUT/zram_algo.txt"     2>/dev/null
cat /sys/block/zram0/mm_stat        > "$OUT/zram_mmstat.txt"   2>/dev/null
cat /proc/swaps                     > "$OUT/swaps.txt"         2>/dev/null
cat /proc/meminfo                   > "$OUT/meminfo.txt"       2>/dev/null
cat /sys/block/zram0/initstate      > "$OUT/zram_initstate.txt" 2>/dev/null
ls /sys/block/zram0/holders         > "$OUT/zram_holders.txt"  2>/dev/null
getprop ro.boot.bootreason          > "$OUT/bootreason.txt"    2>/dev/null
ls /sys/block/                      > "$OUT/block_devices.txt" 2>/dev/null
ls /vendor/lib/modules/             > "$OUT/vendor_module_list.txt" 2>/dev/null
ls /system_dlkm/lib/modules/ /system_dlkm/flatten/lib/modules/ 2>/dev/null \
                                    > "$OUT/system_dlkm_module_list.txt"

# ── 6. 关键配置项快查（适配者第一眼看）───────────
{
  echo "=== device ==="
  echo "model: $(getprop ro.product.model) / device: $(getprop ro.product.device)"
  echo "brand: $(getprop ro.product.brand) / soc: $(getprop ro.board.platform)"
  echo "android: $(getprop ro.build.version.release) / build: $(getprop ro.build.version.incremental)"
  echo "uname: $(uname -r)"
  echo "page_size: $(getconf PAGE_SIZE 2>/dev/null)"
  echo
  echo "=== kernel config (key items) ==="
  grep -E '^CONFIG_(ZRAM|ZSMALLOC|MODVERSIONS|MODULE_SIG|KALLSYMS_ALL|IKCONFIG_PROC|CFI_CLANG|LTO|HYBRIDSWAP|HYBRID_ZSMALLOC|CRYPTO_LZ4K|CRYPTO_LZ4|CRYPTO_ZSTD|KERNEL_MODE_NEON)' \
    "$OUT/config.txt" 2>/dev/null
  echo
  echo "=== zram state ==="
  echo "disksize: $(cat /sys/block/zram0/disksize 2>/dev/null)"
  echo "algo: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
  echo "swap: $(grep -c zram "$OUT/swaps.txt" 2>/dev/null || echo 0) zram device(s)"
  echo
  echo "=== vendor modules (hybridswap related) ==="
  ls "$OUT"/modules_* 2>/dev/null | grep -iE 'hybrid|zram|zsmalloc' || echo "(none found)"
} > "$OUT/00_summary.txt"

# ── 7. 设备指纹（防发错包）───────────────────────
{
  echo "model=$(getprop ro.product.model)"
  echo "device=$(getprop ro.product.device)"
  echo "soc=$(getprop ro.board.platform)"
  echo "uname=$(uname -r)"
  echo "page_size=$(getconf PAGE_SIZE 2>/dev/null)"
  echo "build=$(getprop ro.build.version.incremental)"
  echo "collected=$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT/DEVICE_FINGERPRINT.txt"

# ── 8. 打包 ──────────────────────────────────────
cd /sdcard || exit 1
SAFE_MODEL=$(echo "$MODEL" | tr -cd 'A-Za-z0-9._-')
[ -z "$SAFE_MODEL" ] && SAFE_MODEL=unknown
TARBALL="lz4kds_recon_${SAFE_MODEL}.tgz"
rm -f "$TARBALL"
tar czf "$TARBALL" lz4kds_recon/ 2>/dev/null
SIZE=$(du -h "$TARBALL" 2>/dev/null | cut -f1)
log "=============================================="
log "DONE: /sdcard/$TARBALL ($SIZE)"
log "回传: adb pull /sdcard/$TARBALL"
log "=============================================="
log "全程只读, 未写入任何分区; boot/persist/modem/tz/vbmeta 均未接触"
