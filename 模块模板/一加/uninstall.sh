#!/system/bin/sh
# 卸载清理：删除 ksud 的 preinit 同步副本，避免卸载后仍尝试加载
rm -rf /metadata/vold/ksu/preinit/lz4kds_sidecar
