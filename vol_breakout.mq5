//+------------------------------------------------------------------+
//|                                Hybrid_Rolling_Quantiles_v4.mq5 |
//|                                  Copyright 2026, Singapore Quant |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- INPUTS: Distribution Settings
input group "Distribution Settings"
input int    InpLookback        = 500;   // History Window (N)
input int    InpSRLookback      = 500;   // S/R Lookback

//--- INPUTS: Quantile Criteria
input group "Entry Criteria (Quantiles)"
input double InpQ_ADX_Max       = 0.25; // ADX Quantile
input double InpQ_Dist_Min      = 0.90; // S/R Distance relative to ATR
input double InpQ_ATR_Pct_Max   = 0.50; // ATR Percentage Change
input double InpQ_Std_Pct_Max   = 0.50; // STD Percentage Change
input int InpQ_ATR_ROC_Period= 5; // ATR ROC Period
input double InpQ_ATR_ROC_Max   = 0.50; // ATR ROC Quantile

//--- INPUTS: Execution
input group "Execution Settings"
input string InpDirection       = "both"; // long, short, both
input double InpEntryATRMult    = 0.2;   // Entry Distance
input double InpSLATRMult       = 1.0;   // Initial Stop Loss
input double InpRiskPercent     = 1.0;   
input int    InpTimeStopHours   = 6;     // Time Stop (Hours)
input int    InpOrderExpireHours= 3;     // Pending Order Expiry (Hours)

//--- INPUTS: Exits & Management (NEW)
input group "Management Settings"
input bool   InpUseManualTP     = true;  // Enable Hard Take Profit?
input double InpTPATRMult       = 2.0;   // Take Profit (If Enabled)

input bool   InpUseBreakeven    = true;  // Move to BE?
input double InpBE_TriggerATR   = 0.8;   // Trigger BE at +0.8 ATR
input double InpBE_LockATR      = 0.1;   // Lock +0.1 ATR

input bool   InpUseTrailingStop = false; // Enable Trailing Stop?
input double InpTrailingATRMult = 1.5;   // Trail Distance (e.g. 1.5 ATR behind price)

input group "EA Settings"
input int    MagicNumber        = 88888888;
input bool   EnablePush       = true;  // Enable phone notifications
input int    NotifyHour       = 8;     // Server hour to send daily heartbeat (0-23)
input bool   InpDebugMode       = true;

//--- GLOBALS
CTrade trade;
int hADX, hATR, hStdDev, hMA;

//+------------------------------------------------------------------+
//| Helper: Get Quantile                                             |
//+------------------------------------------------------------------+
double GetQuantile(double &arr[], double percentile) {
   int size = ArraySize(arr);
   if(size == 0) return 0;
   double sorted[]; ArrayCopy(sorted, arr); ArraySort(sorted);
   double realIndex = percentile * (size - 1);
   int lower = (int)MathFloor(realIndex);
   int upper = (int)MathCeil(realIndex);
   if(lower == upper) return sorted[lower];
   return sorted[lower] + (sorted[upper] - sorted[lower]) * (realIndex - lower);
}

//+------------------------------------------------------------------+
//| Helper: Get Lot Size                                             |
//+------------------------------------------------------------------+
double GetLotSize(double sl_dist) {
   if(sl_dist <= 0) return 0.01;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = balance * (InpRiskPercent / 100.0);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal==0 || tickSz==0) return 0.01;
   double lots = risk / ((sl_dist/tickSz) * tickVal);
   lots = MathFloor(lots/SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)) * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lots < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return lots;
}

int OnInit() {
   hADX    = iADX(_Symbol, _Period, 14);
   hATR    = iATR(_Symbol, _Period, 14);
   hStdDev = iStdDev(_Symbol, _Period, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA     = iMA(_Symbol, _Period, 20, 0, MODE_SMA, PRICE_CLOSE);
   if(hADX==INVALID_HANDLE || hATR==INVALID_HANDLE || hStdDev==INVALID_HANDLE || hMA==INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber);
   // 1. Confirm VPS Startup
   if(EnablePush) {
      string host = MQLInfoInteger(MQL_TESTER) ? "Tester" : "Live/VPS";
      SendNotification(StringFormat("🚀 EA Started on %s. Magic: %d. Balance: %.2f", host, MagicNumber, AccountInfoDouble(ACCOUNT_BALANCE)));
   }
   return INIT_SUCCEEDED;
}

void OnTick() {
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

   // --- 1. TRADE MANAGEMENT (TimeStop, BE, Trailing) ---
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         
         // A. TIME STOP
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent() - openTime >= (InpTimeStopHours * 3600)) {
            trade.PositionClose(ticket);
            continue;
         }

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double curPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);
         long type        = PositionGetInteger(POSITION_TYPE);
         
         // Fetch fresh ATR for Management
         double atr_val = 0;
         double atr_buf[];
         if(CopyBuffer(hATR, 0, 0, 1, atr_buf) > 0) atr_val = atr_buf[0];
         
         if(atr_val > 0) {
            
            // B. TRAILING STOP LOGIC
            if(InpUseTrailingStop) {
               double trailDist = atr_val * InpTrailingATRMult;
               
               if(type == POSITION_TYPE_BUY) {
                  // New SL level = Current Price - Trail Distance
                  double newSL = NormalizeDouble(curPrice - trailDist, _Digits);
                  // Only move SL UP
                  if(newSL > currentSL && newSL < curPrice) {
                     trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  }
               }
               else if(type == POSITION_TYPE_SELL) {
                  // New SL level = Current Price + Trail Distance
                  double newSL = NormalizeDouble(curPrice + trailDist, _Digits);
                  // Only move SL DOWN
                  if((newSL < currentSL || currentSL == 0) && newSL > curPrice) {
                     trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  }
               }
            }
            
            // C. BREAKEVEN LOGIC (Only if Trailing didn't already move SL past BE)
            else if(InpUseBreakeven) {
               double triggerDist = atr_val * InpBE_TriggerATR;
               double lockDist    = atr_val * InpBE_LockATR;
               
               if(type == POSITION_TYPE_BUY) {
                  if(curPrice >= (openPrice + triggerDist) && currentSL < (openPrice + lockDist)) {
                     trade.PositionModify(ticket, openPrice + lockDist, PositionGetDouble(POSITION_TP));
                  }
               }
               else if(type == POSITION_TYPE_SELL) {
                  if(curPrice <= (openPrice - triggerDist) && (currentSL > (openPrice - lockDist) || currentSL == 0)) {
                     trade.PositionModify(ticket, openPrice - lockDist, PositionGetDouble(POSITION_TP));
                  }
               }
            }
         }
      }
   }

   // --- 2. OCO & New Bar Checks ---
   bool hasPosition = false;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionGetTicket(i) > 0) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
            hasPosition = true;
            break;
         }
      }
   }
   if(hasPosition) {
      // Delete pending orders if we already have a live position (OCO)
      for(int i=OrdersTotal()-1; i>=0; i--) {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) {
            trade.OrderDelete(OrderGetTicket(i));
         }
      }
      return; 
   }

   static datetime lastBar;
   datetime currentBar = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   // --- 3. BUILD BUFFERS ---
   int count = InpLookback + 6; 
   double buf_adx[], buf_atr[], buf_std[], buf_ma[], buf_close[], buf_high[], buf_low[];
   
   if(CopyBuffer(hADX, 0, 1, count, buf_adx) < count) return;
   if(CopyBuffer(hATR, 0, 1, count, buf_atr) < count) return;
   if(CopyBuffer(hStdDev, 0, 1, count, buf_std) < count) return;
   if(CopyBuffer(hMA, 0, 1, count, buf_ma) < count) return;
   if(CopyClose(_Symbol, _Period, 1, count, buf_close) < count) return;
   if(CopyHigh(_Symbol, _Period, 1, count + InpSRLookback, buf_high) < count) return;
   if(CopyLow(_Symbol, _Period, 1, count + InpSRLookback, buf_low) < count) return;

   // Arrays for history
   double hist_ADX[];      ArrayResize(hist_ADX, InpLookback);
   double hist_DistRes[];  ArrayResize(hist_DistRes, InpLookback);
   double hist_DistSup[];  ArrayResize(hist_DistSup, InpLookback);
   double hist_ATR_ROC[];  ArrayResize(hist_ATR_ROC, InpLookback);
   double hist_ATR_Pct[];  ArrayResize(hist_ATR_Pct, InpLookback);
   double hist_Std_Pct[];  ArrayResize(hist_Std_Pct, InpLookback);
   
   int filled = 0;
   for(int i = count - 2; i >= InpQ_ATR_ROC_Period && filled < InpLookback; i--) {
      hist_ADX[filled] = buf_adx[i];
      if(buf_close[i] > 0) hist_ATR_Pct[filled] = (buf_atr[i] / buf_close[i]) * 100.0;
      double atr_lag = buf_atr[i-InpQ_ATR_ROC_Period];
      if(atr_lag > 0) hist_ATR_ROC[filled] = (buf_atr[i] - atr_lag) / atr_lag;
      if(buf_ma[i] > 0) hist_Std_Pct[filled] = (buf_std[i] / buf_ma[i]) * 100.0;
      
      int shift = count - 1 - i + 1; 
      int highest_idx = iHighest(_Symbol, _Period, MODE_HIGH, InpSRLookback, shift);
      int lowest_idx  = iLowest(_Symbol, _Period, MODE_LOW, InpSRLookback, shift);
      double max_h = iHigh(_Symbol, _Period, highest_idx);
      double min_l = iLow(_Symbol, _Period, lowest_idx);
      
      if(buf_atr[i] > 0) {
         hist_DistRes[filled] = (max_h - buf_close[i]) / buf_atr[i];
         hist_DistSup[filled] = (buf_close[i] - min_l) / buf_atr[i];
      }
      filled++;
   }

   // --- 4. THRESHOLDS & SIGNAL ---
   double thresh_ADX     = GetQuantile(hist_ADX, InpQ_ADX_Max);
   double thresh_Dist    = GetQuantile(hist_DistRes, InpQ_Dist_Min); 
   double thresh_ATR_ROC = GetQuantile(hist_ATR_ROC, InpQ_ATR_ROC_Max);
   double thresh_ATR_Pct = GetQuantile(hist_ATR_Pct, InpQ_ATR_Pct_Max);
   double thresh_Std_Pct = GetQuantile(hist_Std_Pct, InpQ_Std_Pct_Max);
   
   int cur = count - 1; 
   double cur_ADX      = buf_adx[cur];
   double cur_ATR_Pct  = (buf_atr[cur] / buf_close[cur]) * 100.0;
   double cur_ATR_ROC  = (buf_atr[cur] - buf_atr[cur-InpQ_ATR_ROC_Period]) / buf_atr[cur-InpQ_ATR_ROC_Period];
   double cur_Std_Pct  = (buf_std[cur] / buf_ma[cur]) * 100.0;
   
   int cur_shift = 1; 
   double cur_max_h = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, InpSRLookback, cur_shift));
   double cur_min_l = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, InpSRLookback, cur_shift));
   double cur_DistRes  = (cur_max_h - buf_close[cur]) / buf_atr[cur];
   double cur_DistSup  = (buf_close[cur] - cur_min_l) / buf_atr[cur];

   bool signal = (
      cur_ADX < thresh_ADX &&
      cur_DistRes > thresh_Dist &&
      cur_DistSup > thresh_Dist &&
      cur_ATR_ROC > thresh_ATR_ROC && // Changed to > for Breakout Ignition
      cur_ATR_Pct < thresh_ATR_Pct &&
      cur_Std_Pct < thresh_Std_Pct
   );

   // --- 5. EXECUTION ---
   if(signal) {
      double atr = buf_atr[cur];
      double entry = atr * InpEntryATRMult;
      double sl    = atr * InpSLATRMult;
      
      // LOGIC: Manual TP Switch
      double tp = 0; // Default to Infinity
      if(InpUseManualTP) {
         tp = atr * InpTPATRMult;
      }
      
      double buy_pt = buf_close[cur] + entry;
      double sell_pt = buf_close[cur] - entry;
      datetime exp = TimeCurrent() + (InpOrderExpireHours * 3600);
      
      // TP Logic: If InpUseManualTP is FALSE, we send 0.0 as TP.
      double buy_tp_price = (InpUseManualTP) ? NormalizeDouble(buy_pt + tp, _Digits) : 0.0;
      double sell_tp_price = (InpUseManualTP) ? NormalizeDouble(sell_pt - tp, _Digits) : 0.0;
      
      // Check for Buy conditions
      if(InpDirection == "both" || InpDirection == "long") {
          trade.BuyStop(GetLotSize(sl), buy_pt, _Symbol, 
             NormalizeDouble(buy_pt - sl, _Digits), buy_tp_price, 
             ORDER_TIME_SPECIFIED, exp, "Quant Buy");
      } 
      
      // Check for Sell conditions separately
      if(InpDirection == "both" || InpDirection == "short") {
          trade.SellStop(GetLotSize(sl), sell_pt, _Symbol, 
             NormalizeDouble(sell_pt + sl, _Digits), sell_tp_price, 
             ORDER_TIME_SPECIFIED, exp, "Quant Sell");
      }
     
   }
}