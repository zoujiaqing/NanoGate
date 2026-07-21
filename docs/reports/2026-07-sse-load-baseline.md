# SSE 长流并发压测基线（Kotlin/Native + Ktor CIO）

日期：2026-07-22
目的：NewGate M0 验收——验证 Neton 服务端流式响应在高并发长连接下的稳定性（spec §11）。

## 环境

| 项 | 值 |
|----|----|
| 机器 | Apple M1 Pro，macOS 26.2 |
| 构建 | sse-demo release（`linkReleaseExecutableMacosArm64`） |
| 场景 | 每流 300 个 SSE 事件、事件间隔 100ms（每流时长 ~30s） |
| 工具 | `scripts/sse-load-test.sh`（并发 curl + RSS 采样，2s 间隔） |

## 结果

| 并发流 | 结果 | 总耗时（理论下限 30s） | RSS 峰值 | 服务状态 |
|--------|------|------------------------|----------|----------|
| 100 | 全部成功 | 31s | 64 MB | 存活，无 WARN/ERROR |
| 200 | 全部成功 | 32s | 70 MB | 存活，无 WARN/ERROR |
| 500 | 全部成功 | 34s | 127 MB | 存活，无 WARN/ERROR |

## 观察与结论

- **满足 spec §11「500 并发长流」基线**：500 路并发下每流仅比理论时长多 ~4s（调度/握手开销），无失败流、无错误日志、进程存活。
- 内存随并发近似线性（~0.25MB/流），压测结束后进程未见持续攀升（无泄漏迹象）。
- 逐块 flush 语义已由 examples/sse-demo 的时间戳验证确认（事件按 delayMs 间隔逐条到达客户端）。
- 客户端中途断连按 `http.stream.aborted` WARN 收尾，不产生 500 ERROR 噪音，服务不受影响。
- 本基线为单机 loopback 场景，未含 TLS 与真实网络抖动；M1 网关联调时在真实上游下复测 TTFB。
