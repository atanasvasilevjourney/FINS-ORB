#property strict
#property description "NQ ORB strategy for prop-style risk control (Apex/Topstep style)."

#include <Trade/Trade.mqh>
CTrade trade;

input string InpAllowedSymbol           = "MNQ1!";
input int    InpOpenRangeStartHourNY    = 9;
input int    InpOpenRangeStartMinuteNY  = 30;
input int    InpOpenRangeEndHourNY      = 9;
input int    InpOpenRangeEndMinuteNY    = 45;
input int    InpSessionStartHourNY      = 9;
input int    InpSessionStartMinuteNY    = 45;
input int    InpSessionEndHourNY        = 14;
input int    InpSessionEndMinuteNY      = 0;

input double InpSLBufferPoints          = 0.0;
input double InpProfitTargetFactor      = 4.0;
input double InpMaxSLPoints             = 80.0;

input bool   InpUseTrailingStop         = true;
input double InpTrailActivatePoints     = 20.0;
input double InpTrailBufferPoints       = 8.0;

enum ENUM_RISK_TYPE { RISK_FIXED_USD=0, RISK_PERCENT=1, RISK_FIXED_CONTRACTS=2 };
input ENUM_RISK_TYPE InpRiskType        = RISK_FIXED_CONTRACTS;
input double InpRiskAmount              = 1.0;

input bool   InpUseLimitPullback        = true;
input double InpLimitDistancePoints     = 8.0;

input bool   InpTradeMonday             = true;
input bool   InpTradeTuesday            = false;
input bool   InpTradeWednesday          = true;
input bool   InpTradeThursday           = false;
input bool   InpTradeFriday             = true;

input int    InpMaxTradesPerDay         = 1;
enum ENUM_EXIT_TRIGGER { EXIT_CANDLE_CLOSE=0, EXIT_TOUCH=1 };
input ENUM_EXIT_TRIGGER InpExitTrigger  = EXIT_CANDLE_CLOSE;

// state
int      g_lastBarTime = 0;
int      g_tradesToday = 0;
int      g_lastNyDayKey = -1;
bool     g_orReady = false;
double   g_orHigh = 0.0;
double   g_orLow = 0.0;
bool     g_waitLongPullback = false;
bool     g_waitShortPullback = false;
double   g_longPullbackPrice = 0.0;
double   g_shortPullbackPrice = 0.0;
double   g_curSL = 0.0;
double   g_curTP = 0.0;

bool IsUsDst(datetime nyLike)
{
   MqlDateTime t;
   TimeToStruct(nyLike, t);
   datetime march1 = StringToTime(StringFormat("%04d.03.01 00:00", t.year));
   datetime nov1   = StringToTime(StringFormat("%04d.11.01 00:00", t.year));

   MqlDateTime m1; TimeToStruct(march1, m1);
   int firstSundayMarchOffset = (7 - m1.day_of_week) % 7;
   int secondSundayMarchDay = 1 + firstSundayMarchOffset + 7;

   MqlDateTime n1; TimeToStruct(nov1, n1);
   int firstSundayNovOffset = (7 - n1.day_of_week) % 7;
   int firstSundayNovDay = 1 + firstSundayNovOffset;

   datetime dstStart = StringToTime(StringFormat("%04d.03.%02d 02:00", t.year, secondSundayMarchDay));
   datetime dstEnd   = StringToTime(StringFormat("%04d.11.%02d 02:00", t.year, firstSundayNovDay));

   return (nyLike >= dstStart && nyLike < dstEnd);
}

datetime ServerToNewYork(datetime serverTime)
{
   // Approximation: infer UTC via TimeGMT() offset then apply NY offset with DST.
   int serverToUtc = (int)(TimeCurrent() - TimeGMT());
   datetime utc = serverTime - serverToUtc;
   // Use EST baseline then DST correction.
   datetime estCandidate = utc - 5 * 3600;
   bool dst = IsUsDst(estCandidate);
   int nyOffset = dst ? -4 : -5;
   return utc + nyOffset * 3600;
}

int NyDayKey(datetime nyTime)
{
   MqlDateTime t;
   TimeToStruct(nyTime, t);
   return t.year * 10000 + t.mon * 100 + t.day;
}

bool AllowedWeekday(datetime nyTime)
{
   MqlDateTime t;
   TimeToStruct(nyTime, t);
   // MQL: 0=Sunday, 1=Monday, ...
   if(t.day_of_week == 1) return InpTradeMonday;
   if(t.day_of_week == 2) return InpTradeTuesday;
   if(t.day_of_week == 3) return InpTradeWednesday;
   if(t.day_of_week == 4) return InpTradeThursday;
   if(t.day_of_week == 5) return InpTradeFriday;
   return false;
}

int MinutesOfDay(datetime nyTime)
{
   MqlDateTime t; TimeToStruct(nyTime, t);
   return t.hour * 60 + t.min;
}

bool InWindow(int nowMin, int sh, int sm, int eh, int em)
{
   int a = sh * 60 + sm;
   int b = eh * 60 + em;
   return nowMin >= a && nowMin < b;
}

double CalcLots(double slPoints)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = _Point;

   if(tickSize <= 0 || tickValue <= 0 || point <= 0) return 0.0;

   double perPointPerLot = tickValue * (point / tickSize);
   double lossPerLot = slPoints * perPointPerLot;
   if(lossPerLot <= 0) return 0.0;

   double lots = 0.0;
   if(InpRiskType == RISK_FIXED_CONTRACTS)
      lots = InpRiskAmount;
   else if(InpRiskType == RISK_FIXED_USD)
      lots = InpRiskAmount / lossPerLot;
   else
      lots = (AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskAmount / 100.0)) / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minLot, MathMin(maxLot, MathFloor(lots / step) * step));
   return lots;
}

void ResetDay()
{
   g_orReady = false;
   g_orHigh = 0.0;
   g_orLow = 0.0;
   g_tradesToday = 0;
   g_waitLongPullback = false;
   g_waitShortPullback = false;
   g_longPullbackPrice = 0.0;
   g_shortPullbackPrice = 0.0;
}

bool HasPosition()
{
   return PositionSelect(_Symbol);
}

void ManagePosition(double bid, double ask)
{
   if(!HasPosition()) return;

   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   double price = (type == POSITION_TYPE_BUY) ? bid : ask;
   double profitPts = (type == POSITION_TYPE_BUY) ? (price - entry) / _Point : (entry - price) / _Point;

   if(InpUseTrailingStop && profitPts >= InpTrailActivatePoints)
   {
      double newSL = (type == POSITION_TYPE_BUY) ? (price - InpTrailBufferPoints * _Point) : (price + InpTrailBufferPoints * _Point);
      if(type == POSITION_TYPE_BUY && (sl == 0.0 || newSL > sl)) trade.PositionModify(_Symbol, newSL, tp);
      if(type == POSITION_TYPE_SELL && (sl == 0.0 || newSL < sl)) trade.PositionModify(_Symbol, newSL, tp);
   }
}

int OnInit()
{
   if(_Symbol != InpAllowedSymbol)
      Print("WARNING: EA optimized for ", InpAllowedSymbol, " but running on ", _Symbol);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   datetime nyNow = ServerToNewYork(TimeCurrent());
   int nyKey = NyDayKey(nyNow);
   if(nyKey != g_lastNyDayKey)
   {
      g_lastNyDayKey = nyKey;
      ResetDay();
   }

   int nowMin = MinutesOfDay(nyNow);
   bool inOR = InWindow(nowMin, InpOpenRangeStartHourNY, InpOpenRangeStartMinuteNY, InpOpenRangeEndHourNY, InpOpenRangeEndMinuteNY);
   bool inSession = InWindow(nowMin, InpSessionStartHourNY, InpSessionStartMinuteNY, InpSessionEndHourNY, InpSessionEndMinuteNY);

   if(!inSession && HasPosition())
      trade.PositionClose(_Symbol);

   ManagePosition(bid, ask);

   if(barTime == g_lastBarTime) return;
   g_lastBarTime = (int)barTime;

   double barHigh = iHigh(_Symbol, PERIOD_M15, 1);
   double barLow = iLow(_Symbol, PERIOD_M15, 1);
   double barClose = iClose(_Symbol, PERIOD_M15, 1);

   if(inOR)
   {
      if(!g_orReady && g_orHigh == 0.0 && g_orLow == 0.0)
      {
         g_orHigh = barHigh;
         g_orLow = barLow;
      }
      else
      {
         g_orHigh = MathMax(g_orHigh, barHigh);
         g_orLow = MathMin(g_orLow, barLow);
      }
      return;
   }

   if(!inOR && g_orHigh > 0.0 && g_orLow > 0.0)
      g_orReady = true;

   if(!AllowedWeekday(nyNow) || !inSession || !g_orReady || HasPosition() || g_tradesToday >= InpMaxTradesPerDay)
      return;

   bool longBreak = barClose > g_orHigh;
   bool shortBreak = barClose < g_orLow;

   if(longBreak)
   {
      double entry = ask;
      double stop = g_orLow - InpSLBufferPoints * _Point;
      double slPts = MathAbs(entry - stop) / _Point;
      if(slPts <= InpMaxSLPoints)
      {
         if(InpUseLimitPullback)
         {
            g_waitLongPullback = true;
            g_longPullbackPrice = entry - InpLimitDistancePoints * _Point;
         }
         else
         {
            double lots = CalcLots(slPts);
            double tp = entry + (slPts * InpProfitTargetFactor) * _Point;
            if(InpExitTrigger == EXIT_TOUCH)
               trade.Buy(lots, _Symbol, 0.0, stop, tp);
            else
               trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0);
            g_curSL = stop;
            g_curTP = tp;
            g_tradesToday++;
         }
      }
   }

   if(shortBreak)
   {
      double entry = bid;
      double stop = g_orHigh + InpSLBufferPoints * _Point;
      double slPts = MathAbs(stop - entry) / _Point;
      if(slPts <= InpMaxSLPoints)
      {
         if(InpUseLimitPullback)
         {
            g_waitShortPullback = true;
            g_shortPullbackPrice = entry + InpLimitDistancePoints * _Point;
         }
         else
         {
            double lots = CalcLots(slPts);
            double tp = entry - (slPts * InpProfitTargetFactor) * _Point;
            if(InpExitTrigger == EXIT_TOUCH)
               trade.Sell(lots, _Symbol, 0.0, stop, tp);
            else
               trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0);
            g_curSL = stop;
            g_curTP = tp;
            g_tradesToday++;
         }
      }
   }

   if(g_waitLongPullback && bid <= g_longPullbackPrice && !HasPosition())
   {
      double stop = g_orLow - InpSLBufferPoints * _Point;
      double slPts = MathAbs(g_longPullbackPrice - stop) / _Point;
      if(slPts <= InpMaxSLPoints)
      {
         double lots = CalcLots(slPts);
         double tp = g_longPullbackPrice + (slPts * InpProfitTargetFactor) * _Point;
         if(InpExitTrigger == EXIT_TOUCH)
            trade.Buy(lots, _Symbol, 0.0, stop, tp);
         else
            trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0);
         g_curSL = stop;
         g_curTP = tp;
         g_tradesToday++;
      }
      g_waitLongPullback = false;
   }

   if(g_waitShortPullback && ask >= g_shortPullbackPrice && !HasPosition())
   {
      double stop = g_orHigh + InpSLBufferPoints * _Point;
      double slPts = MathAbs(stop - g_shortPullbackPrice) / _Point;
      if(slPts <= InpMaxSLPoints)
      {
         double lots = CalcLots(slPts);
         double tp = g_shortPullbackPrice - (slPts * InpProfitTargetFactor) * _Point;
         if(InpExitTrigger == EXIT_TOUCH)
            trade.Sell(lots, _Symbol, 0.0, stop, tp);
         else
            trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0);
         g_curSL = stop;
         g_curTP = tp;
         g_tradesToday++;
      }
      g_waitShortPullback = false;
   }

   // Candle-close exit mode checks on completed bar.
   if(InpExitTrigger == EXIT_CANDLE_CLOSE && HasPosition())
   {
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY && (barClose <= g_curSL || barClose >= g_curTP)) trade.PositionClose(_Symbol);
      if(type == POSITION_TYPE_SELL && (barClose >= g_curSL || barClose <= g_curTP)) trade.PositionClose(_Symbol);
   }
}
