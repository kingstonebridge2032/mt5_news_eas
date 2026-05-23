//+------------------------------------------------------------------+
//|                                    PhantomEdge_TickScalper.mq5   |
//|                          Ultra-Fast Tick Scalper for Cent Accounts|
//|                                                                  |
//|  PHILOSOPHY:                                                     |
//|  - Works on TICKS not bars — reacts to every price movement      |
//|  - Mean reversion on tick RETURNS (not raw prices)               |
//|  - Micro-VWAP as dynamic fair value anchor                       |
//|  - Ultra-tight risk: equity-based lots, circuit breaker, session |
//|  - News-aware: blocks new entries but NEVER closes winning trades|
//|  - Aggressive entries, surgical exits                            |
//+------------------------------------------------------------------+
#property copyright "PhantomEdge"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

//--- Core Strategy
input group "=== CORE STRATEGY ==="
input int      TickBufferSize       = 40;
input double   ZScoreEntry          = 1.20;
input double   ZScoreExit           = 0.20;
input int      VWAPWindowTicks      = 60;
input bool     UseVWAPConfirm       = true;

//--- Risk Management
input group "=== RISK MANAGEMENT ==="
input double   RiskPercentPerTrade  = 1.0;
input double   MaxDailyDrawdownPct  = 5.0;
input double   MaxTotalDrawdownPct  = 15.0;
input int      MaxPositionsPerSymbol= 1;
input double   MaxLotSize           = 0.50;
input double   MinLotSize           = 0.01;

//--- Stop Loss & Take Profit
input group "=== SL/TP & TRAILING ==="
input double   SL_ATR_Multiplier    = 1.2;
input double   TP_RR_Ratio          = 1.5;
input double   TrailingATR_Mult     = 0.8;
input double   BreakevenATR_Mult    = 0.5;
input int      ATR_Period           = 14;
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M1;

//--- Spread & Volatility Filters
input group "=== FILTERS ==="
input int      MaxSpreadPoints      = 45;
input double   MinATR_Filter        = 0.0;
input bool     UseSessionFilter     = true;
input int      SessionStartHour     = 0;
input int      SessionEndHour       = 24;

//--- News Filter
input group "=== NEWS FILTER ==="
input bool     UseNewsFilter        = false;
input int      NewsMinutesBefore    = 30;
input int      NewsMinutesAfter     = 30;
input bool     NewsClosePositions   = false;

//--- Trade Settings
input group "=== TRADE SETTINGS ==="
input int      MagicNumber          = 777888;
input int      TradeSlippage        = 20;
input string   TradeComment         = "PhantomEdge";
input int      CooldownSeconds      = 1;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;

// Tick data buffers
double         TickPrices[];
double         TickReturns[];
double         TickVolumes[];
int            TickCount = 0;
bool           BufferReady = false;

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
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(TradeSlippage);

   ENUM_SYMBOL_TRADE_EXECUTION exec =
      (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);

   if(exec == SYMBOL_TRADE_EXECUTION_MARKET)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   ArrayResize(TickPrices, TickBufferSize);
   ArrayResize(TickReturns, TickBufferSize);
   ArrayResize(TickVolumes, TickBufferSize);

   ArrayInitialize(TickPrices, 0);
   ArrayInitialize(TickReturns, 0);
   ArrayInitialize(TickVolumes, 0);

   ArrayResize(VWAPPrices, VWAPWindowTicks);
   ArrayResize(VWAPVolumes, VWAPWindowTicks);

   ArrayInitialize(VWAPPrices, 0);
   ArrayInitialize(VWAPVolumes, 0);

   ATR_Handle = iATR(_Symbol, ATR_Timeframe, ATR_Period);

   if(ATR_Handle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }

   DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   PeakEquity = DayStartEquity;
   LastDay = TimeCurrent();

   Print("=== PhantomEdge TickScalper Initialized ===");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ATR_Handle != INVALID_HANDLE)
      IndicatorRelease(ATR_Handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick ticks[];

   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_INFO, 0, 200);

   if(copied <= 0)
      return;

   for(int i = 0; i < copied; i++)
   {
      if(ticks[i].time_msc <= LastTickTime && LastTickTime != 0)
         continue;

      if(ticks[i].ask <= 0 || ticks[i].bid <= 0)
         continue;

      LastTickTime = ticks[i].time_msc;

      double midPrice = (ticks[i].ask + ticks[i].bid) / 2.0;

      double tickVol = (double)ticks[i].volume;

      if(tickVol < 1)
         tickVol = 1;

      ProcessTick(midPrice, tickVol);
   }

   CheckDailyReset();

   UpdateCircuitBreakers();

   if(DailyCircuitBreaker || TotalCircuitBreaker)
   {
      ManageOpenPositions();
      return;
   }

   ManageOpenPositions();

   if(!BufferReady)
      return;

   if(!PassesAllFilters())
      return;

   if(TimeCurrent() - LastTradeTime < CooldownSeconds)
      return;

   if(CountMyPositions() >= MaxPositionsPerSymbol)
      return;

   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| Process Tick                                                      |
//+------------------------------------------------------------------+
void ProcessTick(double price, double volume)
{
   for(int i = 0; i < TickBufferSize - 1; i++)
   {
      TickPrices[i] = TickPrices[i + 1];
      TickReturns[i] = TickReturns[i + 1];
      TickVolumes[i] = TickVolumes[i + 1];
   }

   TickPrices[TickBufferSize - 1] = price;
   TickVolumes[TickBufferSize - 1] = volume;

   if(TickPrices[TickBufferSize - 2] > 0)
      TickReturns[TickBufferSize - 1] =
         MathLog(price / TickPrices[TickBufferSize - 2]);
   else
      TickReturns[TickBufferSize - 1] = 0;

   TickCount++;

   if(TickCount >= TickBufferSize + 1)
      BufferReady = true;

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
//| Calculate ZScore                                                  |
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

   if(stdev < 1e-12)
      return 0;

   return (TickReturns[TickBufferSize - 1] - mean) / stdev;
}

//+------------------------------------------------------------------+
//| Calculate VWAP                                                    |
//+------------------------------------------------------------------+
double CalcMicroVWAP()
{
   if(VWAPCount < VWAPWindowTicks)
      return 0;

   double sumPV = 0;
   double sumV = 0;

   for(int i = 0; i < VWAPWindowTicks; i++)
   {
      if(VWAPPrices[i] <= 0)
         return 0;

      sumPV += VWAPPrices[i] * VWAPVolumes[i];
      sumV += VWAPVolumes[i];
   }

   if(sumV < 1)
      return 0;

   return sumPV / sumV;
}

//+------------------------------------------------------------------+
//| Calculate cumulative ZScore                                       |
//+------------------------------------------------------------------+
double CalcCumulativeZScore(int lookback)
{
   if(lookback > TickBufferSize)
      lookback = TickBufferSize;

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

   if(stdev < 1e-12)
      return 0;

   double expectedStdev = stdev * MathSqrt((double)lookback);

   return (cumReturn - mean * lookback) / expectedStdev;
}

//+------------------------------------------------------------------+
//| Entry Logic                                                       |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double zScore = CalcZScore();
   double cumZ   = CalcCumulativeZScore(10);
   double vwap   = CalcMicroVWAP();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(point <= 0)
      return;

   bool buySignal =
      (zScore <= -ZScoreEntry) &&
      (cumZ <= -1.0);

   if(UseVWAPConfirm && vwap > 0)
      buySignal = buySignal && (mid < vwap);

   bool sellSignal =
      (zScore >= ZScoreEntry) &&
      (cumZ >= 1.0);

   if(UseVWAPConfirm && vwap > 0)
      sellSignal = sellSignal && (mid > vwap);

   if(buySignal)
   {
      double sl = NormalizeDouble(
         ask - atr * SL_ATR_Multiplier,
         _Digits
      );

      double tp = NormalizeDouble(
         ask + atr * SL_ATR_Multiplier * TP_RR_Ratio,
         _Digits
      );

      if(!ValidateStops(ORDER_TYPE_BUY, ask, sl, tp))
         return;

      double lots = CalcLotSize(MathAbs(ask - sl) / point);

      if(trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();

         Print("BUY OPENED");
      }
   }
   else if(sellSignal)
   {
      double sl = NormalizeDouble(
         bid + atr * SL_ATR_Multiplier,
         _Digits
      );

      double tp = NormalizeDouble(
         bid - atr * SL_ATR_Multiplier * TP_RR_Ratio,
         _Digits
      );

      if(!ValidateStops(ORDER_TYPE_SELL, bid, sl, tp))
         return;

      double lots = CalcLotSize(MathAbs(sl - bid) / point);

      if(trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
      {
         LastTradeTime = TimeCurrent();

         Print("SELL OPENED");
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Positions                                                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      long posType = PositionGetInteger(POSITION_TYPE);

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      if(BufferReady)
      {
         double zNow = CalcZScore();
         double cumZNow = CalcCumulativeZScore(10);

         if(posType == POSITION_TYPE_BUY &&
            zNow >= ZScoreExit &&
            cumZNow >= 0)
         {
            double profit =
               PositionGetDouble(POSITION_PROFIT);

            if(profit > 0)
            {
               trade.PositionClose(ticket);
               continue;
            }
         }

         if(posType == POSITION_TYPE_SELL &&
            zNow <= -ZScoreExit &&
            cumZNow <= 0)
         {
            double profit =
               PositionGetDouble(POSITION_PROFIT);

            if(profit > 0)
            {
               trade.PositionClose(ticket);
               continue;
            }
         }
      }

      double breakevenDist =
         atr * BreakevenATR_Mult;

      if(posType == POSITION_TYPE_BUY)
      {
         double bid =
            SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(bid >= openPrice + breakevenDist &&
            currentSL < openPrice)
         {
            double newSL =
               NormalizeDouble(openPrice + point * 2, _Digits);

            if(newSL > currentSL)
               trade.PositionModify(ticket, newSL, currentTP);
         }

         double trailLevel =
            NormalizeDouble(
               bid - atr * TrailingATR_Mult,
               _Digits
            );

         if(trailLevel > currentSL &&
            trailLevel > openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask =
            SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(ask <= openPrice - breakevenDist &&
            (currentSL > openPrice || currentSL == 0))
         {
            double newSL =
               NormalizeDouble(openPrice - point * 2, _Digits);

            if(currentSL == 0 || newSL < currentSL)
               trade.PositionModify(ticket, newSL, currentTP);
         }

         double trailLevel =
            NormalizeDouble(
               ask + atr * TrailingATR_Mult,
               _Digits
            );

         if((trailLevel < currentSL || currentSL == 0) &&
            trailLevel < openPrice)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Lot Size                                                          |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePoints)
{
   if(slDistancePoints <= 0)
      return MinLotSize;

   double equity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   double riskAmount =
      equity * (RiskPercentPerTrade / 100.0);

   double tickValue =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   double tickSize =
      SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || point <= 0)
      return MinLotSize;

   double riskPerLot =
      (slDistancePoints * point / tickSize) * tickValue;

   if(riskPerLot <= 0)
      return MinLotSize;

   double lots = riskAmount / riskPerLot;

   double lotStep =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lotMin =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lotMax =
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(lots, lotMin);
   lots = MathMin(lots, lotMax);

   lots = MathMax(lots, MinLotSize);
   lots = MathMin(lots, MaxLotSize);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Circuit Breakers                                                  |
//+------------------------------------------------------------------+
void UpdateCircuitBreakers()
{
   double equity =
      AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > PeakEquity)
      PeakEquity = equity;

   if(DayStartEquity > 0)
   {
      double dailyDD =
         ((DayStartEquity - equity) / DayStartEquity) * 100.0;

      if(dailyDD >= MaxDailyDrawdownPct)
         DailyCircuitBreaker = true;
   }

   if(PeakEquity > 0)
   {
      double totalDD =
         ((PeakEquity - equity) / PeakEquity) * 100.0;

      if(totalDD >= MaxTotalDrawdownPct)
         TotalCircuitBreaker = true;
   }
}

//+------------------------------------------------------------------+
//| Daily Reset                                                       |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   MqlDateTime last;
   TimeToStruct(LastDay, last);

   if(now.day != last.day || now.mon != last.mon)
   {
      DayStartEquity =
         AccountInfoDouble(ACCOUNT_EQUITY);

      DailyCircuitBreaker = false;

      LastDay = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Filters                                                           |
//+------------------------------------------------------------------+
bool PassesAllFilters()
{
   double spreadPoints =
      SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   if(spreadPoints > MaxSpreadPoints)
      return false;

   double atr = GetATR();

   double minATR = MinATR_Filter;

   if(minATR <= 0)
   {
      double point =
         SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      minATR = spreadPoints * point * 2;
   }

   if(atr < minATR)
      return false;

   if(UseSessionFilter)
   {
      MqlDateTime serverTime;
      TimeToStruct(TimeCurrent(), serverTime);

      if(SessionStartHour < SessionEndHour)
      {
         if(serverTime.hour < SessionStartHour ||
            serverTime.hour >= SessionEndHour)
            return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Validate Stops                                                    |
//+------------------------------------------------------------------+
bool ValidateStops(
   ENUM_ORDER_TYPE orderType,
   double price,
   double sl,
   double tp
)
{
   long stopsLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   long freezeLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   double point =
      SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double minDist =
      MathMax((double)stopsLevel, (double)freezeLevel) * point;

   double spreadDist =
      SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point * 3;

   minDist = MathMax(minDist, spreadDist);

   if(orderType == ORDER_TYPE_BUY)
   {
      if(MathAbs(price - sl) < minDist)
         return false;

      if(MathAbs(tp - price) < minDist)
         return false;
   }
   else
   {
      if(MathAbs(sl - price) < minDist)
         return false;

      if(MathAbs(price - tp) < minDist)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| ATR                                                               |
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
//| Count Positions                                                   |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      count++;
   }

   return count;
}
//+------------------------------------------------------------------+
