#!/usr/bin/env bash
# NetonAPI 最小告警：systemd 定时器每分钟跑一次，发现问题时向 webhook 发 {"text": "..."}。
#
# 检查项（每项独立去重：变坏时报一次，持续坏每 WATCH_REPEAT_HOURS 小时再提醒，恢复时报一次）：
#   health        GET /health 不是 200（进程挂了或数据库不可达）
#   settlement    有结算进入人工复核（netonapi_settlements_manual_review > 0），这些钱需要人裁定
#   channels      启用中的渠道最近一次测速全部失败（用户此刻的请求基本都会失败）
#   backup        BACKUP_DIR 里最新的备份超过 26 小时（备份定时器停了或一直失败）
#
# 环境变量（/etc/netonapi/watch.env）：
#   NETONAPI_URL          后端地址，默认 http://127.0.0.1:8800
#   NETONAPI_METRICS_TOKEN  设了 NETONAPI_METRICS_TOKEN 时填同一个值
#   WATCH_ALERT_WEBHOOK   告警地址（必填，不填只打印）
#   BACKUP_DIR            可选，填了才检查备份新鲜度（与备份脚本同一目录）
#   WATCH_STATE_DIR       去重状态目录，默认 /var/lib/netonapi-watch
#   WATCH_REPEAT_HOURS    持续异常的重复提醒间隔，默认 6
set -uo pipefail

URL="${NETONAPI_URL:-http://127.0.0.1:8800}"
STATE="${WATCH_STATE_DIR:-/var/lib/netonapi-watch}"
REPEAT=$(( ${WATCH_REPEAT_HOURS:-6} * 3600 ))
mkdir -p "$STATE"
now=$(date +%s)

notify() {
  local text="[NetonAPI $(hostname)] $1"
  echo "$text"
  [ -n "${WATCH_ALERT_WEBHOOK:-}" ] || return 0
  local body
  body=$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps({"text":sys.stdin.read()}))')
  curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$body" "$WATCH_ALERT_WEBHOOK" >/dev/null || echo "webhook failed" >&2
}

# report <检查名> <ok|fail> <说明>
report() {
  local key="$1" status="$2" detail="$3" file="$STATE/$1"
  local last_status="ok" last_sent=0
  [ -f "$file" ] && read -r last_status last_sent < "$file"
  if [ "$status" = "fail" ]; then
    if [ "$last_status" != "fail" ] || [ $(( now - last_sent )) -ge "$REPEAT" ]; then
      notify "⚠️ $key: $detail"; echo "fail $now" > "$file"
    fi
  elif [ "$last_status" = "fail" ]; then
    notify "✅ $key 已恢复"; echo "ok $now" > "$file"
  fi
}

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/health" || true)
if [ "$code" = "200" ]; then report health ok ""; else report health fail "/health 返回 ${code:-无响应}"; fi

auth=(); [ -n "${NETONAPI_METRICS_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $NETONAPI_METRICS_TOKEN")
metrics=$(curl -fsS --max-time 15 ${auth[@]+"${auth[@]}"} "$URL/metrics" 2>/dev/null || true)
if [ -n "$metrics" ]; then
  manual=$(printf '%s\n' "$metrics" | awk '$1=="netonapi_settlements_manual_review"{print $2}')
  if [ "${manual:-0}" -gt 0 ] 2>/dev/null; then report settlement fail "$manual 笔结算待人工复核（管理台「结算待处理」）"; else report settlement ok ""; fi

  # 启用中（status=1）且测过速的渠道，全部 probe_ok=0 才算全挂；一条都没测过时不判
  read -r enabled failing < <(printf '%s\n' "$metrics" | awk '
    /^netonapi_channel_status\{/ { split($1,a,"id=\""); split(a[2],b,"\""); st[b[1]]=$2 }
    /^netonapi_channel_probe_ok\{/ { split($1,a,"id=\""); split(a[2],b,"\""); ok[b[1]]=$2 }
    END { e=0; f=0; for (id in st) if (st[id]==1 && (id in ok)) { e++; if (ok[id]==0) f++ } print e, f }')
  if [ "${enabled:-0}" -gt 0 ] && [ "$failing" = "$enabled" ]; then
    report channels fail "启用中的 $enabled 条渠道最近一次测速全部失败"
  else
    report channels ok ""
  fi
fi

if [ -n "${BACKUP_DIR:-}" ]; then
  newest=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -type f -mmin -1560 2>/dev/null | head -1)
  if [ -n "$newest" ]; then report backup ok ""; else report backup fail "$BACKUP_DIR 里 26 小时内没有新备份"; fi
fi
exit 0
