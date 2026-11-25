# SPDX-License-Identifier: GPL-2.0
#
# Crystal HybridSwap zram 驱动 —— out-of-tree 可编译版
#
# 两种用法：
#   1) 树内（放到 <kernel>/drivers/block/zram/）
#      make ARCH=arm64 LLVM=1 modules
#
#   2) 树外（本工作区推荐方式）
#      make -C <kernel> M=<此目录> ARCH=arm64 LLVM=1 modules
#
# 树外编译时 Kconfig 不会被求值，因此这里用 ccflags 直接注入功能开关，
# 保证 SDDC 与 LZ4KD 默认启用（等价于 CONFIG_CRYSTAL_HYBRIDSWAP_SDDC=y）。

# ── 强制启用的功能（树外编译必需）──
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_WRITEBACK=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_TRACK_ENTRY_ACTIME=1

# 可选功能（需要时手动打开）
# ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_MULTI_COMP=1
# ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_LEGACY_EMPTY_APIS=1
# ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC_KUNIT_TEST=1

# ── 头文件搜索路径 ──
# 让 sddc/ 与 sddc/lz4kd/ 下的源码能用相对路径 include
ccflags-y += -I$(src)
ccflags-y += -I$(src)/sddc
ccflags-y += -I$(src)/sddc/lz4kd
# include/linux/crystal_hybridswap.h —— 树外编译需显式指到本地副本
ccflags-y += -I$(src)/include

# ── 产物 ──
obj-m += zram.o

zram-y := \
	zcomp.o \
	zms.o \
	zram_drv.o \
	core.o \
	param.o \
	zram_bridge.o \
	memcg.o \
	pressure.o \
	stats.o

# SDDC 本体
zram-y += sddc/crystal_sddc.o

# SDDC codec + LZ4KD 编解码
zram-y += \
	sddc/crystal_sddc_codec.o \
	sddc/lz4kd/lz4kd_encode.o \
	sddc/lz4kd/lz4kd_encode_delta.o \
	sddc/lz4kd/lz4kd_decode.o

# NEON 加速：lz4kd_encode.c 会调用 crystal_lz4kd_repeat_end_neon()，
# 不编会 undefined。仅 arm64 启用。
# 同时移除 -mgeneral-regs-only 并允许 NEON intrinsics，
# 避免 kmap_atomic 路径与渲染中断产生 FPSIMD 冲突死锁。
ifeq ($(ARCH),arm64)
zram-y += sddc/lz4kd/lz4kd_neon.o
CFLAGS_REMOVE_sddc/lz4kd/lz4kd_neon.o += -mgeneral-regs-only
CFLAGS_sddc/lz4kd/lz4kd_neon.o += -ffreestanding -isystem $(shell $(CC) -print-file-name=include)
endif

# KUnit 测试（默认不编）
# zram-y += sddc/crystal_sddc_codec_test.o
