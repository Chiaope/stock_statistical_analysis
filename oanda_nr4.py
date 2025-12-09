import os
import sys
import time
import warnings
from datetime import datetime, timedelta
import pytz
import pandas as pd
from dotenv import load_dotenv
import concurrent.futures  # <--- Enables Concurrency

import oandapyV20
import oandapyV20.endpoints.instruments as instruments
import oandapyV20.endpoints.orders as orders
import oandapyV20.endpoints.positions as positions
import oandapyV20.endpoints.accounts as accounts
import oandapyV20.endpoints.pricing as pricing

# --- 1. SETUP ---
warnings.filterwarnings("ignore", category=SyntaxWarning)
load_dotenv()

ACCESS_TOKEN = os.getenv("OANDA_ACCESS_TOKEN")
ACCOUNT_ID = os.getenv("OANDA_ACCOUNT_ID")

if not ACCESS_TOKEN or not ACCOUNT_ID:
    print("CRITICAL ERROR: Credentials not found in .env file.")
    sys.exit(1)

# --- 2. CONFIGURATION ---
TRADE_PAIRS = ["GBP_JPY", "USD_JPY", "EUR_JPY"]
LEV_PER_PAIR = 1.33
ATR_MULTIPLIER = 5.0
CLOSE_HOUR = 23  # 23:00 UTC: Exit Time
START_STREAM_HOUR = 23  # 23:59 UTC: Start waiting for new day
START_STREAM_MINUTE = 59

# --- 3. GLOBALS ---
API = oandapyV20.API(access_token=ACCESS_TOKEN)
pending_orders_deleted_today = False

# --- 4. HELPER FUNCTIONS ---


def get_current_gtd_time():
    """Calculates Good-Til-Date (23:59:59 UTC)."""
    now_utc = datetime.utcnow().replace(tzinfo=pytz.utc)
    day_end = now_utc.replace(hour=23, minute=59, second=59, microsecond=0)
    if now_utc.hour >= 23:
        day_end += timedelta(days=1)
    return day_end.isoformat().split("+")[0] + ".000000000Z"


def calculate_lot_size(sym):
    try:
        r = accounts.AccountSummary(ACCOUNT_ID)
        API.request(r)
        equity = float(r.response["account"]["NAV"])
        vol = round((equity * LEV_PER_PAIR) * 0.1)
        return int(max(vol, 100))
    except Exception as e:
        print(f"  [{sym}] Error calculating lot size: {e}")
        return 0


def get_daily_candles(sym, count=5):
    try:
        params = {"count": count, "granularity": "D", "price": "M"}
        r = instruments.InstrumentsCandles(instrument=sym, params=params)
        API.request(r)
        df = pd.DataFrame(r.response["candles"])
        df["h"] = df["mid"].apply(lambda x: float(x["h"]))
        df["l"] = df["mid"].apply(lambda x: float(x["l"]))
        return df.iloc[::-1].reset_index(drop=True)
    except Exception as e:
        print(f"  [{sym}] Data fetch error: {e}")
        return pd.DataFrame()


# --- 5. ATOMIC TASKS (For Threading) ---


def task_delete_pending_orders(sym):
    """Thread-safe function to delete pending orders for one symbol."""
    try:
        r = orders.OrderList(ACCOUNT_ID)
        API.request(r)
        for order in r.response.get("orders", []):
            if order["instrument"] == sym and order["type"] in ["STOP", "LIMIT"]:
                API.request(orders.OrderCancel(ACCOUNT_ID, order["id"]))
                print(f"  -> [{sym}] Deleted pending order {order['id']}")
    except Exception as e:
        print(f"  -> [{sym}] Delete failed: {e}")


def task_close_position(pos):
    """Thread-safe function to close a single position."""
    try:
        sym = pos["instrument"]
        long_units = pos.get("long", {}).get("units", "0")
        short_units = pos.get("short", {}).get("units", "0")

        close_data = {}
        if long_units != "0":
            close_data["longUnits"] = "ALL"
        if short_units != "0":
            close_data["shortUnits"] = "ALL"

        if close_data:
            API.request(positions.PositionClose(ACCOUNT_ID, sym, data=close_data))
            print(f"  -> [{sym}] Closed position.")
    except Exception as e:
        print(f"  -> [{pos.get('instrument')}] Close failed: {e}")


def task_process_nr4(sym):
    """Thread-safe function to run strategy for one symbol."""
    print(f"  [{sym}] Scanning...")

    # 1. Ensure clean slate for this symbol first
    task_delete_pending_orders(sym)

    # 2. Get Data
    df = get_daily_candles(sym, count=5)
    if len(df) < 5:
        return

    r_ranges = (df["h"] - df["l"]).iloc[1:5]
    r1 = r_ranges.iloc[0]

    # 3. Logic Check
    if not (r1 < r_ranges.iloc[1:].min()):
        print(f"  [{sym}] No Signal.")
        return

    print(f"  [{sym}] NR4 DETECTED!")

    nr4_high = df["h"].iloc[1]
    nr4_low = df["l"].iloc[1]
    avg_range = r_ranges.iloc[1:].mean()

    stop_dist = avg_range * ATR_MULTIPLIER
    buffer = 0.20 if "JPY" in sym else 0.0020

    buy_trigger = nr4_high + buffer
    sell_trigger = nr4_low - buffer

    volume = calculate_lot_size(sym)
    gtd_time = get_current_gtd_time()

    if volume > 0:
        # Place Orders
        for side in ["BUY", "SELL"]:
            price = buy_trigger if side == "BUY" else sell_trigger
            sl = price - stop_dist if side == "BUY" else price + stop_dist
            units = volume if side == "BUY" else -volume

            order_data = {
                "order": {
                    "units": str(units),
                    "instrument": sym,
                    "price": str(round(price, 3)),
                    "type": "STOP",
                    "timeInForce": "GTD",
                    "gtdTime": gtd_time,
                    "stopLossOnFill": {"price": str(round(sl, 3))},
                    "positionFill": "DEFAULT",
                    "clientExtensions": {"tag": f"NR4-{side}"},
                }
            }
            try:
                API.request(orders.OrderCreate(ACCOUNT_ID, data=order_data))
                print(f"  -> [{sym}] {side} STOP placed @ {price:.3f}")
            except Exception as e:
                print(f"  -> [{sym}] Order Error: {e}")


# --- 6. PARALLEL EXECUTION MANAGERS ---


def check_time_exits():
    """Manages 23:00 UTC cleanup with MAX CONCURRENCY."""
    global pending_orders_deleted_today
    now = datetime.utcnow()

    if now.hour < CLOSE_HOUR:
        return

    # A. Parallel Pending Order Cleanup (Once at 23:00)
    if not pending_orders_deleted_today:
        print("\n[23:00 UTC] Closing Hour. Parallel Cleanup started.")
        with concurrent.futures.ThreadPoolExecutor() as executor:
            executor.map(task_delete_pending_orders, TRADE_PAIRS)
        pending_orders_deleted_today = True

    # B. Parallel Position Closing
    try:
        r = positions.OpenPositions(ACCOUNT_ID)
        API.request(r)
        open_positions = r.response.get("positions", [])

        if open_positions:
            print(
                f"  -> Found {len(open_positions)} open positions. Closing in parallel..."
            )
            with concurrent.futures.ThreadPoolExecutor() as executor:
                executor.map(task_close_position, open_positions)

    except Exception as e:
        print(f"Exit Check Error: {e}")


def run_daily_entry_logic():
    """Runs the strategy scan for all pairs simultaneously."""
    print("\n[--- STARTING DAILY SCAN (PARALLEL) ---]")

    # This launches 3 threads at once. Total time = time of slowest pair (~0.5s total)
    with concurrent.futures.ThreadPoolExecutor() as executor:
        executor.map(task_process_nr4, TRADE_PAIRS)

    print("[DAILY SCAN COMPLETE]")


def wait_for_new_day_via_stream():
    """Blocks until the first tick of the next UTC day."""
    target_date = (datetime.utcnow() + timedelta(days=1)).strftime("%Y-%m-%d")
    print(f"\n[STREAM] Waiting for first tick of {target_date}...")

    # Stream one pair to act as the clock
    r = pricing.PricingStream(
        accountID=ACCOUNT_ID, params={"instruments": TRADE_PAIRS[0]}
    )
    try:
        for tick in API.request(r):
            if tick.get("type") == "PRICE":
                tick_date = tick.get("time", "").split("T")[0]
                if tick_date == target_date:
                    r.terminate("New day")
                    return True
    except Exception as e:
        print(f"Stream Error: {e}")
        return False
    return False


# --- 7. MAIN LOOP ---


def continuous_monitor():
    global pending_orders_deleted_today
    print(
        f"Bot Started. Monitoring for {CLOSE_HOUR}:00 Exit and {START_STREAM_HOUR}:{START_STREAM_MINUTE} Entry."
    )

    while True:
        try:
            now = datetime.utcnow()

            # 1. EXIT LOGIC (Runs 23:00 - 23:59 UTC)
            check_time_exits()

            # 2. ENTRY LOGIC (Triggers exactly at 23:59 UTC)
            if now.hour == START_STREAM_HOUR and now.minute == START_STREAM_MINUTE:
                # Wait for 00:00:00 tick
                if wait_for_new_day_via_stream():
                    # Run Strategy in Parallel
                    run_daily_entry_logic()

                    # Reset cleanup flag for the new day
                    pending_orders_deleted_today = False

                    # Sleep 5 mins to jump past the trigger window
                    print("Entry complete. Sleeping for 5 minutes...")
                    time.sleep(300)

            # 3. Idle Sleep
            time.sleep(60)

        except KeyboardInterrupt:
            print("Bot stopped.")
            break
        except Exception as e:
            print(f"Main Loop Error: {e}")
            time.sleep(30)


if __name__ == "__main__":
    continuous_monitor()
    # start_time = time.time()
    # # run_daily_entry_logic()
    # check_time_exits()
    # end_time = time.time()
    # elapsed_time = end_time - start_time
    # print(f"Total Execution Time: {elapsed_time} seconds")
