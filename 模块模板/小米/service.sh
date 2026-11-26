#!/system/bin/sh
# 开机完成后：清熔断标记、记录状态
MODDIR=${0%/*}
LOG=$MODDIR/selftest.log

i=0
while [ $i -lt 30 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

# 成功到达系统：清掉替换标记、失败计数、safe_mode（本次已证明稳定）
rm -f "$MODDIR/.replacing" "$MODDIR/data/safe_mode" 2>/dev/null
echo 0 > "$MODDIR/boot_count" 2>/dev/null

{
	echo "=== $(date '+%F %T') boot_completed"
	echo "algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)"
	grep -E "^(enabled|aliases|deltas|saved_bytes|decode_failures):" \
		/sys/block/zram0/sddc_stat 2>/dev/null
	lsmod | grep -E '^zram' 2>/dev/null
} >> "$LOG" 2>/dev/null

tail -100 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
