import MetaTrader5 as mt5
import pandas as pd
import pandas_ta as ta
import numpy as np
import webbrowser
import quantstats as qs
from datetime import datetime
import pytz

# --- INPUTS ---
SYMBOL = "USDJPY"
START_BALANCE = 10000
LEVERAGE = 4.0
POINT = 0.001
PIPS_BUFFER = 20
ATR_MULTIPLIER = 5.0      # <--- Matches your MQL5 Input

# COSTS
SPREAD_PIPS = 2.0         
COMMISSION_PCT = 0.00035   

def get_data_usdjpy(start_dt, end_dt):
    if not mt5.initialize():
        print("MT5 Init Failed")
        return None

    print(f"Fetching {SYMBOL} from {start_dt.date()} to {end_dt.date()}...")
    rates = mt5.copy_rates_range(SYMBOL, mt5.TIMEFRAME_D1, start_dt, end_dt)
    mt5.shutdown()
    
    if rates is None or len(rates) == 0:
        return None

    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df = df.set_index('time')
    df = df[['open', 'high', 'low', 'close']].rename(columns=str.capitalize)
    return df

def run_strategy(df):
    # 1. INDICATORS & SIGNAL
    # Calculate ATR for Stop Loss
    df['ATR'] = ta.atr(df['High'], df['Low'], df['Close'], length=14)
    
    df['Range'] = df['High'] - df['Low']
    df['Prev_Range'] = df['Range'].shift(1)
    df['Is_NR4'] = (df['Prev_Range'] < df['Range'].shift(2)) & \
                   (df['Prev_Range'] < df['Range'].shift(3)) & \
                   (df['Prev_Range'] < df['Range'].shift(4))

    # 2. TRIGGERS
    buffer_val = PIPS_BUFFER * POINT
    df['Buy_Trigger']  = df['High'].shift(1) + buffer_val
    df['Sell_Trigger'] = df['Low'].shift(1) - buffer_val
    spread_cost = SPREAD_PIPS * POINT 

    # 3. EXECUTION WITH GAP & STOP LOSS LOGIC
    
    # --- BUY LOGIC ---
    buy_mask = df['Is_NR4'] & (df['High'] > df['Buy_Trigger'])
    
    # A. Entry Price (Gap Safe)
    # If Open > Trigger, fill at Open. Else fill at Trigger.
    # Add spread cost to entry.
    df.loc[buy_mask, 'Entry_Price'] = np.maximum(df.loc[buy_mask, 'Open'], df.loc[buy_mask, 'Buy_Trigger']) + spread_cost
    
    # B. Calculate Stop Loss Price
    # SL = Trigger - (ATR * Multiplier)
    # We use the previous day's ATR (shift 1) because we decide triggers at start of day
    df.loc[buy_mask, 'SL_Price'] = df.loc[buy_mask, 'Buy_Trigger'] - (df.loc[buy_mask, 'ATR'].shift(1) * ATR_MULTIPLIER)
    
    # C. Check if Stopped Out
    # If Low <= SL_Price, we hit the stop.
    buy_stopped = buy_mask & (df['Low'] <= df['SL_Price'])
    
    # D. Determine Exit Price
    # Default: Close Price
    df.loc[buy_mask, 'Exit_Price'] = df.loc[buy_mask, 'Close']
    # Overwrite if Stopped: Exit at SL Price
    df.loc[buy_stopped, 'Exit_Price'] = df.loc[buy_stopped, 'SL_Price']
    
    df.loc[buy_mask, 'Type'] = 1 
    
    # --- SELL LOGIC ---
    sell_mask = df['Is_NR4'] & (df['Low'] < df['Sell_Trigger'])
    
    # A. Entry Price (Gap Safe)
    df.loc[sell_mask, 'Entry_Price'] = np.minimum(df.loc[sell_mask, 'Open'], df.loc[sell_mask, 'Sell_Trigger'])
    
    # B. Calculate Stop Loss Price
    # SL = Trigger + (ATR * Multiplier)
    df.loc[sell_mask, 'SL_Price'] = df.loc[sell_mask, 'Sell_Trigger'] + (df.loc[sell_mask, 'ATR'].shift(1) * ATR_MULTIPLIER)
    
    # C. Check if Stopped Out
    # If High >= SL_Price, we hit the stop.
    sell_stopped = sell_mask & (df['High'] >= df['SL_Price'])
    
    # D. Determine Exit Price
    # Default: Close Price + Spread
    df.loc[sell_mask, 'Exit_Price'] = df.loc[sell_mask, 'Close'] + spread_cost
    # Overwrite if Stopped: Exit at SL Price + Spread
    df.loc[sell_stopped, 'Exit_Price'] = df.loc[sell_stopped, 'SL_Price'] + spread_cost
    
    df.loc[sell_mask, 'Type'] = -1 
    
    # 4. PNL CALCULATION
    equity = START_BALANCE
    trade_indices = df[df['Type'].notna()].index
    print(f"Processing {len(trade_indices)} trades (Gap + SL Protected)...")
    
    for i in trade_indices:
        row = df.loc[i]
        
        # Sizing
        units = int(equity * LEVERAGE)
        
        # Gross Profit (JPY)
        if row['Type'] == 1: 
            price_diff = row['Exit_Price'] - row['Entry_Price']
        else: 
            price_diff = row['Entry_Price'] - row['Exit_Price']
            
        gross_profit_jpy = price_diff * units
        
        # Commission (JPY)
        entry_comm = (row['Entry_Price'] * units) * COMMISSION_PCT
        exit_comm  = (row['Exit_Price'] * units) * COMMISSION_PCT
        total_comm_jpy = entry_comm + exit_comm
        
        # Net Profit (USD Corrected)
        net_profit_jpy = gross_profit_jpy - total_comm_jpy
        
        # Use Exit Price for conversion if valid, else use Close (safety)
        conv_rate = row['Exit_Price'] if row['Exit_Price'] > 0 else row['Close']
        net_profit_usd = net_profit_jpy / conv_rate
        
        equity += net_profit_usd
        df.at[i, 'Equity'] = equity

    df['Equity'] = df['Equity'].ffill().fillna(START_BALANCE)
    return df

# --- MAIN ---
if __name__ == "__main__":
    tz = pytz.timezone("Etc/UTC")
    start_date = datetime(2020, 1, 1, tzinfo=tz)
    end_date   = datetime.now(tz) 
    
    df = get_data_usdjpy(start_date, end_date)
    
    if df is not None:
        print("Calculating Strategy...")
        df_res = run_strategy(df)
        
        trades = df_res[df_res['Type'].notna()].copy()
        
        # Verification
        trades['Profit_USD'] = trades['Equity'].diff()
        print("\n--- Recent Trades (With SL Protection) ---")
        print(trades[['Close', 'SL_Price', 'Exit_Price', 'Profit_USD']].tail(5))
        
        print("\nGenerating Report...")
        returns = df_res['Equity'].pct_change().dropna()
        
        report_file = f"Pandas_{SYMBOL}_FinalStrict.html"
        qs.reports.html(returns, output=report_file, title=f"{SYMBOL} Strict Backtest")
        
        webbrowser.open(report_file)