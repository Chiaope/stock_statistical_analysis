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
START_STREAM_HOUR = 22
last_process_day = datetime.now(pytz.utc).date()

# --- 3. GLOBALS ---
API = oandapyV20.API(access_token=ACCESS_TOKEN)
pending_orders_deleted_today = False

# --- 4. HELPER FUNCTIONS ---


def get_current_gtd_time():
    """Calculates Good-Til-Date (23:59:59 UTC)."""
    now_utc = datetime.now(pytz.utc)

    # If we are generating this at 22:00 or later, we want the order
    # to expire at the END of the NEXT day (or current trading session).
    if now_utc.hour >= 22:
        target_date = now_utc + timedelta(days=1)
    else:
        target_date = now_utc

    day_end = target_date.replace(hour=23, minute=59, second=59, microsecond=0)
    return day_end.isoformat().split("+")[0] + ".000000000Z"


def calculate_lot_size_from_equity(equity):
    # Pure math, no API calls here
    vol = round((equity * LEV_PER_PAIR) * 0.1)
    return int(max(vol, 100))


def get_daily_candles(sym, count=5):
    print(f"  [{sym}] Fetching data...")
    try:
        params = {"count": count, "granularity": "D", "price": "M"}
        r = instruments.InstrumentsCandles(instrument=sym, params=params)
        API.request(r)
        df = pd.DataFrame(r.response["candles"])
        df["h"] = df["mid"].apply(lambda x: float(x["h"]))
        df["l"] = df["mid"].apply(lambda x: float(x["l"]))
        results = df.iloc[::-1].reset_index(drop=True)
        print(f"  [{sym}] Data fetch complete.\n{results}")
        return results
    except Exception as e:
        print(f"  [{sym}] Data fetch error: {e}")
        return pd.DataFrame()


# --- 5. ATOMIC TASKS (For Threading) ---


def task_order_cancellation(order):
    """Thread-safe function to cancel an order."""
    time.sleep(0.1)
    try:
        API.request(orders.OrderCancel(ACCOUNT_ID, order["id"]))
        print(f"  -> Order {order['id']} cancelled.")
    except Exception as e:
        print(f"  -> Order Cancellation Error: {e}")


def task_close_position(pos):
    """Thread-safe function to close a single position."""
    time.sleep(0.1)
    print(f"  [{pos.get('instrument')}] Closing position...")
    try:
        sym = pos["instrument"]
        long_units = pos.get("long", {}).get("units", "0")
        short_units = pos.get("short", {}).get("units", "0")

        close_data = {}
        if long_units != "0":
            close_data["longUnits"] = "ALL"
        if short_units != "0":
            close_data["shortUnits"] = "ALL"
        print(f"  -> [{sym}] Close data: {close_data}")
        if close_data:
            API.request(positions.PositionClose(ACCOUNT_ID, sym, data=close_data))
            print(f"  -> [{sym}] Closed position.")
    except Exception as e:
        print(f"  -> [{pos.get('instrument')}] Close failed: {e}")


def task_process_nr4(args):
    """Thread-safe function to run strategy for one symbol."""
    sym, equity = args
    print(f"  [{sym}] Scanning...")
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

    volume = calculate_lot_size_from_equity(equity)
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


def exit_everything():
    try:
        r = orders.OrderList(ACCOUNT_ID)
        API.request(r)
        print(f"  -> Found {len(r.response.get('orders', []))} pending orders.")
        order_list = r.response.get("orders", [])
        with concurrent.futures.ThreadPoolExecutor() as executor:
            executor.map(task_order_cancellation, order_list)
    except Exception as e:
        print(f"  -> Delete failed: {e}")

    # B. Parallel Position Closing
    try:
        print("[23:00 UTC] Closing Positions...")
        r = positions.OpenPositions(ACCOUNT_ID)
        API.request(r)
        open_positions = r.response.get("positions", [])
        print(f"  -> Found {len(open_positions)} open positions.")
        if open_positions:
            with concurrent.futures.ThreadPoolExecutor() as executor:
                executor.map(task_close_position, open_positions)

    except Exception as e:
        print(f"Exit Check Error: {e}")


def run_daily_entry_logic():
    """Runs the strategy scan for all pairs simultaneously."""
    global last_process_day
    print("\n[--- STARTING DAILY SCAN (PARALLEL) ---]")

    # This launches 3 threads at once. Total time = time of slowest pair (~0.5s total)
    try:
        exit_everything()
        # 2. Get Equity ONCE (Saves API calls)
        r = accounts.AccountSummary(ACCOUNT_ID)
        API.request(r)
        equity = float(r.response["account"]["NAV"])
        print(f"  [Account] Current Equity: {equity}")

        # 3. Prepare arguments for threads: [('GBP_JPY', 10000), ('USD_JPY', 10000)...]
        task_args = [(pair, equity) for pair in TRADE_PAIRS]

        # 4. Run Threads
        with concurrent.futures.ThreadPoolExecutor() as executor:
            executor.map(task_process_nr4, task_args)
        # with concurrent.futures.ThreadPoolExecutor() as executor:
        #     executor.map(task_process_nr4, TRADE_PAIRS)
    finally:
        last_process_day = datetime.now(pytz.utc).date()
    print("[DAILY SCAN COMPLETE]")


# --- 7. MAIN LOOP ---


def continuous_monitor():
    global pending_orders_deleted_today
    print("Bot Started.")

    while True:
        try:
            now = datetime.now(pytz.utc)

            # 1. EXIT LOGIC (Runs 23:00 - 23:55 UTC)
            # exit_everything()

            # 2. ENTRY LOGIC (Triggers exactly at 22:00 UTC)
            if (
                last_process_day < now.date()
                and now.hour >= START_STREAM_HOUR
                and now.hour < START_STREAM_HOUR + 1
            ):
                # Wait for 00:00:00 tick
                run_daily_entry_logic()

                # Reset cleanup flag for the new day
                # pending_orders_deleted_today = False

                # Sleep 5 mins to jump past the trigger window
                print("Entry complete. Sleeping for 10 minutes...")
                time.sleep(600)

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
    # exit_everything()
    # end_time = time.time()
    # elapsed_time = end_time - start_time
    # print(f"Total Execution Time: {elapsed_time} seconds")
