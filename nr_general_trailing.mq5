//+------------------------------------------------------------------+
//|                             NR4_MultiTF_Trailing_MT5.mq5         |
//|               Multi-Timeframe NR4 Strategy (Trailing Stop)       |
//|                        Copyright 2025, Risk Analyst              |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "3.10" // Version bumped for Trailing Stop
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_D1;    // Strategy Timeframe (D1, H4, etc.)
input double    LevPerPair       = 4.0;       // Leverage Allocation
input int       NR_Period        = 4;         // Number of NR periods
input double    ATR_Multiplier   = 5.0;       // Initial Stop Loss Width (x ATR)

// --- TRAILING STOP SETTINGS ---
input bool      UseTrailingStop  = true;      // Enable ATR Trailing Stop?
input double    Trailing_ATR_Mult= 2.0;       // Trailing Distance (x ATR)
input bool      UseFixedTP       = false;     // Use Fixed TP? (False = Unlimited Run)
input double    TP_Multiplier    = 5.0;       // Take Profit Width (Used if UseFixedTP=true)

input double    Entry_ATR_Buffer = 0.2;       // Entry ATR Buffer
input string    direction        = "both";    // Direction: "both", "long", "short"
input int       Max_Spread_Points= 30;        // Max allowed spread in Points

// TIME FILTER
input int       StartHour        = 2;         // Server Hour to Start (-1 to disable)
input int       StartMinute      = 5;         // Server Minute to Start

input int       MagicNumber      = 888888;    // Unique ID
input bool      EnablePush       = true;      // Enable phone notifications
input int       NotifyHour       = 8;         // Server hour to send daily heartbeat

// --- GLOBALS ---
CTrade          trade;
datetime        lastProcessedBarTime = 0;
string          mySymbol; 
int             atrHandle;

int OnInit()
  {
   mySymbol = _Symbol; 
   lastProcessedBarTime = iTime(mySymbol, InpTimeframe, 0);

   if(EnablePush) {
      string host = MQLInfoInteger(MQL_TESTER) ? "Tester" : "Live/VPS";
      SendNotification(StringFormat("🚀 EA Started (Trailing Mode). Magic: %d", MagicNumber));
   }
   
   // Create ATR Handle
   atrHandle = iATR(mySymbol, InpTimeframe, 14);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR handle.");
      return(INIT_FAILED);
     }
      
   trade.SetExpertMagicNumber(MagicNumber);
   SetRobustFillingMode();
   
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   // --- 1. ALWAYS CHECK TRAILING STOP (Every Tick) ---
   if(UseTrailingStop) ApplyTrailingStop();

   // --- HEARTBEAT LOGIC ---
   static datetime lastNotifyTime = 0;
   datetime currentTime = TimeCurrent();
   
   if(EnablePush && (currentTime - lastNotifyTime) > 3600) 
   {
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);
      if(dt.hour == NotifyHour) 
      {
         string msg = StringFormat("🟢 Bot Alive. Magic: %d. Bal: %.2f", MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE));
         if(SendNotification(msg)) lastNotifyTime = currentTime; 
      }
   }
   
   // --- 2. ENTRY LOGIC (Only New Bar) ---
   int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > Max_Spread_Points) return; 
   
   datetime currentBarDate = iTime(mySymbol, InpTimeframe, 0);
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);

   if(currentBarDate != lastProcessedBarTime)
     {
      if(StartHour >= 0 && dt.hour != StartHour) return;
      if(StartHour >= 0 && dt.min < StartMinute) return;

      DeletePendingOrders(); // Clean up old pending orders
      ProcessStrategy();     // Look for new NR4 entries
      
      lastProcessedBarTime = currentBarDate;
     }
  }

// --- NEW TRAILING STOP FUNCTION ---
void ApplyTrailingStop()
{
   // Get latest ATR for dynamic calculation
   double atrVal[1];
   // We use index 1 (completed bar) to avoid stop jumping too wildly
   if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return; 
   
   double trailDist = atrVal[0] * Trailing_ATR_Mult;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == mySymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            long posType = PositionGetInteger(POSITION_TYPE);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentPrice = 0;
            double newSL = 0;
            bool modify = false;

            if(posType == POSITION_TYPE_BUY)
            {
               currentPrice = SymbolInfoDouble(mySymbol, SYMBOL_BID);
               newSL = currentPrice - trailDist;
               
               // Only move SL UP (Protect Profit)
               if(newSL > currentSL && newSL < currentPrice) 
               {
                  modify = true;
               }
            }
            else if(posType == POSITION_TYPE_SELL)
            {
               currentPrice = SymbolInfoDouble(mySymbol, SYMBOL_ASK);
               newSL = currentPrice + trailDist;
               
               // Only move SL DOWN (Protect Profit)
               if((newSL < currentSL || currentSL == 0) && newSL > currentPrice)
               {
                  modify = true;
               }
            }

            if(modify)
            {
               if(!trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
                  Print("Failed to trail SL: ", trade.ResultRetcodeDescription());
            }
         }
      }
   }
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
   if(SeriesInfoInteger(mySymbol, InpTimeframe, SERIES_BARS_COUNT) < NR_Period + 5) return;

   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(mySymbol, InpTimeframe, 1, NR_Period, high) < NR_Period || 
      CopyLow(mySymbol, InpTimeframe, 1, NR_Period, low) < NR_Period) 
      return;
      
   double currentRange = high[0] - low[0];
   bool isNR = true;
   
   for(int i = 1; i < NR_Period; i++)
   {
      if(currentRange >= (high[i] - low[i])) { isNR = false; break; }
   }

   if(isNR)
   {
      double atrVal[1];
      if(CopyBuffer(atrHandle, 0, 1, 1, atrVal) < 1) return;
      
      double stopDist = atrVal[0] * ATR_Multiplier;   
      double tpDist   = (UseFixedTP) ? (atrVal[0] * TP_Multiplier) : 0; // 0 means Unlimited
      
      double buffer = Entry_ATR_Buffer * atrVal[0]; 
      double buyTrigger = high[0] + buffer;
      double sellTrigger = low[0] - buffer;
      
      double vol = CalculateLotSize();
      if(vol <= 0) return;

      datetime dayEnd = iTime(mySymbol, PERIOD_D1, 0) + 86400 - 60; 
      
      // BUY SETUP
      if (direction == "both" || direction == "long") 
      {
         double finalTP = (UseFixedTP) ? (buyTrigger + tpDist) : 0;
         trade.BuyStop(vol, buyTrigger, mySymbol, buyTrigger - stopDist, finalTP, ORDER_TIME_SPECIFIED, dayEnd);
      }
      
      // SELL SETUP
      if (direction == "both" || direction == "short")
      {
         double finalTP = (UseFixedTP) ? (sellTrigger - tpDist) : 0;
         trade.SellStop(vol, sellTrigger, mySymbol, sellTrigger + stopDist, finalTP, ORDER_TIME_SPECIFIED, dayEnd);
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
   
   string symbolUpper = mySymbol;
   StringToUpper(symbolUpper);
   ENUM_SYMBOL_CALC_MODE calcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(mySymbol, SYMBOL_TRADE_CALC_MODE);

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