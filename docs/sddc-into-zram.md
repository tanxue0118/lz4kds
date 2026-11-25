# SDDC 与 zram 的集成接点

构建、实现顺序及验收统一见[从 AOSP ACK 自建带 SDDC 的 zram](build-own-zram.md)。本页保留 Crystal 代码里值得参考的接点，便于对照 ACK 改写。

| 接点 | 可借鉴的行为 |
|---|---|
| `zcomp.c` / `zcomp.h` | 普通算法使用 Crypto API 后端，`lz4kd` 和 `lz4kds` 用私有后端。后者额外实现带参考流的 delta 编解码。houji 在编码源码中关闭内核态 NEON，scalar 路径具备完整编解码能力。 |
| `disksize_store()` / `crystal_sddc_create()` | 在压缩流就绪后创建 manager。4 KiB 页、slot 数在支持范围内、主算法支持 delta 时才会尝试启用。 |
| 写入与观察 | slot 锁内记录身份，异步观察。转换提交前再次检查代际、handle、大小和算法。 |
| 读回与释放 | 读回时 pin 不可变引用，释放路径对 `REF`、`ALIAS`、`DELTA` 各自持有的引用配对释放。`DELTA` 还拥有独立的 delta 对象。 |
| reset 与移除 | `stop` 先关闭接收并排空任务，随后获取 `init_lock` 写锁，释放 slot 并销毁 manager，最后销毁池。持有索引锁的候选探测仅尝试获取 slot 锁。 |
| 统计与测试 | `sddc_stat` 的 `enabled` 代表 manager 已运行。`deltas` 是当前存量，`released_deltas` 是累计释放。用 KUnit 加运行时逐字节读回覆盖正常、竞态和损坏数据路径。 |

Crystal 的 `zram_drv.c`、ZMS、memcg 和私有接口属于参考实现。ACK 的实际接点从目标分支的标准 zram 源码定位。需要了解参考实现的写回时，区分可选的 native ZMS 和还原成普通流的两条路径。

参考：[houji 压缩后端](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/blob/9b223f005da12d39167515c37828395f412e31f9/drivers/crystal_hybridswap/zcomp.c) · [houji SDDC 设计和 KUnit](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/tree/9b223f005da12d39167515c37828395f412e31f9/drivers/crystal_hybridswap/sddc)
