//+------------------------------------------------------------------+
//|  SwingDetector.mqh  –  Structure-based swing high/low finder      |
//+------------------------------------------------------------------+
#pragma once

//--- Returns the most significant swing LOW within [startBar, startBar+lookback)
//    "Significant" = left and right bars are both higher (fractal style)
double FindSwingLow(string symbol, ENUM_TIMEFRAMES tf,
                    int startBar = 1, int lookback = 30,
                    int fractalBars = 2)
{
    double lowestFractal = DBL_MAX;
    int    bars          = Bars(symbol, tf);

    for(int i = startBar + fractalBars; i < startBar + lookback && i + fractalBars < bars; i++)
    {
        double mid = iLow(symbol, tf, i);
        bool   ok  = true;
        for(int j = 1; j <= fractalBars; j++)
        {
            if(iLow(symbol, tf, i - j) <= mid || iLow(symbol, tf, i + j) <= mid)
            { ok = false; break; }
        }
        if(ok && mid < lowestFractal) lowestFractal = mid;
    }

    // Fallback: plain lowest low in window
    if(lowestFractal == DBL_MAX)
    {
        lowestFractal = iLow(symbol, tf, startBar);
        for(int i = startBar; i < startBar + lookback && i < bars; i++)
        {
            double v = iLow(symbol, tf, i);
            if(v < lowestFractal) lowestFractal = v;
        }
    }
    return lowestFractal;
}

//--- Returns the most significant swing HIGH within [startBar, startBar+lookback)
double FindSwingHigh(string symbol, ENUM_TIMEFRAMES tf,
                     int startBar = 1, int lookback = 30,
                     int fractalBars = 2)
{
    double highestFractal = 0.0;
    int    bars           = Bars(symbol, tf);

    for(int i = startBar + fractalBars; i < startBar + lookback && i + fractalBars < bars; i++)
    {
        double mid = iHigh(symbol, tf, i);
        bool   ok  = true;
        for(int j = 1; j <= fractalBars; j++)
        {
            if(iHigh(symbol, tf, i - j) >= mid || iHigh(symbol, tf, i + j) >= mid)
            { ok = false; break; }
        }
        if(ok && mid > highestFractal) highestFractal = mid;
    }

    // Fallback: plain highest high in window
    if(highestFractal == 0.0)
    {
        highestFractal = iHigh(symbol, tf, startBar);
        for(int i = startBar; i < startBar + lookback && i < bars; i++)
        {
            double v = iHigh(symbol, tf, i);
            if(v > highestFractal) highestFractal = v;
        }
    }
    return highestFractal;
}
