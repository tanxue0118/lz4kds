#!/system/bin/sh
# 卸载清理：删状态文件；stock KO 留在包里随模块一起被 KSU 删除
MODDIR=${0%/*}
rm -f "$MODDIR/boot_count" "$MODDIR/boot_count_bid" "$MODDIR/.replacing" 2>/dev/null
rm -rf "$MODDIR/data" 2>/dev/null
