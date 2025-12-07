//+------------------------------------------------------------------+
//|                                                 NR4_Breakout.mq5 |
//|                        NR4 Volatility Breakout Strategy          |
//|                    Converted from Python for Risk Analyst        |
//+------------------------------------------------------------------+
#property copyright "Risk Analyst"
#property link      "https://www.oanda.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUT PARAMETERS ---
input double   TargetLeverage = 1.33;     // Leverage per Pair (e.g. 4.0 total / 3 pairs = 1.33)
input double   ATR_Multiplier = 3.0;      // Stop Loss Distance (ATR Multiplier)
input int      ATR_Period     = 14;       // ATR Period
input int      MagicNumber    = 123456;   // Unique ID for this EA
input int      Slippage       = 30;       // Max Slippage in Points (3 pips)

// --- GLOBAL VARIABLES ---
CTrade         trade;
int            atrHandle;
datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Initialize ATR Indicator
   atrHandle = iATR(_Symbol, PERIOD_D1, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle");
      return(INIT_FAILED);
     }

   // 2. Setup Trade Execution
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // Fill or Kill (Standard for ECN)
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(atrHandle);
   // Optional: Delete pending orders on removal
   DeletePendingOrders();
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // We only trade on the OPEN of a new Daily Bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_D1, 0);
   if(currentBarTime == lastBarTime) return; // Still the same day, do nothing
   
   lastBarTime = currentBarTime; // Update tracker
   
   // --- NEW DAY START ROUTINE ---
   
   // 1. CLOSE EXISTING POSITIONS (1-Day Hold Logic)
   CloseAllPositions();
   
   // 2. DELETE UNFILLED ORDERS (Expired Logic)
   DeletePendingOrders();
   
   // 3. GET DATA (High, Low for previous 4 completed days)
   // Index 1 = Yesterday, Index 2 = Day before, etc.
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(_Symbol, PERIOD_D1, 1, 4, high) < 4 || CopyLow(_Symbol, PERIOD_D1, 1, 4, low) < 4)
     {
      Print("Not enough history data.");
      return;
     }

   // 4. CHECK NR4 CONDITION
   // Range = High - Low
   double r1 = high[0] - low[0]; // Yesterday (Index 1 in arrays)
   double r2 = high[1] - low[1]; // 2 Days ago
   double r3 = high[2] - low[2]; // 3 Days ago
   double r4 = high[3] - low[3]; // 4 Days ago
   
   bool isNR4 = (r1 < r2 && r1 < r3 && r1 < r4);
   
   if(isNR4)
     {
      Print("NR4 Pattern Detected on ", _Symbol);
      
      // 5. CALCULATE ENTRY LEVELS
      // Add a small buffer (e.g. 1-2 pips) to High/Low to avoid noise
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double buffer = 0; // Set to 10 * point for 1 pip buffer if desired
      
      double buyTrigger = high[0] + buffer;
      double sellTrigger = low[0] - buffer;
      
      // 6. CALCULATE STOP LOSS (ATR)
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1) return;
      
      double stopDist = atr[0] * ATR_Multiplier;
      
      // 7. CALCULATE LOT SIZE (Based on Leverage)
      double volume = CalculateLotSize();
      
      if(volume > 0)
        {
         // 8. PLACE ORDERS
         // Buy Stop
         double buySL = buyTrigger - stopDist;
         // Note: TP is 0 because we use Time Exit (Close next day)
         if(!trade.BuyStop(volume, buyTrigger, _Symbol, buySL, 0.0, ORDER_TIME_DAY))
            Print("Buy Stop Failed: ", GetLastError());
            
         // Sell Stop
         double sellSL = sellTrigger + stopDist;
         if(!trade.SellStop(volume, sellTrigger, _Symbol, sellSL, 0.0, ORDER_TIME_DAY))
            Print("Sell Stop Failed: ", GetLastError());
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size based on Equity & Leverage            |
//+------------------------------------------------------------------+
double CalculateLotSize()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Math: (Equity * Leverage) / ContractSize
   // Example: ($10,000 * 1.33) / 100,000 = 0.13 Lots
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double exchangeRate = 1.0; // Simplified. 
   
   // Accurately getting base currency conversion is complex in MQL5 without more code.
   // Standard approximation for FX pairs where Base Currency != Account Currency:
   // Volume = (Equity * Leverage) / (ContractSize * CurrentPrice)
   // But for simplicity and safety in this demo version:
   
   double targetExposure = equity * TargetLeverage;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Check if pair is JPY (e.g. USDJPY). Contract is usually 100,000 USD.
   // If Account is USD, USDJPY lot costs $100,000 margin (at 1:1).
   
   double vol = targetExposure / 100000.0; // Approximation for USD account trading USD pairs
   
   // Normalize to Broker Steps (e.g. 0.01)
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   vol = MathFloor(vol / step) * step;
   
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(vol < minVol) vol = minVol;
   if(vol > maxVol) vol = maxVol;
   
   return vol;
  }

//+------------------------------------------------------------------+
//| Helper: Close All Open Positions for this Symbol                 |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: Delete All Pending Orders                                |
//+------------------------------------------------------------------+
void DeletePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
           {
            trade.OrderDelete(ticket);
           }
        }
     }
  }
//+------------------------------------------------------------------+