//+------------------------------------------------------------------+
//|                                     NR4_SinglePair_MT5.mq5       |
//|               Single-Currency NR4 Strategy (Chart Specific)      |
//|                                      Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
// Note: LevPerPair replaces TotalLeverage since we are now isolated per chart
input double   LevPerPair     = 4.0;      // Leverage Allocation for THIS pair (e.g., 2.0 = 2x equity)
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input int      HoldDays       = 1;        // Days to Hold
input int      MagicNumber    = 888888;   // Unique ID
input int      StartHour      = 2;        // Server Hour to Start
input int      StartMinute    = 5;        // Server Minute to Start
input int      CloseHour      = 23;       // Server Hour to Force Close (Exit Only)
input int      CloseMinute    = 55;       // Server Minute to Force Close (Exit Only)
input int      PipsBuffer     = 20;       // Pips buffer

// --- GLOBALS ---
CTrade         trade;
datetime       lastProcessedDay = 0;
string         mySymbol; 
int            atrHandle;

int OnInit()
  {
   mySymbol = _Symbol; // Automatically use the symbol of the chart the EA is on
   lastProcessedDay = iTime(mySymbol, PERIOD_D1, 0);
   
   // Create ATR Handle
   atrHandle = iATR(mySymbol, PERIOD_D1, 14);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle for ", mySymbol);
      return(INIT_FAILED);
     }
     
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   Print("NR4 Single-Pair EA Initialized for: ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   // 1. Check Time Exit
   CheckTimeExits();

   // 2. Entry Logic: Run ONLY when a new Daily Bar appears
   // This replaces the StartHour check with the robust New Bar check

   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   // If the bar time has changed, it's a new day
   if(currentBarDate != lastProcessedDay && dt.hour >= StartHour && dt.min >= StartMinute)
     {
      // Clean slate first
      DeletePendingOrders();
      
      // Run Strategy
      ProcessStrategy();
      
      // Mark today as processed
      lastProcessedDay = currentBarDate;
     }
  }

void ProcessStrategy()
  {
   // Check if data is ready
   if(SeriesInfoInteger(mySymbol, PERIOD_D1, SERIES_BARS_COUNT) < 20) return;
   // Get price data
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   // Copy last 5 candles. If not enough data, exit.
   if(CopyHigh(mySymbol, PERIOD_D1, 1, 5, high) < 5 || CopyLow(mySymbol, PERIOD_D1, 1, 5, low) < 5) return;

   // Index 0 in our arrays = Yesterday (because we copied from index 1)
   double r1 = high[0] - low[0];
   double r2 = high[1] - low[1];
   double r3 = high[2] - low[2];
   double r4 = high[3] - low[3];

   // NR4 Logic
   if(r1 < r2 && r1 < r3 && r1 < r4)
     {
      Print("NR4 Pattern Detected on ", mySymbol);
      
      double point = SymbolInfoDouble(mySymbol, SYMBOL_POINT);
      
      // 20 points buffer
      double buffer = PipsBuffer * point; 

      double buyTrigger = high[0] + buffer;
      double sellTrigger = low[0] - buffer;
      
      // Get ATR for Stop Loss
      double atrVal[1];
      if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return;
      double stopDist = atrVal[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize();
      
      if(vol > 0)
        {
         // Expiration: Set to 23:59 of the current day
         datetime dayStart = iTime(mySymbol, PERIOD_D1, 0);
         datetime dayEnd = dayStart + 86400 - 60; 
         
         // Send Buy Stop Order
         if(trade.BuyStop(vol, buyTrigger, mySymbol, buyTrigger - stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
           {
            Print("Buy Stop Placed on ", mySymbol);
           }
         else
           {
            Print("Buy Stop Error: ", trade.ResultRetcode(), " Desc: ", trade.ResultRetcodeDescription());
           }
        // Send Sell Stop Order
        if(trade.SellStop(vol, sellTrigger, mySymbol, sellTrigger + stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
          {
           Print("Sell Stop Placed on ", mySymbol);
          }
        else
          {
           Print("Sell Stop Error: ", trade.ResultRetcode(), " Desc: ", trade.ResultRetcodeDescription());
          }
        }
     }
  }

void CheckTimeExits()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         // CRITICAL: Check Symbol match
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();
            
            double secondsElapsed = currentTime - openTime;
            double daysElapsed = secondsElapsed / 86400.0;
            
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);
            
            // Logic: Held for ~1 day AND it is the CloseHour
            if(daysElapsed >= HoldDays - 0.5 && dt.hour >= CloseHour && dt.min >= CloseMinute)
              {
               DeletePendingOrders();
               trade.PositionClose(ticket);
              }
           }
        }
     }
  }

void DeletePendingOrders()
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         if(OrderGetString(ORDER_SYMBOL) == mySymbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
           {
            trade.OrderDelete(ticket);
           }
        }
     }
  }

double CalculateLotSize()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Since this is per-chart, we use LevPerPair directly
   double targetExposure = equity * LevPerPair; 
   
   double contractSize = SymbolInfoDouble(mySymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize == 0) contractSize = 100000; 
   
   double vol = targetExposure / contractSize; 
   
   double step = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_STEP);
   double min = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MAX);
   
   if(step > 0)
      vol = MathFloor(vol / step) * step;
   
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
  }
//+------------------------------------------------------------------+