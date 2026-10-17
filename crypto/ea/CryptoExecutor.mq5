//+------------------------------------------------------------------+
//| CryptoExecutor.mq5                                               |
//| Execute le plan crypto ecrit par Claude dans GitHub              |
//|                                                                  |
//| - lit crypto/plan.csv et crypto/actions.csv (branche main)       |
//| - pose les ordres avec SL/TP, taille calculee sur le risque      |
//| - stop journalier, stop au prix d'entree a +1R                   |
//| - envoie crypto/data.csv (branche live) pour le suivi et bilan   |
//+------------------------------------------------------------------+
#property copyright "Miguel - trading-plan"
#property version   "1.10"
#property description "Lit le plan crypto sur GitHub, pose les ordres avec SL/TP, envoie les donnees du compte."

#include <Trade\Trade.mqh>

#define EA_VERSION "1.10"
#define API_HOST   "https://api.github.com"

//--- Reglages
input group "GitHub"
input string InpToken       = "";                   // Token GitHub (Contents : lecture/écriture)
input string InpOwner       = "kidimig";            // Propriétaire du dépôt
input string InpRepo        = "trading-plan";       // Dépôt
input string InpPlanBranch  = "main";               // Branche du plan et des actions
input string InpPlanPath    = "crypto/plan.csv";    // Fichier du plan
input string InpActionsPath = "crypto/actions.csv"; // Fichier des actions
input string InpDataBranch  = "live";               // Branche des données envoyées
input string InpDataPath    = "crypto/data.csv";    // Fichier des données

input group "Marchés et risque"
input string InpSymbols         = "BTCUSD,ETHUSD"; // Symboles autorisés (séparés par des virgules)
input double InpRiskPct         = 2.0;  // Risque max par trade (% du solde)
input int    InpMaxPositions    = 2;    // Positions + ordres en attente max
input double InpMaxDailyLossPct = 6.0;  // Perte max par jour UTC (% du solde de début de journée)
input double InpMinRR           = 1.5;  // Ratio gain/risque minimum
input int    InpMaxSpreadPts    = 0;    // Spread max pour un ordre au marché (points, 0 = sans filtre)
input bool   InpBreakEven       = true; // Stop au prix d'entrée quand le gain atteint 1R

input group "Fonctionnement"
input long   InpMagic        = 20261016; // Numéro magique
input int    InpPlanEveryMin = 5;        // Lecture du plan et des actions (minutes)
input int    InpDataEveryMin = 15;       // Envoi des données (minutes)
input bool   InpNotify       = true;     // Notifications push MT5

input group "Réveil de Claude (tâche Surveillance crypto déclenchée par API)"
input bool   InpWakeEnabled  = true;     // Réveiller Claude quand il se passe quelque chose sur un trade
input string InpWakeURL      = "";       // Adresse de la tâche (…/trig_…/fire)
input string InpWakeToken    = "";       // Jeton de la tâche (sk-ant-oat01-…)
input int    InpWakeMinMin   = 10;       // Délai minimum entre deux réveils (minutes)
input int    InpWakeMaxDay   = 20;       // Réveils maximum par jour UTC
input bool   InpWakeTest     = false;    // Réveil de test au démarrage (remettre à false ensuite)

//--- Une ligne du plan
struct PlanLine
  {
   string            id;
   string            sym;
   string            order;
   double            entry;
   double            sl;
   double            tp;
   double            risk;
   string            note;
  };

//--- Etat global
CTrade   g_trade;
string   g_symbols[];
string   g_prefix          = "";
datetime g_lastPlan        = 0;
datetime g_lastData        = 0;
string   g_dataSha         = "";
string   g_planStatus      = "pas encore lu";
string   g_planDate        = "";
datetime g_planValidUntil  = 0;   // heure UTC
string   g_lastError       = "";
string   g_lastEvent       = "";
string   g_lastPush        = "jamais";
string   g_zones           = "";  // lignes ZONE pour data.csv
string   g_wakePending     = "";
datetime g_wakeLast        = 0;
string   g_wakeStatus      = "désactivé";
string   g_stIds[];
string   g_stMsg[];

//+------------------------------------------------------------------+
//| Outils                                                           |
//+------------------------------------------------------------------+
string Trim(string s)
  {
   StringReplace(s, "\r", "");
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

string Clean(string s)
  {
   StringReplace(s, ";", ",");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
  }

string GvName(const string key)        { return g_prefix + key; }
bool   GvHas(const string key)         { return GlobalVariableCheck(GvName(key)); }
double GvGet(const string key)         { return GlobalVariableGet(GvName(key)); }
void   GvSet(const string key, double v) { GlobalVariableSet(GvName(key), v); }
void   GvDel(const string key)         { GlobalVariableDel(GvName(key)); }

long ServerOffset()
  {
   long d = (long)TimeTradeServer() - (long)TimeGMT();
   return (long)MathRound(d / 900.0) * 900;
  }

datetime ToUtc(const datetime serverTime) { return (datetime)((long)serverTime - ServerOffset()); }

string Fmt(const datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
   StringReplace(s, ".", "-");
   return s;
  }

string UtcDayKey()
  {
   MqlDateTime m;
   TimeToStruct(TimeGMT(), m);
   return StringFormat("%04d%02d%02d", m.year, m.mon, m.day);
  }

datetime ParseUtc(string s)
  {
   s = Trim(s);
   StringReplace(s, "-", ".");
   return StringToTime(s);
  }

double NormPrice(const double price, const double tick, const int digits)
  {
   if(tick <= 0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathRound(price / tick) * tick, digits);
  }

int VolDigits(const double step)
  {
   int d = 0;
   double s = step;
   while(s < 1.0 - 1e-9 && d < 8)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

void Log(const string msg)
  {
   Print("CryptoExecutor : ", msg);
   g_lastEvent = Fmt(TimeGMT()) + " " + msg;
  }

void Notify(const string msg)
  {
   Log(msg);
   if(InpNotify && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification("Crypto : " + msg);
  }

//--- Etat de chaque ligne du plan (journalise seulement quand il change)
void SetState(const string id, const string st)
  {
   int n = ArraySize(g_stIds);
   for(int i = 0; i < n; i++)
     {
      if(g_stIds[i] == id)
        {
         if(g_stMsg[i] != st)
           {
            g_stMsg[i] = st;
            Log(id + " : " + st);
           }
         return;
        }
     }
   ArrayResize(g_stIds, n + 1);
   ArrayResize(g_stMsg, n + 1);
   g_stIds[n] = id;
   g_stMsg[n] = st;
   Log(id + " : " + st);
  }

string GetState(const string id)
  {
   for(int i = 0; i < ArraySize(g_stIds); i++)
      if(g_stIds[i] == id)
         return g_stMsg[i];
   return "";
  }

void ParseSymbols()
  {
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   ArrayResize(g_symbols, 0);
   for(int i = 0; i < n; i++)
     {
      string s = Trim(parts[i]);
      if(s == "")
         continue;
      int k = ArraySize(g_symbols);
      ArrayResize(g_symbols, k + 1);
      g_symbols[k] = s;
      if(!SymbolSelect(s, true))
         Log("symbole introuvable chez ce broker : " + s);
     }
  }

bool SymbolAllowed(const string sym)
  {
   for(int i = 0; i < ArraySize(g_symbols); i++)
      if(g_symbols[i] == sym)
         return true;
   return false;
  }

string IdFromComment(const string c)
  {
   if(StringSubstr(c, 0, 3) == "CE|")
      return StringSubstr(c, 3);
   return "";
  }

bool Halted() { return GvHas("H_" + UtcDayKey()); }

bool TradingAllowed()
  {
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
  }

//+------------------------------------------------------------------+
//| GitHub                                                           |
//+------------------------------------------------------------------+
string ContentsUrl(const string path)
  {
   return API_HOST + "/repos/" + InpOwner + "/" + InpRepo + "/contents/" + path;
  }

int Http(const string method, const string url, const string accept, const string body, string &response)
  {
   string headers = "Authorization: Bearer " + InpToken + "\r\n"
                    + "Accept: " + accept + "\r\n"
                    + "User-Agent: CryptoExecutor\r\n"
                    + "X-GitHub-Api-Version: 2022-11-28\r\n";
   char data[];
   if(StringLen(body) > 0)
     {
      headers += "Content-Type: application/json\r\n";
      int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(n > 0)
         ArrayResize(data, n - 1); // retire le 0 final
     }
   char   result[];
   string resHeaders;
   ResetLastError();
   int code = WebRequest(method, url, headers, 20000, data, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      response = "";
      if(err == 4014)
         g_lastError = "URL non autorisée : ajoute https://api.github.com dans Outils > Options > Expert Advisors";
      else
         g_lastError = "WebRequest erreur " + IntegerToString(err);
      return -1;
     }
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == 401)
      g_lastError = "token GitHub refusé (401)";
   return code;
  }

int GetRaw(const string path, const string branch, string &text)
  {
   return Http("GET", ContentsUrl(path) + "?ref=" + branch, "application/vnd.github.raw+json", "", text);
  }

string JsonFirst(const string json, const string field)
  {
   string pat = "\"" + field + "\":\"";
   int p = StringFind(json, pat);
   if(p < 0)
     {
      pat = "\"" + field + "\": \"";
      p = StringFind(json, pat);
      if(p < 0)
         return "";
     }
   p += StringLen(pat);
   int q = StringFind(json, "\"", p);
   if(q < 0)
      return "";
   return StringSubstr(json, p, q - p);
  }

string Base64(const string text)
  {
   uchar src[], key[], dst[];
   int n = StringToCharArray(text, src, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(src, n - 1);
   if(CryptEncode(CRYPT_BASE64, src, key, dst) <= 0)
      return "";
   string b = CharArrayToString(dst, 0, WHOLE_ARRAY, CP_ACP);
   StringReplace(b, "\r", "");
   StringReplace(b, "\n", "");
   return b;
  }

bool PutData(const string content)
  {
   string b64 = Base64(content);
   if(b64 == "")
     {
      g_lastError = "encodage base64 impossible";
      return false;
     }
   for(int attempt = 0; attempt < 2; attempt++)
     {
      if(g_dataSha == "")
        {
         string meta;
         int c = Http("GET", ContentsUrl(InpDataPath) + "?ref=" + InpDataBranch, "application/vnd.github+json", "", meta);
         if(c == 200)
            g_dataSha = JsonFirst(meta, "sha");
         else
            if(c != 404)
              {
               if(c != -1)
                  g_lastError = "lecture de " + InpDataPath + " : HTTP " + IntegerToString(c);
               return false;
              }
        }
      string body = "{\"message\":\"CryptoExecutor " + Fmt(TimeGMT()) + " UTC\",\"branch\":\"" + InpDataBranch
                    + "\",\"content\":\"" + b64 + "\"";
      if(g_dataSha != "")
         body += ",\"sha\":\"" + g_dataSha + "\"";
      body += "}";
      string resp;
      int code = Http("PUT", ContentsUrl(InpDataPath), "application/vnd.github+json", body, resp);
      if(code == 200 || code == 201)
        {
         g_dataSha = JsonFirst(resp, "sha");
         return true;
        }
      if(code == 409 || code == 422)
        {
         g_dataSha = ""; // fichier modifié entre-temps : on relit son sha
         continue;
        }
      if(code != -1)
         g_lastError = "envoi de " + InpDataPath + " : HTTP " + IntegerToString(code);
      return false;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Positions et ordres de l'EA                                      |
//+------------------------------------------------------------------+
int CountOurs()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         n++;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         n++;
   return n;
  }

// 1 = ordre en attente, 2 = position ouverte, 0 = rien
int FindById(const string id)
  {
   string c = "CE|" + id;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_COMMENT) == c)
         return 1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_COMMENT) == c)
         return 2;
   return 0;
  }

void CloseAllOurs()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         g_trade.PositionClose(t);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         g_trade.OrderDelete(t);
     }
  }

//+------------------------------------------------------------------+
//| Taille de position                                               |
//+------------------------------------------------------------------+
// Marge que prendraient nos ordres en attente s'ils se déclenchaient tous
double PendingMargin()
  {
   double total = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      bool buy  = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      double m  = 0.0;
      if(OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, OrderGetString(ORDER_SYMBOL),
                         OrderGetDouble(ORDER_VOLUME_CURRENT), OrderGetDouble(ORDER_PRICE_OPEN), m))
         total += m;
     }
   return total;
  }

double LotsForRisk(const string sym, const bool isBuy, const double entry, const double sl, const double riskPct, string &why)
  {
   ENUM_ORDER_TYPE t = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double loss1 = 0.0;
   if(!OrderCalcProfit(t, sym, 1.0, entry, sl, loss1) || loss1 >= 0.0)
     {
      why = "calcul du risque impossible";
      return 0.0;
     }
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = vmin;
   double lots = MathFloor(riskMoney / MathAbs(loss1) / step + 1e-9) * step;
   if(lots > vmax)
      lots = vmax;
   if(lots < vmin)
     {
      why = StringFormat("lot minimum %.2f = %.2f %s de risque, au-dessus des %.2f autorisés",
                         vmin, MathAbs(loss1) * vmin, AccountInfoString(ACCOUNT_CURRENCY), riskMoney);
      return 0.0;
     }
   double margin = 0.0;
   if(OrderCalcMargin(t, sym, lots, entry, margin) && margin > 0.0)
     {
      double freeM = (AccountInfoDouble(ACCOUNT_MARGIN_FREE) - PendingMargin()) * 0.8;
      if(margin > freeM)
        {
         lots = MathFloor(lots * freeM / margin / step + 1e-9) * step;
         if(lots < vmin)
           {
            why = "marge insuffisante pour le lot minimum (ordres déjà en attente compris)";
            return -1.0; // temporaire : la marge peut se libérer
           }
        }
     }
   return NormalizeDouble(lots, VolDigits(step));
  }

ENUM_ORDER_TYPE_TIME TimeMode(const string sym, datetime &exp)
  {
   int em = (int)SymbolInfoInteger(sym, SYMBOL_EXPIRATION_MODE);
   exp = 0;
   if((em & SYMBOL_EXPIRATION_GTC) != 0)
      return ORDER_TIME_GTC;
   if((em & SYMBOL_EXPIRATION_SPECIFIED) != 0 && g_planValidUntil > 0)
     {
      exp = (datetime)((long)g_planValidUntil + ServerOffset());
      return ORDER_TIME_SPECIFIED;
     }
   return ORDER_TIME_DAY;
  }

//+------------------------------------------------------------------+
//| Plan                                                             |
//+------------------------------------------------------------------+
// Retourne 1 = plan lu, 0 = pas de plan (404), -1 = erreur de lecture
int ReadPlan(PlanLine &lines[])
  {
   ArrayResize(lines, 0);
   string text;
   int code = GetRaw(InpPlanPath, InpPlanBranch, text);
   if(code == 404)
      return 0;
   if(code != 200)
     {
      if(code != -1 && code != 401)
         g_lastError = "lecture du plan : HTTP " + IntegerToString(code);
      return -1;
     }
   g_planDate = "";
   g_planValidUntil = 0;
   string rows[];
   int n = StringSplit(text, '\n', rows);
   for(int i = 0; i < n; i++)
     {
      string r = Trim(rows[i]);
      if(r == "")
         continue;
      string f[];
      int k = StringSplit(r, ';', f);
      for(int j = 0; j < k; j++)
         f[j] = Trim(f[j]);
      if(StringGetCharacter(r, 0) == '#')
        {
         if(k >= 2 && f[0] == "#date")
            g_planDate = f[1];
         if(k >= 2 && f[0] == "#valid_until_utc")
            g_planValidUntil = ParseUtc(f[1]);
         continue;
        }
      if(f[0] == "ID")
         continue;
      if(k < 6)
        {
         Log("ligne du plan ignorée (colonnes manquantes) : " + r);
         continue;
        }
      PlanLine p;
      p.id    = f[0];
      p.sym   = f[1];
      p.order = f[2];
      StringToUpper(p.order);
      p.entry = StringToDouble(f[3]);
      p.sl    = StringToDouble(f[4]);
      p.tp    = StringToDouble(f[5]);
      p.risk  = (k >= 7 && f[6] != "") ? StringToDouble(f[6]) : InpRiskPct;
      p.note  = (k >= 8) ? f[7] : "";
      if(StringLen(p.id) == 0 || StringLen(p.id) > 24)
        {
         Log("ligne du plan ignorée (ID vide ou de plus de 24 caractères) : " + r);
         continue;
        }
      int s = ArraySize(lines);
      ArrayResize(lines, s + 1);
      lines[s] = p;
     }
   return 1;
  }

// Empreinte d'une ligne : si Claude corrige une ligne rejetée, elle est retentée
double LineSig(PlanLine &p)
  {
   string s = p.sym + "|" + p.order + "|" + DoubleToString(p.entry, 8) + "|" + DoubleToString(p.sl, 8) + "|"
              + DoubleToString(p.tp, 8) + "|" + DoubleToString(p.risk, 4);
   ulong h = 5381;
   for(int i = 0; i < StringLen(s); i++)
      h = (h * 33 + (ulong)StringGetCharacter(s, i)) % 2147483647;
   return (double)h;
  }

bool InPlan(PlanLine &lines[], const string id)
  {
   for(int i = 0; i < ArraySize(lines); i++)
      if(lines[i].id == id)
         return true;
   return false;
  }

void PlaceLine(PlanLine &p)
  {
   string kDone = "P_" + p.id;
   string kSig  = "S_" + p.id;
   double sig   = LineSig(p);

   // ligne rejetée puis modifiée dans le plan : on la retente
   if(GvHas(kDone) && GvGet(kDone) < 0 && (!GvHas(kSig) || GvGet(kSig) != sig))
     {
      GvDel(kDone);
      GvDel("F_" + p.id);
     }

   if(GvHas(kDone))
     {
      if(GvGet(kDone) < 0)
        {
         if(GetState(p.id) == "")
            SetState(p.id, "rejeté (raison dans le journal Experts)");
         return;
        }
      int where = FindById(p.id);
      SetState(p.id, where == 1 ? "ordre posé" : (where == 2 ? "position ouverte" : "terminé"));
      return;
     }
   if(!SymbolAllowed(p.sym))
     {
      SetState(p.id, "rejeté : symbole non autorisé (" + p.sym + ")");
      GvSet(kDone, -1);
      GvSet(kSig, sig);
      return;
     }
   if(!SymbolSelect(p.sym, true))
     {
      SetState(p.id, "rejeté : symbole introuvable chez ce broker (" + p.sym + ")");
      GvSet(kDone, -1);
      GvSet(kSig, sig);
      return;
     }
   int where = FindById(p.id);
   if(where > 0)
     {
      GvSet(kDone, 1);
      SetState(p.id, where == 1 ? "ordre posé" : "position ouverte");
      return;
     }
   if(Halted())
     {
      SetState(p.id, "en pause : stop journalier atteint");
      return;
     }
   if(CountOurs() >= InpMaxPositions)
     {
      SetState(p.id, "en attente : maximum de positions atteint");
      return;
     }

   MqlTick tk;
   if(!SymbolInfoTick(p.sym, tk) || tk.bid <= 0 || tk.ask <= 0)
     {
      SetState(p.id, "en attente : pas de cotation");
      return;
     }
   int    digits = (int)SymbolInfoInteger(p.sym, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(p.sym, SYMBOL_POINT);
   double tick   = SymbolInfoDouble(p.sym, SYMBOL_TRADE_TICK_SIZE);
   double stops  = (double)SymbolInfoInteger(p.sym, SYMBOL_TRADE_STOPS_LEVEL) * point;

   string o = p.order;
   bool known  = (o == "BUY" || o == "SELL" || o == "BUY_LIMIT" || o == "SELL_LIMIT" || o == "BUY_STOP" || o == "SELL_STOP");
   bool isBuy  = (StringFind(o, "BUY") == 0);
   bool market = (o == "BUY" || o == "SELL");
   double entry = market ? (isBuy ? tk.ask : tk.bid) : NormPrice(p.entry, tick, digits);
   double sl    = NormPrice(p.sl, tick, digits);
   double tp    = NormPrice(p.tp, tick, digits);

   //--- erreurs définitives : la ligne est fausse
   string why = "";
   if(!known)
      why = "type d'ordre inconnu (" + o + ")";
   else
      if(isBuy && !(sl < entry && entry < tp))
         why = "pour un achat il faut SL < entrée < TP";
      else
         if(!isBuy && !(tp < entry && entry < sl))
            why = "pour une vente il faut TP < entrée < SL";
         else
            if(MathAbs(tp - entry) < InpMinRR * MathAbs(entry - sl))
               why = StringFormat("ratio gain/risque %.2f inférieur au minimum %.2f", MathAbs(tp - entry) / MathAbs(entry - sl), InpMinRR);
            else
               if(MathAbs(entry - sl) <= stops || MathAbs(tp - entry) <= stops)
                  why = "SL ou TP trop proche de l'entrée pour le broker";
   if(why != "" && !market)
     {
      SetState(p.id, "rejeté : " + why);
      GvSet(kDone, -1);
      GvSet(kSig, sig);
      return;
     }
   if(why != "")
     {
      // au marché, le prix bouge : on réessaie au prochain passage
      SetState(p.id, "en attente : " + why + " au prix actuel");
      return;
     }

   //--- erreurs temporaires : le prix n'est pas du bon côté
   string wait = "";
   if(o == "BUY_LIMIT"  && entry >= tk.ask - stops)
      wait = "prix déjà sous l'entrée, on attend qu'il remonte";
   if(o == "SELL_LIMIT" && entry <= tk.bid + stops)
      wait = "prix déjà au-dessus de l'entrée, on attend qu'il redescende";
   if(o == "BUY_STOP"   && entry <= tk.ask + stops)
      wait = "prix déjà au-dessus de l'entrée stop, on attend";
   if(o == "SELL_STOP"  && entry >= tk.bid - stops)
      wait = "prix déjà sous l'entrée stop, on attend";
   int spreadPts = (int)MathRound((tk.ask - tk.bid) / point);
   if(market && InpMaxSpreadPts > 0 && spreadPts > InpMaxSpreadPts)
      wait = StringFormat("spread trop large (%d points)", spreadPts);
   if(wait != "")
     {
      SetState(p.id, "en attente : " + wait);
      return;
     }

   //--- taille
   double riskPct = (p.risk > 0.0) ? MathMin(p.risk, InpRiskPct) : InpRiskPct;
   string lotWhy = "";
   double lots = LotsForRisk(p.sym, isBuy, entry, sl, riskPct, lotWhy);
   if(lots < 0.0)
     {
      SetState(p.id, "en attente : " + lotWhy);
      return;
     }
   if(lots == 0.0)
     {
      SetState(p.id, "rejeté : " + lotWhy);
      GvSet(kDone, -1);
      GvSet(kSig, sig);
      return;
     }

   //--- envoi
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(p.sym);
   g_trade.SetDeviationInPoints((ulong)MathMax(50, 2 * spreadPts));
   string cmt = "CE|" + p.id;
   datetime exp = 0;
   ENUM_ORDER_TYPE_TIME tm = TimeMode(p.sym, exp);
   bool ok = false;
   if(o == "BUY")
      ok = g_trade.Buy(lots, p.sym, 0.0, sl, tp, cmt);
   else
      if(o == "SELL")
         ok = g_trade.Sell(lots, p.sym, 0.0, sl, tp, cmt);
      else
         if(o == "BUY_LIMIT")
            ok = g_trade.BuyLimit(lots, entry, p.sym, sl, tp, tm, exp, cmt);
         else
            if(o == "SELL_LIMIT")
               ok = g_trade.SellLimit(lots, entry, p.sym, sl, tp, tm, exp, cmt);
            else
               if(o == "BUY_STOP")
                  ok = g_trade.BuyStop(lots, entry, p.sym, sl, tp, tm, exp, cmt);
               else
                  ok = g_trade.SellStop(lots, entry, p.sym, sl, tp, tm, exp, cmt);

   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      GvSet(kDone, 1);
      GvDel("F_" + p.id);
      ulong ord = g_trade.ResultOrder();
      if(ord > 0)
         GvSet("R_" + IntegerToString((long)ord), MathAbs(entry - sl));
      string what = StringFormat("%s %s %s lots à %s, SL %s, TP %s (risque %.1f %%)", p.sym, o, DoubleToString(lots, VolDigits(SymbolInfoDouble(p.sym, SYMBOL_VOLUME_STEP))),
                                 DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits), riskPct);
      SetState(p.id, market ? "position ouverte" : "ordre posé");
      if(market)
         Log("entrée " + what); // la notification part depuis OnTradeTransaction
      else
         Notify("ordre posé " + what);
      g_lastData = 0; // envoi des données au prochain passage
     }
   else
     {
      double fails = 1.0;
      if(GvHas("F_" + p.id))
         fails = GvGet("F_" + p.id) + 1.0;
      GvSet("F_" + p.id, fails);
      string err = StringFormat("refusé par le broker (%u : %s), essai %d/3", rc, g_trade.ResultRetcodeDescription(), (int)fails);
      if(fails >= 3)
        {
         GvSet(kDone, -1);
      GvSet(kSig, sig);
         SetState(p.id, "rejeté : " + err);
         Notify(p.id + " " + err);
        }
      else
         SetState(p.id, "en attente : " + err);
     }
  }

void ProcessPlan()
  {
   PlanLine lines[];
   int r = ReadPlan(lines);
   if(r < 0)
     {
      g_planStatus = "lecture impossible : " + g_lastError + " (rien n'est modifié)";
      return;
     }
   bool valid = (r == 1 && g_planValidUntil > 0 && TimeGMT() <= g_planValidUntil);

   //--- annule nos ordres en attente absents du plan, ou tous si le plan n'est plus valable
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      string id = IdFromComment(OrderGetString(ORDER_COMMENT));
      if(valid && InPlan(lines, id))
         continue;
      if(g_trade.OrderDelete(t))
        {
         if(id != "")
           {
            GvDel("P_" + id); // si l'ID revient dans un plan, il sera reposé
            SetState(id, "ordre annulé (retiré du plan ou plan expiré)");
           }
         Notify("ordre " + id + " annulé : retiré du plan ou plan expiré");
        }
     }

   g_zones = "";
   if(r == 0)
     {
      g_planStatus = "aucun plan dans " + InpPlanPath;
      return;
     }
   if(g_planValidUntil == 0)
     {
      g_planStatus = "plan ignoré : ligne #valid_until_utc absente ou illisible";
      return;
     }
   if(!valid)
     {
      g_planStatus = "plan du " + g_planDate + " expiré depuis " + Fmt(g_planValidUntil) + " UTC";
      return;
     }

   for(int i = 0; i < ArraySize(lines); i++)
     {
      PlaceLine(lines[i]);
      int zd = (int)SymbolInfoInteger(lines[i].sym, SYMBOL_DIGITS);
      g_zones += StringFormat("ZONE;%s;%s;%s;%s;%s;%s;%.2f;%s\n", lines[i].id, lines[i].sym, lines[i].order,
                              DoubleToString(lines[i].entry, zd), DoubleToString(lines[i].sl, zd), DoubleToString(lines[i].tp, zd),
                              lines[i].risk, Clean(GetState(lines[i].id)));
     }
   g_planStatus = StringFormat("plan du %s : %d ligne(s), valable jusqu'au %s UTC", g_planDate, ArraySize(lines), Fmt(g_planValidUntil));
  }

//+------------------------------------------------------------------+
//| Actions (fermer, resserrer le stop, changer l'objectif, annuler) |
//+------------------------------------------------------------------+
bool ApplyAction(const string action, const ulong ticket, const double value, string &msg)
  {
   if(action == "CANCEL")
     {
      if(!OrderSelect(ticket) || OrderGetInteger(ORDER_MAGIC) != InpMagic)
        {
         msg = "ordre introuvable";
         return false;
        }
      if(!g_trade.OrderDelete(ticket))
        {
         msg = "annulation refusée : " + g_trade.ResultRetcodeDescription();
         return false;
        }
      msg = "ordre annulé";
      return true;
     }

   if(!PositionSelectByTicket(ticket) || PositionGetInteger(POSITION_MAGIC) != InpMagic)
     {
      msg = "position introuvable (déjà fermée ?)";
      return false;
     }
   string sym  = PositionGetString(POSITION_SYMBOL);
   bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
   int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double stops = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
   double v    = NormPrice(value, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), dg);

   if(action == "CLOSE")
     {
      if(!g_trade.PositionClose(ticket))
        {
         msg = "fermeture refusée : " + g_trade.ResultRetcodeDescription();
         return false;
        }
      msg = "position fermée";
      return true;
     }
   if(action == "SL")
     {
      bool tighter = buy ? (sl == 0.0 || v > sl) : (sl == 0.0 || v < sl);
      bool side    = buy ? (v < bid - stops) : (v > ask + stops);
      if(!tighter)
        {
         msg = "SL refusé : il élargirait le risque";
         return false;
        }
      if(!side)
        {
         msg = "SL refusé : trop près du prix ou du mauvais côté";
         return false;
        }
      if(!g_trade.PositionModify(ticket, v, tp))
        {
         msg = "SL refusé par le broker : " + g_trade.ResultRetcodeDescription();
         return false;
        }
      msg = "SL déplacé à " + DoubleToString(v, dg);
      return true;
     }
   if(action == "TP")
     {
      bool side = buy ? (v > ask + stops) : (v < bid - stops);
      if(!side)
        {
         msg = "TP refusé : trop près du prix ou du mauvais côté";
         return false;
        }
      if(!g_trade.PositionModify(ticket, sl, v))
        {
         msg = "TP refusé par le broker : " + g_trade.ResultRetcodeDescription();
         return false;
        }
      msg = "TP déplacé à " + DoubleToString(v, dg);
      return true;
     }
   msg = "action inconnue (" + action + ")";
   return false;
  }

void ProcessActions()
  {
   string text;
   int code = GetRaw(InpActionsPath, InpPlanBranch, text);
   if(code != 200)
      return; // 404 = pas d'action
   string rows[];
   int n = StringSplit(text, '\n', rows);
   for(int i = 0; i < n; i++)
     {
      string r = Trim(rows[i]);
      if(r == "")
         continue;
      string f[];
      int k = StringSplit(r, ';', f);
      for(int j = 0; j < k; j++)
         f[j] = Trim(f[j]);
      if(StringGetCharacter(r, 0) == '#')
        {
         if(k >= 2 && f[0] == "#date")
           {
            datetime d = ParseUtc(f[1]);
            if(d > 0 && TimeGMT() - d > 2 * 86400)
               return; // fichier trop vieux : on ignore tout
           }
         continue;
        }
      if(f[0] == "ID" || k < 4)
         continue;
      string key = "A_" + f[0];
      if(StringLen(f[0]) > 40 || GvHas(key))
         continue;
      string action = f[1];
      StringToUpper(action);
      ulong  ticket = (ulong)StringToInteger(f[2]);
      double value  = StringToDouble(f[3]);
      string msg;
      bool ok = ApplyAction(action, ticket, value, msg);
      GvSet(key, ok ? 1 : -1);
      string reason = (k >= 5) ? " (" + f[4] + ")" : "";
      Notify("action " + f[0] + " " + action + " #" + IntegerToString((long)ticket) + " : " + msg + reason);
      g_lastData = 0;
     }
  }

//+------------------------------------------------------------------+
//| Gestion continue : stop journalier, stop au prix d'entrée        |
//+------------------------------------------------------------------+
void Manage()
  {
   string day = UtcDayKey();
   if(!GvHas("D_" + day))
      GvSet("D_" + day, AccountInfoDouble(ACCOUNT_BALANCE));
   double start = GvGet("D_" + day);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!Halted() && InpMaxDailyLossPct > 0.0 && start > 0.0 && eq <= start * (1.0 - InpMaxDailyLossPct / 100.0))
     {
      GvSet("H_" + day, 1);
      CloseAllOurs();
      Notify(StringFormat("stop journalier : perte de %.1f %% atteinte, tout est fermé jusqu'à 0h UTC", (start - eq) / start * 100.0));
      g_lastData = 0;
     }

   if(!InpBreakEven)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      long   pid  = PositionGetInteger(POSITION_IDENTIFIER);
      string k    = "R_" + IntegerToString(pid);
      if(!GvHas(k))
         continue;
      double risk = GvGet(k);
      if(risk <= 0.0)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask  = SymbolInfoDouble(sym, SYMBOL_ASK);
      int    dg   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double stops = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT);
      double be   = NormPrice(open, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), dg);
      if(buy)
        {
         if(sl >= be)
            continue;
         if(bid - open >= risk && bid - be > stops && g_trade.PositionModify(t, be, tp))
            Notify(StringFormat("%s : gain de 1R atteint, stop remonté au prix d'entrée %s", sym, DoubleToString(be, dg)));
        }
      else
        {
         if(sl > 0.0 && sl <= be)
            continue;
         if(open - ask >= risk && be - ask > stops && g_trade.PositionModify(t, be, tp))
            Notify(StringFormat("%s : gain de 1R atteint, stop descendu au prix d'entrée %s", sym, DoubleToString(be, dg)));
        }
     }
  }

//+------------------------------------------------------------------+
//| Réveil de Claude : appelle la tâche « Surveillance crypto » par  |
//| API dès qu'un événement compte sur un trade ouvert.              |
//+------------------------------------------------------------------+
bool WakeConfigured()
  {
   return InpWakeEnabled && StringLen(InpWakeURL) > 10 && StringLen(InpWakeToken) > 10;
  }

bool Once(const string key)
  {
   if(GvHas(key))
      return false;
   GvSet(key, (double)TimeGMT());
   return true;
  }

double AtrH1(const string sym)
  {
   MqlRates r[];
   int n = CopyRates(sym, PERIOD_H1, 1, 15, r);
   if(n < 15)
      return 0.0;
   double sum = 0.0;
   for(int i = 1; i < n; i++)
      sum += MathMax(r[i].high, r[i - 1].close) - MathMin(r[i].low, r[i - 1].close);
   return sum / (n - 1);
  }

void QueueWake(const string msg)
  {
   g_wakePending += msg;
   if(StringLen(g_wakePending) > 3000)
      g_wakePending = StringSubstr(g_wakePending, StringLen(g_wakePending) - 3000);
  }

void CheckEvents()
  {
   if(!WakeConfigured())
      return;
   string msg = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      string   sym    = PositionGetString(POSITION_SYMBOL);
      bool     buy    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl     = PositionGetDouble(POSITION_SL);
      double   pl     = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      long     pid    = PositionGetInteger(POSITION_IDENTIFIER);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      double   bid    = SymbolInfoDouble(sym, SYMBOL_BID);
      double   ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
      int      dg     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double   price  = buy ? bid : ask;
      string   k      = "W_" + IntegerToString((long)tk) + "_";
      string   head   = sym + " (ticket " + IntegerToString((long)tk) + ", " + (buy ? "achat" : "vente") + " à "
                        + DoubleToString(open, dg) + ", prix " + DoubleToString(price, dg) + ", SL " + DoubleToString(sl, dg)
                        + ", P/L " + DoubleToString(pl, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + ") : ";

      // 1. nouvelle position
      if(Once(k + "open"))
         msg += head + "nouvelle position ouverte.\n";

      // risque initial
      double risk = GvHas("R_" + IntegerToString(pid)) ? GvGet("R_" + IntegerToString(pid)) : 0.0;
      if(risk <= 0.0 && sl > 0.0 && ((buy && sl < open) || (!buy && sl > open)))
         risk = MathAbs(open - sl);
      bool   locked = (sl > 0.0) && (buy ? sl >= open : sl <= open);
      double gain   = buy ? bid - open : open - ask;

      // 2. paliers de gain
      if(risk > 0.0)
        {
         if(gain >= 0.5 * risk && Once(k + "r05"))
            msg += head + "le gain atteint 0,5R.\n";
         if(gain >= 1.0 * risk && Once(k + "r1"))
            msg += head + "le gain atteint 1R (l'EA remonte le stop au prix d'entrée).\n";
         if(gain >= 2.0 * risk && Once(k + "r2"))
            msg += head + "le gain atteint 2R.\n";
        }

      // 3. prix proche du stop (moins de 20 % de la distance de départ)
      if(risk > 0.0 && sl > 0.0 && !locked && MathAbs(price - sl) < 0.2 * risk && Once(k + "nearsl"))
         msg += head + "le prix est à moins de 20 % du stop.\n";

      // 4. élan H1 qui s'inverse (au plus toutes les 2 heures par position)
      datetime bar1 = iTime(sym, PERIOD_H1, 1);
      if(bar1 > opened)
        {
         bool rev = buy ? (iClose(sym, PERIOD_H1, 1) < iLow(sym, PERIOD_H1, 2))
                        : (iClose(sym, PERIOD_H1, 1) > iHigh(sym, PERIOD_H1, 2));
         string kl   = k + "h1";
         double last = GvHas(kl) ? GvGet(kl) : 0.0;
         if(rev && (double)bar1 - last >= 7200)
           {
            GvSet(kl, (double)bar1);
            msg += head + "la dernière bougie H1 a clôturé " + (buy ? "sous le plus bas" : "au-dessus du plus haut")
                   + " de la précédente (élan qui s'inverse).\n";
           }
        }

      // 5. mouvement brutal contre la position : plus d'1 ATR H1 en 15 minutes (au plus une fois par heure)
      double atr = AtrH1(sym);
      MqlRates m5[];
      if(atr > 0.0 && CopyRates(sym, PERIOD_M5, 0, 4, m5) == 4)
        {
         double move = buy ? (m5[0].open - bid) : (ask - m5[0].open);
         string kb   = k + "brut";
         double last = GvHas(kb) ? GvGet(kb) : 0.0;
         if(move >= atr && (double)TimeGMT() - last >= 3600)
           {
            GvSet(kb, (double)TimeGMT());
            msg += head + StringFormat("mouvement brutal contre la position : %s en 15 minutes (ATR H1 %s).\n",
                                       DoubleToString(move, dg), DoubleToString(atr, dg));
           }
        }
     }
   if(msg != "")
      QueueWake(msg);
  }

string JsonEscape(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "");
   StringReplace(s, "\t", " ");
   return s;
  }

void SendWake()
  {
   if(!WakeConfigured())
     {
      g_wakeStatus = InpWakeEnabled ? "non configuré (adresse ou jeton manquant)" : "désactivé";
      return;
     }
   if(g_wakePending == "")
      return;
   string day = UtcDayKey();
   double done = GvHas("WN_" + day) ? GvGet("WN_" + day) : 0.0;
   if(done >= InpWakeMaxDay)
     {
      g_wakeStatus  = "limite de " + IntegerToString(InpWakeMaxDay) + " réveils atteinte aujourd'hui (UTC)";
      g_wakePending = "";
      return;
     }
   if(g_wakeLast > 0 && TimeLocal() - g_wakeLast < InpWakeMinMin * 60)
      return; // trop tôt : on regroupe avec les événements suivants

   PushData(); // données fraîches pour Claude avant de le réveiller

   string text = "Événements détectés par CryptoExecutor à " + Fmt(TimeGMT()) + " UTC :\n" + g_wakePending;
   string body = "{\"text\":\"" + JsonEscape(text) + "\"}";
   char   data[], result[];
   string rh;
   int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(data, n - 1);
   string headers = "Authorization: Bearer " + InpWakeToken + "\r\n"
                    + "anthropic-beta: experimental-cc-routine-2026-04-01\r\n"
                    + "anthropic-version: 2023-06-01\r\n"
                    + "Content-Type: application/json\r\n";
   ResetLastError();
   int code = WebRequest("POST", InpWakeURL, headers, 20000, data, result, rh);
   g_wakeLast = TimeLocal();
   if(code == -1)
     {
      int err = GetLastError();
      g_wakeStatus = (err == 4014) ? "réveil bloqué : ajoute https://api.anthropic.com dans Outils > Options > Expert Advisors"
                                   : "réveil impossible (WebRequest erreur " + IntegerToString(err) + ")";
      return; // on garde les événements pour réessayer
     }
   if(code >= 200 && code < 300)
     {
      GvSet("WN_" + day, done + 1.0);
      g_wakeStatus  = "dernier réveil le " + Fmt(TimeGMT()) + " UTC";
      Log("réveil de Claude envoyé : " + g_wakePending);
      g_wakePending = "";
      return;
     }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string m    = JsonFirst(resp, "message");
   if(code == 401 || code == 403)
      g_wakeStatus = "réveil refusé : jeton ou adresse de la tâche incorrects (HTTP " + IntegerToString(code) + ")";
   else
      g_wakeStatus = "réveil refusé (HTTP " + IntegerToString(code) + (m != "" ? " : " + m : "") + ")";
   if(code != 429)
      g_wakePending = ""; // erreur définitive : on n'insiste pas
  }

//+------------------------------------------------------------------+
//| Données envoyées dans GitHub                                     |
//+------------------------------------------------------------------+
string OrderTypeName(const long type)
  {
   string s = EnumToString((ENUM_ORDER_TYPE)type);
   StringReplace(s, "ORDER_TYPE_", "");
   return s;
  }

string DealTypeName(const long type)
  {
   if(type == DEAL_TYPE_BUY)
      return "BUY";
   if(type == DEAL_TYPE_SELL)
      return "SELL";
   if(type == DEAL_TYPE_BALANCE)
      return "BALANCE";
   return "OTHER";
  }

string DealEntryName(const long e)
  {
   if(e == DEAL_ENTRY_IN)
      return "IN";
   if(e == DEAL_ENTRY_OUT)
      return "OUT";
   if(e == DEAL_ENTRY_INOUT)
      return "INOUT";
   return "OUT_BY";
  }

void AddBars(string &s, const string sym, const ENUM_TIMEFRAMES tf, const string tfName, const int count, const int dg)
  {
   MqlRates rates[];
   int n = CopyRates(sym, tf, 0, count, rates);
   for(int i = 0; i < n; i++)
      s += "BAR;" + sym + ";" + tfName + ";" + Fmt(ToUtc(rates[i].time)) + ";"
           + DoubleToString(rates[i].open, dg) + ";" + DoubleToString(rates[i].high, dg) + ";"
           + DoubleToString(rates[i].low, dg) + ";" + DoubleToString(rates[i].close, dg) + ";"
           + IntegerToString(rates[i].tick_volume) + "\n";
  }

string BuildData()
  {
   string s = "#generated_utc;" + Fmt(TimeGMT()) + "\n";
   s += "#format;ACCOUNT EA SPEC ZONE POS ORDER DEAL QUOTE BAR (heures en UTC)\n";
   bool demo = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO);
   s += "ACCOUNT;" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ";" + Clean(AccountInfoString(ACCOUNT_SERVER)) + ";"
        + AccountInfoString(ACCOUNT_CURRENCY) + ";" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ";"
        + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ";" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + ";"
        + (demo ? "DEMO" : "REAL") + "\n";
   string day = UtcDayKey();
   s += "EA;version=" + EA_VERSION + ";magic=" + IntegerToString(InpMagic) + ";plan=" + Clean(g_planStatus)
        + ";risque=" + DoubleToString(InpRiskPct, 2) + ";maxpos=" + IntegerToString(InpMaxPositions)
        + ";perte_max_jour=" + DoubleToString(InpMaxDailyLossPct, 2) + ";rr_min=" + DoubleToString(InpMinRR, 2)
        + ";solde_debut_jour=" + DoubleToString(GvHas("D_" + day) ? GvGet("D_" + day) : 0.0, 2)
        + ";stop_jour=" + (Halted() ? "1" : "0") + ";trading_algo=" + (TradingAllowed() ? "1" : "0")
        + ";reveil=" + Clean(g_wakeStatus) + ";erreur=" + Clean(g_lastError) + ";dernier_evenement=" + Clean(g_lastEvent) + "\n";

   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      string sym = g_symbols[i];
      if(!SymbolSelect(sym, true))
         continue;
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double m1 = 0.0;
      if(!OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, SymbolInfoDouble(sym, SYMBOL_ASK), m1))
         m1 = 0.0;
      s += "SPEC;" + sym + ";" + IntegerToString(dg) + ";" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_POINT), dg) + ";"
           + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE), 4) + ";"
           + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 4) + ";" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), 4) + ";"
           + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), 2) + ";" + IntegerToString(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL)) + ";"
           + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), dg) + ";" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE), 6) + ";"
           + DoubleToString(m1, 2) + "\n";
     }

   s += g_zones;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      s += "POS;" + IntegerToString((long)t) + ";" + sym + ";" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL") + ";"
           + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + ";" + Fmt(ToUtc((datetime)PositionGetInteger(POSITION_TIME))) + ";"
           + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg) + ";" + DoubleToString(PositionGetDouble(POSITION_SL), dg) + ";"
           + DoubleToString(PositionGetDouble(POSITION_TP), dg) + ";" + DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), dg) + ";"
           + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + ";" + DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + ";"
           + IntegerToString(PositionGetInteger(POSITION_MAGIC)) + ";" + Clean(PositionGetString(POSITION_COMMENT)) + "\n";
     }

   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      s += "ORDER;" + IntegerToString((long)t) + ";" + sym + ";" + OrderTypeName(OrderGetInteger(ORDER_TYPE)) + ";"
           + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + ";" + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), dg) + ";"
           + DoubleToString(OrderGetDouble(ORDER_SL), dg) + ";" + DoubleToString(OrderGetDouble(ORDER_TP), dg) + ";"
           + Fmt(ToUtc((datetime)OrderGetInteger(ORDER_TIME_SETUP))) + ";" + IntegerToString(OrderGetInteger(ORDER_MAGIC)) + ";"
           + Clean(OrderGetString(ORDER_COMMENT)) + "\n";
     }

   datetime now = TimeTradeServer();
   if(HistorySelect(now - 7 * 86400, now + 86400))
     {
      int nd = HistoryDealsTotal();
      for(int i = 0; i < nd; i++)
        {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0)
            continue;
         string sym = HistoryDealGetString(t, DEAL_SYMBOL);
         int dg = (sym == "") ? 2 : (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         s += "DEAL;" + IntegerToString((long)t) + ";" + Fmt(ToUtc((datetime)HistoryDealGetInteger(t, DEAL_TIME))) + ";" + sym + ";"
              + DealTypeName(HistoryDealGetInteger(t, DEAL_TYPE)) + ";" + DealEntryName(HistoryDealGetInteger(t, DEAL_ENTRY)) + ";"
              + DoubleToString(HistoryDealGetDouble(t, DEAL_VOLUME), 2) + ";" + DoubleToString(HistoryDealGetDouble(t, DEAL_PRICE), dg) + ";"
              + DoubleToString(HistoryDealGetDouble(t, DEAL_PROFIT), 2) + ";" + DoubleToString(HistoryDealGetDouble(t, DEAL_SWAP), 2) + ";"
              + DoubleToString(HistoryDealGetDouble(t, DEAL_COMMISSION), 2) + ";" + IntegerToString(HistoryDealGetInteger(t, DEAL_MAGIC)) + ";"
              + IntegerToString(HistoryDealGetInteger(t, DEAL_POSITION_ID)) + ";" + Clean(HistoryDealGetString(t, DEAL_COMMENT)) + "\n";
        }
     }

   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      string sym = g_symbols[i];
      MqlTick tk;
      if(!SymbolInfoTick(sym, tk))
         continue;
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
      s += "QUOTE;" + sym + ";" + DoubleToString(tk.bid, dg) + ";" + DoubleToString(tk.ask, dg) + ";"
           + IntegerToString((int)MathRound((tk.ask - tk.bid) / pt)) + ";" + IntegerToString(dg) + "\n";
     }

   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      string sym = g_symbols[i];
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      AddBars(s, sym, PERIOD_D1, "D1", 120, dg);
      AddBars(s, sym, PERIOD_H4, "H4", 180, dg);
      AddBars(s, sym, PERIOD_H1, "H1", 240, dg);
      AddBars(s, sym, PERIOD_M15, "M15", 192, dg);
     }
   return s;
  }

void PushData()
  {
   if(PutData(BuildData()))
     {
      g_lastPush = Fmt(TimeGMT()) + " UTC";
      if(StringFind(g_lastError, "envoi") == 0 || StringFind(g_lastError, "lecture de") == 0)
         g_lastError = "";
     }
  }

//+------------------------------------------------------------------+
//| Panneau sur le graphique                                         |
//+------------------------------------------------------------------+
void ShowPanel()
  {
   string s = "CryptoExecutor " + EA_VERSION + "  (magic " + IntegerToString(InpMagic) + ")\n";
   s += "Plan : " + g_planStatus + "\n";
   for(int i = 0; i < ArraySize(g_stIds); i++)
      s += "   " + g_stIds[i] + " : " + g_stMsg[i] + "\n";
   s += StringFormat("Positions + ordres EA : %d / %d   |   risque %.1f %%   |   stop jour %.1f %%%s\n",
                     CountOurs(), InpMaxPositions, InpRiskPct, InpMaxDailyLossPct, Halted() ? "  (ATTEINT)" : "");
   s += "Dernier envoi des données : " + g_lastPush + "\n";
   s += "Réveil de Claude : " + g_wakeStatus + "\n";
   if(!TradingAllowed())
      s += "!! Trading algo désactivé : active le bouton « Trading algo »\n";
   if(g_lastError != "")
      s += "!! " + g_lastError + "\n";
   if(g_lastEvent != "")
      s += "Dernier événement : " + g_lastEvent + "\n";
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Evénements MT5                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_prefix = "CE" + IntegerToString(InpMagic) + "_";
   if(StringLen(InpToken) < 10)
     {
      Alert("CryptoExecutor : renseigne le token GitHub dans les réglages de l'EA.");
      return INIT_PARAMETERS_INCORRECT;
     }
   ParseSymbols();
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_lastPlan = 0;
   g_lastData = 0;
   g_wakeStatus = WakeConfigured() ? "prêt" : (InpWakeEnabled ? "non configuré (adresse ou jeton manquant)" : "désactivé");
   if(InpWakeTest && WakeConfigured())
      QueueWake("Test de connexion envoyé par CryptoExecutor au démarrage. Lis juste crypto/data.csv et réponds « Réveil OK » en une ligne avec le solde du compte.\n");
   EventSetTimer(10);
   Log("démarré sur le compte " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " (" + AccountInfoString(ACCOUNT_SERVER) + ")");
   ShowPanel();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTick()
  {
   // tout passe par le minuteur : l'EA fonctionne même quand le graphique est calme
  }

void OnTimer()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      ShowPanel();
      return;
     }
   if(TradingAllowed())
      Manage();
   CheckEvents();
   SendWake();

   datetime now = TimeLocal();
   if(now - g_lastPlan >= InpPlanEveryMin * 60)
     {
      g_lastPlan = now;
      if(TradingAllowed())
        {
         ProcessActions();
         ProcessPlan();
        }
      else
         g_planStatus = "trading algo désactivé : rien n'est exécuté";
     }
   if(now - g_lastData >= InpDataEveryMin * 60)
     {
      g_lastData = now;
      PushData();
     }
   ShowPanel();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   string sym   = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   long   entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   double vol   = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double res   = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   string side  = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY) ? "achat" : "vente";
   if(entry == DEAL_ENTRY_IN)
      Notify(StringFormat("entrée %s %s %.2f lot(s) à %s", side, sym, vol, DoubleToString(price, dg)));
   else
      Notify(StringFormat("sortie %s %.2f lot(s) à %s, résultat %.2f %s", sym, vol, DoubleToString(price, dg), res, AccountInfoString(ACCOUNT_CURRENCY)));
   g_lastData = 0; // données envoyées au prochain passage du minuteur
  }
//+------------------------------------------------------------------+
