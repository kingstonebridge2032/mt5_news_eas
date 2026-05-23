//+------------------------------------------------------------------+
//|                                    PhantomEdge_TickScalper.mq5    |
//|                          Ultra-Fast Tick Scalper for Cent Accounts |
//|                                  v2.0 — Aggressive + Debug Mode   |
//|                                                                    |
//|  PHILOSOPHY:                                                       |
//|  - Works on TICKS not bars — reacts to every price movement        |
//|  - Mean reversion on tick RETURNS (not raw prices)                 |
//|  - Micro-VWAP as dynamic fair value anchor                        |
//|  - Ultra-tight risk: equity-based lots, circuit breaker            |
//|  - News-aware: blocks new entries but NEVER closes winning trades  |
//|  - Aggressive entries, surgical exits                              |
//|  - FULL DEBUG OUTPUT so you can see what's happening               |
//+------------------------------------------------------------------+
#property copyright "PhantomEdge v2.0"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

//--- Core Strategy
input group "=== CORE STRATEGY ==="
input int      TickBufferSize       = 30;        // Tick buffer size (30 = fast warmup)
input double   ZScoreEntry          = 1.5;       // Z-Score threshold to enter (aggressive)
input double   ZScoreExit           = 0.2;       // Z-Score threshold to exit (quick scalp)
input int      VWAPWindowTicks      = 50;        // Micro-VWAP lookback (ticks)
input bool     UseVWAPConfirm       = true;      // Require VWAP confirmation for entry

//--- Risk Management  
input group "=== RISK MANAGEMENT ==="
input double   RiskPercentPerTrade  = 1.5;       // Risk % of equity per trade
input double   MaxDailyDrawdownPct  = 5.0;       // Max daily drawdown % (circuit breaker)
input double   MaxTotalDrawdownPct  = 15.0;      // Max total drawdown % from peak equity
input int      MaxPositionsPerSymbol= 1;         // Max positions per symbol (keep it 1!)
input double   MaxLotSize           = 1.00;      // Maximum lot size cap
input double   MinLotSize           = 0.01;      // Minimum lot size

//--- Stop Loss & Take Profit
input group "=== SL/TP & TRAILING ==="
input double   SL_ATR_Multiplier    = 1.2;       // SL = ATR × this (tight for fast scalps)
input double   TP_RR_Ratio          = 1.5;       // TP = SL distance × this (quick profit)
input double   TrailingATR_Mult     = 0.8;       // Trailing stop = ATR × this (tight trail)
input double   BreakevenATR_Mult    = 0.5;       // Move SL to breakeven FAST
input int      ATR_Period           = 14;        // ATR period
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M1; // ATR timeframe

//--- Spread & Volatility Filters
input group "=== FILTERS ==="
input int      MaxSpreadPoints      = 100;       // Max allowed spread (100 for crypto)
input double   MinATR_Filter        = 0.0;       // Min ATR to trade (0 = auto-detect)
input bool     UseSessionFilter     = false;     // Session filter (OFF for crypto 24/7)
input int      SessionStartHour     = 7;         // Session start (only if filter ON)
input int      SessionEndHour       = 20;        // Session end (only if filter ON)

//--- News Filter
input group "=== NEWS FILTER ==="
input bool     UseNewsFilter        = true;      // Enable news filter
input int      NewsMinutesBefore    = 30;        // Minutes before news to stop entries
input int      NewsMinutesAfter     = 30;        // Minutes after news to stop entries

//--- Trade Settings
input group "=== TRADE SETTINGS ==="
input int      MagicNumber          = 777888;    // Magic number
input int      TradeSlippage        = 15;        // Max slippage (points)
input string   TradeComment         = "PhantomEdge"; // Trade comment
input int      CooldownSeconds      = 2;         // Seconds between trades (fast re-entry)
input bool     DebugMode            = true;      // Print debug info to Experts tab

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+
CTrade         trade;

// Tick data buffers
double         TickPrices[];         // Raw tick prices (mid)
double         TickReturns[];        // Log returns between ticks
double         TickVolumes[];        // Tick volumes for VWAP
int            TickCount = 0;        // How many ticks we've collected
bool           BufferReady = false;  // Is buffer fully populated?

// VWAP data
double         VWAPPrices[];
double         VWAPVolumes[];
int            VWAPCount = 0;
bool           VWAPReady = false;

// State tracking
datetime       LastTradeTime = 0;
double         DayStartEquity = 0;
double         PeakEquity = 0;
bool           DailyCircuitBreaker = false;
bool           TotalCircuitBreaker = false;
datetime       LastDay = 0;
long           LastTickTimeMsc = 0;   // Milliseconds (was datetime = BUG!)

// Debug tracking
int            DebugCounter = 0;
int            FilterBlockCount = 0;
int            SignalCount = 0;
datetime       LastDebugPrint = 0;

// ATR handle
int            ATR_Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(TradeSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Initialize tick buffers
   ArrayResize(TickPrices, TickBufferSize);
   ArrayResize(TickReturns, TickBufferSize);
   ArrayResize(TickVolumes, TickBufferSize);
   ArrayInitialize(TickPrices, 0);
   ArrayInitialize(TickReturns, 0);
   ArrayInitialize(TickVolumes, 0);
   
   // Initialize VWAP buffers
   ArrayResize(VWAPPrices, VWAPWindowTicks);
   ArrayResize(VWAPVolumes, VWAPWindowTicks);
   ArrayInitialize(VWAPPrices, 0);
   ArrayInitialize(VWAPVolumes, 0);
   
   // Create ATR indicator
   ATR_Handle = iATR(_Symbol, ATR_Timeframe, ATR_Period);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Print("❌ ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }
   
   // Initialize equity tracking
   DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   PeakEquity = DayStartEquity;
   LastDay = TimeCurrent();
   
   Print("╔══════════════════════════════════════════════════════╗");
   Print("║     PhantomEdge TickScalper v2.0 — INITIALIZED      ║");
   Print("╚══════════════════════════════════════════════════════╝");
   Print("  Account: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("  Symbol: ", _Symbol, " | Digits: ", _Digits,
         " | Point: ", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_POINT), _Digits));
   Print("  Spread now: ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " pts",
         " | Max allowed: ", MaxSpreadPoints, " pts");
   Print("  Buffer: ", TickBufferSize, " ticks",
         " | VWAP: ", VWAPWindowTicks, " ticks",
         " | Z-Entry: ", DoubleToString(ZScoreEntry, 1));
   Print("  Risk/trade: ", DoubleToString(RiskPercentPerTrade, 1), "%",
         " | Daily DD limit: ", DoubleToString(MaxDailyDrawdownPct, 1), "%");
   Print("  Session filter: ", (UseSessionFilter ? "ON" : "OFF"),
         " | News filter: ", (UseNewsFilter ? "ON" : "OFF"));
   Print("  Debug mode: ", (DebugMode ? "ON — you'll see what I'm thinking" : "OFF"));
   Print("  ⏳ Warming up... need ", TickBufferSize + 1, " ticks before first trade");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ATR_Handle != INVALID_HANDLE)
      IndicatorRelease(ATR_Handle);
      
   Print("═══ PhantomEdge TickScalper STOPPED ═══");
   Print("  Signals detected: ", SignalCount, " | Blocked by filters: ", FilterBlockCount);
}

//+------------------------------------------------------------------+
//| Expert tick function — THE HEART                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process ALL ticks since last call using CopyTicks
   MqlTick ticks[];
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, 0, 200);
   
   if(copied <= 0)
   {
      if(DebugMode && TimeCurrent() - LastDebugPrint > 30)
      {
         Print("⚠ CopyTicks returned 0 — no tick data available");
         LastDebugPrint = TimeCurrent();
      }
      return;
   }
   
   // Process only new ticks
   int newTicks = 0;
   for(int i = 0; i < copied; i++)
   {
      if(ticks[i].time_msc <= LastTickTimeMsc && LastTickTimeMsc != 0) continue;
      
      LastTickTimeMsc = ticks[i].time_msc;
      double midPrice = (ticks[i].ask + ticks[i].bid) / 2.0;
      double tickVol  = (double)ticks[i].volume;
      if(tickVol < 1) tickVol = 1;
      
      ProcessTick(midPrice, tickVol);
      newTicks++;
   }
   
   //--- Periodic debug status (every 10 seconds)
   if(DebugMode && TimeCurrent() - LastDebugPrint >= 10)
   {
      LastDebugPrint = TimeCurrent();
      DebugCounter++;
      
      if(!BufferReady)
      {
         Print("⏳ Warming up: ", TickCount, "/", TickBufferSize + 1, " ticks collected...");
      }
      else
      {
         double zScore = CalcZScore();
         double cumZ = CalcCumulativeZScore(8);
         double vwap = CalcMicroVWAP();
         double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
         double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         double atr = GetATR();
         
         string vwapDir = "";
         if(vwap > 0)
            vwapDir = (mid > vwap) ? " ABOVE vwap" : " BELOW vwap";
         
         Print("📊 Z=", DoubleToString(zScore, 2),
               " | CumZ=", DoubleToString(cumZ, 2),
               " | Spread=", (int)spread,
               " | ATR=", DoubleToString(atr, _Digits),
               " | VWAP", (VWAPReady ? vwapDir : "=warming"),
               " | Pos=", CountMyPositions(),
               " | Need Z≤-", DoubleToString(ZScoreEntry, 1), " or Z≥+", DoubleToString(ZScoreEntry, 1));
      }
   }
   
   //--- Check daily reset
   CheckDailyReset();
   
   //--- Circuit breaker check
   UpdateCircuitBreakers();
   if(DailyCircuitBreaker || TotalCircuitBreaker)
   {
      ManageOpenPositions();
      return;
   }
   
   //--- Manage existing positions
   ManageOpenPositions();
   
   //--- Check if buffer is ready
   if(!BufferReady) return;
   
   //--- Check all filters before entry
   if(!PassesAllFilters()) return;
   
   //--- Check cooldown
   if(TimeCurrent() - LastTradeTime < CooldownSeconds) return;
   
   //--- Check max positions
   if(CountMyPositions() >= MaxPositionsPerSymbol) return;
   
   //--- ENTRY LOGIC
   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| Process a single tick into our buffers                             |
//+------------------------------------------------------------------+
void ProcessTick(double price, double volume)
{
   // Shift buffer left
   for(int i = 0; i < TickBufferSize - 1; i++)
   {
      TickPrices[i] = TickPrices[i + 1];
      TickReturns[i] = TickReturns[i + 1];
      TickVolumes[i] = TickVolumes[i + 1];
   }
   
   // Add new tick
   TickPrices[TickBufferSize - 1] = price;
   TickVolumes[TickBufferSize - 1] = volume;
   
   // Calculate log return
   if(TickPrices[TickBufferSize - 2] > 0)
      TickReturns[TickBufferSize - 1] = MathLog(price / TickPrices[TickBufferSize - 2]);
   else
      TickReturns[TickBufferSize - 1] = 0;
   
   TickCount++;
   
   // Buffer ready after full population
   if(!BufferReady && TickCount >= TickBufferSize + 1)
   {
      BufferReady = true;
      Print("✅ Tick buffer READY! (", TickCount, " ticks) — Now scanning for entries...");
   }
   
   // VWAP buffer
   for(int i = 0; i < VWAPWindowTicks - 1; i++)
   {
      VWAPPrices[i] = VWAPPrices[i + 1];
      VWAPVolumes[i] = VWAPVolumes[i + 1];
   }
   VWAPPrices[VWAPWindowTicks - 1] = price;
   VWAPVolumes[VWAPWindowTicks - 1] = volume;
   VWAPCount++;
   
   if(!VWAPReady && VWAPCount >= VWAPWindowTicks)
   {
      VWAPReady = true;
      Print("✅ VWAP buffer READY! (", VWAPCount, " ticks)");
   }
}

//+------------------------------------------------------------------+
//| Calculate Z-Score on RETURNS (not raw prices!)                     |
//+------------------------------------------------------------------+
double CalcZScore()
{
   double sum = 0;
   for(int i = 0; i < TickBufferSize; i++)
      sum += TickReturns[i];
   double mean = sum / TickBufferSize;
   
   double sumSqDev = 0;
   for(int i = 0; i < TickBufferSize; i++)
   {
      double dev = TickReturns[i] - mean;
      sumSqDev += dev * dev;
   }
   double stdev = MathSqrt(sumSqDev / (TickBufferSize - 1));
   
   if(stdev < 1e-12) return 0;
   
   return (TickReturns[TickBufferSize - 1] - mean) / stdev;
}

//+------------------------------------------------------------------+
//| Calculate Micro-VWAP                                               |
//+------------------------------------------------------------------+
double CalcMicroVWAP()
{
   if(!VWAPReady) return 0;
   
   double sumPV = 0;
   double sumV = 0;
   
   for(int i = 0; i < VWAPWindowTicks; i++)
   {
      if(VWAPPrices[i] <= 0) return 0;
      sumPV += VWAPPrices[i] * VWAPVolumes[i];
      sumV  += VWAPVolumes[i];
   }
   
   if(sumV < 1) return 0;
   return sumPV / sumV;
}

//+------------------------------------------------------------------+
//| Cumulative Z-Score (multi-tick momentum)                           |
//+------------------------------------------------------------------+
double CalcCumulativeZScore(int lookback)
{
   if(lookback > TickBufferSize) lookback = TickBufferSize;
   
   double cumReturn = 0;
   for(int i = TickBufferSize - lookback; i < TickBufferSize; i++)
      cumReturn += TickReturns[i];
   
   double sum = 0;
   for(int i = 0; i < TickBufferSize; i++)
      sum += TickReturns[i];
   double mean = sum / TickBufferSize;
   
   double sumSqDev = 0;
   for(int i = 0; i < TickBufferSize; i++)
   {
      double dev = TickReturns[i] - mean;
      sumSqDev += dev * dev;
   }
   double stdev = MathSqrt(sumSqDev / (TickBufferSize - 1));
   
   if(stdev < 1e-12) return 0;
   
   double expectedStdev = stdev * MathSqrt((double)lookback);
   return (cumReturn - mean * lookback) / expectedStdev;
}

//+------------------------------------------------------------------+
//| ENTRY — Fast & Aggressive                                          |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double zScore = CalcZScore();
   double cumZ   = CalcCumulativeZScore(8);  // 8-tick momentum (was 10)
   double vwap   = CalcMicroVWAP();
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid    = (ask + bid) / 2.0;
   
   double atr = GetATR();
   if(atr <= 0)
   {
      if(DebugMode) Print("⚠ ATR = 0, can't calculate SL/TP");
      return;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return;
   
   //=== BUY SIGNAL ===
   // Price dipped hard (negative Z) + momentum confirms + below VWAP
   bool buySignal = (zScore <= -ZScoreEntry) && (cumZ <= -0.8);
   
   if(UseVWAPConfirm && vwap > 0)
      buySignal = buySignal && (mid < vwap);
   
   //=== SELL SIGNAL ===
   // Price spiked hard (positive Z) + momentum confirms + above VWAP
   bool sellSignal = (zScore >= ZScoreEntry) && (cumZ >= 0.8);
   
   if(UseVWAPConfirm && vwap > 0)
      sellSignal = sellSignal && (mid > vwap);
   
   //=== EXECUTE ===
   if(buySignal)
   {
      SignalCount++;
      double slDist = atr * SL_ATR_Multiplier;
      double sl = NormalizeDouble(ask - slDist, _Digits);
      double tp = NormalizeDouble(ask + slDist * TP_RR_Ratio, _Digits);
      
      if(!ValidateStops(ORDER_TYPE_BUY, ask, sl, tp))
      {
         if(DebugMode) Print("⚠ BUY signal but stops invalid (too close to price)");
         FilterBlockCount++;
         return;
      }
      
      double lots = CalcLotSize(MathAbs(ask - sl) / point);
      
      Print("🟢══════════════════════════════════════════════");
      Print("🟢 BUY SIGNAL #", SignalCount);
      Print("🟢 Z=", DoubleToString(zScore, 3),
            " | CumZ=", DoubleToString(cumZ, 3),
            " | VWAP=", DoubleToString(vwap, _Digits));
      Print("🟢 Entry=", DoubleToString(ask, _Digits),
            " | SL=", DoubleToString(sl, _Digits),
            " | TP=", DoubleToString(tp, _Digits),
            " | Lots=", DoubleToString(lots, 2));
      
      if(trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();
         Print("🟢 ✅ BUY OPENED SUCCESSFULLY!");
      }
      else
      {
         Print("🟢 ❌ BUY FAILED: ", trade.ResultRetcodeDescription());
      }
      Print("🟢══════════════════════════════════════════════");
   }
   else if(sellSignal)
   {
      SignalCount++;
      double slDist = atr * SL_ATR_Multiplier;
      double sl = NormalizeDouble(bid + slDist, _Digits);
      double tp = NormalizeDouble(bid - slDist * TP_RR_Ratio, _Digits);
      
      if(!ValidateStops(ORDER_TYPE_SELL, bid, sl, tp))
      {
         if(DebugMode) Print("⚠ SELL signal but stops invalid (too close to price)");
         FilterBlockCount++;
         return;
      }
      
      double lots = CalcLotSize(MathAbs(sl - bid) / point);
      
      Print("🔴══════════════════════════════════════════════");
      Print("🔴 SELL SIGNAL #", SignalCount);
      Print("🔴 Z=", DoubleToString(zScore, 3),
            " | CumZ=", DoubleToString(cumZ, 3),
            " | VWAP=", DoubleToString(vwap, _Digits));
      Print("🔴 Entry=", DoubleToString(bid, _Digits),
            " | SL=", DoubleToString(sl, _Digits),
            " | TP=", DoubleToString(tp, _Digits),
            " | Lots=", DoubleToString(lots, 2));
      
      if(trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();
         Print("🔴 ✅ SELL OPENED SUCCESSFULLY!");
      }
      else
      {
         Print("🔴 ❌ SELL FAILED: ", trade.ResultRetcodeDescription());
      }
      Print("🔴══════════════════════════════════════════════");
   }
}

//+------------------------------------------------------------------+
//| MANAGE POSITIONS — Trailing, breakeven, Z-score exit               |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atr = GetATR();
   if(atr <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double profit    = PositionGetDouble(POSITION_PROFIT);
      
      //--- Z-Score exit: price reverted to mean → take profit early
      if(BufferReady)
      {
         double zNow = CalcZScore();
         double cumZNow = CalcCumulativeZScore(8);
         
         if(posType == POSITION_TYPE_BUY && zNow >= ZScoreExit && cumZNow >= 0 && profit > 0)
         {
            trade.PositionClose(ticket);
            Print("💰 BUY CLOSED (Z-revert) | Z=", DoubleToString(zNow, 2),
                  " | Profit=$", DoubleToString(profit, 2));
            continue;
         }
         else if(posType == POSITION_TYPE_SELL && zNow <= -ZScoreExit && cumZNow <= 0 && profit > 0)
         {
            trade.PositionClose(ticket);
            Print("💰 SELL CLOSED (Z-revert) | Z=", DoubleToString(zNow, 2),
                  " | Profit=$", DoubleToString(profit, 2));
            continue;
         }
      }
      
      //--- Breakeven logic
      double breakevenDist = atr * BreakevenATR_Mult;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         // Breakeven
         if(bid >= openPrice + breakevenDist && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + point * 2, _Digits);
            if(newSL > currentSL)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               if(DebugMode) Print("🛡 BUY → BREAKEVEN at ", DoubleToString(newSL, _Digits));
            }
         }
         
         // Trailing stop
         double trailLevel = NormalizeDouble(bid - atr * TrailingATR_Mult, _Digits);
         if(trailLevel > currentSL && trailLevel > openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // Breakeven
         if(ask <= openPrice - breakevenDist && (currentSL > openPrice || currentSL == 0))
         {
            double newSL = NormalizeDouble(openPrice - point * 2, _Digits);
            if(currentSL == 0 || newSL < currentSL)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               if(DebugMode) Print("🛡 SELL → BREAKEVEN at ", DoubleToString(newSL, _Digits));
            }
         }
         
         // Trailing stop
         double trailLevel = NormalizeDouble(ask + atr * TrailingATR_Mult, _Digits);
         if((trailLevel < currentSL || currentSL == 0) && trailLevel < openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| DYNAMIC LOT SIZING                                                 |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePoints)
{
   if(slDistancePoints <= 0) return MinLotSize;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (RiskPercentPerTrade / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(tickValue <= 0 || tickSize <= 0 || point <= 0) return MinLotSize;
   
   double riskPerLot = (slDistancePoints * point / tickSize) * tickValue;
   if(riskPerLot <= 0) return MinLotSize;
   
   double lots = riskAmount / riskPerLot;
   
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, lotMin);
   lots = MathMin(lots, lotMax);
   lots = MathMax(lots, MinLotSize);
   lots = MathMin(lots, MaxLotSize);
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKERS                                                   |
//+------------------------------------------------------------------+
void UpdateCircuitBreakers()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > PeakEquity)
      PeakEquity = equity;
   
   if(DayStartEquity > 0)
   {
      double dailyDD = ((DayStartEquity - equity) / DayStartEquity) * 100.0;
      if(dailyDD >= MaxDailyDrawdownPct && !DailyCircuitBreaker)
      {
         DailyCircuitBreaker = true;
         Print("🚨 DAILY CIRCUIT BREAKER! DD=", DoubleToString(dailyDD, 2), "% — No new trades today");
      }
   }
   
   if(PeakEquity > 0)
   {
      double totalDD = ((PeakEquity - equity) / PeakEquity) * 100.0;
      if(totalDD >= MaxTotalDrawdownPct && !TotalCircuitBreaker)
      {
         TotalCircuitBreaker = true;
         Print("🚨🚨 TOTAL CIRCUIT BREAKER! DD=", DoubleToString(totalDD, 2), "% from peak — EA STOPPED");
      }
   }
}

//+------------------------------------------------------------------+
//| Daily reset                                                        |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime now, last;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(LastDay, last);
   
   if(now.day != last.day || now.mon != last.mon)
   {
      DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      DailyCircuitBreaker = false;
      LastDay = TimeCurrent();
      Print("═══ NEW DAY | Equity: $", DoubleToString(DayStartEquity, 2), " ═══");
   }
}

//+------------------------------------------------------------------+
//| FILTER CHECKS (with debug output!)                                 |
//+------------------------------------------------------------------+
bool PassesAllFilters()
{
   // Spread filter
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpreadPoints)
   {
      if(DebugMode && TimeCurrent() - LastDebugPrint >= 10)
         Print("🚫 Spread too wide: ", spreadPoints, " > ", MaxSpreadPoints);
      FilterBlockCount++;
      return false;
   }
   
   // ATR filter
   double atr = GetATR();
   double minATR = MinATR_Filter;
   
   if(minATR <= 0)
   {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      minATR = spreadPoints * point * 1.5; // 1.5× spread (was 2×, more lenient now)
   }
   
   if(atr < minATR)
   {
      if(DebugMode && TimeCurrent() - LastDebugPrint >= 10)
         Print("🚫 ATR too low: ", DoubleToString(atr, _Digits), " < ", DoubleToString(minATR, _Digits));
      FilterBlockCount++;
      return false;
   }
   
   // Session filter
   if(UseSessionFilter)
   {
      MqlDateTime serverTime;
      TimeToStruct(TimeCurrent(), serverTime);
      
      if(SessionStartHour < SessionEndHour)
      {
         if(serverTime.hour < SessionStartHour || serverTime.hour >= SessionEndHour)
         {
            if(DebugMode && TimeCurrent() - LastDebugPrint >= 10)
               Print("🚫 Outside session: hour=", serverTime.hour,
                     " (allowed: ", SessionStartHour, "-", SessionEndHour, ")");
            FilterBlockCount++;
            return false;
         }
      }
      else
      {
         if(serverTime.hour < SessionStartHour && serverTime.hour >= SessionEndHour)
         {
            FilterBlockCount++;
            return false;
         }
      }
   }
   
   // News filter
   if(UseNewsFilter && IsNewsTime())
   {
      FilterBlockCount++;
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                        |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   datetime now = TimeCurrent();
   datetime from = now - (NewsMinutesAfter * 60);
   datetime to   = now + (NewsMinutesBefore * 60);
   
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to);
   
   if(count <= 0) return false;
   
   string baseCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quoteCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   
   string symbolName = _Symbol;
   StringToUpper(symbolName);
   bool isSpecial = (StringFind(symbolName, "XAU") >= 0 || 
                     StringFind(symbolName, "GOLD") >= 0 ||
                     StringFind(symbolName, "US30") >= 0 ||
                     StringFind(symbolName, "NAS") >= 0 ||
                     StringFind(symbolName, "SPX") >= 0 ||
                     StringFind(symbolName, "BTC") >= 0 ||
                     StringFind(symbolName, "ETH") >= 0);
   
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      
      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      
      string eventCurrency = country.currency;
      StringToUpper(eventCurrency);
      
      bool relevant = false;
      if(isSpecial)
      {
         relevant = (eventCurrency == "USD");
      }
      else
      {
         string baseUp = baseCurrency;
         string quoteUp = quoteCurrency;
         StringToUpper(baseUp);
         StringToUpper(quoteUp);
         relevant = (eventCurrency == baseUp || eventCurrency == quoteUp);
      }
      
      if(relevant)
      {
         datetime eventTime = values[i].time;
         if(now >= eventTime - NewsMinutesBefore * 60 && 
            now <= eventTime + NewsMinutesAfter * 60)
         {
            if(DebugMode)
               Print("📰 NEWS BLOCK: ", event.name, " at ", TimeToString(eventTime));
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| VALIDATE STOPS                                                     |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE orderType, double price, double sl, double tp)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   double minDist = MathMax((double)stopsLevel, (double)freezeLevel) * point;
   double spreadDist = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point * 3;
   minDist = MathMax(minDist, spreadDist);
   
   if(orderType == ORDER_TYPE_BUY)
   {
      if(MathAbs(price - sl) < minDist) return false;
      if(MathAbs(tp - price) < minDist) return false;
   }
   else
   {
      if(MathAbs(sl - price) < minDist) return false;
      if(MathAbs(price - tp) < minDist) return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Get current ATR                                                    |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(ATR_Handle, 0, 0, 1, atrBuffer) <= 0) return 0;
   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Count positions                                                    |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      count++;
   }
   return count;
}
//+------------------------------------------------------------------+
