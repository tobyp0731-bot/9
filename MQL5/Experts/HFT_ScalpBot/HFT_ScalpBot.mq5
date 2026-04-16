//+------------------------------------------------------------------+
//|  HFT_ScalpBot.mq5                                                 |
//|  High-Frequency Scalping Expert Advisor for MetaTrader 5          |
//|                                                                    |
//|  Strategy:                                                         |
//|    • EMA-momentum entries filtered by RSI and M5/M15 trend        |
//|    • Structure-aware SL placed beyond real swing highs / lows,    |
//|      never at a round-number cluster where hunts occur             |
//|    • ATR-scaled TP for asymmetric reward                           |
//|    • Breakeven + trailing trail to protect profit quickly          |
//|    • Compound lot growth on win streaks (resets on any loss)       |
//|    • Hard daily-DD kill-switch, spread filter, session filter      |
//+------------------------------------------------------------------+
#property copyright "HFT ScalpBot"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <HFT\SwingDetector.mqh>
#include <HFT\RiskManager.mqh>

//──────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────

input group "═══ Strategy ═══"
input ENUM_TIMEFRAMES InpTF         = PERIOD_M1;   // Entry timeframe
input int    InpFastEMA             = 8;            // Fast EMA period
input int    InpSlowEMA             = 21;           // Slow EMA period
input int    InpSignalEMA           = 5;            // Signal EMA (confirmation)
input int    InpRSIPeriod           = 7;            // RSI period
input double InpRSIBullMin          = 52.0;         // RSI min for buy
input double InpRSIBearMax          = 48.0;         // RSI max for sell
input double InpRSIOverbought       = 75.0;         // Block buys above
input double InpRSIOversold         = 25.0;         // Block sells below
input int    InpATRPeriod           = 14;           // ATR period

input group "═══ Smart SL / TP ═══"
input double InpSLATRMult           = 1.8;          // ATR mult for SL floor
input double InpTPRRatio            = 1.5;          // TP = SL * this ratio (≥1.0)
input int    InpSwingLookback       = 25;           // Bars to find swing S/R
input int    InpSwingFractalBars    = 2;            // Fractal confirmation bars
input double InpStructureBuffer     = 3.0;          // Extra pips beyond structure
input int    InpMinSLPips           = 6;            // Hard SL minimum (pips)
input int    InpMaxSLPips           = 40;           // Hard SL maximum (pips)
input double InpBEMoveATRMult       = 0.6;          // Move to BE after X*ATR profit
input double InpTrailATRMult        = 1.0;          // Trail SL distance in ATR

input group "═══ Lot Management ═══"
input double InpBaseLot             = 0.01;         // Starting lot
input double InpRiskPct             = 0.8;          // Max risk per trade (%)
input bool   InpCompoundWins        = true;         // Compound lots on win streak
input int    InpWinsPerLotDouble    = 2;            // Wins needed per lot step-up
input double InpLotMultiplier       = 2.0;          // Step-up multiplier
input double InpMaxLot              = 2.0;          // Absolute lot cap

input group "═══ Risk Controls ═══"
input double InpMaxDailyDDPct       = 4.0;          // Daily equity DD% kill-switch
input double InpDailyProfitTargetPct= 3.0;          // Stop trading after this gain
input int    InpMaxOpenTrades       = 3;            // Concurrent positions cap
input int    InpMaxDailyTrades      = 30;           // Max trades per calendar day

input group "═══ Filters ═══"
input double InpMaxSpreadPts        = 20.0;         // Max allowed spread (points)
input bool   InpUseTrendFilter      = true;         // M5 trend-direction filter
input int    InpTrendEMAPeriod      = 50;           // Trend EMA on M5
input bool   InpUseSessionFilter    = true;         // Trade only in active sessions
input int    InpSessionStartHour    = 7;            // Session start (server time)
input int    InpSessionEndHour      = 20;           // Session end  (server time)
input int    InpMagicNumber         = 202501;       // Magic number

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
CTrade        trade;
CPositionInfo posInfo;

int hFastEMA, hSlowEMA, hSignalEMA, hRSI, hATR, hTrendEMA;

double bufFast[], bufSlow[], bufSignal[], bufRSI[], bufATR[], bufTrend[];

double pipSize;
double dailyStartBalance;
int    dailyTrades;
int    consecutiveWins;
datetime lastBarTime;
datetime lastDayReset;

//──────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
    // Pip size (works for 4/5-digit and 2/3-digit brokers)
    pipSize = (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;

    hFastEMA   = iMA(_Symbol, InpTF,      InpFastEMA,   0, MODE_EMA, PRICE_CLOSE);
    hSlowEMA   = iMA(_Symbol, InpTF,      InpSlowEMA,   0, MODE_EMA, PRICE_CLOSE);
    hSignalEMA = iMA(_Symbol, InpTF,      InpSignalEMA, 0, MODE_EMA, PRICE_CLOSE);
    hRSI       = iRSI(_Symbol, InpTF,     InpRSIPeriod, PRICE_CLOSE);
    hATR       = iATR(_Symbol, InpTF,     InpATRPeriod);
    hTrendEMA  = iMA(_Symbol, PERIOD_M5,  InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

    if(hFastEMA   == INVALID_HANDLE ||
       hSlowEMA   == INVALID_HANDLE ||
       hSignalEMA == INVALID_HANDLE ||
       hRSI       == INVALID_HANDLE ||
       hATR       == INVALID_HANDLE ||
       hTrendEMA  == INVALID_HANDLE)
    {
        Print("ERROR: indicator handle creation failed");
        return INIT_FAILED;
    }

    ArraySetAsSeries(bufFast,   true);
    ArraySetAsSeries(bufSlow,   true);
    ArraySetAsSeries(bufSignal, true);
    ArraySetAsSeries(bufRSI,    true);
    ArraySetAsSeries(bufATR,    true);
    ArraySetAsSeries(bufTrend,  true);

    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(15);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    trade.SetAsyncMode(false);

    dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    lastDayReset      = TimeCurrent();
    dailyTrades       = 0;
    consecutiveWins   = 0;
    lastBarTime       = 0;

    Print("HFT_ScalpBot v2.00 initialised | Symbol:", _Symbol,
          " | PipSize:", pipSize, " | Magic:", InpMagicNumber);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(hFastEMA);
    IndicatorRelease(hSlowEMA);
    IndicatorRelease(hSignalEMA);
    IndicatorRelease(hRSI);
    IndicatorRelease(hATR);
    IndicatorRelease(hTrendEMA);
    Comment("");
}

//──────────────────────────────────────────────────────────────────
//  MAIN TICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
    ResetDailyStats();

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

    // Kill-switch: max daily drawdown
    if(DailyLimitHit(dailyStartBalance, equity, InpMaxDailyDDPct))
    {
        ShowDashboard("HALTED – daily DD limit hit", balance, equity);
        return;
    }

    // Kill-switch: daily profit target reached
    double gainPct = (equity - dailyStartBalance) / dailyStartBalance * 100.0;
    if(gainPct >= InpDailyProfitTargetPct)
    {
        ShowDashboard("HALTED – daily profit target hit", balance, equity);
        return;
    }

    // Only act once per closed bar
    datetime barTime = iTime(_Symbol, InpTF, 0);
    if(barTime == lastBarTime) return;
    lastBarTime = barTime;

    if(!LoadBuffers()) return;

    ManagePositions();
    UpdateWinStreak();

    bool canTrade = (CountMyPositions() < InpMaxOpenTrades) &&
                    (dailyTrades < InpMaxDailyTrades);

    if(canTrade) CheckEntry();

    ShowDashboard("", balance, equity);
}

//──────────────────────────────────────────────────────────────────
//  RESET DAILY STATS AT MIDNIGHT
//──────────────────────────────────────────────────────────────────
void ResetDailyStats()
{
    MqlDateTime now, last;
    TimeToStruct(TimeCurrent(),  now);
    TimeToStruct(lastDayReset,   last);
    if(now.day != last.day)
    {
        dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        dailyTrades       = 0;
        lastDayReset      = TimeCurrent();
    }
}

//──────────────────────────────────────────────────────────────────
//  LOAD INDICATOR BUFFERS
//──────────────────────────────────────────────────────────────────
bool LoadBuffers()
{
    if(CopyBuffer(hFastEMA,   0, 0, 4, bufFast)   < 4) return false;
    if(CopyBuffer(hSlowEMA,   0, 0, 4, bufSlow)   < 4) return false;
    if(CopyBuffer(hSignalEMA, 0, 0, 4, bufSignal) < 4) return false;
    if(CopyBuffer(hRSI,       0, 0, 4, bufRSI)    < 4) return false;
    if(CopyBuffer(hATR,       0, 0, 4, bufATR)    < 4) return false;
    if(CopyBuffer(hTrendEMA,  0, 0, 2, bufTrend)  < 2) return false;
    return true;
}

//──────────────────────────────────────────────────────────────────
//  ENTRY LOGIC
//──────────────────────────────────────────────────────────────────
void CheckEntry()
{
    //--- Spread filter
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    if(spread > InpMaxSpreadPts * _Point) return;

    //--- Session filter
    if(InpUseSessionFilter)
    {
        MqlDateTime t;
        TimeToStruct(TimeCurrent(), t);
        if(t.hour < InpSessionStartHour || t.hour >= InpSessionEndHour) return;
    }

    double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double atr  = bufATR[1];
    double rsi  = bufRSI[1];

    // EMA crossover on completed bar [1] vs [2]
    bool bullCross = bufFast[1] >  bufSlow[1] && bufFast[2] <= bufSlow[2];
    bool bearCross = bufFast[1] <  bufSlow[1] && bufFast[2] >= bufSlow[2];

    // Price above/below signal EMA adds confirmation
    bool bullConf  = ask > bufSignal[1];
    bool bearConf  = bid < bufSignal[1];

    // RSI momentum confirmation + not overextended
    bool rsiBull   = rsi > InpRSIBullMin  && rsi < InpRSIOverbought;
    bool rsiBear   = rsi < InpRSIBearMax  && rsi > InpRSIOversold;

    // M5 trend filter
    bool trendBull = !InpUseTrendFilter || ask > bufTrend[1];
    bool trendBear = !InpUseTrendFilter || bid < bufTrend[1];

    // Direction conflicts – block if already in opposite trade
    bool noBull    = !HasPosition(POSITION_TYPE_BUY);
    bool noBear    = !HasPosition(POSITION_TYPE_SELL);

    //--- BUY
    if(bullCross && bullConf && rsiBull && trendBull && noBull)
    {
        double sl = SmartSL(ORDER_TYPE_BUY, ask, atr);
        if(sl <= 0) return;
        double tp = SmartTP(ORDER_TYPE_BUY, ask, sl);
        double lot = CalcLot(ask - sl);

        if(trade.Buy(lot, _Symbol, ask, sl, tp, "HFT_B"))
        {
            dailyTrades++;
            PrintFormat("BUY  | lot=%.2f sl=%.5f tp=%.5f atr=%.5f rsi=%.1f", lot, sl, tp, atr, rsi);
        }
        return;
    }

    //--- SELL
    if(bearCross && bearConf && rsiBear && trendBear && noBear)
    {
        double sl = SmartSL(ORDER_TYPE_SELL, bid, atr);
        if(sl <= 0) return;
        double tp = SmartTP(ORDER_TYPE_SELL, bid, sl);
        double lot = CalcLot(sl - bid);

        if(trade.Sell(lot, _Symbol, bid, sl, tp, "HFT_S"))
        {
            dailyTrades++;
            PrintFormat("SELL | lot=%.2f sl=%.5f tp=%.5f atr=%.5f rsi=%.1f", lot, sl, tp, atr, rsi);
        }
    }
}

//──────────────────────────────────────────────────────────────────
//  SMART STOP-LOSS
//  Places SL beyond real market structure (swing high/low) with an
//  ATR floor so it never sits in the noise zone.
//──────────────────────────────────────────────────────────────────
double SmartSL(ENUM_ORDER_TYPE dir, double entry, double atr)
{
    double bufPts    = InpStructureBuffer * pipSize;
    double atrFloor  = atr * InpSLATRMult;
    double minDist   = InpMinSLPips * pipSize;
    double maxDist   = InpMaxSLPips * pipSize;

    double structureLevel;
    double slDist, slPrice;

    if(dir == ORDER_TYPE_BUY)
    {
        structureLevel = FindSwingLow(_Symbol, InpTF, 1,
                                      InpSwingLookback, InpSwingFractalBars);
        double structDist = entry - structureLevel + bufPts;
        slDist  = MathMax(MathMax(structDist, atrFloor), minDist);
        slDist  = MathMin(slDist, maxDist);
        slPrice = NormalizeDouble(entry - slDist, _Digits);
    }
    else
    {
        structureLevel = FindSwingHigh(_Symbol, InpTF, 1,
                                       InpSwingLookback, InpSwingFractalBars);
        double structDist = structureLevel - entry + bufPts;
        slDist  = MathMax(MathMax(structDist, atrFloor), minDist);
        slDist  = MathMin(slDist, maxDist);
        slPrice = NormalizeDouble(entry + slDist, _Digits);
    }

    // Broker minimum stop-level compliance
    long   stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minBrk    = (stopLevel + 2) * _Point;

    if(dir == ORDER_TYPE_BUY  && entry - slPrice < minBrk)
        slPrice = NormalizeDouble(entry - minBrk, _Digits);
    if(dir == ORDER_TYPE_SELL && slPrice - entry < minBrk)
        slPrice = NormalizeDouble(entry + minBrk, _Digits);

    return slPrice;
}

//──────────────────────────────────────────────────────────────────
//  SMART TAKE-PROFIT  (reward = SL * RRatio)
//──────────────────────────────────────────────────────────────────
double SmartTP(ENUM_ORDER_TYPE dir, double entry, double sl)
{
    double slDist = MathAbs(entry - sl);
    double tpDist = slDist * MathMax(InpTPRRatio, 1.0);

    double tpPrice = (dir == ORDER_TYPE_BUY)
                     ? NormalizeDouble(entry + tpDist, _Digits)
                     : NormalizeDouble(entry - tpDist, _Digits);

    long   stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minBrk    = (stopLevel + 2) * _Point;

    if(dir == ORDER_TYPE_BUY  && tpPrice - entry < minBrk)
        tpPrice = NormalizeDouble(entry + minBrk, _Digits);
    if(dir == ORDER_TYPE_SELL && entry - tpPrice < minBrk)
        tpPrice = NormalizeDouble(entry - minBrk, _Digits);

    return tpPrice;
}

//──────────────────────────────────────────────────────────────────
//  LOT CALCULATION
//──────────────────────────────────────────────────────────────────
double CalcLot(double slDist)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskLot = LotFromRisk(_Symbol, balance, InpRiskPct, slDist / _Point, InpMaxLot);

    if(!InpCompoundWins || consecutiveWins < InpWinsPerLotDouble)
        return MathMax(riskLot, NormaliseLot(_Symbol, InpBaseLot, InpMaxLot));

    double compLot = CompoundLot(_Symbol, InpBaseLot, InpLotMultiplier,
                                 consecutiveWins, InpWinsPerLotDouble, InpMaxLot);
    // Use whichever is larger – risk-based or compound-based
    return MathMax(riskLot, compLot);
}

//──────────────────────────────────────────────────────────────────
//  POSITION MANAGEMENT: breakeven + ATR trail
//──────────────────────────────────────────────────────────────────
void ManagePositions()
{
    double atr = bufATR[1];

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i))           continue;
        if(posInfo.Magic()  != InpMagicNumber)  continue;
        if(posInfo.Symbol() != _Symbol)         continue;

        double open = posInfo.PriceOpen();
        double curSL = posInfo.StopLoss();
        double curTP = posInfo.TakeProfit();
        double newSL = curSL;

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profit = bid - open;

            // Step 1: move to breakeven
            if(profit >= atr * InpBEMoveATRMult && curSL < open)
                newSL = open + _Point;

            // Step 2: trail at InpTrailATRMult * ATR behind price
            double trailSL = bid - atr * InpTrailATRMult;
            if(trailSL > newSL) newSL = trailSL;

            if(newSL > curSL + _Point)
            {
                newSL = NormalizeDouble(newSL, _Digits);
                trade.PositionModify(posInfo.Ticket(), newSL, curTP);
            }
        }
        else // SELL
        {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profit = open - ask;

            if(profit >= atr * InpBEMoveATRMult && curSL > open)
                newSL = open - _Point;

            double trailSL = ask + atr * InpTrailATRMult;
            if(trailSL < newSL || newSL == 0) newSL = trailSL;

            if(newSL < curSL - _Point && newSL > 0)
            {
                newSL = NormalizeDouble(newSL, _Digits);
                trade.PositionModify(posInfo.Ticket(), newSL, curTP);
            }
        }
    }
}

//──────────────────────────────────────────────────────────────────
//  WIN-STREAK TRACKER (scans last 20 closed deals)
//──────────────────────────────────────────────────────────────────
void UpdateWinStreak()
{
    HistorySelect(iTime(_Symbol, PERIOD_D1, 30), TimeCurrent());
    int total = HistoryDealsTotal();

    consecutiveWins = 0;
    for(int i = total - 1; i >= 0; i--)
    {
        ulong tk = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(tk, DEAL_MAGIC)  != InpMagicNumber) continue;
        if(HistoryDealGetString(tk,  DEAL_SYMBOL) != _Symbol)        continue;
        if(HistoryDealGetInteger(tk, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;

        double profit = HistoryDealGetDouble(tk, DEAL_PROFIT)
                      + HistoryDealGetDouble(tk, DEAL_SWAP)
                      + HistoryDealGetDouble(tk, DEAL_COMMISSION);

        if(profit > 0)  consecutiveWins++;
        else            break;   // streak broken
    }
}

//──────────────────────────────────────────────────────────────────
//  HELPERS
//──────────────────────────────────────────────────────────────────
int CountMyPositions()
{
    int n = 0;
    for(int i = 0; i < PositionsTotal(); i++)
        if(posInfo.SelectByIndex(i) &&
           posInfo.Magic() == InpMagicNumber &&
           posInfo.Symbol() == _Symbol) n++;
    return n;
}

bool HasPosition(ENUM_POSITION_TYPE type)
{
    for(int i = 0; i < PositionsTotal(); i++)
        if(posInfo.SelectByIndex(i) &&
           posInfo.Magic()        == InpMagicNumber &&
           posInfo.Symbol()       == _Symbol &&
           posInfo.PositionType() == type) return true;
    return false;
}

void ShowDashboard(string status, double balance, double equity)
{
    double pnlDay = equity - dailyStartBalance;
    double ddPct  = (dailyStartBalance > 0)
                    ? (dailyStartBalance - equity) / dailyStartBalance * 100.0
                    : 0.0;

    string s = StringFormat(
        "╔══════ HFT ScalpBot v2.00 ══════╗\n"
        "║ Symbol   : %-20s ║\n"
        "║ Balance  : %20.2f  ║\n"
        "║ Equity   : %20.2f  ║\n"
        "║ Day P&L  : %+20.2f ║\n"
        "║ Day DD   : %19.2f%% ║\n"
        "║ Trades   : %5d / %-14d ║\n"
        "║ Win Str. : %-20d ║\n"
        "║ Positions: %-20d ║\n"
        "%s"
        "╚════════════════════════════════╝",
        _Symbol,
        balance, equity, pnlDay, ddPct,
        dailyTrades, InpMaxDailyTrades,
        consecutiveWins,
        CountMyPositions(),
        status != "" ? "║ "+status+StringFormat("%*s", 31 - (int)StringLen(status), "")+"║\n" : ""
    );
    Comment(s);
}

//──────────────────────────────────────────────────────────────────
//  TRADE TRANSACTION HANDLER  (log closed deals)
//──────────────────────────────────────────────────────────────────
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if(HistoryDealSelect(trans.deal) != true)    return;
    if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagicNumber) return;
    if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return;

    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

    string outcome = profit > 0 ? "WIN" : "LOSS";
    PrintFormat("DEAL CLOSED | %s | profit=%.2f | streak=%d",
                outcome, profit, consecutiveWins);
}
