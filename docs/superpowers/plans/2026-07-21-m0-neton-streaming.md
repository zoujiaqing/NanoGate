# M0：Neton 框架流式前置 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 NewGate 中转站补齐 Neton 框架缺失的服务端流式响应（SSE）能力，并完成 client 代理支持、根路径挂载验证、长流压测基线与 neton-ai IR 审计。

**Architecture:** 在 `neton-core` 的 `HttpResponse` 接口上新增 `stream()` 流式写出抽象（默认缓冲实现保证所有适配器兼容），KtorHttpAdapter 用 `respondBytesWriter` 提供真流式实现；SSE 格式化做成独立 `SseWriter`（含 `raw()` 透传通道，供 M1 中转直通上游 SSE 字节）。

**Tech Stack:** Kotlin 2.3 Multiplatform（Kotlin/Native）、Ktor CIO、KSP、Gradle 8.14

**关联 spec:** `docs/superpowers/specs/2026-07-21-newgate-design.md` §4（M0 框架前置）

**与 spec 的偏差：** spec §4 第 4 点「可插拔 TokenGuard」不在本计划——`RouteDefinition.routeGroup` 已支持按组选择 authenticator/guard（`neton-core/src/commonMain/kotlin/neton/core/interfaces/RequestEngine.kt:50`），属于 M1 应用侧接线，无框架改动。

## Global Constraints

- 所有代码在 `/Users/zoujiaqing/projects/Neton/neton` 仓库（框架仓库），本计划文件所在 NewGate 仓库只存放文档
- 测试命令统一：`./gradlew :<module>:macosArm64Test`（在 neton 仓库根目录执行）
- 只能用 Kotlin Multiplatform commonMain 可用的 API，禁止 JVM-only 依赖
- 遵循仓库现有约定：中文 KDoc 注释、契约测试放 `src/commonTest`、公共 API 变更需补契约测试
- `HttpResponse.write()` 的「一次提交、isCommitted 置位、引擎跳过 envelope」语义（KtorHttpAdapter.kt:322-327）必须原样保持
- 每个任务完成即 commit（在 neton 仓库），message 前缀 `feat(http):` / `test(http):` / `docs:`

---

### Task 1: `HttpBodyWriter` 接口 + `HttpResponse.stream()` 默认缓冲实现

**Files:**
- Modify: `neton-core/src/commonMain/kotlin/neton/core/http/HttpResponse.kt`（在 `interface HttpResponse` 内、`suspend fun write` 之后新增）
- Test: `neton-core/src/commonTest/kotlin/neton/core/http/HttpResponseStreamContractTest.kt`（新建）

**Interfaces:**
- Consumes: 现有 `HttpResponse.write(data: ByteArray)`
- Produces: `interface HttpBodyWriter { suspend fun writeChunk(chunk: ByteArray); suspend fun writeChunk(text: String) }`；`suspend fun HttpResponse.stream(block: suspend HttpBodyWriter.() -> Unit)`（接口成员，带默认实现）。Task 2、3 依赖这两个签名。

- [ ] **Step 1: 写失败测试**

```kotlin
package neton.core.http

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

/** 契约：默认 stream() 把多次 writeChunk 缓冲为单次 write，块序保持。 */
class HttpResponseStreamContractTest {

    private class RecordingResponse : HttpResponse {
        override var status: HttpStatus = HttpStatus.OK
        override val headers: MutableHeaders = SimpleMutableHeaders()
        override val isCommitted: Boolean get() = writes.isNotEmpty()
        val writes = mutableListOf<ByteArray>()
        override fun cookie(cookie: Cookie) {}
        override suspend fun write(data: ByteArray) { writes.add(data) }
    }

    @Test
    fun defaultStreamBuffersChunksIntoSingleWrite() = kotlinx.coroutines.test.runTest {
        val response = RecordingResponse()
        response.stream {
            writeChunk("hello ".encodeToByteArray())
            writeChunk("world")
        }
        assertEquals(1, response.writes.size)
        assertContentEquals("hello world".encodeToByteArray(), response.writes[0])
    }

    @Test
    fun emptyStreamStillCommitsEmptyBody() = kotlinx.coroutines.test.runTest {
        val response = RecordingResponse()
        response.stream { }
        assertEquals(1, response.writes.size)
        assertEquals(0, response.writes[0].size)
    }
}
```

注意：`SimpleMutableHeaders` 若不存在，用仓库里 `MutableHeaders` 的现有实现类（grep `: MutableHeaders` 找到默认实现，替换类名）。`kotlinx.coroutines.test.runTest` 若 neton-core 测试依赖没有 coroutines-test，参考其他 commonTest 里 suspend 测试的写法（grep `runTest\|runBlocking` in neton-core/src/commonTest）并保持一致。

- [ ] **Step 2: 运行测试确认失败**

Run: `./gradlew :neton-core:macosArm64Test --tests "*HttpResponseStreamContractTest*"`
Expected: FAIL — `unresolved reference: stream` / `HttpBodyWriter`

- [ ] **Step 3: 最小实现**

在 `HttpResponse.kt` 顶层（`interface HttpResponse` 之前）加：

```kotlin
/**
 * 流式响应体写出器。由 [HttpResponse.stream] 提供，逐块写出响应体。
 * 适配器保证每次 writeChunk 后立即 flush（真流式适配器）或缓冲至结束（默认实现）。
 */
interface HttpBodyWriter {
    suspend fun writeChunk(chunk: ByteArray)
    suspend fun writeChunk(text: String) = writeChunk(text.encodeToByteArray())
}
```

在 `interface HttpResponse` 内部、`suspend fun write(data: ByteArray)` 声明之后加：

```kotlin
    /**
     * 流式写出响应体。默认实现缓冲全部块后单次 write()（兼容不支持流式的适配器）；
     * 支持真流式的适配器（如 Ktor）应覆写为逐块 flush。
     * 与 write() 相同：调用即视为提交响应，引擎不再用返回值包 envelope。
     */
    suspend fun stream(block: suspend HttpBodyWriter.() -> Unit) {
        val chunks = mutableListOf<ByteArray>()
        val writer = object : HttpBodyWriter {
            override suspend fun writeChunk(chunk: ByteArray) { chunks.add(chunk) }
        }
        writer.block()
        val total = ByteArray(chunks.sumOf { it.size })
        var pos = 0
        for (c in chunks) { c.copyInto(total, pos); pos += c.size }
        write(total)
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `./gradlew :neton-core:macosArm64Test --tests "*HttpResponseStreamContractTest*"`
Expected: PASS（2 tests）

- [ ] **Step 5: Commit**

```bash
cd /Users/zoujiaqing/projects/Neton/neton
git add neton-core/src
git commit -m "feat(core): HttpResponse.stream() 流式写出抽象与默认缓冲实现"
```

---

### Task 2: `SseWriter` — SSE 事件格式化与透传

**Files:**
- Create: `neton-core/src/commonMain/kotlin/neton/core/http/SseWriter.kt`
- Test: `neton-core/src/commonTest/kotlin/neton/core/http/SseWriterTest.kt`

**Interfaces:**
- Consumes: Task 1 的 `HttpBodyWriter`、`HttpResponse.stream()`
- Produces: `class SseWriter(out: HttpBodyWriter)`，方法 `suspend fun event(data: String, event: String? = null, id: String? = null)`、`suspend fun comment(text: String)`、`suspend fun raw(text: String)`；扩展 `suspend fun HttpResponse.sse(block: suspend SseWriter.() -> Unit)`。M1 中转的 SSE 直通走 `raw()`。

- [ ] **Step 1: 写失败测试**

```kotlin
package neton.core.http

import kotlin.test.Test
import kotlin.test.assertEquals

class SseWriterTest {

    private class Recorder : HttpBodyWriter {
        val sb = StringBuilder()
        override suspend fun writeChunk(chunk: ByteArray) { sb.append(chunk.decodeToString()) }
    }

    @Test
    fun formatsSimpleDataEvent() = kotlinx.coroutines.test.runTest {
        val rec = Recorder()
        SseWriter(rec).event(data = """{"x":1}""")
        assertEquals("data: {\"x\":1}\n\n", rec.sb.toString())
    }

    @Test
    fun formatsNamedEventWithIdAndMultilineData() = kotlinx.coroutines.test.runTest {
        val rec = Recorder()
        SseWriter(rec).event(data = "line1\nline2", event = "message_delta", id = "42")
        assertEquals("id: 42\nevent: message_delta\ndata: line1\ndata: line2\n\n", rec.sb.toString())
    }

    @Test
    fun commentIsKeepaliveFormat() = kotlinx.coroutines.test.runTest {
        val rec = Recorder()
        SseWriter(rec).comment("ping")
        assertEquals(": ping\n\n", rec.sb.toString())
    }

    @Test
    fun rawPassesBytesThroughUnchanged() = kotlinx.coroutines.test.runTest {
        val rec = Recorder()
        // 中转直通场景：上游已格式化的 SSE 块原样转发，不得二次加工
        SseWriter(rec).raw("data: [DONE]\n\n")
        assertEquals("data: [DONE]\n\n", rec.sb.toString())
    }
}
```

（`runTest` 依赖问题同 Task 1 Step 1 的说明。）

- [ ] **Step 2: 运行测试确认失败**

Run: `./gradlew :neton-core:macosArm64Test --tests "*SseWriterTest*"`
Expected: FAIL — `unresolved reference: SseWriter`

- [ ] **Step 3: 实现 SseWriter.kt**

```kotlin
package neton.core.http

/**
 * Server-Sent Events 写出器。
 * event()/comment() 负责按 SSE 规范格式化；raw() 原样透传（供网关直通上游 SSE 字节流）。
 */
class SseWriter(private val out: HttpBodyWriter) {

    suspend fun event(data: String, event: String? = null, id: String? = null) {
        val sb = StringBuilder()
        if (id != null) sb.append("id: ").append(id).append('\n')
        if (event != null) sb.append("event: ").append(event).append('\n')
        for (line in data.split('\n')) sb.append("data: ").append(line).append('\n')
        sb.append('\n')
        out.writeChunk(sb.toString())
    }

    /** SSE 注释行，用作 keepalive。 */
    suspend fun comment(text: String) = out.writeChunk(": $text\n\n")

    /** 原样透传已格式化的 SSE 文本块。 */
    suspend fun raw(text: String) = out.writeChunk(text)
}

/**
 * 以 SSE 形式流式响应。设置标准 SSE 头后进入流式写出。
 */
suspend fun HttpResponse.sse(block: suspend SseWriter.() -> Unit) {
    contentType = "text/event-stream; charset=utf-8"
    header("Cache-Control", "no-cache")
    header("X-Accel-Buffering", "no")
    stream { SseWriter(this).block() }
}
```

- [ ] **Step 4: 补一条 `HttpResponse.sse` 头设置断言到 SseWriterTest**

```kotlin
    @Test
    fun sseExtensionSetsHeadersAndStreams() = kotlinx.coroutines.test.runTest {
        val response = object : HttpResponse {
            override var status: HttpStatus = HttpStatus.OK
            override val headers: MutableHeaders = SimpleMutableHeaders()
            override val isCommitted: Boolean get() = body != null
            var body: ByteArray? = null
            override fun cookie(cookie: Cookie) {}
            override suspend fun write(data: ByteArray) { body = data }
        }
        response.sse { event(data = "hi") }
        assertEquals("text/event-stream; charset=utf-8", response.headers["Content-Type"])
        assertEquals("no-cache", response.headers["Cache-Control"])
        assertEquals("data: hi\n\n", response.body!!.decodeToString())
    }
```

- [ ] **Step 5: 运行测试确认全部通过**

Run: `./gradlew :neton-core:macosArm64Test --tests "*SseWriterTest*"`
Expected: PASS（5 tests）

- [ ] **Step 6: Commit**

```bash
git add neton-core/src
git commit -m "feat(core): SseWriter 与 HttpResponse.sse() 扩展"
```

---

### Task 3: KtorHttpAdapter 真流式实现

**Files:**
- Modify: `neton-http/src/commonMain/kotlin/neton/http/KtorHttpAdapter.kt`（`SimpleKtorHttpResponse`，约 809-850 行）

**Interfaces:**
- Consumes: Task 1 的 `HttpBodyWriter` / `stream()` 签名；Ktor `io.ktor.server.response.respondBytesWriter`、`io.ktor.utils.io.writeFully` / `flush`
- Produces: `SimpleKtorHttpResponse.stream()` 覆写 — 逐块 flush 的真流式；`isCommitted` 置位与 `lastBytesOut` 统计语义同 `write()`

- [ ] **Step 1: 阅读现有 `write()` 实现**

打开 `KtorHttpAdapter.kt:806-850`，确认三件事（后续代码要保持一致）：
1. `isCommitted` 通过哪个字段置位（类头注释「所有提交入口统一置 isCommitted」）
2. `write()` 在 respond 之前如何把 `headers` / cookie 应用到 `call.response`（有一段 header 应用代码，`stream()` 必须复用同一段逻辑——如果它是内联的，先抽成私有方法 `applyHeaders()`）
3. `lastBytesOut` 的累计方式

- [ ] **Step 2: 实现 stream() 覆写**

在 `SimpleKtorHttpResponse` 内加（`applyHeaders()` 为 Step 1 抽出的私有方法名，按实际命名调整；`committed` 为实际的提交字段名）：

```kotlin
    override suspend fun stream(block: suspend neton.core.http.HttpBodyWriter.() -> Unit) {
        committed = true
        applyHeaders()
        val ct = ContentType.parse(contentType ?: "application/octet-stream")
        var bytesOut = 0L
        call.respondBytesWriter(contentType = ct, status = HttpStatusCode.fromValue(status.code)) {
            val channel = this
            val writer = object : neton.core.http.HttpBodyWriter {
                override suspend fun writeChunk(chunk: ByteArray) {
                    channel.writeFully(chunk, 0, chunk.size)
                    channel.flush()
                    bytesOut += chunk.size
                }
            }
            writer.block()
        }
        lastBytesOut = bytesOut
    }
```

要点：
- `writeFully` + `flush` 每块立即出网，这是与默认缓冲实现的唯一行为差异
- 客户端断连时 Ktor 写通道抛出取消/IO 异常，**不得吞掉**——让它沿协程冒泡，`block` 内部（M1 的上游拉取 Flow）才能随之取消。`handleRoute` 的 catch 块会兜底；若断连异常被记成 500 错误日志噪音，在 `handleRoute` 的通用 catch 前加一个 `kotlinx.coroutines.CancellationException` 分支直接 rethrow
- import 需补 `io.ktor.server.response.respondBytesWriter`、`io.ktor.utils.io.*`

- [ ] **Step 3: 编译通过**

Run: `./gradlew :neton-http:compileKotlinMacosArm64`
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 跑全量 neton-http 测试防回归**

Run: `./gradlew :neton-http:macosArm64Test`
Expected: PASS（存量测试全绿；真流式行为的端到端验证在 Task 4）

- [ ] **Step 5: Commit**

```bash
git add neton-http/src
git commit -m "feat(http): KtorHttpAdapter 真流式响应（respondBytesWriter 逐块 flush）"
```

---

### Task 4: sse-demo 示例 + 端到端流式验证

**Files:**
- Create: `examples/sse-demo/build.gradle.kts`（复制 `examples/helloworld/build.gradle.kts`，仅改项目名）
- Create: `examples/sse-demo/src/commonMain/kotlin/Main.kt`
- Modify: `examples/settings.gradle.kts`（include `:sse-demo`，照抄 helloworld 的 include 写法）

**Interfaces:**
- Consumes: Task 2 的 `HttpResponse.sse`、routing DSL `get(path) { ctx -> }`（`neton-routing/src/commonMain/kotlin/neton/routing/RoutingDsl.kt:26`）
- Produces: 可运行的 SSE 演示服务，供 Task 6 压测复用；端点 `GET /stream?count=N&delayMs=M`

- [ ] **Step 1: 写 Main.kt**

```kotlin
import kotlinx.coroutines.delay
import neton.core.Neton
import neton.core.http.sse
import neton.http.http
import neton.routing.*

fun main(args: Array<String>) {
    Neton.run(args) {
        http { port = 8080 }
        routing {
            get("/stream") { ctx ->
                val count = ctx.queryParams["count"]?.toIntOrNull() ?: 5
                val delayMs = ctx.queryParams["delayMs"]?.toLongOrNull() ?: 200L
                ctx.response.sse {
                    repeat(count) { i ->
                        event(data = """{"seq":$i,"ts":${kotlin.time.Clock.System.now().toEpochMilliseconds()}}""")
                        delay(delayMs)
                    }
                    event(data = "[DONE]")
                }
                null
            }
        }
    }
}
```

（`ctx.queryParams` 的实际访问方式以 `HttpContext` 定义为准——RoutingDsl.kt:21 注释确认它暴露 queryParams；若 API 是方法形式按实际调整。`kotlin.time.Clock` 用法与 KtorHttpAdapter.kt:312 一致。）

- [ ] **Step 2: 编译并启动**

```bash
cd /Users/zoujiaqing/projects/Neton/neton/examples
../gradlew :sse-demo:linkDebugExecutableMacosArm64
./sse-demo/build/bin/macosArm64/debugExecutable/sse-demo.kexe &
```

Expected: 启动 banner，`Ready → http://localhost:8080`

- [ ] **Step 3: 验证真流式（关键验收）**

```bash
curl -sN "http://localhost:8080/stream?count=5&delayMs=500" | while IFS= read -r line; do echo "$(date +%s.%N) $line"; done
```

Expected:
- 每条 `data: {"seq":i,...}` 行的本地时间戳**间隔约 0.5s 逐条到达**（证明逐块 flush，而非 2.5s 后一次性到达——那是缓冲实现的表现，算失败）
- 响应头含 `content-type: text/event-stream`（`curl -sI` 或 `-v` 确认）
- 响应体是裸 SSE，**没有** ApiEnvelope JSON 包装（envelope 绕过验证）

- [ ] **Step 4: 验证客户端断连取消**

```bash
curl -sN "http://localhost:8080/stream?count=1000&delayMs=100" | head -3
```

Expected: curl 提前退出后，服务进程不崩溃、无 ERROR 级日志刷屏（允许一条断连 WARN/INFO）；再次 curl 正常服务。若出现 500 error 日志，回到 Task 3 Step 2 的 CancellationException rethrow 要点修复。

- [ ] **Step 5: 停止服务并 Commit**

```bash
kill %1
cd /Users/zoujiaqing/projects/Neton/neton
git add examples
git commit -m "feat(examples): sse-demo 流式响应端到端示例"
```

---

### Task 5: NetonHttpClient 渠道级 HTTP 代理支持

**Files:**
- Modify: `neton-http/src/commonMain/kotlin/neton/http/client/internal/DefaultNetonHttpClient.kt`
- Modify: `neton-http/src/commonMain/kotlin/neton/http/client/NetonHttpClient.kt`（公开工厂函数处，grep `fun NetonHttpClient(` 定位）
- Test: `neton-http/src/commonTest/kotlin/neton/http/client/NetonHttpClientProxyTest.kt`（新建）

**Interfaces:**
- Consumes: 现有 `NetonHttpClient` 工厂、`DefaultNetonHttpClient(engineFactory, ...)` 构造
- Produces: 工厂新增参数 `proxyUrl: String? = null`（形如 `http://host:port`）。M1 渠道配置的 `proxy` 字段将为每个配代理的渠道建独立 client 实例（Ktor 代理是 client 级配置，非请求级）。

- [ ] **Step 1: 写失败测试**

```kotlin
package neton.http.client

import kotlin.test.Test
import kotlin.test.assertFailsWith

class NetonHttpClientProxyTest {

    @Test
    fun factoryAcceptsProxyUrl() {
        // 仅验证构造路径：非法代理地址应在构造或首次请求时报错，而不是被静默忽略
        NetonHttpClient(proxyUrl = "http://127.0.0.1:1")
    }

    @Test
    fun malformedProxyUrlFailsFast() {
        assertFailsWith<IllegalArgumentException> {
            NetonHttpClient(proxyUrl = "not-a-url")
        }
    }
}
```

（工厂函数实际签名如带其他必填参数，按现状补默认值；测试意图不变。）

- [ ] **Step 2: 运行测试确认失败**

Run: `./gradlew :neton-http:macosArm64Test --tests "*NetonHttpClientProxyTest*"`
Expected: FAIL — `no value passed for parameter` / `unresolved reference: proxyUrl`

- [ ] **Step 3: 实现**

`DefaultNetonHttpClient` 构造加 `proxyUrl: String? = null`，在 `HttpClient(engineFactory) { ... }` 配置块内加：

```kotlin
        if (proxyUrl != null) {
            require(proxyUrl.startsWith("http://") || proxyUrl.startsWith("https://")) {
                "proxyUrl must be an http(s) URL: $proxyUrl"
            }
            engine {
                proxy = io.ktor.client.engine.ProxyBuilder.http(io.ktor.http.Url(proxyUrl))
            }
        }
```

公开工厂函数透传该参数。

- [ ] **Step 4: 运行测试确认通过 + 全量回归**

Run: `./gradlew :neton-http:macosArm64Test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add neton-http/src
git commit -m "feat(http-client): 客户端级 HTTP 代理支持（渠道代理前置）"
```

---

### Task 6: 长流并发压测脚本与基线报告

**Files:**
- Create: `scripts/sse-load-test.sh`（neton 仓库）
- Create: `docs/reports/2026-07-sse-load-baseline.md`（neton 仓库，运行后填实测数据）

**Interfaces:**
- Consumes: Task 4 的 sse-demo（release 构建）
- Produces: 压测脚本（可重复执行）+ 基线报告（spec §11 要求的 M0 产出）

- [ ] **Step 1: 写压测脚本**

```bash
#!/usr/bin/env bash
# SSE 长流并发压测：N 路并发 curl 消费长流，采样服务进程 RSS。
# 用法: ./scripts/sse-load-test.sh [并发数=200] [每流事件数=300] [事件间隔ms=100]
set -euo pipefail
CONC="${1:-200}"; COUNT="${2:-300}"; DELAY="${3:-100}"
BIN="examples/sse-demo/build/bin/macosArm64/releaseExecutable/sse-demo.kexe"

[ -x "$BIN" ] || { echo "先构建: ./gradlew -p examples :sse-demo:linkReleaseExecutableMacosArm64"; exit 1; }

"$BIN" & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

echo "server pid=$SRV conc=$CONC count=$COUNT delayMs=$DELAY"
( while kill -0 $SRV 2>/dev/null; do
    echo "$(date +%T) RSS_KB=$(ps -o rss= -p $SRV | tr -d ' ')"
    sleep 2
  done ) & MON=$!

START=$(date +%s)
seq 1 "$CONC" | xargs -P "$CONC" -I{} \
  curl -sN --max-time 300 "http://localhost:8080/stream?count=$COUNT&delayMs=$DELAY" -o /dev/null \
  && echo "ALL_STREAMS_OK elapsed=$(( $(date +%s) - START ))s" \
  || echo "SOME_STREAMS_FAILED"
kill $MON 2>/dev/null || true
kill -0 $SRV && echo "SERVER_ALIVE" || echo "SERVER_CRASHED"
```

- [ ] **Step 2: 运行三档压测**

```bash
cd /Users/zoujiaqing/projects/Neton/neton
./gradlew -p examples :sse-demo:linkReleaseExecutableMacosArm64
chmod +x scripts/sse-load-test.sh
./scripts/sse-load-test.sh 100 300 100 | tee /tmp/sse-100.log
./scripts/sse-load-test.sh 200 300 100 | tee /tmp/sse-200.log
./scripts/sse-load-test.sh 500 300 100 | tee /tmp/sse-500.log
```

Expected: 三档均输出 `ALL_STREAMS_OK` 与 `SERVER_ALIVE`；RSS 曲线平稳（结束后回落，无持续攀升 = 无泄漏迹象）。500 档若失败，记录实际上限并写入报告（这是基线，不是门禁）。

- [ ] **Step 3: 写基线报告**

`docs/reports/2026-07-sse-load-baseline.md` 结构：环境（机器/OS/构建类型）、三档结果表（并发、成功率、总耗时、RSS 峰值/结束值）、观察到的异常与结论（是否满足 spec §11「500 并发长流」基线；不满足则记录瓶颈初判与 M1 前是否需要处理）。数据必须来自 Step 2 实测输出，禁止估算。

- [ ] **Step 4: Commit**

```bash
git add scripts/sse-load-test.sh docs/reports/2026-07-sse-load-baseline.md
git commit -m "test(http): SSE 长流并发压测脚本与 K/N 基线报告"
```

---

### Task 7: 根路径挂载契约测试（gateway 路由组前置）

**Files:**
- Test: `neton-routing/src/commonTest/kotlin/neton/routing/RootMountContractTest.kt`（新建）
- Modify（仅当测试暴露缺陷时）: `neton-routing/src/commonMain/kotlin/neton/routing/RoutingExtensions.kt`（组挂载拼接处，参考 :54-55、:88-94 及 RequestEngineImpl 的按组挂载逻辑）

**Interfaces:**
- Consumes: `RouteGroup` / `RouteMountConfig(RouteMountType.PATH, "/")`（`neton-routing/src/commonMain/kotlin/neton/routing/RoutingModule.kt:36`）
- Produces: 锁定契约——`mount = "/"` 的组，路由 `/v1/models` 最终 pattern 为 `/v1/models`（无 `//` 前缀、不与其它组前缀冲突）。M1 的 gateway 组依赖此契约。

- [ ] **Step 1: 写契约测试**

先读 RoutingExtensions.kt 组挂载拼接的实际函数（mount 值与 route pattern 的 join 点），测试直接调用该拼接路径（或经 RequestEngine 注册组路由后 `getRoutes()` 断言）：

```kotlin
package neton.routing

import kotlin.test.Test
import kotlin.test.assertEquals

/** 契约：mount="/" 的路由组挂载后 pattern 不产生双斜杠、不丢路径。gateway 组（NewGate）依赖此行为。 */
class RootMountContractTest {

    @Test
    fun rootMountJoinsWithoutDoubleSlash() {
        // 以 RoutingExtensions 实际的拼接函数为准调用；期望值固定：
        // join("/", "/v1/models")        == "/v1/models"
        // join("/admin", "/user/list")   == "/admin/user/list"
        // join("/", "/")                 == "/"
    }
}
```

（Step 1 的空测试体是骨架；读完拼接函数后立即填入对它的真实调用与上述三条断言——三个期望值就是契约本身，不可更改。）

- [ ] **Step 2: 运行测试**

Run: `./gradlew :neton-routing:macosArm64Test --tests "*RootMountContractTest*"`
两种结果都接受：PASS → 契约已满足，直接 Step 4；FAIL（出现 `//v1/models` 之类）→ Step 3 修复。

- [ ] **Step 3: 修复拼接（仅在 Step 2 FAIL 时）**

在拼接处做归一化：

```kotlin
internal fun joinMountPath(mount: String, pattern: String): String =
    if (mount == "/" || mount.isEmpty()) pattern
    else mount.trimEnd('/') + pattern
```

用该函数替换原字符串拼接，重跑测试至 PASS。

- [ ] **Step 4: 全量回归 + Commit**

Run: `./gradlew :neton-routing:macosArm64Test`
Expected: PASS

```bash
git add neton-routing/src
git commit -m "test(routing): 根路径挂载契约（gateway 组前置）"
```

---

### Task 8: neton-ai IR 保真度审计报告

**Files:**
- Create: `docs/superpowers/specs/2026-07-m0-neton-ai-ir-audit.md`（NewGate 仓库）
- Read: `neton/neton-ai/src/commonMain/kotlin/neton/ai/`（AiMessage.kt、AiContent.kt、AiStreamEvent.kt、AiUsage.kt、AiToolCall.kt、AiFinishReason.kt、config/AnthropicSpec.kt、config/OpenAiCompatibleSpec.kt）

**Interfaces:**
- Consumes: neton-ai 现有 IR 类型
- Produces: 审计报告——M2 跨协议转换开工前的 IR 扩展工单清单（spec §4 第 3 点的交付物）

- [ ] **Step 1: 逐项核对三协议字段覆盖**

对下列每一项，在报告中记录：IR 现状（支持/部分/缺失）、涉及的 IR 类型、缺失时的扩展建议。核对清单（不可删项，可增项）：

1. 多模态内容块：image（url/base64）、audio、document/PDF（Claude）、video（Gemini）
2. 思维链：Claude thinking/redacted_thinking 块、OpenAI reasoning_content/reasoning_effort、Gemini thought
3. 提示缓存：Claude cache_control（ephemeral）、usage 中 cache_read/cache_creation tokens、OpenAI prompt_tokens_details.cached_tokens
4. 工具调用：并行 tool_calls、tool_choice 全部取值（auto/none/required/具体函数）、Claude tool_use/tool_result 块、流式工具参数增量（OpenAI delta.tool_calls[].function.arguments ↔ Claude input_json_delta）
5. 流式事件序列完备性：Claude message_start/content_block_start/delta/stop/message_delta/message_stop ↔ OpenAI chunk（含 finish_reason、usage 尾包）↔ Gemini streamGenerateContent 分片
6. finish/stop 原因映射表：stop/length/tool_calls/content_filter ↔ end_turn/max_tokens/tool_use/refusal ↔ STOP/MAX_TOKENS/SAFETY
7. 采样参数：temperature/top_p/top_k/frequency_penalty/presence_penalty/stop sequences/seed/logprobs/max_tokens 语义差异（Claude max_tokens 必填等）
8. usage 字段全集：输入/输出/缓存读写/推理 tokens（reasoning_tokens）
9. 结构化输出：response_format json_schema ↔ Gemini responseSchema ↔ Claude 无原生（需注入策略标注）
10. 未知字段处理策略：IR 是否有 extensions/passthrough 通道（决策 A 的跨协议路径也应尽量保留可透传的厂商专有字段）

- [ ] **Step 2: 产出扩展工单清单**

报告末尾输出「M2 前必须完成的 IR 扩展」编号列表，每条含：改动文件、新增字段/类型草案、破坏性评估（neton-ai 是已发布 API，评估加字段是否兼容）。

- [ ] **Step 3: Commit（NewGate 仓库）**

```bash
cd /Users/zoujiaqing/projects/NewGate
git add docs/superpowers/specs/2026-07-m0-neton-ai-ir-audit.md
git commit -m "docs: neton-ai IR 保真度审计（M2 跨协议转换前置）"
```

---

## Self-Review 记录

- **Spec 覆盖**：spec §4 M0 四项 → 服务端流式 = Task 1-4；client 校验/代理/压测 = Task 5-6（multipart 缓冲上限属 M1 网关业务，移入 M1 计划）；IR 审计 = Task 8；gateway 路由组 = Task 7（TokenGuard 接线移 M1，理由见头部偏差说明）
- **占位符**：Task 7 Step 1 测试体为「读代码后立即填入」的骨架，但三条契约断言值已完整给出，不属于 TBD；其余任务代码完整
- **类型一致性**：`HttpBodyWriter.writeChunk` / `HttpResponse.stream` / `SseWriter.event|comment|raw` / `sse()` 在 Task 1/2/3/4 间签名一致；`proxyUrl: String?` 在 Task 5 内自洽
