//+------------------------------------------------------------------+
//|                                       NR4_Monday_SinglePair.mq5  |
//|                 Monday-Only NR4 Strategy (Chart Specific)        |
//|                                   Copyright 2025, Risk Analyst   |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input double   LevPerPair     = 4.0;      // Leverage Allocation for THIS pair
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input string   direction      = "both";   // Direction to place order ("long", "short", "both")
input bool     BrokerMergesCandles = true; // Set to TRUE if broker has no Sunday candle
input int      HoldDays       = 1;        // Days to Hold
input int      StartHour      = 2;        // Server Hour to Start
input int      StartMinute    = 5;        // Server Minute to Start
input int      CloseHour      = 23;       // Server Hour to Force Close (Exit Only)
input int      CloseMinute    = 55;       // Server Minute to Force Close (Exit Only)
input int      PipsBuffer     = 20;       // Pips buffer
input int      MagicNumber    = 999999;   // Unique ID (Changed slightly for safety)

// --- GLOBALS ---
CTrade          trade;
datetime        lastProcessedDay = 0;
string          mySymbol; 
int             atrHandle;

int OnInit()
  {
   mySymbol = _Symbol; 
   lastProcessedDay = iTime(mySymbol, PERIOD_D1, 0);
   
   // Create ATR Handle
   atrHandle = iATR(mySymbol, PERIOD_D1, 14);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle for ", mySymbol);
      return(INIT_FAILED);
     }
      
   trade.SetExpertMagicNumber(MagicNumber);
   SetRobustFillingMode();
   
   Print("Monday-Only NR4 EA Initialized for: ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   // 1. Check Time Exit (Runs every tick to manage open positions)
   CheckTimeExits();

   // 2. Entry Logic: Run ONLY when a new Daily Bar appears
   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   datetime currentTime = TimeCurrent();
   
   // Structs to check hours and day of week
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   MqlDateTime barDt;
   TimeToStruct(currentBarDate, barDt); // We check the day of the BAR, not just current time

   // If the bar time has changed (New Day Detected) AND we are past start time
   if(currentBarDate != lastProcessedDay && dt.hour >= StartHour && dt.min >= StartMinute)
     {
      // --- MONDAY CHECK ---
      // 1 = Monday. We only want to execute analysis if today is Monday.
      if(barDt.day_of_week == 1) 
        {
         Print("New Monday Bar detected on ", mySymbol, ". Checking Sunday NR4...");
         
         // Clean slate first
         DeletePendingOrders();
         
         // Run Strategy (Checks indices 1,2,3,4 -> Sun, Fri, Thu, Wed)
         ProcessStrategy();
        }
      else
        {
         // Optional: Print that we are skipping this day
         // Print("New Bar detected, but it is not Monday (Day ", barDt.day_of_week, "). Skipping.");
        }
      
      // Mark today as processed so we don't check again until the next day
      lastProcessedDay = currentBarDate;
     }
  }

void SetRobustFillingMode()
{
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
   {
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   }
   else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
   {
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   }
   else
   {
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   }
}

void ProcessStrategy()
{
   if(SeriesInfoInteger(mySymbol, PERIOD_D1, SERIES_BARS_COUNT) < 20) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   // We copy 5 bars. 
   // If Merged: We need Index 0 (Current) + 1,2,3 (Fri, Thu, Wed)
   // If Distinct: We need Index 1 (Sun) + 2,3,4 (Fri, Thu, Wed)
   if(CopyHigh(mySymbol, PERIOD_D1, 0, 6, high) < 6 || CopyLow(mySymbol, PERIOD_D1, 0, 6, low) < 6) return;

   double r1, r2, r3, r4;
   double sundayHigh, sundayLow;

   if (BrokerMergesCandles)
   {
      // --- LOGIC FOR MERGED BROKERS ---
      // We assume "Sunday" is the range formed from Market Open until NOW (Index 0)
      r1 = high[0] - low[0]; // Current incomplete bar (Sunday/Early Mon)
      r2 = high[1] - low[1]; // Friday
      r3 = high[2] - low[2]; // Thursday
      r4 = high[3] - low[3]; // Wednesday
      
      sundayHigh = high[0];
      sundayLow  = low[0];
      Print("Merged Mode: Checking Current Range (Index 0) vs Fri/Thu/Wed");
   }
   else
   {
      // --- LOGIC FOR NON-MERGED BROKERS ---
      // We look at the closed bars starting from Index 1
      r1 = high[1] - low[1]; // Sunday (Closed)
      r2 = high[2] - low[2]; // Friday
      r3 = high[3] - low[3]; // Thursday
      r4 = high[4] - low[4]; // Wednesday
      
      sundayHigh = high[1];
      sundayLow  = low[1];
      Print("Standard Mode: Checking Closed Range (Index 1) vs Fri/Thu/Wed");
   }

   // NR4 Calculation
   if(r1 < r2 && r1 < r3 && r1 < r4)
   {
      Print("NR4 Pattern Detected! Range: ", r1);
      
      double point = SymbolInfoDouble(mySymbol, SYMBOL_POINT);
      double buffer = PipsBuffer * point; 
      
      double buyTrigger  = sundayHigh + buffer;
      double sellTrigger = sundayLow - buffer;
      
      // Stop Loss Logic (ATR)
      double atrVal[1];
      if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return;
      double stopDist = atrVal[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize();
      if(vol <= 0) return;

      datetime dayStart = iTime(mySymbol, PERIOD_D1, 0);
      datetime dayEnd = dayStart + 86400 - 60; 
      
      // --- BUY LOGIC ---
      if (direction == "both" || direction == "long") 
      {
         if(!trade.BuyStop(vol, buyTrigger, mySymbol, buyTrigger - stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
            Print("Buy Stop Failed: ", trade.ResultRetcode());
         else
            Print("Buy Stop Placed at ", buyTrigger);
      }
      
      // --- SELL LOGIC ---
      if (direction == "both" || direction == "short")
      {
         if(!trade.SellStop(vol, sellTrigger, mySymbol, sellTrigger + stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
            Print("Sell Stop Failed: ", trade.ResultRetcode());
         else
            Print("Sell Stop Placed at ", sellTrigger);
      }
   }
   else
   {
       Print("No NR4. R1:", r1, " R2:", r2, " R3:", r3, " R4:", r4);
   }
}

void CheckTimeExits()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();
            
            double secondsElapsed = currentTime - openTime;
            double daysElapsed = secondsElapsed / 86400.0;
            
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);
            
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
   double targetExposure = equity * LevPerPair; 
   
   double contractSize = SymbolInfoDouble(mySymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double price        = SymbolInfoDouble(mySymbol, SYMBOL_ASK);
   
   if(contractSize == 0 || price == 0) return 0;

   ENUM_SYMBOL_CALC_MODE calcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(mySymbol, SYMBOL_TRADE_CALC_MODE);
   string symbolUpper = mySymbol;
   StringToUpper(symbolUpper);

   double vol = 0;

   if (StringFind(symbolUpper, "XAU") >= 0 || StringFind(symbolUpper, "GOLD") >= 0 || 
       StringFind(symbolUpper, "US30") >= 0 || StringFind(symbolUpper, "JP225") >= 0 ||
       calcMode == SYMBOL_CALC_MODE_CFD || calcMode == SYMBOL_CALC_MODE_CFDINDEX)
   {
      vol = targetExposure / (contractSize * price);
   }
   else
   {
      vol = targetExposure / contractSize;
   }
      
   double step = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MAX);
   
   if(step > 0)
      vol = MathFloor(vol / step) * step;
      
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
}