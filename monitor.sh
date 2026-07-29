#!/bin/bash
# Monitor IMAX / La Odisea ticket dates on entradas.todoshowcase.com.
# Alerts via Telegram when NEW dates appear — and when the monitor itself breaks.
#
# Config (env vars, or put them in .env next to this script):
#   TELEGRAM_BOT_TOKEN   required for alerts (get from @BotFather)
#   TELEGRAM_CHAT_ID     required for alerts (your chat/user id)
#   CINE / MOVIE / FORMAT   override target (defaults = IMAX/La Odisea/IMAX-Sub)
#   STATE_FILE           known-dates store (default: ./state/known_days.txt)
#   ALERT_EVERY          during an outage, re-alert every N failed runs (default 12)
#   HEARTBEAT            set to 1 to force --verbose (handy from cron env)
#
# Flags:
#   --test      fetch + print current dates, no state/alerts
#   --verbose   send a 💓 Telegram heartbeat on EVERY run (success or failure),
#               so silence means "not running". (More messages; drop it once confident.)
#
# Exit: 0 ok, 2 failure (state untouched; Telegram error alert sent w/ throttling)
set -uo pipefail   # NOTE: no -e; we handle errors explicitly so we can alert on them

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a

TEST=0; VERBOSE=0
[ "${HEARTBEAT:-0}" = 1 ] && VERBOSE=1
for arg in "$@"; do
  case "$arg" in
    --test)            TEST=1 ;;
    --verbose|--heartbeat) VERBOSE=1 ;;
    *) echo "unknown flag: $arg (use --test / --verbose)" >&2; exit 64 ;;
  esac
done

URL='https://entradas.todoshowcase.com/showcase/boleteria.aspx'
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36'
CINE="${CINE:-18}"        # IMAX Theatre (Norcenter)
MOVIE="${MOVIE:-5875}"    # La Odisea
FORMAT="${FORMAT:-8}"     # IMAX-Subtitulado
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state/known_days.txt}"
FAIL_FILE="${STATE_FILE}.failcount"
ALERT_EVERY="${ALERT_EVERY:-12}"

JAR=$(mktemp); TMP=$(mktemp); DAYS=$(mktemp)
trap 'rm -f "$JAR" "$TMP" "$DAYS"' EXIT

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

hid_html()  { perl -ne 'print $1 and exit if /id="'"$1"'"[^>]*value="([^"]*)"/' "$2"; }
hid_delta() { perl -ne 'print $1 and exit if /\|hiddenField\|'"$1"'\|([^|]*)/' "$2"; }

# telegram TEXT -> returns 0 on send (or when no creds configured), 1 on real failure
telegram() {
  local text="$1" resp
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "WARN: no Telegram creds — would have sent:"; printf '%s\n' "$text"; return 0
  fi
  resp=$(curl -s --max-time 30 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$text" \
    --data-urlencode "disable_web_page_preview=true")
  if printf '%s' "$resp" | grep -q '"ok":true'; then log "telegram sent"; return 0; fi
  log "ERROR: telegram send failed: $resp"; return 1
}

# Record a failure, alert on Telegram with throttling, then exit 2.
fail() {
  local reason="$1" n
  n=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
  mkdir -p "$(dirname "$FAIL_FILE")"; echo "$n" > "$FAIL_FILE"
  log "FAILURE #$n: $reason"
  # Alert on the 1st failure, then once every ALERT_EVERY runs while still broken.
  # In --verbose mode, report EVERY failed run (no throttle).
  if [ "$VERBOSE" = 1 ] || [ "$n" -eq 1 ] || [ $(( n % ALERT_EVERY )) -eq 0 ]; then
    telegram "⚠️ Monitor La Odisea IMAX con problemas (fallo #$n).
Motivo: $reason
Host: $(hostname)
Reintenta en el próximo ciclo. No pude leer las fechas, así que no perdiste ninguna alerta."
  else
    log "(alert throttled; next re-alert at multiple of $ALERT_EVERY)"
  fi
  exit 2
}

post() {  # post TARGET FIELD=VAL ...  -> body on stdout; returns curl's exit code
  local target="$1"; shift
  local args=(
    --data-urlencode "ctl00\$Contenido\$GeneralToolkitScriptManager=ctl00\$Contenido\$ctl00|$target"
    --data-urlencode "ctl00_Contenido_GeneralToolkitScriptManager_HiddenField="
  )
  local kv
  for kv in "$@"; do args+=( --data-urlencode "ctl00\$Contenido\$${kv%%=*}=${kv#*=}" ); done
  args+=(
    --data-urlencode "__LASTFOCUS=" --data-urlencode "__EVENTTARGET=$target" --data-urlencode "__EVENTARGUMENT="
    --data-urlencode "__VIEWSTATE=$VS" --data-urlencode "__VIEWSTATEGENERATOR=$VG"
    --data-urlencode "__EVENTVALIDATION=$EV" --data-urlencode "__ASYNCPOST=true"
  )
  curl -s --max-time 30 -b "$JAR" -c "$JAR" -A "$UA" "$URL" \
    -H 'X-MicrosoftAjax: Delta=true' -H 'X-Requested-With: XMLHttpRequest' \
    -H "Origin: https://entradas.todoshowcase.com" -H "Referer: $URL" "${args[@]}"
}

# Walk the cascade; write dates to $DAYS. On any problem, calls fail() (which exits).
fetch_days() {
  local code
  code=$(curl -s --max-time 30 -w '%{http_code}' -c "$JAR" -A "$UA" "$URL" -o "$TMP") \
    || fail "network error on initial GET (curl exit $?)"
  [ "$code" = 200 ] || fail "HTTP $code on initial GET"
  VS=$(hid_html __VIEWSTATE "$TMP"); VG=$(hid_html __VIEWSTATEGENERATOR "$TMP"); EV=$(hid_html __EVENTVALIDATION "$TMP")
  [ -n "$VS" ] || fail "no __VIEWSTATE on initial page (site changed / blocked?)"

  post 'ctl00$Contenido$lstCinemaFull' "lstCinemaFull=$CINE" > "$TMP" || fail "curl error at cinema step"
  VS=$(hid_delta __VIEWSTATE "$TMP"); VG=$(hid_delta __VIEWSTATEGENERATOR "$TMP"); EV=$(hid_delta __EVENTVALIDATION "$TMP")
  [ -n "$VS" ] || fail "cascade failed at cinema step (error page / cinema id $CINE gone?)"

  post 'ctl00$Contenido$lstMovies' "lstCinemaFull=$CINE" "lstMovies=$MOVIE" > "$TMP" || fail "curl error at movie step"
  VS=$(hid_delta __VIEWSTATE "$TMP"); VG=$(hid_delta __VIEWSTATEGENERATOR "$TMP"); EV=$(hid_delta __EVENTVALIDATION "$TMP")
  [ -n "$VS" ] || fail "cascade failed at movie step (movie id $MOVIE gone from cartelera?)"

  post 'ctl00$Contenido$lstFormat' "lstCinemaFull=$CINE" "lstMovies=$MOVIE" "lstFormat=$FORMAT" > "$TMP" \
    || fail "curl error at format step"
  perl -0777 -ne '
    if (/id="ctl00_Contenido_lstDays".*?<\/select>/s) {
      my $b=$&; while ($b =~ /<option value="([^"]*)"/g) { my $v=$1; next if $v =~ /Seleccione/; print "$v\n"; }
    }' "$TMP" | sed '/^$/d' > "$DAYS"
  [ -s "$DAYS" ] || fail "zero dates parsed for format $FORMAT (format removed, or lstDays markup changed)"
}

# ---- main ----
fetch_days   # exits via fail() on any error
COUNT=$(grep -c . "$DAYS")

if [ "$TEST" = 1 ]; then
  log "current dates ($COUNT):"; cat "$DAYS"; exit 0
fi

# We got a good read. If we were previously broken, announce recovery.
PREV_FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
if [ "$PREV_FAILS" -gt 0 ]; then
  log "recovered after $PREV_FAILS failed run(s)"
  telegram "✅ Monitor La Odisea IMAX recuperado (tras $PREV_FAILS fallo(s)). Leyendo $COUNT fechas de nuevo."
fi
rm -f "$FAIL_FILE"

mkdir -p "$(dirname "$STATE_FILE")"

if [ ! -f "$STATE_FILE" ]; then
  sort -u "$DAYS" > "$STATE_FILE"
  log "baseline saved ($COUNT dates)"
  telegram "🎬 Monitor de La Odisea IMAX iniciado. Siguiendo $COUNT fechas (hasta: $(tail -1 "$DAYS")). Te aviso cuando agreguen nuevas."
  exit 0
fi

NEW=$(comm -13 <(sort -u "$STATE_FILE") <(sort -u "$DAYS") || true)
if [ -n "$NEW" ]; then
  NCOUNT=$(printf '%s\n' "$NEW" | grep -c .)
  log "NEW dates ($NCOUNT):"; printf '%s\n' "$NEW"
  if telegram "🎟️ ¡Nuevas fechas para La Odisea en IMAX! ($NCOUNT)
$NEW

Comprá: $URL"; then
    # Only mark known AFTER a successful alert, so a Telegram hiccup retries next run.
    cat <(sort -u "$STATE_FILE") "$DAYS" | sort -u > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    log "alert not delivered — NOT updating state; will retry next run"
    exit 2
  fi
  STATUS="🎟️ $NCOUNT nuevas"
else
  log "no new dates ($COUNT current)"
  STATUS="sin novedades"
fi

if [ "$VERBOSE" = 1 ]; then
  telegram "💓 Monitor OK ($(hostname)) — $COUNT fechas (última: $(tail -1 "$DAYS")). $STATUS. $(date '+%H:%M')"
fi