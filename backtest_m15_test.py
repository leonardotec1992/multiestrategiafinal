import yfinance as yf
import pandas as pd
import numpy as np

# Broker ECN Real Conditions (RoboForex / Libertex)
SPREAD_POINTS = {
    'EURUSD=X': 12, # 1.2 pips
    'GBPUSD=X': 15, # 1.5 pips
    'USDCAD=X': 16, # 1.6 pips
    'USDJPY=X': 14  # 1.4 pips
}

COMMISSION_PER_LOT = 3.50 # $3.50 / lot ($7.00 round turn)

class M15MultiPairSimulator:
    def __init__(self, ticker, fast_ema=9, slow_ema=21, initial_balance=1000.0, base_lot=0.01, max_layers=3, shield_pct=4.0):
        self.ticker = ticker
        self.fast_ema_period = fast_ema
        self.slow_ema_period = slow_ema
        self.initial_balance = initial_balance
        self.balance = initial_balance
        self.equity = initial_balance
        self.base_lot = base_lot
        self.max_layers = max_layers
        self.shield_pct = shield_pct

        # PARAMETERS OPTIMIZED FOR M15 TIMEFRAME
        self.tp_pips = 50.0
        self.sl_pips = 25.0
        self.be_pips = 18.0
        self.be_lock_pips = 3.0
        self.trail_start_pips = 25.0
        self.trail_step_pips = 10.0

        self.is_jpy = 'JPY' in ticker
        self.pip_size = 0.01 if self.is_jpy else 0.0001
        self.pip_value = 6.7 if self.is_jpy else 10.0
        self.spread_pips = SPREAD_POINTS.get(ticker, 15) / 10.0
        self.spread_val = self.spread_pips * self.pip_size

        self.positions = []
        self.history = []
        self.day_start_equity = initial_balance
        self.shield_hit = False

    def fetch_m15_data(self):
        # Fetch 60d of 15m interval data from Yahoo Finance
        data = yf.download(self.ticker, period='60d', interval='15m', progress=False)
        if isinstance(data.columns, pd.MultiIndex):
            data = data.xs(self.ticker, axis=1, level=1)
        data = data.dropna()
        return data

    def calculate_indicators(self, df):
        close = df['Close']
        df['EMA_Fast'] = close.ewm(span=self.fast_ema_period, adjust=False).mean()
        df['EMA_Slow'] = close.ewm(span=self.slow_ema_period, adjust=False).mean()
        df['EMA_Trend'] = close.ewm(span=200, adjust=False).mean() # 200 EMA Trend Filter

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

    def run_monthly_breakdown(self):
        df = self.fetch_m15_data()
        if df.empty or len(df) < 200: return []

        df = self.calculate_indicators(df)
        df['YearMonth'] = df.index.to_period('M')

        monthly_reports = []

        for ym, month_df in df.groupby('YearMonth'):
            month_start_bal = self.balance
            month_history = []
            month_peak = self.balance
            month_max_dd = 0.0
            current_day = None

            for idx, row in month_df.iterrows():
                row_date = idx.date()
                if row_date != current_day:
                    current_day = row_date
                    self.day_start_equity = self.equity
                    self.shield_hit = False

                close = row['Close']
                high  = row['High']
                low   = row['Low']
                atr   = row['ATR'] if not np.isnan(row['ATR']) else (25.0 * self.pip_size)

                if self.shield_pct > 0 and not self.shield_hit:
                    allowed_loss = self.day_start_equity * (self.shield_pct / 100.0)
                    if (self.day_start_equity - self.equity) >= allowed_loss:
                        self.shield_hit = True
                        self.close_all_positions(close, month_history)

                if not self.shield_hit and len(self.positions) > 0:
                    self.manage_positions(close, high, low, atr, month_history)

                if not self.shield_hit and len(self.positions) == 0:
                    hour = idx.hour if hasattr(idx, 'hour') else 12
                    if 7 <= hour <= 19:
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
        grid_dist = max(25.0 * self.pip_size, 1.2 * atr)

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
    print("      BACKTEST EN TEMPO M15 (15 MINUTOS) + EMA (9/21) (ROBOFOREX / LIBERTEX ECN)")
    print("      Spreads Reales: 12-16 pts | Comisión: $3.50/lote | Ticks Reales M15 | Shield 4%")
    print("=" * 105)

    tot_port_init = 0
    tot_port_final = 0

    for pair in pairs:
        pair_clean = pair.replace('=X', '')
        print(f"\n>>> DIVISA: {pair_clean} (Timeframe: M15 | EMAs: 9 / 21 | Capital Inicial: $1,000 USD)")
        print("-" * 105)
        print(f"{'MES':<10} | {'INICIAL ($)':<12} | {'FINAL ($)':<12} | {'BENEFICIO ($)':<14} | {'TRADES':<7} | {'WIN %':<7} | {'PF':<6} | {'MAX DD %':<8}")
        print("-" * 105)

        sim = M15MultiPairSimulator(ticker=pair, fast_ema=9, slow_ema=21, initial_balance=1000.0)
        m_reports = sim.run_monthly_breakdown()

        tot_net = 0
        tot_trades = 0

        for r in m_reports:
            tot_net += r['net_profit']
            tot_trades += r['trades']
            prof_sign = "+" if r['net_profit'] >= 0 else ""
            print(f"{r['month']:<10} | ${r['start_balance']:<11.2f} | ${r['end_balance']:<11.2f} | {prof_sign}${r['net_profit']:<13.2f} | {r['trades']:<7} | {r['win_rate']:<6.1f}% | {r['profit_factor']:<6.2f} | {r['max_dd']:<7.2f}%")

        print("-" * 100)
        tot_sign = "+" if tot_net >= 0 else ""
        print(f"RESUMEN {pair_clean} (M15): Beneficio Neto Total: {tot_sign}${tot_net:.2f} ({(tot_net/1000.0)*100:.2f}%) | Trades Totales: {tot_trades}")
        print("=" * 105)
        tot_port_init += 1000.0
        tot_port_final += (1000.0 + tot_net)

    print("\n" + "=" * 105)
    port_net = tot_port_final - tot_port_init
    p_sign = "+" if port_net >= 0 else ""
    print(f"PORTAFOLIO M15 GLOBAL (4 PARES): Capital Inicial: ${tot_port_init:.2f} | Capital Final: ${tot_port_final:.2f} | GANANCIA NETA: {p_sign}${port_net:.2f} ({(port_net/tot_port_init)*100:.2f}%)")
    print("=" * 105)
