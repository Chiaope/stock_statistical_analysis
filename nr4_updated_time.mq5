//+------------------------------------------------------------------+
//|                                   NR4_Portfolio_DynamicTime.mq5  |
//|               Multi-Currency NR4 Portfolio (Dynamic Time & Swap Fix) |
//|                                  Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "3.02"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input string   TradePairs     = "GBPJPY,USDJPY,EURJPY"; // Comma-separated pairs
input double   LevPerPair     = 1.33;     // Leverage Allocation per Pair
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input int      MagicNumber    = 888888;   // Unique ID

// --- TIME CONFIGURATION (Fixed based on your request) ---
// This strategy targets 24 hours of trading: 
// Entry @ 22:00 UTC (New Candle Open) 
// Exit @ 20:55 UTC (5 mins before the 21:00/22:00 UTC Rollover)
const int      TARGET_ENTRY_HOUR_UTC    = 22;   
const int      TARGET_EXIT_HOUR_UTC     = 20;
const int      TARGET_EXIT_MINUTE_UTC   = 55;

// --- GLOBALS ---
CTrade         trade;
string         symbols[];
int            atrHandles[];
datetime       lastEntryDate = 0;
bool           cleanupDoneToday = false; 
int            g_ServerToUtcOffset = 0; // The difference in hours (e.g., +2 or +3)

// --- HELPER FUNCTION: Calculates Broker's Server Offset to UTC ---
void CalculateServerOffset()
  {
   // The daily candle opens at 00:00 Server Time (Broker Time)
   // This 00:00 Server Time aligns with the New York 5 PM close.
   // During DST, NY 5 PM is 21:00 UTC. Offset = 24 - 21 = +3 hours.
   // During Non-DST, NY 5 PM is 22:00 UTC. Offset = 24 - 22 = +2 hours.
   
   // We use the open time of the current D1 candle to check its UTC time.
   datetime d1_open_time = iTime(symbols[0], PERIOD_D1, 0);
   MqlDateTime dt_server;
   TimeToStruct(d1_open_time, dt_server);
   
   // Get the current UTC time (MQL5 TimeCurrent() is UTC)
   MqlDateTime dt_utc;
   TimeCurrent(dt_utc);
   
   // Calculate the hour difference between Server 00:00 (d1_open_time) and UTC (TimeCurrent)
   // This is simplified, but since the broker aligns D1 open (00:00 server) with 21/22 UTC, 
   // we can just check the server's current offset relative to its 00:00 point.
   g_ServerToUtcOffset = (int)MathRound((double)TimeCurrent() - (double)TimeGMT()) / 3600;
   
   // Fallback check to determine if the server is GMT+2 or GMT+3
   // This assumes the broker's 00:00 aligns to 21:00 UTC (DST) or 22:00 UTC (Non-DST)
   int server_hour = dt_server.hour; // Should be 00
   datetime current_utc_time = TimeGMT();
   MqlDateTime dt_utc_now;
   TimeToStruct(current_utc_time, dt_utc_now);
   
   // Simplified check: If Server Time is GMT+3, UTC hour difference is usually 3.
   // We'll trust TimeLocal() - TimeGMT() for a more robust calculation in MQL5.
   // However, TimeLocal() is usually the *platform's* time zone. We need *Server* vs *UTC*.
   
   // The difference between TimeCurrent() (Server Time) and TimeGMT() (UTC Time) is the offset.
   g_ServerToUtcOffset = (int)MathRound((double)TimeCurrent() - (double)TimeGMT()) / 3600;
   
   Print("Broker Server Time Offset to UTC: GMT+", IntegerToString(g_ServerToUtcOffset));
  }

// --- HELPER FUNCTION: Converts TARGET_HOUR_UTC to Server Time ---
int GetServerHour(int target_hour_utc)
  {
   int server_hour = target_hour_utc + g_ServerToUtcOffset;
   if(server_hour >= 24) server_hour -= 24;
   if(server_hour < 0) server_hour += 24;
   return server_hour;
  }
  
// --- HELPER FUNCTION: Calculates the Order Expiry Time in Server Time ---
datetime GetOrderExpiryTimeServer()
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Convert target UTC time to Server Time
   int server_exit_hour = GetServerHour(TARGET_EXIT_HOUR_UTC);
   
   dt.hour = server_exit_hour;
   dt.min = TARGET_EXIT_MINUTE_UTC;
   dt.sec = 0;
   
   datetime expiryTime = StructToTime(dt);
   
   // If the calculated expiry time is in the past, set it for the next day
   if(expiryTime <= TimeCurrent()) expiryTime += 86400; // Add 24 hours (86400 seconds)
   
   return expiryTime;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   StringSplit(TradePairs, ',', symbols);
   int total = ArraySize(symbols);
   ArrayResize(atrHandles, total);
   
   for(int i=0; i<total; i++)
     {
      StringTrimLeft(symbols[i]);
      StringTrimRight(symbols[i]);
      if(!SymbolSelect(symbols[i], true)) Print("Failed select: ", symbols[i]);
      atrHandles[i] = iATR(symbols[i], PERIOD_D1, 14);
     }
     
   CalculateServerOffset(); // Determine the crucial server time offset

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int i=0; i<ArraySize(atrHandles); i++) IndicatorRelease(atrHandles[i]);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime dt_server;
   TimeCurrent(dt_server);
   
   int server_entry_hour = GetServerHour(TARGET_ENTRY_HOUR_UTC);
   int server_exit_hour = GetServerHour(TARGET_EXIT_HOUR_UTC);

   // 1. EXIT LOGIC (Runs at 20:55 UTC converted to Server Time)
   // This ensures we close before the 21:00/22:00 UTC rollover/swap calculation.
   if(dt_server.hour == server_exit_hour && dt_server.min >= TARGET_EXIT_MINUTE_UTC)
     {
      CheckTimeExits();
     }
   
   // 2. ENTRY LOGIC (Runs at 22:00 UTC converted to Server Time)
   if(dt_server.hour == server_entry_hour && dt_server.min < 5)
     {
      // Check if we already ran entry for today (based on the D1 candle date)
      datetime currentDay = iTime(symbols[0], PERIOD_D1, 0);
      if(currentDay != lastEntryDate)
        {
         RunDailyEntryLogic();
         lastEntryDate = currentDay;
         cleanupDoneToday = false; // Reset cleanup flag for the next exit window
        }
     }
  }

// --- CORE FUNCTIONS ---

void CheckTimeExits()
  {
   // A. One-Time Cleanup of Pending Orders
   if(!cleanupDoneToday)
     {
      Print("Exit Time Reached (Target 20:55 UTC). Deleting Pending Orders.");
      for(int s=0; s<ArraySize(symbols); s++) DeleteOrders(symbols[s]);
      cleanupDoneToday = true;
     }

   // B. Close All Open Positions
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            // Close the position
            if(trade.PositionClose(ticket))
              {
               Print("Closed position: " + PositionGetString(POSITION_SYMBOL));
              }
            else
              {
               Print("Failed to close position: " + PositionGetString(POSITION_SYMBOL) + ", Error: " + IntegerToString(trade.ResultRetcode()));
              }
           }
        }
     }
  }

void RunDailyEntryLogic()
  {
   Print("Starting Daily NR4 Scan (Target 22:00 UTC)...");
   for(int i=0; i<ArraySize(symbols); i++)
     {
      DeleteOrders(symbols[i]); // Clean up any existing pending orders before new entries
      ProcessStrategy(symbols[i], atrHandles[i]);
     }
  }

void ProcessStrategy(string sym, int handle)
  {
   // ... (Omitted for brevity - same NR4 logic as before) ...
   if(SeriesInfoInteger(sym, PERIOD_D1, SERIES_BARS_COUNT) < 20) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(sym, PERIOD_D1, 1, 5, high) < 5 || CopyLow(sym, PERIOD_D1, 1, 5, low) < 5) return;

   double r1 = high[0] - low[0]; 
   double r2 = high[1] - low[1];
   double r3 = high[2] - low[2];
   double r4 = high[3] - low[3];
   
   if(r1 < r2 && r1 < r3 && r1 < r4)
     {
      Print(sym + ": NR4 Detected.");
      
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      // 20 pips buffer for JPY pairs (0.20), 20 points for others
      double buffer = (StringFind(sym, "JPY") >= 0) ? 0.20 : 0.0020;

      double buyTrigger = high[0] + buffer; 
      double sellTrigger = low[0] - buffer;
      
      double atr[];
      ArraySetAsSeries(atr, true);
      CopyBuffer(handle, 0, 1, 1, atr);
      double stopDist = atr[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize(sym);
      
      if(vol > 0)
        {
         datetime expiryTime = GetOrderExpiryTimeServer();
         
         // BUY STOP
         if(trade.BuyStop(vol, buyTrigger, sym, buyTrigger-stopDist, 0, ORDER_TIME_SPECIFIED, expiryTime))
           {
            Print(sym + " - BUY STOP placed @ " + DoubleToString(buyTrigger, _Digits) + " (SL: " + DoubleToString(buyTrigger-stopDist, _Digits) + ", Expires: " + TimeToString(expiryTime) + ")");
           }
         
         // SELL STOP
        //  if(trade.SellStop(vol, sellTrigger, sym, sellTrigger+stopDist, 0, ORDER_TIME_SPECIFIED, expiryTime))
        //    {
        //     Print(sym + " - SELL STOP placed @ " + DoubleToString(sellTrigger, _Digits) + " (SL: " + DoubleToString(sellTrigger+stopDist, _Digits) + ", Expires: " + TimeToString(expiryTime) + ")");
        //    }
        }
     }
  }

void DeleteOrders(string sym)
  {
   for(int i=OrdersTotal()-1; i>=0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket)) {
         if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
            trade.OrderDelete(ticket);
      }
   }
  }

double CalculateLotSize(string sym)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double targetExposure = equity * LevPerPair; 
   double vol = targetExposure / 100000.0; 
   
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   vol = MathFloor(vol / step) * step;
   
   double min = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(vol < min) vol = min;
   
   return vol;
  }
//+------------------------------------------------------------------+