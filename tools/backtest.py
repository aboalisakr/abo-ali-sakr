"""Fast offline backtest of SR_Breakout_EA logic on M15 bars exported from MT5.

Export data in MT5: View > Symbols > Bars, pick XAUUSD + M15, set dates, Export Bars.
Usage:
    python3 tools/backtest.py XAUUSD_M15.csv [--mode fixed|swing] [--balance 1000]

Same rules as the EA (defaults match its inputs). Within one M15 bar, if both SL and
TP are touched, SL is assumed first (conservative).
"""
import argparse
import sys

import numpy as np
import pandas as pd


def load_bars(path):
    df = pd.read_csv(path, sep=None, engine="python")
    df.columns = [c.strip("<>").lower() for c in df.columns]
    if "time" in df.columns and "date" in df.columns:
        ts = pd.to_datetime(df["date"] + " " + df["time"])
    else:
        ts = pd.to_datetime(df[df.columns[0]])
    out = pd.DataFrame({"open": df["open"], "high": df["high"], "low": df["low"], "close": df["close"]})
    out.index = ts
    spread_pts = df["spread"].values if "spread" in df.columns else np.zeros(len(df))
    out["spread"] = spread_pts * 0.01  # XAUUSD point = 0.01
    return out.sort_index()


def build_zones(h, l, k, merge, min_height, min_touches):
    """h, l: arrays newest-first, index 0 = most recent COMPLETED bar (EA's bar 1)."""
    highs, lows = [], []
    n = len(h)
    for a in range(k, n - k):
        is_h = all(h[a] > h[a - j] and h[a] >= h[a + j] for j in range(1, k + 1))
        is_l = all(l[a] < l[a - j] and l[a] <= l[a + j] for j in range(1, k + 1))
        if is_h:
            highs.append(h[a])
        if is_l:
            lows.append(l[a])
    pts = sorted(highs + lows)
    zones, i = [], 0
    while i < len(pts):
        lo = hi = pts[i]
        j = i + 1
        while j < len(pts) and pts[j] - lo <= merge:
            hi = pts[j]
            j += 1
        if j - i >= min_touches:
            if hi - lo < min_height:
                mid = (lo + hi) / 2
                lo, hi = mid - min_height / 2, mid + min_height / 2
            zones.append((lo, hi))
        i = j
    return zones, highs, lows


def run(bars, a):
    h1 = bars.resample("1h", label="left", closed="left").agg({"high": "max", "low": "min"}).dropna()
    h1_times = h1.index.values
    h1_high, h1_low = h1["high"].values, h1["low"].values

    o, hi, lo, c = (bars[x].values for x in ("open", "high", "low", "close"))
    spread = bars["spread"].values
    times = bars.index.values

    balance = a.balance
    trades, pos = [], None
    cache_key, zones, sh, sl_ = None, [], [], []
    n_conf = a.confirm_bars

    for t in range(n_conf + 1, len(bars)):
        # manage open position on bar t
        if pos is not None:
            if pos["dir"] == 1:
                hit_sl, hit_tp = lo[t] <= pos["sl"], hi[t] >= pos["tp"]
            else:  # sell closes at ask
                hit_sl, hit_tp = hi[t] + spread[t] >= pos["sl"], lo[t] + spread[t] <= pos["tp"]
            if hit_sl or hit_tp:
                exit_px = pos["sl"] if hit_sl else pos["tp"]
                pnl = (exit_px - pos["entry"]) * pos["dir"] * pos["lot"] * 100  # 1 lot XAUUSD = 100 oz
                balance += pnl
                trades.append({**pos, "exit": exit_px, "exit_time": times[t], "pnl": pnl, "result": "SL" if hit_sl else "TP"})
                pos = None

        if pos is not None:
            continue

        # zones from completed H1 bars before bar t opens
        # number of H1 bars fully closed before bar t (the one containing bar t is still forming)
        n_done = np.searchsorted(h1_times, times[t], side="right") - 1
        if n_done < a.lookback + 2 * a.k + 2:
            continue
        if n_done != cache_key:
            need = a.lookback + 2 * a.k + 1
            hh = h1_high[n_done - need:n_done][::-1]
            ll = h1_low[n_done - need:n_done][::-1]
            zones, sh, sl_ = build_zones(hh, ll, a.k, a.merge, a.min_height, a.min_touches)
            cache_key = n_done

        closes = c[t - n_conf - 1:t][::-1]  # closes[0] = last closed bar
        prev = closes[n_conf]
        best_buy = best_sell = None
        for z_lo, z_hi in zones:
            if prev <= z_hi and all(x > z_hi + a.break_buffer for x in closes[:n_conf]):
                if best_buy is None or z_hi > best_buy[1]:
                    best_buy = (z_lo, z_hi)
            if prev >= z_lo and all(x < z_lo - a.break_buffer for x in closes[:n_conf]):
                if best_sell is None or z_lo < best_sell[0]:
                    best_sell = (z_lo, z_hi)

        if best_buy is None and best_sell is None:
            continue
        if a.max_spread > 0 and spread[t] > a.max_spread:
            continue
        is_buy = best_buy is not None
        z = best_buy if is_buy else best_sell
        bid = o[t]
        entry = bid + spread[t] if is_buy else bid
        stop = z[0] - a.sl_buffer if is_buy else z[1] + a.sl_buffer

        if a.mode == "fixed":
            tp = entry + a.target if is_buy else entry - a.target
        else:
            if is_buy:
                cands = [x - a.swing_offset for x in sh if x - a.swing_offset - entry >= a.min_target]
                tp = min(cands) if cands else (entry + a.target if a.fallback else None)
            else:
                cands = [x + a.swing_offset for x in sl_ if entry - (x + a.swing_offset) >= a.min_target]
                tp = max(cands) if cands else (entry - a.target if a.fallback else None)
            if tp is None:
                continue
        if (is_buy and not (stop < bid and tp > entry)) or (not is_buy and not (stop > entry and tp < bid)):
            continue
        if a.max_sl > 0 and abs(entry - stop) > a.max_sl:
            continue
        lot = max(0.01, np.floor(balance / 100) * 0.01)
        pos = {"dir": 1 if is_buy else -1, "time": times[t], "entry": entry, "sl": stop, "tp": tp,
               "lot": round(lot, 2), "zone": z}

    return pd.DataFrame(trades), balance


def report(df, start, end_balance):
    if df.empty:
        print("No trades.")
        return
    wins = df[df.pnl > 0]
    losses = df[df.pnl <= 0]
    eq = start + df.pnl.cumsum()
    dd = (eq.cummax() - eq).max()
    pf = wins.pnl.sum() / -losses.pnl.sum() if len(losses) and losses.pnl.sum() < 0 else float("inf")
    print(f"Trades: {len(df)}  (buy {int((df.dir == 1).sum())} / sell {int((df.dir == -1).sum())})")
    print(f"Win rate: {len(wins) / len(df) * 100:.1f}%")
    print(f"Avg win: {wins.pnl.mean() if len(wins) else 0:.2f}$  Avg loss: {losses.pnl.mean() if len(losses) else 0:.2f}$")
    print(f"Avg SL distance: {(df.entry - df.sl).abs().mean():.2f}$  Avg TP distance: {(df.tp - df.entry).abs().mean():.2f}$")
    print(f"Profit factor: {pf:.2f}")
    print(f"Max drawdown: {dd:.2f}$")
    print(f"Balance: {start:.2f}$ -> {end_balance:.2f}$  ({(end_balance / start - 1) * 100:+.1f}%)")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("csv")
    p.add_argument("--mode", choices=["fixed", "swing"], default="fixed")
    p.add_argument("--balance", type=float, default=1000.0)
    p.add_argument("--lookback", type=int, default=200)
    p.add_argument("--k", type=int, default=3)
    p.add_argument("--merge", type=float, default=3.0)
    p.add_argument("--min-height", type=float, default=1.0)
    p.add_argument("--min-touches", type=int, default=2)
    p.add_argument("--confirm-bars", type=int, default=2)
    p.add_argument("--break-buffer", type=float, default=0.5)
    p.add_argument("--target", type=float, default=10.0)
    p.add_argument("--swing-offset", type=float, default=1.0)
    p.add_argument("--min-target", type=float, default=3.0)
    p.add_argument("--no-fallback", dest="fallback", action="store_false")
    p.add_argument("--sl-buffer", type=float, default=2.0)
    p.add_argument("--max-sl", type=float, default=0.0)
    p.add_argument("--max-spread", type=float, default=1.0)
    p.add_argument("--trades-out")
    a = p.parse_args()

    bars = load_bars(a.csv)
    print(f"Bars: {len(bars)}  {bars.index[0]} -> {bars.index[-1]}  mode={a.mode}")
    df, bal = run(bars, a)
    report(df, a.balance, bal)
    if a.trades_out and not df.empty:
        df.to_csv(a.trades_out, index=False)


if __name__ == "__main__":
    sys.exit(main())
