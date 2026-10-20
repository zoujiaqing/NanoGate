# NetonAPI 部署

单机 Docker 部署。PostgreSQL 与 Redis 都在 compose 内，不需要另外准备数据库。
（产品曾用名 NewGate；外层目录名 `NewGate/` 是本地布局名，暂不随改名变动。三个子仓库目录与 GitHub 仓库同名：`netonapi-backend/`、`netonapi-frontend/`、`netonapi-client/`。）

## 依赖仓库布局

镜像用 Gradle composite build，`netonapi-backend/settings.gradle.kts` 里写死了 `../../Neton/<repo>`：
本仓必须正好在那层目录的**两层深处**，框架与六个 canonical 模块必须落在同层的 `Neton/` 下。
外层目录名（`Neton`、`NewGate`）也是契约的一部分——`netonapi-backend/Dockerfile` 的 `COPY` 源同样写死了它们。

```
projects/
├── Neton/
│   ├── neton/                              # 框架（includeBuild）
│   ├── geolite4k/                          # GeoIP（includeBuild）
│   ├── neton-application-module-system/
│   ├── neton-application-module-infra/
│   ├── neton-application-module-account/
│   ├── neton-application-module-member/
│   ├── neton-application-module-payment/
│   ├── neton-application-module-platform/
│   ├── neton-application-module-gateway/   # NetonAPI 的核心模块
│   ├── neton-application-front/            # 管理台基础包（前端镜像需要）
│   ├── neton-application-front-{system,infra,account,member,payment,platform,gateway}/
│   └── neton-application-client-{gateway,member,payment}/   # 控制台模块
└── NewGate/                                # 本仓（含 docker-compose.yml）
    ├── netonapi-backend/                            # 后端发行版（Dockerfile 在此）
    ├── netonapi-frontend/                      # 管理台
    └── netonapi-client/                     # 用户控制台
```

> ⚠️ 八个仓里有六个是公开的（`netonframework/neton`、`netonframework/geolite4k`、
> `neton-application/neton-application-module-{system,member,payment,platform}`），但
> **`neton-application-module-infra` 与 `neton-application-module-gateway` 目前是私有仓**。
> 没有这两个仓的读权限就 clone 不全、也就构建不出镜像；它们转公开之前，本仓的公开只是
> 「源码可读」，不是「人人可自建」。前端同理（见各自 README）。

> ⚠️ 下文 Docker 路径**尚未在实机验证过**（修正时的开发机上 Docker daemon 未运行）。
> 两个前端镜像（`netonapi-frontend/Dockerfile`、`netonapi-client/Dockerfile`）与 Caddy 边缘同样**未实机构建过**，
> 写法照后端镜像的上下文约定推导；首次 `docker compose build` 请当作待验证项。
> `COPY` 布局是按 `settings.gradle.kts` 的路径推导修正的，此前它既漏了三个必需仓、
> 又把应用放在了 `../../Neton` 解不到的深度。首次 `docker compose build` 请当作待验证项，
> 失败时先看是不是布局问题。

## 本机开发（不经 Docker）

三个端口：后端 `8800`、用户控制台 `8880`、管理台 `8888`。

```bash
# 后端：编译后用一份本地配置目录起（database.conf 指向本机 PostgreSQL，redis.conf 指向本机 Redis）
cd NewGate/netonapi-backend && ./gradlew :application:linkDebugExecutableMacosArm64 -Pneton.database.driver=postgres
cd ../local && ../netonapi-backend/application/build/bin/macosArm64/debugExecutable/application.kexe migrate up
NETON_SECURITY__JWT__SECRETKEY=<随便一串> NETONAPI_QUOTA_PER_PRICE_UNIT=10000 NETONAPI_PUBLIC_API_URL=http://localhost:8800 \
  ../netonapi-backend/application/build/bin/macosArm64/debugExecutable/application.kexe
# 管理台（next dev -p 8888；开发模式把 /admin /app /v1 … 重写到本机后端，所以不需要 Caddy）
cd NewGate/netonapi-frontend && pnpm dev
# 控制台（next dev -p 8880；apps/console/.env.development 已指向 http://localhost:8800）
cd NewGate/netonapi-client && pnpm dev
```

管理员种子账号 `admin / admin123`（上线前改掉）。harness 也用 8800，本机跑着后端时用
`NETONAPI_HARNESS_PORT=8801 ./harness/run.sh` 让它换端口。

## 启动

```bash
cd NewGate
cp .env.example .env
# 填写 POSTGRES_PASSWORD、JWT_SECRET、CHANNEL_KEY_ENC_KEY（见下）
docker compose up -d
```

迁移作为独立的一次性服务先跑完，成功后才启动网关——迁移失败时不会有服务在半套 schema 上接流量。

起来之后有三个入口：

| 地址 | 是什么 |
|---|---|
| `http://localhost:8888` | **管理台**，同源承载 API（`/admin` `/app` `/v1` …由 Caddy 分流到后端） |
| `http://localhost:8880` | **用户控制台**（注册 / 登录 / API Key / 用量 / 充值） |
| `http://localhost:8800` | 后端直连，**仅调试**：不经 Caddy，`X-Forwarded-For` 一律不信 |

API 客户端（OpenAI / Anthropic / Gemini SDK）的 base URL 用 `8888`（生产用 `ADMIN_SITE` 域名）。

## 必须设置的密钥

| 变量 | 生成方式 | 不设置的后果 |
|---|---|---|
| `POSTGRES_PASSWORD` | 自定 | compose 直接报错，不会用弱口令启动 |
| `JWT_SECRET` | `openssl rand -base64 48` | 同上；用默认值等于管理台可被任意签发令牌 |
| `CHANNEL_KEY_ENC_KEY` | `openssl rand -base64 32` | 渠道 API Key 明文入库，**数据库泄露 = 你采购的所有上游 Key 泄露** |
| `MFA_MASTER_KEY` | `openssl rand -base64 32` | 不能给管理员开启 MFA（开了的人登不进来）。**有人绑定过之后不能更换**，换了所有已绑定的动态码失效，只能逐个重置 |

`CHANNEL_KEY_ENC_KEY` 可以后补：配置后新写入的 Key 会加密，存量明文仍可读，无需停机迁移。
但请尽早配置，并把它与数据库备份分开保管——两者放在一起等于没加密。

## 管理员 MFA 与管理台 IP 白名单

**人机验证**：在 Cloudflare Turnstile 建一个站点，secret key 设为 `CAPTCHA_SECRET`（容器内 `NETON_CAPTCHA_SECRET`），
然后在管理台「配置管理」打开 `system.security.captcha.enabled`、填 `system.security.captcha.site_key`，
`system.security.captcha.actions` 选需要验证的动作（默认 `register,send_code`：注册与匿名发短信/邮件验证码；
还可加 `login` 用户登录、`admin_login` 管理员登录）。凭证由后端向 Turnstile 核验，并核对它是为哪个动作签发的；
开了开关却没配 secret、或 Turnstile 不可达时，这些动作返回 503 而不是放行。大陆网络访问 Turnstile 不稳定，
面向大陆用户时先实测登录注册页能否加载组件。

**MFA**：设置 `MFA_MASTER_KEY` 后，在管理台「用户管理」里把某个管理员设为必须 MFA（`PUT /admin/system/user/mfa/{id}`）。
设置后他已有的会话立即失效；下次用密码登录只拿到一次性挑战，首次要用认证器 App 绑定，之后每次输入 6 位动态码，同一个码不能重复使用。
丢了手机由其他管理员重置（`POST /admin/system/user/mfa/{id}/reset`，需要「重置密码」权限）。

**白名单**：`ADMIN_IP_ALLOWLIST_ENABLED=true` 加 `ADMIN_IP_ALLOWLIST=你的出口IP或网段`，限制的是整个 `/admin` 路由组，
包括登录接口，判定发生在认证、限流之前。上线前先确认 `RATELIMIT_TRUSTED_PROXIES` 指向你的反向代理
（compose 默认是 caddy 与控制台的 `172.28.0.10,172.28.0.11`，裸机部署是 `127.0.0.1,::1`），并在日志 `rateLimit.initialized` 里看到
`trustedProxies` 不为 0——否则后端看到的来源全是代理自己，白名单会把所有人挡在外面。
写错锁住了管理台，只能登服务器改配置重启，没有远程绕过接口。配置变更都需要重启。

## 定价与毛利

计价是**双轨**的，两轨都固化在每笔请求的定价快照里，事后可逐笔核算毛利：

| 轨道 | 公式 | 落到哪 |
|---|---|---|
| 售价（收入） | 官方价 × 加价率（本模型单独设的优先，否则全站加价率），或逐项填的固定售价；再 × 用户所在分组的倍率 | 用户扣款 `charged` |
| 成本 | **实际打给上游的模型**的官方价 × 渠道 `cost_discount`（渠道做了模型映射时按映射目标算，映射目标没定价则按请求模型） | 结算行与用量日志的 `cost`，不动用户余额 |

完整规则见 [`netonapi-backend/docs/gateway-pricing-spec.md`](./netonapi-backend/docs/gateway-pricing-spec.md)。

日常调价都在管理台「AI 网关 → 模型定价」一页完成：

- **全站加价率、最低毛利**在「配置管理」的 `gateway.pricing.markup` / `gateway.pricing.min_margin`，改完 10 秒内生效。
  没改过时沿用环境变量 `SALE_MARKUP` / `MIN_MARGIN`（再没有就是 1）。
- **售价方式**每个模型三选一：跟随全站加价率（大多数模型）、本模型单独的加价率、逐项填固定售价。
  只改官方价不会动售价设置。
- **定价体检**：列表直接显示每个模型在所有实际会发生的「分组 × 渠道」组合里最差的毛利，亏本标红、低于最低毛利标黄。
  VIP 分组倍率 < 1、渠道折扣 > 1、渠道把模型映射成别的上游模型，这些保存价格时看不到的亏法都会在这里暴露；
  点「查看问题组合」能看到是哪个分组、哪条渠道、哪一项（输入/输出/缓存）。
- **校准官方价**：从价源（默认 LiteLLM 公开价目表，也可换 OpenRouter 或自定义地址，见 `gateway.pricing.source_*`）拉最新官方价，
  逐个列出涨跌幅；渠道已承载但还没定价的模型作为「可新增」列出。勾选后应用，没勾的不动。
- **调价记录**：新增、修改、导入、同步、校准、删除都记一笔（谁、何时、从多少改成多少），在每行的「调价记录」里看。
- **批量导入**：「批量导入」接受每行 `model 输入价 输出价 [缓存读 缓存写]` 或 JSON（数组，或 `{"gpt-4o":{"input":2.5,"output":10}}`）。
  按 model 去重后逐条 upsert；**有一条不合法整批不写**并按行号报错；取消「覆盖已有」则只补新模型。
- **毛利闸门**：售价任一项低于「官方价 × 最低毛利」时不能保存。导入、同步、校准时，写死售价的模型如果新官方价会让它亏本，
  这一行会被扣下不写（结果里列出），等运营调完售价再同步。
- **不同等级的用户不同价**：在「计价分组」里建分组并设倍率（如 VIP 0.9），再用以下任一方式把用户放进去，优先级从高到低：
  令牌的专属分组（令牌页「设置分组」）→ 用户例外（「用户计价例外」页）→ 会员组映射（分组里选会员组，需 `NETONAPI_MEMBER_GROUP_BILLING=true`）→ `default`。
  渠道的 `groups` 决定哪些分组能走它，体检只核算真会发生的组合。
- **事后看账**：概览页按分组、渠道列出收入、成本、毛利；统计期内有实收低于成本的请求时顶部标红，并给出亏损金额。
- 定价数据非法（价格串坏、`sale_override` 不是合法 JSON、倍率配错）时请求在入口就被拒
  （`500 model_pricing_invalid`），不会带着坏价进入结算；已在途请求的快照损坏则保留预留转人工复核。

## 收款与获客

下面几条都是「不配就不可用」，而**启动检查不会拦** —— 它只覆盖密钥与数据库，
钱的功能是等到第一个用户用到时才失败（而且失败往往在用户那边，不在你的日志监控里）。
但「响不响」各不相同，各小节写明自己那一条的查法：邀请奖励与支付回调地址会在启动日志里
念一遍生效值，而充值汇率不会（它只在用户下单那一刻 error）—— 后者只能靠下面的上线前检查表。

### 充值：`QUOTA_PER_PRICE_UNIT`（不设 = 收不到钱）

每 1 单位 `pay_orders.price`（法币最小单位，如「分」）发多少 μUSD 额度（1 USD = 1000000 μUSD）。

**不设的后果是充值功能整个不可用**：用户每次下单都拿到 `500 quota recharge is not configured`。
这是有意的设计 —— 静默按 1:1 发放等于白送钱，而且不会留下任何日志痕迹，所以账务宁可拒绝也不猜汇率。
没有普适默认值：它取决于你按什么币种定价、以及你想让「1 元」对应多少额度。

额度由服务端按这个汇率算出，**不接受客户端指定** —— 客户端能同时填 price 与 amount 就等于自己给自己定价。

控制台「充值与流水」页的在线充值走的就是这条：读 `GET /app/pay/channel/list`（运营在管理台
管理台「支付中心 → 支付渠道」里启用的渠道）→ 用户选渠道、填金额（元）→ `POST /app/gateway/recharge`
→ 按渠道的 `displayMode` 处理：`REDIRECT_URL` 新窗口打开收银台，`QR_CODE` 页内画码，`SDK_PARAMS`
原样展示参数 → 每 2 秒轮询 `GET /app/gateway/recharge/get/{id}` 直到已支付，然后刷新余额。
轮询最多 10 分钟，超时只是不再等，回调到账不受影响。**没有启用任何渠道时该卡片只显示提示**，
用户只能走兑换码 —— 所以上线前先在管理台把渠道配好并用沙箱渠道走一遍。

### 支付回调地址：`PAY_NOTIFY_BASE` / `PAY_RETURN_URL`（要收真钱就得设）

两项都必须是**公网可访问的绝对地址**：

| 变量（容器内） | 含义 |
|---|---|
| `PAY_NOTIFY_BASE`（`NETONAPI_PAY_NOTIFY_BASE`） | 后端对外的 origin，即反向代理那个。渠道服务器要能从它打到 `{基址}/app/pay/channel-notify/{渠道码}` |
| `PAY_RETURN_URL`（`NETONAPI_PAY_RETURN_URL`） | 用户付完跳回的控制台页面，例如 `https://console.example.com/billing` |

**两项留空都不会让支付失败**，但各自退化一处，互不牵连：

- `PAY_NOTIFY_BASE` 空 → 渠道不主动回调，到账靠 `pay-order-reconcile` 定时任务主动查单兜底
  （`*/10 * * * *`，默认启用）。延迟是**十来分钟**而不是整十分钟：任务十分钟一轮，且刚下单
  2 分钟内的单会被跳过（那时用户可能还在付款页上，查了也只会得到「未支付」，白费一次渠道调用）。
- `PAY_RETURN_URL` 空 → 用户付完停在渠道自己的页面上回不来，控制台那套「跳出去 → 回来看到
  已到账」的体验不成立。**这一项与渠道回不回调无关**，别把它当成到账问题去查。

启动日志里这两行各说各的后果（logger `payment.callback-url`），不会互相借词。

⚠️ **别把兜底那条路也关掉**：`pay-order-reconcile` 在后台定时任务页可以停用（`infra_jobs` 是运行期
调度真源，代码 `@Job` 只定义 handler）。它被停用、而 `PAY_NOTIFY_BASE` 又没配的话，两条到账路径
同时断掉 —— **钱会到账，额度永远不发**：用户只看到「付了钱没额度」，运维只看到订单一直待支付，
两边都看不出原因。启动时会为这个组合打一行 ERROR 点名是哪两条；但它**只在启动时查一次**，
运行期在后台停用不会重新检查 —— 所以停用那个任务前，先确认回调基址已经配了。

⚠️ 别填容器内部地址（`http://localhost:8800`、`http://netonapi:8800`）：本地跑得通，
上线后一律回调失败，而失败发生在渠道那一侧 —— 你的日志里只会看到订单一直是待支付。

漏写 `https://` 之类的非法值**不会**被静默当成没配：按未配置处理并记 ERROR。
理由是两者后果不同：没配只是慢十来分钟，而一个不带 scheme 的地址会被渠道判成非法参数，
那是**连单都下不了**。

生效值与状态在启动日志里（INFO=已生效 / WARN=未配置 / ERROR=配置非法或两条到账路径全断）：
`grep "payment.callback-url"`。回调地址与路由共用同一个常量（`channel/PayNotifyRoute.kt`），
所以「发出去的地址」与「实际注册的路由」不可能各说各话。

### 邀请奖励：`INVITE_REWARD_INVITER` / `INVITE_REWARD_INVITEE`

邀请达成时给邀请人 / 被邀请人各发一笔网关额度（μUSD）。留空或 `0` = 该角色不发奖。

- **默认不发**。发钱的路径不该因为一次升级就自己打开，要开必须显式配置。
- 非法值（`1e3`、`-5`、带单位的串）**不会**被静默当成 0：该角色不发奖并记 ERROR，
  另一个角色照常发。理由是「运营以为活动已上线、客服按活动口径答复用户、而账上什么都没有」
  比不发奖糟得多。
- 生效值在启动日志里：`grep "invite reward attached"`。没配额度时每次邀请也会记一行
  `invite reward skipped`，用来区分「评估过而不发」与「链路没装配」—— 两者账面上完全一样。
- 幂等由台账 ref 钉住（`invite:{记录id}:inviter` / `:invitee`），所以补发不会二次入账；
  补发入口 `POST /admin/member/invite-code/retry-invite-reward/{recordId}`（需 `member:invite-code:update`）。
  该接口返回 200 只代表事件已重放，**不代表已到账**，到账与否要去台账按 ref 查。
- **已知边界**：挡得住「绑自己的码」，挡不住「同一个人注册多个账号互邀」—— 那需要设备/IP 指纹
  与人工审核。开启前请知道自己是在一个可被刷的通道上发钱，并对邀请人的累计邀请数设告警。

### 兑换码

管理端批量生成、用户端兑换，无需环境变量。面额只由管理员指定，兑换时不接受客户端改写。
码体 20 字符 × 31 字符集 ≈ 99 bit，因此兑换接口没有额外限流；这条取舍由单测钉住
（缩短码长或缩小字符集会让测试红）。码外泄时用「整批作废」止损，它只影响未用的码 ——
已用的是历史事实，要收回已发放的额度请走管理端的额度调整另记一条台账。

## 渠道

八种类型：`openai_compatible`、`azure_openai`、`anthropic`、`gemini`、`bedrock`、`bedrock_converse`、`vertex_anthropic`、`vertex_gemini`。协议转换在网关内完成（实现在 neton-ai 协议层），
客户端用哪种协议进来都能打到任一类型的上游（错误体也会改写成客户端协议的形状，不会把
OpenAI 形状的错误原样塞给 Anthropic SDK）。

- **模型映射是双向的**：`{"gpt-4o":"my-deployment"}` 请求时把 model 改成上游的名字，响应
  （含流式每一块）再改回客户端请求的名字 —— 客户端看不到上游叫什么，SDK 按 model 做的缓存
  与统计也不会乱。用量日志里 `upstream_model` 记的仍是上游名，成本核算按它查。
- **Azure OpenAI**：鉴权走 `api-key` 头，路径为 `/openai/deployments/{部署名}/chat/completions?api-version=…`。
  Base URL 填资源地址（`https://xxx.openai.azure.com`），**部署名就是模型映射的目标名**，
  `api_version` 留空用代码默认值（当前 `2024-10-21`）。
- **测试连通**（渠道行菜单 / `POST /admin/gateway/channel/probe/{id}`）：用渠道自己的协议、代理、
  Key 打一条 `max_tokens=1` 的请求，把上游的状态码、耗时与原话带回来。不计费、不写用量日志、
  不动 Key 的失败计数。配完渠道先点它，别等第一个客户替你发现 Key 填错了。
- **拉取模型**（同菜单 / `POST /admin/gateway/channel/models/{id}`）：从上游列出模型 id
  （Azure 列的是部署名），确认后**并入**渠道的模型清单 —— 只追加不覆盖，运营挑过的清单不会被冲掉。
  很多 OpenAI 兼容站不实现 `/v1/models`，拉不到就手填。
- **AWS Bedrock**（类型 `bedrock`，Anthropic 模型）：Base URL 填 `https://bedrock-runtime.<region>.amazonaws.com`
  （region 从主机名推，也可在厂商参数里写 `{"region":"us-east-1"}`），渠道 Key 填 `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]`，
  模型映射的目标名就是 Bedrock 模型 id（如 `anthropic.claude-sonnet-4-20250514-v1:0`）。请求走 SigV4 签名，
  流式响应的 AWS event-stream 二进制帧由网关还原成标准 SSE。
- **Bedrock Converse**（类型 `bedrock_converse`，任意 Bedrock 模型：Nova、Llama、Mistral、Claude 等）：Base URL、Key、region
  与 `bedrock` 相同，模型映射的目标名是 Bedrock 模型 id（如 `amazon.nova-pro-v1:0`）。走 Converse 接口，网关负责协议转换。
- **Vertex AI**（类型 `vertex_anthropic` / `vertex_gemini`）：Base URL 填 `https://<location>-aiplatform.googleapis.com`，
  厂商参数必填 `{"project":"<gcp-project>","location":"us-east5"}`，渠道 Key 填服务账号 JSON 整段
  （网关用它换 OAuth token 并缓存到过期前）或直接填一枚 access token（调试用）。模型映射目标名即
  发布者模型 id（`claude-sonnet-4@20250514` / `gemini-2.5-pro`）。Bedrock 与 Vertex 类型没有模型列表接口，模型清单手填。
- **损耗策略**（`loss_policy`，默认 `allow`）：跨协议转换会丢东西时怎么办。`allow` 照常转发、诊断写应用日志；
  `safe` 在工具行为、内容或必要状态会变时（如 Anthropic 的 web_search 托管工具打到 OpenAI 系上游）跳过这个渠道、换下一个；
  `strict` 任何差异都跳过。涉及工具调用的渠道建议 `safe`。
- **推理尾缀**（`reasoning_suffix`，默认关）：开启后，客户端请求 `claude-sonnet-4-5-thinking-8000`、`gpt-5-high` 这类
  名字而没有渠道直接服务它时，按去掉尾缀的模型路由与计价，并把推理设置写进请求。
- **`/v1/responses`** 也能打非 OpenAI 渠道，但只限无状态请求：带 `previous_response_id`、`conversation`、
  `background` 或 OpenAI 托管工具的请求只走 OpenAI 渠道。
- Base URL 与代理地址写入时做 SSRF 校验，见「上游地址与 SSRF」。

## 端点能力

渠道除了「支持哪些模型」，还要声明「能服务哪些端点」（管理台渠道表单的**端点能力**，即 `gateway_channels.capabilities`）：

| 能力 | 覆盖端点 |
|---|---|
| `chat` | `/v1/chat/completions`、`/v1/responses`（仅 OpenAI 兼容 / Azure 渠道参与路由）、`/v1/messages`、Gemini `:generateContent` |
| `embeddings` | `/v1/embeddings`、Gemini `:embedContent` / `:batchEmbedContents` |
| `rerank` | `/v1/rerank`（Jina / Cohere 形状，仅 OpenAI 兼容渠道）。上游 usage 只有 `total_tokens` 时全部按输入计价 |
| `audio` | `/v1/audio/speech`（JSON 进、音频二进制出，按 `input` 字符数计「输入价」，即每百万字符的价）、`/v1/audio/transcriptions` 与 `/v1/audio/translations`（multipart 原样透传，只改写 `model`；`response_format=text` 时按上游的 text/plain 回）。转写模型上游多半不给 usage，定价填「按次」；gpt-4o-transcribe 这类给 usage 的按 token 计 |
| `images` | `/v1/images/generations`（仅 OpenAI 兼容 / Azure 渠道）。DALL·E 这类响应没有 usage，定价里必须填「按次」；gpt-image-1 按 token 计价的填 token 价并配「默认输出上限」 |

- 默认只有 `chat`。**升级后确实提供向量的渠道必须补上 `embeddings`**，否则该端点会明确回 `404 model_not_found`——
  宁可报错，也不把向量请求送进 chat 上游、再用上游的 404 来发现配错（那时钱已预留、日志已脏、重试已撞三遍）。
- 模型名命中但没有对应能力的渠道不会被选中：不预留资金、不调上游、不产生错误日志。
- 无候选时的状态码区分「稍后可能可用」（无启用渠道 / 全部在 429 冷却 → `503`）与
  「配置不变就永远不会可用」（模型没配 / 能力没声明 / 分组不通 → `404`），日志会写明卡在哪一环。

## 上线前检查

- [ ] 产品环境变量一律用 `NETONAPI_*` 前缀（2026-10-20 起，原 `NEWGATE_*`）。环境里还有任何 `NEWGATE_` 开头的变量时后端拒绝启动，并列出每个要改成的新名字
- [ ] 三个密钥都已设置，且不是示例值
- [ ] 数据库端口未对公网暴露（compose 默认只 `expose` 不 `ports`）
- [ ] 网关放在 TLS 终止层之后（本服务不处理证书）
- [ ] 前置反代时已设 `RATELIMIT_TRUSTED_PROXIES`（容器内为 `NETON_ROUTING__RATELIMIT__TRUSTED_PROXIES`），否则限流与令牌 IP 白名单看到的都是代理自己的地址
- [ ] 验证码全站日上限按短信预算设置（`NETON_SECURITY__VERIFICATION__DAILY_LIMIT_GLOBAL`，默认 1000 条/天/通道；0 = 不限，被刷时账单没有上限）
- [ ] 数据库每天备份并同步到另一台机器或对象存储，且**做过一次恢复演练**（见「备份与恢复」）
- [ ] 告警已接通：`netonapi-watch.timer` 在跑、webhook 收到过测试消息，另有外部拨测打 `/health`（见「可观测性」）
- [ ] 多实例部署共用同一个 Redis，否则限流上限被放大到实例数倍
- [ ] 网关容器的出网已收敛（云元数据服务与内网不可达）——写入时 SSRF 校验挡不住 DNS 重绑定
- [ ] 为令牌设置 RPM / TPM / 并发上限——不限意味着单个用户就能打爆你的上游配额与成本
- [ ] 模型定价已配置：**未配定价的模型会被拒绝**（宁可拒绝也不免费放行）
- [ ] 要收钱就设 `QUOTA_PER_PRICE_UNIT`：**不设则充值功能整个不可用**（用户每次下单都拿到 500）
- [ ] 要收真钱就设 `PAY_NOTIFY_BASE` / `PAY_RETURN_URL`（**公网**绝对地址，不是容器内部地址）：
      不设则渠道不回调，到账慢十来分钟、且用户付完回不到你的页面；启动日志 `grep "payment.callback-url"` 能确认生效值
- [ ] 没设 `PAY_NOTIFY_BASE` 的话，**别停用**后台的 `pay-order-reconcile` 任务：两条到账路径全断 = 钱到账了额度永远不发
- [ ] 要开邀请奖励就设 `INVITE_REWARD_INVITER` / `INVITE_REWARD_INVITEE`（默认不发；启动日志会念一遍生效值）
- [ ] 售价与毛利符合经营策略：`SALE_MARKUP` / `MIN_MARGIN` 已设置（默认不加价、不许亏本卖）
- [ ] 按 token 计价的模型配了「默认输出上限」，否则请求必须自带 `max_tokens`
- [ ] 提供向量的渠道已声明 `embeddings` 能力（默认只有 `chat`，未声明的端点会 404）
- [ ] 每条渠道都点过「测试连通」；Azure 渠道的模型映射目标是部署名、`api_version` 与你的资源匹配
- [ ] 管理台「支付中心 → 支付渠道」里至少启用了一条真实渠道（编码业务唯一、填好平台编码与商户凭据 JSON），
      并用沙箱渠道把「下单 → 付款 → 到账」走通过一次
- [ ] 定期查看管理台「结算待处理」：这些记录仍占用用户预留额度，需人工裁定
- [ ] 生产已设 `ADMIN_SITE` / `CONSOLE_SITE` 域名并叠加 `deploy/docker-compose.prod.yml`；别把 `8800` 直连口暴露到公网
- [ ] 已设 `PUBLIC_API_URL`（容器内 `NETONAPI_PUBLIC_API_URL`），否则控制台的接入说明只能显示占位符
- [ ] 控制台已开放**自助注册**（`/register`，无需邀请码）：不想开放注册就在反代层挡掉该路径，或要求邀请码

## 前端镜像与边缘（Caddy）

两个前端各有一个 Dockerfile，构建约定与后端镜像相同（父目录上下文、镜像内复刻宿主布局），
但**只 COPY 显式子路径**——各仓本地 85–480M 的 `node_modules` 不会进入构建上下文，也就不需要无法版本化的父目录 `.dockerignore`。
需要 BuildKit（Docker ≥ 23 默认）。

`deploy/Caddyfile` 不是可选项。管理台在浏览器里**直连**后端并靠 cookie 认证，而后端 CORS 硬编码
`allowedOrigins=*` + `allowCredentials=false`（`Main.kt`，改它要重新编译）——跨源时浏览器不会带 cookie，
所以管理台和 API **必须同源**，Caddy 按路径分流：

| 路径 | 去向 |
|---|---|
| `/admin/*` `/app/*` `/manage/*` `/platform/order*` `/v1/*` `/v1beta/*` | 后端 `netonapi:8800`（SSE 关闭缓冲） |
| 其余（含管理台自己的 `/platform/api` 等页面） | 管理台 `front:3000` |
| `CONSOLE_SITE` 整站 | 控制台 `console:3000`（它自带 `/api/backend` 服务端代理，不直连） |

Caddy 与控制台在 compose 默认网络里固定为 `172.28.0.10` / `172.28.0.11`，后端 `NETON_ROUTING__RATELIMIT__TRUSTED_PROXIES`
默认只信它们——控制台的服务端代理原样透传 Caddy 写入的 `X-Forwarded-For`，所以登录限流、令牌 IP 白名单拿到的
都是真实客户端地址，而直连 `8800` 的请求伪造转发头也无效。
后端 `/health`（匿名，DB 能应答才 200）与两个前端镜像都自带 HEALTHCHECK，compose 的 `depends_on` 一律用 `service_healthy`。

生产：`.env` 填 `ADMIN_SITE` / `CONSOLE_SITE` 为域名，并叠加 `deploy/docker-compose.prod.yml` 发布 80/443，Caddy 自动签发证书。

## 邮件通道

两种发信方式，管理台「邮箱账号」里选：
- **SMTP**：任意邮箱（企业邮箱 / QQ / 163 / Gmail 应用密码）。465 选 SSL，587 选 STARTTLS，
  两者都关是明文（只适合内网中继）。发信走系统 libcurl（macOS 自带；Linux 镜像的 `curl` 包自带
  libcurl4，构建阶段装 `libcurl4-openssl-dev`），证书按系统信任链校验。Windows 构建没有系统 libcurl，
  只支持明文 SMTP，请改用厂商 HTTP 接口。
- **厂商 HTTP 接口**：Resend / SendGrid / Mailgun / Brevo / 自定义 HTTP（POST JSON
  `{from, fromName, to[], subject, text, html}`，`Authorization: Bearer <apiKey>`）。填发件邮箱、API Key（Mailgun 还要接口地址）。

用途：控制台「找回密码」（`/forgot-password`，只对绑定过邮箱的账号生效，未知邮箱不发信也不报错）、
个人资料页「绑定邮箱」、管理台按模板发信。验证码邮件默认文案可被模板 `mail_verification_bind_email` /
`mail_verification_reset_password` 覆盖（模板正文第一行写 `Subject: …` 作主题，正文含 HTML 标签即按 HTML 发）。
没配邮箱账号时验证码只落邮件日志（`[DEV] code=…`），方便本地联调。

## 管理台角色与菜单

种子库自带四个角色，覆盖中转站的常见分工。粒度按「这个岗位要点哪些按钮」定，不按模块切：

| 角色 | code | 能做什么 | 刻意不给 |
|---|---|---|---|
| 网关运营 | `gateway_ops` | 上游渠道增删改、测试连通、拉模型、API 令牌、用量日志、会员只读 | 定价与财务 |
| 财务 | `finance` | 模型定价、计价组与用户例外、兑换码、结算复核、额度发放撤回、支付订单与钱包 | 上游渠道配置 |
| 客服 | `support` | 用量日志、额度发放与撤回（客诉补偿）、令牌与兑换码只读、会员与订单只读 | 任何配置类写操作 |

补充：财务角色额外拿到「支付渠道」的增删改 —— 配收款通道是充值链路的前提，不配就收不到钱。
| 只读 | `readonly` | 业务三组（网关 / 会员 / 支付）全部页面只读 | 一切写操作、系统管理、基础设施 |

在「系统管理 → 用户管理」建账号后，到「角色管理」里勾一个角色即可，不必再逐条勾菜单。
超级管理员（`admin`）绕过权限校验，**上线前务必改掉它的默认密码**，日常操作用上面四个角色。

侧栏只保留与本产品相关的 38 个页面：AI 网关排第一组，其后是会员中心、支付中心、系统管理、基础设施。
开放平台、会员签到 / 积分 / 等级 / 标签 / 分组、转账 / 提现 / 钱包冻结、文件管理、站内信、社交用户
这些继承自通用脚手架的页面已停用（`system_menus.status = 0`）。**要用回它们不需要改代码**：
在「系统管理 → 菜单管理」里把对应行改成启用即可；开放平台还需要把 `front-platform` 加回
`netonapi-frontend/apps/shell/front.modules.ts`。

## 可观测性（最小集）

- `GET /metrics`：Prometheus 文本格式，数字从库里现算（与概览页同口径）：按状态的请求总数与近 5 分钟数、
  收入/成本累计（μUSD）、每条渠道的状态与最近测速、待人工复核与待重放的结算数。默认匿名；设
  `NETONAPI_METRICS_TOKEN` 后要求 `Authorization: Bearer <token>`。生产请设 token 或在反代层只放行监控网段。
- 定时任务（后台「定时任务」页可停用/改 cron）：
  - `gateway-channel-probe`（`*/5 * * * *`）：用渠道自己的 Key 打一条 `max_tokens=1` 的请求，结果写在渠道行
    （管理台渠道表「测速」列、概览渠道表、`/metrics` 都能看到）。每条渠道每 5 分钟消耗一次最小请求。
  - `gateway-price-sync`（每天 03:10）：从 `NETONAPI_PRICE_SYNC_URL` 拉价目表导入（格式与管理台批量导入一致），
    `NETONAPI_PRICE_SYNC_OVERWRITE=false` 则只补新模型。管理台「模型定价 → 同步价源」可立即拉一次。

**告警**：没有 Prometheus 时用 `deploy/monitor/netonapi-watch.sh`（systemd 定时器每分钟跑），出事向
`WATCH_ALERT_WEBHOOK` 发 `{"text": "..."}`：`/health` 不是 200、有结算进入人工复核、启用中的渠道测速全部失败、
26 小时内没有新备份。每项独立去重 —— 变坏报一次、持续坏每 6 小时提醒、恢复报一次，不会每分钟轰炸。

```bash
install -m 755 deploy/monitor/netonapi-watch.sh /usr/local/bin/
install -m 644 deploy/monitor/netonapi-watch.{service,timer} /etc/systemd/system/
cat > /etc/netonapi/watch.env <<'ENV'
NETONAPI_URL=http://127.0.0.1:8800
WATCH_ALERT_WEBHOOK=https://...
# NETONAPI_METRICS_TOKEN=...      与 NETONAPI_METRICS_TOKEN 相同
# BACKUP_DIR=/data/backups/netonapi
ENV
systemctl daemon-reload && systemctl enable --now netonapi-watch.timer
```

它跑在网关同一台机器上，机器整个宕掉时发不出告警 —— 外加一个外部拨测（云监控、UptimeRobot 之类）打 `/health`。

日志里还能看这几样：

| 看什么 | 在哪 |
|---|---|
| 每个 HTTP 请求（方法/路径/状态/耗时） | `logs/access.log`，框架 `http.access` 行，同时异步落库 |
| 每次中转的**结算摘要**：模型、渠道、token 数、收入 `charged`、成本 `cost`、首字节/总耗时、结果 | `logs/all.log` 里的 `settlement.finalized` 行（结构化字段，JSON 日志可直接按字段聚合）；预留被释放的请求是 `settlement.released` |
| 错误与告警 | `logs/error.log`（`ERROR,WARN`） |
| 存活/就绪 | `GET /health`：`200 {"status":"ok"}`；数据库不可达 `503 {"status":"degraded"}` |

成本曲线、渠道故障率、单用户消耗这些运营视图，现阶段就是对 `settlement.finalized` 行做聚合——
它写在结算事务提交之后，worker 重放的结算也会打，所以与账本一一对应。

## 反向代理

网关自身不终止 TLS。前置 Nginx/Caddy 时请注意：

- 流式响应需关闭代理缓冲（Nginx：`proxy_buffering off;`），否则 SSE 会被攒着一次性吐出。
- **`NETON_ROUTING__RATELIMIT__TRUSTED_PROXIES`（`routing.conf` `[ratelimit] trusted_proxies`）决定后端认哪个地址是「客户端」**，
  路由限流、管理台白名单、令牌 IP 白名单、审计 IP 都建在它上面：

  | 配置 | 后端认定的客户端 IP | 后果 |
  |---|---|---|
  | 未设置（默认） | TCP 对端地址（= 你的反代） | `X-Forwarded-For` / `X-Real-IP` **一律忽略**。伪造转发头绕不过白名单，但所有用户共用代理这一个身份：限流全站一个桶，白名单要么全过、要么全不过 |
  | `127.0.0.1,::1` | 从 `X-Forwarded-For` **最右**往左剥掉每一跳可信代理，停在第一个不可信地址 | 才是真实客户端 IP |

  格式：逗号分隔的精确 IP（不支持 CIDR）。`X-Real-IP` 始终不采信。**空 = 谁都不信**，这是刻意的默认。
  多级代理要把每一跳都列进去，包括用户控制台（它的服务端代理替浏览器调后端）；只列最近一跳会让剥链提前停下。
- 为什么不能直接采信 `X-Forwarded-For`：它由客户端自由填写，直连网关时攻击者写什么就是什么；
  经反代时反代通常把真实对端**追加到链尾**，所以剥链必须从右往左、停在第一个不可信地址，
  客户端塞在链首的白名单 IP 一律不算数。
- 网络层仍建议只允许反代连到网关端口：不是为了防 IP 伪造（对端地址伪造不了，上面那条已经关掉），
  而是为了让 TLS / WAF / 代理侧限流这些控制不被直连绕过。

## 上游地址与 SSRF（出站策略）

渠道的 `baseUrl` / `proxyUrl`、Vertex 服务账号 Key 里的 `token_uri` 都是管理员在后台录入的数据，决定网关往哪儿发请求；
配错（或被越权改）就等于把网关变成打内网的跳板。短信 / 邮件渠道的地址、支付渠道的网关地址同理。

**强制点在请求时。** 这些流量全部走受控出站客户端（neton-http `GuardedHttpClientProvider`）：每条新连接解析一次主机名，
**全部** A/AAAA 记录都必须是公网地址（IANA 特殊用途段一律拒：回环、RFC1918、CGNAT、链路本地含云元数据
`169.254.169.254`、IPv6 ULA / 链路本地、保留段，IPv4 映射 / NAT64 / 6to4 按内嵌的 IPv4 判断，`2130706433` 这类非规范写法直接拒），
端口必须在放行列表里（默认 80、443），然后**只连校验过的那个 IP**：校验与连接之间改 DNS（重绑定）挪不走连接，TLS 仍按原主机名
做 SNI 与证书校验。经代理时代理只会收到校验过的 IP（`CONNECT <ip>:443`，http 用指向 IP 的 absolute-form、`Host` 保留原主机），
代理地址本身也按同一规则校验。被拒的请求一个包都不发：转发换下一个候选渠道（不计 Key 失败，全部被拒时 `503 no_available_channel`，
消息里带机器码），探测 / 拉模型结果带 `errorCode`（`UPSTREAM_URL_PRIVATE_ADDRESS` / `UPSTREAM_URL_PORT_FORBIDDEN` /
`UPSTREAM_URL_UNRESOLVABLE` / `UPSTREAM_PROXY_FORBIDDEN`），日志搜 `relay target refused`。

写入时（新建 / 修改渠道、添加 Key）用**同一个**策略和同一个解析器先校验一遍，不过即 `400` 且不落库——那只是快速反馈，
直接写库的渠道同样在请求时被拦。

**放行内网上游只有一个口子：部署配置。** 自托管模型在 10.x、出口代理在内网时，在 `application.conf` 的 `[egress]`
（或环境变量）里放行，后台改不了它：

```toml
[egress]
allowed_ports = "80,443,8000"          # 默认 80,443
allowed_hosts = "vllm.internal"        # 主机名 / IP 字面量精确匹配：解析到哪、什么端口都放行
allowed_networks = "10.20.0.0/16"      # CIDR：这些网段放行（端口仍按 allowed_ports）
```

环境变量写法：`NETON_EGRESS__ALLOWED_NETWORKS=10.20.0.0/16`（compose 里对应 `EGRESS_ALLOWED_*`，见 `.env.example`）。
任一放行项非空时启动日志打 WARN `egress.allowlist.enabled`。旧的 `NETONAPI_ALLOW_PRIVATE_UPSTREAM` 已删除——它一刀关掉全部校验，
现在只能按网段 / 主机精确放行。

仍建议的部署侧措施：给网关容器只允许出公网 443/80 的网络策略，云上开 IMDSv2 并用安全组挡元数据服务。它们是纵深防御，
不再是唯一能覆盖重绑定的一层。

## Redis

- 单实例不配也能跑：限流退化为**进程内**计数，语义不变但不跨实例共享，
  N 个实例的实际放行量约为配置上限 × N。多实例部署必须共用同一个 Redis
  （默认的 compose 已内置 Redis，所以上面这条通常已经满足）。
- RPM / TPM / 并发计数走服务端 Lua 脚本（`INCRBY` 与 `EXPIRE` 一次执行）：并发下不丢增量，
  也不会因为进程在两条命令之间崩溃而留下永不过期的计数键。Redis 抖动时降级为进程内计数并告警，
  不会让请求整体失败。
- 与其他 Neton 应用共用 Redis 时用 `keyPrefix` 隔开命名空间；限流键形如
  `<prefix>:ngrl:rpm:<tokenId>:<分钟窗口>`，窗口键带 120s TTL 自动消失。
  本发行版**没附带** `config/redis.conf`（框架按「文件名 = 命名空间」可选加载，缺文件就走默认值），
  要设前缀有两条路：在 `netonapi-backend/application/config/` 下自建 `redis.conf`（根级平铺
  `keyPrefix = "netonapi"`，**不要**写 `[redis]` 段），或直接给环境变量 `NETON_REDIS__KEYPREFIX`。
- 别把网关和其他项目混在同一个 db 里再做 `flushdb`：harness 就是因此自带一个隔离实例
  （独立端口 + 独立 db + 独立 `keyPrefix` + 关持久化）。

## 裸机部署（不用 Docker）

首尔生产机就是这么装的（Rocky Linux 10，2C/4G）。要点：

- **后端在 macOS 上交叉编译**：机器太小跑不动 Kotlin/Native。装好 `messense/macos-cross-toolchains`
  的 `x86_64-unknown-linux-gnu` 后，从目标机拷一份 `/usr/lib64/libcurl.so.4` 到本地目录并建
  `libcurl.so` 软链，再
  `./gradlew :application:linkReleaseExecutableLinuxX64 -Pnetonapi.linuxX64.libDir=<该目录绝对路径>`
  （或环境变量 `NETONAPI_LINUX_X64_LIBDIR`）。头文件仓里已 vendor，只缺链接用的 so。
- **框架处于 WebSocket 集成阶段时**（框架 `gradle.properties` 里 `netonstream.local=true`），协议栈用
  `../../Neton` 下的兄弟目录源码，其中 tls 依赖的 openssl 4.0.2-3 尚未发布：所有 gradlew 命令都要加
  `-Pnetonstream.local.openssl=true`，改用本地 `openssl-kotlin` 源码。写进本仓 `gradle.properties` 不生效——
  根构建的属性传不到被 includeBuild 的框架 settings。openssl 发布后去掉。
  交叉编译 Linux 时还要加 `-PnativeTargets=macosArm64,linuxX64`：本地 openssl-kotlin 默认只编当前主机平台，
  不加则 linuxX64 解析不到 openssl。
- **运行时依赖**：EL10 要装 `libxcrypt-compat`（二进制链的是 `libcrypt.so.1`），否则启动即
  `libcrypt.so.1 => not found`。`ldd netonapi | grep "not found"` 应为空。
- **前端在目标机构建**：Node 24 + pnpm 11.20，按 Dockerfile 的布局把 `Neton/` 与 `NewGate/` 两层
  放到同一父目录下 `pnpm install --frozen-lockfile && pnpm --filter … build`；4G 内存要加 swap。
  构建产物目录可整体拷走（node_modules 里没有指出仓库的软链）。用 `next start -H 127.0.0.1` 起。
- **边缘**：Caddy 按域名分流——管理台域名下把 `/admin/* /app/* /manage/* /platform/*` 转后端（同源，
  理由见上节），控制台域名整站转控制台，API 域名只放行 `/v1/* /v1beta/* /health
  /app/pay/channel-notify/*`、其余 404。后端设 `NETON_ROUTING__RATELIMIT__TRUSTED_PROXIES=127.0.0.1,::1`，
  控制台只监听 `127.0.0.1`（它透传的 `X-Forwarded-For` 才可信）。
- **后端监听地址**：框架目前写死监听 `0.0.0.0`（`server.host` 不生效），8800 与 Next 的端口要靠
  防火墙挡。腾讯云这类机器上已有主机安全写的 iptables 规则，**别用 `nftables.service`**——它的
  stop/reload 会 `flush ruleset` 把别人的规则一起清掉；单独建一张 `inet` 表、用只增删这张表的
  oneshot 单元加载。
- **迁移**：systemd 单元里 `ExecStartPre=… migrate up`，迁移失败服务就不启动。

## 升级

```bash
git pull --rebase                       # 本仓（NewGate/，compose 与文档）
git -C netonapi-backend pull --rebase            # 后端发行版（嵌套仓，不归上面那条管）
for r in ../Neton/*/; do git -C "$r" pull --rebase; done   # 框架与各 canonical 模块
docker compose build
docker compose up -d
```

迁移脚本一旦应用到保留数据库即冻结，升级只会追加新脚本，不会改写已应用的脚本。

**beta1 是这条规则的唯一例外，而且打破得很彻底**：本发行版六个模块里有五个（gateway /
infra / member / payment / platform）把全部历史脚本按顺序拼成了一个 `V001__baseline.sql`，
原文件删除。所以 **beta1 之前建起来的库无法原地升级，只能重建**。引擎按 SHA-256 逐字节
比对（一字节变化即视为脚本变更），对已应用脚本的不一致直接 fail-fast：`migrate status`
退出码 3，正常启动的 precheck 在 `Neton.run` 之前就打 `STARTUP ABORTED` 并 `exitProcess(1)`，
不会绑定任何端口。一个停在 7 月的库跑出来是 `6 changed / 27 missing_on_disk / 4 pending`。

**不要靠改 `neton_schema_history` 的 checksum 来「重新盖章」过关**——那条路在本发行版会造出
一个能启动、但缺表的库，比拒绝启动糟得多。原因是 squash 之后**版本号槽位被复用**了：
gateway 的 `V002` 在 beta1 之前是 `seed_menus`（内容已并入 baseline），之后是
`group_billing_identity`（给 `gateway_groups` 加 `code` / `member_group_id`、建
`gateway_group_overrides`）。把 V002 的 checksum 盖成新值，等于宣称这份从没跑过的脚本已经
应用，引擎会跳过它：应用照常启动，然后在第一次查询 `gateway_groups.code` 时才炸。实测那个
7 月的库，`gateway_groups` 只有 id/name/ratio/description/deleted/created_at/updated_at，
而 `gateway_group_overrides`、`gateway_settlements`、`gateway_redemption_codes` 三张表不存在。

升级 beta1 之前的库，正确动作是重建；数据要留就先自己导出来（`gateway_channels` /
`gateway_tokens` / 钱包与订单表），迁移跑完再导回：

```bash
dropdb <dbname> && createdb <dbname>
./application.kexe migrate up     # 或交给 compose 里的一次性 migrate 服务
```

beta1 之后冻结规则重新生效：新增能力一律追加 V005、V006……，不再改写已应用的文件。

另注：`migrate status` 的 summary 只统计 executed / pending / changed / failed 四类，
`missing_on_disk` 不在其中，所以 `0 executed, 4 pending, 6 changed, 0 failed` 加不回 history
表的行数。判断状态要看逐行输出，别只看 summary。

## 数据库

只支持 **PostgreSQL**。交付形态固定为本 compose，因此不承担多方言成本。

`module-gateway` 是唯一同时带 `sql/mysql/` 与 `sql/sqlite/` 的模块（两边都已到 V004），
但这两方言**跑不起来**，也不是支持目标：其余模块（system / infra / member / payment /
platform / cs）的 `neton.migration.dialects` 都硬编码 `postgresql`，而 `system_users` /
`system_roles` / `system_menus` 只由 `module-infra` 的 postgresql V001 建。所以
`-Pneton.database.driver=mysql` 能编过、驱动也能连上，却会在 gateway 第一条碰
`system_menus` 的迁移上失败。本发行版从不设置 `neton.database.driver`（默认 postgres），
那两个目录里的 SQL 连编进二进制都不会。

三方言因此**不必保持同版本号**：postgresql 已到 V006，mysql 与 sqlite 停在 V004。差的这两版
（V005 网关权限菜单、V006 额度撤回菜单）改的正是 `system_menus`，而那两方言就算补齐也仍会在
第一条碰它的迁移上失败 —— 所以缺的这两版不是待还的债。

结论：改 schema **只需改 `sql/postgresql/`**。那两个目录是历史遗留，别照着它们补新脚本 ——
补齐了也跑不到，只会让人误以为 mysql 是支持目标。要真支持 mysql，得先给 infra 等模块
补方言（含 `system_menus` 的建表），那是一个独立的、比 gateway 大得多的工程。

## 备份与恢复

额度余额、充值与消费流水、令牌、渠道密钥（加密后）都在 PostgreSQL 里，丢了就是丢钱；Redis 只放限流计数、
验证码、会话吊销这类可丢的状态，不用备份。`deploy/backup/` 提供一个 `pg_dump` 脚本和 systemd 定时器：

- 自定义格式（`-Fc`）导出，先写 `.partial`，`pg_restore --list` 读得出目录才改名为正式备份 —— 截断的导出不会顶掉旧备份；
- 本地保留 `BACKUP_KEEP_DAYS` 天（默认 14），永远至少留最新一份；
- 设了 `BACKUP_RCLONE_REMOTE`（如腾讯云 COS 的 rclone 远端）就同步一份到异地，并按同样天数清理。**只放本机的备份不算备份**；
- 失败非零退出，设了 `BACKUP_ALERT_WEBHOOK` 时 POST `{"text": "..."}` 告警（Slack、企业微信、钉钉机器人都认）。

裸机安装：

```bash
install -m 755 deploy/backup/netonapi-backup.sh /usr/local/bin/
install -m 644 deploy/backup/netonapi-backup.{service,timer} /etc/systemd/system/
install -d -m 700 /etc/netonapi
cat > /etc/netonapi/backup.env <<'ENV'
PGHOST=127.0.0.1
PGUSER=netonapi
PGPASSWORD=...
PGDATABASE=netonapi
BACKUP_DIR=/data/backups/netonapi
# BACKUP_RCLONE_REMOTE=cos:netonapi-backup/db
# BACKUP_ALERT_WEBHOOK=https://...
ENV
chmod 600 /etc/netonapi/backup.env
systemctl daemon-reload && systemctl enable --now netonapi-backup.timer
systemctl start netonapi-backup.service && journalctl -u netonapi-backup -n 5   # 立刻跑一次确认
```

Docker 部署：在 `backup.env` 里设 `PG_DUMP="docker compose -f /path/to/docker-compose.yml exec -T postgres pg_dump -U <用户>"`
和对应的 `PG_RESTORE`，其余相同。

恢复（先在另一个库演练，确认数据对了再切）：

```bash
createdb netonapi_restore
pg_restore --no-owner -d netonapi_restore /data/backups/netonapi/netonapi-<时间>.dump
# 核对：SELECT count(*), sum(balance) FROM gateway_quota_accounts; 与线上量级一致
```

渠道密钥用 `CHANNEL_KEY_ENC_KEY` 加密存储：恢复到新机器时要带上同一个密钥，否则渠道全部解不开。密钥与备份分开保管。
