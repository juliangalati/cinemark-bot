# Cinemark Showcase IMAX ticket-date monitor

Watches the "día" dropdown for **IMAX Theatre (Norcenter) → La Odisea → IMAX-Subtitulado**
on `entradas.todoshowcase.com` and sends a **Telegram** message when new dates appear.

Pure `bash` + `curl` (+ `perl`, preinstalled on macOS/Linux). No login, no Python, no browser.

## How it works
The site is ASP.NET WebForms. `monitor.sh` replays the dropdown cascade over HTTP:
`GET page → POST cinema=18 → POST movie=5875 → POST format=8`, then parses the day
options from the response. It diffs them against `state/known_days.txt` and alerts on anything new.

## Setup
1. **Create a Telegram bot:** message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. **Get your chat id:** message your new bot once, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `result[].message.chat.id`.
3. **Configure:**
   ```sh
   cp .env.example .env
   # edit .env, paste TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID
   ```
4. **Test:**
   ```sh
   ./monitor.sh --test     # just prints current dates, no state/alerts
   ./monitor.sh            # first run = baseline + a "started" Telegram message
   ```

## When it messages you

| Trigger | Message |
|---|---|
| First run | 🎬 "iniciado, siguiendo N fechas…" |
| **New dates appear** | 🎟️ "¡Nuevas fechas!" + the dates + buy link |
| Something breaks | ⚠️ "con problemas (fallo #N)" + the reason + host |
| Recovers after breaking | ✅ "recuperado (tras N fallos)" |
| Every run, only with `--verbose` | 💓 "Monitor OK — N fechas…" |

**Robustness built in:**
- Failures (network error, HTTP non-200, site markup change, zero dates parsed) are
  caught and alerted — the monitor never breaks *silently*.
- Failure alerts are **throttled**: one on the first failure, then only every
  `ALERT_EVERY` runs (default 12) during a prolonged outage — so you're not spammed.
- A **recovery** message fires once it reads dates again, so silence = healthy.
- State is never touched on a failed run, and new dates are only marked "known" after
  the Telegram alert actually sends — so you can't miss a date to a transient glitch.

### Heartbeat / "is it alive?" (`--verbose`)
`--verbose` (or env `HEARTBEAT=1`) sends a 💓 on **every** run — success *and* failure
(throttling disabled). With it on, **silence means it isn't running**. Great for peace of
mind, but noisy (~72 msgs/day at 20-min intervals), so prefer the split schedule below.

## Schedule (pick one)

**cron — recommended split** (quiet alerts + a sane hourly heartbeat). Both jobs share
state, so this is safe:
```sh
crontab -e     # NOTE: crontab, not cron
# add both lines:
*/20 * * * * /Users/tomi/git/tmigone/cinemark-bot/monitor.sh           >> /Users/tomi/git/tmigone/cinemark-bot/monitor.log 2>&1
0    * * * * /Users/tomi/git/tmigone/cinemark-bot/monitor.sh --verbose >> /Users/tomi/git/tmigone/cinemark-bot/monitor.log 2>&1
```
- Line 1: checks every 20 min, alerts only on new dates / breakage.
- Line 2: sends one 💓 per hour so you know it's alive.

Drop the `--verbose` line if you don't want heartbeats, or add it to line 1 to confirm
every single run.

**macOS gotchas:** grant `/usr/sbin/cron` **Full Disk Access** (System Settings →
Privacy & Security), and note cron **skips runs while the Mac is asleep** (no catch-up).

**macOS launchd** (native, survives reboots, can run missed jobs after wake): ask and
I'll drop in a `.plist`.

**Dead-man's-switch (most robust "is it alive"):** have the script ping a free service
like [healthchecks.io](https://healthchecks.io) each run; *they* notify you only when the
pings stop. This is the one thing self-heartbeating can't do — it catches "the Mac was
asleep" or "cron itself died." Ask and I'll wire in the one-line ping.

## Notes
- Runs anonymously — no login, no credentials for the site, nothing to expire between runs.
- State lives in `state/known_days.txt` (gitignored). Delete it to re-baseline.
- `state/known_days.txt.failcount` tracks consecutive failures (drives throttling); it's
  cleared automatically on recovery.
- Exit code `2` = fetch/parse failed; state is left untouched so you never lose history.
- Polling every 15–30 min is plenty and stays polite. Don't hammer it.

## Config reference
| Var | Default | Purpose |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | — | Bot token from @BotFather (required for alerts) |
| `TELEGRAM_CHAT_ID` | — | Your chat/user id (required for alerts) |
| `CINE` / `MOVIE` / `FORMAT` | `18` / `5875` / `8` | Target IDs (IMAX Norcenter / La Odisea / IMAX-Sub) |
| `ALERT_EVERY` | `12` | During an outage, re-alert every N failed runs |
| `HEARTBEAT` | `0` | Set `1` to force `--verbose` (heartbeat every run) |
| `STATE_FILE` | `./state/known_days.txt` | Where known dates are stored |
