#!/system/bin/sh
# 安装提示 —— 只做侧载，不带配置界面

ui_print "- LZ4KDS 侧载模块"
ui_print "- 算法: LZ4KD + SDDC（相同页共享 / 相似页只存差异）"
ui_print "- 来源: Crystal HybridSwap (SDDC) / HiSilicon (LZ4KD)"
ui_print "- 骨架: OPPO/realme oplus_bsp_hybridswap_zram"
ui_print "- 方式: KO 侧载，只改运行内存，不写任何分区"
ui_print "- 回退: KernelSU 禁用本模块后重启即还原原厂 zram"
ui_print "- 容量/算法请在系统侧调整，本模块不做干预"

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
