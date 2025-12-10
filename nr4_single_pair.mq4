//+------------------------------------------------------------------+
//|                               NR4_SinglePair_MT4_BarCheck.mq4    |
//|               Single-Currency NR4 Strategy (New Bar Logic)       |
//|                                      Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "1.01"
#property strict

// --- INPUTS ---
input double   LevPerPair     = 1.33;     // Leverage Allocation for THIS pair
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input int      HoldDays       = 1;        // Days to Hold
input int      MagicNumber    = 888888;   // Unique ID
input int      CloseHour      = 23;       // Server Hour to Close Trades (Exit Logic Only)
input int      Slippage       = 5;        // Slippage in Pips

// --- GLOBALS ---
datetime       lastProcessedDay = 0;
string         mySymbol; 

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   mySymbol = Symbol();
   Print("NR4 EA Initialized for: ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Check Time Exit (Still needs specific hour check for closing)
   CheckTimeExits();

   // 2. Entry Logic: Run ONLY when a new Daily Bar appears
   // This replaces the StartHour check with the robust New Bar check
   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   
   if(currentBarDate != lastProcessedDay)
     {
      // A new daily candle has opened!
      
      // Clean slate first
      DeletePendingOrders();
      
      // Run Strategy
      ProcessStrategy();
      
      // Mark today as processed so we don't run again until tomorrow
      lastProcessedDay = currentBarDate;
     }
  }

//+------------------------------------------------------------------+
//| Core Strategy Logic                                              |
//+------------------------------------------------------------------+
void ProcessStrategy()
  {
   if(iBars(mySymbol, PERIOD_D1) < 20) return;

   // Index 1 = Yesterday (The completed candle we analyze)
   double h1 = iHigh(mySymbol, PERIOD_D1, 1);
   double l1 = iLow(mySymbol, PERIOD_D1, 1);
   double r1 = h1 - l1;

   double r2 = iHigh(mySymbol, PERIOD_D1, 2) - iLow(mySymbol, PERIOD_D1, 2);
   double r3 = iHigh(mySymbol, PERIOD_D1, 3) - iLow(mySymbol, PERIOD_D1, 3);
   double r4 = iHigh(mySymbol, PERIOD_D1, 4) - iLow(mySymbol, PERIOD_D1, 4);
   
   if(r1 < r2 && r1 < r3 && r1 < r4)
     {
      Print("NR4 Pattern Detected on ", mySymbol);
      
      double point = MarketInfo(mySymbol, MODE_POINT);
      if(point == 0.00001) point = 0.0001; 
      if(point == 0.001) point = 0.01;

      double buffer = 20 * point; 

      double buyTrigger = h1 + buffer; 
      double sellTrigger = l1 - buffer;
      
      double atr = iATR(mySymbol, PERIOD_D1, 14, 1);
      double stopDist = atr * ATR_Multiplier;
      
      double vol = CalculateLotSize();
      
      if(vol > 0)
        {
         // EXPIRATION CALCULATION
         // We want orders to expire at the END of the current bar (next open).
         // iTime(0) is the open time of the CURRENT bar.
         // Add 24 hours (86400 seconds) to get the next open time.
         // Subtract 60 seconds to expire right before the new bar.
         
         datetime dayStart = iTime(mySymbol, PERIOD_D1, 0);
         datetime dayEnd = dayStart + 86400 - 60; 
         
         int ticket1 = OrderSend(mySymbol, OP_BUYSTOP, vol, buyTrigger, Slippage, buyTrigger - stopDist, 0, "NR4 Buy", MagicNumber, dayEnd, clrBlue);
         if(ticket1 < 0) Print("BuyStop Error: ", GetLastError());
         
         // Only place Sell Stop if you want Long & Short. 
         // int ticket2 = OrderSend(mySymbol, OP_SELLSTOP, vol, sellTrigger, Slippage, sellTrigger + stopDist, 0, "NR4 Sell", MagicNumber, dayEnd, clrRed);
         // if(ticket2 < 0) Print("SellStop Error: ", GetLastError());
        }
     }
  }

//+------------------------------------------------------------------+
//| Close trades at End of Day                                       |
//+------------------------------------------------------------------+
void CheckTimeExits()
  {
   // NOTE: We still need CloseHour because we might want to exit 
   // *before* the actual bar close (e.g. at 23:00 vs 00:00) to avoid swap.
   
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == mySymbol && OrderMagicNumber() == MagicNumber)
           {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
              {
               datetime openTime = OrderOpenTime();
               datetime currentTime = TimeCurrent();
               
               double secondsElapsed = currentTime - openTime;
               double daysElapsed = secondsElapsed / 86400.0;
               
               int currentHour = TimeHour(currentTime);
               
               // Logic: Held for ~1 day AND it is the CloseHour
               if(daysElapsed >= HoldDays - 0.5 && currentHour >= CloseHour)
                 {
                  bool res = false;
                  double closePrice = 0;
                  
                  if(OrderType() == OP_BUY)
                     closePrice = MarketInfo(mySymbol, MODE_BID);
                  else
                     closePrice = MarketInfo(mySymbol, MODE_ASK);
                     
                  res = OrderClose(OrderTicket(), OrderLots(), closePrice, Slippage, clrNONE);
                  if(!res) Print("Close Error: ", GetLastError());
                 }
              }
           }
        }
     }
  }

void DeletePendingOrders()
  {
   for(int i=OrdersTotal()-1; i>=0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderSymbol() == mySymbol && OrderMagicNumber() == MagicNumber) {
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP) {
               bool res = OrderDelete(OrderTicket());
               if(!res) Print("Delete Error: ", GetLastError());
              }
           }
        }
     }
  }

double CalculateLotSize()
  {
   double equity = AccountEquity();
   double targetExposure = equity * LevPerPair; 
   
   double contractSize = MarketInfo(mySymbol, MODE_LOTSIZE); 
   if(contractSize == 0) contractSize = 100000; 
   
   double vol = targetExposure / contractSize; 
   
   double step = MarketInfo(mySymbol, MODE_LOTSTEP);
   double min = MarketInfo(mySymbol, MODE_MINLOT);
   double max = MarketInfo(mySymbol, MODE_MAXLOT);
   
   if(step > 0)
      vol = MathFloor(vol / step) * step;
   
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
  }
//+------------------------------------------------------------------+