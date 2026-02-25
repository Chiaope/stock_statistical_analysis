//+------------------------------------------------------------------+
//|                                       NR_MultiTimeframe_MT5.mq5  |
//|                  Multi-Timeframe NR Strategy (Chart Specific)    |
//|                                   Copyright 2025, Risk Analyst   |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input ENUM_TIMEFRAMES  InpTimeFrame   = PERIOD_H4;   // Strategy Timeframe
input int              NR_Period      = 4;           // NR Pattern Size (e.g., 4=NR4, 7=NR7)
input double           LevPerPair     = 4.0;         // Leverage Allocation (e.g., 2.0 = 2x equity)
input int              Entry_ATR_Buffer     = 0.2;         // Entry Buffer (Points/Pips)
input double           ATR_Multiplier = 5.0;         // Stop Loss Width (x ATR)
input string           direction      = "both";      // Direction ("both", "long", "short")

// --- EXIT SETTINGS ---
// Note: Since we close on every new candle, HoldDays is less relevant 
// but kept if you want to force close at specific hours intra-candle.
input int      CloseHour      = 23;         // Force Close Hour (Server Time)
input int      CloseMinute    = 55;         // Force Close Minute (Server Time)
input int      MagicNumber    = 888888;     // Unique ID

// --- GLOBALS ---
CTrade         trade;
datetime       lastProcessedBarTime = 0;
string         mySymbol; 
int            atrHandle;

int OnInit()
  {
   mySymbol = _Symbol; 
   
   // Check current bars on the selected timeframe
   lastProcessedBarTime = iTime(mySymbol, InpTimeFrame, 0);
   
   // Create ATR Handle using the USER SELECTED TimeFrame
   atrHandle = iATR(mySymbol, InpTimeFrame, 14);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle for ", mySymbol);
      return(INIT_FAILED);
     }
      
   trade.SetExpertMagicNumber(MagicNumber);
   SetRobustFillingMode();
   
   Print("NR", NR_Period, " Strategy Initialized on ", EnumToString(InpTimeFrame));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   // 1. New Bar Logic (Updated for selected TimeFrame)
   datetime currentBarTime = iTime(mySymbol, InpTimeFrame, 0);
   
   // If the bar time has changed, it is a NEW CANDLE
   if(lastProcessedBarTime != currentBarTime)
     {
      // A. CLOSE ALL OPEN POSITIONS (Market Orders)
      CloseAllPositions();

      // B. Delete pending orders (Limit/Stop orders from previous candle)
      DeletePendingOrders();
      
      // C. Run Strategy for the new candle
      ProcessStrategy();
      
      // Update tracker
      lastProcessedBarTime = currentBarTime;
     }
     
   // 2. Check Time Exit (Optional redundancy if you still want specific hour exits)
   // You can remove this line if you ONLY want to close on new candles.
   // CheckTimeExits(); 
  }

void SetRobustFillingMode()
{
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

void ProcessStrategy()
{
   // 1. Ensure enough history exists on the SELECTED timeframe
   if(SeriesInfoInteger(mySymbol, InpTimeFrame, SERIES_BARS_COUNT) < NR_Period + 5) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   // 2. Copy bars from the SELECTED timeframe
   if(CopyHigh(mySymbol, InpTimeFrame, 1, NR_Period, high) < NR_Period || 
      CopyLow(mySymbol, InpTimeFrame, 1, NR_Period, low) < NR_Period) 
      return;

   // 3. Dynamic NR Logic (Checks previous N bars)
   double currentRange = high[0] - low[0];
   bool isNR = true;

   for(int i = 1; i < NR_Period; i++)
   {
      double prevRange = high[i] - low[i];
      if(currentRange >= prevRange)
      {
         isNR = false;
         break; 
      }
   }

   // 4. Execution
   if(isNR)
   {
      Print("NR", NR_Period, " Pattern Detected on ", EnumToString(InpTimeFrame));

      double atrVal[1];
      if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return;

      double point = SymbolInfoDouble(mySymbol, SYMBOL_POINT);
      double buffer = atrVal[0] * Entry_ATR_Buffer; 
      double buyTrigger = high[0] + buffer;
      double sellTrigger = low[0] - buffer;
      
      // Stop Loss Logic (ATR from selected timeframe)
      double stopDist = atrVal[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize();
      if(vol <= 0) return;

      // 5. Expiration Logic: End of CURRENT Bar
      // If we are on H4, order expires in 4 hours. 
      datetime barStart = iTime(mySymbol, InpTimeFrame, 0);
      datetime barEnd   = barStart + PeriodSeconds(InpTimeFrame) - 1; 
      
      // --- SMART BUY LOGIC ---
      if (direction == "both" || direction == "long") 
      {
         if(!trade.BuyStop(vol, buyTrigger, mySymbol, buyTrigger - stopDist, 0, ORDER_TIME_SPECIFIED, barEnd))
            Print("Buy Stop Failed: ", trade.ResultRetcodeDescription());
      }
      
      // --- SMART SELL LOGIC ---
      if (direction == "both" || direction == "short")
      {
         if(!trade.SellStop(vol, sellTrigger, mySymbol, sellTrigger + stopDist, 0, ORDER_TIME_SPECIFIED, barEnd))
            Print("Sell Stop Failed: ", trade.ResultRetcodeDescription());
      }
   }
}

// --- NEW FUNCTION TO CLOSE ALL POSITIONS ---
void CloseAllPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         // Ensure we only close trades for THIS EA (Symbol + MagicNumber)
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            trade.PositionClose(ticket);
            Print("New Bar Detected. Closed Position: ", ticket);
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
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            // We removed HoldDays check here because the 'New Bar' logic handles the exit now.
            // This function is just a backup if you want to force close at a specific HOUR (e.g. 23:55)
            // regardless of the candle status.
            datetime currentTime = TimeCurrent();
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);
            
            if(dt.hour >= CloseHour && dt.min >= CloseMinute)
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
            trade.OrderDelete(ticket);
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
   
   if(step > 0) vol = MathFloor(vol / step) * step;
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
}