#!/usr/bin/env bash
# NetonAPI 数据库备份：pg_dump 自定义格式 → 校验 → 落盘 → 清理过期 → （可选）同步异地。
#
# 额度余额、充值流水、令牌都在 PostgreSQL 里；Redis 只放限流计数、验证码与会话吊销这类可丢的状态，不备份。
# 失败时非零退出，并在设置了 BACKUP_ALERT_WEBHOOK 时 POST 一条 {"text": "..."} 告警
# （Slack / 企业微信 / 钉钉自定义机器人都认 text 字段；飞书要用它的「自定义机器人」兼容格式自行改）。
#
# 环境变量（裸机放 /etc/netonapi/backup.env，由 systemd 单元加载）：
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE   连接参数（libpq 标准变量）
#   BACKUP_DIR            备份目录，默认 /data/backups/netonapi
#   BACKUP_KEEP_DAYS      本地保留天数，默认 14
#   BACKUP_RCLONE_REMOTE  可选，rclone 目标（如 cos:netonapi-backup/db），每次备份后同步，同样按保留天数清理
#   BACKUP_ALERT_WEBHOOK  可选，失败告警地址
#   PG_DUMP               可选，替换 pg_dump 命令（docker 部署：docker compose -f /path/docker-compose.yml exec -T postgres pg_dump）
#   PG_RESTORE            可选，同上，用于校验（docker：... exec -T postgres pg_restore）
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/backups/netonapi}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
PG_DUMP="${PG_DUMP:-pg_dump}"
PG_RESTORE="${PG_RESTORE:-pg_restore}"
DB="${PGDATABASE:-netonapi}"

alert() {
  local msg="NetonAPI 数据库备份失败（$(hostname)）：$1"
  echo "$msg" >&2
  if [ -n "${BACKUP_ALERT_WEBHOOK:-}" ]; then
    local body
    body=$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps({"text":sys.stdin.read()}))' 2>/dev/null \
      || printf '{"text":"%s"}' "NetonAPI backup failed on $(hostname)")
    curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$body" "$BACKUP_ALERT_WEBHOOK" >/dev/null || true
  fi
}
tmp=""
trap 'alert "第 ${LINENO} 行出错（退出码 $?）"; [ -n "$tmp" ] && rm -f "$tmp"' ERR

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
final="$BACKUP_DIR/$DB-$stamp.dump"
tmp="$final.partial"

# 先写 .partial，校验通过才改名：中途失败留下的半截文件不会被当成可用备份，也不会顶掉旧备份
umask 077
$PG_DUMP --format=custom --compress=6 --no-owner --dbname="$DB" > "$tmp"
[ -s "$tmp" ] || { alert "导出文件为空"; rm -f "$tmp"; exit 1; }
# pg_restore --list 能读出目录 = 文件完整；读不出说明导出被截断
if ! $PG_RESTORE --list < "$tmp" > /dev/null; then
  alert "导出文件校验失败（pg_restore --list 读不出）"; rm -f "$tmp"; exit 1
fi
mv "$tmp" "$final"
echo "backup ok: $final ($(du -h "$final" | cut -f1))"

# 清理：只删本脚本产出的命名格式，避免误删目录里别的东西；永远至少留最新一份
find "$BACKUP_DIR" -maxdepth 1 -name "$DB-*.dump" -type f -mtime "+$BACKUP_KEEP_DAYS" ! -path "$final" -print -delete
find "$BACKUP_DIR" -maxdepth 1 -name "$DB-*.dump.partial" -type f -mmin +120 -print -delete

if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
  rclone copy "$final" "$BACKUP_RCLONE_REMOTE" --immutable
  rclone delete "$BACKUP_RCLONE_REMOTE" --min-age "${BACKUP_KEEP_DAYS}d" --include "$DB-*.dump"
  echo "offsite ok: $BACKUP_RCLONE_REMOTE"
fi
