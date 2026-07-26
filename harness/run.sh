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
seed_reset() { q "TRUNCATE gateway_channels,gateway_channel_keys,gateway_model_prices,gateway_usage_logs,gateway_quota_transactions,gateway_settlements RESTART IDENTITY;
  UPDATE gateway_quota_accounts SET balance=100000000, reserved_balance=0, version=version WHERE user_id=1;
  UPDATE gateway_tokens SET quota_used=0, quota_reserved=0, quota_budget=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null; }

fake() { MODE="$1" PORT="$2" python3 "$HERE/fakes.py" >/dev/null 2>&1 & PIDS+=($!); }

echo "═══ NewGate 可靠性 harness (DB=$DB) ═══"

# ── 前置：编译 + 隔离库 + 迁移 + 基础令牌/账户 ──
echo "[build] linking app…"
( cd "$NEWGATE" && ./gradlew :application:linkDebugExecutableMacosArm64 -q ) || { echo "build failed"; exit 1; }
createdb -U "$PGUSER" "$DB" || { echo "createdb failed"; exit 1; }
# 隔离 workdir：config/ 指向隔离库；app 与 migrate 都从此目录启动（config 相对 CWD 解析）
# 只保留最近 2 次运行的 work 目录，避免长期跑 harness 占满磁盘
ls -dt "$LOGS"/work-* 2>/dev/null | tail -n +3 | xargs rm -rf 2>/dev/null
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
# settlement 终态：FINALIZED + 预留归零（V004 核心不变量）
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

# ══ S14 令牌 IP 白名单 ══
echo "[S14] IP 白名单"
seed_reset
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c-ip','openai_compatible','http://127.0.0.1:9880','default','m-ip',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c-ip'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,per_request_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-ip','0','0','0','0',100,5000,'manual',0,0,0);
   UPDATE gateway_tokens SET allowed_ips='203.0.113.7' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
deny=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 198.51.100.9" -d '{"model":"m-ip","messages":[]}')
allow=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -H "X-Forwarded-For: 203.0.113.7" -d '{"model":"m-ip","messages":[]}')
lg=$(q "SELECT COUNT(*) FROM gateway_usage_logs")
q "UPDATE gateway_tokens SET allowed_ips='' WHERE key_hash='${TOKEN_HASH}';" >/dev/null
[ "$deny" = "403" ] && [ "$allow" = "200" ] && [ "$lg" = "1" ] \
  && pass "IP 白名单：名单外 403、名单内 200、仅 1 条计费" \
  || fail "IP 白名单错: 名单外=${deny} 名单内=${allow} 计费条数=${lg}"

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

echo "═══ 结果：$PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ] || { echo "详细日志见 $LOGS/"; exit 1; }
