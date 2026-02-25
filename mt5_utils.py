import MetaTrader5 as mt5
import pandas as pd
from datetime import timedelta, datetime, timezone

def get_mt5_offset():
    """Returns the offset between UTC and Broker Server Time."""
    if not mt5.initialize():
        print("Init failed")
        quit()

    # 1. Get the last 1-minute candle (Always in Server Time)
    # We use candles because ticks are sometimes stored in UTC, but candles are ALWAYS Server Time.
    rates = mt5.copy_rates_from_pos("EURUSD", mt5.TIMEFRAME_M1, 0, 1)

    if rates is not None and len(rates) > 0:
        # This is the time on the broker's chart
        server_timestamp = float(rates[0]['time'])
        
        # This is the real UTC time right now
        # We use .timestamp() to get raw seconds, ignoring timezones
        real_utc_timestamp = datetime.now(timezone.utc).timestamp()
        
        # Calculate the raw difference in hours
        diff_seconds = server_timestamp - real_utc_timestamp
        offset_hours = round(diff_seconds / 3600)

        print(f"Calculated Broker Offset: UTC{'+' if offset_hours >= 0 else ''}{offset_hours}")
    else:
        print("Could not fetch rates to calculate offset.")

    mt5.shutdown()
    return offset_hours

def pull_tick_data(symbol, start_dt, end_dt):
    """
    Fetches ticks in 1-day chunks.
    Assumes start_dt and end_dt match the BROKER'S SERVER TIME.
    """
    if not mt5.initialize():
        print("MT5 Init Failed")
        return None

    # 1. Validate Symbol Selection
    if not mt5.symbol_select(symbol, True):
        print(f"CRITICAL: Failed to select '{symbol}'. Check spelling or connection.")
        mt5.shutdown()
        return None

    current_start = start_dt - timedelta(days=1)
    ticks_df_list = []
    
    print(f"--- Starting fetch for {symbol} ---")
    
    buffer_end_dt = end_dt + timedelta(days=1)

    while current_start < buffer_end_dt:
        current_end = min(current_start + timedelta(days=1), buffer_end_dt)
        print(f"Fetching: {current_start} to {current_end}")
        
        t_start = int((start_dt + timedelta(hours=2)).timestamp())
        t_end   = int((end_dt + timedelta(hours=2)).timestamp())      

        # Fetch the chunk
        ticks = mt5.copy_ticks_range(symbol, t_start, t_end, mt5.COPY_TICKS_ALL)
        
        if ticks is not None and len(ticks) > 0:
            tick_df = pd.DataFrame(ticks)
            
            # 2. Use High-Res Time
            tick_df['time_msc'] = pd.to_datetime(tick_df['time_msc'], unit='ms')
            tick_df.set_index('time_msc', inplace=True)
            ticks_df_list.append(tick_df)
        else:
            print(f"  >> No data found for {current_start.date()}")

        current_start = current_end
    
    # 3. Prevent 'No objects to concatenate' Crash
    if not ticks_df_list:
        print("Warning: No data fetched for the entire range.")
        mt5.shutdown()
        return pd.DataFrame() # Return empty DataFrame safely

    print(f"Successfully compiled {len(ticks_df_list)} chunks.")
    mt5.shutdown()
    
    df_ticks = pd.concat(ticks_df_list)
    df_ticks = df_ticks[(df_ticks.index >= start_dt.replace(hour=0)) & (df_ticks.index < end_dt.replace(hour=0))]
    return df_ticks


if __name__ == '__main__':
    broker_offset = get_mt5_offset()
    BROKER_OFFSET = timedelta(hours=broker_offset)
    utc_start = datetime(2026,2,4, tzinfo=timezone.utc)
    utc_end = datetime(2026,2,5, tzinfo=timezone.utc)
    mt5_start = (utc_start.replace(tzinfo=None) + BROKER_OFFSET)
    mt5_end = (utc_end.replace(tzinfo=None) + BROKER_OFFSET)
    df_test = pull_tick_data('EURUSD', mt5_start , mt5_end)
    # print(df_test[df_test.index < datetime(2026,2,17)].tail())
    print(df_test.head())