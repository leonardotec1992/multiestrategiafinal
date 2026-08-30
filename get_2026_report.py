import yfinance as yf
import pandas as pd
import numpy as np

# Broker ECN Parameters
SPREAD_PIPS = {
    'EURUSD=X': 0.00012,
    'GBPUSD=X': 0.00015,
    'USDCAD=X': 0.00016,
    'USDJPY=X': 0.014
}
COMMISSION_PER_LOT = 3.50

PAIR_PARAMS = {
    'EURUSD=X': {'tp': 45.0, 'sl': 25.0, 'be': 18.0, 'be_lock': 3.0, 'trail': 25.0, 'step': 8.0, 'grid': 25.0, 'ema_f': 12, 'ema_s': 26, 'ema_t': 200},
    'GBPUSD=X': {'tp': 35.0, 'sl': 20.0, 'be': 12.0, 'be_lock': 3.0, 'trail': 20.0, 'step': 6.0, 'grid': 20.0, 'ema_f': 9, 'ema_s': 21, 'ema_t': 100},
    'USDCAD=X': {'tp': 35.0, 'sl': 20.0, 'be': 12.0, 'be_lock': 3.0, 'trail': 20.0, 'step': 6.0, 'grid': 20.0, 'ema_f': 12, 'ema_s': 26, 'ema_t': 200},
    'USDJPY=X': {'tp': 30.0, 'sl': 18.0, 'be': 10.0, 'be_lock': 2.0, 'trail': 18.0, 'step': 5.0, 'grid': 18.0, 'ema_f': 8, 'ema_s': 21, 'ema_t': 100}
}

class Report2026Simulator:
    def __init__(self, ticker, initial_balance=1000.0, base_lot=0.01, max_layers=3, shield_pct=4.0):
        self.ticker = ticker
        self.initial_balance = initial_balance
        self.balance = initial_balance
        self.equity = initial_balance
        self.base_lot = base_lot
        self.max_layers = max_layers
        self.shield_pct = shield_pct

        cfg = PAIR_PARAMS.get(ticker, PAIR_PARAMS['EURUSD=X'])
        self.tp_pips = cfg['tp']
        self.sl_pips = cfg['sl']
        self.be_pips = cfg['be']
        self.be_lock_pips = cfg['be_lock']
        self.trail_start_pips = cfg['trail']
        self.trail_step_pips = cfg['step']
        self.grid_step_pips = cfg['grid']
        self.fast_ema = cfg['ema_f']
        self.slow_ema = cfg['ema_s']
        self.trend_ema = cfg['ema_t']

        self.is_jpy = 'JPY' in ticker
        self.pip_size = 0.01 if self.is_jpy else 0.0001
        self.pip_value = 6.7 if self.is_jpy else 10.0
        self.spread_val = SPREAD_PIPS.get(ticker, 0.00012)

        self.positions = []
        self.history = []
        self.day_start_equity = initial_balance
        self.shield_hit = False

    def fetch_data(self):
        df = yf.download(self.ticker, start='2026-01-01', end='2026-08-01', interval='1d', progress=False)
        if isinstance(df.columns, pd.MultiIndex):
            df = df.xs(self.ticker, axis=1, level=1)
        df = df.dropna()
        return df

    def calculate_indicators(self, df):
        close = df['Close']
        df['EMA_Fast'] = close.ewm(span=self.fast_ema, adjust=False).mean()
        df['EMA_Slow'] = close.ewm(span=self.slow_ema, adjust=False).mean()
        df['EMA_Trend'] = close.ewm(span=self.trend_ema, adjust=False).mean()

        high = df['High']
        low  = df['Low']
        tr = np.maximum(high - low, np.maximum(abs(high - close.shift(1)), abs(low - close.shift(1))))
        df['ATR'] = tr.rolling(window=14).mean()

        delta = close.diff()
        gain = (delta.where(delta > 0, 0)).rolling(window=14).mean()
        loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
        rs = gain / loss.replace(0, 1e-5)
        df['RSI'] = 100 - (100 / (1 + rs))
        return df

    def run_2026_backtest(self):
        df = self.fetch_data()
        if df.empty: return []

        df = self.calculate_indicators(df)
        df['YearMonth'] = df.index.to_period('M')

        monthly_reports = []
        current_day = None

        for ym, month_df in df.groupby('YearMonth'):
            month_start_bal = self.balance
            month_history = []
            month_peak = self.balance
            month_max_dd = 0.0

            for idx, row in month_df.iterrows():
                row_date = idx.date()
                if row_date != current_day:
                    current_day = row_date
                    self.day_start_equity = self.equity
                    self.shield_hit = False

                close = row['Close']
                high  = row['High']
                low   = row['Low']
                atr   = row['ATR'] if not np.isnan(row['ATR']) else (20.0 * self.pip_size)

                if self.shield_pct > 0 and not self.shield_hit:
                    allowed_loss = self.day_start_equity * (self.shield_pct / 100.0)
                    if (self.day_start_equity - self.equity) >= allowed_loss:
                        self.shield_hit = True
                        self.close_all_positions(close, month_history)

                if not self.shield_hit and len(self.positions) > 0:
                    self.manage_positions(close, high, low, atr, month_history)

                if not self.shield_hit and len(self.positions) == 0:
                    ema_f = row['EMA_Fast']
                    ema_s = row['EMA_Slow']
                    ema_t = row['EMA_Trend']
                    rsi   = row['RSI']

                    prev_idx = df.index.get_loc(idx) - 1
                    if prev_idx >= 0:
                        prev_ema_f = df.iloc[prev_idx]['EMA_Fast']
                        prev_ema_s = df.iloc[prev_idx]['EMA_Slow']

                        buy_sig  = (ema_f > ema_s) and (prev_ema_f <= prev_ema_s) and (close > ema_t) and (rsi > 50.0)
                        sell_sig = (ema_f < ema_s) and (prev_ema_f >= prev_ema_s) and (close < ema_t) and (rsi < 50.0)

                        if buy_sig:
                            ask = close + self.spread_val
                            sl  = ask - (self.sl_pips * self.pip_size)
                            tp  = ask + (self.tp_pips * self.pip_size)
                            self.positions.append({'type': 'BUY', 'open_price': ask, 'lot': self.base_lot, 'sl': sl, 'tp': tp})
                            self.balance -= COMMISSION_PER_LOT * self.base_lot
                        elif sell_sig:
                            bid = close
                            sl  = bid + (self.sl_pips * self.pip_size)
                            tp  = bid - (self.tp_pips * self.pip_size)
                            self.positions.append({'type': 'SELL', 'open_price': bid, 'lot': self.base_lot, 'sl': sl, 'tp': tp})
                            self.balance -= COMMISSION_PER_LOT * self.base_lot

                unrealized = sum(self.calc_profit(p, close) for p in self.positions)
                self.equity = self.balance + unrealized

                if self.equity > month_peak:
                    month_peak = self.equity
                dd = (month_peak - self.equity) / month_peak * 100.0 if month_peak > 0 else 0.0
                if dd > month_max_dd:
                    month_max_dd = dd

            self.close_all_positions(month_df.iloc[-1]['Close'], month_history)

            wins = [t for t in month_history if t['profit'] >= 0]
            losses = [t for t in month_history if t['profit'] < 0]
            win_rate = (len(wins) / len(month_history) * 100.0) if month_history else 0.0
            g_profit = sum(t['profit'] for t in wins)
            g_loss = abs(sum(t['profit'] for t in losses)) if losses else 0.0
            pf = (g_profit / g_loss) if g_loss > 0 else (99.0 if g_profit > 0 else 0.0)

            monthly_reports.append({
                'month': str(ym),
                'start_balance': month_start_bal,
                'end_balance': self.balance,
                'net_profit': self.balance - month_start_bal,
                'trades': len(month_history),
                'win_rate': win_rate,
                'profit_factor': pf,
                'max_dd': month_max_dd
            })

        return monthly_reports

    def manage_positions(self, close, high, low, atr, month_history):
        p_type = self.positions[0]['type']
        last_open = self.positions[-1]['open_price']
        grid_dist = max(self.grid_step_pips * self.pip_size, 1.1 * atr)

        if len(self.positions) < self.max_layers:
            if p_type == 'BUY' and (last_open - low) >= grid_dist:
                new_open = last_open - grid_dist + self.spread_val
                lot = self.base_lot * (1.1 ** len(self.positions))
                sl = new_open - (self.sl_pips * self.pip_size)
                tp = new_open + (self.tp_pips * self.pip_size)
                self.positions.append({'type': 'BUY', 'open_price': new_open, 'lot': lot, 'sl': sl, 'tp': tp})
                self.balance -= COMMISSION_PER_LOT * lot
            elif p_type == 'SELL' and (high - last_open) >= grid_dist:
                new_open = last_open + grid_dist
                lot = self.base_lot * (1.1 ** len(self.positions))
                sl = new_open + (self.sl_pips * self.pip_size)
                tp = new_open - (self.tp_pips * self.pip_size)
                self.positions.append({'type': 'SELL', 'open_price': new_open, 'lot': lot, 'sl': sl, 'tp': tp})
                self.balance -= COMMISSION_PER_LOT * lot

        for p in list(self.positions):
            if p['type'] == 'BUY':
                high_pips = (high - p['open_price']) / self.pip_size
                if high >= p['tp'] and p['tp'] > 0:
                    self.close_position(p, p['tp'], month_history)
                    continue
                if low <= p['sl'] and p['sl'] > 0:
                    self.close_position(p, p['sl'], month_history)
                    continue
                if high_pips >= self.be_pips:
                    be_level = p['open_price'] + (self.be_lock_pips * self.pip_size)
                    if p['sl'] < be_level: p['sl'] = be_level
                if high_pips >= self.trail_start_pips:
                    trail_level = high - (self.trail_step_pips * self.pip_size)
                    if p['sl'] < trail_level: p['sl'] = trail_level

            elif p['type'] == 'SELL':
                high_pips = (p['open_price'] - low) / self.pip_size
                if low <= p['tp'] and p['tp'] > 0:
                    self.close_position(p, p['tp'], month_history)
                    continue
                if high >= p['sl'] and p['sl'] > 0:
                    self.close_position(p, p['sl'], month_history)
                    continue
                if high_pips >= self.be_pips:
                    be_level = p['open_price'] - (self.be_lock_pips * self.pip_size)
                    if p['sl'] == 0.0 or p['sl'] > be_level: p['sl'] = be_level
                if high_pips >= self.trail_start_pips:
                    trail_level = low + (self.trail_step_pips * self.pip_size)
                    if p['sl'] == 0.0 or p['sl'] > trail_level: p['sl'] = trail_level

    def close_position(self, pos, exit_price, month_history):
        profit = self.calc_profit(pos, exit_price)
        self.balance += profit
        month_history.append({'type': pos['type'], 'profit': profit})
        if pos in self.positions:
            self.positions.remove(pos)

    def calc_profit(self, pos, current_price):
        if pos['type'] == 'BUY':
            pips = (current_price - pos['open_price']) / self.pip_size
        else:
            pips = (pos['open_price'] - current_price) / self.pip_size
        return pips * pos['lot'] * self.pip_value

    def close_all_positions(self, exit_price, month_history):
        for p in list(self.positions):
            self.close_position(p, exit_price, month_history)
        self.equity = self.balance

if __name__ == '__main__':
    pairs = ['EURUSD=X', 'GBPUSD=X', 'USDCAD=X', 'USDJPY=X']
    print("=" * 105)
    print("      REPORTE DETALLADO DEL AÑO 2026 MES POR MES (ROBOFOREX / LIBERTEX ECN)")
    print("=" * 105)

    for pair in pairs:
        pair_clean = pair.replace('=X', '')
        sim = Report2026Simulator(ticker=pair, initial_balance=1000.0)
        reports = sim.run_2026_backtest()

        print(f"\n>>> PAR / DIVISA: {pair_clean} (Capital Inicial 2026: $1,000 USD)")
        print("-" * 105)
        print(f"{'MES 2026':<10} | {'INICIAL ($)':<12} | {'FINAL ($)':<12} | {'BENEFICIO ($)':<14} | {'TRADES':<7} | {'WIN %':<7} | {'PF':<6} | {'MAX DD %':<8}")
        print("-" * 105)

        tot_net = 0
        tot_tr = 0
        for r in reports:
            tot_net += r['net_profit']
            tot_tr += r['trades']
            sign = "+" if r['net_profit'] >= 0 else ""
            print(f"{r['month']:<10} | ${r['start_balance']:<11.2f} | ${r['end_balance']:<11.2f} | {sign}${r['net_profit']:<13.2f} | {r['trades']:<7} | {r['win_rate']:<6.1f}% | {r['profit_factor']:<6.2f} | {r['max_dd']:<7.2f}%")

        print("-" * 105)
        tot_sign = "+" if tot_net >= 0 else ""
        print(f"RESUMEN 2026 {pair_clean}: Beneficio Neto Total 2026: {tot_sign}${tot_net:.2f} ({(tot_net/1000.0)*100:.2f}%) | Trades: {tot_tr}")
        print("=" * 105)
