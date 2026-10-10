#!/usr/bin/env bash

# SSH-safe wrapper: all strict/error settings run inside a subshell.
(
set -Eeuo pipefail

# ============================================================
# WAQAAR STATS DASHBOARD - FULL FRESH INSTALL
# Rebuilt from the exact live VPS snapshot captured 2026-09-10
# Includes 6-card layout + live week/month stats + archived week/month reports + responsive P&L calendar + unified status typography + desktop header alignment
# ============================================================

APP_DIR="/opt/waqaar-stats-dashboard"
APP_NAME="Trading Stats"
DASH_SECRET="${DASH_SECRET:-}"
SERVICE_NAME="waqaar-stats-dashboard"
STAMP="$(date +%Y%m%d-%H%M%S)"
DB_BACKUP="/root/waqaar-stats-db-before-install-$STAMP.db"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this command as root."
  exit 1
fi

if [ -z "$DASH_SECRET" ]; then
  read -r -s -p "Enter dashboard secret: " DASH_SECRET </dev/tty
  echo >/dev/tty
fi

if [[ ! "$DASH_SECRET" =~ ^[A-Za-z0-9._-]{8,128}$ ]]; then
  echo "Dashboard secret must be 8-128 characters using letters, numbers, dots, underscores or hyphens."
  exit 1
fi

trap 'rc=$?; echo; echo "INSTALL FAILED at line $LINENO with exit $rc"; echo "SSH session remains open."; exit $rc' ERR

echo "=== WAQAAR DASHBOARD FULL MASTER START ==="

# ------------------------------------------------------------
# Preserve current stats DB before rebuilding, if one exists
# ------------------------------------------------------------
if [ -f "$APP_DIR/data/stats.db" ]; then
  cp "$APP_DIR/data/stats.db" "$DB_BACKUP"
  echo "Existing stats DB backed up to: $DB_BACKUP"
else
  DB_BACKUP=""
fi

# ------------------------------------------------------------
# Base packages
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip nginx curl sqlite3 ufw

ufw allow OpenSSH || true
ufw allow 80 || true
ufw --force enable || true

# ------------------------------------------------------------
# Detect public IP
# ------------------------------------------------------------
SERVER_IP="$(curl -4 -fsS https://api.ipify.org || true)"
if [ -z "$SERVER_IP" ]; then
  read -r -p "Could not auto-detect public IP. Enter VPS public IP: " SERVER_IP
fi
DOMAIN="$(echo "$SERVER_IP" | tr '.' '-').sslip.io"

echo "SERVER_IP=$SERVER_IP"
echo "DOMAIN=$DOMAIN"

# ------------------------------------------------------------
# Rebuild app directory
# ------------------------------------------------------------
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/app" "$APP_DIR/data"

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
cat > "$APP_DIR/requirements.txt" <<'REQS'
annotated-doc==0.0.5
annotated-types==0.8.0
anyio==4.14.2
click==8.5.0
fastapi==0.141.1
h11==0.16.0
idna==3.19
pydantic==2.13.5
pydantic_core==2.46.5
python-dotenv==1.2.3
python-multipart==0.0.32
starlette==1.6.0
typing-inspection==0.4.4
typing_extensions==4.16.0
uvicorn==0.52.4
REQS
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------
cat > "$APP_DIR/.env" <<EOF
APP_NAME=$APP_NAME
DASH_SECRET=$DASH_SECRET
BASE_URL=http://$SERVER_IP
DB_PATH=$APP_DIR/data/stats.db
EOF
chmod 600 "$APP_DIR/.env"

# ------------------------------------------------------------
# Dashboard app based on live VPS snapshot + week/month archive system + upcoming-Sunday rollover
# ------------------------------------------------------------
cat > "$APP_DIR/app/main.py" <<'MAINPY'
import os
import json
import sqlite3
import datetime as dt
import html
import calendar
from zoneinfo import ZoneInfo
from typing import Any, Dict

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

load_dotenv("/opt/waqaar-stats-dashboard/.env")

APP_NAME = os.getenv("APP_NAME", "Trading Stats")
DASH_SECRET = os.getenv("DASH_SECRET", "")
BASE_URL = os.getenv("BASE_URL", "")
DB_PATH = os.getenv("DB_PATH", "/opt/waqaar-stats-dashboard/data/stats.db")
UK_TZ = ZoneInfo("Europe/London")

app = FastAPI(title=APP_NAME)


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def db():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


def init_db():
    con = db()
    cur = con.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS ea_heartbeat (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source TEXT,
            account TEXT,
            broker TEXT,
            terminal_status TEXT,
            trading_allowed INTEGER,
            balance REAL,
            equity REAL,
            margin REAL,
            free_margin REAL,
            raw TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source TEXT,
            account TEXT,
            trade_id TEXT,
            symbol TEXT,
            action TEXT,
            lot TEXT,
            entry TEXT,
            sl TEXT,
            tp TEXT,
            raw TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS trade_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source TEXT,
            account TEXT,
            event_type TEXT,
            trade_id TEXT,
            symbol TEXT,
            action TEXT,
            status TEXT,
            retcode TEXT,
            message TEXT,
            r REAL,
            profit REAL,
            raw TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS full_trade_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source TEXT,
            account TEXT NOT NULL DEFAULT '',
            trade_id TEXT NOT NULL,
            report_mode TEXT,
            week_start TEXT,
            symbol TEXT,
            entry_time TEXT,
            side TEXT,
            entry TEXT,
            sl TEXT,
            tp TEXT,
            sl_pips REAL,
            result TEXT,
            r REAL,
            net_result REAL,
            exit_time TEXT,
            raw TEXT,
            UNIQUE(account, trade_id)
        )
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_full_trade_results_week_entry
        ON full_trade_results(account, week_start, entry_time, id)
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_full_trade_results_received
        ON full_trade_results(account, received_at, id)
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS report_periods (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account TEXT NOT NULL DEFAULT '',
            period_type TEXT NOT NULL,
            period_key TEXT NOT NULL,
            period_start_utc TEXT NOT NULL,
            period_end_utc TEXT NOT NULL,
            display_label TEXT NOT NULL,
            final_r REAL NOT NULL DEFAULT 0,
            final_profit REAL NOT NULL DEFAULT 0,
            archived_at TEXT NOT NULL,
            UNIQUE(account, period_type, period_key)
        )
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_report_periods_type_start
        ON report_periods(account, period_type, period_start_utc DESC)
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS positions_snapshot (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source TEXT,
            account TEXT,
            open_count INTEGER,
            pending_count INTEGER,
            raw TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)

    # Backwards-compatible schema upgrades for older stats.db files.
    cols = [r["name"] for r in cur.execute("PRAGMA table_info(trade_events)").fetchall()]
    if "profit" not in cols:
        cur.execute("ALTER TABLE trade_events ADD COLUMN profit REAL")

    report_cols = [r["name"] for r in cur.execute("PRAGMA table_info(full_trade_results)").fetchall()]
    if "net_result" not in report_cols:
        cur.execute("ALTER TABLE full_trade_results ADD COLUMN net_result REAL")

    # Backfill old detailed rows from the matching close event when possible.
    cur.execute("""
        UPDATE full_trade_results
        SET net_result = (
            SELECT te.profit
            FROM trade_events te
            WHERE te.trade_id = full_trade_results.trade_id
              AND (
                    te.account = full_trade_results.account
                    OR full_trade_results.account = ''
                    OR te.account = ''
                  )
              AND te.profit IS NOT NULL
            ORDER BY te.id DESC
            LIMIT 1
        )
        WHERE net_result IS NULL
    """)

    con.commit()
    con.close()


@app.on_event("startup")
async def startup():
    init_db()


def require_secret(request: Request) -> bool:
    if not DASH_SECRET:
        return True
    return request.query_params.get("secret", "") == DASH_SECRET


async def read_payload(request: Request) -> Dict[str, Any]:
    raw_bytes = await request.body()
    raw = raw_bytes.decode("utf-8", errors="replace").strip()

    if not raw:
        return {"raw": "", "_raw": ""}

    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            data["_raw"] = raw
            return data
    except Exception:
        pass

    return parse_text_signal(raw)


def parse_text_signal(raw: str) -> Dict[str, Any]:
    data: Dict[str, Any] = {"raw": raw, "_raw": raw}
    tokens = [t.strip() for t in raw.replace("\n", " | ").split("|")]

    for tok in tokens:
        up = tok.upper()

        if up.startswith("ID="):
            data["trade_id"] = tok.split("=", 1)[1].strip()
        elif up.startswith("ACCOUNT="):
            data["account"] = tok.split("=", 1)[1].strip()
        elif up.startswith("ACCOUNT_NUMBER="):
            data["account"] = tok.split("=", 1)[1].strip()
        elif up.startswith("LOGIN="):
            data["account"] = tok.split("=", 1)[1].strip()
        elif up.startswith("SYMBOL="):
            data["symbol"] = tok.split("=", 1)[1].strip()
        elif up.startswith("LOT="):
            data["lot"] = tok.split("=", 1)[1].strip()
        elif up.startswith("ENTRY="):
            data["entry"] = tok.split("=", 1)[1].strip()
        elif up.startswith("SL="):
            data["sl"] = tok.split("=", 1)[1].strip()
        elif up.startswith("TP="):
            data["tp"] = tok.split("=", 1)[1].strip()
        elif up.startswith("PROFIT="):
            data["profit"] = as_float(tok.split("=", 1)[1].strip(), 0.0)
        elif up.startswith("R="):
            r_txt = tok.split("=", 1)[1].strip().upper().replace("R", "")
            try:
                data["r"] = float(r_txt)
            except Exception:
                data["r"] = None
        elif any(x in up for x in [
            "BUY LIMIT", "SELL LIMIT", "BUY STOP", "SELL STOP",
            "BUY MARKET", "SELL MARKET", "CANCEL PENDING",
            "TP HIT", "SL HIT", "TIME CLOSE", "BUY", "SELL"
        ]):
            data["action"] = tok

    return data


def esc(x) -> str:
    return html.escape("" if x is None else str(x))


def as_float(x, default=0.0) -> float:
    try:
        if x is None or x == "":
            return default
        return float(x)
    except Exception:
        return default


def as_int(x, default=0) -> int:
    try:
        if x is None or x == "":
            return default
        return int(float(x))
    except Exception:
        return default


def fmt2(x) -> str:
    try:
        if x is None or x == "":
            return ""
        return f"{float(x):,.2f}"
    except Exception:
        return ""


def signed_r(r: float) -> str:
    # Keep explicit +/- signs in the Weekly R Result table.
    if r > 0:
        return f"+{r:.2f}R"
    if r < 0:
        return f"{r:.2f}R"
    return "0.00R"


def card_r(r: float) -> str:
    # Card values use colour for direction, so show magnitude only.
    try:
        return f"{abs(float(r)):.2f}R"
    except Exception:
        return "0.00R"


def report_r(r: float) -> str:
    try:
        n = float(r)
    except Exception:
        n = 0.0
    if n > 0:
        return f"+{n:.2f}"
    if n < 0:
        return f"{n:.2f}"
    return "0.00"


def report_result_label(value) -> str:
    text = str(value or "").strip().upper()
    if text == "BLOCK":
        return "CLOSED"
    return text


def report_money(v: float) -> str:
    try:
        n = float(v)
    except Exception:
        n = 0.0
    if n > 0:
        return f"+£{n:,.2f}"
    if n < 0:
        return f"-£{abs(n):,.2f}"
    return "£0.00"


def gbp_money(v: float) -> str:
    # Money cards use colour for direction, so show magnitude only.
    try:
        return f"£{abs(float(v)):,.2f}"
    except Exception:
        return "£0.00"


def value_class(v: float) -> str:
    try:
        n = float(v)
    except Exception:
        n = 0.0
    if n > 0:
        return "r-positive"
    if n < 0:
        return "r-negative"
    return "r-flat"


def account_from_data(data: Dict[str, Any]) -> str:
    return str(
        data.get("account")
        or data.get("account_number")
        or data.get("login")
        or data.get("account_id")
        or ""
    ).strip()


def source_from_data(data: Dict[str, Any], default: str) -> str:
    return str(data.get("source") or default).strip()


def get_state(key: str, default: str = "") -> str:
    con = db()
    row = con.execute("SELECT value FROM app_state WHERE key = ?", (key,)).fetchone()
    con.close()
    if not row:
        return default
    return str(row["value"])


def set_state(key: str, value: str):
    con = db()
    con.execute(
        "INSERT INTO app_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )
    con.commit()
    con.close()


def reset_stats_for_new_account(new_account: str, source: str = ""):
    con = db()
    con.execute("DELETE FROM ea_heartbeat")
    con.execute("DELETE FROM signals")
    con.execute("DELETE FROM trade_events")
    con.execute("DELETE FROM full_trade_results")
    con.execute("DELETE FROM report_periods")
    con.execute("DELETE FROM positions_snapshot")
    con.execute("DELETE FROM app_state")
    con.execute(
        "INSERT INTO app_state(key, value) VALUES ('active_account', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (str(new_account),),
    )
    con.execute(
        "INSERT INTO app_state(key, value) VALUES ('active_source', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (str(source),),
    )
    con.execute(
        "INSERT INTO app_state(key, value) VALUES ('last_reset_at', ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (now_utc(),),
    )
    con.commit()
    con.close()


def check_account_switch(account: str, source: str = ""):
    account = str(account or "").strip()
    source = str(source or "").strip()

    if not account:
        return

    current = get_state("active_account", "")

    if current == "":
        set_state("active_account", account)
        set_state("active_source", source)
        return

    if current != account:
        reset_stats_for_new_account(account, source)
        return

    if source:
        set_state("active_source", source)


def get_latest_heartbeat():
    con = db()
    row = con.execute("SELECT * FROM ea_heartbeat ORDER BY id DESC LIMIT 1").fetchone()
    con.close()
    return row


def heartbeat_age_seconds(row):
    if not row:
        return None
    try:
        t = dt.datetime.fromisoformat(str(row["received_at"]).replace("Z", "+00:00"))
        return int((dt.datetime.now(dt.timezone.utc) - t).total_seconds())
    except Exception:
        return None


def _dash_utc_now_dt() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def _dash_utc_iso(x: dt.datetime) -> str:
    if x.tzinfo is None:
        x = x.replace(tzinfo=dt.timezone.utc)
    return x.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _dash_uk_now_dt() -> dt.datetime:
    return _dash_utc_now_dt().astimezone(UK_TZ)


def _dash_uk_month_start_utc() -> str:
    uk = _dash_uk_now_dt()
    start_uk = uk.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return _dash_utc_iso(start_uk)


def _dash_current_sunday_date() -> dt.date:
    uk = _dash_uk_now_dt()
    return uk.date() - dt.timedelta(days=(uk.weekday() + 1) % 7)


def _dash_current_sunday_key_uk() -> str:
    return _dash_current_sunday_date().isoformat()


def _dash_current_sunday_midnight_utc() -> str:
    start_uk = dt.datetime.combine(_dash_current_sunday_date(), dt.time(0, 0, 0), tzinfo=UK_TZ)
    return _dash_utc_iso(start_uk)


def _dash_current_month_key_uk() -> str:
    uk = _dash_uk_now_dt()
    return f"{uk.year:04d}-{uk.month:02d}"


def _month_parts(key: str):
    y, m = str(key).split("-", 1)
    return int(y), int(m)


def _month_start_uk(key: str) -> dt.datetime:
    y, m = _month_parts(key)
    return dt.datetime(y, m, 1, 0, 0, 0, tzinfo=UK_TZ)


def _next_month_key(key: str) -> str:
    y, m = _month_parts(key)
    if m == 12:
        y += 1
        m = 1
    else:
        m += 1
    return f"{y:04d}-{m:02d}"


def _month_bounds_utc(key: str):
    start_uk = _month_start_uk(key)
    next_uk = _month_start_uk(_next_month_key(key))
    return _dash_utc_iso(start_uk), _dash_utc_iso(next_uk)


def _month_display(key: str) -> str:
    return _month_start_uk(key).strftime("%B %Y")


def ensure_trading_week_state():
    current_key = get_state("trading_week_key", "")
    current_start = get_state("trading_week_start_utc", "")
    if current_key == "" or current_start == "":
        set_state("trading_week_key", _dash_current_sunday_key_uk())
        set_state("trading_week_start_utc", _dash_current_sunday_midnight_utc())


def ensure_trading_month_state():
    current_key = get_state("trading_month_key", "")
    current_start = get_state("trading_month_start_utc", "")
    if current_key == "" or current_start == "":
        key = _dash_current_month_key_uk()
        start_utc, _ = _month_bounds_utc(key)
        set_state("trading_month_key", key)
        set_state("trading_month_start_utc", start_utc)


def trading_week_start_utc() -> str:
    ensure_trading_week_state()
    return get_state("trading_week_start_utc", _dash_current_sunday_midnight_utc())


def trading_month_start_utc() -> str:
    ensure_trading_month_state()
    key = get_state("trading_month_key", _dash_current_month_key_uk())
    default_start, _ = _month_bounds_utc(key)
    return get_state("trading_month_start_utc", default_start)


def r_sum(period: str):
    con = db()
    if period == "weekly":
        start = trading_week_start_utc()
    elif period == "monthly":
        start = trading_month_start_utc()
    else:
        start = ""

    if start:
        row = con.execute("""
            SELECT COALESCE(SUM(r), 0) AS total
            FROM trade_events
            WHERE r IS NOT NULL AND received_at >= ?
        """, (start,)).fetchone()
    else:
        row = con.execute("SELECT COALESCE(SUM(r), 0) AS total FROM trade_events WHERE r IS NOT NULL").fetchone()
    con.close()
    return float(row["total"] or 0)


def this_week_profit() -> float:
    con = db()
    row = con.execute("""
        SELECT COALESCE(SUM(profit), 0) AS total
        FROM trade_events
        WHERE profit IS NOT NULL AND received_at >= ?
    """, (trading_week_start_utc(),)).fetchone()
    con.close()
    return float(row["total"] or 0)


def this_month_profit() -> float:
    con = db()
    row = con.execute("""
        SELECT COALESCE(SUM(profit), 0) AS total
        FROM trade_events
        WHERE profit IS NOT NULL AND received_at >= ?
    """, (trading_month_start_utc(),)).fetchone()
    con.close()
    return float(row["total"] or 0)


def _parse_dashboard_timestamp(value):
    try:
        text = str(value or "").strip()
        if not text:
            return None
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc)
    except Exception:
        return None


def month_daily_net_results(month_key: str, account: str = ""):
    """
    Return {day_number: net_profit} and {day_number: closed_trade_count} for the
    live dashboard month. Profit is grouped by the UK date on which the close
    event reached the dashboard, so a trade opened in August but closed on
    1 September belongs to 1 September.
    """
    start_utc, end_utc = _month_bounds_utc(month_key)
    con = db()
    if account:
        rows = con.execute("""
            SELECT received_at, profit
            FROM trade_events
            WHERE account = ?
              AND profit IS NOT NULL
              AND received_at >= ?
              AND received_at < ?
            ORDER BY id ASC
        """, (account, start_utc, end_utc)).fetchall()
    else:
        rows = con.execute("""
            SELECT received_at, profit
            FROM trade_events
            WHERE profit IS NOT NULL
              AND received_at >= ?
              AND received_at < ?
            ORDER BY id ASC
        """, (start_utc, end_utc)).fetchall()
    con.close()

    totals = {}
    counts = {}
    for row in rows:
        stamp = _parse_dashboard_timestamp(row["received_at"])
        if stamp is None:
            continue
        local = stamp.astimezone(UK_TZ)
        if local.strftime("%Y-%m") != month_key:
            continue
        day = int(local.day)
        totals[day] = totals.get(day, 0.0) + as_float(row["profit"], 0.0)
        counts[day] = counts.get(day, 0) + 1

    return totals, counts


def build_pnl_calendar(month_key: str, account: str = "") -> str:
    try:
        year_s, month_s = str(month_key).split("-", 1)
        year = int(year_s)
        month = int(month_s)
    except Exception:
        now_uk = _dash_uk_now_dt()
        year, month = now_uk.year, now_uk.month
        month_key = f"{year:04d}-{month:02d}"

    totals, counts = month_daily_net_results(month_key, account)
    today_uk = _dash_uk_now_dt().date()
    cal = calendar.Calendar(firstweekday=6)  # Sunday first, same as trading week

    cells = []
    for week in cal.monthdayscalendar(year, month):
        for day in week:
            if day == 0:
                cells.append('<div class="calendar-day calendar-empty"></div>')
                continue

            value = float(totals.get(day, 0.0))
            trades = int(counts.get(day, 0))
            cls = "calendar-day"
            if trades > 0:
                cls += " cal-positive" if value > 0 else (" cal-negative" if value < 0 else " cal-flat")
            if today_uk.year == year and today_uk.month == month and today_uk.day == day:
                cls += " cal-today"

            pnl_html = ""
            if trades > 0:
                pnl_html = f'<div class="calendar-day-pnl">£{abs(value):,.2f}</div>'

            cells.append(
                f'<div class="{cls}">'
                f'<div class="calendar-day-number">{day}</div>'
                f'{pnl_html}'
                f'</div>'
            )

    return "\n".join(cells)


def _period_totals(start_utc: str, end_utc: str, account: str = ""):
    con = db()
    if account:
        row = con.execute("""
            SELECT COALESCE(SUM(r), 0) AS total_r,
                   COALESCE(SUM(profit), 0) AS total_profit
            FROM trade_events
            WHERE account = ? AND received_at >= ? AND received_at < ?
        """, (account, start_utc, end_utc)).fetchone()
    else:
        row = con.execute("""
            SELECT COALESCE(SUM(r), 0) AS total_r,
                   COALESCE(SUM(profit), 0) AS total_profit
            FROM trade_events
            WHERE received_at >= ? AND received_at < ?
        """, (start_utc, end_utc)).fetchone()
    con.close()
    return float(row["total_r"] or 0), float(row["total_profit"] or 0)


def _archive_period(period_type: str, period_key: str, start_utc: str, end_utc: str, display_label: str):
    account = get_state("active_account", "")
    final_r, final_profit = _period_totals(start_utc, end_utc, account)
    con = db()
    con.execute("""
        INSERT INTO report_periods(
            account, period_type, period_key, period_start_utc, period_end_utc,
            display_label, final_r, final_profit, archived_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account, period_type, period_key) DO UPDATE SET
            period_start_utc=excluded.period_start_utc,
            period_end_utc=excluded.period_end_utc,
            display_label=excluded.display_label,
            final_r=excluded.final_r,
            final_profit=excluded.final_profit,
            archived_at=excluded.archived_at
    """, (
        account, period_type, period_key, start_utc, end_utc,
        display_label, final_r, final_profit, now_utc()
    ))
    con.commit()
    con.close()
    return final_r, final_profit


def _week_start_utc_from_key(key: str) -> str:
    d = dt.date.fromisoformat(str(key))
    start_uk = dt.datetime.combine(d, dt.time(0, 0, 0), tzinfo=UK_TZ)
    return _dash_utc_iso(start_uk)


def start_new_week():
    """
    Manual week rollover.

    The saved week key is the Sunday label for that trading week. When the
    command is run after Friday market close, the next live week must show the
    UPCOMING Sunday, even though that Sunday has not happened yet.

    We advance exactly one Sunday from the currently saved week. The archived
    period is rebuilt from the saved Sunday's UK midnight so a prior bad reset
    cannot accidentally lose the earlier trades from that week.
    """
    ensure_trading_week_state()

    now_dt = _dash_utc_now_dt()
    now = _dash_utc_iso(now_dt)
    today_uk = _dash_uk_now_dt().date()

    old_key = get_state("trading_week_key", _dash_current_sunday_key_uk())
    try:
        old_date = dt.date.fromisoformat(old_key)
    except Exception:
        old_date = _dash_current_sunday_date()
        old_key = old_date.isoformat()

    new_date = old_date + dt.timedelta(days=7)

    # Safety against an accidental double "new week". A legitimate rollover
    # may point at the coming Sunday when run on Friday/Saturday, or at a Sunday
    # that has just passed if the command was run late. It should never jump
    # more than two days into the future in one normal rollover.
    if new_date > today_uk + dt.timedelta(days=2):
        return False, (
            f"Week rollover refused: next saved Sunday would be {new_date.isoformat()}, "
            f"which is too far ahead. Current live week remains {old_key}."
        )

    archive_start = _week_start_utc_from_key(old_key)
    label = old_date.strftime("Sunday %d/%m/%Y")

    _archive_period("week", old_key, archive_start, now, label)

    new_key = new_date.isoformat()
    set_state("trading_week_key", new_key)
    set_state("trading_week_start_utc", now)
    set_state("last_week_reset_at", now)

    return True, (
        f"Archived week {old_key}. New live week started for Sunday "
        f"{new_date.strftime('%d/%m/%Y')}"
    )


def start_new_month():
    ensure_trading_month_state()
    active_key = get_state("trading_month_key", _dash_current_month_key_uk())
    current_key = _dash_current_month_key_uk()

    if active_key == current_key:
        return False, f"{_month_display(current_key)} is already the live month. Nothing changed."

    if active_key > current_key:
        return False, f"Stored month {active_key} is ahead of current UK month {current_key}. Nothing changed."

    key = active_key
    archived = []
    while key < current_key:
        start_utc, end_utc = _month_bounds_utc(key)
        _archive_period("month", key, start_utc, end_utc, _month_display(key))
        archived.append(key)
        key = _next_month_key(key)

    current_start, _ = _month_bounds_utc(current_key)
    set_state("trading_month_key", current_key)
    set_state("trading_month_start_utc", current_start)
    set_state("last_month_reset_at", now_utc())
    return True, f"Archived month(s): {', '.join(archived)}. Live month is now {_month_display(current_key)}."


def _fetch_report_rows(start_utc: str, end_utc: str | None = None, account: str = ""):
    con = db()
    params = []
    where = ["received_at >= ?"]
    params.append(start_utc)
    if end_utc:
        where.append("received_at < ?")
        params.append(end_utc)
    if account:
        where.append("account = ?")
        params.append(account)
    rows = con.execute(
        "SELECT * FROM full_trade_results WHERE " + " AND ".join(where) + " ORDER BY entry_time ASC, id ASC",
        tuple(params),
    ).fetchall()
    con.close()
    return rows


def _report_rows_html(rows, empty_text: str):
    body_rows = []
    for row in rows:
        r_num = as_float(row["r"], 0.0)
        net_num = as_float(row["net_result"], 0.0)
        sl_pips_text = f"{as_float(row['sl_pips'], 0.0):.2f}"
        r_class = value_class(r_num)
        net_class = value_class(net_num)
        body_rows.append(
            "<tr>"
            f"<td>{esc(str(row['symbol'] or '').upper())}</td>"
            f"<td>{esc(row['entry_time'] or '')}</td>"
            f"<td>{esc(row['exit_time'] or '')}</td>"
            f"<td>{esc(str(row['side'] or '').upper())}</td>"
            f"<td class='num'>{esc(row['entry'] or '')}</td>"
            f"<td class='num'>{esc(row['sl'] or '')}</td>"
            f"<td class='num'>{esc(row['tp'] or '')}</td>"
            f"<td class='num'>{esc(sl_pips_text)}</td>"
            f"<td>{esc(report_result_label(row['result']))}</td>"
            f"<td class='num {r_class}'>{esc(report_r(r_num))}</td>"
            f"<td class='num {net_class}'>{esc(report_money(net_num))}</td>"
            "</tr>"
        )
    if not body_rows:
        body_rows.append(f'<tr><td colspan="11" class="muted-cell">{esc(empty_text)}</td></tr>')
    return "\n".join(body_rows)


def latest_closed_trade():
    con = db()
    row = con.execute("""
        SELECT
            te.id,
            te.received_at,
            te.trade_id,
            te.symbol,
            te.action,
            te.status,
            te.r,
            te.profit
        FROM trade_events te
        WHERE
            (
                LOWER(COALESCE(te.event_type, '')) LIKE '%close%'
                OR LOWER(COALESCE(te.event_type, '')) LIKE '%manual_close%'
                OR LOWER(COALESCE(te.status, '')) LIKE '%closed%'
                OR LOWER(COALESCE(te.status, '')) LIKE '%tp%'
                OR LOWER(COALESCE(te.status, '')) LIKE '%sl%'
                OR te.r IS NOT NULL
                OR te.profit IS NOT NULL
            )
            AND LOWER(COALESCE(te.event_type, '')) NOT IN ('order', 'cancel', 'profit')
        ORDER BY te.id DESC
        LIMIT 1
    """).fetchone()
    con.close()
    return row


@app.get("/", response_class=HTMLResponse)
async def dashboard():
    init_db()
    ensure_trading_week_state()
    ensure_trading_month_state()

    hb = get_latest_heartbeat()
    age = heartbeat_age_seconds(hb)

    active_account = get_state("active_account", "")
    active_source = get_state("active_source", "")

    ea_online = age is not None and age <= 180
    ea_status_text = "Online ✅" if ea_online else "Offline ❌"
    ea_status_class = "ok" if ea_online else "bad"
    last_age = "N/A" if age is None else f"{age}s ago"

    shown_account = active_account or (hb["account"] if hb else "Not linked")
    shown_source = active_source or (hb["source"] if hb else "MT5 / cTrader")

    week_r = r_sum("weekly")
    month_r = r_sum("monthly")
    week_profit_value = this_week_profit()
    month_profit_value = this_month_profit()

    week_r_class = value_class(week_r)
    month_r_class = value_class(month_r)
    week_profit_class = value_class(week_profit_value)
    month_profit_class = value_class(month_profit_value)

    con = db()
    signals = con.execute("SELECT * FROM signals ORDER BY id DESC LIMIT 1").fetchall()
    pos = con.execute("SELECT * FROM positions_snapshot ORDER BY id DESC LIMIT 1").fetchone()
    con.close()

    open_count = pos["open_count"] if pos else 0

    balance = hb["balance"] if hb else ""
    margin = hb["margin"] if hb else ""

    last_closed = latest_closed_trade()
    last_closed_symbol = str(last_closed["symbol"] or "").upper() if last_closed else "No closed trade"

    last_signal = signals[0] if signals else None
    if last_signal:
        last_signal_symbol = str(last_signal["symbol"] or "").strip().upper()
        last_signal_title = last_signal_symbol if last_signal_symbol else "No Signal Yet"
    else:
        last_signal_title = "No Signal Yet"

    month_key = get_state("trading_month_key", _dash_current_month_key_uk())
    current_uk_month_display = _month_display(month_key)

    week_key = get_state("trading_week_key", _dash_current_sunday_key_uk())
    try:
        week_date = dt.date.fromisoformat(week_key)
    except Exception:
        week_date = _dash_current_sunday_date()
    current_week_start_display = "From Sunday " + week_date.strftime("%d/%m/%Y")

    week_start_for_tally = trading_week_start_utc()
    con = db()
    pair_rows_db = con.execute("""
        SELECT
            UPPER(TRIM(symbol)) AS symbol,
            COALESCE(SUM(r), 0) AS total_r
        FROM trade_events
        WHERE r IS NOT NULL
          AND received_at >= ?
          AND symbol IS NOT NULL
          AND TRIM(symbol) != ''
        GROUP BY UPPER(TRIM(symbol))
        ORDER BY UPPER(TRIM(symbol)) ASC
    """, (week_start_for_tally,)).fetchall()
    con.close()

    pair_rows = []
    for row in pair_rows_db:
        r_num = float(row["total_r"] or 0)
        r_class = "r-positive" if r_num > 0 else ("r-negative" if r_num < 0 else "r-flat")
        pair_rows.append(
            f'<tr><td>{esc(row["symbol"] or "")}</td>'
            f'<td class="num {r_class}">{esc(signed_r(r_num))}</td></tr>'
        )

    if not pair_rows:
        pair_rows.append('<tr><td colspan="2" class="muted">No pair R tally yet this week</td></tr>')

    pair_tally_html = "\n".join(pair_rows)
    pnl_calendar_html = build_pnl_calendar(month_key, active_account)

    return f"""
<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <title>{esc(APP_NAME)}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="refresh" content="5">
    <style>
        * {{ box-sizing: border-box; }}
        body {{
            font-family: Arial, sans-serif;
            background: #0f1115;
            color: #e6e6e6;
            margin: 0;
            padding: 24px;
        }}
        .top {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 24px;
            margin-bottom: 28px;
        }}
        h1 {{
            margin: 0;
            font-size: 34px;
            letter-spacing: 0.5px;
            white-space: nowrap;
        }}
        h2 {{
            margin-top: 28px;
            margin-bottom: 12px;
        }}
        .status-grid {{
            display: grid;
            grid-template-columns: 1.05fr 1.55fr 1.15fr 0.72fr;
            min-width: 720px;
            max-width: 940px;
            background: #181b22;
            border: 1px solid #2b303b;
            border-radius: 14px;
            overflow: hidden;
            box-shadow: 0 0 0 1px rgba(255,255,255,0.01);
        }}
        .status-item {{
            min-width: 0;
            padding: 10px 14px;
            border-left: 1px solid #2b303b;
            display: flex;
            flex-direction: column;
            justify-content: center;
            gap: 3px;
        }}
        .status-item:first-child {{ border-left: 0; }}
        .status-label {{
            color: #7f8a9a;
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.8px;
        }}
        .status-value {{
            color: #e6e6e6;
            font-size: 13px;
            font-weight: 700;
            line-height: 1.25;
            overflow-wrap: anywhere;
        }}
        .status-sub {{
            color: #e6e6e6;
            font-size: 11px;
            font-weight: 700;
            line-height: 1.25;
            font-family: inherit;
        }}
        .ok {{ color: #38d878; font-weight: bold; }}
        .bad {{ color: #ff4d5e; font-weight: bold; }}
        .top-stat-grid {{
            display: grid;
            grid-template-columns: repeat(4, minmax(190px, 1fr));
            gap: 14px;
            margin-bottom: 14px;
        }}
        .dashboard-lower {{
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 14px;
            align-items: stretch;
        }}
        .dashboard-lower-left {{
            min-width: 0;
            display: flex;
            flex-direction: column;
        }}
        .last-cards-grid {{
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 14px;
        }}
        .weekly-panel {{
            min-width: 0;
            margin-top: 28px;
        }}
        .weekly-panel h2 {{
            margin: 0 0 12px 0;
        }}
        .card {{
            background: #181b22;
            border: 1px solid #2b303b;
            border-radius: 14px;
            padding: 22px;
            min-height: 150px;
            box-shadow: 0 0 0 1px rgba(255,255,255,0.01);
        }}
        .card h3 {{
            margin: 0 0 18px 0;
            font-size: 19px;
        }}
        .big {{
            font-size: 28px;
            font-weight: 700;
        }}
        .muted {{
            color: #9ca3af;
            margin-top: 14px;
            font-size: 17px;
        }}
        .num,
        .big,
        table td,
        table th {{
            font-variant-numeric: tabular-nums;
            font-feature-settings: "tnum" 1, "lnum" 1;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            background: #181b22;
            border-radius: 14px;
            overflow: hidden;
            margin-bottom: 18px;
        }}
        th, td {{
            padding: 12px;
            border-bottom: 1px solid #2b303b;
            text-align: left;
            font-size: 14px;
        }}
        th {{
            background: #20242d;
            color: #e5e7eb;
        }}
        .r-positive {{ color: #22c55e; font-weight: 700; }}
        .r-negative {{ color: #ef4444; font-weight: 700; }}
        .r-flat {{ color: inherit; font-weight: 700; }}

        .weekly-tally-table {{
            width: 100%;
            margin-bottom: 0;
        }}
        .weekly-tally-table th:first-child,
        .weekly-tally-table td:first-child {{ width: 64%; }}
        .weekly-tally-table th:last-child,
        .weekly-tally-table td:last-child {{
            width: 36%;
            text-align: left;
        }}

        .calendar-panel {{
            min-width: 0;
            display: flex;
            align-self: stretch;
        }}
        .calendar-card {{
            width: 100%;
            height: 100%;
            min-height: 100%;
            display: flex;
            flex-direction: column;
            background: #181b22;
            border: 1px solid #2b303b;
            border-radius: 14px;
            overflow: hidden;
        }}
        .calendar-head {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            padding: 10px 12px;
            background: #20242d;
            border-bottom: 1px solid #2b303b;
        }}
        .calendar-month {{
            font-size: 14px;
            font-weight: 700;
            color: #e5e7eb;
        }}
        .calendar-note {{
            color: #9ca3af;
            font-size: 11px;
        }}
        .calendar-weekdays,
        .calendar-grid {{
            display: grid;
            grid-template-columns: repeat(7, minmax(0, 1fr));
        }}
        .calendar-weekdays {{
            flex: 0 0 auto;
        }}
        .calendar-grid {{
            flex: 1 1 auto;
            grid-auto-rows: minmax(44px, 1fr);
        }}
        .calendar-weekday {{
            padding: 6px 3px;
            text-align: center;
            font-size: 10px;
            font-weight: 700;
            color: #9ca3af;
            border-bottom: 1px solid #2b303b;
            background: #171a20;
        }}
        .calendar-day {{
            min-height: 44px;
            padding: 6px;
            border-right: 1px solid #2b303b;
            border-bottom: 1px solid #2b303b;
            background: #181b22;
        }}
        .calendar-day:nth-child(7n) {{ border-right: 0; }}
        .calendar-day-number {{
            font-size: 10px;
            font-weight: 700;
            color: #cbd5e1;
        }}
        .calendar-day-pnl {{
            margin-top: 6px;
            font-size: 10px;
            font-weight: 700;
            white-space: nowrap;
            font-variant-numeric: tabular-nums;
        }}
        .calendar-empty {{ background: #13161b; }}
        .cal-positive {{ background: rgba(34, 197, 94, 0.08); }}
        .cal-negative {{ background: rgba(239, 68, 68, 0.08); }}
        .cal-flat {{ background: rgba(148, 163, 184, 0.06); }}
        .cal-positive .calendar-day-pnl {{ color: #22c55e; }}
        .cal-negative .calendar-day-pnl {{ color: #ef4444; }}
        .cal-flat .calendar-day-pnl {{ color: #cbd5e1; }}
        .cal-today {{ box-shadow: inset 0 0 0 1px #6b7280; }}

        .report-actions {{
            display: flex;
            justify-content: flex-end;
            flex-wrap: wrap;
            gap: 10px;
            margin-top: 20px;
        }}
        .report-button {{
            display: inline-flex;
            align-items: center;
            justify-content: center;
            min-height: 44px;
            padding: 11px 16px;
            border-radius: 10px;
            border: 1px solid #2b303b;
            background: #20242d;
            color: #e6e6e6;
            text-decoration: none;
            font-weight: 700;
            font-size: 14px;
        }}
        .report-button:hover {{
            background: #272c36;
        }}

        @media (min-width: 1101px) {{
            .top-stat-grid,
            .last-cards-grid {{ align-items: start; }}

            /* Desktop only: give the journal/calendar area more vertical room.
               The left Weekly R section is intentionally pushed down; because
               the calendar stretches to the same lower-grid height, its bottom
               still aligns exactly with the Weekly R table. */
            .weekly-panel {{ margin-top: 120px; }}
            .calendar-head {{ padding: 12px 14px; }}
            .calendar-weekday {{ padding: 8px 4px; }}
            .calendar-day {{ min-height: 62px; padding: 8px; }}
            .calendar-day-number {{ font-size: 11px; }}
            .calendar-day-pnl {{ margin-top: 8px; font-size: 11px; }}
        }}

        /* Desktop-only header alignment.
           Keep mobile/tablet status layout exactly as before.
           Every status block uses the same three-row rhythm so labels and
           primary values line up horizontally even when some blocks have
           a third sub-line such as Balance or Heartbeat. */
        @media (min-width: 1101px) {{
            .status-item {{
                justify-content: flex-start;
                display: grid;
                grid-template-rows: 13px 18px 14px;
                align-content: start;
                row-gap: 3px;
            }}
            .status-label {{
                line-height: 13px;
                align-self: start;
            }}
            .status-value {{
                line-height: 18px;
                align-self: start;
            }}
            .status-sub {{
                line-height: 14px;
                align-self: start;
            }}
        }}

        @media (max-width: 1100px) {{
            .top-stat-grid {{
                grid-template-columns: repeat(2, minmax(0, 1fr));
            }}
            .dashboard-lower {{
                grid-template-columns: 1fr;
                gap: 14px;
            }}
            .top {{ flex-direction: column; align-items: stretch; }}
            .status-grid {{
                width: 100%;
                min-width: 0;
                max-width: none;
                grid-template-columns: repeat(2, minmax(0, 1fr));
            }}
            .status-item {{ border-left: 1px solid #2b303b; border-top: 1px solid #2b303b; }}
            .status-item:nth-child(1),
            .status-item:nth-child(2) {{ border-top: 0; }}
            .status-item:nth-child(odd) {{ border-left: 0; }}
            .calendar-panel {{ margin-top: 0; }}
            .calendar-card {{ height: auto; min-height: 0; }}
            .calendar-grid {{ grid-auto-rows: auto; }}
            .calendar-day {{ min-height: 74px; padding: 8px; }}
            .calendar-day-number {{ font-size: 12px; }}
            .calendar-day-pnl {{ margin-top: 11px; font-size: 13px; }}
            .calendar-weekday {{ padding: 9px 4px; font-size: 11px; }}
            .calendar-head {{ padding: 13px 15px; }}
            .calendar-month {{ font-size: 16px; }}
            .calendar-note {{ font-size: 12px; }}
        }}

        @media (max-width: 700px) {{
            body {{ padding: 22px; }}
            h1 {{ font-size: 34px; max-width: 330px; }}
            .status-grid {{ border-radius: 12px; }}
            .status-item {{ padding: 11px 12px; min-height: 66px; }}
            .status-label {{ font-size: 9px; }}
            .status-value {{ font-size: 12px; }}
            .status-sub {{ font-size: 10px; font-weight: 700; }}
            .top-stat-grid,
            .last-cards-grid {{
                grid-template-columns: repeat(2, minmax(0, 1fr));
                gap: 12px;
            }}
            .top-stat-grid {{ margin-bottom: 12px; }}
            .dashboard-lower {{ gap: 14px; }}
            .card {{
                padding: 18px;
                min-height: 205px;
            }}
            .card h3 {{ font-size: 18px; }}
            .big {{ font-size: 27px; }}
            .muted {{ font-size: 16px; line-height: 1.35; }}
            .weekly-panel {{ margin-top: 24px; }}
            .calendar-head {{ align-items: flex-start; flex-direction: column; gap: 4px; }}
            .calendar-weekday {{ font-size: 10px; padding: 8px 2px; }}
            .calendar-day {{ min-height: 62px; padding: 6px 4px; }}
            .calendar-day-number {{ font-size: 11px; }}
            .calendar-day-pnl {{ font-size: 10px; margin-top: 8px; }}
            .report-actions {{
                flex-wrap: nowrap;
                gap: 8px;
                justify-content: stretch;
            }}
            .report-button {{
                flex: 1 1 0;
                min-width: 0;
                padding: 9px 6px;
                font-size: 11px;
                line-height: 1.2;
                text-align: center;
                white-space: normal;
            }}
        }}
    </style>
</head>
<body>
    <div class="top">
        <div><h1>{esc(APP_NAME)}</h1></div>
        <div class="status-grid">
            <div class="status-item">
                <span class="status-label">Account</span>
                <span class="status-value">{esc(shown_account)}</span>
                <span class="status-sub">Balance: {esc(fmt2(balance))}</span>
            </div>
            <div class="status-item">
                <span class="status-label">Source</span>
                <span class="status-value">{esc(shown_source)}</span>
            </div>
            <div class="status-item">
                <span class="status-label">EA Status</span>
                <span class="status-value {ea_status_class}">{esc(ea_status_text)}</span>
                <span class="status-sub">Heartbeat: {esc(last_age)}</span>
            </div>
            <div class="status-item">
                <span class="status-label">Open Trades</span>
                <span class="status-value">{esc(open_count)}</span>
            </div>
        </div>
    </div>

    <div class="top-stat-grid">
        <div class="card card-week-r">
            <h3>This Week&apos;s R</h3>
            <div class="big num {week_r_class}">{esc(card_r(week_r))}</div>
            <div class="muted">{esc(current_week_start_display)}</div>
        </div>

        <div class="card card-week-profit">
            <h3>This Week</h3>
            <div class="big num {week_profit_class}">{esc(gbp_money(week_profit_value))}</div>
            <div class="muted">{esc(current_week_start_display)}</div>
        </div>

        <div class="card card-month-r">
            <h3>This Month&apos;s R</h3>
            <div class="big num {month_r_class}">{esc(card_r(month_r))}</div>
            <div class="muted">{esc(current_uk_month_display)}</div>
        </div>

        <div class="card card-month-profit">
            <h3>This Month</h3>
            <div class="big num {month_profit_class}">{esc(gbp_money(month_profit_value))}</div>
            <div class="muted">{esc(current_uk_month_display)}</div>
        </div>
    </div>

    <div class="dashboard-lower">
        <div class="dashboard-lower-left">
            <div class="last-cards-grid">
                <div class="card card-last-closed">
                    <h3>Last Closed</h3>
                    <div class="big num">{esc(last_closed_symbol)}</div>
                </div>

                <div class="card card-last-signal">
                    <h3>Last Signal</h3>
                    <div class="big num">{esc(last_signal_title)}</div>
                </div>
            </div>

            <section class="weekly-panel">
                <h2>Weekly R Result</h2>
                <table class="weekly-tally-table">
                    <tr>
                        <th>Symbol</th>
                        <th>R</th>
                    </tr>
                    {pair_tally_html}
                </table>
            </section>
        </div>

        <section class="calendar-panel">
            <div class="calendar-card">
                <div class="calendar-head">
                    <div class="calendar-month">{esc(current_uk_month_display)}</div>
                </div>
                <div class="calendar-weekdays">
                    <div class="calendar-weekday">Sun</div>
                    <div class="calendar-weekday">Mon</div>
                    <div class="calendar-weekday">Tue</div>
                    <div class="calendar-weekday">Wed</div>
                    <div class="calendar-weekday">Thu</div>
                    <div class="calendar-weekday">Fri</div>
                    <div class="calendar-weekday">Sat</div>
                </div>
                <div class="calendar-grid">
                    {pnl_calendar_html}
                </div>
            </div>
        </section>
    </div>

    <div class="report-actions">
        <a class="report-button" href="/thisweek">This Weeks Full Report</a>
        <a class="report-button" href="/allhistory">All Weeks / Months Full Report</a>
    </div>
</body>
</html>
"""


@app.get("/thisweek", response_class=HTMLResponse)
async def this_week_full_report():
    init_db()
    ensure_trading_week_state()

    week_key = get_state("trading_week_key", _dash_current_sunday_key_uk())
    start_utc = trading_week_start_utc()
    active_account = get_state("active_account", "")
    rows = _fetch_report_rows(start_utc, None, active_account)
    rows_html = _report_rows_html(rows, "No closed trades yet this week")
    current_r = r_sum("weekly")
    r_class = value_class(current_r)

    try:
        week_display = dt.date.fromisoformat(week_key).strftime("%d/%m/%Y")
    except Exception:
        week_display = week_key

    return f"""
<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <title>This Weeks Full Report</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * {{ box-sizing: border-box; }}
        body {{ font-family: Arial, sans-serif; background: #0f1115; color: #e6e6e6; margin: 0; padding: 24px; }}
        .topline {{ display:flex; gap:16px; flex-wrap:wrap; align-items:center; margin-bottom:14px; font-size:18px; font-weight:700; }}
        .back {{ color:#e6e6e6; text-decoration:none; border:1px solid #2b303b; background:#20242d; padding:9px 12px; border-radius:9px; }}
        .table-wrap {{ width: 100%; overflow-x: auto; border-radius: 14px; }}
        table {{ width: 100%; min-width: 1240px; border-collapse: collapse; background: #181b22; }}
        th, td {{ padding: 12px; border-bottom: 1px solid #2b303b; text-align: left; font-size: 14px; white-space: nowrap; font-variant-numeric: tabular-nums; }}
        th {{ background: #20242d; color: #e5e7eb; }}
        .num {{ font-variant-numeric: tabular-nums; }}
        .r-positive {{ color: #22c55e; font-weight: 700; }}
        .r-negative {{ color: #ef4444; font-weight: 700; }}
        .r-flat {{ color: inherit; font-weight: 700; }}
        .muted-cell {{ color: #9ca3af; text-align: center; padding: 24px; }}
        @media (max-width: 700px) {{ body {{ padding: 16px; }} th, td {{ padding: 10px; font-size: 13px; }} }}
    </style>
</head>
<body>
    <div class="topline">
        <a class="back" href="/">Back to Trading Stats</a>
        <span>Week Start: {esc(week_display)}</span>
        <span class="{r_class}">Current R: {esc(signed_r(current_r))}</span>
    </div>
    <div class="table-wrap">
        <table>
            <thead><tr>
                <th>Pair</th><th>Entry time</th><th>Closing time</th><th>Side</th>
                <th>Entry</th><th>SL</th><th>TP</th><th>SL pips</th>
                <th>Result</th><th>R</th><th>Net Result</th>
            </tr></thead>
            <tbody>{rows_html}</tbody>
        </table>
    </div>
</body>
</html>
"""


@app.get("/allhistory", response_class=HTMLResponse)
async def all_history(request: Request):
    init_db()
    ensure_trading_week_state()
    ensure_trading_month_state()

    active_account = get_state("active_account", "")
    selected_type = str(request.query_params.get("type", "")).strip().lower()
    selected_period = str(request.query_params.get("period", "")).strip()

    con = db()
    if active_account:
        archived_weeks = con.execute("""
            SELECT * FROM report_periods
            WHERE account = ? AND period_type = 'week'
            ORDER BY period_start_utc DESC
        """, (active_account,)).fetchall()
        archived_months = con.execute("""
            SELECT * FROM report_periods
            WHERE account = ? AND period_type = 'month'
            ORDER BY period_start_utc DESC
        """, (active_account,)).fetchall()
    else:
        archived_weeks = con.execute("""
            SELECT * FROM report_periods WHERE period_type = 'week' ORDER BY period_start_utc DESC
        """).fetchall()
        archived_months = con.execute("""
            SELECT * FROM report_periods WHERE period_type = 'month' ORDER BY period_start_utc DESC
        """).fetchall()
    con.close()

    week_options = ['<option value="">Select saved week</option>']
    for p in archived_weeks:
        sel = " selected" if selected_type == "week" and selected_period == str(p["period_key"]) else ""
        week_options.append(f'<option value="{esc(p["period_key"])}"{sel}>{esc(p["display_label"])}</option>')

    current_month_key = get_state("trading_month_key", _dash_current_month_key_uk())
    month_options = ['<option value="">Select month</option>']
    cur_sel = " selected" if selected_type == "month" and selected_period == "current:" + current_month_key else ""
    month_options.append(f'<option value="current:{esc(current_month_key)}"{cur_sel}>{esc(_month_display(current_month_key))} (Current)</option>')
    for p in archived_months:
        sel = " selected" if selected_type == "month" and selected_period == str(p["period_key"]) else ""
        month_options.append(f'<option value="{esc(p["period_key"])}"{sel}>{esc(p["display_label"])}</option>')

    report_html = ""
    if selected_type in ("week", "month") and selected_period:
        period = None
        is_current_month = selected_type == "month" and selected_period.startswith("current:")

        if is_current_month:
            key = selected_period.split(":", 1)[1]
            if key == current_month_key:
                start_utc = trading_month_start_utc()
                end_utc = None
                label = _month_display(key)
                final_r = r_sum("monthly")
                empty = f"No closed trades yet in {label}"
            else:
                start_utc = end_utc = None
        else:
            con = db()
            if active_account:
                period = con.execute("""
                    SELECT * FROM report_periods
                    WHERE account = ? AND period_type = ? AND period_key = ?
                    LIMIT 1
                """, (active_account, selected_type, selected_period)).fetchone()
            else:
                period = con.execute("""
                    SELECT * FROM report_periods
                    WHERE period_type = ? AND period_key = ?
                    ORDER BY id DESC LIMIT 1
                """, (selected_type, selected_period)).fetchone()
            con.close()
            if period:
                start_utc = period["period_start_utc"]
                end_utc = period["period_end_utc"]
                label = period["display_label"]
                final_r = float(period["final_r"] or 0)
                empty = "No closed trades saved for this period"
            else:
                start_utc = end_utc = None

        if start_utc:
            rows = _fetch_report_rows(start_utc, end_utc, active_account)
            rows_html = _report_rows_html(rows, empty)
            r_class = value_class(final_r)
            heading = "Week" if selected_type == "week" else "Month"
            report_html = f"""
            <div class="period-summary">
                <span>{heading}: {esc(label)}</span>
                <span class="{r_class}">Final R: {esc(signed_r(final_r))}</span>
            </div>
            <div class="table-wrap">
                <table>
                    <thead><tr>
                        <th>Pair</th><th>Entry time</th><th>Closing time</th><th>Side</th>
                        <th>Entry</th><th>SL</th><th>TP</th><th>SL pips</th>
                        <th>Result</th><th>R</th><th>Net Result</th>
                    </tr></thead>
                    <tbody>{rows_html}</tbody>
                </table>
            </div>
            """

    return f"""
<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <title>All Weeks / Months Full Report</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * {{ box-sizing: border-box; }}
        body {{ font-family: Arial, sans-serif; background:#0f1115; color:#e6e6e6; margin:0; padding:24px; }}
        .controls {{ position:sticky; top:0; z-index:10; background:#0f1115; padding:0 0 16px 0; display:flex; gap:10px; flex-wrap:wrap; align-items:center; }}
        select, .back {{
            min-height:44px;
            padding:10px 12px;
            border-radius:9px;
            border:1px solid #2b303b;
            background:#20242d;
            color:#e6e6e6;
            font-family:Arial, sans-serif;
            font-size:14px;
            font-weight:700;
        }}
        select option {{
            font-family:Arial, sans-serif;
            font-size:14px;
            font-weight:700;
        }}
        .back {{ text-decoration:none; display:inline-flex; align-items:center; }}
        .period-summary {{ display:flex; gap:18px; flex-wrap:wrap; font-size:18px; font-weight:700; margin:10px 0 14px 0; }}
        .table-wrap {{ width:100%; overflow-x:auto; border-radius:14px; }}
        table {{ width:100%; min-width:1240px; border-collapse:collapse; background:#181b22; }}
        th, td {{ padding:12px; border-bottom:1px solid #2b303b; text-align:left; font-size:14px; white-space:nowrap; font-variant-numeric:tabular-nums; }}
        th {{ background:#20242d; color:#e5e7eb; }}
        .r-positive {{ color:#22c55e; font-weight:700; }}
        .r-negative {{ color:#ef4444; font-weight:700; }}
        .r-flat {{ color:inherit; font-weight:700; }}
        .muted-cell {{ color:#9ca3af; text-align:center; padding:24px; }}
        .hint {{ color:#9ca3af; margin-top:12px; }}
        @media (max-width:700px) {{ body {{ padding:16px; }} .controls {{ top:0; }} th, td {{ padding:10px; font-size:13px; }} }}
    </style>
</head>
<body>
    <div class="controls">
        <a class="back" href="/">Back to Trading Stats</a>
        <select id="typeSelect" onchange="changeType()">
            <option value="">Select Week or Month</option>
            <option value="week"{' selected' if selected_type == 'week' else ''}>Week</option>
            <option value="month"{' selected' if selected_type == 'month' else ''}>Month</option>
        </select>
        <select id="weekSelect" style="display:{'inline-block' if selected_type == 'week' else 'none'}" onchange="changePeriod('week')">
            {''.join(week_options)}
        </select>
        <select id="monthSelect" style="display:{'inline-block' if selected_type == 'month' else 'none'}" onchange="changePeriod('month')">
            {''.join(month_options)}
        </select>
    </div>
    {report_html if report_html else '<div class="hint">Choose Week or Month, then choose the period you want to view.</div>'}
    <script>
        function changeType() {{
            const t = document.getElementById('typeSelect').value;
            if (!t) {{ window.location = '/allhistory'; return; }}
            window.location = '/allhistory?type=' + encodeURIComponent(t);
        }}
        function changePeriod(t) {{
            const id = t === 'week' ? 'weekSelect' : 'monthSelect';
            const p = document.getElementById(id).value;
            if (!p) {{ window.location = '/allhistory?type=' + encodeURIComponent(t); return; }}
            window.location = '/allhistory?type=' + encodeURIComponent(t) + '&period=' + encodeURIComponent(p);
        }}
    </script>
</body>
</html>
"""


@app.get("/health")
@app.get("/health")
async def health():
    return JSONResponse({
        "ok": True,
        "app": APP_NAME,
        "time": now_utc(),
        "base_url": BASE_URL,
        "active_account": get_state("active_account", ""),
        "active_source": get_state("active_source", ""),
    })


@app.post("/api/heartbeat")
async def api_heartbeat(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)

    data = await read_payload(request)
    raw = data.get("_raw") or data.get("raw") or json.dumps(data)

    account_value = account_from_data(data)
    source_value = source_from_data(data, "MT5 EA / cTrader")
    check_account_switch(account_value, source_value)

    con = db()
    con.execute("""
        INSERT INTO ea_heartbeat(
            received_at, source, account, broker, terminal_status, trading_allowed,
            balance, equity, margin, free_margin, raw
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        now_utc(),
        source_value,
        account_value,
        str(data.get("broker", data.get("server", ""))),
        str(data.get("terminal_status", data.get("status", ""))),
        1 if str(data.get("trading_allowed", data.get("trading_enabled", ""))).lower() in ["1", "true", "yes", "enabled"] else 0,
        as_float(data.get("balance", None), 0),
        as_float(data.get("equity", None), 0),
        as_float(data.get("margin", None), 0),
        as_float(data.get("free_margin", data.get("freeMargin", None)), 0),
        raw,
    ))
    con.commit()
    con.close()

    return PlainTextResponse("OK")


@app.post("/api/signal")
async def api_signal(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)

    data = await read_payload(request)
    raw = data.get("_raw") or data.get("raw") or json.dumps(data)

    account_value = account_from_data(data)
    source_value = source_from_data(data, "signal")
    if account_value:
        check_account_switch(account_value, source_value)

    ensure_trading_week_state()
    ensure_trading_month_state()

    con = db()
    con.execute("""
        INSERT INTO signals(received_at, source, account, trade_id, symbol, action, lot, entry, sl, tp, raw)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        now_utc(),
        source_value,
        account_value,
        str(data.get("trade_id", data.get("id", ""))),
        str(data.get("symbol", "")),
        str(data.get("action", "")),
        str(data.get("lot", "")),
        str(data.get("entry", "")),
        str(data.get("sl", "")),
        str(data.get("tp", "")),
        raw,
    ))
    con.commit()
    con.close()

    return PlainTextResponse("OK")


@app.post("/api/trade")
async def api_trade(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)

    data = await read_payload(request)
    raw = data.get("_raw") or data.get("raw") or json.dumps(data)

    account_value = account_from_data(data)
    source_value = source_from_data(data, "trade")
    if account_value:
        check_account_switch(account_value, source_value)

    ensure_trading_week_state()
    ensure_trading_month_state()

    received = now_utc()
    trade_id = str(data.get("trade_id", data.get("id", ""))).strip()
    full_report = str(data.get("full_report", "")).strip().lower() in ["1", "true", "yes", "on"]

    con = db()
    con.execute("""
        INSERT INTO trade_events(
            received_at, source, account, event_type, trade_id, symbol, action,
            status, retcode, message, r, profit, raw
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        received,
        source_value,
        account_value,
        str(data.get("event_type", "trade")),
        trade_id,
        str(data.get("symbol", "")),
        str(data.get("action", "")),
        str(data.get("status", "")),
        str(data.get("retcode", "")),
        str(data.get("message", "")),
        data.get("r", None),
        as_float(data.get("profit", data.get("profit_gbp", data.get("money", 0))), 0),
        raw,
    ))

    # v1.068+ standalone EA enriches every DRY/LIVE close with the exact
    # notepad-style row. Store it separately and sort by entry_time on /thisweek.
    # UPSERT protects the page from duplicate rows if the same trade is resent.
    if full_report and trade_id:
        con.execute("""
            INSERT INTO full_trade_results(
                received_at, source, account, trade_id, report_mode, week_start,
                symbol, entry_time, side, entry, sl, tp, sl_pips, result, r,
                net_result, exit_time, raw
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account, trade_id) DO UPDATE SET
                received_at=excluded.received_at,
                source=excluded.source,
                report_mode=excluded.report_mode,
                week_start=excluded.week_start,
                symbol=excluded.symbol,
                entry_time=excluded.entry_time,
                side=excluded.side,
                entry=excluded.entry,
                sl=excluded.sl,
                tp=excluded.tp,
                sl_pips=excluded.sl_pips,
                result=excluded.result,
                r=excluded.r,
                net_result=excluded.net_result,
                exit_time=excluded.exit_time,
                raw=excluded.raw
        """, (
            received,
            source_value,
            account_value,
            trade_id,
            str(data.get("report_mode", "")),
            str(data.get("week_start", "")),
            str(data.get("symbol", "")),
            str(data.get("entry_time", "")),
            str(data.get("side", "")),
            str(data.get("entry", "")),
            str(data.get("sl", "")),
            str(data.get("tp", "")),
            as_float(data.get("sl_pips", 0), 0),
            str(data.get("result", "")),
            data.get("r", None),
            as_float(data.get("profit", data.get("profit_gbp", data.get("money", 0))), 0),
            str(data.get("exit_time", "")),
            raw,
        ))

    con.commit()
    con.close()

    return PlainTextResponse("OK")


@app.post("/api/positions")
async def api_positions(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)

    data = await read_payload(request)
    raw = data.get("_raw") or data.get("raw") or json.dumps(data)

    account_value = account_from_data(data)
    source_value = source_from_data(data, "positions")
    if account_value:
        check_account_switch(account_value, source_value)

    con = db()
    con.execute("""
        INSERT INTO positions_snapshot(received_at, source, account, open_count, pending_count, raw)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        now_utc(),
        source_value,
        account_value,
        as_int(data.get("open_count", 0), 0),
        as_int(data.get("pending_count", 0), 0),
        raw,
    ))
    con.commit()
    con.close()

    return PlainTextResponse("OK")


@app.post("/api/new-week")
async def api_new_week(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)
    changed, message = start_new_week()
    return JSONResponse({"ok": True, "changed": changed, "message": message})


@app.post("/api/new-month")
async def api_new_month(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)
    changed, message = start_new_month()
    return JSONResponse({"ok": True, "changed": changed, "message": message})


@app.post("/api/reset")
async def api_reset(request: Request):
    if not require_secret(request):
        return PlainTextResponse("FORBIDDEN", status_code=403)

    con = db()
    con.execute("DELETE FROM ea_heartbeat")
    con.execute("DELETE FROM signals")
    con.execute("DELETE FROM trade_events")
    con.execute("DELETE FROM full_trade_results")
    con.execute("DELETE FROM report_periods")
    con.execute("DELETE FROM positions_snapshot")
    con.execute("DELETE FROM app_state")
    con.commit()
    con.close()

    return PlainTextResponse("RESET OK")
MAINPY

touch "$APP_DIR/app/__init__.py"

# Validate Python before starting service
"$APP_DIR/venv/bin/python" -m py_compile "$APP_DIR/app/main.py"

# ------------------------------------------------------------
# Restore existing stats DB if this was a rebuild
# ------------------------------------------------------------
if [ -n "$DB_BACKUP" ] && [ -f "$DB_BACKUP" ]; then
  cp "$DB_BACKUP" "$APP_DIR/data/stats.db"
  chmod 600 "$APP_DIR/data/stats.db"
  echo "Existing stats DB restored."
fi

# ------------------------------------------------------------
# systemd
# ------------------------------------------------------------
cat > /etc/systemd/system/waqaar-stats-dashboard.service <<'SERVICE'
[Unit]
Description=Waqaar Trading Stats Dashboard
After=network.target

[Service]
User=root
WorkingDirectory=/opt/waqaar-stats-dashboard
Environment="PATH=/opt/waqaar-stats-dashboard/venv/bin"
ExecStart=/opt/waqaar-stats-dashboard/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable waqaar-stats-dashboard
systemctl restart waqaar-stats-dashboard
sleep 3

# ------------------------------------------------------------
# Nginx
# ------------------------------------------------------------
cat > /etc/nginx/sites-available/waqaar-stats-dashboard <<EOF
server {
    listen 80;
    server_name $SERVER_IP $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/waqaar-stats-dashboard /etc/nginx/sites-enabled/waqaar-stats-dashboard
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ------------------------------------------------------------
# Helper command: reset
# ------------------------------------------------------------
cat > /usr/local/bin/reset <<'RESET'
#!/usr/bin/env bash
DASH_SECRET="$(sed -n 's/^DASH_SECRET=//p' /opt/waqaar-stats-dashboard/.env)"
curl -s -X POST "http://127.0.0.1:8000/api/reset?secret=${DASH_SECRET}"
echo
RESET
chmod +x /usr/local/bin/reset

# ------------------------------------------------------------
# Helper command: new week / new month
# ------------------------------------------------------------
cat > /usr/local/bin/new <<'NEWHELPER'
#!/usr/bin/env bash
set -e

DASH_SECRET="$(sed -n 's/^DASH_SECRET=//p' /opt/waqaar-stats-dashboard/.env)"

MODE="${1:-}"
case "$MODE" in
  week)
    ENDPOINT="new-week"
    ;;
  month)
    ENDPOINT="new-month"
    ;;
  *)
    echo "Usage: new week | new month"
    exit 1
    ;;
esac

RESPONSE="$(curl -fsS -X POST "http://127.0.0.1:8000/api/${ENDPOINT}?secret=${DASH_SECRET}")"
python3 - "$RESPONSE" <<'PYHELPER'
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data.get("message", sys.argv[1]))
except Exception:
    print(sys.argv[1])
PYHELPER
NEWHELPER
chmod +x /usr/local/bin/new

# ------------------------------------------------------------
# Final service restart + validation
# ------------------------------------------------------------
systemctl restart waqaar-stats-dashboard
sleep 3

HTTP_MAIN="$(curl -s -o /tmp/waqaar-main.html -w '%{http_code}' http://127.0.0.1:8000/)"
HTTP_WEEK="$(curl -s -o /tmp/waqaar-thisweek.html -w '%{http_code}' http://127.0.0.1:8000/thisweek)"
HTTP_HISTORY="$(curl -s -o /tmp/waqaar-allhistory.html -w '%{http_code}' http://127.0.0.1:8000/allhistory)"

if [ "$HTTP_MAIN" != "200" ] || [ "$HTTP_WEEK" != "200" ] || [ "$HTTP_HISTORY" != "200" ]; then
  echo "HTTP validation failed: main=$HTTP_MAIN thisweek=$HTTP_WEEK allhistory=$HTTP_HISTORY"
  journalctl -u waqaar-stats-dashboard -n 100 --no-pager
  exit 1
fi

# Check exact current layout exists
for text in   "This Week&apos;s R"   "This Week"   "This Month&apos;s R"   "This Month"   "Last Closed"   "Last Signal"   "Weekly R Result"   "This Weeks Full Report"   "All Weeks / Months Full Report"
do
  if ! grep -Fq "$text" /tmp/waqaar-main.html; then
    echo "Validation failed. Missing from live dashboard HTML: $text"
    exit 1
  fi
done

# Ensure legacy OG sections are not rendered on main page
for old in   "Account Snapshot"   "Daily R"   "Total R"   "Win / Loss"   "Pending Orders"   "Last Heartbeat Details"   "Dashboard State"   "Latest Signals Seen"   "Trade History / Errors"
do
  if grep -Fq "$old" /tmp/waqaar-main.html; then
    echo "Validation failed. Old dashboard section still present: $old"
    exit 1
  fi
done

# Verify latest cosmetic/layout changes
if ! grep -Fq '<h1>Trading Stats</h1>' /tmp/waqaar-main.html; then
  echo "Validation failed. Trading Stats title not found."
  exit 1
fi

if grep -Fq '| Margin:' /tmp/waqaar-main.html; then
  echo "Validation failed. Margin is still visible in the top account status."
  exit 1
fi

if ! grep -Fq 'class="status-grid"' /tmp/waqaar-main.html; then
  echo "Validation failed. New status bar layout is missing."
  exit 1
fi

# Balance and heartbeat are intentionally smaller, but use the same bold white text style
# as the main status values.
if ! grep -Fq 'font-weight: 700;' /tmp/waqaar-main.html || ! grep -Fq 'font-family: inherit;' /tmp/waqaar-main.html; then
  echo "Validation failed. Unified status typography is missing."
  exit 1
fi

if ! grep -Fq '<h3>Last Closed</h3>' /tmp/waqaar-main.html; then
  echo "Validation failed. Last Closed card title not found."
  exit 1
fi

# Verify report pages contain the new history/report controls and columns
for text in "Entry time" "Closing time" "Net Result"
do
  if ! grep -Fq "$text" /tmp/waqaar-thisweek.html; then
    echo "Validation failed. Missing from This Week report: $text"
    exit 1
  fi
done
for text in "Select Week or Month" "Select saved week" "Select month"
do
  if ! grep -Fq "$text" /tmp/waqaar-allhistory.html; then
    echo "Validation failed. Missing from All History page: $text"
    exit 1
  fi
done
if ! grep -Fq "font-weight:700" /tmp/waqaar-allhistory.html; then
  echo "Validation failed. History dropdown/button font styling missing"
  exit 1
fi

# Verify journal/calendar layout exists
if ! grep -Fq 'class="dashboard-lower"' /tmp/waqaar-main.html; then
  echo "Validation failed. Desktop/mobile journal layout missing"
  exit 1
fi
if ! grep -Fq 'class="calendar-grid"' /tmp/waqaar-main.html; then
  echo "Validation failed. P&L calendar grid missing"
  exit 1
fi
if ! grep -Fq 'class="calendar-panel"' /tmp/waqaar-main.html; then
  echo "Validation failed. Unified calendar panel missing"
  exit 1
fi
if grep -Fq '<h2>P&amp;L Calendar</h2>' /tmp/waqaar-main.html; then
  echo "Validation failed. P&L Calendar title should be removed"
  exit 1
fi
if grep -Fq 'Net result by close day' /tmp/waqaar-main.html; then
  echo "Validation failed. Calendar close-day note should be removed"
  exit 1
fi

# Ensure report-storage tables/columns exist
sqlite3 "$APP_DIR/data/stats.db" "SELECT name FROM sqlite_master WHERE type='table' AND name='full_trade_results';" | grep -qx 'full_trade_results'
sqlite3 "$APP_DIR/data/stats.db" "SELECT name FROM sqlite_master WHERE type='table' AND name='report_periods';" | grep -qx 'report_periods'
sqlite3 "$APP_DIR/data/stats.db" "PRAGMA table_info(full_trade_results);" | grep -q '|net_result|'

echo
echo "============================================================"
echo "INSTALL COMPLETE"
echo "============================================================"
echo "Dashboard: http://$SERVER_IP"
echo "Health: http://$SERVER_IP/health"
echo "This week full report: http://$SERVER_IP/thisweek"
echo "All weeks/months page: http://$SERVER_IP/allhistory"
echo "WebRequest allow URL: http://$SERVER_IP"
echo "Helper to wipe stats: reset"
echo "Helper to start/archive week: new week"
echo "Helper to start/archive month: new month"
echo "Dashboard secret: $DASH_SECRET"
echo
echo "HTTP checks: main=$HTTP_MAIN thisweek=$HTTP_WEEK allhistory=$HTTP_HISTORY"
if [ -n "$DB_BACKUP" ]; then
  echo "Pre-install DB backup retained at: $DB_BACKUP"
fi
echo "=== WAQAAR DASHBOARD FULL MASTER COMPLETE ==="

)
MASTER_RC=$?
if [ "$MASTER_RC" -ne 0 ]; then
  echo
  echo "=== MASTER FAILED WITH EXIT $MASTER_RC. SSH SESSION WAS NOT CLOSED ==="
else
  echo
  echo "=== MASTER FINISHED SUCCESSFULLY ==="
fi
