#!/usr/bin/env bash
# NewGate 可靠性 harness：本机共享 PostgreSQL 上的「隔离测试数据库」+ 假上游 + 真实网关，逐场景自动断言。
# 一条命令：./harness/run.sh   失败即 exit 1，日志留 harness/logs/。
# 注意：这是「每次隔离一个临时 database」，不是「每次拉起隔离 PostgreSQL 实例」；依赖本机 5432、
#   固定应用端口 8080、固定 fake 端口 9920–9991。真正 CI 应改用 PostgreSQL service/container +
#   动态分配应用/​fake 端口（列为紧接着的下一提交，见 SPEC「仍待办」）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NEWGATE="$ROOT/newgate"
APP="$NEWGATE/application/build/bin/macosArm64/debugExecutable/application.kexe"
LOGS="$HERE/logs"; mkdir -p "$LOGS"
DB="newgate_harness_$$"
TOKEN_PLAINTEXT="sk-harness-token-000000000000000000000000000000000000"
TOKEN_HASH="$(python3 -c "import hashlib;print(hashlib.sha256('$TOKEN_PLAINTEXT'.encode()).hexdigest())")"
AUTH="Authorization: Bearer $TOKEN_PLAINTEXT"; CT="Content-Type: application/json"; U="http://localhost:8080"
PGUSER="${PGUSER:-$(whoami)}"; PGPASS="${PGPASS:-privchat}"; export PGPASSWORD="$PGPASS"
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
seed_reset() { q "TRUNCATE gateway_channels,gateway_channel_keys,gateway_model_prices,gateway_usage_logs,gateway_quota_transactions RESTART IDENTITY;
  UPDATE gateway_quota_accounts SET balance=100000000, version=version WHERE user_id=1;
  UPDATE gateway_tokens SET quota_used=0, quota_budget=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null; }

fake() { MODE="$1" PORT="$2" python3 "$HERE/fakes.py" >/dev/null 2>&1 & PIDS+=($!); }

echo "═══ NewGate 可靠性 harness (DB=$DB) ═══"

# ── 前置：编译 + 隔离库 + 迁移 + 基础令牌/账户 ──
echo "[build] linking app…"
( cd "$NEWGATE" && ./gradlew :application:linkDebugExecutableMacosArm64 -q ) || { echo "build failed"; exit 1; }
createdb -U "$PGUSER" "$DB" || { echo "createdb failed"; exit 1; }
# 隔离 workdir：config/ 指向隔离库；app 与 migrate 都从此目录启动（config 相对 CWD 解析）
WORK="$LOGS/work-$$"; mkdir -p "$WORK/config" "$WORK/logs"
cp "$NEWGATE/application/config/"*.conf "$WORK/config/"
cat > "$WORK/config/database.conf" <<EOF
[default]
driver = "POSTGRESQL"
uri = "postgresql://$PGUSER:$PGPASS@localhost:5432/$DB"
debug = false
[migration]
history_table = "neton_schema_history"
EOF
( cd "$WORK" && "$APP" migrate up >"$LOGS/migrate.log" 2>&1 ) || { echo "migrate failed, see $LOGS/migrate.log"; tail -3 "$LOGS/migrate.log"; exit 1; }
# 基础令牌 + 账户（member 用户 id=1 由迁移种子提供；harness 直插 gateway 令牌）
q "INSERT INTO gateway_quota_accounts (user_id,balance,version,created_at,updated_at) VALUES (1,100000000,0,0,0) ON CONFLICT (user_id) DO UPDATE SET balance=100000000;
   INSERT INTO gateway_tokens (user_id,name,key_hash,key_display,status,deleted,created_at,updated_at) VALUES (1,'harness','$TOKEN_HASH','sk-harn****0000',1,0,0,0) ON CONFLICT (key_hash) DO NOTHING;" >/dev/null

echo "[boot] starting gateway…"
( cd "$WORK" && "$APP" >"$LOGS/app.log" 2>&1 ) & PIDS+=($!)
ready=0; for i in $(seq 1 40); do curl -s --max-time 2 -o /dev/null "$U/" && { ready=1; break; }; sleep 0.5; done
[ "$ready" = "1" ] || { echo "gateway 未就绪（20s 超时），见 $LOGS/app.log"; exit 1; }

CID() { q "SELECT id FROM gateway_channels WHERE name='$1'"; }

# ══ S1 并发账务四项不变量 ══
echo "[S1] 并发结算四项不变量"
seed_reset; fake ok 9990; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-ok','openai_compatible','http://127.0.0.1:9990','default','m-ok',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-ok'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,source,deleted,created_at,updated_at) VALUES ('m-ok','2.5','10','0','0','manual',0,0,0);" >/dev/null
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
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,source,deleted,created_at,updated_at) VALUES ('m-fo','1','1','0','0','manual',0,0,0);" >/dev/null
n=$(curl -sN --max-time 15 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-fo","stream":true,"messages":[]}' | grep -c "^data:")
[ "$n" -ge 3 ] && pass "流式 dead→live 重试成功（$n data 行）" || fail "流式重试失败（$n data 行）"

# ══ S3 非零断连真实扣款 + producer 无残留 ══
echo "[S3] 非零断连计费 + producer 无残留"
seed_reset; fake bigstream 9960; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('big','openai_compatible','http://127.0.0.1:9960','default','m-pr',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='big'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,source,deleted,created_at,updated_at) VALUES ('m-pr','0','0','0','0',5000,'manual',0,0,0);" >/dev/null
curl -sN --max-time 1 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-pr","stream":true,"messages":[]}' >/dev/null 2>&1; sleep 3
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-pr' ORDER BY id DESC LIMIT 1")
ta=$(q "SELECT -amount FROM gateway_quota_transactions WHERE ref LIKE 'usage:%' ORDER BY id DESC LIMIT 1")
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
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,source,deleted,created_at,updated_at) VALUES ('m-403','1','1','0','0','manual',0,0,0),('m-429','1','1','0','0','manual',0,0,0);" >/dev/null
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
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,source,deleted,created_at,updated_at) VALUES ('m-rv','1','1','0','0','manual',0,0,0);" >/dev/null
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
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,source,deleted,created_at,updated_at) VALUES ('m-td','0','0','0','0',5000,'manual',0,0,0);" >/dev/null
b0=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
( curl -sN --max-time 2 -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-td","stream":true,"messages":[]}' >/dev/null 2>&1 ) & CURL_PID=$!
sleep 0.6; q "DELETE FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'" >/dev/null; wait "$CURL_PID"; sleep 2
lc=$(q "SELECT charged FROM gateway_usage_logs WHERE request_model='m-td' ORDER BY id DESC LIMIT 1")
bd=$(q "SELECT $b0-balance FROM gateway_quota_accounts WHERE user_id=1")
warn=$(grep -c "token deleted mid-request" "$WORK/logs/all.log")
[ -n "$lc" ] && [ "$lc" = "$bd" ] && [ "$warn" -ge 1 ] && pass "token 删后账户三项一致 charged=$lc balanceΔ=$bd + warn" || fail "token 删账务错: charged=$lc balanceΔ=$bd warn=$warn"
q "INSERT INTO gateway_tokens (user_id,name,key_hash,key_display,status,deleted,created_at,updated_at) VALUES (1,'harness','$TOKEN_HASH','sk-harn****0000',1,0,0,0) ON CONFLICT DO NOTHING" >/dev/null

echo "═══ 结果：$PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ] || { echo "详细日志见 $LOGS/"; exit 1; }
