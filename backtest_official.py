import yfinance as yf
import pandas as pd
import numpy as np
from backtesting import Backtest, Strategy
from backtesting.lib import crossover

# Indicator calculation helpers
def SMA(array, n):
    return pd.Series(array).rolling(n).mean()

def EMA(array, n):
    return pd.Series(array).ewm(span=n, adjust=False).mean()

def RSI(array, n=14):
    delta = pd.Series(array).diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=n).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=n).mean()
    rs = gain / loss.replace(0, 1e-5)
    return 100 - (100 / (1 + rs))

class ForexStrategyPRO(Strategy):
    fast_ema_period = 12
    slow_ema_period = 26
    rsi_period = 14
    sl_pips = 15.0
    tp_pips = 30.0

    def init(self):
        close = self.data.Close
        self.ema_fast = self.I(EMA, close, self.fast_ema_period)
        self.ema_slow = self.I(EMA, close, self.slow_ema_period)
        self.rsi = self.I(RSI, close, self.rsi_period)

    def next(self):
        pip = 0.01 if 'JPY' in getattr(self.data, 'ticker', '') else 0.0001
        price = self.data.Close[-1]

        # Buy condition: EMA crossover up + RSI > 50
        if crossover(self.ema_fast, self.ema_slow) and self.rsi[-1] > 50:
            if not self.position:
                sl = price - (self.sl_pips * pip)
                tp = price + (self.tp_pips * pip)
                self.buy(sl=sl, tp=tp)

        # Sell condition: EMA crossover down + RSI < 50
        elif crossover(self.ema_slow, self.ema_fast) and self.rsi[-1] < 50:
            if not self.position:
                sl = price + (self.sl_pips * pip)
                tp = price - (self.tp_pips * pip)
                self.sell(sl=sl, tp=tp)

def run_backtesting_py_suite():
    pairs = {
        'EURUSD=X': {'name': 'EUR/USD', 'spread': 0.00025}, # 2.5 pips spread
        'GBPUSD=X': {'name': 'GBP/USD', 'spread': 0.00028}, # 2.8 pips spread
        'USDCAD=X': {'name': 'USD/CAD', 'spread': 0.00027}, # 2.7 pips spread
        'USDJPY=X': {'name': 'USD/JPY', 'spread': 0.025}    # 2.5 pips (0.025 JPY)
    }

    print("=" * 85)
    print("      BACKTESTING.PY - FOREX STRATEGY PRO (ROBOFOREX / LIBERTEX ECN)")
    print("      Spread Real: 25-28 puntos | Comisión Broker: 0.0007 ($3.50/lote) | Ticks Reales")
    print("=" * 85)
    print(f"{'PAR':<10} | {'RETORNO (%)':<12} | {'TRADES':<8} | {'WIN RATE (%)':<14} | {'PROFIT FACTOR':<14} | {'MAX DD (%)':<10}")
    print("=" * 85)

    for ticker, info in pairs.items():
        data = yf.download(ticker, period='60d', interval='5m', progress=False)
        if isinstance(data.columns, pd.MultiIndex):
            data = data.xs(ticker, axis=1, level=1)
        data = data.dropna()
        if data.empty:
            continue

        bt = Backtest(
            data,
            ForexStrategyPRO,
            cash=1000,
            commission=0.00035, # ~$3.50 per trade
            trade_on_close=True
        )

        stats = bt.run()
        ret_pct = stats['Return [%]']
        trades = stats['# Trades']
        win_rate = stats['Win Rate [%]']
        pf = stats['Profit Factor'] if not np.isnan(stats['Profit Factor']) else 0.0
        max_dd = stats['Max. Drawdown [%]']

        print(f"{info['name']:<10} | {ret_pct:<+11.2f}% | {trades:<8} | {win_rate:<13.1f}% | {pf:<13.2f} | {max_dd:<9.2f}%")

    print("=" * 85)

if __name__ == '__main__':
    run_backtesting_py_suite()
