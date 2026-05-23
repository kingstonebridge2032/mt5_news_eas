//+------------------------------------------------------------------+
//|                                    PhantomEdge_TickScalper.mq5    |
//|                          Ultra-Fast Tick Scalper for Cent Accounts |
//|                                                                    |
//|  PHILOSOPHY:                                                       |
//|  - Works on TICKS not bars — reacts to every price movement        |
//|  - Mean reversion on tick RETURNS (not raw prices)                 |
//|  - Micro-VWAP as dynamic fair value anchor                        |
//|  - Ultra-tight risk: equity-based lots, circuit breaker, session   |
//|  - News-aware: blocks new entries but NEVER closes winning trades  |
//|  - Aggressive entries, surgical exits                              |
//+------------------------------------------------------------------+
#property copyright "PhantomEdge"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

//--- Core Strategy
input group "=== CORE STRATEGY ==="
input int      TickBufferSize       = 60;        // Tick buffer size (number of ticks)
input double   ZScoreEntry          = 2.0;       // Z-Score threshold to enter (on returns)
input double   ZScoreExit           = 0.3;       // Z-Score threshold to exit (mean reached)
input int      VWAPWindowTicks      = 120;       // Micro-VWAP lookback (ticks)
input bool     UseVWAPConfirm       = true;      // Require VWAP confirmation for entry

//--- Risk Management  
input group "=== RISK MANAGEMENT ==="
input double   RiskPercentPerTrade  = 1.0;       // Risk % of equity per trade
input double   MaxDailyDrawdownPct  = 5.0;       // Max daily drawdown % (circuit breaker)
input double   MaxTotalDrawdownPct  = 15.0;      // Max total drawdown % from peak equity
input int      MaxPositionsPerSymbol= 1;         // Max positions per symbol (keep it 1!)
input double   MaxLotSize           = 0.50;      // Maximum lot size cap
input double   MinLotSize           = 0.01;      // Minimum lot size

//--- Stop Loss & Take Profit
input group "=== SL/TP & TRAILING ==="
input double   SL_ATR_Multiplier    = 1.5;       // SL = ATR × this (tight for scalping)
input double   TP_RR_Ratio          = 2.0;       // TP = SL distance × this (risk:reward)
input double   TrailingATR_Mult     = 1.0;       // Trailing stop = ATR × this
input double   BreakevenATR_Mult    = 0.8;       // Move SL to breakeven at ATR × this profit
input int      ATR_Period           = 14;        // ATR period
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M1; // ATR timeframe

//--- Spread & Volatility Filters
input group "=== FILTERS ==="
input int      MaxSpreadPoints      = 25;        // Max allowed spread (points)
input double   MinATR_Filter        = 0.0;       // Min ATR to trade (0 = auto-detect)
input bool     UseSessionFilter     = true;      // Filter by trading session
input int      SessionStartHour     = 7;         // Session start (server hour, London open)
input int      SessionEndHour       = 20;        // Session end (server hour, NY close)

//--- News Filter
input group "=== NEWS FILTER ==="
input bool     UseNewsFilter        = true;      // Enable news filter
input int      NewsMinutesBefore    = 30;        // Minutes before news to stop entries
input int      NewsMinutesAfter     = 30;        // Minutes after news to stop entries
input bool     NewsClosePositions   = false;     // Close positions on news? (false = safer)

//--- Trade Settings
input group "=== TRADE SETTINGS ==="
input int      MagicNumber          = 777888;    // Magic number
input int      TradeSlippage        = 10;        // Max slippage (points)
input string   TradeComment         = "PhantomEdge"; // Trade comment
input int      CooldownSeconds      = 5;         // Seconds between trades

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

// State tracking
datetime       LastTradeTime = 0;
double         DayStartEquity = 0;
double         PeakEquity = 0;
bool           DailyCircuitBreaker = false;
bool           TotalCircuitBreaker = false;
datetime       LastDay = 0;
datetime       LastTickTime = 0;

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
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }
   
   // Initialize equity tracking
   DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   PeakEquity = DayStartEquity;
   LastDay = TimeCurrent();
   
   Print("=== PhantomEdge TickScalper Initialized ===");
   Print("Account Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("Account Equity: ", AccountInfoDouble(ACCOUNT_EQUITY));
   Print("Symbol: ", _Symbol, " | Digits: ", _Digits);
   Print("Tick Buffer: ", TickBufferSize, " | Z-Entry: ", ZScoreEntry);
   Print("Risk per trade: ", RiskPercentPerTrade, "% | Max Daily DD: ", MaxDailyDrawdownPct, "%");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ATR_Handle != INVALID_HANDLE)
      IndicatorRelease(ATR_Handle);
      
   Print("=== PhantomEdge TickScalper Deinitialized ===");
}

//+------------------------------------------------------------------+
//| Expert tick function — THE HEART OF THE EA                        |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process ALL ticks since last call using CopyTicks
   MqlTick ticks[];
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, 0, 200);
   
   if(copied <= 0) return;
   
   // Process only new ticks (after our last processed time)
   for(int i = 0; i < copied; i++)
   {
      if(ticks[i].time_msc <= LastTickTime && LastTickTime != 0) continue;
      
      LastTickTime = ticks[i].time_msc;
      double midPrice = (ticks[i].ask + ticks[i].bid) / 2.0;
      double tickVol  = (double)ticks[i].volume;
      if(tickVol < 1) tickVol = 1;
      
      ProcessTick(midPrice, tickVol);
   }
   
   //--- Check daily reset
   CheckDailyReset();
   
   //--- Circuit breaker check
   UpdateCircuitBreakers();
   if(DailyCircuitBreaker || TotalCircuitBreaker)
   {
      ManageOpenPositions(); // Still manage exits
      return;
   }
   
   //--- Manage existing positions (trailing, breakeven, z-score exit)
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
   // Shift buffer left (oldest drops off)
   for(int i = 0; i < TickBufferSize - 1; i++)
   {
      TickPrices[i] = TickPrices[i + 1];
      TickReturns[i] = TickReturns[i + 1];
      TickVolumes[i] = TickVolumes[i + 1];
   }
   
   // Add new tick
   TickPrices[TickBufferSize - 1] = price;
   TickVolumes[TickBufferSize - 1] = volume;
   
   // Calculate log return (if we have a previous price)
   if(TickPrices[TickBufferSize - 2] > 0)
      TickReturns[TickBufferSize - 1] = MathLog(price / TickPrices[TickBufferSize - 2]);
   else
      TickReturns[TickBufferSize - 1] = 0;
   
   TickCount++;
   
   // Mark buffer as ready only after it's fully populated with real data
   if(TickCount >= TickBufferSize + 1)
      BufferReady = true;
   
   // VWAP buffer
   for(int i = 0; i < VWAPWindowTicks - 1; i++)
   {
      VWAPPrices[i] = VWAPPrices[i + 1];
      VWAPVolumes[i] = VWAPVolumes[i + 1];
   }
   VWAPPrices[VWAPWindowTicks - 1] = price;
   VWAPVolumes[VWAPWindowTicks - 1] = volume;
   VWAPCount++;
}

//+------------------------------------------------------------------+
//| Calculate Z-Score on RETURNS (not raw prices!)                     |
//+------------------------------------------------------------------+
double CalcZScore()
{
   // Calculate mean of returns
   double sum = 0;
   for(int i = 0; i < TickBufferSize; i++)
      sum += TickReturns[i];
   double mean = sum / TickBufferSize;
   
   // Calculate standard deviation of returns
   double sumSqDev = 0;
   for(int i = 0; i < TickBufferSize; i++)
   {
      double dev = TickReturns[i] - mean;
      sumSqDev += dev * dev;
   }
   double stdev = MathSqrt(sumSqDev / (TickBufferSize - 1)); // Sample stdev (N-1)
   
   if(stdev < 1e-12) return 0; // Avoid division by zero
   
   // Z-score of the LATEST return
   double zScore = (TickReturns[TickBufferSize - 1] - mean) / stdev;
   
   return zScore;
}

//+------------------------------------------------------------------+
//| Calculate Micro-VWAP (Volume-Weighted Average Price)               |
//+------------------------------------------------------------------+
double CalcMicroVWAP()
{
   if(VWAPCount < VWAPWindowTicks) return 0;
   
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
//| Calculate cumulative Z-Score (multi-tick momentum)                  |
//+------------------------------------------------------------------+
double CalcCumulativeZScore(int lookback)
{
   if(lookback > TickBufferSize) lookback = TickBufferSize;
   
   // Sum of recent returns (cumulative move)
   double cumReturn = 0;
   for(int i = TickBufferSize - lookback; i < TickBufferSize; i++)
      cumReturn += TickReturns[i];
   
   // Mean and stdev of individual returns for scaling
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
   
   // Scale cumulative return by expected stdev of sum
   double expectedStdev = stdev * MathSqrt((double)lookback);
   return (cumReturn - mean * lookback) / expectedStdev;
}

//+------------------------------------------------------------------+
//| ENTRY EVALUATION — The money-maker                                 |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double zScore = CalcZScore();
   double cumZ   = CalcCumulativeZScore(10); // 10-tick momentum check
   double vwap   = CalcMicroVWAP();
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid    = (ask + bid) / 2.0;
   
   // Get ATR for SL/TP calculation
   double atr = GetATR();
   if(atr <= 0) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return;
   
   //=== BUY SIGNAL ===
   // Tick returns show extreme negative deviation (price crashed down relative to recent behavior)
   // AND cumulative momentum confirms the dip (not just noise)
   // AND price is below VWAP (undervalued) — mean reversion BUY
   bool buySignal = (zScore <= -ZScoreEntry) && (cumZ <= -1.0);
   
   if(UseVWAPConfirm && vwap > 0)
      buySignal = buySignal && (mid < vwap); // Price below fair value
   
   //=== SELL SIGNAL ===
   // Tick returns show extreme positive deviation (price spiked up)
   // AND cumulative momentum confirms the spike
   // AND price is above VWAP (overvalued) — mean reversion SELL
   bool sellSignal = (zScore >= ZScoreEntry) && (cumZ >= 1.0);
   
   if(UseVWAPConfirm && vwap > 0)
      sellSignal = sellSignal && (mid > vwap); // Price above fair value
   
   //=== EXECUTE ===
   if(buySignal)
   {
      double sl = NormalizeDouble(ask - atr * SL_ATR_Multiplier, _Digits);
      double tp = NormalizeDouble(ask + atr * SL_ATR_Multiplier * TP_RR_Ratio, _Digits);
      
      // Ensure stops are valid
      if(!ValidateStops(ORDER_TYPE_BUY, ask, sl, tp)) return;
      
      double lots = CalcLotSize(MathAbs(ask - sl) / point);
      
      if(trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();
         Print(">>> BUY | Z=", DoubleToString(zScore, 2), 
               " CumZ=", DoubleToString(cumZ, 2),
               " VWAP=", DoubleToString(vwap, _Digits),
               " Lots=", DoubleToString(lots, 2),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits));
      }
   }
   else if(sellSignal)
   {
      double sl = NormalizeDouble(bid + atr * SL_ATR_Multiplier, _Digits);
      double tp = NormalizeDouble(bid - atr * SL_ATR_Multiplier * TP_RR_Ratio, _Digits);
      
      if(!ValidateStops(ORDER_TYPE_SELL, bid, sl, tp)) return;
      
      double lots = CalcLotSize(MathAbs(sl - bid) / point);
      
      if(trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();
         Print(">>> SELL | Z=", DoubleToString(zScore, 2),
               " CumZ=", DoubleToString(cumZ, 2),
               " VWAP=", DoubleToString(vwap, _Digits),
               " Lots=", DoubleToString(lots, 2),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS — Trailing, breakeven, Z-score exit          |
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
      
      //--- Z-Score exit: if price has reverted back to mean, close early
      if(BufferReady)
      {
         double zNow = CalcZScore();
         double cumZNow = CalcCumulativeZScore(10);
         
         if(posType == POSITION_TYPE_BUY && zNow >= ZScoreExit && cumZNow >= 0)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               trade.PositionClose(ticket);
               Print("<<< BUY CLOSED (Z-revert) | Z=", DoubleToString(zNow, 2),
                     " Profit=", DoubleToString(profit, 2));
               continue;
            }
         }
         else if(posType == POSITION_TYPE_SELL && zNow <= -ZScoreExit && cumZNow <= 0)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               trade.PositionClose(ticket);
               Print("<<< SELL CLOSED (Z-revert) | Z=", DoubleToString(zNow, 2),
                     " Profit=", DoubleToString(profit, 2));
               continue;
            }
         }
      }
      
      //--- Breakeven logic
      double breakevenDist = atr * BreakevenATR_Mult;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         // Move to breakeven
         if(bid >= openPrice + breakevenDist && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + point * 2, _Digits); // Tiny profit guaranteed
            if(newSL > currentSL)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("--- BUY BREAKEVEN | NewSL=", DoubleToString(newSL, _Digits));
            }
         }
         
         // Trailing stop
         double trailLevel = bid - atr * TrailingATR_Mult;
         trailLevel = NormalizeDouble(trailLevel, _Digits);
         
         if(trailLevel > currentSL && trailLevel > openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // Move to breakeven
         if(ask <= openPrice - breakevenDist && (currentSL > openPrice || currentSL == 0))
         {
            double newSL = NormalizeDouble(openPrice - point * 2, _Digits);
            if(currentSL == 0 || newSL < currentSL)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("--- SELL BREAKEVEN | NewSL=", DoubleToString(newSL, _Digits));
            }
         }
         
         // Trailing stop
         double trailLevel = ask + atr * TrailingATR_Mult;
         trailLevel = NormalizeDouble(trailLevel, _Digits);
         
         if((trailLevel < currentSL || currentSL == 0) && trailLevel < openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| DYNAMIC LOT SIZING — Based on equity and risk %                    |
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
   
   // Convert SL distance to monetary risk per lot
   double riskPerLot = (slDistancePoints * point / tickSize) * tickValue;
   
   if(riskPerLot <= 0) return MinLotSize;
   
   double lots = riskAmount / riskPerLot;
   
   // Round to lot step
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
//| CIRCUIT BREAKERS — Protect the account                             |
//+------------------------------------------------------------------+
void UpdateCircuitBreakers()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Track peak equity
   if(equity > PeakEquity)
      PeakEquity = equity;
   
   // Daily drawdown check
   if(DayStartEquity > 0)
   {
      double dailyDD = ((DayStartEquity - equity) / DayStartEquity) * 100.0;
      if(dailyDD >= MaxDailyDrawdownPct)
      {
         if(!DailyCircuitBreaker)
         {
            DailyCircuitBreaker = true;
            Print("!!! DAILY CIRCUIT BREAKER TRIGGERED !!! DD=", DoubleToString(dailyDD, 2), "%");
            Print("!!! No new trades until tomorrow. Managing exits only.");
         }
      }
   }
   
   // Total drawdown from peak
   if(PeakEquity > 0)
   {
      double totalDD = ((PeakEquity - equity) / PeakEquity) * 100.0;
      if(totalDD >= MaxTotalDrawdownPct)
      {
         if(!TotalCircuitBreaker)
         {
            TotalCircuitBreaker = true;
            Print("!!! TOTAL CIRCUIT BREAKER TRIGGERED !!! DD from peak=", DoubleToString(totalDD, 2), "%");
            Print("!!! EA STOPPED. Manual intervention required.");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Daily reset                                                        |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   
   MqlDateTime last;
   TimeToStruct(LastDay, last);
   
   if(now.day != last.day || now.mon != last.mon)
   {
      DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      DailyCircuitBreaker = false;
      LastDay = TimeCurrent();
      Print("=== NEW DAY | Equity Reset: ", DoubleToString(DayStartEquity, 2), " ===");
   }
}

//+------------------------------------------------------------------+
//| FILTER CHECKS                                                      |
//+------------------------------------------------------------------+
bool PassesAllFilters()
{
   // Spread filter
   double spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpreadPoints)
      return false;
   
   // ATR volatility filter  
   double atr = GetATR();
   double minATR = MinATR_Filter;
   
   // Auto-detect minimum ATR if set to 0
   if(minATR <= 0)
   {
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      minATR = spreadPoints * point * 2; // At least 2× spread of movement
   }
   
   if(atr < minATR)
      return false;
   
   // Session filter
   if(UseSessionFilter)
   {
      MqlDateTime serverTime;
      TimeToStruct(TimeCurrent(), serverTime);
      
      if(SessionStartHour < SessionEndHour)
      {
         if(serverTime.hour < SessionStartHour || serverTime.hour >= SessionEndHour)
            return false;
      }
      else // Wraps midnight
      {
         if(serverTime.hour < SessionStartHour && serverTime.hour >= SessionEndHour)
            return false;
      }
   }
   
   // News filter
   if(UseNewsFilter && IsNewsTime())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| NEWS FILTER — Uses MT5 Economic Calendar                           |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   datetime now = TimeCurrent();
   
   // Query window: from (NewsPauseAfterMin ago) to (NewsPauseBeforeMin ahead)
   // This fixes the bug in your previous EAs that only looked 60 seconds back!
   datetime from = now - (NewsMinutesAfter * 60);
   datetime to   = now + (NewsMinutesBefore * 60);
   
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to);
   
   if(count <= 0) return false;
   
   // Get the currencies in our symbol
   string baseCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quoteCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   
   // For gold/indices/crypto, watch USD
   string symbolName = _Symbol;
   StringToUpper(symbolName);
   bool isGoldOrIndex = (StringFind(symbolName, "XAU") >= 0 || 
                         StringFind(symbolName, "GOLD") >= 0 ||
                         StringFind(symbolName, "US30") >= 0 ||
                         StringFind(symbolName, "NAS") >= 0 ||
                         StringFind(symbolName, "SPX") >= 0 ||
                         StringFind(symbolName, "BTC") >= 0 ||
                         StringFind(symbolName, "ETH") >= 0);
   
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
         continue;
      
      // Only HIGH impact
      if(event.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      
      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country))
         continue;
      
      string eventCurrency = country.currency;
      StringToUpper(eventCurrency);
      
      bool relevant = false;
      
      if(isGoldOrIndex)
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
         // Check if we're within the blocking window
         datetime eventTime = values[i].time;
         
         if(now >= eventTime - NewsMinutesBefore * 60 && 
            now <= eventTime + NewsMinutesAfter * 60)
         {
            Print("NEWS BLOCK: ", event.name, " at ", TimeToString(eventTime));
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| VALIDATE STOPS — Broker-safe                                       |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE orderType, double price, double sl, double tp)
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Minimum distance from price
   double minDist = MathMax((double)stopsLevel, (double)freezeLevel) * point;
   double spreadDist = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point * 3; // 3× spread safety
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
//| Get current ATR value                                              |
//+------------------------------------------------------------------+
double GetATR()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   
   if(CopyBuffer(ATR_Handle, 0, 0, 1, atrBuffer) <= 0)
      return 0;
   
   return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Count our open positions on this symbol                            |
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
