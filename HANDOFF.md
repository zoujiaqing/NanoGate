# NanoGate 项目交接（曾用名 NewGate）

> **2026-09-02 改名**：产品更名 NewGate → **NanoGate**。根仓 GitHub 已改名为 `zoujiaqing/nanogate`；
> 代码仓规划为 `nanogate-backend` / `nanogate-frontend` / `nanogate-client`。
> **本地目录（`NewGate/`、`newgate/` 等）、`NEWGATE_*` 环境变量、隔离库名暂不改**：
> `harness/run.sh` 依赖 `$ROOT/newgate` 路径，环境变量是后端配置契约，动了会破 37 断言基线。
> 下文路径里的 NewGate/newgate 均为本地目录名，非产品名。

> 最后核实：2026-09-02。本文以代码与 `harness/` 实测为准；与代码冲突的历史文档（尤其
> `SPEC.md` 末尾的「待办」段落）已过时，见第五节。

## 一、这是什么

对标 [new-api](https://github.com/QuantumNous/new-api) 的**开源 LLM API 中转站（产品名 NanoGate）**，用
Kotlin/Native + Neton 框架重写（new-api 是 Go，难维护）。核心能力：任意入站协议 → 任意上游
协议的 3×3 转发（OpenAI / Anthropic / Gemini），带计费、额度、渠道容错。

## 二、目录与仓库

工作区在 `~/projects/`，分两棵树：

### `Neton/` — 框架与**通用**模块（canonical 源）

| 目录 | 说明 | 远端 |
|---|---|---|
| `neton` | Kotlin/Native Web 框架本体（186 commits） | `netonframework/neton` |
| `neton-application` | 后端应用底座 | `neton-application/neton-application` |
| `neton-application-front` | 管理台前端底座 | 同组织 |
| `neton-application-client` | **C 端控制台底座** | 同组织 |
| `neton-application-module-{member,payment,platform}` | 通用后端模块 | 同组织 |
| `neton-application-module-gateway` | **网关后端（NewGate 核心，49 commits）** | 同组织 |
| `neton-application-front-gateway` | 网关管理台页面 | 同组织 |
| `neton-application-client-{gateway,member,payment}` | C 端模块（gateway=产品，后两个=通用） | 同组织 |

⚠️ 2026-09-01 已全部推送完毕（含此前领先的框架重构与适配提交）。
另：`module-system` 的短信宝（smsbao）SMS 实现于 2026-09-01 接手时才首次提交（此前是未提交
WIP，从未入过基线），未经过完整评审，上线前需重点看。

### `NewGate/` — 产品发行版（fork 装配）

| 目录 | 说明 | 远端 |
|---|---|---|
| `NewGate/` | 设计文档、harness、docker-compose、DEPLOY.md | `zoujiaqing/nanogate`（由 `zoujiaqing/NewGate` 改名） |
| `newgate` | 后端发行版（fork 自 neton-application） | ⚠️ origin 指向本地路径，本地领先 5 提交未推 |
| `newgate-front` | 管理台发行版 | ⚠️ 同上 |
| `newgate-client` | 用户控制台发行版 | ⚠️ 同上 |
| `new-api` | 参考源码，已 gitignore | — |

> ⚠️ **三个 fork 的 origin 指向 fork 来源的本地路径**（`../Neton/neton-application*`）。
> 直接 `git push` 会把产品代码注入通用底座仓——**已在 2026-09-01 验证拦截，不要推**。
> 需在 GitHub 建 `zoujiaqing/nanogate-backend` / `nanogate-frontend` / `nanogate-client`
> （本机无 `gh`、无 token，建仓需手工在网页操作），建好后改 origin 推送；
> 后端仓本地领先 5 个提交（含全部发行版历史）。

### 关键设计文档

```
NewGate/docs/superpowers/specs/2026-07-21-newgate-design.md   总设计
NewGate/DEPLOY.md                                             部署
Neton/neton-application-module-gateway/SPEC.md                网关规格（⚠️ 末尾「待办」段过时）
Neton/neton-application-module-gateway/docs/V004-durable-settlement-design.md
                                                              账务状态机 + 崩溃恢复表
```

## 三、技术栈与依赖

```
Kotlin           2.4.0    (Kotlin/Native，编译成单二进制)
Ktor             3.5.1    CIO 引擎
sqlx4k           1.12.0   Rust FFI 数据库驱动
cryptography     0.6.0    CSPRNG / SHA-256 / AES-GCM
kotlinx          coroutines 1.11.0 / serialization 1.11.0
前端             Next.js 16 + React 19 + shadcn-ui + TanStack Query
数据库           PostgreSQL（MySQL 已明确退出范围，见 SPEC「存量问题」）
```

**六条必须知道的坑：**

1. **sqlx4k 不支持 NUMERIC 解码**，碰到就 `panic=abort` 整进程崩溃。所有小数列一律用
   `VARCHAR`。这是未修的上游 P0（issue 草稿：`NewGate/docs/issues/sqlx4k-numeric-decode-p0.md`）。
2. **测试必须从 newgate 聚合仓跑**：`cd newgate && ./gradlew :module-gateway:macosArm64Test`。
   单独在 module 仓跑会因坐标解析失败。
3. **Apple 平台链接需要 Swift 库路径**：AES-GCM 在 Apple 上走 CryptoKit（Swift 实现）。
   已在 `neton/build.gradle.kts` 与 `module-gateway/build.gradle.kts` 用 `xcrun` 动态注入
   `-L.../MacOSX.sdk/usr/lib/swift`。**新增任何链接 Apple 二进制的模块都要照做**，否则
   Xcode 15 上链接失败。
4. **框架拆分后的出站 HTTP 规则**（2026-09 重构后）：`NetonHttpClient.create { }` 扩展已从
   `neton-http` 移到 `neton-http-ktor`（neton-http 不再携带引擎）。模块若直接建出站 client，
   build.gradle.kts 需加 `implementation("com.netonstream:neton-http-ktor")`，且文件需能解析到
   `neton.http.client.create`（显式 import 或 `neton.http.client.*`）。system/payment/gateway
   已按此修好。
5. **KSP 的 @Logic 装配跳过带默认值的构造参数**（`LogicProcessor` 里 `if (p.hasDefault) continue`，
   视为「自 provision」）。所以 `class RateLimiter(log, redis: RedisClient? = null)` 生成出来只传 log，
   redis 恒为 null——**不报错，只是限流静默退化成进程内计数**（多实例部署等于没限）。
   修法是模块手写 `init.{Id}RuntimeBootstrap`（KSP 约定，在 logics 之后、routes 之前调用）重绑一次：
   gateway 已加 `GatewayRuntimeBootstrap`。给 @Logic 类新增可选依赖时必须走这条路。
6. **全局关掉了 Kotlin 默认层级模板**（`gradle.properties` 里 `kotlin.mpp.applyDefaultHierarchyTemplate=false`）：
   `nativeMain` / `appleMain` / `linuxMain` 这些中间源集**不存在**。写 expect/actual 时得在模块自己的
   build.gradle.kts 里 `val posixMain by creating { dependsOn(commonMain.get()) }`，再把具体目标源集
   （`macosArm64Main` / `linuxX64Main` / `linuxArm64Main`）`by getting { dependsOn(posixMain) }` 挂上去；
   `mingwX64Main` 由 target 声明自带，直接放 `src/mingwX64Main/kotlin` 即可（gateway 的平台 DNS
   解析就是这么接的）。直接去 get `nativeMain` 会报 `KotlinSourceSet with name 'nativeMain' not found`。

## 四、已完成的部分

### 后端网关（可运行、有测试）

- **3×3 协议矩阵**：OpenAI/Anthropic/Gemini 任意组合互通。同协议透传保真，跨协议经 OpenAI
  枢纽（`ProtocolCodecs`）
- **流式**：真 SSE 直通、首字节前重试、断连结算、`terminalSeen` 协议级终止判定
  （`[DONE]`/`message_stop`/`finishReason`，按请求的 `n`/`candidateCount` 判断）
- **V004 durable settlement**：`reserve → UPSTREAM_STARTED → FINALIZE_PENDING → FINALIZED`，
  CAS 状态转换，两阶段 worker（避免锁序反转），崩溃恢复
- **安全**：CSPRNG token、渠道 Key AES-GCM 加密（`GatewayCrypto.seal/open`）、IP 白名单实际
  校验（`NetGuard.ipAllowed`）、SSRF `isPrivateHost`、RPM/TPM/并发限流（`RateLimiter.kt`）
- **安全三件套（2026-09-02）**：
  - **XFF 信任边界**：框架新增 `HttpRequest.peerAddress`（真实 TCP 对端，不被 XFF 污染；此前
    `remoteAddress` 取的就是 XFF 最左值 = 客户端可控）。`NetGuard.clientIp` 只信
    `NEWGATE_TRUSTED_PROXIES` 里的代理，从右往左剥链；未配则**完全忽略**转发头。
    ⚠️ 空列表 = 谁都不信（与 `ipAllowed` 的「空 = 不限制」相反）。S14 两阶段断言
  - **DNS 解析型 SSRF**：注入式 `HostResolver`（posix `getaddrinfo`；mingw 显式降级为不解析），
    解析失败 fail-closed，任一结果落内网即拒。**挡不住 DNS rebinding**，那层只能靠部署侧出网
    过滤（DEPLOY.md 有写）。S25 断言
  - **原子限流计数**：`INCRBY` + 条件 `EXPIRE` 一次 Lua 执行（此前读-改-写并发下丢增量 = 限流可
    绕过），`DECRBY` 带下限（防负数白送额度、防留下 TTL=-1 的永久键）。S24 断言
- **三个路由组**：`admin`（管理台）、`app`（用户控制台，归属强制取 identity）、`gateway`
  （`/` 根挂载，`Bearer sk-`）
- **原生认证载体**：`x-api-key`、`x-goog-api-key` 已映射
- 迁移 V001–V006

### 前端

- 管理台：渠道 / 定价 / 日志 / 令牌 / 结算复核页
- 用户控制台：3 个模块（我的 Key / 用量账单 / 模型广场 + 用户中心 + 财务），typecheck 通过

### 验证与 CI

- **`NewGate/harness/run.sh` — 一条命令，25 场景 37 断言。**
  隔离临时库 + 隔离 Redis 实例（6399/db15/前缀 `ngharness`，`--save ''`，PID 受控，**绝不碰开发机
  6379**）+ 可注入故障的假上游（`fakes.py`）+ 真实网关。覆盖并发账务四项不变量、故障转移、
  断连计费、worker 恢复、TTL 转人工、限流（含 Redis 原子计数）、IP 白名单 + XFF 信任边界、
  SSRF（含 DNS 复查）、原生认证、用户端越权防护等。
  **改动账务或流式代码后必须跑这个。**
  2026-09-02 实测 **37/37 全绿**（已含下述框架拆分迁移修复）。
  ⚠️ 若断言大面积 404，先查 7080 是否被残留网关进程占用（`lsof -nP -iTCP:7080 -sTCP:LISTEN`）——
  旧进程应答会让所有场景假性失败。
- **CI：三个仓都有 workflow（2026-09-02 重写）**
  - 后端 `newgate/.github/workflows/backend-ci.yml`：macOS job 编译 + `:module-gateway` /
    `:module-system` 单测；Linux job 用真实 PostgreSQL service + 隔离 Redis 跑整个可靠性 harness，
    失败上传日志。两个 job 都缓存 `~/.konan`（Kotlin/Native 工具链 ~1GB，不缓存每轮重下）。
  - 前端 `newgate-front` / `newgate-client` 各一份 `frontend-ci.yml`：pnpm 11 + Node 24，
    `install --frozen-lockfile` → typecheck → build（本机已实测三步全绿）。
    ⚠️ 两仓的 `pnpm-workspace.yaml` 里 `allowBuilds` 原本是脚手架占位文本，pnpm 11 会直接
    报 `ERR_PNPM_IGNORED_BUILDS` 并以 exit 1 结束 install（esbuild 不落二进制 → `pnpm registry` 的 tsx
    也跑不了），已改成 `true`。
  - **checkout 布局是硬约束**：fork 放 `dist/<repo>`（两层深），canonical 仓放 workspace 根的 `Neton/*`。
    后端 `settings.gradle.kts` 的 `../../Neton/*`、前端 `apps/*/package.json` 的
    `file:../../../../Neton/*` 都按这个相对深度解析，差一层就装不起来。旧 workflow 的平铺路径
    （`neton`、`neton-application-module-*` 直接放根）是错的，且漏了 geolite4k / module-system /
    module-infra 三个必选 checkout，已修。
  ⚠️ **仍未真跑过**：三个 fork 的 GitHub 仓还没建（origin 仍指向本地路径）。建好后需在每个仓
  配 secret `NETON_CI_TOKEN`（fine-grained PAT，对 netonframework / neton-application 只读）：
  canonical 仓里有私有仓（如 module-gateway、front-gateway），`actions/checkout` 跨仓拉私有仓时
  `GITHUB_TOKEN` 无效。workflow 已写成 `secrets.NETON_CI_TOKEN || secrets.GITHUB_TOKEN`，全公开时不配也行。
  ⚠️ 两个前端仓的 `pnpm-lock.yaml` 把 tarball 地址固定在 `registry.npmmirror.com`（维护者本地
  registry 就是这个镜像）。GitHub runner 能访问但偏慢；要换官方源，得在没有全局 mirror 配置的
  环境重新生成 lockfile。

## 五、⚠️ SPEC.md 的「待办」段落已过时

`neton-application-module-gateway/SPEC.md` 末尾「待办（Codex 评审确认的真实差距）」一段列的
很多项**已经做完**（同一文件前面的「商业上线 A/B/C 三阶段」章节才是新记录）：

| SPEC 末尾说"未完成" | 实际 |
|---|---|
| IP 白名单仅字段无校验 | ✅ 已校验（S14 断言，含 XFF 信任边界） |
| RPM/TPM/并发未实现 | ✅ 已实现（S13 断言；S24 断言 Redis 原子计数） |
| 渠道 Key 明文存储 | ✅ AES-GCM 加密 |
| SSRF 无校验 | ✅ `isPrivateHost` + DNS 解析复查（S25 断言） |
| `/v1/models` 返回空 | ✅ 真数据（S15 断言） |
| 原生认证载体未映射 | ✅ 已映射（S15 断言） |
| 未定价模型免费放行 | ✅ 拒绝（S16 断言） |
| 管理台日志页契约错位 | ✅ `/gateway/log/page` 已补 |

**以代码和 harness 为准，不要以那段文字为准。** 接手后建议先重写该段（真实剩余差距见下节）。

## 六、真正还没做的

**上线阻塞：**
- 真实支付接入（现在只有 mock 充值，且需 `NEWGATE_ENABLE_MOCK_RECHARGE=true` 才启用）；
  payment/member 的充值与 gateway 额度未接通
- 用户注册登录流（控制台只做了资料页，无自助注册）
- 三个发行版仓（`newgate` / `newgate-front` / `newgate-client`）的正式远端未配置（CI workflow 已写好，
  建仓 + 配 `NETON_CI_TOKEN` 后即可真跑）

**功能缺口：**
- Azure OpenAI 原生（当前走 OpenAiAdapter）
- 扩展端点：Responses / Images / Audio / Rerank
- codec 有损：thinking / cache_control / 多模态 / structured output
- 价源同步、渠道测速、毛利看板
- 可观测性：无 metrics / 告警 / 审计日志

**小残留：**
- `harness/run.sh` 的 `PGPASS` 默认值还叫 `privchat`（可被环境变量覆盖；应用配置本身已
  清理干净——`database.conf` 默认 `newgate:newgate@localhost`，`application.conf` 名为
  `newgate`，JWT secret 是显式 `REPLACE_ME` 占位）
- **框架拆分迁移修复（已提交，2026-09-01）**：neton 的 6 个重构提交（已推送）把 Ktor
  server/client 拆出 `neton-http`，曾导致本机聚合构建编译失败。已修：
  - `module-system`/`module-payment`/`module-gateway`：build.gradle.kts 补 `neton-http-ktor`
    依赖；`SmsProvider.kt`、`AlipayPayPlatform.kt`、`SifangPayPlatform.kt` 补 `import neton.http.client.create`
  - `newgate/application`：补 `neton-http-ktor` 依赖；`Main.kt` 改 `http(::KtorHttpAdapter) { }`
  修后 23/23 全绿。模块仓修复已推送；**newgate 发行版仓的修复已提交但未推送**（无可推远端，见下）。

**已知未闭环（V004 设计文档 §6 有详述）：**
- `C3′`：拿到 usage 但 payload 落库失败且进程崩溃 → usage 永久丢失，只能人工处理。
  **"收入有资金保障"成立，但"结算可自动恢复"仅在 payload 已落库后成立** —— 这个区分不要混淆
- 幂等只做到"拒绝重复"（409），未做响应缓存重放

## 七、给接手者的三条建议

1. **先跑 harness**（`cd NewGate && bash harness/run.sh`），37 绿是当前基线。任何改动后回归它。
   需要本机 5432 的 PostgreSQL（Homebrew postgresql@16 即可），凭据走 `PGUSER`/`PGPASS` 环境变量；
   另需 `redis-server`（`brew install redis`）——没装不会失败，但 S24 会跳过、限流退化为进程内计数。
2. **配 remote**：`newgate` / `newgate-front` / `newgate-client` 三个仓的 origin 仍指向
   `../Neton/*` 本地路径，推送产品代码前必须先改成正式远端（在 GitHub 建空的
   `nanogate-backend` / `nanogate-frontend` / `nanogate-client`，然后
   `git remote set-url origin git@github.com:zoujiaqing/<repo>.git && git push -u origin main`）。
3. **提交规范**：简短英文单行，无 AI 痕迹（无 `Co-Authored-By`、无工具名）。全部历史已按此
   清理过，包括 force-push 重写了 `netonframework/neton` 的公共历史。
