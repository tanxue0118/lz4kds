# Crystal HybridSwap 参考记录

自建 zram 的构建与移植说明见[从 AOSP ACK 自建带 SDDC 的 zram](build-own-zram.md)。Crystal 在这些公开实现里提供完整的 zram 替代驱动，其中值得借鉴的是 SDDC 的引用所有权、异步观察、回读校验及并发退出流程。具体接点见[SDDC 与 zram 的集成接点](sddc-into-zram.md)。

- **源码参考。** `Wcoom/oneplus_sm8750_kernel` 是 `whitewhale0612/android_kernel_common_oneplus_sm8750-C16` 的 fork。其 Crystal 目录是可核对的代码快照，作者与贡献按提交和文件版权确认。houji 的 6.1 移植补充了可读的设计文档与 KUnit 用例。 [Wcoom 源码快照](https://github.com/Wcoom/oneplus_sm8750_kernel/tree/13d291aef3d1d9607ad3fa5ff30dc23b2888a3da/drivers/crystalfrostwork/crystal_hybridswap) · [houji 设计与测试](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/tree/9b223f005da12d39167515c37828395f412e31f9/drivers/crystal_hybridswap/sddc)
- **已知读回问题。** OnePlus 13T 分支的 README 报告 `LZ4KDS` 可能读回错误页或零页。这个报告可转化为读回回归测试。实际原因和其他版本的影响范围需要各自复现。 [OnePlus 13T README](https://github.com/whitewhale0612/android_kernel_common_oneplus_sm8750-C16/blob/6.6.118-13T/README.md#压缩与写回测试)
- **设备集成。** 工作区现有厂商流水线仍使用各自的驱动和模板。直接采用 ACK 自建驱动时，应使用 ACK 构建与验证流程，并按目标内核重新评估模块兼容性。 [ACK 自建指南](build-own-zram.md)
