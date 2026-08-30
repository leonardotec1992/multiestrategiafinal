//+------------------------------------------------------------------+
//|                                           ForexStrategyPRO.mq5   |
//|                        Copyright 2026, straderShop / Forex PRO   |
//|                                    https://fxstrategy.netlify.app |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, straderShop Forex Strategy PRO"
#property link      "https://fxstrategy.netlify.app"
#property version   "2.10"
#property description "Forex Strategy PRO Expert Advisor - Advanced EURUSD London Asian Breakout + Trend Strategy."
#property description "Includes Adaptive Layers, Daily Shield Protection, Trailing Stop, Break Even, and Interactive On-Chart Panel."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Canvas\Canvas.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_RISK_PROFILE
  {
   PROFILE_CONSERVATIVE = 0, // Conservador (Shield 3%, Target 2%)
   PROFILE_BALANCED     = 1, // Balanceado (Shield 4%, Target 3%)
   PROFILE_AGGRESSIVE   = 2  // Agresivo (Shield 6%, Target 5%)
  };

enum ENUM_PANEL_TAB
  {
   TAB_CTA   = 0, // Panel principal
   TAB_CFG   = 1, // Configuraciones
   TAB_STAT  = 2, // Estadísticas
   TAB_INTEL = 3, // Análisis IA Multifactor
   TAB_HIST  = 4, // Historial
   TAB_HELP  = 5  // Ayuda / Tutorial
  };

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== CONFIGURACIÓN DE RIESGO Y PERFIL ==="
input ENUM_RISK_PROFILE InpRiskProfile     = PROFILE_BALANCED;   // Perfil de Riesgo Predeterminado
input double            InpBaseLot         = 0.01;               // Lote Inicial Base
input int               InpMaxLayers       = 3;                  // Capas Máximas Abiertas
input double            InpGridStepPips    = 25.0;               // Distancia entre Capas (Pips)

input group "=== SEGURIDAD Y SHIELD ==="
input bool              InpEnableShield    = true;               // Activar Shield Diario
input double            InpDailyShieldPct  = 4.0;                // Límite de Pérdida Diaria Shield (%)
input double            InpTakeProfitPips  = 45.0;               // Take Profit Target (Pips)
input double            InpStopLossPips    = 25.0;               // Stop Loss Base (Pips)
input bool              InpUseBreakEven    = true;               // Activar Break Even Automático
input double            InpBreakEvenPips   = 15.0;               // Activación Break Even (Pips Profit)
input double            InpBreakEvenLock   = 3.0;                // Ganancia Asegurada Break Even (Pips)
input bool              InpUseTrailing     = true;               // Activar Trailing Stop Automático
input double            InpTrailingStart   = 22.0;               // Inicio Trailing Stop (Pips Profit)
input double            InpTrailingStep    = 8.0;                // Paso Trailing Stop (Pips)

input group "=== ESTRATEGIA BREAKOUT & TREND (EURUSD OPTIMIZADA) ==="
input int               InpTrendEma        = 200;                // Filtro Tendencia EMA 200
input int               InpFastEma         = 12;                 // Período EMA Rápida
input int               InpSlowEma         = 26;                 // Período EMA Lenta
input int               InpRsiPeriod       = 14;                 // Período RSI
input double            InpRsiBuyThreshold = 52.0;               // Umbral Compra RSI
input double            InpRsiSellThresh   = 48.0;               // Umbral Venta RSI
input int               InpAtrPeriod       = 14;                 // Período ATR
input int               InpStartHour       = 7;                  // Hora Inicio Sesión (UTC)
input int               InpEndHour         = 18;                 // Hora Fin Sesión (UTC)

input group "=== SISTEMA Y MÁGICO ==="
input ulong             InpMagicNumber     = 202604;             // Número Mágico
input string            InpTradeComment    = "ForexStrategyPRO"; // Comentario de Operación

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade          m_trade;
CPositionInfo   m_position;
CCanvas         m_canvas;

// Handles
int             h_trend_ema   = INVALID_HANDLE;
int             h_fast_ema    = INVALID_HANDLE;
int             h_slow_ema    = INVALID_HANDLE;
int             h_rsi         = INVALID_HANDLE;
int             h_atr         = INVALID_HANDLE;

// Panel State
ENUM_PANEL_TAB  g_current_tab  = TAB_CTA;
bool            g_paused       = false;
bool            g_shield_active= true;
bool            g_be_active    = true;
bool            g_trail_active = true;

// Daily Tracking
datetime        g_last_day     = 0;
double          g_day_start_eq = 0.0;
double          g_today_profit = 0.0;
int             g_today_wins   = 0;
int             g_today_losses = 0;
bool            g_shield_hit   = false;

// Geometry for UI
const int       PANEL_X      = 20;
const int       PANEL_Y      = 30;
const int       PANEL_W      = 340;
const int       PANEL_H      = 540;

//+------------------------------------------------------------------+
//| Helper for Pip Point Conversion (Supports 3 & 5 Digits / JPY)   |
//+------------------------------------------------------------------+
double GetPipValue()
  {
   if(_Digits == 3 || _Digits == 5) return _Point * 10.0;
   return _Point;
  }

//+------------------------------------------------------------------+
//| Expert Initialization Function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   m_trade.SetExpertMagicNumber(InpMagicNumber);

   // Initialize Indicators
   h_trend_ema = iMA(_Symbol, _Period, InpTrendEma, 0, MODE_EMA, PRICE_CLOSE);
   h_fast_ema  = iMA(_Symbol, _Period, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   h_slow_ema  = iMA(_Symbol, _Period, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi       = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   h_atr       = iATR(_Symbol, _Period, InpAtrPeriod);

   if(h_trend_ema == INVALID_HANDLE || h_fast_ema == INVALID_HANDLE ||
      h_slow_ema == INVALID_HANDLE || h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE)
     {
      Print("Error al crear handles de indicadores para ", _Symbol);
      return(INIT_FAILED);
     }

   // Initialize Daily State
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_last_day     = TimeCurrent();
   g_day_start_eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_shield_active= InpEnableShield;
   g_be_active    = InpUseBreakEven;
   g_trail_active = InpUseTrailing;

   // Create Canvas Panel
   if(!m_canvas.CreateBitmapLabel("ForexPRO_Panel", PANEL_X, PANEL_Y, PANEL_W, PANEL_H, COLOR_FORMAT_ARGB_NORMALIZE))
     {
      Print("Error creando el lienzo del panel.");
      return(INIT_FAILED);
     }

   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   RenderPanel();
   ChartRedraw();

   Print("Forex Strategy PRO 2.10 (EURUSD Breakout) iniciado correctamente en ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert Deinitialization Function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   m_canvas.Destroy();
   IndicatorRelease(h_trend_ema);
   IndicatorRelease(h_fast_ema);
   IndicatorRelease(h_slow_ema);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Expert Tick Function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();
   UpdateDailyStats();

   if(g_shield_active && !g_shield_hit)
     {
      CheckDailyShield();
     }

   if(!g_paused && !g_shield_hit)
     {
      ManageOpenPositions();
      CheckEntrySignals();
     }

   RenderPanel();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == "ForexPRO_Panel")
        {
         int mouse_x = (int)lparam - PANEL_X;
         int mouse_y = (int)dparam - PANEL_Y;
         HandlePanelClick(mouse_x, mouse_y);
         RenderPanel();
         ChartRedraw();
        }
     }
  }

//+------------------------------------------------------------------+
//| Check for New Trading Day                                        |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt_curr, dt_last;
   TimeToStruct(TimeCurrent(), dt_curr);
   TimeToStruct(g_last_day, dt_last);

   if(dt_curr.day != dt_last.day)
     {
      g_last_day     = TimeCurrent();
      g_day_start_eq = AccountInfoDouble(ACCOUNT_EQUITY);
      g_today_profit = 0.0;
      g_today_wins   = 0;
      g_today_losses = 0;
      g_shield_hit   = false;
      Print("Nuevo día detectado. Shield reseteado. Capital Base del día: ", g_day_start_eq);
     }
  }

//+------------------------------------------------------------------+
//| Check Daily Shield Protection Limit                              |
//+------------------------------------------------------------------+
void CheckDailyShield()
  {
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double max_allowed_loss = g_day_start_eq * (GetShieldLimitPct() / 100.0);
   double current_drawdown = g_day_start_eq - current_equity;

   if(current_drawdown >= max_allowed_loss)
     {
      g_shield_hit = true;
      Print("🛡 SHIELD ACTIVADO: Límite de pérdida diaria alcanzado ( -", DoubleToString(current_drawdown, 2), " USD ). Cerrando todas las posiciones.");
      CloseAllPositions();
     }
  }

//+------------------------------------------------------------------+
//| Get Shield Limit Percent according to Profile / Input            |
//+------------------------------------------------------------------+
double GetShieldLimitPct()
  {
   switch(InpRiskProfile)
     {
      case PROFILE_CONSERVATIVE: return 3.0;
      case PROFILE_BALANCED:     return 4.0;
      case PROFILE_AGGRESSIVE:   return 6.0;
     }
   return InpDailyShieldPct;
  }

//+------------------------------------------------------------------+
//| Update Today's Profit & Stats                                    |
//+------------------------------------------------------------------+
void UpdateDailyStats()
  {
   g_today_profit = 0.0;
   g_today_wins   = 0;
   g_today_losses = 0;

   HistorySelect(g_last_day, TimeCurrent());
   int total_deals = HistoryDealsTotal();

   for(int i = 0; i < total_deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
        {
         ulong magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
         if(magic == InpMagicNumber)
           {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                            HistoryDealGetDouble(ticket, DEAL_SWAP) +
                            HistoryDealGetDouble(ticket, DEAL_COMMISSION);

            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT)
              {
               g_today_profit += profit;
               if(profit >= 0) g_today_wins++;
               else g_today_losses++;
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check Entry Signals (London Breakout + EMA Trend Strategy)       |
//+------------------------------------------------------------------+
void CheckEntrySignals()
  {
   int open_layers = GetOpenLayersCount();
   if(open_layers > 0) return;

   // Session Time Filter (London / NY Liquidity)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour > InpEndHour) return;

   double trend_ema[], ema_f[], ema_s[], rsi_val[];
   ArraySetAsSeries(trend_ema, true);
   ArraySetAsSeries(ema_f, true);
   ArraySetAsSeries(ema_s, true);
   ArraySetAsSeries(rsi_val, true);

   if(CopyBuffer(h_trend_ema, 0, 1, 3, trend_ema) < 3 ||
      CopyBuffer(h_fast_ema, 0, 1, 3, ema_f) < 3 ||
      CopyBuffer(h_slow_ema, 0, 1, 3, ema_s) < 3 ||
      CopyBuffer(h_rsi, 0, 1, 3, rsi_val) < 3)
      return;

   double close_last = iClose(_Symbol, _Period, 1);

   // Buy: Closed candle > 200 EMA + Fast EMA crossover Slow EMA on closed candle + RSI > 52
   bool buy_condition  = (close_last > trend_ema[0]) && (ema_f[0] > ema_s[0]) && (ema_f[1] <= ema_s[1]) && (rsi_val[0] > InpRsiBuyThreshold);
   // Sell: Closed candle < 200 EMA + Fast EMA crossover below Slow EMA on closed candle + RSI < 48
   bool sell_condition = (close_last < trend_ema[0]) && (ema_f[0] < ema_s[0]) && (ema_f[1] >= ema_s[1]) && (rsi_val[0] < InpRsiSellThresh);

   double pip = GetPipValue();

   if(buy_condition)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = ask - (InpStopLossPips * pip);
      double tp  = ask + (InpTakeProfitPips * pip);
      m_trade.Buy(InpBaseLot, _Symbol, ask, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment);
      Print("EURUSD Buy Breakout #1 a ", ask, " SL: ", sl, " TP: ", tp);
     }
   else if(sell_condition)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = bid + (InpStopLossPips * pip);
      double tp  = bid - (InpTakeProfitPips * pip);
      m_trade.Sell(InpBaseLot, _Symbol, bid, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment);
      Print("EURUSD Sell Breakout #1 a ", bid, " SL: ", sl, " TP: ", tp);
     }
  }

//+------------------------------------------------------------------+
//| Manage Open Positions (Dynamic ATR Layers, BE, Trailing)         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   int total_pos = PositionsTotal();
   if(total_pos == 0) return;

   ENUM_POSITION_TYPE pos_type = WRONG_VALUE;
   double last_open_price = 0.0;
   datetime latest_open_time = 0;
   int open_layers = 0;

   for(int i = total_pos - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            open_layers++;
            pos_type = m_position.PositionType();
            if(m_position.Time() >= latest_open_time)
              {
               latest_open_time = m_position.Time();
               last_open_price  = m_position.PriceOpen();
              }

            if(g_be_active) ApplyBreakEven(m_position.Ticket());
            if(g_trail_active) ApplyTrailingStop(m_position.Ticket());
           }
        }
     }

   // Dynamic ATR Grid Spacing for Layers
   if(open_layers > 0 && open_layers < InpMaxLayers)
     {
      double atr[];
      ArraySetAsSeries(atr, true);
      CopyBuffer(h_atr, 0, 1, 1, atr);

      double pip = GetPipValue();
      double atr_grid = (atr[0] > 0) ? (atr[0] * 1.2) : (InpGridStepPips * pip);
      double grid_dist = MathMax(InpGridStepPips * pip, atr_grid);

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(pos_type == POSITION_TYPE_BUY)
        {
         if((last_open_price - ask) >= grid_dist)
           {
            double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double lot = InpBaseLot * MathPow(1.1, open_layers);
            if(step_vol > 0) lot = MathFloor(lot / step_vol) * step_vol;

            double sl  = ask - (InpStopLossPips * pip);
            double tp  = ask + (InpTakeProfitPips * pip);
            m_trade.Buy(lot, _Symbol, ask, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment);
            Print("Añadida Capa EURUSD Buy #", open_layers + 1, " a ", ask);
           }
        }
      else if(pos_type == POSITION_TYPE_SELL)
        {
         if((bid - last_open_price) >= grid_dist)
           {
            double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double lot = InpBaseLot * MathPow(1.1, open_layers);
            if(step_vol > 0) lot = MathFloor(lot / step_vol) * step_vol;

            double sl  = bid + (InpStopLossPips * pip);
            double tp  = bid - (InpTakeProfitPips * pip);
            m_trade.Sell(lot, _Symbol, bid, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment);
            Print("Añadida Capa EURUSD Sell #", open_layers + 1, " a ", bid);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Apply Break Even to a Position                                   |
//+------------------------------------------------------------------+
void ApplyBreakEven(ulong ticket)
  {
   if(!m_position.SelectByTicket(ticket)) return;

   double pip = GetPipValue();
   double trigger  = InpBreakEvenPips * pip;
   double lock_pts = InpBreakEvenLock * pip;

   if(m_position.PositionType() == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid - m_position.PriceOpen() >= trigger)
        {
         double new_sl = NormalizeDouble(m_position.PriceOpen() + lock_pts, _Digits);
         if(m_position.StopLoss() < new_sl)
           {
            m_trade.PositionModify(ticket, new_sl, m_position.TakeProfit());
            Print("Break Even activado en Buy #", ticket, " SL -> ", new_sl);
           }
        }
     }
   else if(m_position.PositionType() == POSITION_TYPE_SELL)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(m_position.PriceOpen() - ask >= trigger)
        {
         double new_sl = NormalizeDouble(m_position.PriceOpen() - lock_pts, _Digits);
         if(m_position.StopLoss() == 0.0 || m_position.StopLoss() > new_sl)
           {
            m_trade.PositionModify(ticket, new_sl, m_position.TakeProfit());
            Print("Break Even activado en Sell #", ticket, " SL -> ", new_sl);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Apply Trailing Stop to a Position                                |
//+------------------------------------------------------------------+
void ApplyTrailingStop(ulong ticket)
  {
   if(!m_position.SelectByTicket(ticket)) return;

   double pip = GetPipValue();
   double start_dist = InpTrailingStart * pip;
   double step_dist  = InpTrailingStep * pip;

   if(m_position.PositionType() == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid - m_position.PriceOpen() >= start_dist)
        {
         double new_sl = NormalizeDouble(bid - step_dist, _Digits);
         if(m_position.StopLoss() < new_sl)
           {
            m_trade.PositionModify(ticket, new_sl, m_position.TakeProfit());
           }
        }
     }
   else if(m_position.PositionType() == POSITION_TYPE_SELL)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(m_position.PriceOpen() - ask >= start_dist)
        {
         double new_sl = NormalizeDouble(ask + step_dist, _Digits);
         if(m_position.StopLoss() == 0.0 || m_position.StopLoss() > new_sl)
           {
            m_trade.PositionModify(ticket, new_sl, m_position.TakeProfit());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Get Open Layers Count                                            |
//+------------------------------------------------------------------+
int GetOpenLayersCount()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Close All Positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            m_trade.PositionClose(m_position.Ticket());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Lock Profit / Asegurar                                           |
//+------------------------------------------------------------------+
void LockProfits()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            if(m_position.Profit() > 0)
              {
               double pip = GetPipValue();
               double current_price = (m_position.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double lock_sl = (m_position.PositionType() == POSITION_TYPE_BUY) ? current_price - (3.0 * pip) : current_price + (3.0 * pip);
               m_trade.PositionModify(m_position.Ticket(), NormalizeDouble(lock_sl, _Digits), m_position.TakeProfit());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Handle Panel Button Clicks                                       |
//+------------------------------------------------------------------+
void HandlePanelClick(int x, int y)
  {
   if(y >= 45 && y <= 75)
     {
      int tab_w = PANEL_W / 6;
      int clicked_tab = x / tab_w;
      if(clicked_tab >= 0 && clicked_tab <= 5)
        {
         g_current_tab = (ENUM_PANEL_TAB)clicked_tab;
         return;
        }
     }

   if(g_current_tab == TAB_CTA)
     {
      if(x >= 15 && x <= 115 && y >= 460 && y <= 490) g_trail_active = !g_trail_active;
      if(x >= 120 && x <= 220 && y >= 460 && y <= 490) g_be_active = !g_be_active;
      if(x >= 225 && x <= 325 && y >= 460 && y <= 490) LockProfits();

      if(x >= 15 && x <= 115 && y >= 495 && y <= 525) g_shield_active = !g_shield_active;
      if(x >= 120 && x <= 220 && y >= 495 && y <= 525) g_paused = !g_paused;
      if(x >= 225 && x <= 325 && y >= 495 && y <= 525) CloseAllPositions();
     }
  }

//+------------------------------------------------------------------+
//| Render Complete Interactive Dark/Neon Panel                      |
//+------------------------------------------------------------------+
void RenderPanel()
  {
   m_canvas.FillRectangle(0, 0, PANEL_W, PANEL_H, ColorToARGB(0x0a0a0e, 240));
   m_canvas.Rectangle(0, 0, PANEL_W - 1, PANEL_H - 1, ColorToARGB(0x00e676, 255));

   m_canvas.FillRectangle(1, 1, PANEL_W - 2, 40, ColorToARGB(0x111116, 255));
   m_canvas.TextOut(15, 12, "FOREX STRATEGY PRO (" + _Symbol + ")", ColorToARGB(0x00e676, 255));

   string status_str = g_paused ? "PAUSADO" : (g_shield_hit ? "SHIELD HIT" : "ACTIVO");
   color status_col  = g_paused ? 0x00ffff00 : (g_shield_hit ? 0x000000ff : 0x0000ff00);
   m_canvas.TextOut(240, 12, status_str, ColorToARGB(status_col, 255));

   string tabs[6] = {"CTA", "CFG", "STAT", "INTEL", "HIST", "?"};
   int tab_w = PANEL_W / 6;
   for(int i = 0; i < 6; i++)
     {
      int x1 = i * tab_w;
      int x2 = x1 + tab_w - 2;
      color tab_bg = (g_current_tab == i) ? 0x00e676 : 0x1f1f28;
      color tab_fg = (g_current_tab == i) ? 0x000000 : 0xaaaaaa;
      m_canvas.FillRectangle(x1 + 2, 45, x2, 70, ColorToARGB(tab_bg, 255));
      m_canvas.TextOut(x1 + 10, 50, tabs[i], ColorToARGB(tab_fg, 255));
     }

   switch(g_current_tab)
     {
      case TAB_CTA:   RenderTabCTA(); break;
      case TAB_CFG:   RenderTabCFG(); break;
      case TAB_STAT:  RenderTabSTAT(); break;
      case TAB_INTEL: RenderTabINTEL(); break;
      case TAB_HIST:  RenderTabHIST(); break;
      case TAB_HELP:  RenderTabHELP(); break;
     }

   m_canvas.Update();
  }

//+------------------------------------------------------------------+
//| Render CTA Dashboard Tab                                         |
//+------------------------------------------------------------------+
void RenderTabCTA()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin_pct  = (AccountInfoDouble(ACCOUNT_MARGIN) > 0) ? (equity / AccountInfoDouble(ACCOUNT_MARGIN) * 100.0) : 100.0;
   int open_layers    = GetOpenLayersCount();
   double spread_pts  = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;

   int y = 85;
   m_canvas.TextOut(15, y, "EQUITY:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, "$" + DoubleToString(equity, 2), ColorToARGB(0x00e676, 255));
   y += 22;
   m_canvas.TextOut(15, y, "BALANCE:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, "$" + DoubleToString(balance, 2), ColorToARGB(0xffffff, 255));
   y += 22;
   m_canvas.TextOut(15, y, "MARGEN LIBRE:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, "$" + DoubleToString(free_margin, 2), ColorToARGB(0xffffff, 255));
   y += 22;
   m_canvas.TextOut(15, y, "MARGEN %:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, DoubleToString(margin_pct, 1) + "%", ColorToARGB(0x00e676, 255));

   y += 35;
   m_canvas.TextOut(15, y, "OPERACIONES", ColorToARGB(0x00e676, 255));
   y += 22;
   m_canvas.TextOut(15, y, "Capas abiertas:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, IntegerToString(open_layers) + " / " + IntegerToString(InpMaxLayers), ColorToARGB(0xffffff, 255));
   y += 22;
   m_canvas.TextOut(15, y, "GANANCIA HOY:", ColorToARGB(0x888888, 255));
   color prof_col = (g_today_profit >= 0) ? 0x00e676 : 0xff4444;
   m_canvas.TextOut(200, y, (g_today_profit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(g_today_profit), 2), ColorToARGB(prof_col, 255));
   y += 22;
   m_canvas.TextOut(15, y, "SPREAD:", ColorToARGB(0x888888, 255));
   m_canvas.TextOut(200, y, DoubleToString(spread_pts, 1) + " pts", ColorToARGB(0xffffff, 255));

   y += 35;
   m_canvas.TextOut(15, y, "SHIELD HOY (Límite Pérdida)", ColorToARGB(0x00e676, 255));
   y += 20;
   double loss_pct = 0.0;
   if(g_day_start_eq > 0)
      loss_pct = MathMax(0.0, (g_day_start_eq - equity) / g_day_start_eq * 100.0);
   double max_pct  = GetShieldLimitPct();
   m_canvas.TextOut(15, y, "Perdida acum: " + DoubleToString(loss_pct, 1) + "% / " + DoubleToString(max_pct, 1) + "%", ColorToARGB(0xcccccc, 255));

   y += 20;
   m_canvas.FillRectangle(15, y, 325, y + 8, ColorToARGB(0x222222, 255));
   int fill_w = (int)MathMin(310.0, (loss_pct / max_pct) * 310.0);
   color bar_col = (loss_pct > max_pct * 0.8) ? 0xff4444 : 0x00e676;
   if(fill_w > 0) m_canvas.FillRectangle(15, y, 15 + fill_w, y + 8, ColorToARGB(bar_col, 255));

   y = 460;
   DrawButton(15, y, 100, 30, "TRAIL", g_trail_active);
   DrawButton(120, y, 100, 30, "BE", g_be_active);
   DrawButton(225, y, 100, 30, "ASEGURAR", false, 0x00a050);

   y = 495;
   DrawButton(15, y, 100, 30, "SHIELD", g_shield_active);
   DrawButton(120, y, 100, 30, g_paused ? "REANUDAR" : "PAUSAR", g_paused, 0xffaa00);
   DrawButton(225, y, 100, 30, "CERRAR", false, 0xcc0000);
  }

//+------------------------------------------------------------------+
//| Render CFG Tab                                                   |
//+------------------------------------------------------------------+
void RenderTabCFG()
  {
   int y = 90;
   m_canvas.TextOut(15, y, "CONFIGURACIÓN DE PARAMETROS", ColorToARGB(0x00e676, 255));
   y += 30;

   string prof_name = "Balanceado";
   if(InpRiskProfile == PROFILE_CONSERVATIVE) prof_name = "Conservador";
   if(InpRiskProfile == PROFILE_AGGRESSIVE) prof_name = "Agresivo";

   m_canvas.TextOut(15, y, "Perfil de Riesgo: " + prof_name, ColorToARGB(0xffffff, 255)); y += 25;
   m_canvas.TextOut(15, y, "Par Activo: " + _Symbol, ColorToARGB(0x00e676, 255)); y += 25;
   m_canvas.TextOut(15, y, "Lote Base Inicial: " + DoubleToString(InpBaseLot, 2), ColorToARGB(0xcccccc, 255)); y += 25;
   m_canvas.TextOut(15, y, "Capas Máximas: " + IntegerToString(InpMaxLayers), ColorToARGB(0xcccccc, 255)); y += 25;
   m_canvas.TextOut(15, y, "Estrategia: London Breakout + EMA200", ColorToARGB(0x00e676, 255)); y += 25;
   m_canvas.TextOut(15, y, "Shield Límite Diario: " + DoubleToString(GetShieldLimitPct(), 1) + "%", ColorToARGB(0x00e676, 255)); y += 25;
   m_canvas.TextOut(15, y, "Break Even: " + DoubleToString(InpBreakEvenPips, 1) + " Pips", ColorToARGB(0xcccccc, 255)); y += 25;
   m_canvas.TextOut(15, y, "Trailing Stop: " + DoubleToString(InpTrailingStart, 1) + " Pips", ColorToARGB(0xcccccc, 255));
  }

//+------------------------------------------------------------------+
//| Render STAT Tab                                                  |
//+------------------------------------------------------------------+
void RenderTabSTAT()
  {
   int y = 90;
   m_canvas.TextOut(15, y, "ESTADÍSTICAS HOY", ColorToARGB(0x00e676, 255));
   y += 30;

   int total_trades = g_today_wins + g_today_losses;
   double win_rate  = (total_trades > 0) ? ((double)g_today_wins / total_trades * 100.0) : 0.0;

   m_canvas.TextOut(15, y, "Trades Ganados (W): " + IntegerToString(g_today_wins), ColorToARGB(0x00e676, 255)); y += 25;
   m_canvas.TextOut(15, y, "Trades Perdidos (L): " + IntegerToString(g_today_losses), ColorToARGB(0xff4444, 255)); y += 25;
   m_canvas.TextOut(15, y, "Ratio W / L: " + DoubleToString(win_rate, 1) + "%", ColorToARGB(0xffffff, 255)); y += 25;
   m_canvas.TextOut(15, y, "Ganancia Acumulada: $" + DoubleToString(g_today_profit, 2), ColorToARGB(g_today_profit >= 0 ? 0x00e676 : 0xff4444, 255));
  }

//+------------------------------------------------------------------+
//| Render INTEL Tab                                                 |
//+------------------------------------------------------------------+
void RenderTabINTEL()
  {
   int y = 90;
   m_canvas.TextOut(15, y, "ANÁLISIS MULTIFACTOR IA", ColorToARGB(0x00e676, 255));
   y += 30;

   double trend_ema[], ema_f[], ema_s[], rsi_val[];
   ArraySetAsSeries(trend_ema, true); ArraySetAsSeries(ema_f, true); ArraySetAsSeries(ema_s, true); ArraySetAsSeries(rsi_val, true);
   CopyBuffer(h_trend_ema, 0, 1, 1, trend_ema);
   CopyBuffer(h_fast_ema, 0, 1, 1, ema_f);
   CopyBuffer(h_slow_ema, 0, 1, 1, ema_s);
   CopyBuffer(h_rsi, 0, 1, 1, rsi_val);

   double close_last = iClose(_Symbol, _Period, 1);
   string trend = (close_last > trend_ema[0]) ? "ALCISTA (BUY)" : "BAJISTA (SELL)";
   color  t_col = (close_last > trend_ema[0]) ? 0x00e676 : 0xff4444;

   m_canvas.TextOut(15, y, "Tendencia EMA 200: " + trend, ColorToARGB(t_col, 255)); y += 25;
   m_canvas.TextOut(15, y, "Fuerza RSI: " + DoubleToString(rsi_val[0], 1), ColorToARGB(0xffffff, 255)); y += 25;
   m_canvas.TextOut(15, y, "Sesión Activa: LONDRES/NY (07-18 UTC)", ColorToARGB(0x00e676, 255)); y += 25;
   m_canvas.TextOut(15, y, "Estrategia: London Breakout + Trend", ColorToARGB(0xcccccc, 255));
  }

//+------------------------------------------------------------------+
//| Render HIST Tab                                                  |
//+------------------------------------------------------------------+
void RenderTabHIST()
  {
   int y = 90;
   m_canvas.TextOut(15, y, "ÚLTIMOS TRADES CERRADOS", ColorToARGB(0x00e676, 255));
   y += 30;

   HistorySelect(g_last_day, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   int displayed = 0;

   for(int i = total_deals - 1; i >= 0 && displayed < 8; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber)
        {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT)
           {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            color  p_col  = profit >= 0 ? 0x00e676 : 0xff4444;
            string str = "#" + IntegerToString(ticket) + " PnL: " + (profit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(profit), 2);
            m_canvas.TextOut(15, y, str, ColorToARGB(p_col, 255));
            y += 22;
            displayed++;
           }
        }
     }
   if(displayed == 0)
     {
      m_canvas.TextOut(15, y, "Sin trades cerrados hoy.", ColorToARGB(0x888888, 255));
     }
  }

//+------------------------------------------------------------------+
//| Render HELP Tab                                                  |
//+------------------------------------------------------------------+
void RenderTabHELP()
  {
   int y = 90;
   m_canvas.TextOut(15, y, "GUÍA RÁPIDA DE USO", ColorToARGB(0x00e676, 255));
   y += 25;
   m_canvas.TextOut(15, y, "1. Estrategia EURUSD London Breakout.", ColorToARGB(0x00e676, 255)); y += 20;
   m_canvas.TextOut(15, y, "2. Shield limita tu pérdida máxima diaria.", ColorToARGB(0xcccccc, 255)); y += 20;
   m_canvas.TextOut(15, y, "3. Trailing Stop asegura tus ganancias.", ColorToARGB(0xcccccc, 255)); y += 20;
   m_canvas.TextOut(15, y, "4. Break Even mueve tu SL a cero.", ColorToARGB(0xcccccc, 255)); y += 20;
   m_canvas.TextOut(15, y, "5. Soporte VIP: t.me/estrategieVipsupp", ColorToARGB(0x00e676, 255));
  }

//+------------------------------------------------------------------+
//| Utility Helper: Draw Custom UI Button                            |
//+------------------------------------------------------------------+
void DrawButton(int x, int y, int w, int h, string text, bool active, color active_color = 0x00e676)
  {
   color bg = active ? active_color : 0x22222c;
   color fg = active ? 0x000000 : 0xffffff;

   m_canvas.FillRectangle(x, y, x + w, y + h, ColorToARGB(bg, 255));
   m_canvas.Rectangle(x, y, x + w, y + h, ColorToARGB(0x33333f, 255));
   m_canvas.TextOut(x + 12, y + 8, text, ColorToARGB(fg, 255));
  }
//+------------------------------------------------------------------+
