#!/usr/bin/env bash
# NanoGate 可靠性 harness：本机共享 PostgreSQL 上的「隔离测试数据库」+ 假上游 + 真实网关，逐场景自动断言。
# 一条命令：./harness/run.sh   失败即 exit 1，日志留 harness/logs/。
# 注意：这是「每次隔离一个临时 database」，不是「每次拉起隔离 PostgreSQL 实例」；库位置由
#   PGUSER/PGPASS/PGHOST/PGPORT 指定（默认本机 5432），其余端口是写死的：应用 7080、
#   fake 9920–9991、隔离 Redis 6399。CI 跑的是同一个脚本（postgres 用 service 容器，见
#   newgate/.github/workflows/backend-ci.yml）：一次性 runner 上写死端口不会撞，但本机并行跑
#   多份 harness 会（动态端口仍在 SPEC.md 末「待办」段）。
#   Redis 是「每次拉起一个独立实例」：开发机上 6379 往往有别的项目在用，绝不能往里写 harness 的键。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NEWGATE="$ROOT/newgate"
# 构建目标可覆盖：本机默认 macosArm64，CI（Linux）传 NEWGATE_TARGET=linuxX64
TARGET="${NEWGATE_TARGET:-macosArm64}"
LINK_TASK="${NEWGATE_LINK_TASK:-:application:linkDebugExecutable$(echo "${TARGET:0:1}" | tr '[:lower:]' '[:upper:]')${TARGET:1}}"
APP="$NEWGATE/application/build/bin/$TARGET/debugExecutable/application.kexe"
LOGS="$HERE/logs"; mkdir -p "$LOGS"
DB="newgate_harness_$$"
TOKEN_PLAINTEXT="sk-harness-token-000000000000000000000000000000000000"
TOKEN_HASH="$(python3 -c "import hashlib;print(hashlib.sha256('$TOKEN_PLAINTEXT'.encode()).hexdigest())")"
AUTH="Authorization: Bearer $TOKEN_PLAINTEXT"; CT="Content-Type: application/json"; U="http://localhost:7080"
PGUSER="${PGUSER:-$(whoami)}"; PGPASS="${PGPASS:-privchat}"; PGHOST="${PGHOST:-localhost}"; PGPORT="${PGPORT:-5432}"
# PGPORT 必须一起 export：createdb/dropdb/psql 与应用的 DSN 都靠它找库。写死 5432 等于假定
# 目标库一定在默认端口上（CI 的 postgres 服务容器、或本机跑在非默认端口的集群都不成立）。
export PGPASSWORD="$PGPASS" PGHOST PGPORT
PASS=0; FAIL=0; PIDS=()

# 清理：只终结本次 run 创建的进程（PIDS），逐个等待退出后再 drop 明确库名；不 pkill 全机同名进程。
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  # 明确库名 + --force（断开残留连接）；失败输出警告而非静默吞掉。
  if ! dropdb --if-exists --force -U "$PGUSER" "$DB" 2>/tmp/harness-drop-$$.err; then
    echo "  ⚠️  cleanup: dropdb '$DB' 失败：$(cat /tmp/harness-drop-$$.err 2>/dev/null)" >&2
  fi
  rm -f /tmp/harness-drop-$$.err
  # 确认库已不存在
  if [ "$(psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" 2>/dev/null)" = "1" ]; then
    echo "  ⚠️  cleanup: 数据库 '$DB' 仍存在，请手动 dropdb '$DB'" >&2
  fi
}
trap cleanup EXIT INT TERM

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
q() { psql -U "$PGUSER" -d "$DB" -tAc "$1" 2>/dev/null; }
# Redis 断言助手：只碰本次拉起的隔离实例的隔离 db。键名带 keyPrefix（配置里可变），
# 故一律用 *ngrl:* 通配匹配，不把前缀写死在断言里。
rc() { redis-cli -p "$REDIS_PORT" -n "$REDIS_DB" "$@" 2>/dev/null; }
rksum() { local k v s=0; for k in $(rc --scan --pattern "$1"); do v=$(rc get "$k"); s=$((s + ${v:-0})); done; echo "$s"; }
rkdel() { local k; for k in $(rc --scan --pattern "$1"); do rc del "$k" >/dev/null; done; }
seed_reset() { q "TRUNCATE gateway_channels,gateway_channel_keys,gateway_model_prices,gateway_usage_logs,gateway_quota_transactions,gateway_settlements RESTART IDENTITY;
  UPDATE gateway_quota_accounts SET balance=100000000, reserved_balance=0, version=version WHERE user_id=1;
  UPDATE gateway_tokens SET quota_used=0, quota_reserved=0, quota_budget=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null; }

fake() { MODE="$1" PORT="$2" python3 "$HERE/fakes.py" >/dev/null 2>&1 & PIDS+=($!); }

echo "═══ NanoGate 可靠性 harness (DB=$DB) ═══"

# ── 前置：编译 + 隔离库 + 迁移 + 基础令牌/账户 ──
echo "[build] linking app…"
( cd "$NEWGATE" && ./gradlew "$LINK_TASK" -q ) || { echo "build failed"; exit 1; }
createdb -U "$PGUSER" "$DB" || { echo "createdb failed"; exit 1; }
# 隔离 workdir：config/ 指向隔离库；app 与 migrate 都从此目录启动（config 相对 CWD 解析）
# 只保留最近 2 次运行的 work 目录，避免长期跑 harness 占满磁盘
ls -dt "$LOGS"/work-* 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null
WORK="$LOGS/work-$$"; mkdir -p "$WORK/config" "$WORK/logs"
cp "$NEWGATE/application/config/"*.conf "$WORK/config/"
cat > "$WORK/config/database.conf" <<EOF
[default]
driver = "POSTGRESQL"
uri = "postgresql://$PGUSER:$PGPASS@$PGHOST:$PGPORT/$DB"
debug = false
[migration]
history_table = "neton_schema_history"
EOF
# ── 隔离 Redis：限流计数是 S24 的断言对象，必须落在本 harness 独占的实例里 ──
# 不隔离的后果很实际：开发机 6379 的 db0 里混着别的项目的键（谁也不敢 flush），
# 而 harness 的 rpm/tpm 计数会被上一轮残留污染，断言变成看运气。
# 关持久化（--save '' --appendonly no）+ 数据目录放在 work 里，进程记进 PIDS 由 cleanup 收尾。
# 没装 redis-server 不让整个 harness 失败：网关会退化成进程内计数（单实例语义不变），
# 只有真正依赖 Redis 的 S24 显式跳过。
REDIS_PORT="${NEWGATE_REDIS_PORT:-6399}"; REDIS_DB=15; REDIS_OK=0
mkdir -p "$WORK/redis"
cat > "$WORK/config/redis.conf" <<EOF
host = "127.0.0.1"
port = $REDIS_PORT
database = $REDIS_DB
keyPrefix = "ngharness"
debug = false
EOF
if command -v redis-server >/dev/null 2>&1; then
  redis-server --port "$REDIS_PORT" --save '' --appendonly no --dir "$WORK/redis" >"$LOGS/redis.log" 2>&1 & PIDS+=($!)
  for i in $(seq 1 40); do redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG && { REDIS_OK=1; break; }; sleep 0.25; done
  [ "$REDIS_OK" = "1" ] || echo "  ⚠️  redis-server 10s 内未就绪（端口 $REDIS_PORT 被占？见 $LOGS/redis.log）；限流退化为进程内计数，S24 跳过" >&2
else
  echo "  ⚠️  未安装 redis-server（brew install redis）：限流退化为进程内计数，S24 跳过" >&2
fi
if ! ( cd "$WORK" && "$APP" migrate up >"$LOGS/migrate.log" 2>&1 ); then
  # NETON-DB-VARIANT mismatch 不是配置错，而是链接进二进制的 neton-database variant 陈旧：
  # link 任务可能判 UP-TO-DATE 而复用旧产物（kexe 里的字符串不是明文，无法直接取证）。
  # 不提示的话，这个错会被当成 database.conf 写错去查，白白耗掉很久。
  if grep -q 'NETON-DB-VARIANT' "$LOGS/migrate.log"; then
    echo "  ⚠️  variant 陈旧：重链一次即可 ——" >&2
    echo "     ( cd \"$NEWGATE\" && ./gradlew :application:clean && ./gradlew \"$LINK_TASK\" -Pneton.database.driver=postgres )" >&2
  fi
  echo "migrate failed, see $LOGS/migrate.log"; tail -3 "$LOGS/migrate.log"; exit 1
fi
# 基础令牌 + 账户（member 用户 id=1 由迁移种子提供；harness 直插 gateway 令牌）
q "INSERT INTO gateway_quota_accounts (user_id,balance,version,created_at,updated_at) VALUES (1,100000000,0,0,0) ON CONFLICT (user_id) DO UPDATE SET balance=100000000;
   INSERT INTO gateway_tokens (user_id,name,key_hash,key_display,status,deleted,created_at,updated_at) VALUES (1,'harness','$TOKEN_HASH','sk-harn****0000',1,0,0,0) ON CONFLICT (key_hash) DO NOTHING;" >/dev/null

# 网关启动/停止：boot_app 可带 env 覆盖（S22 验证全局加价率与毛利下限），故 APP_PID 单独记录以便中途重启。
APP_PID=""
boot_app() {
  ( cd "$WORK" && env "$@" "$APP" >"$LOGS/app.log" 2>&1 ) & APP_PID=$!; PIDS+=($!)
  ready=0; for i in $(seq 1 40); do curl -s --max-time 2 -o /dev/null "$U/" && { ready=1; break; }; sleep 0.5; done
  [ "$ready" = "1" ] || { echo "gateway 未就绪（20s 超时），见 $LOGS/app.log"; exit 1; }
}
stop_app() {
  [ -n "$APP_PID" ] || return 0
  pkill -P "$APP_PID" 2>/dev/null; kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
  # 端口必须真的空出来，否则新实例 bind 失败（表现为「未就绪」，误判成代码问题）
  # 不用 lsof/ss 探端口：前者 GitHub 的 ubuntu runner 不一定装（缺了就静默「立刻返回端口已空」），
  # 后者 macOS 没有。bash 内建的 /dev/tcp 两端都可用；连不上（ECONNREFUSED）即为端口已释放。
  for i in $(seq 1 20); do (exec 3<>"/dev/tcp/127.0.0.1/7080") 2>/dev/null || return 0; sleep 0.5; done
  echo "  ⚠️  端口 7080 仍被占用，重启网关可能失败" >&2
}
echo "[boot] starting gateway…"
boot_app

CID() { q "SELECT id FROM gateway_channels WHERE name='$1'"; }

# ══ S1 并发账务四项不变量 ══
echo "[S1] 并发结算四项不变量"
seed_reset; fake ok 9990; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-ok','openai_compatible','http://127.0.0.1:9990','default','m-ok',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-ok'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-ok','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
seq 1 20 | xargs -P 20 -I{} curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-ok","messages":[]}'
sleep 1
sc=$(q "SELECT COALESCE(SUM(charged),0) FROM gateway_usage_logs WHERE user_id=1")
sd=$(q "SELECT -COALESCE(SUM(amount),0) FROM gateway_quota_transactions WHERE user_id=1 AND type='consume'")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
tu=$(q "SELECT quota_used FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
[ "$sc" = "150000" ] && [ "$sc" = "$sd" ] && [ "$sc" = "$bd" ] && [ "$sc" = "$tu" ] \
  && pass "20 并发 → charged=$sc == debit=$sd == balanceΔ=$bd == quotaUsed=$tu" \
  || fail "四项不等: charged=$sc debit=$sd balanceΔ=$bd quotaUsed=$tu"

# ══ S2 dead→live 首字节前重试 ══
echo "[S2] dead→live 故障转移"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES
   ('dead','openai_compatible','http://127.0.0.1:9970','default','m-fo',9,1,1,3000,3000,'1.0',0,0,0),
   ('live','openai_compatible','http://127.0.0.1:9990','default','m-fo',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES
   ((SELECT id FROM gateway_channels WHERE name='dead'),'k',1,0,0,0,0),((SELECT id FROM gateway_channels WHERE name='live'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-fo','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
n=$(curl -sN --max-time 15 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-fo","stream":true,"messages":[]}' | grep -c "^data:")
[ "$n" -ge 3 ] && pass "流式 dead→live 重试成功（$n data 行）" || fail "流式重试失败（$n data 行）"

# ══ S3 非零断连真实扣款 + producer 无残留 ══
echo "[S3] 非零断连计费 + producer 无残留"
seed_reset; fake bigstream 9960; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('big','openai_compatible','http://127.0.0.1:9960','default','m-pr',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='big'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-pr','0','0','0','0',5000,5000,'manual',0,0,0);" >/dev/null
curl -sN --max-time 1 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-pr","stream":true,"messages":[]}' >/dev/null 2>&1; sleep 3
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-pr' ORDER BY id DESC LIMIT 1")
ta=$(q "SELECT -amount FROM gateway_quota_transactions WHERE ref LIKE 'settlement:%' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
tu=$(q "SELECT quota_used FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
[ "$lc" = "5000" ] && [ "$ta" = "5000" ] && [ "$bd" = "5000" ] && [ "$tu" = "5000" ] \
  && pass "断连真实扣款四项一致 charged=$lc == debit=$ta == balanceΔ=$bd == quotaUsed=$tu" \
  || fail "断连扣款不一致: charged=$lc debit=$ta balanceΔ=$bd quotaUsed=$tu"
# producer 无残留（强断言）：断连后网关应拆掉到上游的连接 → bigstream fake 在途计数归零。
# 泄漏的 producer 协程会继续读上游，使 handler 不退出、在途停在 >0。
inf=-1; for i in $(seq 1 30); do
  inf=$(curl -s --max-time 2 "http://127.0.0.1:9960/inflight" | python3 -c "import sys,json;print(json.load(sys.stdin).get('inflight',-1))" 2>/dev/null)
  [ "$inf" = "0" ] && break; sleep 0.5
done
[ "$inf" = "0" ] && pass "断连后上游在途归零（producer 已拆除，无残留）" || fail "producer 残留：上游 fake 在途=$inf"
# 复核：断连后服务端仍能立即服务新请求
fake ok 9991; sleep 1
q "UPDATE gateway_channels SET base_url='http://127.0.0.1:9991' WHERE name='big'; UPDATE gateway_model_prices SET per_request_price=NULL, input_price='1', output_price='1' WHERE model='m-pr';" >/dev/null
code=$(timeout 8 curl -s --max-time 8 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-pr","messages":[]}')
[ "$code" = "200" ] && pass "断连后服务端立即响应新请求（无 producer 挂起）" || fail "断连后服务端异常/挂起 code=$code"

# ══ S4 401/403 禁用 Key；429 不禁用 ══
echo "[S4] 401/403 禁用 / 429 不禁用"
seed_reset; fake err403 9950; fake err429 9940; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES
   ('c403','openai_compatible','http://127.0.0.1:9950','default','m-403',1,1,1,3000,3000,'1.0',0,0,0),
   ('c429','openai_compatible','http://127.0.0.1:9940','default','m-429',1,1,1,3000,3000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES
   ((SELECT id FROM gateway_channels WHERE name='c403'),'k',1,0,0,0,0),((SELECT id FROM gateway_channels WHERE name='c429'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-403','1','1','0','0',5000,'manual',0,0,0),('m-429','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
for i in 1 2 3 4 5; do curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-403","messages":[]}'; done
s403=$(q "SELECT status FROM gateway_channel_keys WHERE channel_id=$(CID c403)")
[ "$s403" = "2" ] && pass "403 连续失败 → Key 自动禁用(status=2)" || fail "403 未禁用 Key(status=$s403)"
for i in 1 2 3 4 5 6 7; do curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-429","messages":[]}'; done
s429=$(q "SELECT status FROM gateway_channel_keys WHERE channel_id=$(CID c429)")
[ "$s429" = "1" ] && pass "429 限流 → Key 保持可用(status=1)" || fail "429 误禁用 Key(status=$s429)"

# ══ S5 revive 保留手动禁用 ══
echo "[S5] revive 保留手动禁用"
seed_reset; fake err500 9930; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('rv','openai_compatible','http://127.0.0.1:9930','default','m-rv',1,1,1,3000,3000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES
   ((SELECT id FROM gateway_channels WHERE name='rv'),'auto',1,0,0,0,0),((SELECT id FROM gateway_channels WHERE name='rv'),'manual',0,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-rv','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
for i in 1 2 3 4 5; do curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-rv","messages":[]}'; done
JWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
curl -s --max-time 10 -o /dev/null -X PUT "$U/admin/gateway/channel/revive/$(CID rv)" -H "Authorization: Bearer $JWT"
sa=$(q "SELECT status FROM gateway_channel_keys WHERE channel_id=$(CID rv) AND api_key='auto'")
sm=$(q "SELECT status FROM gateway_channel_keys WHERE channel_id=$(CID rv) AND api_key='manual'")
[ "$sa" = "1" ] && [ "$sm" = "0" ] && pass "revive: auto 复位(1)、manual 保留(0)" || fail "revive 语义错: auto=$sa manual=$sm"

# ══ S6 token 中途删除 → 账户级三项一致 + warn ══
echo "[S6] token 中途删除"
seed_reset; fake bigstream 9920; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('td','openai_compatible','http://127.0.0.1:9920','default','m-td',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='td'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-td','0','0','0','0',5000,5000,'manual',0,0,0);" >/dev/null
b0=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
( curl -sN --max-time 2 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-td","stream":true,"messages":[]}' >/dev/null 2>&1 ) & CURL_PID=$!
sleep 0.6; q "DELETE FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'" >/dev/null; wait "$CURL_PID"; sleep 2
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-td' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT $b0-balance FROM gateway_quota_accounts WHERE user_id=1")
warn=$(grep -c "token deleted mid-request" "$WORK/logs/all.log")
[ -n "$lc" ] && [ "$lc" = "$bd" ] && [ "$warn" -ge 1 ] && pass "token 删后账户三项一致 charged=$lc balanceΔ=$bd + warn" || fail "token 删账务错: charged=$lc balanceΔ=$bd warn=$warn"
q "INSERT INTO gateway_tokens (user_id,name,key_hash,key_display,status,deleted,created_at,updated_at) VALUES (1,'harness','$TOKEN_HASH','sk-harn****0000',1,0,0,0) ON CONFLICT DO NOTHING" >/dev/null

# ══ S7 首建账户并发（唯一键竞态）══
# 删除账户制造"首建"：20 并发同一 user 首请求各自触发 account() 首建（RelayEngine 余额预检路径）。
# 修复前两个并发首建会各自 INSERT 撞 uk_gateway_quota_accounts_user 抛异常 → 500；
# 修复（ON CONFLICT DO NOTHING + 重读）后：账户表恰好 1 行、无 500 崩溃。
# 注：裸首建 balance=0，被 balance<=0 预检拒为 429（正确的后付费语义，需先授信）；计费四项不变量已由 S1 覆盖。
echo "[S7] 首建账户并发"
seed_reset; fake ok 9910; sleep 1
q "DELETE FROM gateway_quota_accounts WHERE user_id=1;
   INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-new','openai_compatible','http://127.0.0.1:9910','default','m-new',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-new'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-new','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
codes=$(seq 1 20 | xargs -P 20 -I{} curl -s --max-time 15 -o /dev/null -w "%{http_code}\n" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-new","messages":[]}')
rows=$(q "SELECT COUNT(*) FROM gateway_quota_accounts WHERE user_id=1")
n500=$(printf '%s\n' "$codes" | grep -c '^500')
nresp=$(printf '%s\n' "$codes" | grep -cE '^[0-9]{3}')
[ "$rows" = "1" ] && [ "$n500" = "0" ] && [ "$nresp" = "20" ] \
  && pass "并发首建账户唯一(rows=1)、无唯一键崩溃(500=0)、20 请求全部干净响应" \
  || fail "首建并发错: accountRows=${rows} http500=${n500} 响应数=${nresp} codes=$(printf '%s' "$codes" | tr '\n' ' ')"

# ══ S8 结算幂等（ref 唯一约束防重复扣费）══
echo "[S8] 结算幂等唯一约束"
seed_reset; fake ok 9900; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-idem','openai_compatible','http://127.0.0.1:9900','default','m-idem',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-idem'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-idem','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-idem","messages":[]}'; sleep 1
ref=$(q "SELECT ref FROM gateway_quota_transactions WHERE type='consume' ORDER BY id DESC LIMIT 1")
b1=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
# 重放：手动以同一 ref 再插一条台账 → 唯一约束应拒绝（模拟重试/outbox 重放不重复扣）
duperr=$(psql -U "$PGUSER" -d "$DB" -tAc "INSERT INTO gateway_quota_transactions (user_id,type,amount,balance_after,ref,created_at) VALUES (1,'consume',-9999,0,'$ref',0)" 2>&1)
cnt=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$ref'")
b2=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
{ echo "$duperr" | grep -qiE "duplicate|unique|uk_gateway_quota_tx_ref"; } && rejected=1 || rejected=0
[ -n "$ref" ] && [ "$rejected" = "1" ] && [ "$cnt" = "1" ] && [ "$b1" = "$b2" ] \
  && pass "重复 ref 被唯一约束拒绝(ref=$ref)、台账唯一(cnt=1)、余额不变" \
  || fail "幂等约束失效: ref=$ref rejected=$rejected cnt=$cnt bal=${b1}->${b2}"
# settlement 终态：FINALIZED + 预留归零（V004-durable-settlement-design 的核心不变量）
st=$(q "SELECT status FROM gateway_settlements ORDER BY id DESC LIMIT 1")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
qr=$(q "SELECT quota_reserved FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
[ "$st" = "FINALIZED" ] && [ "$rb" = "0" ] && [ "$qr" = "0" ] \
  && pass "settlement 终态 FINALIZED、预留归零(account=$rb token=$qr)" \
  || fail "settlement 终态错: status=$st reservedBalance=$rb quotaReserved=$qr"

# ══ S9 上游 midstream abort（真实 partial 语义）══
# 上游发 2 块后关连接、未发 [DONE] → 网关须判 PARTIAL：partial 日志、per-request 价四项账务一致、Key 计失败、
# 不伪造 [DONE]、上游在途归零、请求有限时间结束。
echo "[S9] 上游 midstream abort"
seed_reset; fake midabort 9901; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-mid','openai_compatible','http://127.0.0.1:9901','default','m-mid',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-mid'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-mid','0','0','0','0',3000,5000,'manual',0,0,0);" >/dev/null
t0=$(date +%s); resp=$(curl -sN --max-time 10 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-mid","stream":true,"messages":[]}' 2>/dev/null); t1=$(date +%s)
sleep 2
mchunks=$(printf '%s\n' "$resp" | grep -c "^data:")
fakedone=$(printf '%s\n' "$resp" | grep -c "\[DONE\]")
st=$(q "SELECT status FROM gateway_usage_logs WHERE request_model='m-mid' ORDER BY id DESC LIMIT 1")
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-mid' ORDER BY id DESC LIMIT 1")
ta=$(q "SELECT -amount FROM gateway_quota_transactions WHERE ref LIKE 'settlement:%' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
tu=$(q "SELECT quota_used FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
fc=$(q "SELECT fail_count FROM gateway_channel_keys WHERE channel_id=$(CID c-mid)")
inflight=$(curl -s --max-time 2 "http://127.0.0.1:9901/inflight" | python3 -c "import sys,json;print(json.load(sys.stdin).get('inflight',-1))" 2>/dev/null)
dur=$((t1 - t0))
[ "$mchunks" -ge 1 ] && [ "$fakedone" = "0" ] && [ "$st" = "partial" ] \
  && [ "$lc" = "3000" ] && [ "$lc" = "$ta" ] && [ "$lc" = "$bd" ] && [ "$lc" = "$tu" ] \
  && [ "$fc" -ge 1 ] && [ "$inflight" = "0" ] && [ "$dur" -le 10 ] \
  && pass "midstream partial: 收 ${mchunks} 块无伪造[DONE]、status=partial、四项=${lc} 一致、Key失败=${fc}、在途=0、${dur}s 结束" \
  || fail "midstream partial 异常: chunks=$mchunks 伪DONE=$fakedone status=$st charged=$lc ta=$ta bd=$bd tu=$tu keyFail=$fc inflight=$inflight dur=${dur}s"

# ══ S10 429 → 渠道 cooldown 退避并排除 ══
echo "[S10] 429 渠道 cooldown"
seed_reset; fake err429 9903; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,cooldown_until,deleted,created_at,updated_at) VALUES ('c-cd','openai_compatible','http://127.0.0.1:9903','default','m-cd',1,1,1,3000,3000,'1.0',0,0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-cd'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-cd','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
# 首请求：唯一渠道返回 429 → 无其它候选 → 503，但记录 cooldown
curl -s --max-time 10 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-cd","messages":[]}'; sleep 1
cd=$(q "SELECT cooldown_until FROM gateway_channels WHERE name='c-cd'")
# 冷却期内二次请求：该渠道被排除 → 候选为空 → 503 no_available_channel（且 Key 未被永久禁用）
code2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-cd","messages":[]}')
kstatus=$(q "SELECT status FROM gateway_channel_keys WHERE channel_id=$(CID c-cd)")
[ -n "$cd" ] && [ "$cd" -gt 0 ] && [ "$code2" = "503" ] && [ "$kstatus" = "1" ] \
  && pass "429 → 渠道 cooldown(until=$cd)、冷却期内被排除(503)、Key 未永久禁用(status=1)" \
  || fail "429 cooldown 异常: until=$cd 二次码=$code2 keyStatus=$kstatus"

# ══ S11 worker 恢复：FINALIZE_PENDING 重放（C3）══
echo "[S11] worker 重放 FINALIZE_PENDING"
seed_reset; fake ok 9890; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-wk','openai_compatible','http://127.0.0.1:9890','default','m-wk',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-wk'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-wk','0','0','0','0',7000,5000,'manual',0,0,0);" >/dev/null
# 模拟「usage 已落库但 finalize 未完成」：把已 FINALIZED 的记录退回 FINALIZE_PENDING 并撤销其账务效果
curl -s --max-time 15 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-wk","messages":[]}'; sleep 1
sid=$(q "SELECT settlement_id FROM gateway_settlements ORDER BY id DESC LIMIT 1")
q "DELETE FROM gateway_usage_logs; DELETE FROM gateway_quota_transactions;
   UPDATE gateway_quota_accounts SET balance=100000000, reserved_balance=7000 WHERE user_id=1;
   UPDATE gateway_tokens SET quota_used=0, quota_reserved=7000 WHERE key_hash='$TOKEN_HASH';
   UPDATE gateway_settlements SET status='FINALIZE_PENDING', lease_owner=NULL, lease_until=0, next_retry_at=0, attempts=0 WHERE settlement_id='$sid';" >/dev/null
JWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
tick=$(curl -s --max-time 15 -X POST "$U/admin/gateway/settlement/tick" -H "Authorization: Bearer $JWT" -H "$CT" -d '{}')
st=$(q "SELECT status FROM gateway_settlements WHERE settlement_id='$sid'")
lc=$(q "SELECT COALESCE(SUM(charged),0) FROM gateway_usage_logs")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
qr=$(q "SELECT quota_reserved FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
[ "$st" = "FINALIZED" ] && [ "$lc" = "7000" ] && [ "$bd" = "7000" ] && [ "$rb" = "0" ] && [ "$qr" = "0" ] \
  && pass "worker 重放 FINALIZE_PENDING → FINALIZED、补记 charged=${lc}、扣款=${bd}、预留归零" \
  || fail "worker 重放失败: status=$st charged=$lc balanceΔ=$bd reserved=$rb/$qr tick=$tick"
# 再 tick 一次必须幂等（不重复扣费）
curl -s --max-time 15 -o /dev/null -X POST "$U/admin/gateway/settlement/tick" -H "Authorization: Bearer $JWT" -H "$CT" -d '{}'
bd2=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$bd2" = "7000" ] && pass "worker 重复 tick 幂等（扣款仍=${bd2}）" || fail "worker 重复 tick 重复扣费: $bd -> $bd2"

# ══ S12 worker TTL：RESERVED 自动释放 / UPSTREAM_STARTED 转人工（C1、C2）══
echo "[S12] worker TTL 恢复"
seed_reset
q "INSERT INTO gateway_settlements (settlement_id,user_id,token_id,request_model,endpoint,status,reserved_amount,pricing_snapshot,created_at,updated_at)
   VALUES ('ttlreserved00000000000000000000',1,(SELECT id FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'),'m-x','/v1/chat/completions','RESERVED',4000,'{}',0,0),
          ('ttlstarted000000000000000000000',1,(SELECT id FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'),'m-x','/v1/chat/completions','UPSTREAM_STARTED',6000,'{}',0,0);
   UPDATE gateway_quota_accounts SET reserved_balance=10000 WHERE user_id=1;
   UPDATE gateway_tokens SET quota_reserved=10000 WHERE key_hash='$TOKEN_HASH';" >/dev/null
curl -s --max-time 15 -o /dev/null -X POST "$U/admin/gateway/settlement/tick" -H "Authorization: Bearer $JWT" -H "$CT" -d '{"reserveTtlMs":1,"upstreamTtlMs":1}'
s1=$(q "SELECT status FROM gateway_settlements WHERE settlement_id='ttlreserved00000000000000000000'")
s2=$(q "SELECT status FROM gateway_settlements WHERE settlement_id='ttlstarted000000000000000000000'")
ra=$(q "SELECT retry_action FROM gateway_settlements WHERE settlement_id='ttlstarted000000000000000000000'")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
bal=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
# RESERVED 释放 4000 → 剩 6000 仍被 UPSTREAM_STARTED 持有（不自动退款）；余额未被扣
[ "$s1" = "RELEASED" ] && [ "$s2" = "MANUAL_REVIEW" ] && [ "$ra" = "FINALIZE" ] && [ "$rb" = "6000" ] && [ "$bal" = "100000000" ] \
  && pass "TTL：RESERVED→RELEASED(释放4000)、UPSTREAM_STARTED→MANUAL_REVIEW(保留6000不退款)、余额未动" \
  || fail "TTL 恢复错: reserved=$s1 started=$s2 action=$ra 剩余预留=$rb 余额=$bal"

# ══ S13 速率限制 RPM ══
echo "[S13] 速率限制 RPM"
seed_reset; fake ok 9880; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-rl','openai_compatible','http://127.0.0.1:9880','default','m-rl',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-rl'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-rl','0','0','0','0',100,5000,'manual',0,0,0);
   UPDATE gateway_tokens SET rpm_limit=3 WHERE key_hash='${TOKEN_HASH}';" >/dev/null
codes=""
for i in 1 2 3 4 5; do
  c=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-rl","messages":[]}')
  codes="$codes $c"
done
n200=$(echo "$codes" | grep -o "200" | wc -l | tr -d ' ')
n429=$(echo "$codes" | grep -o "429" | wc -l | tr -d ' ')
lg=$(q "SELECT COUNT(*) FROM gateway_usage_logs")
q "UPDATE gateway_tokens SET rpm_limit=NULL WHERE key_hash='${TOKEN_HASH}';" >/dev/null
[ "$n200" = "3" ] && [ "$n429" = "2" ] && [ "$lg" = "3" ] \
  && pass "RPM=3：前 3 个 200、后 2 个 429、仅 3 条计费（被限流的不调上游）" \
  || fail "RPM 限流错: codes=${codes} 200=${n200} 429=${n429} 计费条数=${lg}"

# ══ S14 令牌 IP 白名单：X-Forwarded-For 信任边界 ══
# 白名单只能建立在**传输层对端**之上：XFF 由客户端自由填写，无条件采信最左项等于
# 「一个请求头就能把自己伪装成白名单里的 IP」——那比没有白名单更糟（它给运营者虚假的安全感）。
#  - A 段（默认：未配可信代理）→ 转发头一律忽略，伪造 XFF 必须被拒；
#  - B 段（NEWGATE_TRUSTED_PROXIES=127.0.0.1,::1，即 curl 的对端）→ 才采信 XFF，且从**右**往左剥链：
#    客户端自己塞在链首的白名单 IP 不算数（真实部署里反代会把客户端真实 IP 追加到链尾，
#    剥链必须停在第一个不可信地址）。
echo "[S14] IP 白名单 + XFF 信任边界"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-ip','openai_compatible','http://127.0.0.1:9880','default','m-ip',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-ip'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-ip','0','0','0','0',100,5000,'manual',0,0,0);
   UPDATE gateway_tokens SET allowed_ips='203.0.113.7' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
spoof=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 203.0.113.7" -d '{"model":"m-ip","messages":[]}')
plain=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-ip","messages":[]}')
lg=$(q "SELECT COUNT(*) FROM gateway_usage_logs")
[ "$spoof" = "403" ] && [ "$plain" = "403" ] && [ "$lg" = "0" ] \
  && pass "未配可信代理：伪造 XFF=203.0.113.7（名单内）被拒 ${spoof}、无转发头也被拒 ${plain}、零计费" \
  || fail "XFF 信任边界失效: 伪造名单内IP=${spoof}(期望403) 无头=${plain}(期望403) 计费=${lg}(期望0)"
stop_app; boot_app NEWGATE_TRUSTED_PROXIES=127.0.0.1,::1
allow=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 203.0.113.7" -d '{"model":"m-ip","messages":[]}')
deny=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 198.51.100.9" -d '{"model":"m-ip","messages":[]}')
# 链首伪造：客户端先写一个名单内 IP，反代再追加它自己的真实地址 → 剥链应停在后者
prepend=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 203.0.113.7, 198.51.100.9" -d '{"model":"m-ip","messages":[]}')
sleep 1   # 非流式先响应后计费（延迟优先，资金已由预留担保），等账落库再断言
lg=$(q "SELECT COUNT(*) FROM gateway_usage_logs")
q "UPDATE gateway_tokens SET allowed_ips='' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
[ "$allow" = "200" ] && [ "$deny" = "403" ] && [ "$prepend" = "403" ] && [ "$lg" = "1" ] \
  && pass "可信代理剥链：真客户端 203.0.113.7 → ${allow}、名单外 → ${deny}、名单内IP塞链首仍 → ${prepend}、仅 ${lg} 条计费" \
  || fail "可信代理剥链错: 名单内=${allow}(期望200) 名单外=${deny}(期望403) 链首伪造=${prepend}(期望403) 计费=${lg}(期望1)"

# ══ S15 /v1/models 真数据 + 原生认证载体 ══
echo "[S15] /v1/models 与原生认证"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES
   ('c-m1','openai_compatible','http://127.0.0.1:9880','default','gpt-4o,gpt-4o-mini',1,1,1,30000,90000,'1.0',0,0,0),
   ('c-m2','anthropic','http://127.0.0.1:9880','vip','claude-3-5-sonnet',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES
   ((SELECT id FROM gateway_channels WHERE name='c-m1'),'k',1,0,0,0,0),((SELECT id FROM gateway_channels WHERE name='c-m2'),'k',1,0,0,0,0);" >/dev/null
models=$(curl -s --max-time 10 "$U/v1/models" -H "$AUTH")
has4o=$(echo "$models" | grep -c '"gpt-4o"')
hasMini=$(echo "$models" | grep -c '"gpt-4o-mini"')
hasVip=$(echo "$models" | grep -c 'claude-3-5-sonnet')
# 令牌白名单收窄后应只剩一个
q "UPDATE gateway_tokens SET allowed_models='gpt-4o' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
narrowed=$(curl -s --max-time 10 "$U/v1/models" -H "$AUTH" | grep -c '"gpt-4o-mini"')
q "UPDATE gateway_tokens SET allowed_models='' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
[ "$has4o" = "1" ] && [ "$hasMini" = "1" ] && [ "$hasVip" = "0" ] && [ "$narrowed" = "0" ] \
  && pass "/v1/models 返回可用模型、排除非本组(vip)、遵守令牌白名单" \
  || fail "/v1/models 错: gpt-4o=${has4o} mini=${hasMini} vip泄漏=${hasVip} 白名单后mini=${narrowed} body=${models}"
# 三家原生认证载体都应能通过
ck=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/v1/models" -H "x-api-key: ${TOKEN_PLAINTEXT}")
gk=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/v1/models" -H "x-goog-api-key: ${TOKEN_PLAINTEXT}")
bad=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/v1/models" -H "x-api-key: sk-wrong-key")
[ "$ck" = "200" ] && [ "$gk" = "200" ] && [ "$bad" != "200" ] \
  && pass "原生认证载体：x-api-key=200、x-goog-api-key=200、错误 key 被拒(${bad})" \
  || fail "原生认证错: x-api-key=${ck} x-goog-api-key=${gk} 错误key=${bad}"

# ══ S16 用户端 app 路由组：自助令牌 / 用量 / 模型广场 / 越权防护 ══
echo "[S16] 用户端 app API"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-app','openai_compatible','http://127.0.0.1:9880','default','m-app',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-app'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-app','0','0','0','0',100,5000,'manual',0,0,0);" >/dev/null
# 模型广场：未登录可访问（@AllowAnonymous）
anon=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/app/gateway/model/list")
anonBody=$(curl -s --max-time 10 "$U/app/gateway/model/list")
hasModel=$(echo "$anonBody" | grep -c "m-app")
# 用户端需要会员登录态；无凭据时受保护端点必须拒绝
noauth=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/app/gateway/usage/balance")
[ "$anon" = "200" ] && [ "$hasModel" -ge 1 ] && [ "$noauth" != "200" ] \
  && pass "模型广场未登录可读(200/含模型)、受保护端点未登录被拒(${noauth})" \
  || fail "app 路由组错: 广场=${anon} 含模型=${hasModel} 未登录余额=${noauth}"
# 未定价模型不得出现在广场（网关会拒绝它，列出来是误导）
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-np','openai_compatible','http://127.0.0.1:9880','default','m-unpriced',1,1,1,30000,90000,'1.0',0,0,0);" >/dev/null
unpriced=$(curl -s --max-time 10 "$U/app/gateway/model/list" | grep -c "m-unpriced")
[ "$unpriced" = "0" ] && pass "未定价模型不出现在模型广场" || fail "未定价模型泄漏到广场(${unpriced})"

# ══ S17 在途改价按预留快照计价（V004-durable-settlement-design §7.1）══
# 慢上游 2s 才响应：在「已预留、未结算」窗口把模型价涨 10 倍、分组倍率改 2。
# 若 bill() 重查价表会扣 (25×1000+100×500)×2=150000；快照语义必须仍是 7500。
echo "[S17] 在途改价按快照计价"
seed_reset; fake slowok 9905; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-snap','openai_compatible','http://127.0.0.1:9905','default','m-snap',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-snap'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-snap','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
( curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-snap","messages":[]}' >/tmp/s17-code.$$ ) & CURL_PID=$!
sleep 1   # 上游 2s 慢响应，此刻请求必然在途（已预留、未结算）
q "UPDATE gateway_model_prices SET input_price='25', output_price='100' WHERE model='m-snap';
   UPDATE gateway_groups SET ratio='2.0' WHERE code='default';" >/dev/null
wait "$CURL_PID"; sleep 1
code=$(cat /tmp/s17-code.$$ 2>/dev/null); rm -f /tmp/s17-code.$$
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-snap' ORDER BY id DESC LIMIT 1")
ta=$(q "SELECT -amount FROM gateway_quota_transactions WHERE ref LIKE 'settlement:%' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
tu=$(q "SELECT quota_used FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
q "UPDATE gateway_groups SET ratio='1.0' WHERE code='default';" >/dev/null   # 还原倍率，不污染后续场景/库状态
# 这里按 code 而不是 name 找组：V002 之后 name 只是显示名（S27 就会改它），
# 用 name 定位等于把「改显示名不影响计价」这条不变量在 harness 自己这里破掉。
[ "$code" = "200" ] && [ "$lc" = "7500" ] && [ "$lc" = "$ta" ] && [ "$lc" = "$bd" ] && [ "$lc" = "$tu" ] \
  && pass "在途改价/改倍率仍按预留快照计费 charged=${lc}（重查价表会扣 150000）、四项一致" \
  || fail "在途改价计费错: code=$code charged=${lc} debit=${ta} balanceΔ=${bd} quotaUsed=${tu}（期望 7500）"

# ══ S18 快照损坏不得按实时价扣款 → MANUAL_REVIEW 保留预留（V004-durable-settlement-design §7.1）══
# 注入点：渠道 cost_discount 坏值。模型价在入口就要过售价轨校验（坏价走 S19），渠道折扣却是 T2
# 才并入快照的，坏值因此能「合法」写进快照；bill() 严格校验四要素必须拒绝：不扣款、不写台账/
# usage log、不释放预留、转 MANUAL_REVIEW + 高优告警。修复前：坏字段被默认值补齐或回退实时价。
echo "[S18] 快照损坏转人工、预留保留"
seed_reset; fake ok 9906; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-crp','openai_compatible','http://127.0.0.1:9906','default','m-crp',1,1,1,30000,90000,'{corrupted',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-crp'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-crp','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-crp","messages":[]}')
sleep 1   # 非流式先响应后计费，等结算落库
st=$(q "SELECT status FROM gateway_settlements WHERE request_model='m-crp' ORDER BY id DESC LIMIT 1")
ra=$(q "SELECT retry_action FROM gateway_settlements WHERE request_model='m-crp' ORDER BY id DESC LIMIT 1")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
qr=$(q "SELECT quota_reserved FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
nlog=$(q "SELECT COUNT(*) FROM gateway_usage_logs WHERE request_model='m-crp'")
ntx=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='consume'")
alert=$(grep -c "pricing snapshot invalid" "$WORK/logs/all.log" 2>/dev/null)
[ "$code" = "200" ] && [ "$st" = "MANUAL_REVIEW" ] && [ "$ra" = "FINALIZE" ] \
  && [ "${rb:-0}" -gt 0 ] && [ "${qr:-0}" -gt 0 ] && [ "$bd" = "0" ] && [ "$nlog" = "0" ] && [ "$ntx" = "0" ] && [ "${alert:-0}" -ge 1 ] \
  && pass "快照损坏：客户端 200、转 MANUAL_REVIEW(action=${ra})、预留保留(account=${rb} token=${qr})、未扣款(balanceΔ=${bd}/台账=${ntx}/日志=${nlog})、告警=${alert}" \
  || fail "快照损坏语义错: code=${code} status=${st} action=${ra} 预留=${rb}/${qr} balanceΔ=${bd} usageLogs=${nlog} consumeTx=${ntx} alert=${alert}"

# ══ S19 坏价入口 fail-fast：绝不带病进 reserve（双轨计价）══
# cache_read_price 坏值在入口解析售价轨时就被拒：500 model_pricing_invalid、零 settlement、零预留。
# 若放行，坏价会随快照进入结算，届时只能猜价或转人工——账务事故必须挡在门口。
# 500 而非 400：请求本身没问题，是运营侧定价数据坏了，归成客户端错误会掩盖事故。
echo "[S19] 坏价入口 fail-fast"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-bad','openai_compatible','http://127.0.0.1:9906','default','m-bad',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-bad'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-bad','2.5','10','{corrupted','0',5000,'manual',0,0,0);" >/dev/null
code=$(curl -s --max-time 20 -o /tmp/s19-body.$$ -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-bad","messages":[]}')
body=$(cat /tmp/s19-body.$$ 2>/dev/null); rm -f /tmp/s19-body.$$
ns=$(q "SELECT COUNT(*) FROM gateway_settlements")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
qr=$(q "SELECT quota_reserved FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
nlog=$(q "SELECT COUNT(*) FROM gateway_usage_logs")
ec=$(echo "$body" | grep -c "model_pricing_invalid")
alert=$(grep -c "model pricing invalid" "$WORK/logs/all.log" 2>/dev/null)
[ "$code" = "500" ] && [ "${ec:-0}" -ge 1 ] && [ "$ns" = "0" ] && [ "${rb:-0}" = "0" ] && [ "${qr:-0}" = "0" ] \
  && [ "$bd" = "0" ] && [ "$nlog" = "0" ] && [ "${alert:-0}" -ge 1 ] \
  && pass "坏价入口拒绝：500/model_pricing_invalid、零 settlement(${ns})、零预留(${rb}/${qr})、未扣款(${bd})、告警=${alert}" \
  || fail "坏价未入口 fail-fast: code=${code} body=${body} settlements=${ns} 预留=${rb}/${qr} balanceΔ=${bd} logs=${nlog} alert=${alert}"

# ══ S20 双轨计价：收入按售价轨（saleOverride）、成本按官方价 × 渠道折扣 ══
# 官方 2.5/10、售价覆盖 5/20、渠道折扣 0.8：charged 必须是 15000（售价轨）、cost 必须是 6000
# （官方轨 7500 × 0.8）；预留也按售价轨；广场展示售价而非官方成本价；毛利为正 → 无倒挂告警。
echo "[S20] 双轨计价（售价/成本分离）"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-sale','openai_compatible','http://127.0.0.1:9906','default','m-sale',1,1,1,30000,90000,'0.8',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-sale'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,sale_override,source,deleted,created_at,updated_at) VALUES ('m-sale','2.5','10','0','0',5000,'{\"input\":\"5\",\"output\":\"20\"}','manual',0,0,0);" >/dev/null
BODY='{"model":"m-sale","messages":[]}'
# 预期预留：输入上界（请求体字节数）× 售价 5 + 输出上限 5000 × 售价 20，向上取整
exp_res=$(BODY="$BODY" python3 -c 'import os;b=len(os.environ["BODY"].encode());tc=lambda t,p:(t*p+999999)//1000000;print(tc(b,5000000)+tc(5000,20000000))')
code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d "$BODY")
sleep 1
sc=$(q "SELECT charged FROM gateway_settlements WHERE request_model='m-sale' ORDER BY id DESC LIMIT 1")
sco=$(q "SELECT cost FROM gateway_settlements WHERE request_model='m-sale' ORDER BY id DESC LIMIT 1")
rs=$(q "SELECT reserved_amount FROM gateway_settlements WHERE request_model='m-sale' ORDER BY id DESC LIMIT 1")
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-sale' ORDER BY id DESC LIMIT 1")
lco=$(q "SELECT cost FROM gateway_usage_logs WHERE request_model='m-sale' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
tu=$(q "SELECT quota_used FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
cat5=$(curl -s --max-time 10 "$U/app/gateway/model/list" | grep -c '"inputPrice":"5"')
inv=$(grep -c "margin inversion" "$WORK/logs/all.log" 2>/dev/null)
[ "$code" = "200" ] && [ "$sc" = "15000" ] && [ "$lc" = "15000" ] && [ "$sco" = "6000" ] && [ "$lco" = "6000" ] \
  && [ "$bd" = "15000" ] && [ "$tu" = "15000" ] && [ "$rs" = "$exp_res" ] && [ "${cat5:-0}" -ge 1 ] && [ "${inv:-0}" = "0" ] \
  && pass "双轨：收入=${sc}（售价 5/20）、成本=${sco}（官方 7500 × 0.8）、预留=${rs}、余额Δ=${bd}、广场展售价、无毛利倒挂" \
  || fail "双轨计价错: code=$code charged=${sc}/${lc} cost=${sco}/${lco} 预留=${rs}(期望${exp_res}) balanceΔ=${bd} quotaUsed=${tu} 广场售价=${cat5} inversion=${inv}"

# ══ S21 发布闸门：售价低于官方成本 → 拒绝发布（毛利底线）══
echo "[S21] 毛利闸门（发布期）"
seed_reset
JWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
low=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/price/create" -H "Authorization: Bearer $JWT" -H "$CT" -d '{"model":"m-gate","inputPrice":"2.5","outputPrice":"10","cacheReadPrice":"0","cacheWritePrice":"0","saleOverride":"{\"input\":\"1\"}"}')
nlow=$(q "SELECT COUNT(*) FROM gateway_model_prices WHERE model='m-gate'")
hi=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/price/create" -H "Authorization: Bearer $JWT" -H "$CT" -d '{"model":"m-gate","inputPrice":"2.5","outputPrice":"10","cacheReadPrice":"0","cacheWritePrice":"0","saleOverride":"{\"input\":\"5\",\"output\":\"20\"}"}')
nhi=$(q "SELECT COUNT(*) FROM gateway_model_prices WHERE model='m-gate'")
[ "$low" = "400" ] && [ "$nlow" = "0" ] && [ "$hi" = "200" ] && [ "$nhi" = "1" ] \
  && pass "毛利闸门：售价低于官方成本被拒(400/未落库)、合法售价通过(200/落库=${nhi})" \
  || fail "毛利闸门错: 低价=${low}(落库${nlow}) 合法=${hi}(落库${nhi})"

# ══ S22 全局加价率 + 毛利下限（env 运营开关）══
# 重启网关带 NEWGATE_SALE_MARKUP=2.0 / NEWGATE_MIN_MARGIN=1.5：
#  - 无 saleOverride 的模型售价 = 官方价 × 2 → 收入翻倍（官方 2.5/10 → 售价 5/20 → charged 15000），
#    而成本仍按官方价轨（7500）——加价率只动收入轨，不污染成本核算；
#  - 发布底线抬到官方 × 1.5（官方 2.5 → 售价底线 3.75）。
echo "[S22] 全局加价率 / 毛利下限"
stop_app; boot_app NEWGATE_SALE_MARKUP=2.0 NEWGATE_MIN_MARGIN=1.5
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-mk','openai_compatible','http://127.0.0.1:9906','default','m-mk',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-mk'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-mk','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
BODY='{"model":"m-mk","messages":[]}'
exp_res=$(BODY="$BODY" python3 -c 'import os;b=len(os.environ["BODY"].encode());tc=lambda t,p:(t*p+999999)//1000000;print(tc(b,5000000)+tc(5000,20000000))')
code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d "$BODY")
sleep 1
sc=$(q "SELECT charged FROM gateway_settlements WHERE request_model='m-mk' ORDER BY id DESC LIMIT 1")
sco=$(q "SELECT cost FROM gateway_settlements WHERE request_model='m-mk' ORDER BY id DESC LIMIT 1")
rs=$(q "SELECT reserved_amount FROM gateway_settlements WHERE request_model='m-mk' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$code" = "200" ] && [ "$sc" = "15000" ] && [ "$sco" = "7500" ] && [ "$bd" = "15000" ] && [ "$rs" = "$exp_res" ] \
  && pass "加价率 2.0：收入=${sc}（官方×2）、成本=${sco}（官方轨不变）、预留=${rs}、余额Δ=${bd}" \
  || fail "加价率未生效: code=$code charged=${sc}(期望15000) cost=${sco}(期望7500) 预留=${rs}(期望${exp_res}) balanceΔ=${bd}"
JWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
low=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/price/create" -H "Authorization: Bearer $JWT" -H "$CT" -d '{"model":"m-gate2","inputPrice":"2.5","outputPrice":"10","cacheReadPrice":"0","cacheWritePrice":"0","saleOverride":"{\"input\":\"3\"}"}')
nlow=$(q "SELECT COUNT(*) FROM gateway_model_prices WHERE model='m-gate2'")
hi=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/price/create" -H "Authorization: Bearer $JWT" -H "$CT" -d '{"model":"m-gate2","inputPrice":"2.5","outputPrice":"10","cacheReadPrice":"0","cacheWritePrice":"0","saleOverride":"{\"input\":\"4\"}"}')
nhi=$(q "SELECT COUNT(*) FROM gateway_model_prices WHERE model='m-gate2'")
[ "$low" = "400" ] && [ "$nlow" = "0" ] && [ "$hi" = "200" ] && [ "$nhi" = "1" ] \
  && pass "毛利下限 1.5：售价 3（<2.5×1.5=3.75）被拒(400)、售价 4 通过(200/落库=${nhi})" \
  || fail "毛利下限错: 售价3=${low}(落库${nlow}) 售价4=${hi}(落库${nhi})"

# ══ S23 端点能力路由：embeddings 只落到声明了该能力的渠道 ══
# capabilities 列在 sql/*/V001__baseline.sql 的「原 V007__channel_capabilities」段 ——
# 迁移已合并成单 baseline（ff36f49），别再按 V007 去找文件。
# 此前 /v1/embeddings 只要模型名命中就路由：打到只会 chat 的上游必然 404，而钱已预留、日志已脏、重试还撞三遍同一堵墙。
#  - m-emb 同时挂在 chat-only 与 chat,embeddings 两个渠道 → 必须选中后者（用 usage_logs.channel_id 举证）；
#    embeddings 响应只有 prompt_tokens → charged 只按 7 个输入 token，不得凭空补出输出费用；
#  - m-chatonly 只挂在 chat-only 渠道 → /v1/embeddings 直接 404 model_not_found，零 settlement、零预留
#    （不是 503：配置不变就永远不会可用，503 只会让客户端按退避策略一直撞墙）；
#  - 同一渠道的 /v1/chat/completions 照常可用 → 能力过滤不误伤对话。
echo "[S23] 端点能力路由（embeddings）"
stop_app; boot_app
seed_reset
fake embok 9971; fake ok 9972; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,capabilities,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES
   ('c-chatonly','openai_compatible','http://127.0.0.1:9972','default','m-emb,m-chatonly','chat',1,1,1,30000,90000,'1.0',0,0,0),
   ('c-emb','openai_compatible','http://127.0.0.1:9971','default','m-emb','chat,embeddings',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES
   ((SELECT id FROM gateway_channels WHERE name='c-chatonly'),'k',1,0,0,0,0),((SELECT id FROM gateway_channels WHERE name='c-emb'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES
   ('m-emb','1','1','0','0',5000,'manual',0,0,0),('m-chatonly','1','1','0','0',5000,'manual',0,0,0);" >/dev/null
code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/embeddings" -H "$AUTH" -H "$CT" -d '{"model":"m-emb","input":"hello"}')
sleep 1
ch=$(q "SELECT c.name FROM gateway_usage_logs l JOIN gateway_channels c ON c.id=l.channel_id WHERE l.request_model='m-emb' ORDER BY l.id DESC LIMIT 1")
pt=$(q "SELECT prompt_tokens FROM gateway_usage_logs WHERE request_model='m-emb' ORDER BY id DESC LIMIT 1")
ct=$(q "SELECT completion_tokens FROM gateway_usage_logs WHERE request_model='m-emb' ORDER BY id DESC LIMIT 1")
lg=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-emb' ORDER BY id DESC LIMIT 1")
code2=$(curl -s --max-time 20 -o /tmp/s23-body.$$ -w "%{http_code}" -X POST "$U/v1/embeddings" -H "$AUTH" -H "$CT" -d '{"model":"m-chatonly","input":"hello"}')
b2=$(cat /tmp/s23-body.$$ 2>/dev/null); rm -f /tmp/s23-body.$$
nf=$(echo "$b2" | grep -c "model_not_found")
ns=$(q "SELECT COUNT(*) FROM gateway_settlements WHERE request_model='m-chatonly'")
rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$code" = "200" ] && [ "$ch" = "c-emb" ] && [ "$pt" = "7" ] && [ "${ct:-0}" = "0" ] && [ "$lg" = "7" ] \
  && [ "$code2" = "404" ] && [ "${nf:-0}" -ge 1 ] && [ "$ns" = "0" ] && [ "${rb:-0}" = "0" ] \
  && pass "能力路由：embeddings 落到 ${ch}（charged=${lg}/prompt=${pt}/completion=${ct}）、chat-only 模型 404 model_not_found 且零 settlement(${ns})/零预留(${rb})" \
  || fail "能力路由错: emb=${code}(渠道=${ch} charged=${lg} tokens=${pt}/${ct}) 无能力=${code2}(${b2}) settlements=${ns} 预留=${rb}"
code3=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-chatonly","messages":[]}')
sleep 1
ch3=$(q "SELECT c.name FROM gateway_usage_logs l JOIN gateway_channels c ON c.id=l.channel_id WHERE l.request_model='m-chatonly' ORDER BY l.id DESC LIMIT 1")
lg3=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-chatonly' ORDER BY id DESC LIMIT 1")
[ "$code3" = "200" ] && [ "$ch3" = "c-chatonly" ] && [ "$lg3" = "1500" ] \
  && pass "能力过滤不误伤对话：chat/completions 仍走 ${ch3}（charged=${lg3}）" \
  || fail "chat 路由被误伤: code=${code3} 渠道=${ch3} charged=${lg3}(期望1500)"

# ══ S24 原子限流计数：Redis 里的账必须与 ledger 完全一致 ══
# 计数器曾是 get + set 读-改-写：并发下两个请求读到同一旧值、各自 +N 再写回，增量被吞掉。
# TPM 少记的每个 token 都是真金白银的成本敞口，所以这里不只看「有没有限流」（S13 已看），
# 而是把 Redis 里的计数与账本对账：
#  - 20 并发 → RPM 必须精确等于 20（读-改-写会少计）、TPM 必须等于 SUM(prompt+completion)；
#  - 窗口键必须带 TTL（incr 与 expire 分两条命令时，进程在中间崩溃会留下永不过期的死键）；
#  - 并发占用归还后键必须被删干净：多归还一次不得变成负数（负数 = 白送并发额度）。
echo "[S24] Redis 原子限流计数"
if [ "$REDIS_OK" != "1" ]; then
  echo "  ⏭️  跳过：没有隔离 redis-server（限流已退化为进程内计数，单实例语义不变、多实例不共享）"
else
  seed_reset; fake ok 9974; sleep 1
  q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-atom','openai_compatible','http://127.0.0.1:9974','default','m-atom',1,1,1,30000,90000,'1.0',0,0,0);
     INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-atom'),'k',1,0,0,0,0);
     INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-atom','2.5','10','0','0',5000,'manual',0,0,0);
     UPDATE gateway_tokens SET rpm_limit=1000, tpm_limit=NULL, concurrency_limit=NULL WHERE key_hash='${TOKEN_HASH}';" >/dev/null
  TID=$(q "SELECT id FROM gateway_tokens WHERE key_hash='${TOKEN_HASH}'")
  sleep 2   # 等前序场景的在途结算落定，否则它们的 recordTokens 会混进本轮计数
  rkdel "*ngrl:rpm:${TID}:*"; rkdel "*ngrl:tpm:${TID}:*"; rkdel "*ngrl:cc:${TID}"
  seq 1 20 | xargs -P 20 -I{} curl -s --max-time 20 -o /dev/null -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-atom","messages":[]}'
  sleep 2   # 非流式：先响应后结算，recordTokens 发生在结算之后
  n=$(q "SELECT COUNT(*) FROM gateway_usage_logs WHERE user_id=1")
  dbt=$(q "SELECT COALESCE(SUM(prompt_tokens+completion_tokens),0) FROM gateway_usage_logs WHERE user_id=1")
  rpm=$(rksum "*ngrl:rpm:${TID}:*")   # 跳分钟窗口也要算全，否则边界上会假失败
  tpm=$(rksum "*ngrl:tpm:${TID}:*")
  ttl=$(rc ttl "$(rc --scan --pattern "*ngrl:rpm:${TID}:*" | head -1)")
  [ "$n" = "20" ] && [ "$rpm" = "20" ] && [ "$tpm" = "$dbt" ] && [ "$dbt" != "0" ] && [ "${ttl:-0}" -gt 0 ] && [ "${ttl:-0}" -le 120 ] \
    && pass "20 并发：RPM=${rpm}（精确 20，无丢增量）、TPM=${tpm} == 账本 token 总数 ${dbt}、窗口键 TTL=${ttl}s" \
    || fail "原子计数错: 计费=${n}(期望20) RPM=${rpm}(期望20) TPM=${tpm}(期望${dbt}) TTL=${ttl}(期望1..120)"
  q "UPDATE gateway_tokens SET concurrency_limit=3 WHERE key_hash='${TOKEN_HASH}';" >/dev/null
  rkdel "*ngrl:cc:${TID}"
  codes=$(seq 1 12 | xargs -P 12 -I{} curl -s --max-time 20 -o /dev/null -w "%{http_code}\n" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-atom","messages":[]}')
  sleep 2
  nok=$(echo "$codes" | grep -c "^200$"); n429=$(echo "$codes" | grep -c "^429$")
  ccn=$(rc --scan --pattern "*ngrl:cc:${TID}" | grep -c ngrl)
  led=$(q "SELECT COUNT(*) FROM gateway_usage_logs WHERE user_id=1")
  q "UPDATE gateway_tokens SET rpm_limit=NULL, concurrency_limit=NULL WHERE key_hash='${TOKEN_HASH}';" >/dev/null
  # 429 的具体个数取决于调度时序（假上游太快时可能一个也不限），故只断言可对账的部分
  [ $((nok + n429)) -eq 12 ] && [ "$ccn" = "0" ] && [ "$led" = "$((20 + nok))" ] \
    && pass "并发额度生命周期：12 并发下 200=${nok}/429=${n429}、结束后并发键已删（无泄漏、无负数）、计费条数与 200 数对账" \
    || fail "并发计数错: 200=${nok} 429=${n429}(合计应12) 残留并发键=${ccn}(期望0) 计费=${led}(期望$((20 + nok)))"
fi

# ══ S25 渠道写入的 SSRF 校验（管理员 API 全链路）══
# NetGuard 的字面量/域名解析边界已在单测里穷举（含真 getaddrinfo 的 smoke）；这里验的是**接线**：
# 控制器确实调了校验、新增的 Logger 构造注入没有破 DI（KSP 注入少一个绑定只有真跑才暴露）。
# 域名 → DNS 复查这一层无法在 harness 里确定性触发（本机 DNS 可能是 fake-IP 模式，对任何
# 名字都返回 198.18.0.0/15），所以公网域名用例只区分「放行」与「因解析失败而 fail-closed」，
# 后者是 DNS 不可用时的预期行为，不计失败。
echo "[S25] 渠道 SSRF 校验（admin API）"
JWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
mkch() { curl -s --max-time 10 -o "/tmp/s25-$2-$$" -w "%{http_code}" -X POST "$U/admin/gateway/channel/create" \
  -H "Authorization: Bearer $JWT" -H "$CT" -d "{\"name\":\"s25-$2\",\"type\":\"openai_compatible\",\"baseUrl\":\"$1\"}"; }
meta=$(mkch "http://169.254.169.254/latest/meta-data" meta)
loop=$(mkch "http://[::1]:9974/v1" loop)
pub=$(mkch "http://8.8.8.8:8080/v1" pub)
nbad=$(q "SELECT COUNT(*) FROM gateway_channels WHERE name IN ('s25-meta','s25-loop')")
npub=$(q "SELECT COUNT(*) FROM gateway_channels WHERE name='s25-pub'")
[ "$meta" = "400" ] && [ "$loop" = "400" ] && [ "$nbad" = "0" ] && [ "$pub" = "200" ] && [ "$npub" = "1" ] \
  && pass "SSRF：云元数据 169.254.169.254 与 [::1] 被拒(400/未落库)、公网字面量正常创建(200/落库=${npub})" \
  || fail "SSRF 校验错: 元数据=${meta}(期望400) ipv6回环=${loop}(期望400) 未落库=${nbad}(期望0) 公网=${pub}(期望200/落库${npub})"
dom=$(mkch "https://api.openai.com/v1" dom); reason=$(cat "/tmp/s25-dom-$$" 2>/dev/null)
rm -f "/tmp/s25-"*"-$$"
if [ "$dom" = "200" ]; then
  pass "域名渠道经 DNS 复查后放行（api.openai.com）"
elif echo "$reason" | grep -q "could not be resolved"; then
  echo "  ⚠️  本机解析不出 api.openai.com → 按 fail-closed 拒绝（DNS 不可用时的预期行为，不计失败）" >&2
else
  fail "域名渠道被意外拒绝: ${dom} ${reason}"
fi

# ════════════════════════════════════════════════════════════════════
# S26–S34：计费组身份（gateway V002）与充值闭环（gateway V003）
#
# 这一批盯的都是**不报错的错账**：静默回落 default、按显示名路由、改名改掉计价、
# 悬空引用、重复入账、付了钱没额度。它们共同点是代码里没有任何一处会抛异常 ——
# 只会安静地少收钱或多发额度，所以只能靠断言账面数字来抓。
#
# 分组用的模型价 2.5/10 + fake 的 usage（1000 in / 500 out）→ 成本 7500 μUSD，
# 乘上组倍率就是该收的数：ratio 1.0 → 7500、2.0 → 15000、5.0 → 37500。
# 与 S1/S17 同一套数，不引入新的计价假设。
# ════════════════════════════════════════════════════════════════════
GB=/tmp/s26-body-$$
GJWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
# /app 与 /admin 共用 JWT 体系（只有 gateway 组走 sk- 令牌，见 GatewaySecurityConfig）
GID() { q "SELECT id FROM gateway_groups WHERE code='$1'"; }
relay26() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-grp","messages":[]}'; }
charged26() { q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-grp' ORDER BY id DESC LIMIT 1"; }

echo "[S26] 计费组解析：缺组/缺映射一律拒绝，不静默回落 default"
seed_reset; fake ok 9931; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-grp','openai_compatible','http://127.0.0.1:9931','default,vip26','m-grp',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-grp'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-grp','2.5','10','0','0',5000,'manual',0,0,0);
   INSERT INTO gateway_groups (code,name,ratio,description,deleted,created_at,updated_at) VALUES ('vip26','VIP 26','2.0',NULL,0,0,0),('del26','待删组','1.0',NULL,0,0,0);
   INSERT INTO member_groups (id,name,status,created_at,updated_at) VALUES (9926,'未映射会员组',1,0,0);
   INSERT INTO member_users (id,nickname,status,group_id) VALUES (1,'harness',1,9926);" >/dev/null
VIP26=$(GID vip26)

# (a) 令牌覆盖指向不存在的 code。修复前这里是 `?: "default"`：请求照常放行、按 default 计价，
#     而运营以为自己给这个令牌配了 vip 价 —— 差额不会出现在任何日志里。
q "UPDATE gateway_tokens SET group_override='ghost26' WHERE key_hash='$TOKEN_HASH'" >/dev/null
ca=$(relay26); sleep 1
na=$(q "SELECT COUNT(*) FROM gateway_settlements")
da=$(q "SELECT 100000000-balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$ca" = "500" ] && grep -q 'billing_group_config_broken' "$GB" && [ "$na" = "0" ] && [ "$da" = "0" ] \
  && pass "令牌覆盖指向不存在的组 → 500 billing_group_config_broken、零 settlement(${na})、未扣款(${da})" \
  || fail "缺目标组未拒绝: code=${ca}(期望500) body=$(head -c 160 "$GB") settlement=${na} balanceΔ=${da}"

# (b) default 组本身缺失：最后一级也不能回落，只能拒绝
q "UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH';
   UPDATE gateway_groups SET deleted=1 WHERE code='default';" >/dev/null
cb=$(relay26); sleep 1
nb=$(q "SELECT COUNT(*) FROM gateway_settlements")
q "UPDATE gateway_groups SET deleted=0 WHERE code='default';" >/dev/null
[ "$cb" = "500" ] && grep -q 'billing_group_config_broken' "$GB" && [ "$nb" = "0" ] \
  && pass "default 组缺失 → 500 billing_group_config_broken、零 settlement(${nb})（不凭空按 1.0 计）" \
  || fail "缺 default 组未拒绝: code=${cb}(期望500) body=$(head -c 160 "$GB") settlement=${nb}"

# (c) 会员组无映射，但开关**关着** → 会员组整个不参与解析，照走 default。
#     这条是 (d) 的对照：没有它，「开关真的门控」只是代码里的一行 if，没人验过。
cc=$(relay26); sleep 1
sc26=$(charged26)
[ "$cc" = "200" ] && [ "$sc26" = "7500" ] \
  && pass "开关关闭时会员组不参与解析：200、按 default 组计价 charged=${sc26}" \
  || fail "开关未门控: code=${cc} charged=${sc26}(期望7500，即 default 组 ratio 1.0)"

echo "[S27] 计费组：改显示名不动路由与计价，code 不可变"
q "UPDATE gateway_tokens SET group_override='vip26' WHERE key_hash='$TOKEN_HASH'" >/dev/null
c0=$(relay26); sleep 1; s0=$(charged26)
ren=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X PUT "$U/admin/gateway/group/update" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"id\":$VIP26,\"name\":\"贵宾二十六\",\"ratio\":\"2.0\"}")
newname=$(q "SELECT name FROM gateway_groups WHERE id=$VIP26")
c1=$(relay26); sleep 1; s1=$(charged26)
# 改 code 必须被拒而不是静默忽略：忽略了调用方会以为改成功，而路由与计价仍按旧 code 走
imm=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X PUT "$U/admin/gateway/group/update" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"id\":$VIP26,\"code\":\"hacked26\",\"name\":\"贵宾二十六\",\"ratio\":\"2.0\"}")
codeNow=$(q "SELECT code FROM gateway_groups WHERE id=$VIP26")
[ "$c0" = "200" ] && [ "$s0" = "15000" ] && [ "$ren" = "200" ] && [ "$newname" = "贵宾二十六" ] \
  && [ "$c1" = "200" ] && [ "$s1" = "15000" ] \
  && pass "改显示名（${newname}）后仍按 code=vip26 路由、按 ratio 2.0 计价：改名前=${s0} 改名后=${s1}" \
  || fail "改名影响了计价: 前=${c0}/${s0} 改名HTTP=${ren} 现名=${newname} 后=${c1}/${s1}(期望均为200/15000)"
# 409 而不是「非 200」：改 code 走的是 conflict()，落 500 就说明它又变回了未分类异常
# （框架会把 message 换成 "Internal Server Error"，管理端拿不到原因）。
[ "$imm" = "409" ] && [ "$codeNow" = "vip26" ] \
  && pass "code 不可变：带不同 code 的更新被拒(409)、库里仍是 ${codeNow}" \
  || fail "code 被改掉了: HTTP=${imm}(期望409) 现值=${codeNow}(期望 vip26)"
# 创建守卫同样要给干净的 4xx：重复 code 是 409，含逗号是 400（逗号会污染 channel.groups 的 CSV，
# 让 'vip,26' 在路由眼里变成两个组）。两者落 500 的话管理端只看到一句 Internal Server Error。
dup=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"code":"vip26","name":"撞车","ratio":"1.0"}')
badcode=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"code":"vip,26","name":"带逗号","ratio":"1.0"}')
ndup=$(q "SELECT COUNT(*) FROM gateway_groups WHERE code IN ('vip26','vip,26')")
[ "$dup" = "409" ] && [ "$badcode" = "400" ] && [ "$ndup" = "1" ] \
  && pass "创建守卫给干净的 4xx：重复 code=${dup}、含逗号=${badcode}、库里仍只有 1 行 vip26" \
  || fail "创建守卫响应码不对: 重复=${dup}(期望409) 含逗号=${badcode}(期望400) 行数=${ndup}(期望1)"

echo "[S28] 被引用的组禁删（令牌覆盖 / 用户级例外 / 渠道 CSV）"
DEL26=$(GID del26)
d0=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$DEL26" -H "Authorization: Bearer $GJWT")
gone=$(q "SELECT deleted FROM gateway_groups WHERE id=$DEL26")
[ "$d0" = "200" ] && [ "$gone" = "1" ] \
  && pass "无引用的组可删（HTTP=${d0}、deleted=${gone}）" \
  || fail "无引用组删不掉: HTTP=${d0} deleted=${gone}"
# 用户级例外：gateway_group_overrides 目前只有 SQL + 表对象（还没有管理端 CRUD），
# 所以直接按 a5 解析器第 2 步会读到的形态插一行。漏了这条检查就会留下悬空 group_code。
q "INSERT INTO gateway_group_overrides (user_id,group_code,remark,created_at,updated_at) VALUES (1,'vip26','大客户谈判价',0,0)" >/dev/null
d1=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
a1=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
q "DELETE FROM gateway_group_overrides WHERE user_id=1" >/dev/null
d2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
a2=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
q "UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH'" >/dev/null
d3=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
a3=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
[ "$d1" = "409" ] && [ "$a1" = "0" ] && [ "$d2" = "409" ] && [ "$a2" = "0" ] && [ "$d3" = "409" ] && [ "$a3" = "0" ] \
  && pass "三类引用都拦住删除(409)：用户级例外、令牌覆盖、渠道 CSV，组均仍在(deleted=0)" \
  || fail "删除保护有洞: 例外=${d1}(期望409)/deleted=${a1} 令牌=${d2}(期望409)/deleted=${a2} 渠道=${d3}(期望409)/deleted=${a3}"

echo "[S29] 用户不能自行提组"
# 自助建 Key 的 DTO（CreateMyTokenRequest）里没有 groupOverride 字段，TokenLogic.issue 也不收这个参数。
# 这里不断言注入请求的响应码：@Body 目前用默认 Json 解码（ignoreUnknownKeys=false），所以多塞
# 一个键会被直接 400；但那是框架的解码宽严，不是本场景要守的东西 —— 哪天有人为兼容客户端
# 放宽了它，提组依然必须失败。所以只断言不变量：无论注入请求结局如何，自助路径写不进
# group_override；并额外走一遍干净请求，证明接口本身是通的（否则「零泄漏」只是接口坏掉的副作用）。
inj=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/token/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"name":"s29inj","groupOverride":"vip26"}')
# 按名字收窄：S28 为了测删除保护，用 SQL 给 harness 令牌写过 group_override
leak=$(q "SELECT COUNT(*) FROM gateway_tokens WHERE name LIKE 's29%' AND group_override IS NOT NULL")
mytok=$(curl -s --max-time 10 -X POST "$U/app/gateway/token/create" -H "Authorization: Bearer $GJWT" -H "$CT" \
  -d '{"name":"s29ok"}')
TID=$(echo "$mytok" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
go=$(q "SELECT COALESCE(group_override,'<null>') FROM gateway_tokens WHERE id=$TID")
[ "$leak" = "0" ] && [ -n "$TID" ] && [ "$go" = "<null>" ] \
  && pass "自助建 Key 提不了组：注入请求 HTTP=${inj} 且零泄漏行，干净请求建出令牌 ${TID} 的 group_override=${go}" \
  || fail "用户能自行提组: 泄漏行=${leak}(期望0) 干净建Key id=${TID} group_override=${go}(期望 <null>) 注入HTTP=${inj} body=$(head -c 200 "$GB")"
# 组管理只在 admin 组：app 组没有这条路由，且 admin 路由不带凭据必须拒
ratioBefore=$(q "SELECT ratio FROM gateway_groups WHERE id=$VIP26")
appgrp=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X PUT "$U/app/gateway/group/update" -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"id\":$VIP26,\"name\":\"x\",\"ratio\":\"0.1\"}")
noauth=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X PUT "$U/admin/gateway/group/update" -H "$CT" -d "{\"id\":$VIP26,\"name\":\"x\",\"ratio\":\"0.1\"}")
ratioNow=$(q "SELECT ratio FROM gateway_groups WHERE id=$VIP26")
# 倍率跟攻击前读到的值比，不硬编码 "2.0"：建组时过了 PricingCalc.normalize，它会剥掉尾随零，
# 库里存的是 "2"。写期望字面量会把「规范化行为」误报成「倍率被改了」。
[ "$appgrp" = "404" ] && [ "$noauth" = "401" ] && [ "$ratioNow" = "$ratioBefore" ] \
  && pass "提组入口只在管理端：/app 无此路由(${appgrp})、/admin 无凭据被拒(${noauth})、倍率未动(${ratioBefore}->${ratioNow})" \
  || fail "提组入口有洞: /app/gateway/group/update=${appgrp}(期望404) /admin 无凭据=${noauth}(期望401) ratio=${ratioBefore}->${ratioNow}(期望不变)"


echo "[S30] 充值入口：汇率没配就拒绝，不静默按 1:1 发额度"
# 此时是清洁启动（S23 起就没带 env），NEWGATE_QUOTA_PER_PRICE_UNIT 未设。
# 静默 1:1 的后果是「充 100 得 100 μUSD」—— 数字太小看不出问题，而换成 1:1000 的部署
# 就是白送一千倍额度，且台账上一切正常。所以必须拒绝，而且原因要能查到。
# 框架对未分类异常一律回 500 + "Internal Server Error"（message 不进信封，见
# BufferedHttpDispatcher 的兜底分支），真实原因异步落 infra_api_error_logs（infra 的
# DbErrorLogWriter）—— 这里连它一起断言：光拒绝不够，运维得能查出是哪个环变量没配。
nrc0=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
ntx0=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'gateway:quota:%'")
nlog0=$(q "SELECT COUNT(*) FROM infra_api_error_logs")
# 余额用「请求前后不变」而不是绝对值：走到这里 S26(c)/S27 已经真扣过费（共 37500），
# 写 100000000 等于把前面场景的花费误报成「充值入口漏了额度」。
balBefore=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
r1=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"sandbox_alipay"}')
nrc1=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
ntx1=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'gateway:quota:%'")
bal0=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$r1" = "500" ] && [ "$nrc1" = "$nrc0" ] && [ "$ntx1" = "$ntx0" ] && [ "$bal0" = "$balBefore" ] \
  && pass "汇率未配 → 500、零意图单(${nrc1})、零发放(${ntx1})、余额未动(${balBefore}->${bal0})" \
  || fail "缺汇率没有干净拒绝: HTTP=${r1}(期望500) 意图单=${nrc0}->${nrc1} 台账=${ntx0}->${ntx1} 余额=${balBefore}->${bal0}(期望不变) body=$(head -c 160 "$GB")"
sleep 1   # 错误日志是 logScope.launch 异步写的，不等就会读到旧值
nlog1=$(q "SELECT COUNT(*) FROM infra_api_error_logs")
errmsg=$(q "SELECT COALESCE(exception_message,'') FROM infra_api_error_logs ORDER BY id DESC LIMIT 1")
[ "$nlog1" -gt "$nlog0" ] && echo "$errmsg" | grep -q 'NEWGATE_QUOTA_PER_PRICE_UNIT' \
  && pass "拒绝的原因落库可查：infra_api_error_logs ${nlog0}->${nlog1} 行，exception_message 指名了缺的环变量" \
  || fail "拒绝原因不可查: 错误日志 ${nlog0}->${nlog1} 行（若为 0 行则 ErrorLogWriter 未落库）最新一条='${errmsg}'"
# channelCode 必填：payment 没有「默认渠道」这回事（PayOrderLogic.resolveRoute 收到 null 直接判不可用），
# 留空只会在下单那步才 400，白白在钱据表里留一张开完就关的单 —— 对账时那是纯噪声。
r2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100}')
nrc2=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
[ "$r2" = "400" ] && [ "$nrc2" = "$nrc0" ] \
  && pass "缺 channelCode → 400 且不留意图单(${nrc2})，校验在建单之前" \
  || fail "缺 channelCode 处理不对: HTTP=${r2}(期望400) 意图单=${nrc0}->${nrc2}(期望不变)"

# ══ 以下五个场景需要会员组计费与充值汇率，故重启带 env ══
# 重启后重取 JWT（与 :582 / :617 / :700 同一惯例）。后面没有场景了，所以末尾不需要
# 再还原成清洁启动：cleanup 会杀掉进程并 drop 整个库，没有东西会被污染。
stop_app; boot_app NEWGATE_MEMBER_GROUP_BILLING=true NEWGATE_QUOTA_PER_PRICE_UNIT=1000
GJWT=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)

echo "[S31] 在途改会员组映射：按下单时冻结的快照计价"
# 装配层的 MemberGroupPort 是 `MemberTable.get(userId)?.groupId` —— 每次解析都活读 DB，没缓存。
# 所以本场景真的能测到东西：如果结算重查组，中途改成 ratio 5.0 的组就会把 15000 变成 37500。
# S17 测的是「在途改模型价/改 default 组倍率」，这里测的是「在途换掉用户所属的组」—— 另一条路径。
seed_reset; fake slowok 9932; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-snap31','openai_compatible','http://127.0.0.1:9932','default,vip26,hot31','m-snap31',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-snap31'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-snap31','2.5','10','0','0',5000,'manual',0,0,0);
   INSERT INTO member_groups (id,name,status,created_at,updated_at) VALUES (9927,'热点会员组',1,0,0) ON CONFLICT (id) DO NOTHING;
   UPDATE member_users SET group_id=9926 WHERE id=1;
   UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null
# 组与映射走管理端 API 建（而不是直插 SQL）：顺便让 requireMappingFree 与会员组列真的跑一遍
hot=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"code":"hot31","name":"热点三十一","ratio":"5.0","memberGroupId":9927}')
mp=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X PUT "$U/admin/gateway/group/update" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"id\":$VIP26,\"name\":\"贵宾二十六\",\"ratio\":\"2.0\",\"memberGroupId\":9926}")
if [ "$hot" != "200" ] || [ "$mp" != "200" ]; then
  fail "S31 前置失败：建 hot31=${hot} 映射 vip26->9926=${mp} body=$(head -c 200 "$GB")"
else
  relay31() { curl -s --max-time 25 -o "$GB" -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-snap31","messages":[]}'; }
  charged31() { q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-snap31' ORDER BY id DESC LIMIT 1"; }
  # 对照一：映射生效时按 vip26 的 ratio 2.0 收 15000（不是 default 的 7500，也不是 hot31 的 37500）
  c0=$(relay31); sleep 1; s0=$(charged31)
  # 在途改组：上游 2s 慢响应，sleep 1 后请求必然已预留、未结算
  ( relay31 >/tmp/s31-code-$$ ) & CURL31=$!
  sleep 1
  q "UPDATE member_users SET group_id=9927 WHERE id=1" >/dev/null
  wait "$CURL31"; sleep 1
  ci=$(cat /tmp/s31-code-$$ 2>/dev/null); rm -f /tmp/s31-code-$$
  si=$(charged31)
  # 对照二：变更生效后的**新**请求按 hot31 的 5.0 收 37500。这一发是关键：
  # 没它就无法区分「快照真的冻结了」与「会员组映射根本没生效」（后者也会停在 15000）。
  c2=$(relay31); sleep 1; s2=$(charged31)
  q "UPDATE member_users SET group_id=9926 WHERE id=1" >/dev/null   # 还原，不污染后续场景
  [ "$c0" = "200" ] && [ "$s0" = "15000" ] && [ "$ci" = "200" ] && [ "$si" = "15000" ] && [ "$c2" = "200" ] && [ "$s2" = "37500" ] \
    && pass "在途改会员组不改本次计价：改前=${s0} 在途=${si}（仍按 vip26 的 2.0）改后新请求=${s2}（按 hot31 的 5.0）" \
    || fail "在途改组影响了计价: 改前=${c0}/${s0}(期望200/15000) 在途=${ci}/${si}(期望200/15000) 改后=${c2}/${s2}(期望200/37500)"
fi

echo "[S32] 充值闭环：下单 → 回调 → 入账，并发/重投只入一次"
# 模拟支付靠全局设置开（payment.mock.enabled）；payment V001 已种子 sandbox_alipay 渠道。
# value_type 列不填：它只是后台渲染控件的冗余元数据（权威在代码里的 SettingDefinition），
# currentValue() 只读 value。
seed_reset
q "INSERT INTO system_settings (category,setting_key,value,name,created_at,updated_at)
     VALUES ('payment','payment.mock.enabled','true','模拟支付模式',0,0)
     ON CONFLICT (setting_key) DO UPDATE SET value='true';
   DELETE FROM gateway_quota_recharges;" >/dev/null
rc32=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"sandbox_alipay"}')
jdata() { python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('$1',''))" < "$GB" 2>/dev/null; }
RID=$(jdata rechargeId); MOID=$(jdata merchantOrderId); AMT=$(jdata amountMicro)
poid=$(q "SELECT COALESCE(pay_order_id,0) FROM gateway_quota_recharges WHERE id=${RID:-0}")
[ "$rc32" = "200" ] && [ "$AMT" = "100000" ] && [ "$MOID" = "gateway:quota:$RID" ] && [ "$poid" != "0" ] \
  && pass "下单：price=100 × 汇率1000 → amountMicro=${AMT}、merchantOrderId=${MOID}、pay_order_id 已回填(${poid})" \
  || fail "下单不对: HTTP=${rc32} amountMicro=${AMT}(期望100000) merchantOrderId=${MOID} pay_order_id=${poid} body=$(head -c 200 "$GB")"
# 5 路并发回调：真实渠道会重试，运维也会手工补单。三层幂等里这里靠的是
# payment 的 status 早退与 markPaid 的乐观锁占位；极端竞态下还有 ref 唯一约束兜底。
# 必须 wait 到具体 PID：裸 wait 会等上 fake 服务器与网关（它们是同一 shell 的后台子进程）。
CODES=/tmp/s32-codes-$$; : > "$CODES"; CB=""
for i in 1 2 3 4 5; do
  curl -s --max-time 15 -o /dev/null -w "%{http_code}\n" -X POST "$U/app/pay/channel-notify/sandbox_alipay/mock-success" \
    -H "$CT" -d "{\"merchantOrderId\":\"$MOID\"}" >> "$CODES" & CB="$CB $!"
done
wait $CB; sleep 1
ok32=$(grep -c '^200$' "$CODES"); rm -f "$CODES"
bal32=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
ntx32=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$MOID'")
ps32=$(q "SELECT pay_status FROM gateway_quota_recharges WHERE id=$RID")
pos32=$(q "SELECT status FROM pay_orders WHERE merchant_order_id='$MOID'")
[ "$bal32" = "100100000" ] && [ "$ntx32" = "1" ] && [ "$ps32" = "1" ] && [ "$pos32" = "1" ] \
  && pass "5 路并发回调（${ok32}/5 返回200）只入账一次：余额 100000000→${bal32}(+100000)、台账 ${ntx32} 条、充值单与支付单均已支付" \
  || fail "并发回调没幂等: 余额=${bal32}(期望100100000) 台账=${ntx32}(期望1) pay_status=${ps32}(期望1) pay_orders.status=${pos32}(期望1) 200数=${ok32}"
# 串行重投：此时支付单已 SUCCESS，updateSuccess 在 publish 之前就早退了，根本不会二次发事件
curl -s --max-time 15 -o /dev/null -X POST "$U/app/pay/channel-notify/sandbox_alipay/mock-success" -H "$CT" -d "{\"merchantOrderId\":\"$MOID\"}"
sleep 1
bal32b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
ntx32b=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$MOID'")
[ "$bal32b" = "$bal32" ] && [ "$ntx32b" = "1" ] \
  && pass "串行重投不再入账：余额仍 ${bal32b}、台账仍 ${ntx32b} 条" \
  || fail "重投又入账了: 余额 ${bal32}→${bal32b} 台账 ${ntx32}→${ntx32b}"

echo "[S33] 入账失败可恢复：整笔回滚，不留「付了钱没额度」也不留「已支付但台账没记」"
rc33=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":50,"channelCode":"sandbox_alipay"}')
RID2=$(jdata rechargeId); MOID2="gateway:quota:$RID2"
# 伪装成「已关闭」：markPaid 见到非待支付状态会抛，异常沿 SYNC 监听者传回 payment 的
# updateSuccess 事务 → 整笔回滚。这正是想要的：宁可支付单停在未支付（可重投），
# 也不要它变成已支付而额度没发 —— 后者没人会再去看，钱就静静消失了。
q "UPDATE gateway_quota_recharges SET pay_status=2 WHERE id=$RID2" >/dev/null
cb33=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/app/pay/channel-notify/sandbox_alipay/mock-success" -H "$CT" -d "{\"merchantOrderId\":\"$MOID2\"}")
sleep 1
pos33=$(q "SELECT status FROM pay_orders WHERE merchant_order_id='$MOID2'")
ntx33=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$MOID2'")
bal33=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$cb33" != "200" ] && [ "$pos33" = "0" ] && [ "$ntx33" = "0" ] && [ "$bal33" = "$bal32" ] \
  && pass "入账失败 → 整笔回滚：回调 HTTP=${cb33}、支付单仍待支付(status=${pos33})、台账 ${ntx33} 条、余额未动(${bal33})" \
  || fail "入账失败没有整笔回滚: HTTP=${cb33} pay_orders.status=${pos33}(期望0) 台账=${ntx33}(期望0) 余额=${bal33}(期望${bal32})"
# 修好原因后重投即可到账：失败必须是**可恢复**的，而不是一次失败就把这笔钱永久卡住
q "UPDATE gateway_quota_recharges SET pay_status=0 WHERE id=$RID2" >/dev/null
cb33b=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/app/pay/channel-notify/sandbox_alipay/mock-success" -H "$CT" -d "{\"merchantOrderId\":\"$MOID2\"}")
sleep 1
pos33b=$(q "SELECT status FROM pay_orders WHERE merchant_order_id='$MOID2'")
ntx33b=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$MOID2'")
bal33b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
ps33b=$(q "SELECT pay_status FROM gateway_quota_recharges WHERE id=$RID2")
[ "$cb33b" = "200" ] && [ "$pos33b" = "1" ] && [ "$ntx33b" = "1" ] && [ "$bal33b" = "100150000" ] && [ "$ps33b" = "1" ] \
  && pass "重投即恢复：支付单转已支付、台账 1 条、余额 ${bal33}→${bal33b}(+50000)" \
  || fail "重投没恢复: HTTP=${cb33b} pay_orders.status=${pos33b}(期望1) 台账=${ntx33b}(期望1) 余额=${bal33b}(期望100150000) pay_status=${ps33b}(期望1)"

echo "[S34] 钱包充值不增网关额度（两个账本不共用余额）"
# 同一笔支付不能既进钱包又进网关额度：那样一次付款发放两份价值。
# 分流靠 merchant_order_id 前缀，两个监听者各认各的：网关那个对 `wallet:recharge:` 直接 return，
# 钱包那个对 `gateway:quota:` 也一样 —— 任何一方误认都会在账面上多出一份钱。
nrc34=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
gbal34=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
w1=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/pay/wallet-recharge/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"totalPrice":200,"payPrice":200,"bonusPrice":0}')
WRID=$(python3 -c "import sys,json;print(json.load(sys.stdin).get('data',''))" < "$GB" 2>/dev/null)
w2=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/app/pay/wallet-recharge/submit?rechargeId=$WRID&channelCode=sandbox_alipay" \
  -H "Authorization: Bearer $GJWT")
w3=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/app/pay/channel-notify/sandbox_alipay/mock-success" \
  -H "$CT" -d "{\"merchantOrderId\":\"wallet:recharge:$WRID\"}")
sleep 1
wps=$(q "SELECT pay_status FROM pay_wallet_recharges WHERE id=${WRID:-0}")
wbal=$(q "SELECT COALESCE(balance,-1) FROM pay_wallets WHERE user_id=1")
nrc34b=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
gbal34b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
ngtx=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='wallet:recharge:$WRID'")
[ "$w1" = "200" ] && [ "$w2" = "200" ] && [ "$w3" = "200" ] && [ "$wps" = "1" ] && [ "$wbal" = "200" ] \
  && [ "$nrc34b" = "$nrc34" ] && [ "$gbal34b" = "$gbal34" ] && [ "$ngtx" = "0" ] \
  && pass "钱包充值 200 只进钱包（pay_wallets.balance=${wbal}）：网关充值单 ${nrc34}→${nrc34b}、网关余额仍 ${gbal34b}、台账无以 wallet: 为 ref 的记录" \
  || fail "两个账本串了: 建单=${w1} 发起=${w2} 回调=${w3} 钱包pay_status=${wps}(期望1) 钱包余额=${wbal}(期望200) 网关充值单=${nrc34}->${nrc34b} 网关余额=${gbal34}->${gbal34b} wallet前缀台账=${ngtx}(期望0)"

echo "[S35] 会员组没配计费组 → 403，且 5xx/4xx 的日志级别分得开"
# 解析第 3 层的拒绝：member_users.group_id 命中了，但没有 gateway_groups.member_group_id 指向它。
# 这是部署决策（这批用户没开通），不是故障 —— 配置不变就永远 403，回 5xx 客户端会一直重试撞墙，
# 与 RelayEngine 里 no_candidate 非 retryable 走 404 是同一条标准（见 GroupReject 的 KDoc）。
# 拒绝走 respondError、不抛异常，所以框架那条「5xx → 落 infra_api_error_logs」的路径不可达，
# 日志级别就是运营唯一的告警面 —— 于是级别本身要锁：5xx 类必须 ERROR，403 必须留 WARN。
# 注意：error.log 收的是 WARN+（不是只有 ERROR），所以断言读级别字段，不读文件归属。
#
# 模型名在这里是**无关变量**：S32 的 seed_reset 已 TRUNCATE 掉渠道与价格，此刻没有任何可用模型。
# 这不是疏漏 —— resolve 在 RelayEngine 里排在选渠道之前（:97 vs :125），拒绝必然先发生。但只有
# 403 一条断言的话，「403 只是环境反正跑不通的副产品」这个可能排除不掉（S29 犯过同类错）。
# 所以补一个对照组：把映射还原后同一发请求必须**换个失败原因**，证明解析这一层已经放行、
# 403 确实由 group_id=9999 造成，而不是普遍坏掉。对照组的期望值是 **503 no_available_channel**
# 而不是 404：渠道表为空时 noCandidateReason 第一层就返回 NO_CHANNEL_ENABLED，而它的
# retryable=true（渠道全下线是运维态、可能自行恢复，与「模型根本没配」不同）。
q "UPDATE member_users SET group_id=9999 WHERE id=1" >/dev/null
na=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/v1/chat/completions" \
  -H "$AUTH" -H "$CT" -d '{"model":"m-snap31","messages":[]}')
nabody=$(grep -c "billing_group_not_allowed" "$GB")
q "UPDATE member_users SET group_id=9926 WHERE id=1" >/dev/null
ctl=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/v1/chat/completions" \
  -H "$AUTH" -H "$CT" -d '{"model":"m-snap31","messages":[]}')
ctlbody=$(grep -c "no_available_channel" "$GB")
sleep 1   # 日志异步落盘，与 S30 等错误日志同理
loglvl() { grep "reason=$1" "$WORK/logs/all.log" 2>/dev/null | tail -1 | grep -oE " (ERROR|WARN|INFO) " | tr -d ' '; }
nalvl=$(loglvl NOT_ALLOWED)
cblvl=$(loglvl CONFIG_BROKEN)
cbn=$(grep -c "reason=CONFIG_BROKEN" "$WORK/logs/all.log" 2>/dev/null)
[ "$na" = "403" ] && [ "$nabody" = "1" ] && [ "$ctl" = "503" ] && [ "$ctlbody" = "1" ] \
  && [ "$nalvl" = "WARN" ] && [ "$cblvl" = "ERROR" ] && [ "${cbn:-0}" -ge 2 ] \
  && pass "会员组未映射 → 403 billing_group_not_allowed（对照：映射还原后同一发变 503 no_available_channel，已走到选渠道阶段，证明拒绝出自解析层）；告警级别分得开：NOT_ALLOWED=${nalvl}、CONFIG_BROKEN=${cblvl}(${cbn} 行)" \
  || fail "未映射会员组的处置不对: HTTP=${na}(期望403) body命中=${nabody}(期望1) 对照组=${ctl}(期望503)/${ctlbody}(期望1) NOT_ALLOWED级别=${nalvl}(期望WARN) CONFIG_BROKEN级别=${cblvl}(期望ERROR，${cbn:-0}行)"

rm -f "$GB"

echo "═══ 结果：$PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ] || { echo "详细日志见 $LOGS/"; exit 1; }
