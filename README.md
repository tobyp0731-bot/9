# HFT ScalpBot v2.00 — MT5 Expert Advisor

High-frequency scalping EA for MetaTrader 5 with structure-aware stop placement, ATR-scaled targets, and compounding lot growth on win streaks.

---

## Files

```
MQL5/
├── Experts/
│   └── HFT_ScalpBot/
│       └── HFT_ScalpBot.mq5      ← Main EA
└── Include/
    └── HFT/
        ├── SwingDetector.mqh     ← Fractal swing high/low finder
        └── RiskManager.mqh       ← Lot sizing & drawdown guard
```

---

## Installation

1. Open **MetaEditor** (F4 in MT5, or Tools → MetaQuotes Language Editor).
2. Copy `MQL5/Include/HFT/` → `<MT5 data folder>/MQL5/Include/HFT/`
3. Copy `MQL5/Experts/HFT_ScalpBot/` → `<MT5 data folder>/MQL5/Experts/HFT_ScalpBot/`
4. Press **F7** in MetaEditor to compile `HFT_ScalpBot.mq5`.  
   Expect 0 errors, 0 warnings.
5. Drag the EA onto any chart.

> **Find your MT5 data folder:** `File → Open Data Folder` in MT5.

---

## Strategy Overview

| Component | Detail |
|-----------|--------|
| Entry | EMA crossover (fast/slow) + signal EMA + RSI momentum |
| Trend filter | M5 EMA direction (optional, default ON) |
| Session filter | Server-time window (default 07:00–20:00) |
| Spread filter | Skips entries when spread > `InpMaxSpreadPts` points |
| Stop-loss | Placed **beyond real market structure** (fractal swing high/low) with an ATR floor — prevents stop hunts |
| Take-profit | `SL distance × InpTPRRatio` (default 1.5 → 1:1.5 R:R) |
| Breakeven trail | Moves SL to entry+1pt after `0.6×ATR` profit, then trails at `1.0×ATR` behind price |
| Lot growth | Compounds on consecutive wins; resets immediately on any loss |
| Kill-switches | Daily DD% limit **and** daily profit-target cap |

---

## Key Parameters

### Strategy
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTF` | M1 | Entry timeframe |
| `InpFastEMA` | 8 | Fast EMA |
| `InpSlowEMA` | 21 | Slow EMA |
| `InpRSIPeriod` | 7 | RSI period |
| `InpRSIBullMin` | 52 | RSI must be above this for buys |
| `InpRSIBearMax` | 48 | RSI must be below this for sells |

### Smart SL/TP
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpSLATRMult` | 1.8 | ATR multiplier for SL floor |
| `InpTPRRatio` | 1.5 | Reward:Risk ratio |
| `InpSwingLookback` | 25 | Bars scanned for swing levels |
| `InpStructureBuffer` | 3.0 | Extra pips beyond swing level |
| `InpMinSLPips` | 6 | Hard SL minimum |
| `InpMaxSLPips` | 40 | Hard SL cap |

### Risk Controls
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskPct` | 0.8 | % of balance risked per trade |
| `InpMaxDailyDDPct` | 4.0 | Halt trading if equity drops this % today |
| `InpDailyProfitTargetPct` | 3.0 | Halt after this % daily gain |
| `InpMaxOpenTrades` | 3 | Concurrent positions |
| `InpMaxDailyTrades` | 30 | Trades per day |

### Lot Compounding
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpBaseLot` | 0.01 | Starting lot |
| `InpCompoundWins` | true | Enable compounding |
| `InpWinsPerLotDouble` | 2 | Wins needed per step-up |
| `InpLotMultiplier` | 2.0 | Multiplier per step |
| `InpMaxLot` | 2.0 | Hard lot cap |

---

## Recommended Symbols

- **Forex**: EURUSD, GBPUSD, USDJPY, XAUUSD (Gold)
- **Indices**: US30, NAS100, SPX500
- Use brokers with **raw/ECN spreads** (< 0.5 pip on majors).

---

## Backtesting Guidance

1. Use **Every Tick Based on Real Ticks** model for accuracy.
2. Test with at least 6 months of data across different volatility regimes.
3. Start with default parameters before optimising.
4. Key metrics to target: Profit Factor > 1.8, Max DD < 15%, Recovery Factor > 3.

---

## Risk Disclaimer

Algorithmic trading involves substantial risk of loss. Past performance does not guarantee future results. Always test on a demo account before going live. Never risk more than you can afford to lose. Adjust `InpRiskPct`, `InpMaxDailyDDPct`, and `InpMaxLot` conservatively when starting.
