# 复制本文件夹为 devices/<机型>-<uname_r段>/, 用户取证文件放入后填写 build.conf
# 命名规范: <机型代号>-<uname_r 关键段>, 如 RMX5010-6.6.89-android15-8

## 应放入的文件 (tools/recon.sh 自动产出, 用户回传解压)
# 00_summary.txt    uname.txt    proc_version.txt
# config.txt        kallsyms.txt page_size.txt
# model.txt brand.txt soc.txt android_ver.txt
# zram_disksize.txt zram_algo.txt swaps.txt
# boot.img (可选)
# modules_vendor_lib_modules/*.ko   <- 全部 vendor KO, 其中原厂 oplus_bsp_hybridswap_zram.ko 是 CRC 参照物
