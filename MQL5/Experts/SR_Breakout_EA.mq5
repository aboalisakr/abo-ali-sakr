//+------------------------------------------------------------------+
//|                                              SR_Breakout_EA.mq5 |
//|  Support / Resistance breakout Expert Advisor for MetaTrader 5   |
//|                                                                  |
//|  - Lot size: 0.01 for every 100$ of account balance              |
//|  - Detects S/R zones from swing highs/lows and draws them        |
//|  - Close beyond resistance & hold  -> BUY                        |
//|  - Close beyond support    & hold  -> SELL                        |
//|  - TP: fixed $ move from market price, or 1$ before prior swing  |
//|  - SL: 2$ beyond the broken zone                                 |
//+------------------------------------------------------------------+
#property copyright "abo-ali-sakr"
#property version   "1.00"
#property description "S/R breakout EA: 0.01 lot per 100$, TP 10$ or before previous swing, SL 2$ beyond zone"

#include <Trade\Trade.mqh>

enum ENUM_TARGET_MODE
  {
   TARGET_FIXED_DISTANCE = 0, // Fixed distance from market price (e.g. 10$)
   TARGET_BEFORE_SWING   = 1  // 1$ before the previous high / low
  };

//--- inputs
input group "Money management"
input double           InpLotPer100         = 0.01;        // Lot per balance step
input double           InpBalanceStep       = 100.0;       // Balance step ($)
input double           InpMaxLot            = 50.0;        // Maximum lot

input group "Support / Resistance zones"
input ENUM_TIMEFRAMES  InpSRTimeframe       = PERIOD_H1;   // Timeframe used to find S/R
input int              InpSRLookback        = 200;         // Bars scanned for swings
input int              InpSwingStrength     = 3;           // Bars on each side of a swing
input double           InpZoneMergeDistance = 3.0;         // Max zone width when merging swings ($)
input double           InpMinZoneHeight     = 1.0;         // Minimum zone height ($)
input int              InpMinTouches        = 2;           // Minimum swings that form a zone

input group "Breakout confirmation"
input ENUM_TIMEFRAMES  InpSignalTimeframe   = PERIOD_M15;  // Timeframe used to confirm the break
input int              InpConfirmBars       = 2;           // Closed candles that must hold beyond the zone
input double           InpBreakBuffer       = 0.5;         // Close must be this far beyond the zone ($)

input group "Trade settings"
input ENUM_TARGET_MODE InpTargetMode        = TARGET_FIXED_DISTANCE; // Take-profit mode
input double           InpTargetDistance    = 10.0;        // Fixed target distance ($)
input double           InpSwingOffset       = 1.0;         // Target offset before previous swing ($)
input double           InpMinTargetDistance = 3.0;         // Swing mode: minimum target distance ($)
input bool             InpFallbackToFixed   = true;        // Swing mode: use fixed target if no swing found
input double           InpSLBuffer          = 2.0;         // Stop loss beyond the zone ($)
input double           InpMaxSLDistance     = 10.0;        // Skip trade if SL farther than this ($, 0 = off)
input double           InpMaxSpread         = 1.0;         // Maximum spread ($, 0 = off)
input bool             InpAllowBuy          = true;        // Allow buy trades
input bool             InpAllowSell         = true;        // Allow sell trades
input int              InpMaxPositions      = 1;           // Maximum open positions
input ulong            InpMagic             = 20261014;    // Magic number
input int              InpSlippagePoints    = 30;          // Max slippage (points)

input group "Breakeven"
input double           InpBreakevenTrigger  = 5.0;         // Move SL to entry after this profit ($, 0 = off)
input double           InpBreakevenOffset   = 0.5;         // SL placed this far past entry ($)

input group "Time filter (server time)"
input bool             InpUseTimeFilter     = true;        // Block new trades during the hours below
input int              InpNoTradeStartHour  = 15;          // Block from this hour
input int              InpNoTradeEndHour    = 17;          // Until this hour (not included)

input group "Display"
input bool             InpDrawZones         = true;        // Draw zones on the chart
input color            InpSupportColor      = clrSeaGreen;  // Support zone color
input color            InpResistanceColor   = clrIndianRed; // Resistance zone color
input color            InpInsideColor       = clrGoldenrod; // Zone price is currently inside

//--- types / globals
struct SRZone
  {
   double low;
   double high;
   int    touches;
  };

CTrade   g_trade;
SRZone   g_zones[];
double   g_swingHighs[];
double   g_swingLows[];
datetime g_lastSignalBar = 0;
datetime g_lastSRBar     = 0;
bool     g_showVisuals   = true;
string   g_prefix        = "SRBO_";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSRLookback < 20 || InpSwingStrength < 1 || InpConfirmBars < 1 || InpBalanceStep <= 0)
     {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // drawing and Comment() only slow down a non-visual backtest
   g_showVisuals = !(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE));

   if(BuildZones())
     {
      g_lastSRBar = iTime(_Symbol, InpSRTimeframe, 0);
      DrawZones();
     }
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpBreakevenTrigger > 0 && PositionsTotal() > 0)
      ManageBreakeven();

   datetime barTime = iTime(_Symbol, InpSignalTimeframe, 0);
   if(barTime == 0 || barTime == g_lastSignalBar)
      return;

   // zones only change when a new S/R-timeframe bar opens
   datetime srTime = iTime(_Symbol, InpSRTimeframe, 0);
   if(srTime != g_lastSRBar)
     {
      // history for the S/R timeframe may still be loading: retry next tick
      if(!BuildZones())
         return;
      g_lastSRBar = srTime;
     }
   g_lastSignalBar = barTime;

   DrawZones();
   if(!IsBlockedHour())
      CheckBreakouts();
  }

//+------------------------------------------------------------------+
//| True when new trades are not allowed at the current server hour  |
//+------------------------------------------------------------------+
bool IsBlockedHour()
  {
   if(!InpUseTimeFilter || InpNoTradeStartHour == InpNoTradeEndHour)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpNoTradeStartHour < InpNoTradeEndHour)
      return dt.hour >= InpNoTradeStartHour && dt.hour < InpNoTradeEndHour;
   // range wraps past midnight, e.g. 22 -> 2
   return dt.hour >= InpNoTradeStartHour || dt.hour < InpNoTradeEndHour;
  }

//+------------------------------------------------------------------+
//| Move SL to entry +/- offset once price moved InpBreakevenTrigger |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         double newSl = NormalizeDouble(open + InpBreakevenOffset, _Digits);
         if(t.bid - open >= InpBreakevenTrigger && sl < newSl && t.bid - newSl >= minDist)
            g_trade.PositionModify(ticket, newSl, tp);
        }
      else
        {
         double newSl = NormalizeDouble(open - InpBreakevenOffset, _Digits);
         if(open - t.ask >= InpBreakevenTrigger && (sl == 0 || sl > newSl) && newSl - t.ask >= minDist)
            g_trade.PositionModify(ticket, newSl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Find swing highs/lows and merge them into zones                  |
//+------------------------------------------------------------------+
bool BuildZones()
  {
   int k    = InpSwingStrength;
   int need = InpSRLookback + 2 * k + 2;

   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(_Symbol, InpSRTimeframe, 0, need, h) < need)
      return false;
   if(CopyLow(_Symbol, InpSRTimeframe, 0, need, l) < need)
      return false;

   ArrayResize(g_swingHighs, 0);
   ArrayResize(g_swingLows, 0);

   // bar 0 is still forming, so the newest possible swing is bar k+1
   for(int i = k + 1; i < need - k; i++)
     {
      bool isHigh = true, isLow = true;
      for(int j = 1; j <= k; j++)
        {
         if(h[i] <= h[i - j] || h[i] < h[i + j])
            isHigh = false;
         if(l[i] >= l[i - j] || l[i] > l[i + j])
            isLow = false;
        }
      if(isHigh)
         PushDouble(g_swingHighs, h[i]);
      if(isLow)
         PushDouble(g_swingLows, l[i]);
     }

   double pts[];
   ArrayCopy(pts, g_swingHighs);
   ArrayCopy(pts, g_swingLows, ArraySize(pts));
   ArraySort(pts);

   ArrayResize(g_zones, 0);
   int n = ArraySize(pts);
   int i = 0;
   while(i < n)
     {
      double lo = pts[i], hi = pts[i];
      int cnt = 1;
      int j = i + 1;
      while(j < n && pts[j] - lo <= InpZoneMergeDistance)
        {
         hi = pts[j];
         cnt++;
         j++;
        }
      if(cnt >= InpMinTouches)
        {
         if(hi - lo < InpMinZoneHeight)
           {
            double mid = (lo + hi) / 2.0;
            lo = mid - InpMinZoneHeight / 2.0;
            hi = mid + InpMinZoneHeight / 2.0;
           }
         int z = ArraySize(g_zones);
         ArrayResize(g_zones, z + 1);
         g_zones[z].low     = lo;
         g_zones[z].high    = hi;
         g_zones[z].touches = cnt;
        }
      i = j;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| A zone is broken when the candle before the confirmation candles |
//| closed on the old side and every confirmation candle closed      |
//| beyond it. This fires once per break.                            |
//+------------------------------------------------------------------+
void CheckBreakouts()
  {
   int n = InpConfirmBars;
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, InpSignalTimeframe, 1, n + 1, c) != n + 1)
      return;

   int bestBuy = -1, bestSell = -1;
   for(int z = 0; z < ArraySize(g_zones); z++)
     {
      bool up = c[n] <= g_zones[z].high;
      bool dn = c[n] >= g_zones[z].low;
      for(int k = 0; k < n; k++)
        {
         if(c[k] <= g_zones[z].high + InpBreakBuffer)
            up = false;
         if(c[k] >= g_zones[z].low - InpBreakBuffer)
            dn = false;
        }
      // when several zones are broken at once, use the nearest one for the stop
      if(up && (bestBuy < 0 || g_zones[z].high > g_zones[bestBuy].high))
         bestBuy = z;
      if(dn && (bestSell < 0 || g_zones[z].low < g_zones[bestSell].low))
         bestSell = z;
     }

   if(bestBuy >= 0 && InpAllowBuy)
      OpenTrade(true, g_zones[bestBuy]);
   else if(bestSell >= 0 && InpAllowSell)
      OpenTrade(false, g_zones[bestSell]);
  }

//+------------------------------------------------------------------+
bool OpenTrade(bool isBuy, const SRZone &zone)
  {
   if(CountPositions() >= InpMaxPositions)
      return false;

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return false;
   if(InpMaxSpread > 0 && t.ask - t.bid > InpMaxSpread)
     {
      PrintFormat("Spread %.2f too high, signal skipped", t.ask - t.bid);
      return false;
     }

   double entry = isBuy ? t.ask : t.bid;
   double sl    = isBuy ? zone.low - InpSLBuffer : zone.high + InpSLBuffer;
   double tp    = CalcTakeProfit(isBuy, entry);
   if(tp <= 0)
      return false;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(InpMaxSLDistance > 0 && MathAbs(entry - sl) > InpMaxSLDistance)
     {
      PrintFormat("SL distance %.2f > max %.2f, signal skipped", MathAbs(entry - sl), InpMaxSLDistance);
      return false;
     }

   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   bool valid = isBuy ? (t.bid - sl >= minDist && tp - t.bid >= minDist && sl < t.bid && tp > t.ask)
                      : (sl - t.ask >= minDist && t.ask - tp >= minDist && sl > t.ask && tp < t.bid);
   if(!valid)
     {
      PrintFormat("Invalid stops: entry=%.2f sl=%.2f tp=%.2f", entry, sl, tp);
      return false;
     }

   double lot = CalcLot();
   string cmt = StringFormat("SR %s %.2f-%.2f", isBuy ? "break up" : "break down", zone.low, zone.high);
   bool ok = isBuy ? g_trade.Buy(lot, _Symbol, entry, sl, tp, cmt)
                   : g_trade.Sell(lot, _Symbol, entry, sl, tp, cmt);
   PrintFormat("%s %.2f lot @ %.2f SL=%.2f TP=%.2f zone=[%.2f-%.2f] -> %s (%u)",
               isBuy ? "BUY" : "SELL", lot, entry, sl, tp, zone.low, zone.high,
               ok ? "OK" : "FAILED", g_trade.ResultRetcode());
   return ok;
  }

//+------------------------------------------------------------------+
//| Fixed mode : entry +/- InpTargetDistance                         |
//| Swing mode : InpSwingOffset before the nearest previous swing    |
//|              high (buy) / low (sell) beyond the entry            |
//+------------------------------------------------------------------+
double CalcTakeProfit(bool isBuy, double entry)
  {
   double fixedTp = isBuy ? entry + InpTargetDistance : entry - InpTargetDistance;
   if(InpTargetMode == TARGET_FIXED_DISTANCE)
      return fixedTp;

   double best = 0;
   if(isBuy)
     {
      for(int i = 0; i < ArraySize(g_swingHighs); i++)
        {
         double tp = g_swingHighs[i] - InpSwingOffset;
         if(tp - entry >= InpMinTargetDistance && (best == 0 || tp < best))
            best = tp;
        }
     }
   else
     {
      for(int i = 0; i < ArraySize(g_swingLows); i++)
        {
         double tp = g_swingLows[i] + InpSwingOffset;
         if(entry - tp >= InpMinTargetDistance && (best == 0 || tp > best))
            best = tp;
        }
     }

   if(best > 0)
      return best;
   if(InpFallbackToFixed)
     {
      Print("No previous swing beyond entry, using fixed target");
      return fixedTp;
     }
   Print("No previous swing beyond entry, signal skipped");
   return 0;
  }

//+------------------------------------------------------------------+
//| 0.01 lot for every 100$ of balance, rounded to the volume step   |
//+------------------------------------------------------------------+
double CalcLot()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot     = MathFloor(balance / InpBalanceStep) * InpLotPer100;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;

   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, MathMin(maxLot, InpMaxLot));

   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lot, digits);
  }

//+------------------------------------------------------------------+
int CountPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Draw zones and show nearest support / resistance in the comment  |
//+------------------------------------------------------------------+
void DrawZones()
  {
   if(!g_showVisuals)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double nearestRes = 0, nearestSup = 0;

   if(InpDrawZones)
      ObjectsDeleteAll(0, g_prefix);

   datetime t1 = iTime(_Symbol, InpSRTimeframe, InpSRLookback);
   datetime t2 = TimeCurrent() + PeriodSeconds(InpSRTimeframe) * 20;

   for(int z = 0; z < ArraySize(g_zones); z++)
     {
      color clr = InpInsideColor;
      if(g_zones[z].low > bid)
        {
         clr = InpResistanceColor;
         if(nearestRes == 0 || g_zones[z].low < nearestRes)
            nearestRes = g_zones[z].low;
        }
      else if(g_zones[z].high < bid)
        {
         clr = InpSupportColor;
         if(g_zones[z].high > nearestSup)
            nearestSup = g_zones[z].high;
        }

      if(!InpDrawZones)
         continue;

      string name = g_prefix + "zone_" + IntegerToString(z);
      if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_zones[z].high, t2, g_zones[z].low))
        {
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, name, OBJPROP_FILL, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetString(0, name, OBJPROP_TOOLTIP,
                         StringFormat("%.2f - %.2f (%d touches)", g_zones[z].low, g_zones[z].high, g_zones[z].touches));
        }

      string label = g_prefix + "label_" + IntegerToString(z);
      if(ObjectCreate(0, label, OBJ_TEXT, 0, t2, g_zones[z].high))
        {
         ObjectSetString(0, label, OBJPROP_TEXT, StringFormat("%.2f-%.2f", g_zones[z].low, g_zones[z].high));
         ObjectSetInteger(0, label, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, label, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
         ObjectSetInteger(0, label, OBJPROP_SELECTABLE, false);
        }
     }
   ChartRedraw();

   Comment(StringFormat("SR Breakout EA\nZones: %d\nNearest resistance: %s\nNearest support: %s\nLot: %.2f\nTarget mode: %s",
                        ArraySize(g_zones),
                        nearestRes > 0 ? DoubleToString(nearestRes, _Digits) : "-",
                        nearestSup > 0 ? DoubleToString(nearestSup, _Digits) : "-",
                        CalcLot(),
                        InpTargetMode == TARGET_FIXED_DISTANCE
                           ? StringFormat("fixed %.2f$", InpTargetDistance)
                           : StringFormat("%.2f$ before previous swing", InpSwingOffset)));
  }

//+------------------------------------------------------------------+
void PushDouble(double &arr[], double v)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = v;
  }
//+------------------------------------------------------------------+
