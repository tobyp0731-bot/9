//+------------------------------------------------------------------+
//|  RiskManager.mqh  –  Position sizing, drawdown guard, lot scaling |
//+------------------------------------------------------------------+
#pragma once

//--- Normalise a lot to broker constraints
double NormaliseLot(string symbol, double rawLot, double capLot)
{
    double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot = MathMin(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), capLot);

    double lot = MathFloor(rawLot / step) * step;
    lot        = MathMax(lot, minLot);
    lot        = MathMin(lot, maxLot);
    return NormalizeDouble(lot, 2);
}

//--- Risk-based lot: stakes riskPct % of balance over slPoints of SL
double LotFromRisk(string   symbol,
                   double   balance,
                   double   riskPct,
                   double   slPoints,   // SL in _Point units
                   double   capLot)
{
    if(slPoints <= 0) return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

    double tickVal  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickVal <= 0 || tickSize <= 0)
        return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

    double riskMoney      = balance * riskPct / 100.0;
    double pointValue     = tickVal / tickSize * SymbolInfoDouble(symbol, SYMBOL_POINT);
    double rawLot         = riskMoney / (slPoints * pointValue);

    return NormaliseLot(symbol, rawLot, capLot);
}

//--- Compound lot after N consecutive wins: base * multiplier^(wins/winsPerStep)
double CompoundLot(string symbol,
                   double baseLot,
                   double multiplier,
                   int    wins,
                   int    winsPerStep,
                   double capLot)
{
    if(wins <= 0 || winsPerStep <= 0)
        return NormaliseLot(symbol, baseLot, capLot);

    int    steps  = wins / winsPerStep;
    double scaled = baseLot * MathPow(multiplier, steps);
    return NormaliseLot(symbol, scaled, capLot);
}

//--- Daily P&L guard: returns true when bot should pause
bool DailyLimitHit(double startBalance, double equity, double maxDDpct)
{
    if(startBalance <= 0) return false;
    double dd = (startBalance - equity) / startBalance * 100.0;
    return dd >= maxDDpct;
}
