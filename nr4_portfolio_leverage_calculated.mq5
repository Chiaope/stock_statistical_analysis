//+------------------------------------------------------------------+
//|                                            NR4_Portfolio_Fix.mq5 |
//|                   Multi-Currency NR4 Portfolio (Python Aligned)  |
//|                                      Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input string   TradePairs     = "GBPJPY,USDJPY,EURJPY"; 
input double   TotalLeverage     = 1.33;     
input double   ATR_Multiplier = 3.0;      
input int      HoldDays       = 1;        
input int      MagicNumber    = 888888;   
input int      CloseHour      = 23;       // Hour to Force Close (Server Time)

// --- GLOBALS ---
CTrade         trade;
string         symbols[];
int            atrHandles[];
datetime       lastProcessedDay = 0;

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

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int i=0; i<ArraySize(atrHandles); i++) IndicatorRelease(atrHandles[i]);
  }

void OnTick()
  {
   // Check Time Exit constantly (every tick)
   CheckTimeExits();

   // Entry Logic: Only run once per day, after the new bar opens
   datetime currentDay = iTime(symbols[0], PERIOD_D1, 0); // Use first symbol as master clock
   if(currentDay == lastProcessedDay) return; 
   
   lastProcessedDay = currentDay;
   
   // Loop through portfolio
   for(int i=0; i<ArraySize(symbols); i++)
     {
      string sym = symbols[i];
      // Close old pending orders from yesterday
      DeleteOrders(sym);
      // Scan for new setups
      ProcessStrategy(sym, atrHandles[i]);
     }
  }

// --- LOGIC: CLOSE AT END OF DAY (Matches Python) ---
void CheckTimeExits()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            // Calculate how many days have passed
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();
            
            // Convert to Days (86400 seconds)
            double secondsElapsed = currentTime - openTime;
            double daysElapsed = secondsElapsed / 86400.0;
            
            // LOGIC: If we have held for 'HoldDays' AND it is late in the day (CloseHour)
            // Python 'closes[i]' implies closing at the end of that day.
            
            MqlDateTime dt;
            TimeToStruct(currentTime, dt);
            
            // If we are in the target Hold Day (or later) AND it is the closing hour
            if(daysElapsed >= HoldDays - 0.5 && dt.hour >= CloseHour)
              {
               trade.PositionClose(ticket);
              }
           }
        }
     }
  }

void ProcessStrategy(string sym, int handle)
  {
   // Check if data is ready
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
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      double buyTrigger = high[0] + (20 * point); 
      double sellTrigger = low[0] - (20 * point);
      
      double atr[];
      ArraySetAsSeries(atr, true);
      CopyBuffer(handle, 0, 1, 1, atr);
      double stopDist = atr[0] * ATR_Multiplier;
      
      double vol = CalculateLotSize(sym);
      
      if(vol > 0)
        {
         // Expiration must be END OF TODAY. 
         // If not triggered by tonight, the NR4 setup is invalid.
         datetime dayEnd = iTime(sym, PERIOD_D1, 0) + (24*60*60) - 60; // 23:59 tonight
         
         trade.BuyStop(vol, buyTrigger, sym, buyTrigger-stopDist, 0, ORDER_TIME_SPECIFIED, dayEnd);
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
   int length = ArraySize(symbols);
   double targetExposure = equity * TotalLeverage / length; 
   double vol = targetExposure / 100000.0; 
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   vol = MathFloor(vol / step) * step;
   double min = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(vol < min) vol = min;
   return vol;
  }
//+------------------------------------------------------------------+