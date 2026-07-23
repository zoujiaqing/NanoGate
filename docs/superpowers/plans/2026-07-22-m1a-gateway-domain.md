# M1a：module-gateway 领域基础 — 实施计划

> ⚠️ **数据库范围已被最新设计取代**：NewGate 仅支持 **PostgreSQL / MySQL**，**不支持 SQLite**。本历史计划中一切
> 以 SQLite 为验收路径的步骤（SQLite 零配置建库、`sql/sqlite/` 建表、SQLite 冒烟等）**不再执行**。sqlx4k Native 驱动
> 编译期单选，PostgreSQL 与 MySQL 各为一种构建产物（`-Pneton.database.driver=postgres`（默认）/`=mysql`）。
> 详见 `2026-07-21-newgate-design.md` §10 与 gateway `SPEC.md`「数据库支持范围」。（历史计划正文不改写，仅此声明为准。）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 `neton-application-module-gateway` canonical 仓库：8 张领域表 + admin CRUD API + sk- 令牌体系 + gateway 路由组接线（TokenGuard），为 M1b 中转引擎提供全部领域基础。

**Architecture:** 按 module-template-spec 的外部模块形态建 canonical 仓（sibling of member/payment），newgate 聚合装配；gateway 路由组挂载 `/`，用 `SecurityBuilder.setGroupAuthenticator("gateway", ...)` 注入 sk- 令牌认证器；额度走台账（BIGINT μUSD，原子扣减）。

**Tech Stack:** Kotlin/Native + Neton（KSP 路由组已编译期写入）、neton-database DSL、SQLite/PostgreSQL/MySQL

**关联 spec:** `2026-07-21-newgate-design.md` §6（领域模型）、§2.2（路由组）、决策 B/B2/F
**范围外（后续里程碑）**：`gateway_price_sources` / `gateway_price_revisions`（M3 价源同步）、`gateway_redemptions`（M4 兑换码）、中转引擎本身（M1b）

## Global Constraints

- canonical 仓路径：`/Users/zoujiaqing/projects/Neton/neton-application-module-gateway`；聚合注册在 `/Users/zoujiaqing/projects/NewGate/newgate/settings.gradle.kts`
- 遵循 `neton-application/docs/module-template-spec.md`：资源规则 §4（`/get/{id}`、DTO 写接口、0/1 布尔、标准方法名 page/list/get/create/update/delete）、controller 类名不带 Admin 前缀（组来自包路径）
- 表名前缀 `gateway_`；金额一律 **BIGINT μUSD**（1e-6 USD）；价格 **十进制字符串存储**（DECIMAL(20,6)），单位 USD/1M tokens
- 时间戳 Long epoch millis（`@CreatedAt/@UpdatedAt Long?`，列 BIGINT），软删 `@SoftDelete deleted INT 0/1`
- 权限码：`gateway:channel:*`、`gateway:token:*`、`gateway:price:*`、`gateway:group:*`、`gateway:quota:*`、`gateway:log:*`
- 测试命令：模块内 `./gradlew macosArm64Test`；聚合编译 `cd newgate && ./gradlew :application:compileKotlinMacosArm64`
- 每任务完成即 commit（gateway 模块仓自己的 git）；newgate/框架仓的改动各自提交
- 敏感值纪律：渠道 Key 全文不入日志；令牌只存 `key_hash`（SHA-256 hex）+ `key_display`（前 7 + 后 4）

---

### Task 1: 建仓 neton-application-module-gateway + 聚合装配

**Files:**
- Create: `/Users/zoujiaqing/projects/Neton/neton-application-module-gateway/`（复制自 `neton-application-module-template`）
- Modify: `/Users/zoujiaqing/projects/NewGate/newgate/settings.gradle.kts`

**Interfaces:**
- Produces: Gradle 项目 `:module-gateway`、`@Module(dependsOn=["system"], migrations=true) object GatewayModule`。后续任务全部落在此仓。

- [ ] **Step 1: 复制模板并重命名**

```bash
cd /Users/zoujiaqing/projects/Neton
cp -R neton-application-module-template neton-application-module-gateway
cd neton-application-module-gateway
rm -rf build .git
git init -b main
sed -i '' 's/neton-application-module-template/neton-application-module-gateway/' settings.gradle.kts
```

- [ ] **Step 2: 替换 initializer 与示例 controller**

删除 `src/commonMain/kotlin/init/HelloWorldModuleInitializer.kt` 与
`src/commonMain/kotlin/controller/admin/helloworld/`，新建
`src/commonMain/kotlin/init/GatewayModule.kt`：

```kotlin
package init

import neton.core.annotations.Module

/**
 * gateway 模块声明锚点：LLM 中转站领域（渠道/令牌/定价/额度/用量）。
 * KSP 生成 GatewayModuleManifest（@Logic 装配 + 路由 + migrations）。
 */
@Module(dependsOn = ["system"], migrations = true)
object GatewayModule
```

新建占位健康检查 `src/commonMain/kotlin/controller/admin/gateway/GatewayInfoController.kt`：

```kotlin
package controller.admin.gateway

import neton.core.annotations.Controller
import neton.core.annotations.Get

@Controller("/gateway/info")
class GatewayInfoController {
    @Get("/ping")
    suspend fun ping(): String = "gateway module ok"
}
```

同步清理 `src/commonTest/kotlin/HelloWorldTemplateTest.kt` → 改名 `GatewayModuleTest.kt`，
断言模块编译期常量即可（保留一个最小测试防空测试集）。
`build.gradle.kts` 的依赖段对齐 platform 模块（module-system + neton-core/routing/security/http/database/logging/validation + KSP），
`SPEC.md` 先写一句占位（Task 6 完成正文）。

- [ ] **Step 3: 模块独立编译**

```bash
./gradlew compileKotlinMacosArm64
```
Expected: BUILD SUCCESSFUL

- [ ] **Step 4: 注册进 newgate 聚合**

`/Users/zoujiaqing/projects/NewGate/newgate/settings.gradle.kts` 的模块区追加：

```kotlin
include(":module-gateway")
project(":module-gateway").projectDir = file("../../Neton/neton-application-module-gateway")
```

`newgate/application/build.gradle.kts` 依赖区（对照 module-member 的引入行）追加
`implementation(project(":module-gateway"))`；application 的模块清单
（`neton.modules`，grep `"member"` 定位注册点）追加 `gateway`。

- [ ] **Step 5: 聚合编译**

```bash
cd /Users/zoujiaqing/projects/NewGate/newgate && ./gradlew :application:compileKotlinMacosArm64
```
Expected: BUILD SUCCESSFUL

- [ ] **Step 6: Commit（两仓）**

```bash
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway
git add -A && git commit -m "feat: gateway 模块骨架（NewGate LLM 中转领域）"
cd /Users/zoujiaqing/projects/NewGate/newgate
git add settings.gradle.kts application/ && git commit -m "feat: 装配 module-gateway"
```

---

### Task 2: Channel + ChannelKey 资源（完整链路示范）

**Files:**（均在 gateway 模块仓）
- Create: `src/commonMain/kotlin/model/Channel.kt`、`model/ChannelKey.kt`
- Create: `src/commonMain/kotlin/table/ChannelTable.kt`、`table/ChannelKeyTable.kt`
- Create: `src/commonMain/kotlin/logic/ChannelLogic.kt`
- Create: `src/commonMain/kotlin/controller/admin/channel/ChannelController.kt` + `dto/`
- Create: `sql/postgresql/V001__create_tables.sql`（本任务先写 channels/channel_keys 两张，后续任务追加同文件）
- Test: `src/commonTest/kotlin/logic/ChannelLogicTest.kt`

**Interfaces:**
- Produces: `ChannelTable`/`ChannelKeyTable`（Table facade）、`ChannelLogic.pickKey(channelId): ChannelKey?`（M1b 取 Key 用）、admin API `/admin/gateway/channel/*`

- [ ] **Step 1: model（完整代码）**

```kotlin
package model

import kotlinx.serialization.Serializable
import neton.database.annotations.*

/** 上游渠道。type: openai_compatible / anthropic / gemini / azure_openai（spec 决策 D）。 */
@Serializable
@Table("gateway_channels")
data class Channel(
    @Id val id: Long = 0,
    val name: String,
    val type: String,
    val baseUrl: String,
    /** 渠道分组（与用户分组求交集决定可用性），逗号分隔如 "default,vip" */
    val groups: String = "default",
    /** 支持的模型清单，逗号分隔 */
    val models: String = "",
    /** 模型映射 JSON：{"请求名":"上游名"} */
    val modelMapping: String? = null,
    /** 请求参数覆盖 JSON */
    val paramOverride: String? = null,
    val priority: Int = 0,
    val weight: Int = 1,
    /** 1=启用 0=禁用 2=自动挂起（全部 Key 失效） */
    val status: Int = 1,
    /** TTFB 超时 ms */
    val ttfbTimeoutMs: Long = 30_000,
    /** 流式块间空闲超时 ms */
    val idleTimeoutMs: Long = 90_000,
    val proxyUrl: String? = null,
    /** 成本折扣（如 0.6 = 官方价 6 折），DECIMAL 字符串，毛利核算用（spec 决策 B2） */
    val costDiscount: String = "1.0",
    val remark: String? = null,
    @SoftDelete val deleted: Int = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)

/** 渠道 Key（多 Key 逐个禁用，优于 new-api 换行分隔）。 */
@Serializable
@Table("gateway_channel_keys")
data class ChannelKey(
    @Id val id: Long = 0,
    val channelId: Long,
    val apiKey: String,
    /** 1=可用 0=手动禁用 2=连续失败自动禁用 */
    val status: Int = 1,
    val failCount: Int = 0,
    val lastError: String? = null,
    val lastUsedAt: Long? = null,
    @SoftDelete val deleted: Int = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)
```

- [ ] **Step 2: table facade（完整代码）**

```kotlin
// table/ChannelTable.kt
package table

import model.Channel
import model.ChannelTableImpl
import neton.database.api.Table

object ChannelTable : Table<Channel, Long> by ChannelTableImpl
```

```kotlin
// table/ChannelKeyTable.kt
package table

import model.ChannelKey
import model.ChannelKeyTableImpl
import neton.database.api.Table

object ChannelKeyTable : Table<ChannelKey, Long> by ChannelKeyTableImpl
```

- [ ] **Step 3: 先写失败测试**

```kotlin
package logic

import kotlin.test.Test
import kotlin.test.assertEquals

class ChannelLogicTest {
    @Test
    fun pickKeySkipsDisabledKeys() {
        // 纯函数测试：从候选 Key 列表中选择可用 Key（DB 交互由 Logic 内部走 Table，
        // 选择策略抽成可测纯函数 pickAvailable）
        val keys = listOf(
            model.ChannelKey(id = 1, channelId = 1, apiKey = "sk-a", status = 0),
            model.ChannelKey(id = 2, channelId = 1, apiKey = "sk-b", status = 1),
            model.ChannelKey(id = 3, channelId = 1, apiKey = "sk-c", status = 2),
        )
        assertEquals(2L, ChannelLogic.pickAvailable(keys)?.id)
    }

    @Test
    fun pickAvailableReturnsNullWhenAllDisabled() {
        val keys = listOf(model.ChannelKey(id = 1, channelId = 1, apiKey = "sk-a", status = 0))
        assertEquals(null, ChannelLogic.pickAvailable(keys))
    }
}
```

Run: `./gradlew macosArm64Test --tests "*ChannelLogicTest*"` → Expected: FAIL（unresolved ChannelLogic）

- [ ] **Step 4: logic（完整代码）**

```kotlin
package logic

import model.Channel
import model.ChannelKey
import neton.database.dsl.*
import neton.logging.Logger
import table.ChannelKeyTable
import table.ChannelTable

@neton.core.annotations.Logic(logger = "logic.gateway-channel")
class ChannelLogic(private val log: Logger) {

    suspend fun create(channel: Channel): Long = ChannelTable.insert(channel).id

    suspend fun get(id: Long): Channel? = ChannelTable.get(id)

    suspend fun update(channel: Channel) { ChannelTable.update(channel) }

    suspend fun delete(id: Long) {
        ChannelTable.destroy(id)
        log.info("gateway channel deleted id=$id")
    }

    suspend fun listEnabled(): List<Channel> =
        ChannelTable.listWhere { Channel::status eq 1 }

    suspend fun updateStatus(id: Long, status: Int) {
        val current = get(id) ?: return
        ChannelTable.update(current.copy(status = status))
    }

    // ===== Key 管理 =====

    suspend fun listKeys(channelId: Long): List<ChannelKey> =
        ChannelKeyTable.listWhere { ChannelKey::channelId eq channelId }

    suspend fun addKey(channelId: Long, apiKey: String): Long =
        ChannelKeyTable.insert(ChannelKey(channelId = channelId, apiKey = apiKey)).id

    suspend fun pickKey(channelId: Long): ChannelKey? = pickAvailable(listKeys(channelId))

    companion object {
        /** 选择策略纯函数：只取 status=1，按 lastUsedAt 轮转（最久未用优先）。 */
        fun pickAvailable(keys: List<ChannelKey>): ChannelKey? =
            keys.filter { it.status == 1 }.minByOrNull { it.lastUsedAt ?: 0L }
    }
}
```

（`listWhere` 若 DSL 实际方法名不同——以 ChargeLogic 里 `oneWhere` 同族 API 为准 grep
`neton-database/.../dsl` 确认列表查询方法名后替换，语义不变。）

- [ ] **Step 5: controller + DTO（完整代码）**

`controller/admin/channel/dto/ChannelDtos.kt`：

```kotlin
package controller.admin.channel.dto

import kotlinx.serialization.Serializable

@Serializable
data class CreateChannelRequest(
    val name: String,
    val type: String,
    val baseUrl: String,
    val groups: String = "default",
    val models: String = "",
    val modelMapping: String? = null,
    val paramOverride: String? = null,
    val priority: Int = 0,
    val weight: Int = 1,
    val proxyUrl: String? = null,
    val costDiscount: String = "1.0",
    val remark: String? = null,
    /** 初始 Key 列表（可批量粘贴） */
    val keys: List<String> = emptyList(),
)

@Serializable
data class UpdateChannelRequest(
    val id: Long,
    val name: String,
    val type: String,
    val baseUrl: String,
    val groups: String,
    val models: String,
    val modelMapping: String?,
    val paramOverride: String?,
    val priority: Int,
    val weight: Int,
    val proxyUrl: String?,
    val costDiscount: String,
    val remark: String?,
)

@Serializable
data class ChannelKeyVO(
    val id: Long,
    val display: String,   // 前 7 + **** + 后 4，全文不出接口
    val status: Int,
    val failCount: Int,
    val lastError: String?,
)
```

`controller/admin/channel/ChannelController.kt`：

```kotlin
package controller.admin.channel

import controller.admin.channel.dto.*
import logic.ChannelLogic
import model.Channel
import neton.core.annotations.*

@Controller("/gateway/channel")
class ChannelController(private val channelLogic: ChannelLogic) {

    @Get("/list")
    @Permission("gateway:channel:list")
    suspend fun list(): List<Channel> = channelLogic.listEnabled()

    @Get("/get/{id}")
    @Permission("gateway:channel:get")
    suspend fun get(@PathVariable id: Long): Channel? = channelLogic.get(id)

    @Post("/create")
    @Permission("gateway:channel:create")
    suspend fun create(@Body request: CreateChannelRequest): Long {
        val id = channelLogic.create(
            Channel(
                name = request.name, type = request.type, baseUrl = request.baseUrl,
                groups = request.groups, models = request.models,
                modelMapping = request.modelMapping, paramOverride = request.paramOverride,
                priority = request.priority, weight = request.weight,
                proxyUrl = request.proxyUrl, costDiscount = request.costDiscount,
                remark = request.remark,
            )
        )
        request.keys.forEach { channelLogic.addKey(id, it) }
        return id
    }

    @Put("/update")
    @Permission("gateway:channel:update")
    suspend fun update(@Body request: UpdateChannelRequest) {
        val current = channelLogic.get(request.id)
            ?: throw IllegalArgumentException("gateway channel id=${request.id} not found")
        channelLogic.update(current.copy(
            name = request.name, type = request.type, baseUrl = request.baseUrl,
            groups = request.groups, models = request.models,
            modelMapping = request.modelMapping, paramOverride = request.paramOverride,
            priority = request.priority, weight = request.weight,
            proxyUrl = request.proxyUrl, costDiscount = request.costDiscount,
            remark = request.remark,
        ))
    }

    @Put("/update-status")
    @Permission("gateway:channel:update")
    suspend fun updateStatus(@Query id: Long, @Query status: Int) =
        channelLogic.updateStatus(id, status)

    @Delete("/delete/{id}")
    @Permission("gateway:channel:delete")
    suspend fun delete(@PathVariable id: Long) = channelLogic.delete(id)

    @Get("/keys/{id}")
    @Permission("gateway:channel:get")
    suspend fun keys(@PathVariable id: Long): List<ChannelKeyVO> =
        channelLogic.listKeys(id).map {
            ChannelKeyVO(
                id = it.id,
                display = maskKey(it.apiKey),
                status = it.status, failCount = it.failCount, lastError = it.lastError,
            )
        }

    @Post("/keys/{id}/add")
    @Permission("gateway:channel:update")
    suspend fun addKey(@PathVariable id: Long, @Body request: AddKeyRequest): Long =
        channelLogic.addKey(id, request.apiKey)

    private fun maskKey(key: String): String =
        if (key.length <= 11) "****" else key.take(7) + "****" + key.takeLast(4)
}

@kotlinx.serialization.Serializable
data class AddKeyRequest(val apiKey: String)
```

- [ ] **Step 6: SQL（PostgreSQL，本任务两张表）**

`sql/postgresql/V001__create_tables.sql`（新建；后续任务在同文件追加）：

```sql
-- gateway module V001: 渠道
CREATE TABLE gateway_channels (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    type VARCHAR(32) NOT NULL,
    base_url VARCHAR(512) NOT NULL,
    groups VARCHAR(256) NOT NULL DEFAULT 'default',
    models TEXT NOT NULL DEFAULT '',
    model_mapping TEXT,
    param_override TEXT,
    priority INT NOT NULL DEFAULT 0,
    weight INT NOT NULL DEFAULT 1,
    status INT NOT NULL DEFAULT 1,
    ttfb_timeout_ms BIGINT NOT NULL DEFAULT 30000,
    idle_timeout_ms BIGINT NOT NULL DEFAULT 90000,
    proxy_url VARCHAR(512),
    cost_discount DECIMAL(10,4) NOT NULL DEFAULT 1.0,
    remark VARCHAR(512),
    deleted INT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);
CREATE INDEX idx_gateway_channels_status ON gateway_channels(status, deleted);

CREATE TABLE gateway_channel_keys (
    id BIGSERIAL PRIMARY KEY,
    channel_id BIGINT NOT NULL,
    api_key VARCHAR(1024) NOT NULL,
    status INT NOT NULL DEFAULT 1,
    fail_count INT NOT NULL DEFAULT 0,
    last_error VARCHAR(512),
    last_used_at BIGINT,
    deleted INT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);
CREATE INDEX idx_gateway_channel_keys_channel ON gateway_channel_keys(channel_id, status, deleted);
```

- [ ] **Step 7: 测试通过 + 聚合编译 + Commit**

```bash
./gradlew macosArm64Test --tests "*ChannelLogicTest*"   # PASS
cd /Users/zoujiaqing/projects/NewGate/newgate && ./gradlew :application:compileKotlinMacosArm64  # BUILD SUCCESSFUL
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway
git add -A && git commit -m "feat: Channel/ChannelKey 资源（多 Key 逐个禁用 + 轮转选择）"
```

---

### Task 3: Sha256 公开工具（框架）+ Token 资源（sk- 令牌）

**Files:**
- Modify: `/Users/zoujiaqing/projects/Neton/neton/neton-security/src/commonMain/kotlin/neton/security/password/PasswordHasher.kt`（提取 sha256 为可复用）
- Create: `/Users/zoujiaqing/projects/Neton/neton/neton-security/src/commonMain/kotlin/neton/security/digest/Sha256.kt`
- Test: `/Users/zoujiaqing/projects/Neton/neton/neton-security/src/commonTest/kotlin/neton/security/digest/Sha256Test.kt`
- Create（gateway 模块仓）: `model/GatewayToken.kt`、`table/GatewayTokenTable.kt`、`logic/TokenLogic.kt`、`controller/admin/token/TokenController.kt` + dto、`sql/postgresql/V001__create_tables.sql` 追加
- Test: `src/commonTest/kotlin/logic/TokenLogicTest.kt`

**Interfaces:**
- Produces: `neton.security.digest.Sha256.hex(input: String): String`（框架公共 API）；
  `TokenLogic.issue(userId, name, ...): IssuedToken(plaintext, record)`（明文仅此一次）；
  `TokenLogic.verify(plaintext): GatewayToken?`（M1b TokenGuard 用）

- [ ] **Step 1: 框架 Sha256 失败测试**

```kotlin
package neton.security.digest

import kotlin.test.Test
import kotlin.test.assertEquals

class Sha256Test {
    @Test
    fun knownVector() {
        // NIST 标准向量
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.hex("abc")
        )
    }

    @Test
    fun emptyString() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Sha256.hex("")
        )
    }
}
```

Run: `cd /Users/zoujiaqing/projects/Neton/neton && ./gradlew :neton-security:macosArm64Test --tests "*Sha256Test*"` → FAIL（unresolved）

- [ ] **Step 2: 实现 Sha256.hex**

`PasswordHasher.kt:116` 已有私有 `sha256(input, blockSize, digestLength)` 实现。新建
`digest/Sha256.kt`，把该实现**移动**为共享 internal 函数（或直接在 Sha256 对象中实现标准
SHA-256——以 PasswordHasher 现有实现为准抽取，不重写算法），对外暴露：

```kotlin
package neton.security.digest

/** 通用 SHA-256（hex 小写）。NewGate 网关令牌哈希等场景使用。 */
object Sha256 {
    fun hex(input: String): String = hex(input.encodeToByteArray())
    fun hex(input: ByteArray): String {
        val digest = sha256Digest(input)  // 与 PasswordHasher 共用的实现
        return digest.joinToString("") { byte ->
            val v = byte.toInt() and 0xff
            v.toString(16).padStart(2, '0')
        }
    }
}
```

PasswordHasher 改为调用共享实现，其现有测试必须保持全绿（回归约束）。

Run: `./gradlew :neton-security:macosArm64Test` → PASS，然后框架仓 commit：
`feat(security): 公开 Sha256.hex 摘要工具（网关令牌哈希前置）`

- [ ] **Step 3: Token model + SQL（gateway 仓，完整代码）**

```kotlin
package model

import kotlinx.serialization.Serializable
import neton.database.annotations.*

/** 用户 API 令牌。明文不落库：key_hash = SHA-256(sk-...)，key_display = 前7+后4。 */
@Serializable
@Table("gateway_tokens")
data class GatewayToken(
    @Id val id: Long = 0,
    val userId: Long,
    val name: String,
    val keyHash: String,
    val keyDisplay: String,
    /** μUSD 预算；null = 不限（仍受账户余额约束） */
    val quotaBudget: Long? = null,
    val quotaUsed: Long = 0,
    val expiresAt: Long? = null,
    /** 允许模型，逗号分隔；空 = 不限 */
    val allowedModels: String = "",
    /** 允许 IP（CIDR/精确），逗号分隔；空 = 不限 */
    val allowedIps: String = "",
    /** 覆盖用户分组；空 = 用用户自身分组 */
    val groupOverride: String? = null,
    val status: Int = 1,
    @SoftDelete val deleted: Int = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)
```

`table/GatewayTokenTable.kt` 同 Task 2 facade 模式。V001 追加：

```sql
CREATE TABLE gateway_tokens (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    name VARCHAR(128) NOT NULL,
    key_hash CHAR(64) NOT NULL,
    key_display VARCHAR(32) NOT NULL,
    quota_budget BIGINT,
    quota_used BIGINT NOT NULL DEFAULT 0,
    expires_at BIGINT,
    allowed_models TEXT NOT NULL DEFAULT '',
    allowed_ips TEXT NOT NULL DEFAULT '',
    group_override VARCHAR(64),
    status INT NOT NULL DEFAULT 1,
    deleted INT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);
CREATE UNIQUE INDEX uk_gateway_tokens_hash ON gateway_tokens(key_hash);
CREATE INDEX idx_gateway_tokens_user ON gateway_tokens(user_id, deleted);
```

- [ ] **Step 4: TokenLogic 失败测试**

```kotlin
package logic

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TokenLogicTest {
    @Test
    fun generatedKeyHasSkPrefixAnd48Chars() {
        val key = TokenLogic.generateKey()
        assertTrue(key.startsWith("sk-"))
        assertEquals(51, key.length) // "sk-" + 48
        // 只含 URL 安全字符
        assertTrue(key.drop(3).all { it.isLetterOrDigit() })
    }

    @Test
    fun displayMasksMiddle() {
        assertEquals("sk-abcd****wxyz", TokenLogic.display("sk-abcdEFGHijklMNOPqrstUVWXyz0123456789abcdefwxyz"))
    }

    @Test
    fun hashIsStable() {
        val key = "sk-test"
        assertEquals(TokenLogic.hashKey(key), TokenLogic.hashKey(key))
        assertEquals(64, TokenLogic.hashKey(key).length)
    }
}
```

Run → FAIL（unresolved TokenLogic）

- [ ] **Step 5: TokenLogic 实现（完整代码）**

```kotlin
package logic

import model.GatewayToken
import neton.database.dsl.*
import neton.logging.Logger
import neton.security.digest.Sha256
import table.GatewayTokenTable
import kotlin.random.Random

data class IssuedToken(val plaintext: String, val record: GatewayToken)

@neton.core.annotations.Logic(logger = "logic.gateway-token")
class TokenLogic(private val log: Logger) {

    suspend fun issue(
        userId: Long,
        name: String,
        quotaBudget: Long? = null,
        expiresAt: Long? = null,
        allowedModels: String = "",
        allowedIps: String = "",
        groupOverride: String? = null,
    ): IssuedToken {
        val plaintext = generateKey()
        val record = GatewayTokenTable.insert(
            GatewayToken(
                userId = userId, name = name,
                keyHash = hashKey(plaintext), keyDisplay = display(plaintext),
                quotaBudget = quotaBudget, expiresAt = expiresAt,
                allowedModels = allowedModels, allowedIps = allowedIps,
                groupOverride = groupOverride,
            )
        )
        log.info("gateway token issued id=${record.id} user=$userId display=${record.keyDisplay}")
        return IssuedToken(plaintext, record)
    }

    /** M1b TokenGuard 入口：明文 → 哈希查表。过期/禁用返回 null。 */
    suspend fun verify(plaintext: String): GatewayToken? {
        val token = GatewayTokenTable.oneWhere { GatewayToken::keyHash eq hashKey(plaintext) } ?: return null
        if (token.status != 1) return null
        token.expiresAt?.let { if (it < nowMillis()) return null }
        return token
    }

    suspend fun listByUser(userId: Long): List<GatewayToken> =
        GatewayTokenTable.listWhere { GatewayToken::userId eq userId }

    suspend fun updateStatus(id: Long, status: Int) {
        val current = GatewayTokenTable.get(id) ?: return
        GatewayTokenTable.update(current.copy(status = status))
    }

    suspend fun delete(id: Long) = GatewayTokenTable.destroy(id)

    companion object {
        private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

        fun generateKey(): String =
            "sk-" + buildString(48) { repeat(48) { append(ALPHABET[Random.nextInt(ALPHABET.length)]) } }

        fun hashKey(plaintext: String): String = Sha256.hex(plaintext)

        fun display(key: String): String =
            if (key.length <= 11) "****" else key.take(7) + "****" + key.takeLast(4)

        fun nowMillis(): Long = kotlin.time.Clock.System.now().toEpochMilliseconds()
    }
}
```

（`Random` 用于 v1；后续安全强化换 SecureRandom 等价物时补契约测试。`kotlin.time.Clock`
用法与 KtorHttpAdapter.kt:312 一致。）

- [ ] **Step 6: TokenController（admin 全局视角，完整代码）**

```kotlin
package controller.admin.token

import kotlinx.serialization.Serializable
import logic.IssuedToken
import logic.TokenLogic
import model.GatewayToken
import neton.core.annotations.*

@Serializable
data class CreateTokenRequest(
    val userId: Long,
    val name: String,
    val quotaBudget: Long? = null,
    val expiresAt: Long? = null,
    val allowedModels: String = "",
    val allowedIps: String = "",
    val groupOverride: String? = null,
)

@Serializable
data class IssuedTokenVO(val id: Long, val key: String, val display: String)

@Controller("/gateway/token")
class TokenController(private val tokenLogic: TokenLogic) {

    @Post("/create")
    @Permission("gateway:token:create")
    suspend fun create(@Body request: CreateTokenRequest): IssuedTokenVO {
        val issued: IssuedToken = tokenLogic.issue(
            userId = request.userId, name = request.name,
            quotaBudget = request.quotaBudget, expiresAt = request.expiresAt,
            allowedModels = request.allowedModels, allowedIps = request.allowedIps,
            groupOverride = request.groupOverride,
        )
        // 明文仅在创建响应中出现一次
        return IssuedTokenVO(issued.record.id, issued.plaintext, issued.record.keyDisplay)
    }

    @Get("/list-by-user/{userId}")
    @Permission("gateway:token:list")
    suspend fun listByUser(@PathVariable userId: Long): List<GatewayToken> =
        tokenLogic.listByUser(userId)

    @Put("/update-status")
    @Permission("gateway:token:update")
    suspend fun updateStatus(@Query id: Long, @Query status: Int) =
        tokenLogic.updateStatus(id, status)

    @Delete("/delete/{id}")
    @Permission("gateway:token:delete")
    suspend fun delete(@PathVariable id: Long) = tokenLogic.delete(id)
}
```

（GatewayToken 序列化输出含 keyHash——加 `@kotlinx.serialization.Transient` 不可（构造参数），
改为 list 返回 VO：执行时若发现 keyHash 出现在响应，新增 `TokenVO`（不含 keyHash）替换返回类型，字段同 model 减 keyHash。）

- [ ] **Step 7: 测试 + 聚合编译 + Commit**

```bash
./gradlew macosArm64Test    # 模块全绿
cd /Users/zoujiaqing/projects/NewGate/newgate && ./gradlew :application:compileKotlinMacosArm64
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway
git add -A && git commit -m "feat: sk- 令牌体系（哈希存储/一次性展示/verify 入口）"
```

---

### Task 4: gateway 路由组接线（挂载 / + TokenGuard 认证器）

**Files:**
- Modify: `/Users/zoujiaqing/projects/NewGate/newgate/application/config/routing.conf`
- Create（gateway 模块仓）: `src/commonMain/kotlin/security/GatewayTokenAuthenticator.kt`
- Create（gateway 模块仓）: `src/commonMain/kotlin/config/GatewaySecurityConfig.kt`
- Create（gateway 模块仓）: `src/commonMain/kotlin/controller/gateway/ModelsController.kt`（第一个 gateway 组端点，冒烟用）

**Interfaces:**
- Consumes: `SecurityBuilder.setGroupAuthenticator("gateway", auth)`（neton-core SecurityBuilder:104）、`TokenLogic.verify`、KSP 目录约定（`controller.gateway.*` → routeGroup="gateway"）
- Produces: `GET /v1/models` 需 `Authorization: Bearer sk-xxx`；无效 401、有效 200

- [ ] **Step 1: routing.conf 加 gateway 组**

`newgate/application/config/routing.conf` 追加：

```toml
[[groups]]
group = "gateway"
mount = "/"
requireAuth = true
```

- [ ] **Step 2: GatewayTokenAuthenticator（完整代码）**

```kotlin
package security

import logic.TokenLogic
import neton.core.interfaces.Identity
import neton.core.interfaces.RequestContext
import neton.security.Authenticator

/** gateway 组认证器：Authorization: Bearer sk-xxx → 哈希查表 → Identity。 */
class GatewayTokenAuthenticator(private val tokenLogic: TokenLogic) : Authenticator {

    override suspend fun authenticate(context: RequestContext): Identity? {
        val header = context.headers["Authorization"] ?: context.headers["authorization"] ?: return null
        val plaintext = header.removePrefix("Bearer ").trim()
        if (!plaintext.startsWith("sk-")) return null
        val token = tokenLogic.verify(plaintext) ?: return null
        return GatewayTokenIdentity(token.userId, token.id)
    }
}

class GatewayTokenIdentity(
    private val userId: Long,
    val tokenId: Long,
) : Identity {
    override val id: String get() = userId.toString()
    override fun hasRole(role: String): Boolean = false
    override fun hasPermission(permission: String): Boolean = false
}
```

（`Authenticator`/`Identity` 的实际接口成员以 `neton-security/Authenticator.kt:19` 与
`neton.core.interfaces.Identity` 为准；Identity 若为接口含更多成员，按 MockIdentity 的实现面补齐。）

- [ ] **Step 3: GatewaySecurityConfig（完整代码）**

对照 privchat 的 order=-10 前置模式与 newgate `config/SecurityConfig.kt`：

```kotlin
package config

import logic.TokenLogic
import neton.core.component.NetonContext
import neton.core.config.NetonConfig
import neton.core.config.NetonConfigurer
import neton.core.interfaces.SecurityBuilder
import security.GatewayTokenAuthenticator

/** gateway 组安全接线：sk- 令牌认证器，不影响 admin/app 组的 JWT 体系。 */
@NetonConfig("security", order = 10)
class GatewaySecurityConfig : NetonConfigurer<SecurityBuilder> {
    override fun configure(ctx: NetonContext, target: SecurityBuilder) {
        val tokenLogic = ctx.get(TokenLogic::class)
        target.setGroupAuthenticator("gateway", GatewayTokenAuthenticator(tokenLogic))
    }
}
```

（`ctx.get(TokenLogic::class)` 的取法以 @Logic 装配后的实际获取方式为准——grep
module-member 的 configurer 如何取 Logic；若 Logic 不入 ctx，则在此直接构造
`TokenLogic(ctx.get(LoggerFactory::class).get("logic.gateway-token"))`。）

- [ ] **Step 4: 第一个 gateway 端点 /v1/models（完整代码）**

```kotlin
package controller.gateway

import kotlinx.serialization.Serializable
import neton.core.annotations.Controller
import neton.core.annotations.Get

@Serializable
data class ModelEntry(val id: String, val `object`: String = "model", val owned_by: String = "newgate")

@Serializable
data class ModelsResponse(val `object`: String = "list", val data: List<ModelEntry>)

/** OpenAI 兼容 /v1/models。M1b 接入定价/渠道后按令牌过滤，这里先返回空表打通链路。 */
@Controller("/v1/models")
class ModelsController {
    @Get("")
    suspend fun list(): ModelsResponse = ModelsResponse(data = emptyList())
}
```

注意：gateway 组响应**不走 envelope**——本端点直接返回值会被引擎包 envelope，
需按 M0 约定用 `ctx.response`（`json()` 直写）绕过；执行时改为：

```kotlin
@Controller("/v1/models")
class ModelsController {
    @Get("")
    suspend fun list(ctx: neton.core.http.HttpContext) {
        ctx.response.json("""{"object":"list","data":[]}""")
    }
}
```

（handler 参数注入 HttpContext 的写法以 RoutingDsl.kt:21 注释确认的上下文能力为准；
若注解式 controller 不支持注入 HttpContext 参数，grep module-system 里已有 controller
的用法；实在不支持则此端点暂时接受 envelope，M1b 统一处理裸响应问题并记录。）

- [ ] **Step 5: 端到端冒烟**

需要可用数据库（SQLite 零配置路径）：

```bash
cd /Users/zoujiaqing/projects/NewGate/newgate
# 按 README SQLite 初始化流程建库（system/infra/member/payment/gateway 各 V001）
./gradlew :application:linkDebugExecutableMacosArm64
cd application && ./build/bin/macosArm64/debugExecutable/application.kexe &
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/v1/models          # 期望 401（无令牌）
# 用 admin API 造一个令牌（或直接 SQL 插入已知哈希），然后：
curl -s -H "Authorization: Bearer sk-<明文>" http://localhost:8080/v1/models      # 期望 200
```

Expected: 401 / 200 如上；`/admin/*`、`/app/*` 现有路由不受影响（登录冒烟一次）。

- [ ] **Step 6: Commit（gateway 仓 + newgate 仓）**

---

### Task 5: 额度台账 + 定价/分组/用量日志表

**Files:**（gateway 模块仓）
- Create: `model/QuotaAccount.kt`、`model/QuotaTransaction.kt`、`model/ModelPrice.kt`、`model/GatewayGroup.kt`、`model/UsageLog.kt` + 对应 `table/` facade（模式同 Task 2 Step 2，逐个新建）
- Create: `logic/QuotaLogic.kt`
- Create: `controller/admin/price/PriceController.kt`、`controller/admin/group/GroupController.kt`、`controller/admin/quota/QuotaController.kt`、`controller/admin/log/UsageLogController.kt`（CRUD 面，方法集与 Task 2 Step 5 的 ChannelController 同构：list/get/create/update/delete + Permission 码按 Global Constraints）
- Modify: `sql/postgresql/V001__create_tables.sql` 追加
- Test: `src/commonTest/kotlin/logic/QuotaLogicTest.kt`

**Interfaces:**
- Produces: `QuotaLogic.grant(userId, amount, ref)`、`QuotaLogic.consume(userId, amount, ref): Boolean`（余额不足返回 false，M1b 计费用）、`UsageLogTable`（M1b 写日志）

- [ ] **Step 1: model（完整代码，五个）**

```kotlin
package model

import kotlinx.serialization.Serializable
import neton.database.annotations.*

/** 额度账户（μUSD）。 */
@Serializable
@Table("gateway_quota_accounts")
data class QuotaAccount(
    @Id val id: Long = 0,
    val userId: Long,
    val balance: Long = 0,
    /** 乐观锁版本号：consume 用 balance+version 条件更新防并发超扣 */
    val version: Long = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)

/** 额度台账（审计，只增不改）。type: grant/consume/refund/redeem。 */
@Serializable
@Table("gateway_quota_transactions")
data class QuotaTransaction(
    @Id val id: Long = 0,
    val userId: Long,
    val type: String,
    val amount: Long,
    val balanceAfter: Long,
    /** 关联凭据：支付订单号 / usage_log id / 兑换码 */
    val ref: String? = null,
    @CreatedAt val createdAt: Long? = null,
)

/** 模型定价（官方价 + 售价覆盖，spec 决策 B2）。价格 DECIMAL 字符串，USD/1M tokens。 */
@Serializable
@Table("gateway_model_prices")
data class ModelPrice(
    @Id val id: Long = 0,
    val model: String,
    val inputPrice: String = "0",
    val outputPrice: String = "0",
    val cacheReadPrice: String = "0",
    val cacheWritePrice: String = "0",
    /** 按次计价（μUSD/次）；非 null 时 token 价格无效 */
    val perRequestPrice: Long? = null,
    /** 售价覆盖 JSON（空 = 官方价 × 全局加价率） */
    val saleOverride: String? = null,
    /** 价源：builtin/manual（litellm/openrouter 在 M3 加入） */
    val source: String = "manual",
    @SoftDelete val deleted: Int = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)

/** 用户分组倍率。 */
@Serializable
@Table("gateway_groups")
data class GatewayGroup(
    @Id val id: Long = 0,
    val name: String,
    /** 倍率 DECIMAL 字符串，如 "1.0"/"0.8" */
    val ratio: String = "1.0",
    val description: String? = null,
    @SoftDelete val deleted: Int = 0,
    @CreatedAt val createdAt: Long? = null,
    @UpdatedAt val updatedAt: Long? = null,
)

/** 逐请求用量日志（收入/成本双记，支撑毛利看板）。 */
@Serializable
@Table("gateway_usage_logs")
data class UsageLog(
    @Id val id: Long = 0,
    val userId: Long,
    val tokenId: Long,
    val channelId: Long,
    val requestModel: String,
    val upstreamModel: String,
    val promptTokens: Int = 0,
    val completionTokens: Int = 0,
    val cacheReadTokens: Int = 0,
    val cacheWriteTokens: Int = 0,
    /** 收入 μUSD（按售价） */
    val charged: Long = 0,
    /** 成本 μUSD（官方价 × 渠道折扣） */
    val cost: Long = 0,
    val ttfbMs: Long? = null,
    val latencyMs: Long? = null,
    /** 1=流式 */
    val stream: Int = 0,
    /** ok/error/partial */
    val status: String = "ok",
    val errorCode: String? = null,
    @CreatedAt val createdAt: Long? = null,
)
```

- [ ] **Step 2: SQL 追加（完整）**

```sql
CREATE TABLE gateway_quota_accounts (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    balance BIGINT NOT NULL DEFAULT 0,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);
CREATE UNIQUE INDEX uk_gateway_quota_accounts_user ON gateway_quota_accounts(user_id);

CREATE TABLE gateway_quota_transactions (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    type VARCHAR(16) NOT NULL,
    amount BIGINT NOT NULL,
    balance_after BIGINT NOT NULL,
    ref VARCHAR(128),
    created_at BIGINT
);
CREATE INDEX idx_gateway_quota_tx_user ON gateway_quota_transactions(user_id, created_at);

CREATE TABLE gateway_model_prices (
    id BIGSERIAL PRIMARY KEY,
    model VARCHAR(128) NOT NULL,
    input_price DECIMAL(20,6) NOT NULL DEFAULT 0,
    output_price DECIMAL(20,6) NOT NULL DEFAULT 0,
    cache_read_price DECIMAL(20,6) NOT NULL DEFAULT 0,
    cache_write_price DECIMAL(20,6) NOT NULL DEFAULT 0,
    per_request_price BIGINT,
    sale_override TEXT,
    source VARCHAR(16) NOT NULL DEFAULT 'manual',
    deleted INT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);
CREATE UNIQUE INDEX uk_gateway_model_prices_model ON gateway_model_prices(model) WHERE deleted = 0;

CREATE TABLE gateway_groups (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    ratio DECIMAL(10,4) NOT NULL DEFAULT 1.0,
    description VARCHAR(256),
    deleted INT NOT NULL DEFAULT 0,
    created_at BIGINT,
    updated_at BIGINT
);

CREATE TABLE gateway_usage_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    token_id BIGINT NOT NULL,
    channel_id BIGINT NOT NULL,
    request_model VARCHAR(128) NOT NULL,
    upstream_model VARCHAR(128) NOT NULL,
    prompt_tokens INT NOT NULL DEFAULT 0,
    completion_tokens INT NOT NULL DEFAULT 0,
    cache_read_tokens INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    charged BIGINT NOT NULL DEFAULT 0,
    cost BIGINT NOT NULL DEFAULT 0,
    ttfb_ms BIGINT,
    latency_ms BIGINT,
    stream INT NOT NULL DEFAULT 0,
    status VARCHAR(16) NOT NULL DEFAULT 'ok',
    error_code VARCHAR(64),
    created_at BIGINT
);
CREATE INDEX idx_gateway_usage_logs_user ON gateway_usage_logs(user_id, created_at);
CREATE INDEX idx_gateway_usage_logs_channel ON gateway_usage_logs(channel_id, created_at);

-- 种子：默认分组
INSERT INTO gateway_groups (name, ratio, description, created_at) VALUES ('default', 1.0, '默认分组', 0);
```

- [ ] **Step 3: QuotaLogic 失败测试（计费不变量）**

```kotlin
package logic

import kotlin.test.Test
import kotlin.test.assertEquals

class QuotaLogicTest {
    @Test
    fun consumeMathNeverGoesNegative() {
        // 纯函数：扣减决策（DB 原子性由条件更新保证，决策逻辑单测）
        assertEquals(700L, QuotaLogic.balanceAfterConsume(balance = 1000, amount = 300))
        assertEquals(null, QuotaLogic.balanceAfterConsume(balance = 200, amount = 300)) // 不足
        assertEquals(0L, QuotaLogic.balanceAfterConsume(balance = 300, amount = 300))
    }

    @Test
    fun grantAccumulates() {
        assertEquals(1300L, QuotaLogic.balanceAfterGrant(balance = 1000, amount = 300))
    }
}
```

- [ ] **Step 4: QuotaLogic 实现（完整代码）**

```kotlin
package logic

import model.QuotaAccount
import model.QuotaTransaction
import neton.database.dsl.*
import neton.logging.Logger
import table.QuotaAccountTable
import table.QuotaTransactionTable

@neton.core.annotations.Logic(logger = "logic.gateway-quota")
class QuotaLogic(private val log: Logger) {

    suspend fun account(userId: Long): QuotaAccount =
        QuotaAccountTable.oneWhere { QuotaAccount::userId eq userId }
            ?: QuotaAccountTable.insert(QuotaAccount(userId = userId))

    suspend fun grant(userId: Long, amount: Long, type: String = "grant", ref: String? = null): Long {
        require(amount > 0) { "grant amount must be positive" }
        val acc = account(userId)
        val newBalance = balanceAfterGrant(acc.balance, amount)
        QuotaAccountTable.update(acc.copy(balance = newBalance, version = acc.version + 1))
        QuotaTransactionTable.insert(
            QuotaTransaction(userId = userId, type = type, amount = amount, balanceAfter = newBalance, ref = ref)
        )
        return newBalance
    }

    /**
     * 扣减：余额不足返回 false。并发安全依赖「重读-条件更新-重试」：
     * update 时带 version 条件，失败则重读重试（最多 3 次）。
     * （若 Table DSL 不支持条件更新，执行时先实现 whereUpdate 或退化为单写者约束并在 M1b 网关内串行化同一用户的扣减。）
     */
    suspend fun consume(userId: Long, amount: Long, ref: String?): Boolean {
        require(amount >= 0) { "consume amount must be >= 0" }
        if (amount == 0L) return true
        repeat(3) {
            val acc = account(userId)
            val newBalance = balanceAfterConsume(acc.balance, amount) ?: return false
            val updated = QuotaAccountTable.updateWhere(
                acc.copy(balance = newBalance, version = acc.version + 1)
            ) { QuotaAccount::version eq acc.version }
            if (updated > 0) {
                QuotaTransactionTable.insert(
                    QuotaTransaction(userId = userId, type = "consume", amount = -amount, balanceAfter = newBalance, ref = ref)
                )
                return true
            }
        }
        log.warn("quota consume contention user=$userId amount=$amount")
        return false
    }

    companion object {
        fun balanceAfterGrant(balance: Long, amount: Long): Long = balance + amount
        fun balanceAfterConsume(balance: Long, amount: Long): Long? =
            if (balance < amount) null else balance - amount
    }
}
```

（`updateWhere` 若 DSL 无此方法：本任务内在 neton-database 补最小条件更新 API 或按注释降级方案执行并在 SPEC.md 记录。）

- [ ] **Step 5: 四个 admin controller（方法集同构 ChannelController）**

PriceController（`/gateway/price`：list/get/create/update/delete，DTO 字段=ModelPrice 全字段减 id/时间戳）、
GroupController（`/gateway/group`）、
QuotaController（`/gateway/quota`：`GET /get-by-user/{userId}` 返回账户、`POST /grant`{userId,amount,ref} 调 QuotaLogic.grant、`GET /transactions/{userId}` 台账列表）、
UsageLogController（`/gateway/log`：`GET /list-by-user/{userId}`、`GET /list-by-channel/{channelId}`，只读）。
代码结构、注解、Permission 码逐一比照 Task 2 Step 5（每个文件 40-70 行，无新模式）。

- [ ] **Step 6: 测试 + 聚合编译 + Commit**

```bash
./gradlew macosArm64Test
cd /Users/zoujiaqing/projects/NewGate/newgate && ./gradlew :application:compileKotlinMacosArm64
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway
git add -A && git commit -m "feat: 额度台账(乐观锁扣减)/定价/分组/用量日志"
```

---

### Task 6: 三方言 SQL 补齐 + SPEC.md + 收口

**Files:**
- Create: `sql/mysql/V001__create_tables.sql`、`sql/sqlite/V001__create_tables.sql`
- Create: `SPEC.md`（正文）
- Test: SQLite 全量建表冒烟

- [ ] **Step 1: 方言转换**

以 PostgreSQL V001 为源，逐表转换（规则固定）：
- MySQL：`BIGSERIAL PRIMARY KEY` → `BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY`；`TEXT` 保持；部分索引 `WHERE deleted = 0` → 去掉 WHERE（改普通唯一索引 + 逻辑层保证）；表尾加 `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`
- SQLite：`BIGSERIAL PRIMARY KEY` → `INTEGER PRIMARY KEY AUTOINCREMENT`；`DECIMAL(x,y)` → `NUMERIC`；`VARCHAR(n)` → `TEXT`；部分索引同 MySQL 处理
- 两方言文件必须**逐表完整写出**（不引用 pg 文件），表/列名与 pg 完全一致

- [ ] **Step 2: SQLite 冒烟**

```bash
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway
sqlite3 /tmp/gateway-smoke.db < sql/sqlite/V001__create_tables.sql
sqlite3 /tmp/gateway-smoke.db ".tables" | tr ' ' '\n' | grep -c gateway_
```
Expected: `8`

- [ ] **Step 3: SPEC.md**

写模块规范：资源清单（8 表字段语义）、权限码表、金额/价格单位纪律（μUSD/DECIMAL 字符串）、
令牌哈希纪律、与 member（userId 来源）/payment（充值 grant 的 ref=订单号）边界、
M1b 将消费的接口（`TokenLogic.verify`、`ChannelLogic.pickKey`、`QuotaLogic.consume`、`UsageLogTable`）。

- [ ] **Step 4: 全量验证 + Commit**

```bash
./gradlew macosArm64Test && cd /Users/zoujiaqing/projects/NewGate/newgate && ./gradlew :application:compileKotlinMacosArm64
cd /Users/zoujiaqing/projects/Neton/neton-application-module-gateway && git add -A && git commit -m "docs: SPEC + 三方言迁移脚本"
```

---

## Self-Review 记录

- **Spec 覆盖**：spec §6 表清单中 M1 范围的 8 张全覆盖（channels/channel_keys/tokens/model_prices/groups/quota_accounts/quota_transactions/usage_logs）；price_sources/revisions→M3、redemptions→M4，已在头部标注。TokenGuard=Task 4（spec §2.2）；决策 B（μUSD 台账）/B2（成本折扣+双记日志）/F（哈希令牌）落地于 Task 3/5
- **占位符**：Task 5 Step 5 四个 controller 以「方法集同构 + 每资源差异字段已在 model 定义」描述而未逐一展开代码——差异内容（字段/路径/权限码）均已在本计划内给出，模式代码在 Task 2 Step 5 完整可抄；接受此折衷
- **已知不确定点（均给了在场判定规则而非 TBD）**：DSL 列表查询方法名（Task 2 Step 4）、条件更新 updateWhere（Task 5 Step 4 含降级方案）、HttpContext 参数注入（Task 4 Step 4 含降级方案）、Logic 从 ctx 获取方式（Task 4 Step 3）
- **类型一致性**：`TokenLogic.verify/issue`、`ChannelLogic.pickKey`、`QuotaLogic.consume/grant` 的签名在 Interfaces 块与实现代码一致；μUSD 全部 Long
