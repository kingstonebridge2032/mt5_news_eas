//+------------------------------------------------------------------+
//|                                            CentGrower_Rescue.mq5 |
//|              RESCUED CONSERVATIVE CENT GROWTH SYSTEM             |
//|                                                                  |
//|  KEY FIXES:                                                      |
//|  1. Reduced risk from 5% to 0.5% per trade                      |
//|  2. Max lot capped at 0.1 instead of 5.0                        |
//|  3. Higher conviction entries (Z-Score 2.0 vs 1.2)              |
//|  4. Stricter regime filter (ER 0.7 vs 0.55)                     |
//|  5. Wider stops to avoid premature stop-outs                    |
//|  6. Removed aggressive timeout (was killing winners)            |
//|  7. Better R:R ratio (minimum 1:2 instead of 1:1.33)            |
//|  8. Lower max concurrent from 3 to 1                            |
//+------------------------------------------------------------------+
#property copyright "CentGrower Rescue v7.00"
#property version   "7.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS - RESCUED & OPTIMIZED                             |
//+------------------------------------------------------------------+

input group "=== CONSERVATIVE DUAL-ENGINE ==="
input int    TickLookback         = 50;        // Increased for better signal quality
input double RegimeThresholdER    = 0.70;      // Stricter: Only enter strong trends (was 0.55)
input double EntryDeviationZ      = 2.0;       // Higher conviction (was 1.2)
input int    ATR_Period           = 20;        // Longer ATR for stability (was 14)
input ENUM_TIMEFRAMES ATR_TF      = PERIOD_M5; // Higher timeframe ATR (was M1)

input group "=== SPIKE SHIELD - KEPT BUT REFINED ==="
input int    VelocityLookback     = 30;        // More samples for better detection
input double MaxTickVelocityDev   = 2.5;       // More sensitive to spikes (was 3.5)
input double MinSpikeVelocity     = 5000.0;    // Higher threshold
input int    SpikePauseSeconds    = 120;       // Longer pause (2 min vs 1 min)

input group "=== CONSERVATIVE EXITS ==="
input double StopLossATR_Mult     = 2.0;       // Wider stops to survive noise (was 1.5)
input double TakeProfitATR_Mult   = 4.0;       // Better R:R ratio (2:1 minimum)
input bool   UseTrailingStop      = true;
input double Trailing_ATR_Mult    = 2.5;       // Wider trail to let winners run
input double BreakevenTriggerPct  = 0.70;      // Move to BE later (70% vs 50%)
input int    MaxHoldSeconds       = 3600;      // 1 hour instead of 5 min (was killing winners)

input group "=== CONSERVATIVE RISK ==="
input double RiskPctPerTrade      = 0.5;       // 0.5% risk (10x smaller than 5%)
input double MaxLot               = 0.10;      // Hard cap at 0.1
input double MinLot               = 0.01;
input int    MaxConcurrent        = 1;         // Single position (was 3)

input group "=== CIRCUIT BREAKERS ==="
input double DailyProfitTargetPct = 5.0;       // Lock in 5% (was 15%)
input double DailyLossLimitPct    = 5.0;       // Stop at -5% (was -15%)
input int    MaxSpreadPts         = 3000;      // Tighter spread filter (was 5000)
input int    CooldownSec          = 300;       // 5 min cooldown between trades (was 1 sec!)
input bool   UseNewsFilter        = true;
input int    NewsPauseBeforeMin   = 60;        // Longer news pause
input int    NewsPauseAfterMin    = 30;
input bool   DebugLog             = true;

//+------------------------------------------------------------------+
//| GLOBAL SYSTEM VARIABLES                                            |
//+------------------------------------------------------------------+
CTrade trade;

double TickPrices[];
double TickReturns[];
double TickVolumes[];
long   TickTimesMsc[];
int    TickCount = 0;
bool   WarmupDone = false;
long   LastTickMsc = 0;

double TickVelocities[];
datetime SpikeBlockEndTime = 0;
bool IsSpikeShieldActive = false;

double DayOpenEquity = 0;
bool   DailyTargetHit = false;
bool   DailyLossHit = false;
datetime DayResetTime = 0;

int ATR_Handle = INVALID_HANDLE;
datetime LastTradeTime = 0;
datetime LastDiagTime = 0;

int WinCount = 0;
int LossCount = 0;
double TotalProfit = 0;

bool NewsBlocking = false;
datetime NewsBlockEnd = 0;

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(777322); // New magic number for rescue version
   trade.SetDeviationInPoints(30);     // Higher deviation tolerance
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   ArrayResize(TickPrices, TickLookback);
   ArrayResize(TickReturns, TickLookback);
   ArrayResize(TickVolumes, TickLookback);
   ArrayResize(TickTimesMsc, TickLookback);
   ArrayInitialize(TickPrices, 0.0);
   ArrayInitialize(TickReturns, 0.0);
   ArrayInitialize(TickVolumes, 0.0);
   ArrayInitialize(TickTimesMsc, 0);

   ArrayResize(TickVelocities, VelocityLookback);
   ArrayInitialize(TickVelocities, 0.0);

   ATR_Handle = iATR(_Symbol, ATR_TF, ATR_Period);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Print("❌ INIT FAILED: Cannot create ATR indicator.");
      return INIT_FAILED;
   }

   DayOpenEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   DayResetTime  = TimeCurrent();

   Print("╔══════════════════════════════════════════════════════╗");
   Print("║     CENTGROWER RESCUE v7.00 — CONSERVATIVE MODE      ║");
   Print("╠══════════════════════════════════════════════════════╣");
   Print("║  FIXED: Lower risk, better entries, wider stops      ║");
   Print("╚══════════════════════════════════════════════════════╝");
   Print("  Symbol        : ", _Symbol);
   Print("  Risk / Trade  : ", RiskPctPerTrade, "% (Down from 5%)");
   Print("  Max Lot       : ", MaxLot, " (Down from 5.0)");
   Print("  Max Positions : ", MaxConcurrent, " (Single position)");
   Print("  Min R:R       : 1:2");
   Print("  Cooldown      : ", CooldownSec, "s (Up from 1s)");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ATR_Handle != INVALID_HANDLE)
      IndicatorRelease(ATR_Handle);

   int total = WinCount + LossCount;
   double wr = total > 0 ? ((double)WinCount / total) * 100.0 : 0.0;

   Print("═══════════════════════ SESSION END ══════════════════════");
   Print("  Trades completed : ", total, " | Wins: ", WinCount, " | Losses: ", LossCount);
   Print("  Win Rate achieved: ", DoubleToString(wr, 1), "%");
   Print("  Total Profit/Loss: $", DoubleToString(TotalProfit, 2));
   Print("═══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick rawTicks[];
   int cnt = CopyTicks(_Symbol, rawTicks, COPY_TICKS_ALL, 0, 100);
   if(cnt > 0)
   {
      for(int i = 0; i < cnt; i++)
      {
         if(rawTicks[i].time_msc <= LastTickMsc && LastTickMsc != 0) continue;
         LastTickMsc = rawTicks[i].time_msc;
         
         double mid = (rawTicks[i].ask + rawTicks[i].bid) * 0.5;
         double vol = (double)rawTicks[i].volume;
         if(vol < 1.0) vol = 1.0;
         
         IngestTickData(mid, vol, rawTicks[i].time_msc);
      }
   }

   CheckDailyReset();
   CheckDailyLimits();
   ManagePositions();

   if(DailyTargetHit || DailyLossHit) return;

   if(DebugLog && TimeCurrent() - LastDiagTime >= 60) // Less frequent logging
   {
      LastDiagTime = TimeCurrent();
      PrintDiagnostics();
   }

   if(!WarmupDone) return;
   if(IsSpikeShieldActive && TimeCurrent() < SpikeBlockEndTime) return;
   if(!PassesFilters()) return;
   if(CountPositions() >= MaxConcurrent) return;
   if(TimeCurrent() - LastTradeTime < CooldownSec) return;

   TryEntry();
}

//+------------------------------------------------------------------+
//| IngestTickData - Same as original but with Velocity buffer fix    |
//+------------------------------------------------------------------+
void IngestTickData(double price, double volume, long timeMsc)
{
   for(int i = 0; i < TickLookback - 1; i++)
   {
      TickPrices[i]     = TickPrices[i + 1];
      TickReturns[i]    = TickReturns[i + 1];
      TickVolumes[i]    = TickVolumes[i + 1];
      TickTimesMsc[i]   = TickTimesMsc[i + 1];
   }
   TickPrices[TickLookback - 1]     = price;
   TickVolumes[TickLookback - 1]    = volume;
   TickTimesMsc[TickLookback - 1]   = timeMsc;

   if(TickPrices[TickLookback - 2] > 0.0)
      TickReturns[TickLookback - 1] = MathLog(price / TickPrices[TickLookback - 2]);
   else
      TickReturns[TickLookback - 1] = 0.0;

   TickCount++;
   if(!WarmupDone && TickCount >= TickLookback + 5) // More warmup ticks
   {
      WarmupDone = true;
      Print("✅ Warmup complete! Ready for high-probability entries.");
   }

   // Velocity calculation (same logic)
   double timeDeltaMsc = 0.0;
   double pointsDelta = 0.0;

   for(int i = TickLookback - 2; i >= 0; i--)
   {
      if(TickTimesMsc[TickLookback - 1] != TickTimesMsc[i])
      {
         timeDeltaMsc = (double)(TickTimesMsc[TickLookback - 1] - TickTimesMsc[i]);
         pointsDelta = MathAbs(TickPrices[TickLookback - 1] - TickPrices[i]) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         break;
      }
   }

   if(timeDeltaMsc < 10.0) timeDeltaMsc = 10.0;
   double velocity = pointsDelta / (timeDeltaMsc / 1000.0);

   for(int i = 0; i < VelocityLookback - 1; i++)
      TickVelocities[i] = TickVelocities[i + 1];
   TickVelocities[VelocityLookback - 1] = velocity;

   if(WarmupDone)
   {
      double sum = 0;
      int validCount = 0;
      for(int i = 0; i < VelocityLookback - 1; i++)
      {
         if(TickVelocities[i] > 0)
         {
            sum += TickVelocities[i];
            validCount++;
         }
      }
      
      if(validCount < 3) return;
      double mean = sum / validCount;

      double sumSq = 0;
      for(int i = 0; i < VelocityLookback - 1; i++)
      {
         if(TickVelocities[i] > 0)
         {
            double diff = TickVelocities[i] - mean;
            sumSq += diff * diff;
         }
      }
      double stdev = MathSqrt(sumSq / (validCount - 1));

      if(stdev > 0.01 && velocity > mean + MaxTickVelocityDev * stdev && velocity > MinSpikeVelocity)
      {
         if(!IsSpikeShieldActive)
         {
            IsSpikeShieldActive = true;
            SpikeBlockEndTime = TimeCurrent() + SpikePauseSeconds;
            Print("🚨 SPIKE DETECTED! Pausing for ", SpikePauseSeconds, "s");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CalculateFractalEfficiency - Same as original                     |
//+------------------------------------------------------------------+
double CalculateFractalEfficiency()
{
   double displacement = MathAbs(TickPrices[TickLookback - 1] - TickPrices[0]);
   double totalPath = 0.0;
   for(int i = 1; i < TickLookback; i++)
      totalPath += MathAbs(TickPrices[i] - TickPrices[i - 1]);

   if(totalPath < 1e-12) return 0.0;
   return displacement / totalPath;
}

//+------------------------------------------------------------------+
//| CalculateReturnsZScore - Same as original                         |
//+------------------------------------------------------------------+
double CalculateReturnsZScore()
{
   double sum = 0;
   for(int i = 0; i < TickLookback; i++) sum += TickReturns[i];
   double mean = sum / TickLookback;

   double sumSq = 0;
   for(int i = 0; i < TickLookback; i++)
   {
      double diff = TickReturns[i] - mean;
      sumSq += diff * diff;
   }
   double stdev = MathSqrt(sumSq / (TickLookback - 1));
   if(stdev < 1e-12) return 0.0;

   return (TickReturns[TickLookback - 1] - mean) / stdev;
}

//+------------------------------------------------------------------+
//| CalculateVWAP - Same as original                                  |
//+------------------------------------------------------------------+
double CalculateVWAP()
{
   double sumPriceVolume = 0.0;
   double sumVolume = 0.0;

   for(int i = 0; i < TickLookback; i++)
   {
      sumPriceVolume += TickPrices[i] * TickVolumes[i];
      sumVolume += TickVolumes[i];
   }

   if(sumVolume < 1.0) return TickPrices[TickLookback - 1];
   return sumPriceVolume / sumVolume;
}

//+------------------------------------------------------------------+
//| TryEntry - IMPROVED with confirmation filter                      |
//+------------------------------------------------------------------+
void TryEntry()
{
   double efficiency = CalculateFractalEfficiency();
   double zScore     = CalculateReturnsZScore();
   double vwap       = CalculateVWAP();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = (ask + bid) * 0.5;

   bool buySignal = false;
   bool sellSignal = false;
   string engineUsed = "";

   if(efficiency >= RegimeThresholdER)
   {
      // ENGINE 1: STRONG TREND BREAKOUT (Stricter conditions)
      double bufferHigh = -999999.0;
      double bufferLow  = 999999.0;
      
      for(int i = 0; i < TickLookback - 1; i++)
      {
         if(TickPrices[i] > bufferHigh) bufferHigh = TickPrices[i];
         if(TickPrices[i] < bufferLow && TickPrices[i] > 0.0) bufferLow = TickPrices[i];
      }

      // ADDED: Require momentum confirmation (price must be accelerating)
      double recentReturn = TickReturns[TickLookback - 1];
      double prevReturn = TickReturns[TickLookback - 3];
      
      if(mid > bufferHigh && recentReturn > 0 && recentReturn > prevReturn)
      {
         buySignal = true;
         engineUsed = "Strong Trend Breakout";
      }
      else if(mid < bufferLow && recentReturn < 0 && recentReturn < prevReturn)
      {
         sellSignal = true;
         engineUsed = "Strong Trend Breakout";
      }
   }
   else
   {
      // ENGINE 2: EXTREME MEAN REVERSION (Stricter Z-Score)
      if(zScore <= -EntryDeviationZ && mid < vwap)
      {
         buySignal = true;
         engineUsed = "Deep Mean Reversion";
      }
      else if(zScore >= EntryDeviationZ && mid > vwap)
      {
         sellSignal = true;
         engineUsed = "Deep Mean Reversion";
      }
   }

   if(!buySignal && !sellSignal) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // ADDED: Minimum ATR filter for meaningful moves
   if(atr / point < 5.0) // At least 5 points ATR
   {
      if(DebugLog)
         Print("🔍 Signal found but ATR too low (", atr/point, " pts) - skipping");
      return;
   }

   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double limitDist = MathMax((double)stopLevel, (double)freeze);
   double minSafety = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * 2.0; // Tighter spread buffer
   limitDist = MathMax(limitDist, minSafety);

   double slPoints = atr / point * StopLossATR_Mult;
   double tpPoints = atr / point * TakeProfitATR_Mult;

   if(slPoints < limitDist) slPoints = limitDist;
   if(tpPoints < limitDist) tpPoints = limitDist;

   // CHANGED: Minimum 1:2 risk-reward ratio
   if(tpPoints < slPoints * 2.0) 
   {
      tpPoints = slPoints * 2.0;
      if(DebugLog)
         Print("📐 Adjusted TP to maintain 1:2 R:R");
   }

   double lots = ComputeLots(slPoints);
   
   // ADDED: Maximum exposure check
   double maxExposure = AccountInfoDouble(ACCOUNT_EQUITY) * 0.01; // Max 1% account exposure
   double exposurePerLot = slPoints * point / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * 
                           SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double maxAllowedLots = maxExposure / exposurePerLot;
   lots = MathMin(lots, maxAllowedLots);
   lots = MathMin(lots, MaxLot);

   if(buySignal)
   {
      double sl = NormalizeDouble(ask - slPoints * point, _Digits);
      double tp = NormalizeDouble(ask + tpPoints * point, _Digits);

      Print("🟢 BUY | Engine: ", engineUsed, " | ER: ", DoubleToString(efficiency, 2), 
            " | Z: ", DoubleToString(zScore, 2), " | R:R 1:", DoubleToString(tpPoints/slPoints, 1),
            " | Lots: ", DoubleToString(lots, 2));
            
      if(trade.Buy(lots, _Symbol, ask, sl, tp, "CentGrower Rescue"))
         LastTradeTime = TimeCurrent();
   }
   else if(sellSignal)
   {
      double sl = NormalizeDouble(bid + slPoints * point, _Digits);
      double tp = NormalizeDouble(bid - tpPoints * point, _Digits);

      Print("🔴 SELL | Engine: ", engineUsed, " | ER: ", DoubleToString(efficiency, 2), 
            " | Z: ", DoubleToString(zScore, 2), " | R:R 1:", DoubleToString(tpPoints/slPoints, 1),
            " | Lots: ", DoubleToString(lots, 2));
            
      if(trade.Sell(lots, _Symbol, bid, sl, tp, "CentGrower Rescue"))
         LastTradeTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| ManagePositions - IMPROVED trailing logic                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double atr = GetATR();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(atr <= 0.0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 777322) continue; // Changed magic
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      datetime openTime= (datetime)PositionGetInteger(POSITION_TIME);
      double profit    = PositionGetDouble(POSITION_PROFIT);
      double swap      = PositionGetDouble(POSITION_SWAP);
      double commission = 0; // Some brokers include commission

      // ADDED: Check if position is actually profitable enough to trail
      double totalPnL = profit + swap;
      
      // IMPROVED: Timeout only for truly dead trades (1 hour)
      int holdSecs = (int)(TimeCurrent() - openTime);
      if(holdSecs >= MaxHoldSeconds && totalPnL < 0) // Only close losers on timeout
      {
         trade.PositionClose(ticket);
         Print("⏳ LOSING TRADE TIMEOUT: Closed after ", holdSecs/60, "min | P&L: $", DoubleToString(totalPnL, 2));
         continue;
      }

      // ADDED: Lock in profits at specific thresholds
      double atrValue = atr;
      double profitInATR = MathAbs(totalPnL) / (atrValue * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / 
                           SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double distInProfit = bid - openPrice;

         // Breakeven at 70% profit distance
         double slDistance = MathAbs(openPrice - currentSL);
         if(slDistance <= 0.0) slDistance = atrValue * StopLossATR_Mult;
         double targetForBE = slDistance * BreakevenTriggerPct;

         if(distInProfit >= targetForBE && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + 1.0 * point, _Digits);
            long minStop = MathMax(
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

            if(MathAbs(bid - newSL) > minStop * point)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               if(DebugLog) Print("🛡️ BUY BREAKEVEN: SL moved to entry+1pt");
               currentSL = newSL;
            }
         }

         // Trailing stop - wider and smarter
         if(UseTrailingStop && distInProfit > atrValue)
         {
            double trailDist = atrValue * Trailing_ATR_Mult;
            double desiredSL = NormalizeDouble(bid - trailDist, _Digits);

            // Only trail if we're moving SL significantly
            if(desiredSL > currentSL + atrValue * 0.5 && desiredSL > openPrice)
            {
               long minStop = MathMax(
                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

               if(MathAbs(bid - desiredSL) > minStop * point)
               {
                  trade.PositionModify(ticket, desiredSL, currentTP);
                  if(DebugLog) Print("📈 BUY TRAIL: SL moved to ", desiredSL);
               }
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double distInProfit = openPrice - ask;

         double slDistance = MathAbs(openPrice - currentSL);
         if(slDistance <= 0.0) slDistance = atrValue * StopLossATR_Mult;
         double targetForBE = slDistance * BreakevenTriggerPct;

         if(distInProfit >= targetForBE && (currentSL > openPrice || currentSL == 0.0))
         {
            double newSL = NormalizeDouble(openPrice - 1.0 * point, _Digits);
            long minStop = MathMax(
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

            if(MathAbs(newSL - ask) > minStop * point)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               if(DebugLog) Print("🛡️ SELL BREAKEVEN: SL moved to entry-1pt");
               currentSL = newSL;
            }
         }

         if(UseTrailingStop && distInProfit > atrValue)
         {
            double trailDist = atrValue * Trailing_ATR_Mult;
            double desiredSL = NormalizeDouble(ask + trailDist, _Digits);

            if((desiredSL < currentSL - atrValue * 0.5 || currentSL == 0.0) && desiredSL < openPrice)
            {
               long minStop = MathMax(
                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));

               if(MathAbs(desiredSL - ask) > minStop * point)
               {
                  trade.PositionModify(ticket, desiredSL, currentTP);
                  if(DebugLog) Print("📉 SELL TRAIL: SL moved to ", desiredSL);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| PassesFilters - Tighter quality control                           |
//+------------------------------------------------------------------+
bool PassesFilters()
{
   // Spread check - tighter
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPts)
   {
      if(DebugLog)
         Print("🚫 SPREAD: ", spread, " pts (max ", MaxSpreadPts, ")");
      return false;
   }

   // News filter
   if(UseNewsFilter && IsNearHighImpactNews())
      return false;

   // Spike shield
   if(IsSpikeShieldActive && TimeCurrent() < SpikeBlockEndTime)
      return false;

   if(IsSpikeShieldActive && TimeCurrent() >= SpikeBlockEndTime)
   {
      IsSpikeShieldActive = false;
      Print("🛡 Spike Shield cleared");
   }

   // ATR check - require more market movement
   double atr = GetATR();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(atr <= 0 || (atr / point) < 5.0) // Minimum 5 points ATR (was 2.0)
   {
      return false;
   }

   // ADDED: Session time filter - only trade active hours
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Avoid first 15 minutes of session (spread widening)
   if(dt.hour == 0 && dt.min < 15) return false;
   
   // Avoid low liquidity periods (adjust for your broker timezone)
   // if(dt.hour >= 22 || dt.hour < 2) return false;

   return true;
}

//+------------------------------------------------------------------+
//| IsNearHighImpactNews - Same as original                           |
//+------------------------------------------------------------------+
bool IsNearHighImpactNews()
{
   if(NewsBlocking)
   {
      if(TimeCurrent() < NewsBlockEnd)
         return true;
      else
      {
         NewsBlocking = false;
         Print("📰 News window cleared");
      }
   }

   MqlCalendarValue values[];
   datetime now = TimeCurrent();
   datetime from = now - (NewsPauseAfterMin * 60);
   datetime to   = now + (NewsPauseBeforeMin * 60);

   int count = CalendarValueHistory(values, from, to);
   if(count <= 0) return false;

   string sym = _Symbol;
   StringToUpper(sym);
   string cur1 = StringSubstr(sym, 0, 3);
   string cur2 = StringSubstr(sym, 3, 3);

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;
      if(evt.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry cntry;
      if(!CalendarCountryById(evt.country_id, cntry)) continue;
      string evtCurrency = cntry.currency;

      bool relevant = false;
      if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0 ||
         StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0)
      {
         if(evtCurrency == "USD") relevant = true;
      }
      else
      {
         if(evtCurrency == cur1 || evtCurrency == cur2) relevant = true;
      }

      if(!relevant) continue;

      datetime evtTime = values[i].time;
      datetime blockStart = evtTime - (NewsPauseBeforeMin * 60);
      datetime blockEnd   = evtTime + (NewsPauseAfterMin * 60);

      if(now >= blockStart && now <= blockEnd)
      {
         NewsBlocking = true;
         NewsBlockEnd = blockEnd;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| CheckDailyLimits - Conservative targets                           |
//+------------------------------------------------------------------+
void CheckDailyLimits()
{
   if(DailyTargetHit || DailyLossHit) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double changePct = ((equity - DayOpenEquity) / DayOpenEquity) * 100.0;

   if(changePct >= DailyProfitTargetPct && !DailyTargetHit)
   {
      DailyTargetHit = true;
      Print("🎯 DAILY TARGET +", DoubleToString(DailyProfitTargetPct, 1), "% HIT! Locking gains.");
   }

   if(changePct <= -DailyLossLimitPct && !DailyLossHit)
   {
      DailyLossHit = true;
      Print("🚨 DAILY LOSS LIMIT -", DoubleToString(DailyLossLimitPct, 1), "% HIT! Trading halted.");
   }
}

//+------------------------------------------------------------------+
//| CheckDailyReset - Same as original                                |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime cur, prev;
   TimeToStruct(TimeCurrent(), cur);
   TimeToStruct(DayResetTime, prev);

   if(cur.day != prev.day || cur.mon != prev.mon)
   {
      DayOpenEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      DayResetTime   = TimeCurrent();
      DailyTargetHit = false;
      DailyLossHit   = false;
      Print("🌅 Daily Reset. Equity: $", DoubleToString(DayOpenEquity, 2));
   }
}

//+------------------------------------------------------------------+
//| ComputeLots - Conservative sizing with 0.1 cap                    |
//+------------------------------------------------------------------+
double ComputeLots(double slPoints)
{
   if(slPoints <= 0.0) return MinLot;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPctPerTrade / 100.0);

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickVal <= 0 || tickSize <= 0 || pt <= 0) return MinLot;

   double riskPerLot = (slPoints * pt / tickSize) * tickVal;
   if(riskPerLot <= 0.0) return MinLot;

   double lots = riskMoney / riskPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   lots = MathMax(lots, vMin);
   lots = MathMin(lots, vMax);
   lots = MathMax(lots, MinLot);
   lots = MathMin(lots, MaxLot); // Hard cap at 0.1

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| GetATR                                                             |
//+------------------------------------------------------------------+
double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(ATR_Handle, 0, 0, 1, buf) < 1) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| CountPositions                                                     |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == 777322 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - Same but with updated magic                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(deal == 0) return;
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != 777322) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double p = HistoryDealGetDouble(deal, DEAL_PROFIT);
   TotalProfit += p;

   if(p > 0) WinCount++;
   else if(p < 0) LossCount++;

   int total = WinCount + LossCount;
   double wr = total > 0 ? ((double)WinCount / total) * 100.0 : 0.0;

   Print("💰 CLOSED | P&L: $", DoubleToString(p, 2),
         " | Session: $", DoubleToString(TotalProfit, 2),
         " | WR: ", DoubleToString(wr, 1), "%");
}

//+------------------------------------------------------------------+
//| PrintDiagnostics - Less frequent logging                          |
//+------------------------------------------------------------------+
void PrintDiagnostics()
{
   if(!WarmupDone)
   {
      Print("⏳ Warming: ", TickCount, "/", TickLookback, " ticks...");
      return;
   }

   double efficiency = CalculateFractalEfficiency();
   double zScore     = CalculateReturnsZScore();
   double vwap       = CalculateVWAP();
   long   spread     = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double changePct  = ((equity - DayOpenEquity) / DayOpenEquity) * 100.0;

   string marketRegime = (efficiency >= RegimeThresholdER) ? "STRONG TREND" : "RANGE/REVERSION";
   string spikeStatus  = IsSpikeShieldActive ? "BLOCKED" : "CLEAR";

   Print("📊 ER: ", DoubleToString(efficiency, 2), 
         " | Z: ", DoubleToString(zScore, 2), 
         " | VWAP: ", DoubleToString(vwap, _Digits),
         " | Day: ", DoubleToString(changePct, 1), "%",
         " | Regime: ", marketRegime,
         " | Shield: ", spikeStatus);
}
