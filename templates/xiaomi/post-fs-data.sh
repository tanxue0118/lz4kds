#!/system/bin/sh
# 小米/标准 zram.ko 替换路线 —— post-fs-data 热替换（参考 dali Crystal 的安全设计）
#
# 安全层（按顺序）:
#   1. disable 标记检查
#   2. safe_mode：上次开机 panic/watchdog 则跳过（需手动删除标记重试）
#   3. boot_count 熔断：连续 3 次未到 boot_completed 自动禁用
#   4. KO sha256 完整性
#   5. 空闲四重检查：disksize=0 / initstate=0 / 不在 swaps / 无 holders
#   6. 依赖加载：zsmalloc 未载则加载随包 stock 副本
#   7. 失败回滚：insmod 失败立刻还原原厂 zram.ko
#
# 本模块只侧载算法，不配置容量；原厂 KO 随包（stock/），回滚永不依赖系统状态

MODDIR=${0%/*}
LOG=$MODDIR/load.log
STOCK=$MODDIR/stock/zram.ko
STOCK_ZSM=$MODDIR/stock/zsmalloc.ko
OURS=$MODDIR/zram.ko

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ── 0. 日志轮转 ──
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && \
	mv -f "$LOG" "$LOG.old" 2>/dev/null

log "=== post-fs-data $(date '+%F %T') ==="

# ── 1. disable 标记 ──
if [ -f "$MODDIR/disable" ]; then
	log "module disabled; 原厂 zram 保持原样"
	exit 0
fi

# ── 2. safe_mode：上次开机崩溃则不碰 zram ──
if [ -f "$MODDIR/data/safe_mode" ]; then
	log "safe_mode 存在; 本次跳过加载（删除 data/safe_mode 并重启可重试）"
	exit 0
fi
BOOTREASON=$(getprop ro.boot.bootreason 2>/dev/null)
case "$BOOTREASON" in
	*kernel_panic*|*watchdog*|*hard_reset*|*panic*|*oops*)
		log "上次开机原因 [$BOOTREASON] 疑似崩溃 → 写入 safe_mode 跳过"
		mkdir -p "$MODDIR/data" 2>/dev/null
		touch "$MODDIR/data/safe_mode" 2>/dev/null
		exit 0
		;;
esac

# ── 3. boot_count 熔断 ──
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
CNT_F=$MODDIR/boot_count
BID_F=$MODDIR/boot_count_bid
LAST_BID=$(cat "$BID_F" 2>/dev/null)
CNT=$(cat "$CNT_F" 2>/dev/null || echo 0)
case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac

if [ "$LAST_BID" != "$BID" ]; then
	if [ -f "$MODDIR/.replacing" ]; then
		CNT=$((CNT + 1))
		log "上次替换后未到 boot_completed，累计失败 $CNT 次"
	else
		CNT=0
	fi
	echo "$BID" > "$BID_F" 2>/dev/null
	echo "$CNT" > "$CNT_F" 2>/dev/null
fi
if [ "$CNT" -ge 3 ]; then
	log "熔断: 连续 $CNT 次失败，自动禁用本模块"
	touch "$MODDIR/disable" 2>/dev/null
	exit 0
fi

# ── 4. 设备/内核门禁（安装时已查，此处再防用户跨设备换包）──
MODEL=$(getprop ro.product.device 2>/dev/null | tr -d ' ')
EXPECT_MODEL=$(cat "$MODDIR/.target_device" 2>/dev/null | tr -d ' ')
if [ -n "$EXPECT_MODEL" ] && [ "$MODEL" != "$EXPECT_MODEL" ]; then
	log "设备不匹配: expect=$EXPECT_MODEL got=$MODEL，跳过"
	exit 0
fi

# ── 5. KO 完整性（sha256）──
[ -f "$OURS" ] || { log "FATAL: zram.ko 缺失"; exit 0; }
[ -f "$STOCK" ] || { log "FATAL: stock/zram.ko 缺失，无法保证回滚"; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then
	WANT=$(cat "$MODDIR/zram.ko.sha256" 2>/dev/null | awk '{print $1}')
	GOT=$(sha256sum "$OURS" 2>/dev/null | awk '{print $1}')
	if [ -n "$WANT" ] && [ "$WANT" != "$GOT" ]; then
		log "KO sha256 不匹配: expect=$WANT got=$GOT，拒绝加载"
		exit 0
	fi
	log "KO sha256 校验通过"
fi

# ── 6. 空闲四重检查 ──
i=0
while [ ! -e /sys/block/zram0 ] && [ "$i" -lt 10 ]; do
	sleep 1; i=$((i + 1))
done
[ -e /sys/block/zram0 ] || { log "zram0 未出现（vendor zram 未加载），跳过"; exit 0; }

DS=$(timeout 2 cat /sys/block/zram0/disksize 2>/dev/null)
INIT=$(cat /sys/block/zram0/initstate 2>/dev/null)
log "原厂状态: disksize=$DS initstate=$INIT"
if [ "$DS" != "0" ] || [ "$INIT" != "0" ]; then
	log "原厂 zram0 已初始化，拒绝热替换"; exit 0
fi
if grep -q 'zram' /proc/swaps 2>/dev/null; then
	log "zram 已在 swaps 中，拒绝热替换"; exit 0
fi
HOLDERS=$(ls /sys/block/zram0/holders 2>/dev/null)
if [ -n "$HOLDERS" ]; then
	log "zram0 有 holders: $HOLDERS，拒绝热替换"; exit 0
fi
if ! grep -q '^zram ' /proc/modules 2>/dev/null; then
	log "原厂 zram 模块未加载，跳过"; exit 0
fi

# ── 7. 内存充足性 ──
MEMFREE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
[ -n "$MEMFREE" ] && [ "$MEMFREE" -lt 800 ] && { log "可用内存仅 ${MEMFREE}MB，跳过"; exit 0; }

# ── 8. 执行替换 ──
echo "$BID" > "$MODDIR/.replacing" 2>/dev/null
log "=== 开始热替换 ==="

# 8.1 依赖：zsmalloc 未载则用随包 stock 副本
if ! grep -q '^zsmalloc ' /proc/modules 2>/dev/null; then
	if [ -f "$STOCK_ZSM" ]; then
		log "加载 stock zsmalloc"
		insmod "$STOCK_ZSM" 2>>"$LOG" || { log "zsmalloc 加载失败，放弃"; rm -f "$MODDIR/.replacing"; exit 0; }
	else
		log "无 stock zsmalloc 且内核未载 zsmalloc，放弃（避免符号缺失）"
		rm -f "$MODDIR/.replacing"; exit 0
	fi
fi

# 8.2 卸载原厂
log "卸载原厂 zram"
if ! rmmod zram 2>>"$LOG"; then
	log "rmmod 失败，放弃"
	rm -f "$MODDIR/.replacing"; exit 0
fi

# 8.3 加载自编版
log "加载自编 zram.ko"
if insmod "$OURS" 2>>"$LOG"; then
	log "insmod 成功"
else
	RC=$?
	log "insmod 失败 rc=$RC，还原原厂"
	grep -q '^zram ' /proc/modules 2>/dev/null && rmmod zram 2>>"$LOG"
	insmod "$STOCK" 2>>"$LOG" && log "原厂还原 OK" || log "原厂还原失败（重启后系统自行加载）"
	rm -f "$MODDIR/.replacing"
	exit 0
fi

# 8.4 验证设备节点 + 指定算法
sleep 1
if [ ! -e /sys/block/zram0 ]; then
	log "zram0 未出现，回滚"
	rmmod zram 2>>"$LOG"
	insmod "$STOCK" 2>>"$LOG"
	rm -f "$MODDIR/.replacing"; exit 0
fi
if [ -w /sys/block/zram0/comp_algorithm ]; then
	echo lz4kds > /sys/block/zram0/comp_algorithm 2>>"$LOG" \
		&& log "算法已选: lz4kds" \
		|| log "WARN: 算法写入失败（内核可能不支持），继续观察"
fi

log "zram0 就绪 算法=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
log "=== 替换完成 ==="
