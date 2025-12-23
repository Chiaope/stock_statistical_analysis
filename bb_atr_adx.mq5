//+------------------------------------------------------------------+
//|                        BB_Reversion_Daily_Sniper.mq5             |
//|           Bollinger + ADX + Squeeze (Daily Timeframe)            |
//|                                   Copyright 2025, Risk Analyst   |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input double           LevPerPair       = 4.0;        // Leverage Allocation (e.g., 4.0x)
input string           direction        = "both";     // "both", "long", "short"

// --- STRATEGY PARAMETERS ---
input double           Compression_Factor = 1.1;      // Candle Range < (ATR * Factor)
input int              Bands_Period     = 20;         // BB Period
input double           Bands_Deviation  = 2.0;        // BB Deviation (Touch to trigger)
input double           ADX_Threshold    = 30.0;       // ADX must be below this (Range Filter)

// --- EXECUTION SETTINGS ---
input double           ATR_Multiplier   = 4.0;        // Stop Loss Width (x ATR)
input double           Entry_ATR_Buffer = 0.2;        // Buffer for Pending Order (x ATR)
input int              HoldDays         = 1;          // Days to Hold (Time Exit)

// --- TIME & ADMIN ---
input int              StartHour        = 2;          // Server Hour to Scan (New Day)
input int              StartMinute      = 5;          // Server Minute to Scan
input int              CloseHour        = 23;         // Force Close Hour
input int              CloseMinute      = 55;         // Force Close Minute
input int              MagicNumber      = 999111;     // Unique ID
input bool             EnablePush       = true;       // Enable phone notifications
input int              NotifyHour       = 8;          // Heartbeat Report Hour

// --- GLOBALS ---
CTrade         trade;
datetime       lastProcessedDay = 0;
string         mySymbol; 
int            atrHandle;
int            bbHandle;
int            adxHandle;

int OnInit()
  {
   mySymbol = _Symbol; 
   lastProcessedDay = iTime(mySymbol, PERIOD_D1, 0);

   if(EnablePush) {
      string host = MQLInfoInteger(MQL_TESTER) ? "Tester" : "Live/VPS";
      SendNotification(StringFormat("🚀 Daily Reversion EA Started on %s. Magic: %d", host, MagicNumber));
   }
   
   // --- CREATE INDICATORS (All Forced to D1) ---
   atrHandle = iATR(mySymbol, PERIOD_D1, 14);
   bbHandle  = iBands(mySymbol, PERIOD_D1, Bands_Period, 0, Bands_Deviation, PRICE_CLOSE);
   adxHandle = iADX(mySymbol, PERIOD_D1, 14);

   if(atrHandle == INVALID_HANDLE || bbHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
     {
      Print("Error creating indicator handles.");
      return(INIT_FAILED);
     }
      
   trade.SetExpertMagicNumber(MagicNumber);
   SetRobustFillingMode();
   
   Print("Daily Reversion Strategy Initialized on ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
   IndicatorRelease(bbHandle);
   IndicatorRelease(adxHandle);
  }

void OnTick()
  {
   // 1. Exit Logic (Time-based or Mean Reversion Targets if you wanted to add them)
   CheckTimeExits();
   
   // 2. Heartbeat Logic
   ProcessHeartbeat();

   // 3. New Day Scanning Logic
   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   MqlDateTime dt;
   TimeCurrent(dt);

   // Check if it's a new day AND we are past the Start Time
   if(currentBarDate != lastProcessedDay && dt.hour >= StartHour && dt.min >= StartMinute)
     {
      // A. Clean up old pending orders (they expired yesterday)
      DeletePendingOrders();
      
      // B. Scan for new setup
      ProcessStrategy();
      
      // C. Mark day as processed
      lastProcessedDay = currentBarDate;
     }
  }

// --- CORE STRATEGY ---
void ProcessStrategy()
{
   if(SeriesInfoInteger(mySymbol, PERIOD_D1, SERIES_BARS_COUNT) < Bands_Period + 5) return;

   // 1. Get Price Data (Yesterday's Closed Candle -> Index 1)
   double high[], low[], close[];
   ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
   
   if(CopyHigh(mySymbol, PERIOD_D1, 1, 1, high) < 1 || 
      CopyLow(mySymbol, PERIOD_D1, 1, 1, low) < 1 ||
      CopyClose(mySymbol, PERIOD_D1, 1, 1, close) < 1) return;
      
   // 2. Get Indicator Data (Index 1)
   double atrVal[1], adxVal[1], upper[1], lower[1];
   if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1 || 
      CopyBuffer(adxHandle, 0, 1, 1, adxVal) < 1 ||
      CopyBuffer(bbHandle, 1, 1, 1, upper) < 1 || 
      CopyBuffer(bbHandle, 2, 1, 1, lower) < 1) return;

   // 3. Define Variables
   double YestHigh  = high[0];
   double YestLow   = low[0];
   double YestClose = close[0];
   double ATR       = atrVal[0];
   double ADX       = adxVal[0];
   double UpperBB   = upper[0];
   double LowerBB   = lower[0];
   double Range     = YestHigh - YestLow;

   // 4. Calculate Logic Conditions
   bool isRanging    = (ADX < ADX_Threshold); // Market is quiet (Safe to fade)
   bool isCompressed = (Range < (ATR * Compression_Factor)); // Candle is small (Exhaustion)
   
   // --- LOGIC GATES ---
   if(!isRanging) return;    // Filter: Trend is too strong
   if(!isCompressed) return; // Filter: Candle too big (Momentum, not exhaustion)

   // 5. Execution Setup
   double slDist = ATR * ATR_Multiplier;
   double buffer = ATR * Entry_ATR_Buffer;
   
   double vol = CalculateLotSize();
   if(vol <= 0) { Print("Err: Zero Volume"); return; }

   datetime dayEnd = iTime(mySymbol, PERIOD_D1, 0) + 86400 - 60; // Expire at end of today

   // --- SCENARIO A: SELL SETUP (Revert from Upper Band) ---
   // Logic: Price touched Upper Band -> Revert Down -> Sell Stop below Low
   if(YestHigh >= UpperBB || YestClose >= UpperBB)
   {
      if(direction == "both" || direction == "short")
      {
         double triggerPrice = YestLow - buffer;
         double stopLoss     = triggerPrice + slDist;
         
         if(trade.SellStop(vol, triggerPrice, mySymbol, stopLoss, 0, ORDER_TIME_SPECIFIED, dayEnd))
         {
            Print("SHORT Setup detected: Reverting from Upper Band.");
            if(EnablePush) SendNotification("SHORT Setup: " + mySymbol + " at Upper Band");
         }
      }
   }

   // --- SCENARIO B: BUY SETUP (Revert from Lower Band) ---
   // Logic: Price touched Lower Band -> Revert Up -> Buy Stop above High
   if(YestLow <= LowerBB || YestClose <= LowerBB)
   {
      if(direction == "both" || direction == "long")
      {
         double triggerPrice = YestHigh + buffer;
         double stopLoss     = triggerPrice - slDist;
         
         if(trade.BuyStop(vol, triggerPrice, mySymbol, stopLoss, 0, ORDER_TIME_SPECIFIED, dayEnd))
         {
            Print("LONG Setup detected: Reverting from Lower Band.");
            if(EnablePush) SendNotification("LONG Setup: " + mySymbol + " at Lower Band");
         }
      }
   }
}

// --- UTILITIES ---

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
            TimeCurrent(dt);
            
            // Exit if held for HoldDays AND it is late in the day
            if(daysElapsed >= HoldDays - 0.5 && dt.hour >= CloseHour && dt.min >= CloseMinute)
            {
               trade.PositionClose(ticket);
               Print("Time Exit Triggered");
            }
         }
      }
   }
}

void ProcessHeartbeat()
{
   static datetime lastNotifyTime = 0;
   datetime currentTime = TimeCurrent();
   
   if(EnablePush && (currentTime - lastNotifyTime) > 3600) 
   {
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);

      if(dt.hour == NotifyHour) 
      {
         string msg = StringFormat("💤 Alive. Magic: %d. Bal: %.2f", MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE));
         SendNotification(msg);
         lastNotifyTime = currentTime; 
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
            trade.OrderDelete(ticket);
      }
   }
}

void SetRobustFillingMode() {
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

double CalculateLotSize() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double targetExposure = equity * LevPerPair; 
   double contractSize = SymbolInfoDouble(mySymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double price        = SymbolInfoDouble(mySymbol, SYMBOL_ASK);
   if(contractSize == 0 || price == 0) return 0;

   ENUM_SYMBOL_CALC_MODE calcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(mySymbol, SYMBOL_TRADE_CALC_MODE);
   string sym = mySymbol; StringToUpper(sym);
   double vol = 0;
   
   if (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0 || calcMode == SYMBOL_CALC_MODE_CFD)
      vol = targetExposure / (contractSize * price);
   else
      vol = targetExposure / contractSize;
      
   double step = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(mySymbol, SYMBOL_VOLUME_MAX);
   
   if(step > 0) vol = MathFloor(vol / step) * step;
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   return vol;
}