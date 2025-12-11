//+------------------------------------------------------------------+
//|                          NR4_SinglePair_Strict_MT4.mq4           |
//|               Single-Currency NR4 Strategy (Chart Specific)      |
//|                                      Copyright 2025, Risk Analyst |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property version   "2.01"
#property strict

// --- INPUTS ---
input double   LevPerPair     = 2;     // Leverage Allocation per Pair
input double   ATR_Multiplier = 5.0;      // Stop Loss Width (x ATR)
input int      HoldDays       = 1;        // Days to Hold
input int      MagicNumber    = 888888;   // Unique ID for this Strategy
input int      StartHour      = 0;
input int      CloseHour      = 23;       // Server Hour to Close Trades
input int      CloseMinute      = 55;       // Server Minute to Close Trades
input int      PipsBuffer       = 20;        // Slippage in Pips
input int      Slippage       = 5;        // Slippage in Pips

// --- GLOBALS ---
datetime       lastProcessedDay = 0;
string         mySymbol; 

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   mySymbol = Symbol(); // Get the chart symbol
   lastProcessedDay = iTime(mySymbol, PERIOD_D1, 0);
   
   // Validate Data availability
   if(iBars(mySymbol, PERIOD_D1) < 100)
     {
      Print("Error: Not enough history data for ", mySymbol);
      return(INIT_FAILED);
     }
     
   Print("NR4 Single-Pair EA Initialized for: ", mySymbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   // Optional: Clean up objects if any were created
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Check Time Exit (Run continuously to catch the exact hour)
   CheckTimeExits();
   datetime currentTime = TimeCurrent();
   int currentHour = TimeHour(currentTime);

   // 2. Entry Logic: Run ONLY when a new Daily Bar appears
   datetime currentBarDate = iTime(mySymbol, PERIOD_D1, 0);
   
   if(currentBarDate != lastProcessedDay && currentHour >= StartHour)
     {
      // New Day Detected!
      
      // Step A: Clean up old pending orders from yesterday
      DeletePendingOrders();
      
      // Step B: Run Strategy Scan
      ProcessStrategy();
      
      // Step C: Update state
      lastProcessedDay = currentBarDate;
     }
  }

//+------------------------------------------------------------------+
//| Core Strategy Logic                                              |
//+------------------------------------------------------------------+
void ProcessStrategy()
  {
   // Define Candle Indices (1 = Yesterday/Completed)
   int shift = 1;
   
   double h1 = iHigh(mySymbol, PERIOD_D1, shift);
   double l1 = iLow(mySymbol, PERIOD_D1, shift);
   double r1 = h1 - l1;

   double r2 = iHigh(mySymbol, PERIOD_D1, shift+1) - iLow(mySymbol, PERIOD_D1, shift+1);
   double r3 = iHigh(mySymbol, PERIOD_D1, shift+2) - iLow(mySymbol, PERIOD_D1, shift+2);
   double r4 = iHigh(mySymbol, PERIOD_D1, shift+3) - iLow(mySymbol, PERIOD_D1, shift+3);
   
   // NR4 Logic check
   if(r1 < r2 && r1 < r3 && r1 < r4)
     {
      Print("NR4 Pattern Detected on ", mySymbol);
      
      double point = MarketInfo(mySymbol, MODE_POINT);
      // Safety fix for 3/5 digit brokers
      if(point == 0.00001) point = 0.0001; 
      if(point == 0.001) point = 0.01;

      // 20 pips buffer
      double buffer = PipsBuffer * point; 

      double buyTrigger = h1 + buffer; 
      double sellTrigger = l1 - buffer;
      
      // MQL4 Style: Call iATR directly here
      double atr = iATR(mySymbol, PERIOD_D1, 14, shift);
      double stopDist = atr * ATR_Multiplier;
      
      double vol = CalculateLotSize();
      
      if(vol > 0)
        {
         // Expiration: End of the CURRENT day (23:59:59)
         datetime dayStart = iTime(mySymbol, PERIOD_D1, 0);
         datetime dayEnd = dayStart + 86400 - 60; 
         
         // 1. BUY STOP Order
         int ticket1 = OrderSend(mySymbol, OP_BUYSTOP, vol, buyTrigger, Slippage, buyTrigger - stopDist, 0, "NR4 Buy", MagicNumber, dayEnd, clrBlue);
         if(ticket1 < 0) 
            Print("BuyStop Error: ", GetLastError());
         else 
            Print("Buy Stop Placed: Ticket #", ticket1);
            
        //  // 2. SELL STOP Order
        //  int ticket2 = OrderSend(mySymbol, OP_SELLSTOP, vol, sellTrigger, Slippage, sellTrigger + stopDist, 0, "NR4 Sell", MagicNumber, dayEnd, clrRed);
        //  if(ticket2 < 0) 
        //     Print("SellStop Error: ", GetLastError());
        //  else 
        //     Print("Sell Stop Placed: Ticket #", ticket2);
        }
     }
  }

//+------------------------------------------------------------------+
//| Exit Logic                                                       |
//+------------------------------------------------------------------+
void CheckTimeExits()
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      // Select Order by Position Index
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         // Filter: Must match Symbol AND Magic Number
         if(OrderSymbol() == mySymbol && OrderMagicNumber() == MagicNumber)
           {
            // Only close active market orders (Not pending)
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
              {
               datetime openTime = OrderOpenTime();
               datetime currentTime = TimeCurrent();
               
               double secondsElapsed = currentTime - openTime;
               double daysElapsed = secondsElapsed / 86400.0;
               
               int currentHour = TimeHour(currentTime);
               int currentMinute = TimeMinute(currentTime);
               
               // Exit Rule: Held for ~1 day AND current hour matches CloseHour
               if(daysElapsed >= HoldDays - 0.5 && currentHour >= CloseHour && currentMinute >= CloseMinute)
                 {
                  bool res = false;
                  double closePrice = 0;
                  DeletePendingOrders();
                  
                  if(OrderType() == OP_BUY)
                     closePrice = MarketInfo(mySymbol, MODE_BID);
                  else
                     closePrice = MarketInfo(mySymbol, MODE_ASK);
                     
                  res = OrderClose(OrderTicket(), OrderLots(), closePrice, Slippage, clrNONE);
                  
                  if(!res) 
                     Print("Close Error for Ticket ", OrderTicket(), ": ", GetLastError());
                  else
                     Print("Time Exit Executed for Ticket ", OrderTicket());
                 }
              }
           }
        }
     }
  }

void DeletePendingOrders()
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderSymbol() == mySymbol && OrderMagicNumber() == MagicNumber)
           {
            // Delete only pending types
            if(OrderType() == OP_BUYSTOP || OrderType() == OP_SELLSTOP)
              {
               if(!OrderDelete(OrderTicket()))
                  Print("Delete Error for Ticket ", OrderTicket(), ": ", GetLastError());
              }
           }
        }
     }
  }

double CalculateLotSize()
  {
   double equity = AccountEquity();
   // Leverage calculation for THIS single chart
   double targetExposure = equity * LevPerPair; 
   
   double contractSize = MarketInfo(mySymbol, MODE_LOTSIZE); 
   if(contractSize == 0) contractSize = 100000; 
   
   double vol = targetExposure / contractSize; 
   
   double step = MarketInfo(mySymbol, MODE_LOTSTEP);
   double min = MarketInfo(mySymbol, MODE_MINLOT);
   double max = MarketInfo(mySymbol, MODE_MAXLOT);
   
   // Normalize volume steps
   if(step > 0)
      vol = MathFloor(vol / step) * step;
   
   if(vol < min) vol = min;
   if(vol > max) vol = max;
   
   return vol;
  }
//+------------------------------------------------------------------+