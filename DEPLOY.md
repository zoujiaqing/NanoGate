# NewGate 部署

单机 Docker 部署。PostgreSQL 与 Redis 都在 compose 内，不需要另外准备数据库。

## 依赖仓库布局

镜像用 Gradle composite build，构建上下文必须能看到同级的框架与模块仓库：

```
projects/
├── neton/                              # 框架
├── neton-application-module-member/
├── neton-application-module-payment/
├── neton-application-module-platform/
├── neton-application-module-gateway/
└── NewGate/
    ├── newgate/                        # 应用（Dockerfile 在此）
    └── docker-compose.yml
```

## 启动

```bash
cd NewGate
cp .env.example .env
# 填写 POSTGRES_PASSWORD、JWT_SECRET、CHANNEL_KEY_ENC_KEY（见下）
docker compose up -d
```

迁移作为独立的一次性服务先跑完，成功后才启动网关——迁移失败时不会有服务在半套 schema 上接流量。

## 必须设置的密钥

| 变量 | 生成方式 | 不设置的后果 |
|---|---|---|
| `POSTGRES_PASSWORD` | 自定 | compose 直接报错，不会用弱口令启动 |
| `JWT_SECRET` | `openssl rand -base64 48` | 同上；用默认值等于管理台可被任意签发令牌 |
| `CHANNEL_KEY_ENC_KEY` | `openssl rand -base64 32` | 渠道 API Key 明文入库，**数据库泄露 = 你采购的所有上游 Key 泄露** |

`CHANNEL_KEY_ENC_KEY` 可以后补：配置后新写入的 Key 会加密，存量明文仍可读，无需停机迁移。
但请尽早配置，并把它与数据库备份分开保管——两者放在一起等于没加密。

## 上线前检查

- [ ] 三个密钥都已设置，且不是示例值
- [ ] 数据库端口未对公网暴露（compose 默认只 `expose` 不 `ports`）
- [ ] 网关放在 TLS 终止层之后（本服务不处理证书）
- [ ] 为令牌设置 RPM / TPM / 并发上限——不限意味着单个用户就能打爆你的上游配额与成本
- [ ] 模型定价已配置：**未配定价的模型会被拒绝**（宁可拒绝也不免费放行）
- [ ] 按 token 计价的模型配了「默认输出上限」，否则请求必须自带 `max_tokens`
- [ ] 定期查看管理台「结算待处理」：这些记录仍占用用户预留额度，需人工裁定

## 反向代理

网关自身不终止 TLS。前置 Nginx/Caddy 时请注意：

- 转发 `X-Forwarded-For`——令牌 IP 白名单依赖它，且该头**可被伪造**，
  必须同时在网络层限制只有可信代理能连到网关；
- 流式响应需关闭代理缓冲（Nginx：`proxy_buffering off;`），否则 SSE 会被攒着一次性吐出。

## 升级

```bash
git -C .. pull --rebase   # 各依赖仓库同理
docker compose build
docker compose up -d
```

迁移脚本一旦应用到保留数据库即冻结，升级只会追加新脚本，不会改写已应用的脚本。

## 数据库

只支持 **PostgreSQL**。交付形态固定为本 compose，因此不承担多方言成本；
`sql/mysql/` 冻结在 V003，不作为支持目标。
