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
   ./monitor.sh --test     # just prints current dates
   ./monitor.sh            # first run = baseline + a "started" Telegram message
   ```

## Schedule (pick one)

**cron** (every 20 min):
```sh
crontab -e
# add:
*/20 * * * * /Users/tomi/git/tmigone/cinemark-bot/monitor.sh >> /Users/tomi/git/tmigone/cinemark-bot/monitor.log 2>&1
```

**macOS launchd** (survives reboots, runs even if cron is disabled): ask and I'll drop in a `.plist`.

## Notes
- Runs anonymously — no credentials stored anywhere.
- State lives in `state/known_days.txt` (gitignored). Delete it to re-baseline.
- Exit code `2` = fetch/parse failed; state is left untouched so you never lose history.
- Polling every 15–30 min is plenty and stays polite. Don't hammer it.
