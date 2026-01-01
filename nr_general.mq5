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
input int      NR_Period      = 4;        // Number of NR periods
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input double   Entry_ATR_Buffer     = 0.2;       // Entry ATR Buffer
input string   direction = "both"; // Direction to place order
input int      Max_Spread_Points = 30;  // Max allowed spread in Points (e.g. 30 = 3 pips)
input int      MinHoldHours = 12; // Minimum hours to hold
input int      StartHour      = 2;        // Server Hour to Start
input int      StartMinute    = 5;        // Server Minute to Start
input int      CloseHour      = 23;       // Server Hour to Force Close (Exit Only)
input int      CloseMinute    = 55;       // Server Minute to Force Close (Exit Only)
input int      MagicNumber    = 888888;   // Unique ID
input bool     EnablePush       = true;  // Enable phone notifications
input int      NotifyHour       = 8;     // Server hour to send daily heartbeat (0-23)


// --- GLOBALS ---
CTrade         trade;
datetime       lastProcessedDay = 0;
string         mySymbol; 
int            atrHandle;

int OnInit()
  {
   mySymbol = _Symbol; // Automatically use the symbol of the chart the EA is on
   lastProcessedDay = iTime(mySymbol, PERIOD_D1, 0);

   // 1. Confirm VPS Startup
   if(EnablePush) {
      string host = MQLInfoInteger(MQL_TESTER) ? "Tester" : "Live/VPS";
      SendNotification(StringFormat("🚀 EA Started on %s. Magic: %d. Balance: %.2f", host, MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE)));
   }
   
   // Create ATR Handle
   atrHandle = iATR(mySymbol, PERIOD_D1, 14);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle for ", mySymbol);
      return(INIT_FAILED);
     }
     
   trade.SetExpertMagicNumber(MagicNumber);
   SetRobustFillingMode();
   
   Print("NR4 Single-Pair EA Initialized for: ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   // --- HEARTBEAT LOGIC START ---
   static datetime lastNotifyTime = 0;
   datetime currentTime = TimeCurrent();
   
   // 1. Spam protection: Ensure we haven't notified in the last hour
   // (Safety mechanism to prevent draining phone battery if logic fails)
   if(EnablePush && (currentTime - lastNotifyTime) > 3600) 
   {
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);

      // 2. Check if it is the target hour (e.g., 08:00 AM)
      if(dt.hour == NotifyHour) 
      {
         string msg = "";
         
         // 1. Construct Message with StringFormat
         if(dt.day_of_week == 1) { 
            // Monday Message
            msg = StringFormat("🟢 Mon. Magic: %d. SCANNING. Bal: %.2f", MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE));
         }
         else {
            // Standby Message
            msg = StringFormat("💤 Alive. Magic: %d. Standby. Bal: %.2f", MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE));
         }
         
         // 2. Send or Print (Your Code)
         if(SendNotification(msg)) {
            lastNotifyTime = currentTime; 
         }
         else if(MQLInfoInteger(MQL_TESTER)) {
            // This prints to the Journal tab in Strategy Tester
            Print("✅ [TESTER-ONLY] ", msg);
            lastNotifyTime = currentTime; 
         }
      }
   }
   // --- HEARTBEAT LOGIC END ---
   
   // Get current spread in points
   int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   // Check if spread exceeds limit
   if(currentSpread > Max_Spread_Points)
   {
      // Optional: Print to journal so you know why it's silent (don't spam this on every tick)
      // Print("Spread too high: ", currentSpread, " pts. Filter Active.");
      return; // EXIT FUNCTION IMMEDIATELY
   }
   
   // 1. Check Time Exit
   CheckTimeExits();

   // 2. Entry Logic: Run ONLY when a new Daily Bar appears
   // This replaces the StartHour check with the robust New Bar check

   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   //datetime currentTime = TimeCurrent();
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

void SetRobustFillingMode()
{
   // Check what the symbol supports
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
   {
      trade.SetTypeFilling(ORDER_FILLING_FOK);
      Print("Filling Mode set to: FOK");
   }
   else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
   {
      trade.SetTypeFilling(ORDER_FILLING_IOC);
      Print("Filling Mode set to: IOC");
   }
   else
   {
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
      Print("Filling Mode set to: RETURN");
   }
}

// Replace your ProcessStrategy with this robust version:
void ProcessStrategy()
{
   if(SeriesInfoInteger(mySymbol, PERIOD_D1, SERIES_BARS_COUNT) < NR_Period + 5) return;

   if(EnablePush) {
      string host = MQLInfoInteger(MQL_TESTER) ? "Tester" : "Live/VPS";
      SendNotification(StringFormat("🚀 Bot started processing %s. Magic: %d. Balance: %.2f", host, MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE)));
   }
   
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   // if(CopyHigh(mySymbol, PERIOD_D1, 1, 5, high) < 5 || CopyLow(mySymbol, PERIOD_D1, 1, 5, low) < 5) return;
   if(CopyHigh(mySymbol, PERIOD_D1, 1, NR_Period, high) < NR_Period || 
      CopyLow(mySymbol, PERIOD_D1, 1, NR_Period, low) < NR_Period) 
      return;
      
   double currentRange = high[0] - low[0];
   bool isNR = true;
   double highestHigh = -9999999;
   double lowestLow = 9999999;
   
   for(int i = 1; i < NR_Period; i++)
   {
      double prevRange = high[i] - low[i];
      if (high[i] > highestHigh) {highestHigh = high[i];}
      if (low[i] < lowestLow) {highestHigh = high[i];}
      
      // If the current range is NOT smaller than a previous range, it is not an NR pattern
      if(currentRange >= prevRange)
      {
         isNR = false;
         break; // Stop checking, pattern failed
      }
   }

   if(isNR)
   {
      Print("NR4 Pattern Detected on ", mySymbol);
      
      // Stop Loss Logic
      double atrVal[1];
      if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return;
      double stopDist = atrVal[0] * ATR_Multiplier;
      
      double point = SymbolInfoDouble(mySymbol, SYMBOL_POINT);
      double ask   = SymbolInfoDouble(mySymbol, SYMBOL_ASK);
      double bid   = SymbolInfoDouble(mySymbol, SYMBOL_BID);
      
      double buffer = Entry_ATR_Buffer * atrVal[0]; 
      double buyTrigger = high[0] + buffer;
      double sellTrigger = low[0] - buffer;
      
      
      
      double vol = CalculateLotSize();
      if(vol <= 0) 
      {
         Print("Error: Lot Size calculated as 0. Check Equity/Leverage settings.");
         return;
      }

      datetime dayStart = iTime(mySymbol, PERIOD_D1, 0);
      datetime dayEnd = dayStart + 86400 - 60; 
      
      // --- SMART BUY LOGIC ---
      // 1. If Ask is BELOW trigger, place Buy Stop (Normal)
      if (direction == "both" || direction == "long") 
      {
      //if(ask < buyTrigger)
      //{
         if(!trade.BuyStop(vol, buyTrigger, mySymbol, buyTrigger - stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
            Print("Buy Stop Failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         else
            Print("Buy Stop Placed at ", buyTrigger);
      //}
      // 2. If Ask is ABOVE trigger, we missed the breakout!
      // Option A: Enter Market immediately (Aggressive)
      // Option B: Skip trade (Conservative) -> We will skip to be safe.
      //else
      //{
      //   Print("Price already above Buy Trigger (Ask: ", ask, " > Trig: ", buyTrigger, "). Skipping Buy.");
      //}
      }
      // --- SMART SELL LOGIC ---
      if (direction == "both" || direction == "short")
      {
      //if(bid > sellTrigger)
      //{
         if(!trade.SellStop(vol, sellTrigger, mySymbol, sellTrigger + stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd))
            Print("Sell Stop Failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         else
            Print("Sell Stop Placed at ", sellTrigger);
      //}
      //else
      //{
      //   Print("Price already below Sell Trigger. Skipping Sell.");
      //}
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
         // 1. Symbol & Magic Check
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();
            
            // 2. MINIMUM DURATION FILTER
            // Forces late trades to hold overnight, boosting average duration to ~22h
            double hoursElapsed = (currentTime - openTime) / 3600.0;
            if(hoursElapsed < MinHoldHours) continue;

            // 3. TARGET EXIT WINDOW (23:55 - 23:59)
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);

            if(dt.hour == CloseHour && dt.min >= CloseMinute)
            {
               // Optional: Uncomment to avoid exiting during extreme spreads
               if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > Max_Spread_Points) continue;

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

//+------------------------------------------------------------------+
//| Smart Lot Size Calculation (Forex + Indices/Metals Safe)         |
//+------------------------------------------------------------------+
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

   // --- FORCE CFD MATH FOR GOLD/INDICES ---
   // If it's Gold (XAU), Silver (XAG), or an Index (US30, JP225), ALWAYS divide by Price.
   if (StringFind(symbolUpper, "XAU") >= 0 || StringFind(symbolUpper, "GOLD") >= 0 || 
       StringFind(symbolUpper, "US30") >= 0 || StringFind(symbolUpper, "JP225") >= 0 ||
       calcMode == SYMBOL_CALC_MODE_CFD || calcMode == SYMBOL_CALC_MODE_CFDINDEX)
   {
      // Correct Formula for Gold/Indices: Exposure / (Contract * Price)
      vol = targetExposure / (contractSize * price);
   }
   else
   {
      // Standard Forex (e.g. GBPJPY): Exposure / Contract
      vol = targetExposure / contractSize;
   }
     
   // --- NORMALIZE VOLUME ---
   double step = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MAX);
   
   if(step > 0)
      vol = MathFloor(vol / step) * step;
      
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
}
//+------------------------------------------------------------------+