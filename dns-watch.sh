#!/usr/bin/env bash
set -u

ENV_FILE="${DNS_WATCH_ENV_FILE:-/etc/dns-watch/dns-watch.env}"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

DOMAIN="www.google.com"
TIMEOUT="2"
TRIES="1"

FAIL_LIMIT=3
SLOW_LIMIT_MS=500

LOG="/var/log/dns-watch.log"
STATE_DIR="/var/lib/dns-watch"

mkdir -p "$STATE_DIR"

declare -A SERVERS=(
  ["quad9-1"]="9.9.9.9"
  ["quad9-2"]="149.112.112.112"
  ["elisa-1"]="193.229.0.40"
  ["elisa-2"]="193.229.0.42"
)

now() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

send_gotify() {
  local title="$1"
  local message="$2"
  local priority="${3:-5}"

  [ -n "${GOTIFY_URL:-}" ] || return 0
  [ -n "${GOTIFY_TOKEN:-}" ] || return 0

  curl -fsS \
    -X POST "${GOTIFY_URL%/}/message" \
    -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
    -F "title=${title}" \
    -F "message=${message}" \
    -F "priority=${priority}" \
    >/dev/null 2>&1 || true
}

send_email() {
  local subject="$1"
  local body="$2"

  [ -n "${MAIL_TO:-}" ] || return 0
  [ -n "${MSMTP_BIN:-}" ] || MSMTP_BIN="/usr/bin/msmtp"

  if [ -x "$MSMTP_BIN" ]; then
    {
      printf 'From: %s\n' "${MAIL_FROM:-dns-watch@localhost}"
      printf 'To: %s\n' "$MAIL_TO"
      printf 'Subject: %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n'
      printf '%s\n' "$body"
    } | "$MSMTP_BIN" "$MAIL_TO" || true
  elif command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$MAIL_TO" || true
  else
    echo "$(now) WARN email not sent: no msmtp/mail command found" >> "$LOG"
  fi
}

notify_both() {
  local title="$1"
  local body="$2"
  local priority="${3:-5}"

  send_gotify "$title" "$body" "$priority"
  send_email "$title" "$body"
}

state_file() {
  local name="$1"
  echo "$STATE_DIR/$name.state"
}

read_state_value() {
  local file="$1"
  local key="$2"

  [ -r "$file" ] || return 0
  awk -F= -v k="$key" '$1 == k {print $2}' "$file" 2>/dev/null
}

write_state() {
  local file="$1"
  local fail_count="$2"
  local alert_sent="$3"

  {
    echo "fail_count=$fail_count"
    echo "alert_sent=$alert_sent"
  } > "$file"
}

probe_dns() {
  local ip="$1"

  dig @"$ip" "$DOMAIN" A \
    +time="$TIMEOUT" \
    +tries="$TRIES" \
    +noall \
    +comments \
    +stats \
    2>&1
}

for name in "${!SERVERS[@]}"; do
  ip="${SERVERS[$name]}"
  sf="$(state_file "$name")"

  old_fail_count="$(read_state_value "$sf" fail_count)"
  old_alert_sent="$(read_state_value "$sf" alert_sent)"

  fail_count="${old_fail_count:-0}"
  alert_sent="${old_alert_sent:-0}"

  output="$(probe_dns "$ip")"
  rc=$?

  status="$(printf '%s\n' "$output" | awk -F'status: ' '/status:/ {split($2,a,","); print a[1]; exit}')"
  query_time="$(printf '%s\n' "$output" | awk -F': ' '/Query time:/ {print $2}' | awk '{print $1; exit}')"

  is_ok=0
  reason=""

  if [ "$rc" -eq 0 ] && [ "${status:-}" = "NOERROR" ]; then
    if [ -n "${query_time:-}" ]; then
      if [ "$query_time" -le "$SLOW_LIMIT_MS" ]; then
        is_ok=1
      else
        reason="slow response: ${query_time}ms"
      fi
    else
      reason="NOERROR but query time missing"
    fi
  else
    reason="DNS failure, status=${status:-unknown}"
  fi

  if [ "$is_ok" -eq 1 ]; then
    echo "$(now) OK   $name $ip ${query_time}ms $DOMAIN" >> "$LOG"

    if [ "$alert_sent" = "1" ]; then
      title="DNS recovered: $name"
      body="$name ($ip) is responding again.

Domain: $DOMAIN
Response time: ${query_time}ms
Time: $(now)"

      notify_both "$title" "$body" 4
    fi

    write_state "$sf" 0 0
  else
    fail_count=$((fail_count + 1))

    echo "$(now) FAIL $name $ip count=$fail_count reason=$reason" >> "$LOG"

    if [ "$fail_count" -ge "$FAIL_LIMIT" ] && [ "$alert_sent" != "1" ]; then
      title="DNS problem: $name"
      body="$name ($ip) has failed DNS checks.

Domain: $DOMAIN
Consecutive failures: $fail_count
Reason: $reason
Time: $(now)"

      notify_both "$title" "$body" 8
      alert_sent=1
    fi

    write_state "$sf" "$fail_count" "$alert_sent"
  fi
done
