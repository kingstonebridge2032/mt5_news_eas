//+------------------------------------------------------------------+
//| Tick_Reversion_Pro.mq5                                           |
//| WITH HIGH IMPACT NEWS FILTER                                     |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input double ForexLotSize=0.10;
input double OtherLotSize=0.01;
input int LookbackTicks=50;
input double DeviationThreshold=1.5;
input int ATRPeriod=14;
input double ATRMultiplier=2.5;
input double RiskReward=4.0;
input int MaxPositionsPerSymbol=2;
input bool UseEMA200=true;
input double ProfitTargetPerLot=100.0;
input ulong MagicNumber=777777;

//====================================================
// NEWS FILTER
//====================================================
input bool UseNewsFilter=true;
input int NewsPauseBeforeMin=60;
input int NewsPauseAfterMin=60;

double TickBuffer[];
int atrHandle;
int emaHandle;
CTrade trade;

//====================================================
// LOT SIZE
//====================================================
double GetLotSize()
{
   string s=_Symbol;

   if(StringFind(s,"XAU")>=0 || StringFind(s,"XAG")>=0 ||
      StringFind(s,"BTC")>=0 || StringFind(s,"ETH")>=0 ||
      StringFind(s,"US30")>=0 || StringFind(s,"NAS")>=0 ||
      StringFind(s,"GER")>=0)
      return OtherLotSize;

   return ForexLotSize;
}

//====================================================
// POSITION COUNT
//====================================================
int CountPositionsForSymbol()
{
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      count++;
   }

   return count;
}

//====================================================
// TREND FILTER
//====================================================
bool TrendFilter(ENUM_ORDER_TYPE type)
{
   if(!UseEMA200)
      return true;

   double ema[1];

   if(CopyBuffer(emaHandle,0,1,1,ema)<1)
      return false;

   double close=iClose(_Symbol,_Period,1);

   if(type==ORDER_TYPE_BUY)
      return close>ema[0];

   return close<ema[0];
}

//====================================================
// DYNAMIC STOP
//====================================================
double DynamicStopDistance()
{
   double atr[1];

   if(CopyBuffer(atrHandle,0,0,1,atr)<1)
      return 100*_Point;

   double stopLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freezeLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   double spread=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double brokerMin=MathMax(MathMax(stopLevel,freezeLevel),spread*10.0);

   return MathMax(atr[0]*ATRMultiplier,brokerMin*3.0);
}

//====================================================
// MANAGE PROFIT TARGET
//====================================================
void ManageProfitTarget()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      double profit=PositionGetDouble(POSITION_PROFIT);
      double volume=PositionGetDouble(POSITION_VOLUME);

      if(profit>=volume*ProfitTargetPerLot)
         trade.PositionClose(ticket);
   }
}

//====================================================
// MANAGE TRAILING
//====================================================
void ManageTrailing()
{
   double dist=DynamicStopDistance();

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      ENUM_POSITION_TYPE pos=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);

      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      if(pos==POSITION_TYPE_BUY)
      {
         double newSL=NormalizeDouble(bid-dist,_Digits);

         if(newSL>sl)
            trade.PositionModify(ticket,newSL,tp);
      }
      else
      {
         double newSL=NormalizeDouble(ask+dist,_Digits);

         if(sl==0 || newSL<sl)
            trade.PositionModify(ticket,newSL,tp);
      }
   }
}

//====================================================
// CLOSE ALL POSITIONS
//====================================================
void CloseAllPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);

      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      trade.PositionClose(ticket);
   }
}

//====================================================
// NEWS FILTER
//====================================================
bool IsHighImpactNewsTime()
{
   MqlCalendarValue values[];

   datetime now  = TimeCurrent();
   datetime from = now - 60;
   datetime to   = now + (NewsPauseBeforeMin * 60);

   int count=CalendarValueHistory(values,from,to);

   if(count<=0)
      return false;

   string symbolCurrency1=StringSubstr(_Symbol,0,3);
   string symbolCurrency2=StringSubstr(_Symbol,3,3);

   for(int i=0;i<count;i++)
   {
      MqlCalendarEvent event;

      if(!CalendarEventById(values[i].event_id,event))
         continue;

      if(event.importance!=CALENDAR_IMPORTANCE_HIGH)
         continue;

      MqlCalendarCountry country;

      if(!CalendarCountryById(event.country_id,country))
         continue;

      string currency=country.currency;

      bool relevant=false;

      // GOLD/SILVER/CRYPTO/INDICES -> USD NEWS
      if(StringFind(_Symbol,"XAU")>=0 ||
         StringFind(_Symbol,"XAG")>=0 ||
         StringFind(_Symbol,"BTC")>=0 ||
         StringFind(_Symbol,"ETH")>=0 ||
         StringFind(_Symbol,"US30")>=0 ||
         StringFind(_Symbol,"NAS")>=0 ||
         StringFind(_Symbol,"GER")>=0)
      {
         if(currency=="USD")
            relevant=true;
      }
      else
      {
         if(currency==symbolCurrency1 ||
            currency==symbolCurrency2)
            relevant=true;
      }

      if(!relevant)
         continue;

      datetime eventTime=values[i].time;

      datetime blockStart=
         eventTime-(NewsPauseBeforeMin*60);

      datetime blockEnd=
         eventTime+(NewsPauseAfterMin*60);

      if(now>=blockStart && now<=blockEnd)
         return true;
   }

   return false;
}

//====================================================
// EXECUTE DEAL
//====================================================
void ExecuteDeal(ENUM_ORDER_TYPE type)
{
   double dist=DynamicStopDistance();

   double price=(type==ORDER_TYPE_BUY)
      ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
      : SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double sl=(type==ORDER_TYPE_BUY) ? price-dist : price+dist;
   double tp=(type==ORDER_TYPE_BUY) ? price+dist*RiskReward : price-dist*RiskReward;

   trade.PositionOpen(
      _Symbol,
      type,
      GetLotSize(),
      price,
      NormalizeDouble(sl,_Digits),
      NormalizeDouble(tp,_Digits),
      "TickReversionProNews"
   );
}

//====================================================
// INIT
//====================================================
int OnInit()
{
   ArrayResize(TickBuffer,LookbackTicks);
   ArrayInitialize(TickBuffer,0);

   atrHandle=iATR(_Symbol,_Period,ATRPeriod);
   emaHandle=iMA(_Symbol,_Period,200,0,MODE_EMA,PRICE_CLOSE);

   trade.SetExpertMagicNumber(MagicNumber);

   return(INIT_SUCCEEDED);
}

//====================================================
// ON TICK
//====================================================
void OnTick()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   for(int i=LookbackTicks-1;i>0;i--)
      TickBuffer[i]=TickBuffer[i-1];

   TickBuffer[0]=bid;

   //================================================
   // NEWS FILTER
   //================================================
   if(UseNewsFilter && IsHighImpactNewsTime())
   {
      CloseAllPositions();
      return;
   }

   ManageProfitTarget();
   ManageTrailing();

   if(TickBuffer[LookbackTicks-1]==0)
      return;

   if(CountPositionsForSymbol()>=MaxPositionsPerSymbol)
      return;

   double sum=0;

   for(int i=0;i<LookbackTicks;i++)
      sum+=TickBuffer[i];

   double avg=sum/LookbackTicks;

   double var=0;

   for(int i=0;i<LookbackTicks;i++)
      var+=MathPow(TickBuffer[i]-avg,2);

   double sd=MathSqrt(var/LookbackTicks);

   if(sd<=0)
      return;

   double z=(bid-avg)/sd;

   //================================================
   // ORIGINAL STRATEGY LOGIC UNCHANGED
   //================================================
   if(z<=-DeviationThreshold && TrendFilter(ORDER_TYPE_BUY))
      ExecuteDeal(ORDER_TYPE_BUY);

   if(z>=DeviationThreshold && TrendFilter(ORDER_TYPE_SELL))
      ExecuteDeal(ORDER_TYPE_SELL);
}
//+------------------------------------------------------------------+