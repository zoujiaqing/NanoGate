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
# 等某条计数查询达到期望值（非流式先响应后计费：客户端拿到 200 时结算还在 NonCancellable 里写库）。
# 有界轮询代替裸 sleep：到点仍不等就原值返回，交给调用方断言——多写一条同样会被 = 抓住。
wait_rows() { local sql=$1 want=$2 tries=${3:-25} v; for _ in $(seq 1 "$tries"); do v=$(q "$sql"); [ "$v" = "$want" ] && break; sleep 0.2; done; echo "$v"; }
q() { psql -U "$PGUSER" -d "$DB" -tAc "$1" 2>/dev/null; }
# Redis 断言助手：只碰本次拉起的隔离实例的隔离 db。键名带 keyPrefix（配置里可变），
# 故一律用 *ngrl:* 通配匹配，不把前缀写死在断言里。
rc() { redis-cli -p "$REDIS_PORT" -n "$REDIS_DB" "$@" 2>/dev/null; }
rksum() { local k v s=0; for k in $(rc --scan --pattern "$1"); do v=$(rc get "$k"); s=$((s + ${v:-0})); done; echo "$s"; }
rkdel() { local k; for k in $(rc --scan --pattern "$1"); do rc del "$k" >/dev/null; done; }
seed_reset() { q "TRUNCATE gateway_channels,gateway_channel_keys,gateway_model_prices,gateway_usage_logs,gateway_quota_transactions,gateway_settlements RESTART IDENTITY;
  UPDATE gateway_quota_accounts SET balance=100000000, reserved_balance=0, version=version WHERE user_id=1;
  UPDATE gateway_tokens SET quota_used=0, quota_reserved=0, quota_budget=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null; }

# fake 是后台拉起的，bind 需要时间；以前每个调用点靠 `sleep 1` 等它，机器一忙就踩空。
# 踩空的症状会漂到断言里、指向错误的原因：实测 S8 的上游没起来 → relay 失败 → 没有 consume
# 台账 → ref 为空 → 那条手插的 ref='' 既不撞唯一约束、又数出 cnt=1、余额也不动，看起来跟
# 「幂等约束失效」一模一样。所以在这里等端口真能连上（最多 5s）；25 个调用点的 sleep 一律
# 保留不动，只会更稳。探测用 bash 内建的 /dev/tcp 而不是 nc：本脚本本来就依赖 bash
# （数组、$(seq)），不该为此再引入一个 CI 上未必存在的外部命令。
fake() {
  MODE="$1" PORT="$2" python3 "$HERE/fakes.py" >/dev/null 2>&1 & PIDS+=($!)
  local i
  for i in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$2") >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "⚠️  上游 fake :$2 起不来（5s 内端口没开）—— 这条场景的断言会指向错误的原因" >&2
}

echo "═══ NanoGate 可靠性 harness (DB=$DB) ═══"

# ── 前置：编译 + 隔离库 + 迁移 + 基础令牌/账户 ──
echo "[build] linking app…"
# sqlx4k driver 编译期单选（一个 K/N 可执行文件只能链一个），选哪个由 gradle property
# neton.database.driver 决定，默认 postgres。这里**显式**传而不吃默认值：下面写的
# database.conf 是 POSTGRESQL，两者必须一致，而「默认值」是会被别处改写的 ——
# neton-database 的 build 目录被所有把 Neton/neton 当 composite build 的项目共享，
# 而 privchat-application/settings.gradle.kts 会给测试调用注入 =sqlite。up-to-date 状态是按
# 各自 root build 的历史算的，于是本项目这边判 compileKotlinMacosArm64 UP-TO-DATE、
# 拿别人留下的 sqlite klib 去链接（或者 link 自己也判 UP-TO-DATE，直接复用那个已经链错的
# kexe —— 实测两种都发生过）。产物一跑就死在 NETON-DB-VARIANT mismatch。
DB_VARIANT=postgres
link_app() { ( cd "$NEWGATE" && ./gradlew "$LINK_TASK" -q -Pneton.database.driver="$DB_VARIANT" ); }
link_app || { echo "build failed"; exit 1; }
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
  # NETON-DB-VARIANT mismatch 不是 database.conf 写错，而是链进二进制的 sqlx4k variant 不对，
  # 成因见上面 link_app 的注释。两种形状都实测过：link 重跑了、但吃到别人留下的 klib（04:59）；
  # 以及 link 自己判 UP-TO-DATE、直接复用那个已经链错的 kexe（05:08）。
  # 自愈一次：--rerun-tasks 把整条链（含框架的 neton-database）在同一次调用里重编重链。
  # 只 clean + 重链不够：那样 compileKotlinMacosArm64 仍按本项目的历史判 UP-TO-DATE，
  # klib 还是别人留下的那份 sqlite。但这也不是万无一失：重编与重链之间有一分钟量级的窗口，
  # 兄弟项目正好在这时写入的话，本次 link 又会吃到 sqlite（实测 2026-09-08 05:04：
  # --rerun-tasks -Ppostgres 跑完，kexe 仍是 sqlite variant）。所以下面还留了「自愈后仍不匹配」
  # 那条分支 —— 那种情况只能等对方的构建跑完再重跑。
  if grep -q 'NETON-DB-VARIANT' "$LOGS/migrate.log"; then
    echo "  ⚠️  链进二进制的 sqlx4k variant 不是 ${DB_VARIANT}（多半是共享 Neton/neton 的兄弟项目刚用" >&2
    echo "     -Pneton.database.driver=sqlite 跑过测试）：--rerun-tasks 重编重链一次…" >&2
    ( cd "$NEWGATE" && ./gradlew "$LINK_TASK" -q --rerun-tasks -Pneton.database.driver="$DB_VARIANT" ) \
      || { echo "rebuild failed"; exit 1; }
    if ! ( cd "$WORK" && "$APP" migrate up >"$LOGS/migrate.log" 2>&1 ); then
      echo "  ⚠️  自愈后仍不匹配：有别的构建正在并发改写那份共享 klib，等它跑完再重跑 harness" >&2
      echo "migrate failed, see $LOGS/migrate.log"; tail -3 "$LOGS/migrate.log"; exit 1
    fi
  else
    echo "migrate failed, see $LOGS/migrate.log"; tail -3 "$LOGS/migrate.log"; exit 1
  fi
fi
# 基础令牌 + 账户（harness 直插 gateway 令牌）。
# ⚠️ member_users **没有迁移种子**：admin/admin123 那个用户来自 module-infra 的 system_users，
# member 侧的 id=1 是 S26 自己 INSERT 出来的。这一行原本写的是「member 用户 id=1 由迁移种子
# 提供」，全仓 SQL 里根本没有那条 INSERT —— 它把一次「能不能开户」的排查带偏了很久。
# 顺带记下相关事实：member_users_id_seq 由迁移 setval 到 GREATEST(MAX(id),10000)，所以 S26 显式
# 插的 id=1 与 sms-login 自动注册取到的号（10000 起）不会撞。
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
h8=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/v1/chat/completions" -H "$AUTH" -H "$CT" -d '{"model":"m-idem","messages":[]}'); sleep 1
ref=$(q "SELECT ref FROM gateway_quota_transactions WHERE type='consume' ORDER BY id DESC LIMIT 1")
b1=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
if [ "$h8" != "200" ] || [ -z "$ref" ]; then
  # 前置不成立就**别**去断言幂等：请求没成功就不会有 consume 台账，ref 为空会让下面那条手插的
  # ref='' 既不撞唯一约束、又数出 cnt=1、余额也不动 —— 症状跟「约束失效」完全一样。
  # 这条场景真这么误报过一次（真因是上游 fake 没起来），所以把前置单独判掉、只报一条准的。
  fail "S8 前置没成立：relay HTTP=$h8(期望200)、consume ref='${ref:-空}' —— 请求没成功，幂等约束与结算终态这次都没被测到（不是约束失效）"
else
  # 重放：手动以同一 ref 再插一条台账 → 唯一约束应拒绝（模拟重试/outbox 重放不重复扣）
  duperr=$(psql -U "$PGUSER" -d "$DB" -tAc "INSERT INTO gateway_quota_transactions (user_id,type,amount,balance_after,ref,created_at) VALUES (1,'consume',-9999,0,'$ref',0)" 2>&1)
  cnt=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$ref'")
  b2=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
  { echo "$duperr" | grep -qiE "duplicate|unique|uk_gateway_quota_tx_ref"; } && rejected=1 || rejected=0
  [ "$rejected" = "1" ] && [ "$cnt" = "1" ] && [ "$b1" = "$b2" ] \
    && pass "重复 ref 被唯一约束拒绝(ref=$ref)、台账唯一(cnt=1)、余额不变" \
    || fail "幂等约束失效: ref=$ref rejected=$rejected cnt=$cnt bal=${b1}->${b2}"
  # settlement 终态：FINALIZED + 预留归零（V004-durable-settlement-design 的核心不变量）
  st=$(q "SELECT status FROM gateway_settlements ORDER BY id DESC LIMIT 1")
  rb=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
  qr=$(q "SELECT quota_reserved FROM gateway_tokens WHERE key_hash='$TOKEN_HASH'")
  [ "$st" = "FINALIZED" ] && [ "$rb" = "0" ] && [ "$qr" = "0" ] \
    && pass "settlement 终态 FINALIZED、预留归零(account=$rb token=$qr)" \
    || fail "settlement 终态错: status=$st reservedBalance=$rb quotaReserved=$qr"
fi

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
lg=$(wait_rows "SELECT COUNT(*) FROM gateway_usage_logs" 3)
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
# 三类引用必须**分别**被证明。GroupController.delete 的检查顺序是 令牌覆盖 → 用户级例外 → 渠道 CSV，
# 先命中的先返回，所以只要令牌覆盖还在，「测用户级例外」那一发拿到的其实是令牌那条原因 ——
# 409 是对的，原因却不是：把用户级例外那个 if 整块删掉，这条也照样绿。它此前正是这个状态
# （S27 把令牌的 group_override 设成 vip26 后一直没清，d1 与 d2 因此都在证明同一件事）。
# 于是每一发只留一类引用，并断言 409 的 message **点名**是哪一类 —— 点名才是真守卫。
q "UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH'" >/dev/null

# (1) 只剩用户级例外。走管理端 API 建（写路径本身由 S48 覆盖），要的是「生产上真会出现的那种引用」，
#     而不是一行手写 SQL —— 手写 SQL 正是悬空 group_code 的来源。
c28=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"vip26","remark":"大客户谈判价"}')
d1=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
m1=$(head -c 300 "$GB" 2>/dev/null)
a1=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
rm28=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group-override/delete/1" -H "Authorization: Bearer $GJWT")

# (2) 只剩令牌覆盖
q "UPDATE gateway_tokens SET group_override='vip26' WHERE key_hash='$TOKEN_HASH'" >/dev/null
d2=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
m2=$(head -c 300 "$GB" 2>/dev/null)
a2=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
q "UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH'" >/dev/null

# (3) 只剩渠道 CSV（c-grp 的 groups 一直是 'default,vip26'）
d3=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X DELETE "$U/admin/gateway/group/delete/$VIP26" -H "Authorization: Bearer $GJWT")
m3=$(head -c 300 "$GB" 2>/dev/null)
a3=$(q "SELECT deleted FROM gateway_groups WHERE id=$VIP26")
p1=$(printf '%s' "$m1" | grep -c 'per-user override')
p2=$(printf '%s' "$m2" | grep -c 'token group override')
p3=$(printf '%s' "$m3" | grep -c 'channel(s)')
[ "$c28" = "200" ] && [ "$rm28" = "200" ] \
  && [ "$d1" = "409" ] && [ "$a1" = "0" ] && [ "$p1" = "1" ] \
  && [ "$d2" = "409" ] && [ "$a2" = "0" ] && [ "$p2" = "1" ] \
  && [ "$d3" = "409" ] && [ "$a3" = "0" ] && [ "$p3" = "1" ] \
  && pass "三类引用分别被证明（各 409、组均仍在 deleted=0、message 各点名一类）：用户级例外(建=${c28}/撤=${rm28}) 点名=${p1}、令牌覆盖 点名=${p2}、渠道 CSV 点名=${p3}" \
  || fail "删除保护没分开证明: 建例外=${c28}(期望200) 撤例外=${rm28}(期望200) 例外=${d1}(期望409)/deleted=${a1}/点名=${p1}(期望1) 令牌=${d2}(期望409)/deleted=${a2}/点名=${p2}(期望1) 渠道=${d3}(期望409)/deleted=${a3}/点名=${p3}(期望1) m1=${m1:0:110} m2=${m2:0:110} m3=${m3:0:110}"

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

# ══ 以下场景跑在带 env 的这次启动上：S31–S35 需要会员组计费与充值汇率，故重启带 env；
# 其后的兑换码场景（S36+）复用同一次启动与同一个 admin JWT。
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

echo "[S36] 兑换码：生成 → 兑换 → 入账，重复兑换只入一次"
# 台账的 type='redeem' 与「ref = 兑换码」从 V001 起就预留着，此前没有任何代码会产生这种记录。
# 这里锁的不变量是「一码一次」：断言的不只是响应码，而是**拒绝 + 余额不变 + 台账仍一条**
# 三件事同时成立（与 S26 锁静默回落、S32 锁并发回调同一套路数）—— 只看状态码的话，
# 重复入账照样能返回 409。
gen36=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":50000,"count":3,"note":"S36 活动码"}')
batch36=$(printf '%s' "$gen36" | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('batchId',''))" 2>/dev/null)
c36=$(printf '%s' "$gen36" | python3 -c "import sys,json;print(' '.join((json.load(sys.stdin).get('data') or {}).get('codes',[])))" 2>/dev/null)
c1=$(echo "$c36" | cut -d' ' -f1)
# DB 存无分隔大写裸码、返回给运营的是分组展示形态，两边靠 normalize 对齐。这两条断的是设计本身：
# 只按字面量比对的话，运营发出去的码用户照着输入却兑不了，而后台看那张码明明还是未用。
raw36=$(q "SELECT code FROM gateway_redemption_codes WHERE batch_id='$batch36' ORDER BY id LIMIT 1")
c1bare=$(printf '%s' "$c1" | tr -d '-' | tr 'a-z' 'A-Z')
bal36=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
red36() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/redeem" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "$1"; }
d1=$(red36 "{\"code\":\"$c1\"}"); sleep 1
bal36a=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
tx1=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem' AND ref='redeem:$raw36'")
st1=$(q "SELECT status FROM gateway_redemption_codes WHERE code='$raw36'")
uu1=$(q "SELECT COALESCE(used_user_id,0) FROM gateway_redemption_codes WHERE code='$raw36'")
d2=$(red36 "{\"code\":\"$c1\"}"); sleep 1
bal36b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
tx2=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem' AND ref='redeem:$raw36'")
[ -n "$batch36" ] && [ "$c1bare" = "$raw36" ] && [ "$c1bare" != "$c1" ] \
  && [ "$d1" = "200" ] && [ "$bal36a" = "$((bal36+50000))" ] && [ "$tx1" = "1" ] && [ "$st1" = "1" ] && [ "$uu1" = "1" ] \
  && [ "$d2" = "409" ] && [ "$bal36b" = "$bal36a" ] && [ "$tx2" = "1" ] \
  && pass "兑换码入账：展示形态 ${c1} 归一后对上裸码 ${raw36}；首发 200 余额 ${bal36}→${bal36a}(+50000)、台账 ${tx1} 条、码已用且记了 used_user_id=${uu1}；重复兑换 409 且余额仍 ${bal36b}、台账仍 ${tx2} 条" \
  || fail "兑换码入账不对: batch=${batch36} 展示码=${c1} 裸码=${raw36} 归一=${c1bare} 首发=${d1}(期望200) 余额=${bal36}->${bal36a}->${bal36b}(期望+50000后不变) 台账=${tx1}/${tx2}(期望1/1) 码状态=${st1}(期望1) used_user_id=${uu1}(期望1) 重兑=${d2}(期望409)"

echo "[S37] 5 路并发兑同一张码：只有一发成功，账只入一次"
# 这是兑换码唯一的真风险：两个人（或同一个人开两个窗口）同时兑同一张码。
# 三层幂等在这里靠的是 ② 乐观锁占位（UPDATE ... WHERE status=未用，只有一个请求拿到 1 行）；
# 极端竞态下还有 ③ 台账 ref 唯一约束兜底 —— 撞约束会让整个事务回滚、码状态退回未用，
# 所以失败形态只能是「没兑上」，不会是「码没了钱也没到」。
# 与 S32 同理：必须 wait 到具体 PID，裸 wait 会等上 fake 服务器与网关。
gen37=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":30000,"count":1}')
c37=$(printf '%s' "$gen37" | python3 -c "import sys,json;print(((json.load(sys.stdin).get('data') or {}).get('codes') or [''])[0])" 2>/dev/null)
raw37=$(printf '%s' "$c37" | tr -d '-' | tr 'a-z' 'A-Z')
bal37=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
RC=/tmp/s37-codes-$$; : > "$RC"; RB=""
for i in 1 2 3 4 5; do
  curl -s --max-time 20 -o /dev/null -w "%{http_code}\n" -X POST "$U/app/gateway/redeem" \
    -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"code\":\"$c37\"}" >> "$RC" & RB="$RB $!"
done
wait $RB; sleep 1
ok37=$(grep -c '^200$' "$RC"); rm -f "$RC"
bal37a=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
tx37=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem' AND ref='redeem:$raw37'")
st37=$(q "SELECT status FROM gateway_redemption_codes WHERE code='$raw37'")
[ "$ok37" = "1" ] && [ "$tx37" = "1" ] && [ "$bal37a" = "$((bal37+30000))" ] && [ "$st37" = "1" ] \
  && pass "5 路并发兑同一张码（${ok37}/5 返回200）只入账一次：余额 ${bal37}→${bal37a}(+30000)、台账 ${tx37} 条、码状态已用" \
  || fail "并发兑换没幂等: 200数=${ok37}(期望1) 台账=${tx37}(期望1) 余额=${bal37}->${bal37a}(期望+30000) 码状态=${st37}(期望1)"

echo "[S38] 兑换码止损：作废/过期码兑不动，已用码不能作废，整批作废只动未用的"
# 作废是运营的止损手段（码外泄、活动取消）。这里锁三件事：
#  ① 作废与过期的码兑不动，且**余额与台账都不动** —— 只断 4xx 的话，「拒了但钱也发了」照样过；
#  ② 已用的码不能作废：那是历史事实，改它等于篡改账务（要收回额度得另记一条调整台账）；
#  ③ 整批作废只影响未用的 —— 一刀切会把已核销的记录改脏，按批统计的核销额也就不可信了。
gen38=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":20000,"count":3,"note":"S38"}')
batch38=$(printf '%s' "$gen38" | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('batchId',''))" 2>/dev/null)
c38=$(printf '%s' "$gen38" | python3 -c "import sys,json;print(' '.join((json.load(sys.stdin).get('data') or {}).get('codes',[])))" 2>/dev/null)
a1=$(echo "$c38" | cut -d' ' -f1); a2=$(echo "$c38" | cut -d' ' -f2); a3=$(echo "$c38" | cut -d' ' -f3)
b1=$(printf '%s' "$a1" | tr -d '-' | tr 'a-z' 'A-Z'); b2=$(printf '%s' "$a2" | tr -d '-' | tr 'a-z' 'A-Z'); b3=$(printf '%s' "$a3" | tr -d '-' | tr 'a-z' 'A-Z')
id2=$(q "SELECT id FROM gateway_redemption_codes WHERE code='$b2'")
red38() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/redeem" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "$1"; }
adm38() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/redemption/$1" \
  -H "Authorization: Bearer $GJWT" -H "$CT" ${2:+-d "$2"}; }
# 出生即过期的码不允许造：它能创建成功就是一行永远兑不了的死数据，而运营看不出来
exp38=$(curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":20000,"count":1,"expiresAt":1000}')
bal38=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
u1=$(red38 "{\"code\":\"$a1\"}"); sleep 1
bal38a=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
dis2=$(adm38 "disable/$id2")
u2=$(red38 "{\"code\":\"$a2\"}"); sleep 1
disUsed=$(adm38 "disable/$(q "SELECT id FROM gateway_redemption_codes WHERE code='$b1'")")
bal38b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
# 台账按这三张码的 ref 精确点名（不是按面额筛）：断的是「本批三张码里，只有首发那张产生过钱」。
# 这一条是 409 那几发的**钱侧**证据 —— 余额不变只说明当下没动，台账不多才说明拒得干净。
tx38=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem' AND ref IN ('redeem:$b1','redeem:$b2','redeem:$b3')")
# 过期只能靠 SQL 造：API 拒绝生成已过期的码（上面已断），而“时间流逝”无法等
q "UPDATE gateway_redemption_codes SET expires_at=1000 WHERE code='$b3'" >/dev/null
st38=$(curl -s --max-time 20 -X GET "$U/admin/gateway/redemption/stats/$batch38" -H "Authorization: Bearer $GJWT")
expn=$(printf '%s' "$st38" | python3 -c "import sys,json;d=(json.load(sys.stdin).get('data') or {});print(f\"{d.get('total')}/{d.get('used')}/{d.get('disabled')}/{d.get('expired')}/{d.get('unused')}\")" 2>/dev/null)
u3=$(red38 "{\"code\":\"$a3\"}"); sleep 1
bal38c=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
db38=$(adm38 "disable-batch" "{\"batchId\":\"$batch38\"}")
dbn=$(grep -o '"disabled":[0-9]*' "$GB" | cut -d: -f2 | head -1)
fin=$(q "SELECT string_agg(status::text,',' ORDER BY id) FROM gateway_redemption_codes WHERE batch_id='$batch38'")
[ "$exp38" = "400" ] && [ "$u1" = "200" ] && [ "$bal38a" = "$((bal38+20000))" ] && [ "$dis2" = "200" ] \
  && [ "$u2" = "409" ] && [ "$disUsed" = "409" ] && [ "$u3" = "409" ] \
  && [ "$bal38b" = "$bal38a" ] && [ "$bal38c" = "$bal38a" ] && [ "$tx38" = "1" ] && [ "$expn" = "3/1/1/1/0" ] \
  && [ "$dbn" = "1" ] && [ "$fin" = "1,2,2" ] \
  && pass "止损边界：过期码不允许生成(${exp38})；首发入账 ${bal38}→${bal38a}(+20000)；作废码兑=${u2}、过期码兑=${u3}、作废已用码=${disUsed} 均 409 且余额始终 ${bal38c}、本批台账只 ${tx38} 条；批次统计 total/used/disabled/expired/unused=${expn}；整批作废只动了 ${dbn} 张未用的，最终状态=${fin}（已用那张没被改脏）" \
  || fail "止损边界不对: 过期码生成=${exp38}(期望400) 首发=${u1}(期望200) 余额=${bal38}->${bal38a}->${bal38b}->${bal38c}(期望+20000后全不变) 本批台账=${tx38}(期望1) 作废=${dis2}(期望200) 兑作废码=${u2}(期望409) 作废已用码=${disUsed}(期望409) 兑过期码=${u3}(期望409) 统计=${expn}(期望3/1/1/1/0) 整批作废=${db38}/disabled=${dbn}(期望1) 最终状态=${fin}(期望1,2,2)"

echo "[S39] 兑换码权限边界：用户不能造码，app 组不暴露管理路由，塞面额不生效"
# 兑换码是能直接变成钱的凭据，所以「谁能生成」就是钱的安全边界。
#  ① 网关令牌（sk-）调管理端生成 → 必须拒；
#  ② app 路由组下不存在生成/作废路由 → 404，而不是 403（403 等于向用户承认这个路由存在）；
#  ③ 兑换请求里塞 quotaMicro：@Body 用默认 Json 解码（ignoreUnknownKeys=false），多一个键会 400，
#     但那是框架的解码宽严、不是这里要守的东西（S29 犯过把框架行为当业务断言的错）。
#     所以只断不变量：无论注入请求结局如何，入账的面额只能是生成时定的那个。
genSk=$(curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/redemption/generate" \
  -H "$AUTH" -H "$CT" -d '{"quotaMicro":50000,"count":1}')
appGen=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/app/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":50000,"count":1}')
appDis=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST "$U/app/gateway/redemption/disable/1" \
  -H "Authorization: Bearer $GJWT" -H "$CT")
gen39=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":10000,"count":1,"note":"S39 内部备注"}')
c39=$(printf '%s' "$gen39" | python3 -c "import sys,json;print(((json.load(sys.stdin).get('data') or {}).get('codes') or [''])[0])" 2>/dev/null)
raw39=$(printf '%s' "$c39" | tr -d '-' | tr 'a-z' 'A-Z')
n39a=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem'")
inj39=$(curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/redeem" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"code\":\"$c39\",\"quotaMicro\":99999999}")
sleep 1
n39b=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='redeem'")
# 面额按**这张码的 ref** 取，不是全表 MAX：S36/S37/S38 各留了不同面额的台账，
# MAX 会读到 S36 的 50000 —— 那等于拿别人的数在比，「注入的面额没生效」这条断言恒真。
amt39=$(q "SELECT COALESCE(MAX(amount),0) FROM gateway_quota_transactions WHERE type='redeem' AND ref='redeem:$raw39'")
# 运营备注不得进用户侧响应（note 里写着活动名/客户名，泄露给用户是信息外流）
leak39=$(grep -c "S39 内部备注" "$GB")
# 两种世界都得对：注入被拒（400）则台账不得多一条、且这张码名下零台账；
# 注入被接受（200）则入账必为生成时定的 10000。
if [ "$inj39" = "200" ]; then amtok=$([ "$amt39" = "10000" ] && echo yes || echo no)
else amtok=$([ "$n39b" = "$n39a" ] && [ "$amt39" = "0" ] && echo yes || echo no); fi
[ "$genSk" != "200" ] && [ "$appGen" = "404" ] && [ "$appDis" = "404" ] \
  && [ "$amtok" = "yes" ] && [ "$leak39" = "0" ] \
  && pass "权限与注入边界：网关令牌造码=${genSk}（非200）；app 组下生成=${appGen}、作废=${appDis} 均 404（路由不存在，不是403）；塞面额兑换=${inj39}，该码名下台账面额=${amt39}（全局台账 ${n39a}→${n39b} 条），客户端定的 99999999 没生效；运营备注未泄露(${leak39})" \
  || fail "权限边界不对: 网关令牌造码=${genSk}(期望非200) app组生成=${appGen}(期望404) app组作废=${appDis}(期望404) 注入兑换=${inj39} 台账=${n39a}->${n39b} 该码面额=${amt39}(amtok=${amtok}) 备注泄露=${leak39}(期望0)"

echo "[S40] 下单失败 → 意图单必须被关掉，且真实原因不被清理动作盖掉"
# QuotaRechargeLogic.close 的 SQL 里有 :waiting，而参数表里一度没有它 —— sqlx4k 抛
# NamedParameterValueNotSupplied，于是 catch 块里的清理动作自己炸了：真实原因（渠道不可用）
# 被一条 sqlx4k 内部错误盖掉，意图单停在待支付，正是那行注释说要消除的对账噪声。
# 这条路径此前**完全没被覆盖**：S30 的 r1 在建单前就抛（汇率未配）、r2 在 controller 校验就拒
# （缺 channelCode），两条都到不了 close。一个因为没测试而藏住的 bug，修好后就得有测试。
#
# 用未知渠道触发：payment 的 submit 在 resolveRoute 失败时抛 BadRequestException(→400)，
# 且抛在 PayOrderTable.insert 之前，所以支付单侧不留痕 —— 干净的「下单失败」。
nrc40a=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
npo40a=$(q "SELECT COUNT(*) FROM pay_orders")
bal40=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
bad40=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"no_such_channel_40"}')
sleep 1
nrc40b=$(q "SELECT COUNT(*) FROM gateway_quota_recharges")
rid40=$(q "SELECT COALESCE(MAX(id),0) FROM gateway_quota_recharges")
ps40=$(q "SELECT pay_status FROM gateway_quota_recharges WHERE id=$rid40")
poid40=$(q "SELECT COALESCE(pay_order_id,-1) FROM gateway_quota_recharges WHERE id=$rid40")
npo40b=$(q "SELECT COUNT(*) FROM pay_orders")
ntx40=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='gateway:quota:$rid40'")
bal40b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
# 全轮日志扫描：命名参数漏绑这类 bug 在编译期与启动期都不报错，只在执行到那一行时 500。
# 这一条同时守住 close 与 S38 的 disable-batch（两者都犯过）。
npe40=$(grep -c "NamedParameterValueNotSupplied" "$WORK/logs/all.log" 2>/dev/null)
[ "$bad40" = "400" ] && [ "$nrc40b" = "$((nrc40a+1))" ] && [ "$ps40" = "2" ] && [ "$poid40" = "-1" ] \
  && [ "$npo40b" = "$npo40a" ] && [ "$ntx40" = "0" ] && [ "$bal40b" = "$bal40" ] && [ "${npe40:-0}" = "0" ] \
  && pass "下单失败干净收尾：HTTP=${bad40}（payment 报「不可用的支付通道」）；意图单建了又关了（${nrc40a}→${nrc40b} 行，id=${rid40} pay_status=${ps40}、pay_order_id 未回填）；支付单 ${npo40a}→${npo40b}、台账 ${ntx40} 条、余额 ${bal40}→${bal40b} 均未动；全轮日志无命名参数漏绑(${npe40})" \
  || fail "下单失败没收干净: HTTP=${bad40}(期望400) 意图单=${nrc40a}->${nrc40b}(期望+1) id=${rid40} pay_status=${ps40}(期望2=已关，0=停在待支付就是 close 又抛了) pay_order_id=${poid40}(期望-1=NULL) 支付单=${npo40a}->${npo40b}(期望不变) 台账=${ntx40}(期望0) 余额=${bal40}->${bal40b}(期望不变) 命名参数漏绑=${npe40}(期望0) body=$(head -c 200 "$GB")"

echo "[S41] 台账时间戳：每一行钱都得知道自己是什么时候发生的"
# QuotaLogic.debitInTx 走 ref 幂等路径时，先插一行哨兵占住 uk_gateway_quota_tx_ref，那条手写
# SQL 把 created_at 写成了字面量 0，随后的 UPDATE 只回填 balance_after —— 于是**所有**带 ref
# 的台账（结算 settlement:*、充值 gateway:quota:*、兑换 redeem:*）时间戳都停在 epoch 0。
# 后果不只是显示成 1970：V001 建 idx_gateway_quota_tx_user(user_id, created_at) 就是为了按时间
# 查流水，全表同一个值等于这个索引白建，「这个客户上个月花了多少」在台账上无法回答，而台账是
# 钱的唯一审计来源。走非 ref 路径的行（管理端手工 grant 不填 ref）时间反而是对的 —— 同一张表里
# 两种行混着，按 created_at 排序会把手工调整整堆排到一端，对账时看不出真实先后。
#
# 断言做成**全局不变量**而不是挑一行：哨兵插入是所有 ref 路径共用的那一条 SQL，挑一行只能证明
# 我挑的那条路径，扫全表才证明这条 SQL 本身。
#
# 非空前提只拿 recharge 与 redeem 两类，**不含 settlement**：S32 开头的 seed_reset 会 TRUNCATE
# gateway_quota_transactions，而结算台账只由 S28 之前的中继场景产生 —— 到本场景时它们已被清掉。
# 写 nset>0 会因为 harness 的结构而假红，与本 bug 无关；哨兵 SQL 是同一条，证一类即证全部。
ntx41=$(q "SELECT COUNT(*) FROM gateway_quota_transactions")
nzero41=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE created_at IS NULL OR created_at <= 0")
nrc41=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'gateway:quota:%'")
nred41=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'redeem:%'")
min41=$(q "SELECT COALESCE(MIN(created_at),0) FROM gateway_quota_transactions")
max41=$(q "SELECT COALESCE(MAX(created_at),0) FROM gateway_quota_transactions")
nowms41=$(python3 -c 'import time;print(int(time.time()*1000))')
# 时间窗既要「不是 0」也要「单位对」：写成秒的话约 1.7e9，比 nowms 小三个数量级，会被下界抓住。
# 上界留 10 分钟余量给本机与容器的时钟差；下界留 1 小时覆盖整轮 harness 的耗时。
lo41=$((nowms41 - 3600000)); hi41=$((nowms41 + 600000))
[ "$ntx41" -gt 0 ] && [ "$nrc41" -gt 0 ] && [ "$nred41" -gt 0 ] \
  && [ "$nzero41" = "0" ] && [ "$min41" -ge "$lo41" ] && [ "$max41" -le "$hi41" ] \
  && pass "台账时间戳全部真实：共 ${ntx41} 行（充值 ${nrc41} / 兑换 ${nred41}），created_at 为空或 <=0 的 ${nzero41} 行；区间 ${min41}..${max41} 落在本轮窗口内（单位是毫秒）" \
  || fail "台账时间戳不对: 共 ${ntx41} 行(期望>0，否则本场景恒真) 充值=${nrc41}(期望>0) 兑换=${nred41}(期望>0) created_at空或<=0=${nzero41}(期望0) 区间=${min41}..${max41} 期望落在 ${lo41}..${hi41} 内(now=${nowms41}；0=哨兵SQL没填时间，1.7e9量级=单位写成了秒)"

# ════════════════════════════════════════════════════════════════════
# S42–S45 邀请达成 → 网关额度
#
# 这一批盯的是一条**早就写好、却从没被装配过**的发钱链路。member 侧的扩展点
# （port/MemberInviteRewardPort.kt：事件 / 监听者 / 注册表）一直都在，MemberInviteLogic 也一直在
# dispatch —— 但全仓没有任何一处 bind 过那个注册表，getOrNull 恒 null，于是邀请被如实记录、
# 邀请人的累计数也在维护，一份奖励都发不出去，而且**没有一行日志说明这件事**（契约把「未装配」
# 当合法配置，是有意沉默的）。对网关这种额度就是钱的东西，「拉人双方得额度」是最便宜的获客通道，
# 而 member 侧的机器全都写好且测过了，缺的只是一个桥和一次 bind。
#
# 四个场景各钉一件事：
#   S42 未配置额度 = 一分不发（且必须证明链路**真的装配了**，否则「零台账」是假绿）
#   S43 配置后两个角色各恰好一条台账、余额按配置动
#   S44 重放同一条记录不产生第二条（幂等靠台账 ref 唯一约束，不是靠没人重放）
#   S45 配置非法必须**响**，且不连累另一个角色
#
# 断言一律落在台账行数与余额上，不只落 HTTP 状态：这条链路的失败形态是「200 但没发钱」，
# 只看状态码的话它永远是绿的。
# ════════════════════════════════════════════════════════════════════

# 管理端 JWT。重启后旧 token 其实仍然有效（无状态签名、密钥来自配置），但重新登一次能消掉
# 「401 是因为 token 失效还是因为权限不够」这一整类歧义 —— 下面 S44 正好要断言 401。
admin_jwt() {
  curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" \
    -d '{"username":"admin","password":"admin123"}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null
}

# 注册一个真会员，回显 "<userId> <accessToken>"（失败回显 "0 <原因>"，从不回显空串）。
#
# 为什么走 sms-login 而不是 /auth/register：register 要求 USERNAME_PASSWORD ∈
# authPolicy.registerModes，而 NanoGate 没 bind MemberAuthPolicy，默认策略只含 PHONE_SMS，
# 用户名注册会被 REGISTER_MODE_DISABLED 拒。sms-login 对不存在的手机号**自动注册**
# （MemberAuthLogic.smsLogin → registerNewUser），且注册路径直接收 inviteCode ——
# 一次调用就能走到 dispatchInviteReward，不必先注册再补绑（那是另一条代码路径）。
#
# 没有短信通道也走得通：MessageSendLogic.sendVerificationCode 总是**先**把码写进 Redis，
# 再尝试模板发送，无模板就降级成 dev-mode 的 message_log。所以这里直接从隔离实例把码读出来。
sms_register() {
  local mobile="$1" invite="${2:-}" code body resp out
  # send-sms-code 与 sms-login 各限 5 次/60s/IP，而隔离 Redis 跨 app 重启存活 ——
  # 本批要注册 6 个用户，不清计数必然撞 429（表现成「注册失败」，会被误判成代码问题）。
  rkdel "*ngrl:*"
  curl -s --max-time 10 -o /dev/null -X POST "$U/app/auth/send-sms-code" -H "$CT" \
    -d "{\"mobile\":\"$mobile\",\"scene\":1}"
  # 键名带 keyPrefix（ngharness），一律通配匹配，不把前缀写死（与 rksum/rkdel 同一约定）。
  code=$(rc get "$(rc --scan --pattern "*sms:code:$mobile" | head -1)")
  if [ -z "$code" ]; then echo "0 NO_SMS_CODE_IN_REDIS"; return 0; fi
  if [ -n "$invite" ]; then
    body="{\"mobile\":\"$mobile\",\"smsCode\":\"$code\",\"inviteCode\":\"$invite\"}"
  else
    body="{\"mobile\":\"$mobile\",\"smsCode\":\"$code\"}"
  fi
  resp=$(curl -s --max-time 15 -X POST "$U/app/auth/sms-login" -H "$CT" -d "$body")
  out=$(printf '%s' "$resp" | python3 -c "import sys,json;d=(json.load(sys.stdin).get('data') or {});print(d.get('userId') or 0, d.get('accessToken') or '')" 2>/dev/null)
  if [ -z "$out" ]; then
    echo "0 BAD_RESPONSE:$(printf '%s' "$resp" | tr -d '\n' | head -c 160)"
  else
    echo "$out"
  fi
}

# 取某个用户的专属邀请码（服务端不存在则生成）。
invite_code_of() {
  curl -s --max-time 10 "$U/app/member/invite-code/mine" -H "Authorization: Bearer $1" \
    | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('code') or '')" 2>/dev/null
}

echo "[S42] 邀请奖励未配置额度：链路已装配，但一分不发"
# 这个场景真正的难点是：额度为 0 时，「装配了但不发」与「压根没装配」的**账面结果完全一样**
# （零台账、零额度账户）—— 后者正是修复前的状态。只看台账就是恒绿的假守卫。
#
# 两道断言各堵一半，缺一不可：
#  - attach 日志证明桥被构造并挂上了 ctx，且生效额度确实是 0；
#  - **skip 日志才证明 member 拿到了注册表并真的回调了监听者**。少了它，只删 bind、留着 attach
#    的变异照样绿：attach 是 onStart 里无条件跑的，它根本不知道注册表有没有 bind 进 member。
# all.log 跨重启累积，故 attach 取最后一条 = 当前这次 boot 的配置；skip 用前后计数差归因。
atk42=$(grep "invite reward attached" "$WORK/logs/all.log" 2>/dev/null | tail -1)
atok42=no; printf '%s' "$atk42" | grep -q "inviter=0 invitee=0" && atok42=yes
skip42a=$(grep -c "invite reward skipped" "$WORK/logs/all.log" 2>/dev/null)
read -r a42 ta42 <<<"$(sms_register '+8615000042001')"
c42=$(invite_code_of "$ta42")
read -r b42 tb42 <<<"$(sms_register '+8615000042002' "$c42")"
sleep 1
# 子查询包一层再 COALESCE：不包的话无命中行时 psql 返回**空串**而不是 0，下面的数值比较会炸。
rid42=$(q "SELECT COALESCE((SELECT id FROM member_invite_records WHERE invitee_user_id=$b42),0)")
inv42=$(q "SELECT COALESCE((SELECT inviter_user_id FROM member_invite_records WHERE id=$rid42),0)")
nled42=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'invite:%'")
nacc42=$(q "SELECT COUNT(*) FROM gateway_quota_accounts WHERE user_id IN ($a42,$b42)")
skip42b=$(grep -c "invite reward skipped" "$WORK/logs/all.log" 2>/dev/null)
# 恰好 +2：两个角色各被评估一次。断「>0」不够 —— 那只证明至少一个角色走到了，
# 另一个角色的回调丢了（比如 grantRole 写成了 early return 整个事件）就看不出来。
dskip42=$((skip42b - skip42a))
[ "$atok42" = "yes" ] && [ -n "$c42" ] && [ "$rid42" -gt 0 ] && [ "$inv42" = "$a42" ] \
  && [ "$nled42" = "0" ] && [ "$nacc42" = "0" ] && [ "$dskip42" = "2" ] \
  && pass "未配置额度 → 一分不发，且证明是「评估过而不发」而非「没装配」：邀请链路跑通（记录 ${rid42}，邀请人 ${inv42}=注册出的 ${a42}，码 ${c42}），invite:* 台账 ${nled42} 条、两人额度账户 ${nacc42} 个；attach 日志确认额度为 0，监听者回调日志恰好 +${dskip42}（两个角色各一次 → 注册表确实 bind 进了 member）" \
  || fail "默认不发奖不成立: attach日志=${atok42}(期望yes，内容 '${atk42:0:120}') 监听者回调增量=${dskip42}(期望2；0=注册表没bind进member或dispatch没跑) 邀请码=${c42:-<空>} 记录id=${rid42}(期望>0) 邀请人=${inv42}(期望=${a42}) invite台账=${nled42}(期望0) 额度账户=${nacc42}(期望0) 注册回显 a=${a42} b=${b42}"

echo "[S43] 配置额度后：两个角色各恰好一条台账，余额按配置动"
# 保留上一次 boot 的两个计费 env：本批不再中继，但少传一个就等于顺手改了全局计价，
# 万一后面还要加场景就会踩到一个谁也说不清的差异。
stop_app; boot_app NEWGATE_MEMBER_GROUP_BILLING=true NEWGATE_QUOTA_PER_PRICE_UNIT=1000 \
  NEWGATE_INVITE_REWARD_INVITER=50000 NEWGATE_INVITE_REWARD_INVITEE=20000
GJWT=$(admin_jwt)
atk43=$(grep "invite reward attached" "$WORK/logs/all.log" 2>/dev/null | tail -1)
atok43=no; printf '%s' "$atk43" | grep -q "inviter=50000 invitee=20000" && atok43=yes
read -r a43 ta43 <<<"$(sms_register '+8615000043001')"
c43=$(invite_code_of "$ta43")
read -r b43 tb43 <<<"$(sms_register '+8615000043002' "$c43")"
sleep 1
rid43=$(q "SELECT COALESCE((SELECT id FROM member_invite_records WHERE invitee_user_id=$b43),0)")
# 一条 SQL 里把「角色 / 类型 / 面额 / 归属 / 时间戳」全钉住：少钉一项就等于允许一种错账。
# created_at>0 与 S41 是同一件事 —— 发奖走的正是那条 ref 哨兵 SQL。
ni43=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='invite:$rid43:inviter' AND type='invite' AND amount=50000 AND user_id=$a43 AND created_at>0")
ne43=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='invite:$rid43:invitee' AND type='invite' AND amount=20000 AND user_id=$b43 AND created_at>0")
# 总数必须是 2：只数「各自那一条」的话，同一角色被发两次是看不出来的。
tot43=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'invite:%'")
ba43=$(q "SELECT COALESCE((SELECT balance FROM gateway_quota_accounts WHERE user_id=$a43),-1)")
bb43=$(q "SELECT COALESCE((SELECT balance FROM gateway_quota_accounts WHERE user_id=$b43),-1)")
[ "$atok43" = "yes" ] && [ "$rid43" -gt 0 ] && [ "$ni43" = "1" ] && [ "$ne43" = "1" ] && [ "$tot43" = "2" ] \
  && [ "$ba43" = "50000" ] && [ "$bb43" = "20000" ] \
  && pass "配置后双角色各一条台账：记录 ${rid43} → inviter(${a43}) 50000 ×${ni43}、invitee(${b43}) 20000 ×${ne43}，invite:* 共 ${tot43} 条，余额 ${ba43}/${bb43}（两人都是从 0 起，所以余额就等于奖励额）" \
  || fail "奖励入账不对: attach=${atok43}(期望yes，'${atk43:0:120}') 记录id=${rid43}(期望>0) inviter行=${ni43}(期望1) invitee行=${ne43}(期望1) invite台账总数=${tot43}(期望2) 余额 inviter=${ba43}(期望50000) invitee=${bb43}(期望20000) 注册回显 a=${a43} b=${b43}"

echo "[S44] 重放同一条邀请记录：不产生第二条台账"
# 幂等不能靠「没人会重放」——契约明说奖励失败不回滚、监听者可能再被触发，所以补发入口是必须有的，
# 而补发入口存在就必然带来「补发会不会二次入账」这个问题。这里直接重放一次已经发成功的记录。
skip44a=$(grep -c "quota debit idempotent skip" "$WORK/logs/all.log" 2>/dev/null)
rr44=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST \
  "$U/admin/member/invite-code/retry-invite-reward/$rid43" -H "Authorization: Bearer $GJWT")
# 记录不存在必须报错而不是 200：dispatchInviteReward 对缺失记录是 `?: return`（正常链路不该因为
# 一条脏记录影响注册），但运维手工补发时拿到 200 却什么都没发生，比拿到 400 糟得多。
ghost44=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST \
  "$U/admin/member/invite-code/retry-invite-reward/99999999" -H "Authorization: Bearer $GJWT")
noauth44=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST \
  "$U/admin/member/invite-code/retry-invite-reward/$rid43")
sleep 1
tot44=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref LIKE 'invite:%'")
ba44=$(q "SELECT COALESCE((SELECT balance FROM gateway_quota_accounts WHERE user_id=$a43),-1)")
bb44=$(q "SELECT COALESCE((SELECT balance FROM gateway_quota_accounts WHERE user_id=$b43),-1)")
skip44b=$(grep -c "quota debit idempotent skip" "$WORK/logs/all.log" 2>/dev/null)
# 恰好 +2：两个 ref 各被唯一约束挡下一次。断「增加了」不够 —— 那兼容「重放其实什么都没干」；
# 断「恰好 2」才证明重放真的走到了发钱那一步、并且是被幂等闸门拦下的。
dskip44=$((skip44b - skip44a))
[ "$rr44" = "200" ] && [ "$ghost44" = "400" ] && [ "$noauth44" = "401" ] \
  && [ "$tot44" = "2" ] && [ "$ba44" = "50000" ] && [ "$bb44" = "20000" ] && [ "$dskip44" = "2" ] \
  && pass "重放幂等：retry-invite-reward(${rid43}) → ${rr44}，台账仍 ${tot44} 条、余额仍 ${ba44}/${bb44}，幂等跳过日志恰好 +${dskip44}（两个 ref 各挡一次，证明重放真走到了发钱那步）；不存在的记录 → ${ghost44}、无凭据 → ${noauth44}" \
  || fail "重放不幂等或补偿端点不对: 重放=${rr44}(期望200) 不存在记录=${ghost44}(期望400) 无凭据=${noauth44}(期望401) invite台账=${tot44}(期望2) 余额=${ba44}/${bb44}(期望50000/20000) 幂等跳过增量=${dskip44}(期望2) body=$(head -c 160 "$GB")"

echo "[S45] 额度配置非法：该角色不发奖但必须响，且不连累另一个角色"
# `1e3` 是个很可能的笔误（想写 1000）。把它静默读成「不奖励」的后果是：运营以为活动已上线、
# 客服按活动口径答复用户，而账上什么都没有 —— 那比不发奖励糟得多。所以非法必须与 0 严格区分。
stop_app; boot_app NEWGATE_MEMBER_GROUP_BILLING=true NEWGATE_QUOTA_PER_PRICE_UNIT=1000 \
  NEWGATE_INVITE_REWARD_INVITER=1e3 NEWGATE_INVITE_REWARD_INVITEE=20000
GJWT=$(admin_jwt)
atk45=$(grep "invite reward attached" "$WORK/logs/all.log" 2>/dev/null | tail -1)
atok45=no; printf '%s' "$atk45" | grep -q "inviter=INVALID invitee=20000" && atok45=yes
mis45a=$(grep -c "invite reward MISCONFIGURED role=inviter" "$WORK/logs/all.log" 2>/dev/null)
read -r a45 ta45 <<<"$(sms_register '+8615000045001')"
c45=$(invite_code_of "$ta45")
read -r b45 tb45 <<<"$(sms_register '+8615000045002' "$c45")"
sleep 1
rid45=$(q "SELECT COALESCE((SELECT id FROM member_invite_records WHERE invitee_user_id=$b45),0)")
# 显式断言邀请人就是 a45。今天它必然成立（invite_code_of 拿 a45 自己的 token 调 /mine，
# 服务端按认证主体解析，结构上不可能返回别人的码），但下面两条断言（邀请人台账 0 条、
# 邀请人额度账户 0 个）在「a45 压根没参与这次邀请」的世界里**同样为真** —— 那就是空断言，
# 而 pass 文案还写着「邀请人(a45)」。S42 已经断了这一条，S45 不断就等于把结论押在 helper 的
# 实现细节上：哪天 /mine 改成能代查，这个场景会绿着失去意义。
inv45=$(q "SELECT COALESCE((SELECT inviter_user_id FROM member_invite_records WHERE id=$rid45),0)")
ni45=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='invite:$rid45:inviter'")
ne45=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='invite:$rid45:invitee' AND type='invite' AND amount=20000 AND user_id=$b45 AND created_at>0")
bb45=$(q "SELECT COALESCE((SELECT balance FROM gateway_quota_accounts WHERE user_id=$b45),-1)")
nacc45=$(q "SELECT COUNT(*) FROM gateway_quota_accounts WHERE user_id=$a45")
mis45b=$(grep -c "invite reward MISCONFIGURED role=inviter" "$WORK/logs/all.log" 2>/dev/null)
dmis45=$((mis45b - mis45a))
[ "$atok45" = "yes" ] && [ "$rid45" -gt 0 ] && [ "$inv45" = "$a45" ] && [ "$ni45" = "0" ] && [ "$nacc45" = "0" ] && [ "$dmis45" = "1" ] \
  && [ "$ne45" = "1" ] && [ "$bb45" = "20000" ] \
  && pass "配置非法响而不发：attach 报 inviter=INVALID，邀请人(${inv45}=注册出的 ${a45}) 台账 ${ni45} 条、额度账户 ${nacc45} 个、MISCONFIGURED 日志 +${dmis45}；同一条记录的被邀请人(${b45}) 照拿 20000（余额 ${bb45}）—— 一个角色配错不连累另一个" \
  || fail "非法配置处理不对: attach=${atok45}(期望yes，'${atk45:0:120}') 记录id=${rid45}(期望>0) 邀请人=${inv45}(期望=${a45}) inviter台账=${ni45}(期望0) inviter额度账户=${nacc45}(期望0) MISCONFIGURED增量=${dmis45}(期望1) invitee行=${ne45}(期望1) invitee余额=${bb45}(期望20000) 注册回显 a=${a45} b=${b45}"

echo "[S46] 兑换码管理端要授权，不只是认证：零角色的管理端账号必须被挡，且被挡时一行也不写"
# 为什么这条要紧：@Permission 缺失时框架**完全不做授权检查** —— SecurityPreHandle 第 5 步的条件是
# `route.permission != null`，而 admin 路由组只保证「你是某个管理端账号」。造码就是造钱，
# 「一个只有客服权限的账号能造码」等于把印钞机挂在最弱的那把钥匙后面。授权层此前零覆盖：
# S39 断的是网关令牌 401（认证层）与 app 组 404（路由层），都不是「管理端账号但权限不够」。
#
# 主体怎么造：system_users 插一行、**不插 system_user_roles** —— resolvePermissions 对没有任何
# 角色的用户直接返回 emptySet()（PermissionLogic:37）。于是这个账号能登录（认证过）、token 里
# 零权限（授权必拒），403 只可能来自授权这一层，归因是干净的。
# 哈希用 INSERT ... SELECT 从 admin 那行复制：它含 `$`（pbkdf2-sha256$210000$…），经 shell 双引号
# 插值会被当成变量展开吃掉，于是密码悄悄变了、登录失败，场景会红在「登录」而不是测到授权。
#
# 末尾那一发 admin 对照是必需的：少了它，403 可能来自任何原因（路由坏了、body 不合法），
# 而这个场景会绿着放行一个已经谁都用不了的接口。另一半保险在 S36–S39：它们全程用 admin 造码，
# 补注解若把 super_admin 的 `*:*:*` 通配也挡住，那四个场景会一起红。
q "INSERT INTO system_users (id, username, password_hash, nickname, status, created_at, updated_at) SELECT 946, 'cs_s46', password_hash, 'S46 客服', 1, 0, 0 FROM system_users WHERE id=1 ON CONFLICT (id) DO NOTHING" >/dev/null
csjwt=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" \
  -d '{"username":"cs_s46","password":"admin123"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
csok46=no; [ -n "$csjwt" ] && csok46=yes
csrole46=$(q "SELECT COUNT(*) FROM system_user_roles WHERE user_id=946")
ngen46a=$(q "SELECT COUNT(*) FROM gateway_redemption_codes")
cs46() { curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U$1" \
  -H "Authorization: Bearer $csjwt" -H "$CT" -d "$2"; }
p1=$(cs46 "/admin/gateway/redemption/generate" '{"quotaMicro":50000,"count":3,"note":"S46 越权尝试"}')
p2=$(cs46 "/admin/gateway/redemption/disable-batch" '{"batchId":"rc-0000000000000000"}')
p3=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" \
  "$U/admin/gateway/redemption/page?pageNo=1&pageSize=10" -H "Authorization: Bearer $csjwt")
sleep 1
ngen46b=$(q "SELECT COUNT(*) FROM gateway_redemption_codes")
# 对照：同一个接口、换成 super_admin，必须 200 且真的多出一行。
GJWT=$(admin_jwt)
ok46=$(curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":1000,"count":1,"note":"S46 对照"}')
sleep 1
ngen46c=$(q "SELECT COUNT(*) FROM gateway_redemption_codes")
[ "$csok46" = "yes" ] && [ "$csrole46" = "0" ] && [ "$p1" = "403" ] && [ "$p2" = "403" ] && [ "$p3" = "403" ] \
  && [ "$ngen46b" = "$ngen46a" ] && [ "$ok46" = "200" ] && [ "$ngen46c" = "$((ngen46a+1))" ] \
  && pass "授权与认证分得开：零角色账号登录成功（认证过了，角色数 ${csrole46}）但造码=${p1}、整批作废=${p2}、列表=${p3} 全 403，且码表 ${ngen46a}→${ngen46b} 一行没多；同一接口换 super_admin → ${ok46} 且 ${ngen46b}→${ngen46c}（+1，注解没把通配挡住）" \
  || fail "授权边界不对: cs登录=${csok46}(期望yes) 角色数=${csrole46}(期望0) 造码=${p1}(期望403) 整批作废=${p2}(期望403) 列表=${p3}(期望403) 越权后码数=${ngen46b}(期望=${ngen46a}) admin对照=${ok46}(期望200) 对照后码数=${ngen46c}(期望=$((ngen46a+1))) body=$(head -c 160 "$GB" 2>/dev/null)"

echo "[S47] 授权巡检：钱相关的管理端动作一律要权限，且拒绝理由必须点名那条权限"
# S46 盯的是兑换码。这一条把同一个零权限主体（沿用 S46 造的 cs_s46，同一轮里 token 仍有效）
# 打到另外三个能动钱的管理端动作上，跨模块盯着“授权注解被摘”这一类回归：
#   直接发额度 gateway:quota:grant / 发起退款 pay:refund:create / 新建计价组 gateway:group:create
# 它们今天都带着 @Permission，所以这一轮应该是绿的 —— 价值在以后：谁把注解摘掉了这里就红。
# 一次性的人工扫描拦不住下一次（本次就是扫出来的），巡检才能。
#
# 拒绝理由必须**点名权限串**（框架把 `Permission denied: <permission>` 写进信封）：
# 403 本身只说明「被拒了」，点名才说明是这一条 @Permission 在起作用 ——
# 否则路由写错打到别处的 403 与权限生效长得一模一样。
# 副作用不变量与状态码一起断言：“403 但已经写进去了”比 200 更糟。
bal47a=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nled47a=$(q "SELECT COUNT(*) FROM gateway_quota_transactions")
ngrp47a=$(q "SELECT COUNT(*) FROM gateway_groups")
h1=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/quota/grant" \
  -H "Authorization: Bearer $csjwt" -H "$CT" -d '{"userId":1,"amount":100000,"ref":"s47-probe"}')
b1=$(head -c 200 "$GB" 2>/dev/null | tr -d '\n')
h2=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/admin/pay/refund/create" \
  -H "Authorization: Bearer $csjwt" -H "$CT" \
  -d '{"merchantOrderId":"s47-nope","merchantRefundId":"s47-ref","refundAmount":100}')
b2=$(head -c 200 "$GB" 2>/dev/null | tr -d '\n')
h3=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $csjwt" -H "$CT" -d '{"code":"s47probe","name":"S47","ratio":"1.0"}')
b3=$(head -c 200 "$GB" 2>/dev/null | tr -d '\n')
sleep 1
bal47b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nled47b=$(q "SELECT COUNT(*) FROM gateway_quota_transactions")
ngrp47b=$(q "SELECT COUNT(*) FROM gateway_groups")
k1=no; printf '%s' "$b1" | grep -q 'gateway:quota:grant' && k1=yes
k2=no; printf '%s' "$b2" | grep -q 'pay:refund:create' && k2=yes
k3=no; printf '%s' "$b3" | grep -q 'gateway:group:create' && k3=yes
[ "$h1" = "403" ] && [ "$h2" = "403" ] && [ "$h3" = "403" ] \
  && [ "$k1" = "yes" ] && [ "$k2" = "yes" ] && [ "$k3" = "yes" ] \
  && [ "$bal47b" = "$bal47a" ] && [ "$nled47b" = "$nled47a" ] && [ "$ngrp47b" = "$ngrp47a" ] \
  && pass "钱端点全在授权后面（零权限主体，拒绝理由各点名一条权限）：发额度=${h1}、退款=${h2}、建组=${h3} 全 403；余额 ${bal47a}→${bal47b}、台账 ${nled47a}→${nled47b} 条、计价组 ${ngrp47a}→${ngrp47b} 个均未动" \
  || fail "授权巡检不过: 发额度=${h1}(期望403，点名=${k1}) 退款=${h2}(期望403，点名=${k2}) 建组=${h3}(期望403，点名=${k3}) 余额=${bal47a}→${bal47b}(期望不变) 台账=${nled47a}→${nled47b}(期望不变) 组=${ngrp47a}→${ngrp47b}(期望不变) bodies='${b1:0:80}'|'${b2:0:80}'|'${b3:0:80}'"

rm -f "$GB"

echo "[S48] 用户级计价例外：管理端能写、写了真的改变计价，悬空组写不进去"
# 这一条补的是两层空白：
#   ① 写路径此前**根本不存在** —— gateway_group_overrides 只有 SQL + 表对象 + 解析器第 2 步的读，
#      运营要给人配谈判价只能手工改库，而手工改库正是悬空 group_code 的来源。
#   ② 解析顺序的**第 2 层此前零端到端覆盖**：整个 run.sh 里这张表只出现在 S28 的两行裸 SQL
#      （插入 → 测删除守卫 → 删掉），从来没有任何场景断言过「配了例外之后计价真的变了」。
#      S26 覆盖的是第 1 层（令牌覆盖）、第 3 层（会员组）、第 4 层（default），第 2 层被跳过了。
# 所以核心断言不是「接口返回 200」，而是**倍率真的生效**：先量一次基线，配例外后再量一次，
# 断言后者恰好是前者的 ratio 倍。用比值而不是写死金额：金额取决于模型价与 token 数，
# 写死期望值会把「定价变了」误报成「例外没生效」（S27 已经因为 normalize 剔尾零踩过一次）。
stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000
GJWT=$(admin_jwt)
# 会员组计费开关**不开**：开着的话第 3 层会参与解析，而 member_users(1) 的会员组是 S26 留下的
# 未映射组，基线那一发会变成 403 而不是按 default 计价。关掉它，比较才是干净的两层：例外 vs default。
seed_reset; fake ok 9948; sleep 1
# ⚠️ 必须先把 member_users(2) 建出来：下面三发「写入校验」用的都是 userId=2，而 create 现在会
# **先**校验 userId 是不是一个活会员（MemberDirectoryPort，见 S54）。库里没有 id=2 的话，那三发
# 仍然回 400、行数仍然是 0，但理由从「组码悬空 / 空白 / 超长」悄悄换成「没有这个会员」——
# 结果码一模一样，三条覆盖就这么静默失效（S28 那次假绿正是这个形状：409 不变、理由全错）。
# status 显式写 1：DDL 的默认是 0(DISABLED)，与 Kotlin model 的默认 1(NORMAL) 相反。
q "INSERT INTO member_users (id,nickname,status,deleted,created_at,updated_at) VALUES (2,'s48-second',1,0,0,0)
     ON CONFLICT (id) DO UPDATE SET status=1, deleted=0;
   INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c48','openai_compatible','http://127.0.0.1:9948','default,vip48','m-grp',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c48'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-grp','2.5','10','0','0',5000,'manual',0,0,0);
   UPDATE gateway_groups SET deleted=0, ratio='1.0' WHERE code='default';
   DELETE FROM gateway_group_overrides WHERE user_id IN (1,2);
   UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null
g48=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"code":"vip48","name":"谈判价三倍","ratio":"3.0"}')
VIP48=$(GID vip48)
b0=$(relay26); sleep 1; base=$(charged26)
cr=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"vip48","remark":"S48 大客户谈判价"}')
row48=$(q "SELECT COALESCE(group_code,'<none>') FROM gateway_group_overrides WHERE user_id=1")
b1=$(relay26); sleep 1; with48=$(charged26)
[ "$g48" = "200" ] && [ -n "$VIP48" ] && [ "$b0" = "200" ] && [ "$cr" = "200" ] && [ "$row48" = "vip48" ] \
  && [ "$b1" = "200" ] && [ -n "$base" ] && [ "$base" -gt 0 ] && [ "$with48" = "$((base*3))" ] \
  && pass "用户级例外真的改变计价（解析第 2 层，此前零覆盖）：建组=${g48}(id=${VIP48}) 基线 relay=${b0} charged=${base}（default ratio 1.0）→ 管理端配例外=${cr} 且库里 group_code=${row48} → relay=${b1} charged=${with48}，恰好是基线的 3 倍（vip48 ratio 3.0）" \
  || fail "例外没生效: 建组=${g48}(期望200) VIP48=${VIP48} 基线=${b0}/${base} 配例外=${cr}(期望200) 库里=${row48}(期望vip48) 例外后=${b1}/${with48}(期望$(( ${base:-0} * 3 ))) body=$(head -c 160 "$GB" 2>/dev/null)"

# 悬空 group_code 必须在**写入时**就被拒。放它进去的代价不是脏数据，是该用户此后每一个请求
# 都 500 billing_group_config_broken（第 2 层命中却找不到活组，且不回落）。
# 超长 remark 同理：到了驱动那一层三方言处置不一致（报错 / 静默截断），截断会把备注变成半句话。
dang=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":2,"groupCode":"ghost48","remark":"悬空"}')
# message 必须在**这里**就取走：下面三发共用 $GB，等到断言时里面已经是 userId=0 那一发的响应了
# —— fail 信息指着错的那半边，比没有信息更坑（S53 块 A 踩过同一类坑）。
# 点名 'ghost48' 是真守卫：userId=2 现在也是一个合法会员（见上面 seed 的注释），少了这条
# 断言，一发因「没有这个会员」而回的 400 会冒充「组码悬空」的 400，两者状态码与行数完全一样。
mdang=$(python3 -c "import json;print(json.load(open('$GB')).get('message') or '')" 2>/dev/null)
blank=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":2,"groupCode":"   "}')
LONGR48=$(python3 -c 'print("x"*257)')
longr=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"userId\":2,\"groupCode\":\"vip48\",\"remark\":\"$LONGR48\"}")
nonpos=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":0,"groupCode":"vip48"}')
n2=$(q "SELECT COUNT(*) FROM gateway_group_overrides WHERE user_id IN (0,2)")
[ "$dang" = "400" ] && [ "$blank" = "400" ] && [ "$longr" = "400" ] && [ "$nonpos" = "400" ] && [ "$n2" = "0" ] \
  && printf '%s' "$mdang" | grep -q "ghost48" \
  && pass "写入校验在驱动之前：悬空组=${dang}（message 点名 'ghost48' 而不是 '没有这个会员'）、空白组=${blank}、257 字 remark=${longr}、userId=0 均 400（非 500），且一行也没写进去（user 0/2 共 ${n2} 条）" \
  || fail "写入校验不对: 悬空=${dang}(期望400) 空白=${blank}(期望400) 超长remark=${longr}(期望400) userId=0=${nonpos}(期望400) 写入行数=${n2}(期望0) 悬空message='${mdang:0:120}'(期望点名 ghost48；若写的是 'no chargeable member' 则本发测的是 S54 那件事、组码校验已失去覆盖)"

# 主键就是 userId，所以「同一用户第二条」只能是冲突。这里要同时守住两件事：
# ① 是 409 而不是 500（撞主键的驱动异常未被归类的话，框架会兜底成 500 + "Internal Server Error"，
#    message 不进信封，管理端只看到一片空白）；② 被拒的那一发**没把旧行改掉**。
dup=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"default","remark":"第二条"}')
still=$(q "SELECT COALESCE(group_code,'<none>') FROM gateway_group_overrides WHERE user_id=1")
upd=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X PUT "$U/admin/gateway/group-override/update" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"default","remark":"改回默认价"}')
now48=$(q "SELECT COALESCE(group_code,'<none>') FROM gateway_group_overrides WHERE user_id=1")
b2=$(relay26); sleep 1; back=$(charged26)
[ "$dup" = "409" ] && [ "$still" = "vip48" ] && [ "$upd" = "200" ] && [ "$now48" = "default" ] \
  && [ "$b2" = "200" ] && [ "$back" = "$base" ] \
  && pass "一人一条：重复 create=${dup}（409 而非 500）且旧行仍是 ${still} 没被踩；update 才是改它的入口=${upd} → ${now48}，且计价跟着回到基线（charged ${with48}→${back}，等于基线 ${base}）" \
  || fail "唯一性/更新不对: 重复create=${dup}(期望409) 被拒后库里=${still}(期望vip48) update=${upd}(期望200) 现值=${now48}(期望default) relay=${b2} charged=${back}(期望=${base}) body=$(head -c 160 "$GB" 2>/dev/null)"

# 最后两件事：撤销真的是硬删（表无 deleted 列），以及 app 组一条也不许有 ——
# 自助用户能设自己的计费组就等于自己给自己打折。404 而不是 403：路由就不应该存在，
# 403 反而会告知攻击者「这条路对，只是你不够权」。
del=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group-override/delete/1" -H "Authorization: Bearer $GJWT")
gone48=$(q "SELECT COUNT(*) FROM gateway_group_overrides WHERE user_id=1")
del2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group-override/delete/1" -H "Authorization: Bearer $GJWT")
nfbody=$(curl -s --max-time 10 "$U/admin/gateway/group-override/get/1" -H "Authorization: Bearer $GJWT")
ac1=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U/app/gateway/group-override/create" -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"vip48"}')
ac2=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$U/app/gateway/group-override/list" -H "Authorization: Bearer $GJWT")
ac3=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/app/gateway/group-override/delete/1" -H "Authorization: Bearer $GJWT")
leak48=$(q "SELECT COUNT(*) FROM gateway_group_overrides")
[ "$del" = "200" ] && [ "$gone48" = "0" ] && [ "$del2" = "404" ] \
  && printf '%s' "$nfbody" | grep -q '"data":null' \
  && [ "$ac1" = "404" ] && [ "$ac2" = "404" ] && [ "$ac3" = "404" ] && [ "$leak48" = "0" ] \
  && pass "撤销是硬删且 app 组不暴露：delete=${del} 且行已消失(${gone48})、再删=${del2}（404 而非 500）、get 回 ${nfbody}；app 组下 create/list/delete 均 ${ac1}/${ac2}/${ac3}（路由不存在，不是 403），全表剩 ${leak48} 行" \
  || fail "撤销/暴露不对: delete=${del}(期望200) 删后行数=${gone48}(期望0) 再删=${del2}(期望404) get回显='${nfbody:0:80}'(期望 data:null) app组 create=${ac1} list=${ac2} delete=${ac3}（均期望404）全表行数=${leak48}(期望0)"

rm -f "$GB"

# ══ S49 权限 → 菜单 → 页面 的接线完整性（常驻哨兵）══
# 前面 48 个场景断言的都是「跑起来的行为」，这一条断言的是「能不能被委派」。
# rbac-spec §1.4 冻结了权限只能经 菜单 → 角色 → 用户 继承，禁止 User→Permission 与
# Role→Permission 直连。所以一个 @Permission 串如果没有 system_menus 行，它就无法被授予任何
# 角色 —— 只有 super_admin 的 *:*:* 通配能过。**这个洞不会让任何一条行为断言变红**：
# 接口照样 200，因为跑 harness 用的就是超级管理员。它只能靠「数注解、数种子」看见。
# 三道：① 每个 @Permission 都有菜单种子 ② 每个二级菜单的 component 都有前端页面
# ③ 根目录与二级菜单都 status=1（前端 buildRouteMap/buildNav 对 status!==1 直接 continue，
#    而列默认值是 0 —— 漏写这一位，菜单既不进侧栏也不进路由表，且不报任何错；
#    根目录被跳时整棵子树跟着不可达）。
echo "[S49] 权限→菜单→页面 接线完整性"
NETON="$NEWGATE/../../Neton"
GWSRC="$NETON/neton-application-module-gateway/src/commonMain/kotlin"
GWMANIFEST="$NETON/neton-application-front-gateway/src/manifest.ts"
A1=/tmp/s49-annot-$$; A2=/tmp/s49-seeded-$$; A3=/tmp/s49-comp-$$; A4=/tmp/s49-keys-$$
if [ -d "$GWSRC" ]; then
  # 注解集只取字面量形式。已核实本模块 44 处 @Permission 全是字面量、无 @Permission(CONST)
  # 写法，也无全限定名 —— 后者（@neton.core.annotations.Permission）曾在 payment 骗过一次扫描，
  # 把本来有保护的退款端点报成了授权洞。将来换了写法，这里的数字会当场对不上。
  grep -rhoE '@Permission\("[^"]+"\)' "$GWSRC" | sed 's/@Permission("//;s/")//' | sort -u > "$A1"
  q "SELECT permission FROM system_menus WHERE permission LIKE 'gateway:%' ORDER BY 1" | sort -u > "$A2"
  na=$(wc -l < "$A1" | tr -d ' '); ns=$(wc -l < "$A2" | tr -d ' ')
  miss=$(comm -23 "$A1" "$A2" | tr '\n' ' '); nmiss=$(comm -23 "$A1" "$A2" | wc -l | tr -d ' ')
  orph=$(comm -13 "$A1" "$A2" | tr '\n' ' '); norph=$(comm -13 "$A1" "$A2" | wc -l | tr -d ' ')
  # 只卡「有注解无种子」这个方向（它造成真实伤害：权限委派不出去）。
  # 反方向（有种子无注解）只是一个点了没对应接口的死按钮，不造成越权，所以只报数不判红 ——
  # 拿它判红会卡住「先播菜单、后接接口」这种合理的施工顺序。
  [ "$nmiss" = "0" ] \
    && pass "每个 @Permission 都有菜单种子（注解 ${na} 个唯一串 vs 种子 ${ns} 行，缺口 0）；反向孤儿种子 ${norph} 个 ${orph}——不判红，但应该是 0" \
    || fail "有注解无菜单种子 ${nmiss} 个（按 rbac-spec §1.4 这些权限无法被授予任何角色，只有 super_admin 能用）: ${miss} | 注解=${na} 种子=${ns}"
else
  echo "  ⚠️  跳过注解↔种子比对：$GWSRC 不存在" >&2
fi
if [ -f "$GWMANIFEST" ]; then
  # component 是承重字段：前端 catch-all 拿它去 pageRegistry 取 loader（而 pageRegistry 由
  # manifest 的 page key 生成）。对不上就是悬空引用，点进去只得到「页面未安装」。
  q "SELECT component FROM system_menus WHERE component LIKE 'gateway/%' ORDER BY 1" | sort -u > "$A3"
  grep -oE 'key: "[^"]+"' "$GWMANIFEST" | sed 's/key: "//;s/"//' | sort -u > "$A4"
  dang=$(comm -23 "$A3" "$A4" | tr '\n' ' '); ndang=$(comm -23 "$A3" "$A4" | wc -l | tr -d ' ')
  ncomp=$(wc -l < "$A3" | tr -d ' '); nkey=$(wc -l < "$A4" | tr -d ' ')
  [ "$ndang" = "0" ] \
    && pass "每个菜单 component 都有前端页面（菜单 ${ncomp} 个 component vs manifest ${nkey} 个 key，悬空 0）" \
    || fail "菜单引用了不存在的页面 ${ndang} 个（点进去只会得到「页面未安装」）: ${dang} | 菜单 component=${ncomp} manifest key=${nkey}"
else
  # CI 只 checkout 后端模块（见 backend-ci.yml），前端仓不在 —— 这道比对在那里无从执行。
  echo "  ⚠️  跳过 component↔manifest 比对：$GWMANIFEST 不存在（CI 不 checkout 前端仓）" >&2
fi
bad49=$(q "SELECT COUNT(*) FROM system_menus WHERE status <> 1 AND (component LIKE 'gateway/%' OR (type = 1 AND path = '/gateway'))")
n49=$(q "SELECT COUNT(*) FROM system_menus WHERE component LIKE 'gateway/%'")
[ "$bad49" = "0" ] && [ "$n49" -ge 8 ] \
  && pass "gateway 菜单全部 status=1（${n49} 个二级菜单均可路由，根目录也未被停用）" \
  || fail "菜单不可达: status<>1 的 gateway 菜单=${bad49}(期望0) 二级菜单总数=${n49}(期望>=8：V001 的 5 个 + V005 的 3 个)"
rm -f "$A1" "$A2" "$A3" "$A4"

# ══ S50 兑换码列表脱敏：能看列表 ≠ 能兑换 ══
# 码在库里是明文（model/RedemptionCode.kt 记着理由：运营要能把码导出发给客户）。但 /page 是
# 给「盘点与审计」用的，不是给「取码」用的 —— 完整码只在 /generate 那一刻下发一次。
# 脱敏之前 /page 返回的就是完整码，于是 gateway:redemption:list 这条**本来是要给只读审计
# 角色**的权限，实际含义变成「把库里所有未使用的码兑进自己账户」。码体 99 bit 的熵在这条
# 通路上完全不起作用：熵防的是「猜」，而列表直接把答案念出来了。
# 所以头号断言不是字符串比对，而是**拿 /page 返回的串真去兑一次**：脱敏被摘掉，这一发就会
# 200 并且真入账 —— 字符串断言只能证明「看起来脱敏了」，这一条证明「兑不动」。
echo "[S50] 兑换码列表脱敏：能看列表不等于能兑换"
GJWT=$(admin_jwt)
gen50=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/generate" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"quotaMicro":70000,"count":3,"note":"S50 脱敏"}')
batch50=$(printf '%s' "$gen50" | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('batchId',''))" 2>/dev/null)
# A：/generate 必须给完整码。脱敏脱到这里就是把功能脱没了 —— 运营只有这一次机会导出。
gok=0; gtot=0
for c in $(printf '%s' "$gen50" | python3 -c "import sys,json;print(' '.join((json.load(sys.stdin).get('data') or {}).get('codes',[])))" 2>/dev/null); do
  gtot=$((gtot+1)); b=$(printf '%s' "$c" | tr -d '-' | tr 'a-z' 'A-Z')
  [ "${#b}" = "20" ] && [ "$(q "SELECT COUNT(*) FROM gateway_redemption_codes WHERE code='$b'")" = "1" ] && gok=$((gok+1))
done
[ -n "$batch50" ] && [ "$gtot" = "3" ] && [ "$gok" = "3" ] \
  && pass "/generate 下发完整码（${gok}/${gtot} 都是 20 字符裸码且库里查得到），批次 ${batch50}" \
  || fail "/generate 没给完整码: batch=${batch50} 返回=${gtot}(期望3) 完整且入库=${gok}(期望3)"
# B：/page 不得泄露。裸形态与展示形态都查，因为泄露哪一种都能兑。
pg50=$(curl -s --max-time 20 "$U/admin/gateway/redemption/page?pageNo=1&pageSize=50&batchId=$batch50" -H "Authorization: Bearer $GJWT")
P50=/tmp/s50-page-$$
printf '%s' "$pg50" | python3 -c "
import sys,json
for r in ((json.load(sys.stdin).get('data') or {}).get('list') or []): print(r.get('id'), r.get('code'))
" > "$P50" 2>/dev/null
fmt50() { printf '%s' "$1" | sed -E 's/^(.{5})(.{5})(.{5})(.{5})$/\1-\2-\3-\4/'; }
leak=0
while read -r b; do
  [ -n "$b" ] || continue
  f=$(fmt50 "$b")
  case "$pg50" in *"$b"*) leak=$((leak+1));; esac
  case "$pg50" in *"$f"*) leak=$((leak+1));; esac
done < <(q "SELECT code FROM gateway_redemption_codes WHERE batch_id='$batch50' ORDER BY id")
nostar=0; misplaced=0; nrows=0
while read -r rid rcode; do
  [ -n "$rid" ] || continue
  nrows=$((nrows+1))
  case "$rcode" in *"*"*) ;; *) nostar=$((nostar+1));; esac
  # 首尾两组必须与库里**同一 id** 的码一致：全掩的话客服对不上号，等于把功能删了。
  # 按 id 对而不是按顺序对：/page 是 id 倒序、/generate 是插入顺序，两边第一行不是同一张码。
  db=$(q "SELECT code FROM gateway_redemption_codes WHERE id=$rid")
  [ "$(printf '%s' "$rcode" | cut -c1-5)" = "$(printf '%s' "$db" | cut -c1-5)" ] || misplaced=$((misplaced+1))
  [ "$(printf '%s' "$rcode" | rev | cut -c1-5 | rev)" = "$(printf '%s' "$db" | rev | cut -c1-5 | rev)" ] || misplaced=$((misplaced+1))
done < "$P50"
[ "$nrows" = "3" ] && [ "$leak" = "0" ] && [ "$nostar" = "0" ] && [ "$misplaced" = "0" ] \
  && pass "/page 不泄露完整码（${nrows} 行；本批 3 张码的裸形态与展示形态在响应体里各 0 次命中、每行都带掩码、首尾两组仍与库里同 id 的码对得上）" \
  || fail "/page 泄露或脱敏过头: 行数=${nrows}(期望3) 泄露命中=${leak}(期望0) 无掩码行=${nostar}(期望0) 首尾对不上=${misplaced}(期望0)"
# C：拿 /page 给的串真去兑 —— 必须兑不动、一分不入账。这一条才是脱敏的意义。
rid1=$(head -1 "$P50" | cut -d' ' -f1); rcode1=$(head -1 "$P50" | cut -d' ' -f2-)
bal50=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
d50=$(curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/redeem" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"code\":\"$rcode1\"}"); sleep 1
bal50a=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
m50=$(python3 -c "import json;print(json.load(open('$GB')).get('message') or '')" 2>/dev/null)
ntx50=$(q "SELECT COUNT(*) FROM gateway_quota_transactions t JOIN gateway_redemption_codes r ON t.ref='redeem:'||r.code WHERE r.batch_id='$batch50'")
# /disable/{id} 与 /page 共用同一个 toVO，但「共用」是会被改散的，所以单独验一次。
dis50=$(curl -s --max-time 20 -X POST "$U/admin/gateway/redemption/disable/$rid1" -H "Authorization: Bearer $GJWT")
dcode50=$(printf '%s' "$dis50" | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('code',''))" 2>/dev/null)
# 404「兑换码无效」而不是 400「格式不正确」：前者是「查不到这张码」，后者意味着脱敏串
# 归一化后反而变长了 —— 两者都兑不动，但只有前者是设计意图。
case "$m50" in *"无效"*) okmsg=1;; *) okmsg=0;; esac
[ "$d50" = "404" ] && [ "$okmsg" = "1" ] && [ "$bal50a" = "$bal50" ] && [ "$ntx50" = "0" ] && [ "$dcode50" = "$rcode1" ] && [ -n "$dcode50" ] \
  && pass "拿 /page 的脱敏串去兑 → 404「${m50}」、余额 ${bal50}→${bal50a} 一分未动、本批 redeem 台账 ${ntx50} 条；/disable 的响应同样脱敏（${dcode50}）" \
  || fail "脱敏形同虚设: 兑 /page 给的串 HTTP=${d50}(期望404) message='${m50}'(期望含「无效」) 余额=${bal50}->${bal50a}(期望不变) 台账=${ntx50}(期望0) /disable 返回='${dcode50}'(期望等于 /page 的 '${rcode1}')"
rm -f "$P50"

# ══ S51 额度撤回：能发就得能收，收了要真收得住 ══
# 缺口：QuotaController 到本轮之前只有 grant，没有反向操作。运营误发额度（金额多打一个 0）
# 之后没有任何受支持的撤回路径，剩下唯一的工具是直接改库 —— 而台账是只增不改的审计链，
# balance_after 逐行累加，改掉一行会让它之后所有行的 balance_after 全部失真，等于把
# 「钱的唯一审计来源」弄坏。所以这条场景锁的不是「有个撤回接口」，而是撤回真的落在账上。
#
# 撤回的语义与 settle 一致（无条件扣、允许转负）而不是与 consume 一致（不足即拒）。
# 块 C 因此断言的是**转负成功**：若哪天有人把它改成看起来更安全的「余额不足即拒」，块 C 与
# 块 G 会一起红 —— 那种改法会让撤回在最需要它的场景下失效（误发的额度被用户赶紧花掉就撤不
# 回来了），而拒绝的理由听起来永远像是谨慎。
echo "[S51] 额度撤回：真扣钱、幂等、允许转负、非法入参与越权一律挡住"
GJWT=$(admin_jwt)
# 零角色主体自建，不沿用 S46 的 csjwt：S51 要能独立成立，不该因为 S46 改了 token 就连带失败。
q "INSERT INTO system_users (id, username, password_hash, nickname, status, created_at, updated_at) SELECT 951, 'cs_s51', password_hash, 'S51 客服', 1, 0, 0 FROM system_users WHERE id=1 ON CONFLICT (id) DO NOTHING" >/dev/null
csjwt51=$(curl -s --max-time 10 -X POST "$U/admin/system/auth/login" -H "$CT" \
  -d '{"username":"cs_s51","password":"admin123"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('accessToken',''))" 2>/dev/null)
csrole51=$(q "SELECT COUNT(*) FROM system_user_roles WHERE user_id=951")
# 环境自建，且**不跑 seed_reset**：它会 TRUNCATE gateway_quota_transactions，而台账正是本场景
# 的断言对象。渠道/定价/上游都用 S51 独占的名字与端口，不碰 S48 留下的那套。
fake ok 9951; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c51','openai_compatible','http://127.0.0.1:9951','default','m-rv51',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c51'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-rv51','2.5','10','0','0',5000,'manual',0,0,0);" >/dev/null
rv51() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/quota/revoke" \
  -H "Authorization: Bearer $1" -H "$CT" -d "$2"; }
relay51() { curl -s --max-time 20 -o "$GB" -w "%{http_code}" -X POST "$U/v1/chat/completions" \
  -H "$AUTH" -H "$CT" -d '{"model":"m-rv51","messages":[]}'; }
msg51() { python3 -c "import json;print(json.load(open('$GB')).get('message') or '')" 2>/dev/null; }
# relay 的错误信封与 admin 的不是同一个形状，取值函数因此必须分开：
#   admin 走框架统一信封，message 在顶层；
#   relay 走 respondError → inbound.errorBody，OpenAiAdapter 产出
#   {"error":{"message":...,"type":"<code>","code":"<code>"}} —— 顶层没有 message。
# 共用一个抽取函数正是本场景第一版翻红的成因：402 拿到了、reserved 归零了、余额没动了，
# 唯独理由是空串，于是「撤回真的挡住了请求」这条最关键的因果看起来像没成立。
# 分开之后，将来哪个信封改了只会红对应的那一块，不会让两类断言互相污染。
rmsg51() { python3 -c "import json;d=json.load(open('$GB'));e=d.get('error') or {};print(e.get('message') or '')" 2>/dev/null; }
rtype51() { python3 -c "import json;d=json.load(open('$GB'));e=d.get('error') or {};print(e.get('type') or '')" 2>/dev/null; }

# ── 块 G 的前半：撤回**之前**必须先证明这条路是通的 ──
# 没有这一发对照，后面的 402 可以来自任何原因（渠道挂了、定价缺失、上游没起），
# 而场景会绿着放行一个「谁都调不通」的接口。与 S46 的 admin 对照同一个道理。
rpre51=$(relay51); sleep 1

# ── 块 A：撤回真扣钱、台账 type='revoke'、balance_after 对得上、reserved_balance 不被碰 ──
bala51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
resa51=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
hA51=$(rv51 "$GJWT" '{"userId":1,"amount":30000,"ref":"revoke:s51-a"}'); sleep 1
balA51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
resA51=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
rowA51=$(q "SELECT amount||'|'||balance_after FROM gateway_quota_transactions WHERE ref='revoke:s51-a' AND type='revoke'")
nA51=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='revoke:s51-a'")
# voA51 取的是 revokedAmount，期望值 **30000 而不是 -30000**：撤回量恒正，而台账的 amount 是
# 「余额变动了多少」（带符号，撤回为负，就是上面 rowA51 期望里的 -30000）。
# 第一版断言把两者当成同一个东西，于是其余五项真实数字全对、只有这一项不符而翻红。
# 字段当时叫 amount，与台账同名不同义 —— 歧义活在 JSON 里，而我是照着 JSON 字段名写的断言，
# 所以光在 Kotlin 侧加 KDoc 兜不住，已把它改名成 revokedAmount（理由写在 VO 的类级 KDoc 里）。
voA51=$(python3 -c "import json;d=json.load(open('$GB')).get('data') or {};print(d.get('balance'),d.get('revokedAmount'),d.get('ref'))" 2>/dev/null)
[ "$hA51" = "200" ] && [ "$balA51" = "$((bala51-30000))" ] && [ "$rowA51" = "-30000|$balA51" ] && [ "$nA51" = "1" ] \
  && [ "$resA51" = "$resa51" ] && [ "$voA51" = "$balA51 30000 revoke:s51-a" ] \
  && pass "撤回真扣钱：余额 ${bala51}→${balA51}(-30000)、台账 1 行 type=revoke amount=-30000 balance_after=${balA51}、reserved_balance ${resa51}→${resA51} 未被碰、响应与库一致（${voA51}）" \
  || fail "撤回没落在账上: HTTP=${hA51}(期望200) 余额=${bala51}->${balA51}(期望比前值少 30000) 台账行='${rowA51}'(期望 -30000|${balA51}) 台账数=${nA51}(期望1) reserved=${resa51}->${resA51}(期望不变) 响应='${voA51}'(期望 '${balA51} 30000 revoke:s51-a'，中间一项是恒正的撤回量)"

# ── 块 B：同 ref 重放只扣一次 ──
# ref 是撤回唯一的幂等键，所以它必填（块 E 断言）。运营在后台双击一次就是双扣的话，
# 台账上看不出这是两次还是一次 —— 与 S36 的重兑、S8 的重复 ref 同一套路数。
hB51=$(rv51 "$GJWT" '{"userId":1,"amount":30000,"ref":"revoke:s51-a"}'); sleep 1
balB51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nB51=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='revoke:s51-a'")
[ "$hB51" = "200" ] && [ "$balB51" = "$balA51" ] && [ "$nB51" = "1" ] \
  && pass "同 ref 重放幂等：HTTP=${hB51}（幂等跳过不报错）、余额仍 ${balB51}、台账仍 ${nB51} 行" \
  || fail "撤回不幂等: HTTP=${hB51}(期望200) 余额=${balA51}->${balB51}(期望不变) 台账=${nB51}(期望1)"

# ── 块 D+E：非法入参给干净的 400，且零副作用 ──
# 负数 amount 不是输入卫生问题：revoke(-50000) 就是一次发放，持有 gateway:quota:revoke 的人
# 借此绕过 gateway:quota:grant，两个权限的分离形同虚设。所以拒绝理由必须**点名 grant**，
# 与 S47 要求点名权限串同理 —— 只断 400 的话，任何一处校验失败都长得一样。
balD51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nledD51=$(q "SELECT COUNT(*) FROM gateway_quota_transactions")
hD51=$(rv51 "$GJWT" '{"userId":1,"amount":-50000,"ref":"revoke:s51-d"}'); mD51=$(msg51)
hE51=$(rv51 "$GJWT" '{"userId":1,"amount":1000,"ref":""}'); mE51=$(msg51)
hE251=$(rv51 "$GJWT" '{"userId":1,"amount":0,"ref":"revoke:s51-e2"}'); mE251=$(msg51)
sleep 1
balD51b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nledD51b=$(q "SELECT COUNT(*) FROM gateway_quota_transactions")
case "$mD51" in *"gateway:quota:grant"*) okD51=1;; *) okD51=0;; esac
[ "$hD51" = "400" ] && [ "$okD51" = "1" ] && [ "$hE51" = "400" ] && [ "$hE251" = "400" ] \
  && [ "$balD51b" = "$balD51" ] && [ "$nledD51b" = "$nledD51" ] \
  && pass "非法入参一律 400 且零副作用：负数 amount=${hD51}（理由点名 gateway:quota:grant）、空 ref=${hE51}、零 amount=${hE251}；余额仍 ${balD51b}、台账仍 ${nledD51b} 行" \
  || fail "非法入参没挡住: 负数=${hD51}(期望400) 点名grant=${okD51}(期望1，message='${mD51}') 空ref=${hE51}(期望400，'${mE51}') 零amount=${hE251}(期望400，'${mE251}') 余额=${balD51}->${balD51b}(期望不变) 台账=${nledD51}->${nledD51b}(期望不变)"

# ── 块 F：零角色主体必须 403 且点名权限，admin 对照 200 ──
balF51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
hF51=$(rv51 "$csjwt51" '{"userId":1,"amount":1000,"ref":"revoke:s51-f"}'); mF51=$(msg51); sleep 1
balF51b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nF51=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='revoke:s51-f'")
case "$mF51" in *"gateway:quota:revoke"*) okF51=1;; *) okF51=0;; esac
[ -n "$csjwt51" ] && [ "$csrole51" = "0" ] && [ "$hF51" = "403" ] && [ "$okF51" = "1" ] \
  && [ "$balF51b" = "$balF51" ] && [ "$nF51" = "0" ] && [ "$hA51" = "200" ] \
  && pass "撤回要授权不只是认证：零角色账号（角色数 ${csrole51}）登录成功但撤回=${hF51} 且理由点名 gateway:quota:revoke、余额仍 ${balF51b}、台账 ${nF51} 行；同一接口换 super_admin → ${hA51}" \
  || fail "撤回的授权边界不对: cs登录=$([ -n "$csjwt51" ] && echo yes || echo no)(期望yes) 角色数=${csrole51}(期望0) HTTP=${hF51}(期望403) 点名权限=${okF51}(期望1，message='${mF51}') 余额=${balF51}->${balF51b}(期望不变) 台账=${nF51}(期望0) admin对照=${hA51}(期望200)"

# ── 块 C：撤到转负也必须成功（这是与 consume 的分界线）──
balC51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
over51=$((balC51 + 50000))
hC51=$(rv51 "$GJWT" "{\"userId\":1,\"amount\":${over51},\"ref\":\"revoke:s51-c\"}"); sleep 1
balC51b=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
availC51=$(q "SELECT balance - reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
voC51=$(python3 -c "import json;d=json.load(open('$GB')).get('data') or {};print(d.get('balance'),d.get('available'))" 2>/dev/null)
[ "$hC51" = "200" ] && [ "$balC51b" = "-50000" ] && [ "$availC51" = "-50000" ] && [ "$voC51" = "-50000 -50000" ] \
  && pass "撤到转负成功（不是「余额不足被拒」）：余额 ${balC51} 撤 ${over51} → ${balC51b}、可用余额 ${availC51}、响应 balance/available 与库一致" \
  || fail "撤回在余额不足时被拒了（语义被改成了 consume 那一套）: HTTP=${hC51}(期望200) 余额=${balC51}->${balC51b}(期望-50000) 可用=${availC51}(期望-50000) 响应='${voC51}' message='$(msg51)'"

# ── 块 G 的后半：撤回生效 = 用户真的用不了了 ──
# 数字变了不等于功能生效。这一发证明撤回落在了一条真实的商业通路上：余额转负后新请求必须
# 402 insufficient_quota。顺带把 402 这条路径第一次纳入 harness —— 此前 run.sh 里没有任何
# 场景断言过余额不足，而它是「没钱就不给调上游」唯一的闸门。
# 还要断言 402 之后 reserved_balance 归零：reserve 失败时 SettlementLogic 会补偿撤销刚占的
# token 预留（净效果为零），若那道补偿被改掉，这里会留下泄漏的预留，用户后续充值也用不掉。
hG51=$(relay51); sleep 1
mG51=$(rmsg51)
tG51=$(rtype51)
resG51=$(q "SELECT reserved_balance FROM gateway_quota_accounts WHERE user_id=1")
balG51=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
nlogG51=$(q "SELECT COUNT(*) FROM gateway_usage_logs WHERE request_model='m-rv51'")
ntxG51=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE type='consume' AND created_at > 0")
# type 精确断言 insufficient_quota，message 还须含 balance：RelayEngine 里 402（账户余额不足）与
# 429（token 预算耗尽）共用同一个 error.type，只断 type 分不清这一发到底是被「撤回扣掉的账户
# 余额」挡的、还是被某个 token 的预算挡的。而本场景要证的因果恰恰是前者 —— 撤回动的是
# gateway_quota_accounts.balance，与 token 预算无关。message 含 balance 才把这条因果钉死。
case "$mG51" in *balance*) okG51=1;; *) okG51=0;; esac
[ "$rpre51" = "200" ] && [ "$hG51" = "402" ] && [ "$tG51" = "insufficient_quota" ] && [ "$okG51" = "1" ] \
  && [ "$resG51" = "0" ] && [ "$balG51" = "$balC51b" ] \
  && pass "撤回真的生效：撤回前 relay=${rpre51}（对照，证明渠道/定价/上游都正常）→ 撤到转负后 relay=${hG51} type=${tG51} 理由='${mG51}'（是账户余额不足，不是 token 预算）；402 之后 reserved_balance=${resG51}（无泄漏预留）、余额仍 ${balG51}、m-rv51 用量日志 ${nlogG51} 行" \
  || fail "撤回没落到真实通路上: 撤回前 relay=${rpre51}(期望200，若不是则本块环境就没搭好) 撤回后=${hG51}(期望402) type='${tG51}'(期望 insufficient_quota) 理由含balance=${okG51}(期望1，message='${mG51}') reserved=${resG51}(期望0) 余额=${balC51b}->${balG51}(期望不变) 用量日志=${nlogG51} consume台账=${ntxG51}"

# ══ S52 用户控制台接线完整性：装配了的页面必须有侧栏入口，icon 名必须真的存在 ══
# C 端与 B 端是两套毫不相干的接线，所以 S49 那三道断言对用户控制台一条都不适用：管理台的侧栏
# 来自数据库（system_menus → buildNav），用户侧的侧栏来自一个静态数组
# （newgate-client/apps/console/src/config/console.nav.ts），与库、与 RBAC、与权限全无关系
# —— layout 给 AppShell 传的是 roles={[]} permissions={[]}，每个登录用户看到的都一样。
# 这个数组此前就是空的：`export const consoleNav: NavItem[] = [];`。后果是 console 装配的 5 个
# 页面路由全在、组件全能渲染、typecheck 全绿，而用户登录后侧栏一片空白，进入任何一页的唯一
# 方式是手敲 URL。**没有任何一条既有断言会因此变红** —— 「页面装配了」记在各模块的 manifest.ts
# 里、「页面有入口」记在 app 的 nav 里，两套文件谁都不检查对方。这与 S49 要抓的洞同构：
# 能力本身存在，授予它的那根接线断了，而断掉是静默的。
# 三处静默失配各钉一道：
# ① 已装配页面 → nav 里有条目（漏了就是只能手敲 URL 的隐形页）；
# ② nav 条目 → 页面真存在（漏了就是点进去 404 的死链接：页面被删而 nav 忘了跟着改）；
# ③ icon 名 → app-shell 的 iconMap 里真有这个键。NavItem.icon 的类型是 string|null，写错任何串
#    typecheck 都放行，resolveIcon 静默回落 CircleDot —— 图标错了不报错，只是侧栏长得不对。
# ①② 互为守卫：页面集若被算空，① 会假绿（0 个页面自然 0 个无入口）而 ② 立刻红（nav 的 5 条
# 全成了悬空）。但两边同时算空时①②都绿 —— 那恰好是原始缺陷的形状，所以 ① 另加一条 >=5 的下限。
# 页面集取自 console 自己 package.json 的 file: 依赖、再读各模块 manifest.ts，不读
# modules.generated.ts：生成物要跑 pnpm 才有，manifest 是源码、永远在。cs 模块存在于仓库但没进
# console 的依赖，所以不计入 —— 「装配了什么」由 app 说了算，不由模块自己说了算。
echo "[S52] 用户控制台接线完整性：页面有入口、入口有页面、icon 名存在"
CONSOLE52="$ROOT/newgate-client/apps/console"
NAV52="$CONSOLE52/src/config/console.nav.ts"
SHELL52="$CONSOLE52/src/components/app-shell.tsx"
B1=/tmp/s52-mods-$$; B2=/tmp/s52-pages-$$; B3=/tmp/s52-nav-$$; B4=/tmp/s52-icons-$$; B5=/tmp/s52-iconmap-$$
if [ -f "$CONSOLE52/package.json" ] && [ -f "$NAV52" ] && [ -f "$SHELL52" ]; then
  grep -oE '"@neton/application-client-[a-z]+": "file:[^"]+"' "$CONSOLE52/package.json" \
    | sed 's/.*"file://;s/"$//' > "$B1"
  : > "$B2"
  # while read 而不是 for $mods：for 靠词分割，而词分割在 zsh 下不发生（整个多行串被当成一个
  # 路径）。本场景的提取链就是这么断过一次 —— 页面数算成 0，5 条正确的 nav 全被报成悬空入口。
  while read -r m52; do
    [ -n "$m52" ] || continue
    d52=$(cd "$CONSOLE52/$m52" 2>/dev/null && pwd) || continue
    [ -f "$d52/src/manifest.ts" ] || continue
    grep -oE 'path: "[^"]+"' "$d52/src/manifest.ts" | sed 's/path: "//;s/"$//' >> "$B2"
  done < "$B1"
  sort -u "$B2" -o "$B2"
  grep -oE 'path: "[^"]+"' "$NAV52" | sed 's/path: "//;s/"$//' | sort -u > "$B3"
  nm52=$(wc -l < "$B1" | tr -d ' '); np52=$(wc -l < "$B2" | tr -d ' '); nn52=$(wc -l < "$B3" | tr -d ' ')
  hide=$(comm -23 "$B2" "$B3" | tr '\n' ' '); nhide=$(comm -23 "$B2" "$B3" | wc -l | tr -d ' ')
  dead=$(comm -13 "$B2" "$B3" | tr '\n' ' '); ndead=$(comm -13 "$B2" "$B3" | wc -l | tr -d ' ')
  [ "$nhide" = "0" ] && [ "$np52" -ge 5 ] \
    && pass "每个已装配页面都有侧栏入口（${nm52} 个 client 模块 → ${np52} 个页面 vs nav ${nn52} 条，隐形页 0）" \
    || fail "隐形页 ${nhide} 个（路由与组件都在、typecheck 也绿，用户却只能手敲 URL 进去）: ${hide} | 页面=${np52}(期望>=5：gateway 3 页 + member 1 页 + payment 1 页) nav=${nn52}"
  [ "$ndead" = "0" ] \
    && pass "每条侧栏入口都指向真页面（悬空 0）" \
    || fail "nav 里有 ${ndead} 条指向不存在的页面（点进去 404）: ${dead} | 页面=${np52} nav=${nn52}"
  grep -oE 'icon: "[^"]+"' "$NAV52" | sed 's/icon: "//;s/"$//' | sort -u > "$B4"
  sed -n '/^const iconMap/,/^};/p' "$SHELL52" | grep -oE '^ *"?[A-Za-z-]+"?:' | tr -d ' ":' | sort -u > "$B5"
  ni52=$(wc -l < "$B4" | tr -d ' '); nk52=$(wc -l < "$B5" | tr -d ' ')
  badicon=$(comm -23 "$B4" "$B5" | tr '\n' ' '); nbad=$(comm -23 "$B4" "$B5" | wc -l | tr -d ' ')
  [ "$nbad" = "0" ] && [ "$nk52" -ge 1 ] \
    && pass "每个 icon 名都在 iconMap 里（nav 用了 ${ni52} 个图标 vs iconMap ${nk52} 个键，非法 0）" \
    || fail "nav 引用了不存在的 icon ${nbad} 个（NavItem.icon 是自由串，typecheck 放行，resolveIcon 静默回落 CircleDot）: ${badicon} | iconMap 键=${nk52}(期望>=1，为 0 说明提取链断了)"
else
  # CI 只 checkout 后端模块（见 backend-ci.yml），用户控制台仓不在 —— 这三道在那里无从执行。
  echo "  ⚠️  跳过用户控制台接线比对：$CONSOLE52 下文件不齐（CI 不 checkout 前端仓）" >&2
fi
rm -f "$B1" "$B2" "$B3" "$B4" "$B5"

# ══ S53 充值单回读：跳转付款回来后前端唯一的完成信号，且只能读自己的单 ══
# POST /app/gateway/recharge 在 displayMode=REDIRECT_URL 时把用户送出本站，回来后那个标签页对
# 「回调到底落了没有」一无所知。此前唯一可用的信号是轮询 usage/balance，而「余额没变」分不清
# 三种情况 —— 还在等 / 回调失败 / 单子已被服务端关掉。三者的处置分别是等、找运营、重新下单，
# 混成一个「没变」等于让用户自己猜。S32/S33 已经把「回调 → 入账」这半边钉死了，钉的是库里的
# 数字；用户看不到库。这一场景补的是从库到用户眼前那一段。
#
# 块 A/B 钉「回读说的与账面一致」：只断 payStatus 的话，一个把状态写对却不入账的实现照样绿，
# 而「已支付但没额度」正是 S33 要消灭的那种静默错账 —— 不能让 pay_status 一个字段替它作证。
# 块 C/D 钉归属门：跨用户必须 404，且与「查无此单」**逐字同形**。分成 403/404 两种就等于给
# 探测者装了一台「哪些 id 存在」的预言机，而 rechargeId 自增，那台预言机几乎零成本。
# 块 D 另加一条「message 非空」的下限守卫：提取链断掉时两边都是空串，相等会假绿 ——
# 与 S52 给隐形页那条加 >=5 下限是同一个理由。
# 块 E 钉第三种状态可读：下单失败被 close() 关掉的单必须回读成 payStatus=2，不能被过滤掉。
# 过滤掉的话用户拿到 404，于是「我点了充值、什么也没发生、什么也查不到」—— 那正是最容易变成
# 工单的一类。这里走的是**真 close() 路径**（未知渠道 → payment 抛 → 意图单被关闭），与 S40 同源；
# 不用 SQL 把 pay_status 改成 2 假装，那只会验到「字段能透传」，验不到 close 真的写了它。
echo "[S53] 充值单回读：状态与账面一致、跨用户与不存在同形 404、已关闭单可读"
st53() { curl -s --max-time 15 -o "$GB" -w "%{http_code}" "$U/app/gateway/recharge/get/$1" \
  -H "Authorization: Bearer $2"; }
jf53() { python3 -c "import json;v=(json.load(open('$GB')).get('data') or {}).get('$1');print('null' if v is None else v)" 2>/dev/null; }
jmsg53() { python3 -c "import json;print(json.load(open('$GB')).get('message') or '')" 2>/dev/null; }

# ── 块 A：刚下的单 —— 待支付、额度已算定、paidAt 还是空 ──
bal53=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
rc53=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"sandbox_alipay"}')
RID53=$(jf53 rechargeId); MOID53=$(jf53 merchantOrderId); AMT53=$(jf53 amountMicro)
# 下单响应的 message 与 body 必须在这里就存下来：下面 st53 会覆盖 $GB，那时再取就变成
# 回读端点的响应了 —— fail 信息指着错的那半边，比没有信息更坑（S8 就踩过这类坑）。
mrc53=$(jmsg53); brc53=$(head -c 200 "$GB")
hA53=$(st53 "${RID53:-0}" "$GJWT")
rowA53="$(jf53 payStatus) $(jf53 amountMicro) $(jf53 price) $(jf53 merchantOrderId) $(jf53 paidAt)"
[ "$rc53" = "200" ] && [ "$hA53" = "200" ] && [ "$rowA53" = "0 $AMT53 100 gateway:quota:$RID53 null" ] \
  && pass "块A 刚下的单可读：下单 ${rc53} → 回读 ${hA53}，payStatus=0(待支付) amountMicro=${AMT53} price=100 merchantOrderId=gateway:quota:${RID53} paidAt=null" \
  || fail "块A 回读与下单对不上: 下单=${rc53}(期望200) 回读=${hA53}(期望200) 回读行='${rowA53}'(期望'0 ${AMT53} 100 gateway:quota:${RID53} null') 下单响应 rechargeId=${RID53} merchantOrderId=${MOID53} amountMicro=${AMT53} message='${mrc53}' body=${brc53}"

# ── 块 B：回调落定后，回读说「已入账」而账面也真的入了 ──
cb53=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST \
  "$U/app/pay/channel-notify/sandbox_alipay/mock-success" -H "$CT" -d "{\"merchantOrderId\":\"$MOID53\"}")
sleep 1
hB53=$(st53 "$RID53" "$GJWT")
psB53=$(jf53 payStatus); paB53=$(jf53 paidAt); moB53=$(jf53 merchantOrderId)
balB53=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
ntx53=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='$MOID53' AND type='recharge'")
# paidAt 必须是正数时间戳：null/空/0 都算没写。-gt 对非数字会报错，所以先用 case 拦住。
okpa53=0; case "$paB53" in ''|null) ;; *) [ "$paB53" -gt 0 ] 2>/dev/null && okpa53=1;; esac
[ "$cb53" = "200" ] && [ "$hB53" = "200" ] && [ "$psB53" = "1" ] && [ "$okpa53" = "1" ] \
  && [ "$moB53" = "gateway:quota:$RID53" ] && [ "$ntx53" = "1" ] && [ "$balB53" = "$((bal53+AMT53))" ] \
  && pass "块B 回读与账面一致：回调 ${cb53} → payStatus=${psB53}(已入账) paidAt=${paB53}(>0) merchantOrderId=${moB53}；余额 ${bal53}→${balB53}(+${AMT53})、type='recharge' 台账 ${ntx53} 条" \
  || fail "块B 状态写对了但账没对上（或反之）: 回调=${cb53}(期望200) 回读=${hB53}(期望200) payStatus=${psB53}(期望1) paidAt=${paB53}(期望>0) merchantOrderId=${moB53}(期望gateway:quota:${RID53}) 台账=${ntx53}(期望1) 余额=${bal53}->${balB53}(期望$((bal53+AMT53)))"

# ── 块 C：另一个真会员读同一张单 → 404（不是 403） ──
read -r c53 tc53 <<<"$(sms_register '+8615000053001')"
hC53=$(st53 "$RID53" "$tc53"); mC53=$(jmsg53)
[ "$c53" != "0" ] && [ "$c53" != "1" ] && [ "$hC53" = "404" ] \
  && pass "块C 跨用户读不到：新会员 id=${c53} 读 user 1 的单 ${RID53} → ${hC53}（403 会确认单子存在，rechargeId 自增，那就是零成本的枚举预言机）" \
  || fail "块C 归属门没拦住: 新会员 id=${c53}(期望非0且非1，0 说明注册失败、环境未搭好) 回读=${hC53}(期望404) message='${mC53}'"

# ── 块 D：不存在的 id 也是 404，且 message 与块 C 逐字相同 ──
hD53=$(st53 999999999 "$GJWT"); mD53=$(jmsg53)
[ "$hD53" = "404" ] && [ -n "$mC53" ] && [ "$mC53" = "$mD53" ] \
  && pass "块D 「不是你的」与「不存在」同形：两者均 404 且 message 逐字相同（'${mD53}'）—— 分开就等于把存在性泄给了探测者" \
  || fail "块D 两种 404 可区分: 不存在id=${hD53}(期望404) message='${mD53}' vs 跨用户 message='${mC53}'（两者必须非空且相等，空串相等是提取链断了的假绿）"

# ── 块 E：下单失败被 close() 关掉的单仍可读，且回读成「已关闭」 ──
bal53e=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
bad53=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"no_such_channel_53"}')
sleep 1
# 这条路回 400（payment 的 resolveRoute 抛），响应体里没有 rechargeId，只能取 MAX(id) ——
# 与 S40 同一做法：本场景没有并发写手。多断一条 rid53e != RID53 把「根本没建新行」这种情况
# 从「pay_status 对不上」里分出来，否则 fail 信息会把人指到错的那半边。
rid53e=$(q "SELECT COALESCE(MAX(id),0) FROM gateway_quota_recharges")
psE53db=$(q "SELECT pay_status FROM gateway_quota_recharges WHERE id=$rid53e")
hE53=$(st53 "$rid53e" "$GJWT")
psE53=$(jf53 payStatus); paE53=$(jf53 paidAt)
ntx53e=$(q "SELECT COUNT(*) FROM gateway_quota_transactions WHERE ref='gateway:quota:$rid53e'")
bal53f=$(q "SELECT balance FROM gateway_quota_accounts WHERE user_id=1")
[ "$bad53" = "400" ] && [ "$rid53e" != "$RID53" ] && [ "$psE53db" = "2" ] && [ "$hE53" = "200" ] \
  && [ "$psE53" = "2" ] && [ "$paE53" = "null" ] && [ "$ntx53e" = "0" ] && [ "$bal53f" = "$bal53e" ] \
  && pass "块E 已关闭的单可读：未知渠道 → 下单 ${bad53}、意图单 ${rid53e} 被 close() 置 pay_status=${psE53db}；回读 ${hE53} payStatus=${psE53} paidAt=${paE53}、台账 ${ntx53e} 条、余额未动(${bal53f})" \
  || fail "块E 已关闭单的回读不对: 下单=${bad53}(期望400) 新单id=${rid53e}(期望!=${RID53}) 库中pay_status=${psE53db}(期望2) 回读=${hE53}(期望200，404 意味着已关闭单被过滤掉了) payStatus=${psE53}(期望2) paidAt=${paE53}(期望null) 台账=${ntx53e}(期望0) 余额=${bal53e}->${bal53f}(期望不变)"

# ══ S54 写用户级计费例外时校验 userId：打错一位数字必须响，不能静默按 default 计价 ══
# 钉的是 GROUP-OVERRIDE-ADMIN-CRUD-P1 的第一条 follow-up。此前 userId 只校验了正数：
# 把 10001 打成 100001，create 返回 200，例外静静躺在 gateway_group_overrides 里，而解析器
# 第 2 层是按**发起请求的那个** userId 查的，永远够不着它 —— 客户继续按 default 组计价，
# 谈判价没生效而**双方都不报错**：客户按标准价付了钱，运营以为给了折扣。
#
# 五块各钉一件事，少一块就有一种「看着对」的实现能溜过去：
#  A 不存在的 id → 400 且一行也不写。必须是 400 而不是 500：抛 IllegalArgumentException 会被
#    兜底成 500 + "Internal Server Error"，message 不进信封，管理端只看到一片空白。
#  B NORMAL 会员 → 200 且例外真的落库。这块是为了证明校验没把合法写入一起挡掉 ——
#    一个无条件 badRequest 的实现会让 A/C/D 全绿。
#  C **注销会员 → 400，且库里确实查得到这个会员**。这是本场景的灵魂：member 的自助注销
#    （MemberAuthLogic.deleteOwnAccount）只把 status 置 DELETED、**不动 deleted 列**，所以
#    MemberTable.get(id) 对注销会员依然返回非 null —— 一个只判「查得到」的实现会放行它。
#    那两条 SQL 断言（mbr54c/st54c）把「查得到、status=2、deleted=0」钉成事实，免得块 C
#    因为别的原因（比如 INSERT 根本没成功）而假绿。
#  D DISABLED 会员 → 400：判据是白名单 status == NORMAL，不是 status != DELETED。member 的
#    MemberStatus KDoc 用红字要求这么写 —— 否定式在新增状态时会默默放行，DELETED 当初就是
#    这么被漏掉的。
#  E 注销会员的**既有**例外仍可 delete → 拦写入、不拦清理。校验只挂在 create 上：会员注销
#    之后运营要的正是删掉那条例外，而按当前 status 拦 delete 会让它永远删不掉，谈判价就
#    永久留在表里指向一个不再存在的客户。
echo "[S54] 写计费例外校验 userId：不存在/注销/禁用一律 400 且零副作用，既有例外仍可清理"
# 显式 id 远离 member_users_id_seq（迁移把它 setval 到 GREATEST(MAX(id),10000)，自增从 10001 起，
# 所以 S26 的 id=1、S48 的 id=2 与 sms_register 拿到的 10000+ 互不相撞，这里同理）。
# status 必须显式写：DDL 默认 0(DISABLED) 而 Kotlin model 默认 1(NORMAL)，靠默认值会插出一个
# 与代码语义相反的账号 —— 块 D 就变成在测「DDL 默认值」而不是「禁用」。
q "INSERT INTO member_users (id,nickname,status,deleted,created_at,updated_at) VALUES
     (90541,'s54-normal',1,0,0,0),(90542,'s54-deleted',2,0,0,0),(90543,'s54-disabled',0,0,0,0)
   ON CONFLICT (id) DO UPDATE SET status=EXCLUDED.status, deleted=0;
   DELETE FROM gateway_group_overrides WHERE user_id IN (90541,90542,90543,999554);" >/dev/null
# default 组必须是活的：否则下面每一发的 400 都可能来自组码校验而不是 userId 校验，
# 四块会一起变成在测另一件事，而且照样绿。
g54=$(q "SELECT COALESCE(code,'<none>') FROM gateway_groups WHERE code='default' AND deleted=0")
ov54() { curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d "{\"userId\":$1,\"groupCode\":\"default\",\"remark\":\"S54\"}"; }
jm54() { python3 -c "import json;print(json.load(open('$GB')).get('message') or '')" 2>/dev/null; }
row54() { q "SELECT COUNT(*) FROM gateway_group_overrides WHERE user_id=$1"; }

# ── 块 A：不存在的 id → 400、点名原因、一行也不写 ──
aA54=$(ov54 999554); mA54=$(jm54); nA54=$(row54 999554)
[ "$g54" = "default" ] && [ "$aA54" = "400" ] && [ "$nA54" = "0" ] \
  && printf '%s' "$mA54" | grep -q "no chargeable member" \
  && pass "块A 打错 id 会响：userId=999554（库里没有）→ ${aA54}、message 点名原因（'${mA54:0:58}…'），一行也没写进去(${nA54})" \
  || fail "块A 不存在的 userId 没被拦: default组=${g54}(期望default，否则这发测的是组码校验) create=${aA54}(期望400，500 意味着 message 不进信封) 写入行数=${nA54}(期望0) message='${mA54:0:120}'(期望含 'no chargeable member')"

# ── 块 B：NORMAL 会员 → 200 且例外真的落库 ──
aB54=$(ov54 90541); nB54=$(row54 90541)
cB54=$(q "SELECT COALESCE(group_code,'<none>') FROM gateway_group_overrides WHERE user_id=90541")
[ "$aB54" = "200" ] && [ "$nB54" = "1" ] && [ "$cB54" = "default" ] \
  && pass "块B 合法写入没被挡：NORMAL 会员 90541 → ${aB54}，库里 ${nB54} 行 group_code=${cB54}（校验不是无条件拒绝）" \
  || fail "块B 把合法写入也挡了（校验过宽）: create=${aB54}(期望200) 行数=${nB54}(期望1) group_code=${cB54}(期望default) body=$(head -c 160 "$GB" 2>/dev/null)"

# ── 块 C：注销会员（status=DELETED 但 deleted=0）→ 400 ──
mbr54c=$(q "SELECT COUNT(*) FROM member_users WHERE id=90542 AND deleted=0")
st54c=$(q "SELECT status FROM member_users WHERE id=90542")
aC54=$(ov54 90542); mC54=$(jm54); nC54=$(row54 90542)
[ "$mbr54c" = "1" ] && [ "$st54c" = "2" ] && [ "$aC54" = "400" ] && [ "$nC54" = "0" ] \
  && pass "块C 注销会员挂不上例外：member_users(90542) 确实**查得到**（deleted=0 的行 ${mbr54c} 条）而 status=${st54c}(DELETED) —— 只判存在性的实现会放行它；实际 ${aC54} 且零副作用(${nC54})" \
  || fail "块C 注销会员被放行了: 库里查得到=${mbr54c}(期望1，0 说明 INSERT 没成、本块在测空气) status=${st54c}(期望2=DELETED) create=${aC54}(期望400，200 意味着判据写成了 MemberTable.get()!=null) 行数=${nC54}(期望0) message='${mC54:0:120}'"

# ── 块 D：DISABLED 会员 → 400（判据是白名单，不是 status != DELETED）──
st54d=$(q "SELECT status FROM member_users WHERE id=90543")
aD54=$(ov54 90543); nD54=$(row54 90543)
[ "$st54d" = "0" ] && [ "$aD54" = "400" ] && [ "$nD54" = "0" ] \
  && pass "块D 禁用会员也挂不上：status=${st54d}(DISABLED) → ${aD54}、零副作用(${nD54})。判据是 status==NORMAL 白名单，与 member 的登录/刷新同一套，不自创第二套账号可用性规则" \
  || fail "块D 禁用会员被放行了: status=${st54d}(期望0=DISABLED) create=${aD54}(期望400，200 意味着判据写成了 status!=DELETED 这类否定式) 行数=${nD54}(期望0)"

# ── 块 E：注销会员的**既有**例外仍可 delete（拦写入、不拦清理）──
# 手工插一行模拟真实时序：例外是会员还正常时建的，人后来注销了。这一行现在指向一个不再
# 可用的会员，运营要的正是删掉它 —— 所以 delete 不能按当前 status 拦。
q "INSERT INTO gateway_group_overrides (user_id,group_code,remark) VALUES (90542,'default','S54 注销前建的')" >/dev/null
pre54e=$(row54 90542)
aE54=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X DELETE "$U/admin/gateway/group-override/delete/90542" -H "Authorization: Bearer $GJWT")
post54e=$(row54 90542)
[ "$pre54e" = "1" ] && [ "$aE54" = "200" ] && [ "$post54e" = "0" ] \
  && pass "块E 清理不受拦：注销会员 90542 的既有例外（手插 ${pre54e} 行）→ delete ${aE54}、行已消失(${post54e})。校验只挂 create，否则这条例外会永久留在表里指向一个不再存在的客户" \
  || fail "块E delete 被 status 拦了（校验挂错了端点）: 手插后行数=${pre54e}(期望1) delete=${aE54}(期望200，400 意味着 requireChargeableMember 也加到了 delete 上) 删后行数=${post54e}(期望0)"

# ════════════════════════════════════════════════════════════════════
# S55 计费归因：每笔钱都得说得出「走的是哪个组、这个组是哪一层给的」
#
# 修的是两处**静默白传**。BillingGroupResolver 早就算出了 GroupSource —— 它的 KDoc 第一句就是
# 「进日志：错账排查第一个要问的就是来源」，而 RelayEngine 解析那一步写的是 `-> r.group`，
# source 当场被扔掉。group code 的遭遇更奇怪：它被一路传过 execute / streamWithPreflight / bill /
# recordLog 四层签名，最后 recordLog 构造 UsageLog 时也没用它 —— 表里根本没有那两列。Kotlin 不
# 对未使用的**函数参数**报警告（只报未使用的局部变量），所以这两处一次也没响过。
# 后果：pricing_snapshot 逐笔冻结了 ratio，「按什么倍率收了多少」查得出；但倍率相同的四层含义
# 完全不同（令牌口子 / 大客户谈判价 / 会员套餐 / 标准价），「为什么是这个倍率」答不上来。bill 里
# 那条毛利倒挂告警是活例 —— 它打了 ratio 与 costDiscount 却没打组，运营看到「ratio=3.0 倒挂」时
# 无法判断是谈判价配错了还是标准价本身配错了。撤销用户例外时这个缺口最疼：那张表是硬删。
#
# 四块各钉一件事，少一块就有一种「看着对」的实现能溜过去：
#   A 无例外无覆盖 → DEFAULT，charged 作后两块的基准
#   B 配用户例外 → USER_OVERRIDE，**且 charged 恰好翻倍**：把归因与金额绑成同一件事的两面，
#     硬编码一个假 source 骗得过字符串断言，骗不过「金额也跟着变了」
#   C 令牌覆盖与用户例外并存且指向不同的组 → TOKEN_OVERRIDE 胜出。没有这一块，「source 是随手
#     取了第一层」与「source 真跟着优先级走」分不出来
#   D 上游 403 → 失败请求那行也带归因。成功行由 finalize 落、失败行由 recordLog 落，进的是同一
#     张表；失败行缺归因，这张表就只能按组统计成功量，「某个组是不是在集中撞某个上游」问不出来
# 两块表都断言（usage_logs 与 settlements）：finalize 的日志维度全部取自结算行，worker 重放时
# 可能已是另一个进程，所以归因必须先固化在 settlements 上 —— 只断言 usage_logs 会漏掉「重放丢归因」。
# 不覆盖 MEMBER_GROUP 那层：它要 NEWGATE_MEMBER_GROUP_BILLING 开关加会员组映射（其解析行为 S26
# 已覆盖），而本场景要证的是「source 落库了、且跟着优先级走」，三层足够。
# ════════════════════════════════════════════════════════════════════
echo "[S55] 计费归因落库：DEFAULT / USER_OVERRIDE / TOKEN_OVERRIDE 三层 + 失败请求也带归因"
# seed_reset 会 TRUNCATE usage_logs 与 settlements，所以本场景里「最新一行」是干净的。
# 端口避开 S4 的 9950(err403)/9940(err429) 与 S48 的 9948：那些 fake 进程整轮都活着。
seed_reset; fake ok 9955; sleep 1
q "INSERT INTO gateway_channels (name,type,base_url,groups,models,priority,weight,status,ttfb_timeout_ms,idle_timeout_ms,cost_discount,deleted,created_at,updated_at) VALUES ('c55','openai_compatible','http://127.0.0.1:9955','default,vip55','m-grp',1,1,1,30000,90000,'1.0',0,0,0);
   INSERT INTO gateway_channel_keys (channel_id,api_key,status,fail_count,deleted,created_at,updated_at) VALUES ((SELECT id FROM gateway_channels WHERE name='c55'),'k',1,0,0,0,0);
   INSERT INTO gateway_model_prices (model,input_price,output_price,cache_read_price,cache_write_price,default_max_output_tokens,source,deleted,created_at,updated_at) VALUES ('m-grp','2.5','10','0','0',5000,'manual',0,0,0);
   UPDATE gateway_groups SET deleted=0, ratio='1.0' WHERE code='default';
   DELETE FROM gateway_group_overrides WHERE user_id=1;
   UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH';" >/dev/null
g55=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"code":"vip55","name":"归因两倍","ratio":"2.0"}')
# 归因读取。'<null>' 而不是空串：空串与「列不存在/查不出」在 shell 里分不开，而 NULL 是本场景
# 要能识别的一种真实状态（V007 之前的旧行就是 NULL）。
attr55() { q "SELECT COALESCE(group_code,'<null>')||'/'||COALESCE(group_source,'<null>') FROM gateway_usage_logs ORDER BY id DESC LIMIT 1"; }
sattr55() { q "SELECT COALESCE(group_code,'<null>')||'/'||COALESCE(group_source,'<null>') FROM gateway_settlements ORDER BY id DESC LIMIT 1"; }
chg55() { q "SELECT charged FROM gateway_usage_logs ORDER BY id DESC LIMIT 1"; }

# ── 块 A：兜底层也要有归因 ──
rA55=$(relay26); sleep 1
atA55=$(attr55); satA55=$(sattr55); chA55=$(chg55)
[ "$g55" = "200" ] && [ "$rA55" = "200" ] && [ "$atA55" = "default/DEFAULT" ] && [ "$satA55" = "default/DEFAULT" ] \
  && [ -n "$chA55" ] && [ "$chA55" -gt 0 ] 2>/dev/null \
  && pass "块A 兜底层有归因：建 vip55(ratio 2.0)=${g55} → relay=${rA55}；usage_logs 最新行 group/source=${atA55}、settlements 最新行=${satA55}（两张表都落了），charged=${chA55}（default ratio 1.0，作块B 的基准）" \
  || fail "块A 归因没落库: 建组=${g55}(期望200) relay=${rA55}(期望200) usage_logs='${atA55}'(期望 default/DEFAULT；'<null>/<null>' 说明 V007 的列没被写进去、空串说明查询本身没出行) settlements='${satA55}'(期望同) charged=${chA55}(期望>0)"

# ── 块 B：谈判价那一层，且金额跟着变 ──
crB55=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U/admin/gateway/group-override/create" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"userId":1,"groupCode":"vip55","remark":"S55 归因"}')
rB55=$(relay26); sleep 1
atB55=$(attr55); satB55=$(sattr55); chB55=$(chg55)
[ "$crB55" = "200" ] && [ "$rB55" = "200" ] && [ "$atB55" = "vip55/USER_OVERRIDE" ] && [ "$satB55" = "vip55/USER_OVERRIDE" ] \
  && [ "$chB55" = "$((chA55*2))" ] \
  && pass "块B 谈判价那一层有归因、且金额跟着变：配例外=${crB55} → relay=${rB55}；group/source=${atB55}（结算行 ${satB55}），charged ${chA55}→${chB55} 恰好两倍（vip55 ratio 2.0）。归因与计价是同一件事的两面：写死一个假 source 能过字符串断言，过不了这条" \
  || fail "块B 归因或金额不对: 配例外=${crB55}(期望200；400 说明 userId=1 不是活会员，那是 S54 那件事) relay=${rB55}(期望200) usage_logs='${atB55}'(期望 vip55/USER_OVERRIDE) settlements='${satB55}'(期望同) charged=${chB55}(期望$(( ${chA55:-0} * 2 ))，基准 ${chA55})"

# ── 块 C：令牌覆盖压过用户例外，归因与金额都取自第一层 ──
# 用户例外留在 vip55(2.0)，令牌覆盖指向 default(1.0)。若来源报 TOKEN_OVERRIDE 而金额回到块A 的
# 水平，就同时证明了「记的是第一层」与「计价也真按第一层」—— 只断言字符串的话，一个把 source
# 写死成 TOKEN_OVERRIDE 的实现同样能过。
q "UPDATE gateway_tokens SET group_override='default' WHERE key_hash='$TOKEN_HASH'" >/dev/null
rC55=$(relay26); sleep 1
atC55=$(attr55); satC55=$(sattr55); chC55=$(chg55)
[ "$rC55" = "200" ] && [ "$atC55" = "default/TOKEN_OVERRIDE" ] && [ "$satC55" = "default/TOKEN_OVERRIDE" ] \
  && [ "$chC55" = "$chA55" ] \
  && pass "块C 归因跟着优先级走：令牌覆盖 default 压过用户例外 vip55 → relay=${rC55}；group/source=${atC55}（结算行 ${satC55}），charged=${chC55} 回到块A 水平而不是 vip55 的 ${chB55} —— 来源与金额取自同一层" \
  || fail "块C 优先级归因不对: relay=${rC55}(期望200) usage_logs='${atC55}'(期望 default/TOKEN_OVERRIDE；若是 vip55/USER_OVERRIDE 则令牌覆盖这一层没被记进来源) settlements='${satC55}'(期望同) charged=${chC55}(期望=${chA55}，即按 default 计而非 vip55)"
q "UPDATE gateway_tokens SET group_override=NULL WHERE key_hash='$TOKEN_HASH';
   DELETE FROM gateway_group_overrides WHERE user_id=1;" >/dev/null

# ── 块 D：上游 403 的失败请求也带归因（recordLog 那半边）──
# 换端口而不是改 fake 模式：既有惯例就是不同端口跑不同模式（见 S4），且 listEnabled() 每次查库、
# 无缓存，所以 UPDATE base_url 立即生效。一发 403 不会禁用 Key —— S4 证明要连续 5 发。
fake err403 9956; sleep 1
q "UPDATE gateway_channels SET base_url='http://127.0.0.1:9956' WHERE name='c55';
   INSERT INTO gateway_group_overrides (user_id,group_code,remark) VALUES (1,'vip55','S55 失败路径归因');" >/dev/null
rD55=$(relay26); sleep 1
# 按 status='error' 取行，不取「最新一行」：worker 可能在 TTL 后把结算行 finalize 掉、
# 于是最新那行变成成功行，断言就会指着错的那半边。
atD55=$(q "SELECT COALESCE(group_code,'<null>')||'/'||COALESCE(group_source,'<null>')||'/'||status FROM gateway_usage_logs WHERE status='error' ORDER BY id DESC LIMIT 1")
[ "$rD55" = "403" ] && [ "$atD55" = "vip55/USER_OVERRIDE/error" ] \
  && pass "块D 失败请求也有归因：上游 403 → relay=${rD55}；usage_logs 里 status=error 那行 group/source=${atD55}（recordLog 路径 —— 此前它的 group 参数从 V001 起就白传，这一行连组都没有）" \
  || fail "块D 失败路径缺归因: relay=${rD55}(期望403；200 说明 err403 的 fake 没起来或 base_url 没改到、这一发其实成功了) error 行='${atD55}'(期望 vip55/USER_OVERRIDE/error；'<null>/<null>/error' 说明 recordLog 仍没写归因、只修了 finalize 那半边；空串说明这一发根本没写 error 行)"

# ════════════════════════════════════════════════════════════════════
# S56 支付回调地址：发出去的 notify_url 必须是一条**活路由**
#
# 修的是「装配层从不 bind PayPlatformRegistry」：PaymentRuntimeBootstrap 用 getOrNull 取不到就静默
# 回落到 default(http)，两个回调地址 hook 全是空串，于是下单时既不发 notify_url 也不发 return_url。
# 账面上一切正常 —— 下单 200、钱也能到账（定时任务 pay-order-reconcile 十来分钟一轮查单兜底），所以这条缺陷
# 在本机永远测不出来：本机没有公网地址，回调本来就打不进来。也正因如此，本场景不试图证明「渠道能
# 打回来」，只证两件事：地址**发出去了**、以及发出去的那条路径在本进程里**真是一条注册过的路由**。
#
# 五块各钉一件事：
#   A 配了基址 → payload 里的 notify_url 是逐字的绝对地址（断相等，不是断「包含」），return_url 同理，
#     且 biz_content 里带 quit_url（支付宝用它让用户从收银台跳回）；启动日志 INFO 念出生效值
#   B 把 A 里真发出去的 notify_url 剥掉基址、打回本机 → 200；同一路径多挂一段 → 404 作对照。
#     这一块与单测各证一半：单测钉得住字面量，钉不住「路由真注册了」；反过来改常量时两处一起改，
#     这一块仍绿（钉字面量的是 PayNotifyRouteTest）
#   C 没配 → 两个参数都不出现，但 payload 仍是那条真 alipay 跳转地址、下单仍 200：留空是退化不是失败。
#     额外钉日志文案：两行各说各的后果（return_url 没配与「渠道会不会回调」无关，共用一句就是说谎），
#     且提到的名字是后台任务页上真能搜到的 job id 而不是类名
#   D 写错（漏 scheme）→ 按未配置处理并记 ERROR，**且只影响那一个变量**（return_url 照常发）。
#     这一块最要紧：静默接受一个不带 scheme 的地址，渠道会判成非法参数，那是连单都下不了
#   E 两条到账路径同时断（基址没生效 + 对账任务在后台被停用）→ ERROR；而只要还剩一条路就不该报。
#     这是 C 那行 WARN 的下游：它承诺了「靠对账任务兜底」，而那个任务能被停用（infra_jobs 是运行期
#     调度真源）。承诺不成立时不响的话，后果是钱到账了额度永远不发，而两边（用户、运维）都看不到原因
# 不覆盖沙箱渠道：SandboxPayPlatform 的 payload 是站内相对地址（模拟收银台），它本就不该带公网回调。
# 基址用 .test 保留域（RFC 2606）：本场景从不真去连它（alipay 的 WAP 下单是页面接口，不发请求），
# 但万一哪天有人拿这个 payload 去 curl，也不会打到一个真实第三方身上。
# ════════════════════════════════════════════════════════════════════
echo "[S56] 支付回调地址：下单 payload 带 notify_url/return_url、那条地址真打得回来，且两条到账路径全断时必须响"
# 下单响应里取字段（同 S53 的 jf53，只是缺失时回显空串而不是 'null'，好与「参数没发出去」对齐）。
jf56() { python3 -c "import json;v=(json.load(open('$GB')).get('data') or {}).get('$1');print('' if v is None else v)" 2>/dev/null; }
# 从 payload 的 query 里取某个参数的**解码后**值，没有就回显空串。
# 用 Python 而不是 sed/IFS：值里有 %3A%2F 这类转义，而 biz_content 自己是一串编码过的 JSON，
# 手写切分迟早在这儿出错 —— 切错了的表现是「参数不存在」，正好与本场景要断言的东西同形。
pq56() { python3 -c '
import sys, urllib.parse
p = sys.argv[1]; k = sys.argv[2] + "="
q = p.split("?", 1)[1] if "?" in p else ""
print(next((urllib.parse.unquote(x[len(k):]) for x in q.split("&") if x.startswith(k)), ""))
' "$1" "$2" 2>/dev/null; }
# 启动日志里那行「回调地址配没配」。all.log 跨重启累积，故取最后一条 = 当前这次 boot 的配置
# （与 S42 取 invite reward attached 同一个做法）。按 env 名过滤：两行共用同一个 logger 名。
lg56() { grep "payment.callback-url" "$WORK/logs/all.log" 2>/dev/null | grep "$1" | tail -1; }
# 级别取字段而不是 grep 整行（同 S33 的 loglvl）：整行 grep 的话，消息里出现「INFO」也会算命中。
lvl56() { printf '%s' "$1" | grep -oE " (ERROR|WARN|INFO) " | head -1 | tr -d ' '; }
# 密钥取自 module-payment 的测试 fixture，不在 harness 里抄第二份：抄一份的话日后 fixture 换密钥，
# 这里会静默过期，表现同样是下单 500「签名失败」，但原因在 harness 自己。那份 fixture 由 13 条单测
# 盯着，不会悄悄消失；真取不到就整段跳过并喊一声 —— 静默跳过等于这五块覆盖不存在。
KEYS56="$ROOT/../Neton/neton-application-module-payment/src/commonTest/kotlin/channel/AlipayTestKeys.kt"
rk56() { python3 -c '
import sys
Q = chr(34)
for line in open(sys.argv[1]):
    if line.strip().startswith("const val " + sys.argv[2]):
        print(line.split(Q)[1]); break
else:
    print("")
' "$KEYS56" "$1" 2>/dev/null; }
PRIV56=$(rk56 PRIVATE_KEY); PUB56=$(rk56 PUBLIC_KEY)
if [ -z "$PRIV56" ] || [ -z "$PUB56" ]; then
  echo "  ⚠️  取不到 alipay 测试密钥（$KEYS56 不在？priv=${#PRIV56}B pub=${#PUB56}B）：S56 四块整段跳过" >&2
else
BASE56="https://pay.nanogate.test"; RET56="https://console.nanogate.test/billing"
# config 用 json.dumps 组装：私钥是 1.6KB base64，手拼进 SQL 迟早漏一个转义。
CFG56=$(python3 -c '
import json, sys
print(json.dumps({"appId": "2021000000000056", "privateKey": sys.argv[1], "alipayPublicKey": sys.argv[2]}))
' "$PRIV56" "$PUB56")
# 真平台与模拟支付互斥（PaymentSettingKeys.MOCK_PAY_ENABLED：打开模拟支付会禁用全部真实渠道），
# 所以跑真 alipay 必须把它关掉。currentValue() 每次查表、无缓存 → 改完立即生效，末尾还原成 'true'。
# 副作用可控：S56 是最后一段，而关着它只会让 sandbox_* 一律「不可用的支付通道」，对账任务也因同一个
# 判据不会去查前面场景留下的沙箱单 —— 全程不发一个外网请求（WAP 下单本身就是页面接口）。
stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000 NEWGATE_PAY_NOTIFY_BASE="$BASE56" NEWGATE_PAY_RETURN_URL="$RET56"
GJWT=$(admin_jwt)
q "INSERT INTO system_settings (category,setting_key,value,name,created_at,updated_at)
     VALUES ('payment','payment.mock.enabled','false','模拟支付模式',0,0)
     ON CONFLICT (setting_key) DO UPDATE SET value='false';
   DELETE FROM pay_channels WHERE code='alipay56';
   INSERT INTO pay_channels (code,platform_code,method,platform_channel_id,display_mode,config,status,remark)
     VALUES ('alipay56','alipay','ALIPAY','WAP','REDIRECT_URL','$CFG56',1,'S56 回调地址');" >/dev/null
rc56=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"alipay56"}')
pl56=$(jf56 payload)
nu56=$(pq56 "$pl56" notify_url); ru56=$(pq56 "$pl56" return_url); bc56=$(pq56 "$pl56" biz_content)
ENU56="$BASE56/app/pay/channel-notify/alipay56"
qa56=no; printf '%s' "$bc56" | grep -q "\"quit_url\":\"$RET56\"" && qa56=yes
la56=$(lg56 NEWGATE_PAY_NOTIFY_BASE); la56l=$(lvl56 "$la56")

# ── 块 A：配了基址 → 两个地址逐字进 payload ──
[ "$rc56" = "200" ] && [ "$nu56" = "$ENU56" ] && [ "$ru56" = "$RET56" ] && [ "$qa56" = "yes" ] && [ "$la56l" = "INFO" ] \
  && pass "块A 回调地址真发出去了：下单=${rc56} → notify_url=${nu56}、return_url=${ru56}（都是逐字相等，不是「包含」），biz_content 里 quit_url=${qa56}（支付宝用它让用户从收银台跳回）；启动日志 ${la56l} 念出生效基址" \
  || fail "块A 回调地址没进 payload: 下单=${rc56}(期望200；400「不可用的支付通道」= 模拟支付没关掉或 alipay56 没插进去，500 = 密钥/config 有问题) notify_url='${nu56}'(期望 '${ENU56}'；空串说明 hook 没被 bind、或基址被判非法) return_url='${ru56}'(期望 '${RET56}') quit_url=${qa56}(期望yes) 启动日志级别='${la56l}'(期望INFO，行内容 '${la56:0:140}')"

# ── 块 B：发出去的那条地址，剥掉基址后在本进程里真是一条注册过的路由 ──
# 用 Python 剥前缀而不是 ${nu56#$BASE56}：前缀不匹配时后者会**原样返回整条 URL**，
# 于是下面那一发会打到一个奇怪的绝对地址上，失败信息指向错误的原因。
pb56=$(python3 -c '
import sys
print(sys.argv[1][len(sys.argv[2]):] if sys.argv[1].startswith(sys.argv[2]) else "")
' "$nu56" "$BASE56")
hb56=$(curl -s --max-time 10 -o "$GB" -w "%{http_code}" -X POST "$U$pb56" -H "$CT" -d '{}')
ab56=$(head -c 40 "$GB" 2>/dev/null)
# 对照：同一条路径多挂一段 → 404。没有这一发，「不是 404」可能只是某个兜底路由给的假绿
# （S28 那次正是这个形状：结果码不变、理由全错）。
hc56=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$U$pb56/nope" -H "$CT" -d '{}')
[ -n "$pb56" ] && [ "$hb56" = "200" ] && [ "$hc56" = "404" ] \
  && pass "块B 那条地址是活路由：把 A 里发出去的 notify_url 剥掉基址得 ${pb56} → 打回本机 ${hb56}、回执 '${ab56}'（验签不过，符合预期：本发只证路由存在）；对照 ${pb56}/nope → ${hc56}，所以那个 ${hb56} 是真匹配上的，不是兜底路由" \
  || fail "块B 发出去的地址打不回来: 剥基址后的路径='${pb56}'(期望 /app/pay/channel-notify/alipay56；空串说明块A 的 notify_url 不以配置的基址开头) 打回本机=${hb56}(期望200；404 说明注册的路由与发出去的地址各说各话 —— 那正是本条缺陷) 对照多挂一段=${hc56}(期望404；非404 说明有兜底路由在应答，那么「打回本机不是 404」就不证明任何事) 回执='${ab56}'"

# ── 块 C：没配 → 两个参数都不出现，但下单照样成功（留空是退化，不是失败）──
stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000
GJWT=$(admin_jwt)
rcC56=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"alipay56"}')
plC56=$(jf56 payload)
# 两面都断言：既要「没有回调参数」，也要「payload 仍是那条真 alipay 跳转地址」。
# 只断言前者的话，一个把整个 prepay 弄挂的实现（payload 空）同样能过 —— 与块A 的正反配对同一个道理。
ali56=no; printf '%s' "$plC56" | grep -q "openapi.alipay.com" && ali56=yes
nnC56=no; printf '%s' "$plC56" | grep -q "notify_url=" && nnC56=yes
nrC56=no; printf '%s' "$plC56" | grep -q "return_url=" && nrC56=yes
lcC56=$(lg56 NEWGATE_PAY_NOTIFY_BASE); lcC56l=$(lvl56 "$lcC56")
lrC56=$(lg56 NEWGATE_PAY_RETURN_URL); lrC56l=$(lvl56 "$lrC56")
# 两行各说各的后果：return_url 没配与「渠道会不会回调」无关。共用一句文案的话其中一行会说谎，
# 而运维读到那行会去查一条没坏的路 —— 所以两行都要断：说了自己的、没借对方的。
own56=no; printf '%s' "$lcC56" | grep -q "pay-order-reconcile" && own56=yes
# 日志里那个名字必须是后台任务页上真能搜到的那一个（handler 列 = @Job.id）。
# 写类名 PayOrderReconcileJob 的话运维搜不到 —— 所以这里反向钉一条：不许出现类名。
cls56=no; printf '%s' "$lcC56" | grep -q "PayOrderReconcileJob" && cls56=yes
back56=no; printf '%s' "$lrC56" | grep -q "回不来" && back56=yes
lie56=no; printf '%s' "$lrC56" | grep -q "pay-order-reconcile" && lie56=yes
[ "$rcC56" = "200" ] && [ "$ali56" = "yes" ] && [ "$nnC56" = "no" ] && [ "$nrC56" = "no" ] \
  && [ "$lcC56l" = "WARN" ] && [ "$lrC56l" = "WARN" ] && [ "$own56" = "yes" ] && [ "$cls56" = "no" ] \
  && [ "$back56" = "yes" ] && [ "$lie56" = "no" ] \
  && pass "块C 没配就退化、不失败：不传两个 env 重启 → 下单=${rcC56}、payload 仍是真 alipay 跳转地址(${ali56})，但 notify_url 出现=${nnC56}、return_url 出现=${nrC56}（都不发，退化成靠对账任务查单兜底）；两行日志都是 ${lcC56l}/${lrC56l} 且各说各的后果（notify 行提 job id pay-order-reconcile=${own56}、没写成类名=${cls56}、return 行提回不来=${back56}、return 行没借对账任务=${lie56}）" \
  || fail "块C 未配置时的行为不对: 下单=${rcC56}(期望200，留空不该让下单失败) payload 仍是 alipay 跳转地址=${ali56}(期望yes；no 说明 prepay 本身挂了，那么「没有 notify_url」是假象) notify_url 出现=${nnC56}(期望no) return_url 出现=${nrC56}(期望no) 两行级别='${lcC56l}'/'${lrC56l}'(期望WARN/WARN；空说明这行日志压根没写，运营就无从知道回调没配) notify行提 job id=${own56}(期望yes) notify行写成了类名=${cls56}(期望no；yes 说明日志点了个后台任务页上搜不到的名字 —— 那一列是 @Job.id) return行提回不来=${back56}(期望yes) return行借了对账任务=${lie56}(期望no；yes 说明两行又共用了同一句文案 —— return_url 没配并不影响渠道回调，那句话会把人送去查一条没坏的路) notify行='${lcC56:0:170}' return行='${lrC56:0:170}'"

# ── 块 D：写错（漏 scheme）→ 按未配置处理 + ERROR，且只影响那一个变量 ──
BAD56="pay.nanogate.test"
stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000 NEWGATE_PAY_NOTIFY_BASE="$BAD56" NEWGATE_PAY_RETURN_URL="$RET56"
GJWT=$(admin_jwt)
rcD56=$(curl -s --max-time 15 -o "$GB" -w "%{http_code}" -X POST "$U/app/gateway/recharge" \
  -H "Authorization: Bearer $GJWT" -H "$CT" -d '{"price":100,"channelCode":"alipay56"}')
plD56=$(jf56 payload)
ndD56=no; printf '%s' "$plD56" | grep -q "notify_url=" && ndD56=yes
rdD56=no; printf '%s' "$plD56" | grep -q "return_url=" && rdD56=yes
ldD56=$(lg56 NEWGATE_PAY_NOTIFY_BASE); ldD56l=$(lvl56 "$ldD56")
lrD56=$(lg56 NEWGATE_PAY_RETURN_URL); lrD56l=$(lvl56 "$lrD56")
[ "$rcD56" = "200" ] && [ "$ndD56" = "no" ] && [ "$rdD56" = "yes" ] && [ "$ldD56l" = "ERROR" ] && [ "$lrD56l" = "INFO" ] \
  && printf '%s' "$ldD56" | grep -q "$BAD56" \
  && pass "块D 写错不静默、也不连累另一半：notify 基址漏 scheme('${BAD56}') → 启动日志 ${ldD56l} 且点名了原值，payload 里 notify_url 出现=${ndD56}（按未配置处理，不把非法地址发给渠道）；return_url 出现=${rdD56}、它那行仍是 ${lrD56l} —— 两个变量各判各的；下单=${rcD56}（没被拖累）" \
  || fail "块D 非法配置的处置不对: 下单=${rcD56}(期望200；400/500 说明非法地址被原样发给了渠道，那是连单都下不了) notify_url 出现=${ndD56}(期望no) return_url 出现=${rdD56}(期望yes，一个变量写错不该连累另一个) notify 行级别='${ldD56l}'(期望ERROR；WARN 说明非法值被当成「没配」，两者后果不同) return 行级别='${lrD56l}'(期望INFO) notify 行点名原值=$(printf '%s' "$ldD56" | grep -c "$BAD56")(期望1) 行内容 '${ldD56:0:160}'"

# ── 块 E：两条到账路径同时断 → 必须响，而且不能无条件响 ──
# notify 没生效时到账只剩对账任务这一条路，而 infra_jobs 是运行期调度真源 —— 那个任务能被停用
# （DDL 里 status 默认还是 0）。两条同时断 = 真实支付的钱到账了、额度永远不发，
# 而块C 那行 WARN 恰恰承诺了「靠对账任务兜底」。承诺不成立时必须响，所以这里要看到 ERROR。
# E2/E3 两个对照同样要紧：配了基址、或任务还开着，就还剩一条路，此时不该再报「两条都断」。
# 没有对照，一个无条件打 ERROR 的实现也能过 E1 —— 与块A/块C 的正反配对同一个道理。
#
# all.log 是 O_APPEND（neton-logging 的 FileSinkNative 用 O_WRONLY|O_CREAT|O_APPEND 打开），
# 所以「这次启动新增了什么」必须按行号切片：直接 grep 整个文件会把 E1 那行 ERROR 算进 E2/E3 的
# 对照里，对照于是假红；而切片方向写错（比如忘了 +1）会连旧行一起当成新增，那就是假绿。
JOB56="pay-order-reconcile"
nj56=$(q "SELECT count(*) FROM infra_jobs WHERE handler_name='$JOB56';" 2>/dev/null | tail -1 | tr -d ' ')
if [ "$nj56" != "1" ]; then
  echo "  ⚠️  infra_jobs 里 '$JOB56' 不是恰好一行（count='${nj56}'）：块E 整段跳过" >&2
else
  ln56() { wc -l < "$WORK/logs/all.log" 2>/dev/null | tr -d ' '; }
  new56() { tail -n +$((${1:-0} + 1)) "$WORK/logs/all.log" 2>/dev/null | grep "payment.callback-url"; }

  # E1：停用对账任务 + 不配基址 → 两条都断，ERROR 点名是哪两条
  q "UPDATE infra_jobs SET status=0 WHERE handler_name='$JOB56';" >/dev/null
  n1e56=$(ln56); stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000
  e1e56=$(new56 "$n1e56" | grep "两条到账路径" | tail -1)
  e1l56=$(lvl56 "$e1e56")
  # 同一次启动还该有那行 WARN（未配置本身仍然要说）—— ERROR 是**加**上去的，不是替换掉它
  w1e56=$(new56 "$n1e56" | grep NEWGATE_PAY_NOTIFY_BASE | grep -v "两条到账路径" | tail -1)
  w1l56=$(lvl56 "$w1e56")

  # E2 对照：任务仍停用，但配上基址 → 渠道能回调，还剩一条路
  n2e56=$(ln56); stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000 NEWGATE_PAY_NOTIFY_BASE="$BASE56"
  e2e56=$(new56 "$n2e56" | grep -c "两条到账路径")
  i2e56=$(lvl56 "$(new56 "$n2e56" | grep NEWGATE_PAY_NOTIFY_BASE | tail -1)")

  # E3 对照：任务恢复启用 + 不配基址 → 就是块C 那个形状，只该有 WARN
  q "UPDATE infra_jobs SET status=1 WHERE handler_name='$JOB56';" >/dev/null
  n3e56=$(ln56); stop_app; boot_app NEWGATE_QUOTA_PER_PRICE_UNIT=1000
  e3e56=$(new56 "$n3e56" | grep -c "两条到账路径")
  w3l56=$(lvl56 "$(new56 "$n3e56" | grep NEWGATE_PAY_NOTIFY_BASE | tail -1)")

  [ "$e1l56" = "ERROR" ] && [ "$w1l56" = "WARN" ] && [ "$e2e56" = "0" ] && [ "$i2e56" = "INFO" ] \
    && [ "$e3e56" = "0" ] && [ "$w3l56" = "WARN" ] && printf '%s' "$e1e56" | grep -q "$JOB56" \
    && pass "块E 两条到账路径同时断就响、且只在那时响：停用 $JOB56 + 不配基址 → 新增 ${e1l56} 行点名两条都断（且含 job id=$(printf '%s' "$e1e56" | grep -c "$JOB56")），那行 WARN 也仍在(${w1l56})；对照①任务仍停用但配了基址 → 新增那类 ERROR=${e2e56} 条、基址行是 ${i2e56}；对照②任务启用且不配基址 → 新增那类 ERROR=${e3e56} 条、基址行是 ${w3l56}" \
    || fail "块E 组合检查不对: E1(停用+没配) ERROR 行级别='${e1l56}'(期望ERROR；空说明这个「钱到账了额度永远不发」的组合压根没人说 —— 用户只会投诉付了钱没额度) E1 同次启动的 WARN 行级别='${w1l56}'(期望WARN；ERROR 该是加上去的，不是把未配置那行替换掉) E1 行点名 job id=$(printf '%s' "$e1e56" | grep -c "$JOB56")(期望≥1；后台任务页那一列是 @Job.id，写类名就搜不到) E2(停用+配了基址) 新增该类 ERROR=${e2e56}(期望0；非0 说明它是无条件报的，那么这行 ERROR 不携带任何信息) E2 基址行级别='${i2e56}'(期望INFO) E3(启用+没配) 新增该类 ERROR=${e3e56}(期望0) E3 基址行级别='${w3l56}'(期望WARN) E1 行内容='${e1e56:0:200}'"
fi

# 还原：本场景是最后一段，但库要等到 cleanup 才 drop，而「悄悄关着的模拟支付」会让任何后来追加的
# 沙箱场景一律拿到「不可用的支付通道」—— 那条错误信息与「渠道被关了」完全一样，排查会走错方向。
q "UPDATE system_settings SET value='true' WHERE setting_key='payment.mock.enabled';
   DELETE FROM pay_channels WHERE code='alipay56';" >/dev/null
fi

# ══ S57 健康端点：匿名可读，DB 可达即 200（容器 HEALTHCHECK / compose depends_on / 反代健康检查都靠它）══
echo "[S57] /health"
hc=$(curl -s --max-time 5 -o /tmp/nanogate-health.json -w "%{http_code}" "$U/health"); hb=$(cat /tmp/nanogate-health.json 2>/dev/null)
[ "$hc" = "200" ] && echo "$hb" | grep -q '"status":"ok"' \
  && pass "/health 匿名 200 且 status=ok" \
  || fail "/health 错: HTTP=${hc} body=${hb}"

echo "═══ 结果：$PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ] || { echo "详细日志见 $LOGS/"; exit 1; }
