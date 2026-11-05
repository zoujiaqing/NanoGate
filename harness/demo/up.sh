#!/usr/bin/env bash
# 本地演示环境：独立库 netonapi_demo + 后端 :8810 + 演示上游 :9850 + 管理台 :8888 + 网站 :8880，灌一份演示数据。
# 用于截图与演示；用完 ./down.sh。需要先链接 debug 后端（harness 的 link 步骤，或 ./gradlew :application:linkDebugExecutableMacosArm64）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
APP="$ROOT/netonapi-backend/application/build/bin/macosArm64/debugExecutable/application.kexe"
PGUSER="${PGUSER:-$(whoami)}"; PGPASS="${PGPASS:-privchat}"; PGHOST="${PGHOST:-localhost}"; PGPORT="${PGPORT:-5432}"
DB=netonapi_demo; PORT=8810; UP_PORT=9850
WORK="$HERE/work"; PIDS="$WORK/pids"
[ -x "$APP" ] || { echo "先链接 debug 后端：$APP 不存在"; exit 1; }
"$HERE/down.sh" >/dev/null 2>&1 || true
mkdir -p "$WORK/config" "$WORK/logs"; : > "$PIDS"
dropdb -U "$PGUSER" --if-exists "$DB"; createdb -U "$PGUSER" "$DB"
cp "$ROOT/netonapi-backend/application/config/"*.conf "$WORK/config/"
sed -i.bak "s/^port = .*/port = $PORT/" "$WORK/config/application.conf" && rm -f "$WORK/config/application.conf.bak"
# 自己的 Redis 库与键前缀，并清掉上一轮留下的计数：后端默认连本机 6379，注册限流（每 IP 每小时 10 次）的计数
# 会跨轮次留在里面，反复灌数据就会撞上 429
cat > "$WORK/config/redis.conf" <<CONF
host = "127.0.0.1"
port = 6379
database = 14
keyPrefix = "netonapi-demo"
debug = false
CONF
if command -v redis-cli >/dev/null; then redis-cli -n 14 --scan --pattern 'netonapi-demo*' | xargs redis-cli -n 14 del >/dev/null 2>&1 || true; fi
cat > "$WORK/config/database.conf" <<CONF
[default]
driver = "POSTGRESQL"
uri = "postgresql://$PGUSER:$PGPASS@$PGHOST:$PGPORT/$DB"
debug = false
[migration]
history_table = "neton_schema_history"
CONF
export NETON_EGRESS__ALLOWED_HOSTS="127.0.0.1" NETON_EGRESS__ALLOWED_PORTS="80,443,$UP_PORT"
# 演示专用密钥（每次随机）：样例配置里的占位 JWT 密钥会被启动守卫拒绝
export NETON_SECURITY__JWT__SECRETKEY="demo-$(openssl rand -hex 24)" NETON_MFA_MASTER_KEY="$(openssl rand -base64 32)" PGPASSWORD="$PGPASS"
export NETONAPI_PUBLIC_API_URL="${NETONAPI_PUBLIC_API_URL:-https://api.neton.cloud}"
( cd "$WORK" && "$APP" migrate up > "$WORK/logs/migrate.log" 2>&1 )
( cd "$WORK" && exec "$APP" > "$WORK/logs/app.log" 2>&1 ) & echo $! >> "$PIDS"
PORT=$UP_PORT python3 "$HERE/demo-upstream.py" > "$WORK/logs/upstream.log" 2>&1 & echo $! >> "$PIDS"
for i in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.5; done
BASE="http://127.0.0.1:$PORT" UPSTREAM="http://127.0.0.1:$UP_PORT/v1" PSQL="psql -U $PGUSER -h $PGHOST -d $DB -q -At" /usr/bin/python3 -I "$HERE/seed.py"
( cd "$ROOT/netonapi-frontend" && NETON_BACKEND_URL="http://127.0.0.1:$PORT" NETON_DEV_BACKEND_URL="http://127.0.0.1:$PORT" NEXT_PUBLIC_NETON_BACKEND_URL= exec pnpm --filter @neton/application-front-shell dev > "$WORK/logs/admin.log" 2>&1 ) & echo $! >> "$PIDS"
( cd "$ROOT/netonapi-client" && NETON_BACKEND_URL="http://127.0.0.1:$PORT" exec pnpm --filter @neton/application-client-console dev > "$WORK/logs/web.log" 2>&1 ) & echo $! >> "$PIDS"
for p in 8888 8880; do for i in $(seq 1 120); do curl -s -o /dev/null "http://localhost:$p/" && break; sleep 1; done; done
echo "演示环境就绪：网站 http://localhost:8880（acme_ai / Demo-acme_ai-2026）  管理台 http://localhost:8888（admin / admin123）  后端 :$PORT"
