//+------------------------------------------------------------------+
//|                                          NR4_Portfolio_Trend.mq5 |
//|             Multi-Currency NR4 Portfolio + 200 SMA Trend Filter  |
//|                                      Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input string   TradePairs     = "GBPJPY,USDJPY,EURJPY"; 
input double   LevPerPair     = 1.33;     
input double   ATR_Multiplier = 3.0;      
input int      HoldDays       = 1;        
input int      MagicNumber    = 888888;   
input int      StartHour      = 0;        
input int      CloseHour      = 23;       
input int      MA_Period      = 200;      // Trend Filter (Simple Moving Average)

// --- GLOBALS ---
CTrade         trade;
string         symbols[];
int            atrHandles[];
int            maHandles[];   // NEW: Handles for Moving Averages
datetime       lastProcessedDay = 0;

int OnInit()
  {
   StringSplit(TradePairs, ',', symbols);
   int total = ArraySize(symbols);
   ArrayResize(atrHandles, total);
   ArrayResize(maHandles, total); // Resize MA array
   
   for(int i=0; i<total; i++)
     {
      StringTrimLeft(symbols[i]);
      StringTrimRight(symbols[i]);
      if(!SymbolSelect(symbols[i], true)) Print("Failed select: ", symbols[i]);
      
      // Create ATR Handle
      atrHandles[i] = iATR(symbols[i], PERIOD_D1, 14);
      
      // Create MA Handle (200 SMA, Close Price)
      maHandles[i] = iMA(symbols[i], PERIOD_D1, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
      
      if(atrHandles[i] == INVALID_HANDLE || maHandles[i] == INVALID_HANDLE)
         Print("Error creating indicators for ", symbols[i]);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int i=0; i<ArraySize(atrHandles); i++) 
     {
      IndicatorRelease(atrHandles[i]);
      IndicatorRelease(maHandles[i]); // Release MA handles
     }
  }

void OnTick()
  {
   CheckTimeExits();

   datetime currentDay = iTime(symbols[0], PERIOD_D1, 0); 
   if(currentDay == lastProcessedDay) return; 
   
   lastProcessedDay = currentDay;
   
   for(int i=0; i<ArraySize(symbols); i++)
     {
      string sym = symbols[i];
      // Note: We do NOT use the OCO check here anymore, 
      // because the Trend Filter naturally selects direction.
      DeleteOrders(sym); 
      ProcessStrategy(sym, atrHandles[i], maHandles[i]); // Pass MA Handle
     }
  }

void CheckTimeExits()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();
            double secondsElapsed = currentTime - openTime;
            double daysElapsed = secondsElapsed / 86400.0;
            
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);
            
            if(daysElapsed >= HoldDays - 0.5 && dt.hour >= CloseHour)
              {
               trade.PositionClose(ticket);
              }
           }
        }
     }
  }

// Updated Strategy Function with Trend Logic
void ProcessStrategy(string sym, int atrHandle, int maHandle)
  {
   if(SeriesInfoInteger(sym, PERIOD_D1, SERIES_BARS_COUNT) < 205) return; // Need 200 bars for MA

   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true); // We need Close price for trend check
   
   if(CopyHigh(sym, PERIOD_D1, 1, 5, high) < 5 || 
      CopyLow(sym, PERIOD_D1, 1, 5, low) < 5 ||
      CopyClose(sym, PERIOD_D1, 1, 1, close) < 1) return;

   // NR4 Logic
   double r1 = high[0] - low[0]; 
   double r2 = high[1] - low[1];
   double r3 = high[2] - low[2];
   double r4 = high[3] - low[3];
   
   if(r1 < r2 && r1 < r3 && r1 < r4)
     {
      // --- TREND FILTER LOGIC ---
      double maVal[];
      ArraySetAsSeries(maVal, true);
      if(CopyBuffer(maHandle, 0, 1, 1, maVal) < 1) return;
      
      bool isUptrend = close[0] > maVal[0];
      bool isDowntrend = close[0] < maVal[0];
      // --------------------------

      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      double buyTrigger = high[0] + (20 * point); 
      double sellTrigger = low[0] - (20 * point);
      
      double atr[];
      ArraySetAsSeries(atr, true);
      CopyBuffer(atrHandle, 0, 1, 1, atr);
      double stopDist = atr[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize(sym);
      
      if(vol > 0)
        {
         datetime dayEnd = iTime(sym, PERIOD_D1, 0) + (24*60*60) - 60; 
         
         // Only place Buy Stop if Uptrend
         if(isUptrend)
            trade.BuyStop(vol, buyTrigger, sym, buyTrigger-stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd);
         
         // Only place Sell Stop if Downtrend
         if(isDowntrend)
            trade.SellStop(vol, sellTrigger, sym, sellTrigger+stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd);
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