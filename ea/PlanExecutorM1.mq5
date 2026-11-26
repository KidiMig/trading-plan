//+------------------------------------------------------------------+
//|                                            PlanExecutorM1.mq5    |
//|  OBSERVATION M1 du « Plan de trading du jour » : NE TRADE PAS.    |
//|                                                                  |
//|  Lit le même plan.csv que PlanExecutor (M5), cherche les signaux  |
//|  d'entrée en M1 avec trois filtres anti-bruit, et les compare au  |
//|  signal M5 de la même zone, calculé avec les mêmes règles.        |
//|  Chaque signal devient un trade virtuel suivi jusqu'au stop ou à  |
//|  l'objectif, puis tout est écrit dans m1.csv (branche m1).        |
//|                                                                  |
//|  Signal M1 de vente sur rebond (achat : symétrique) :            |
//|   1. le prix est entré dans la zone et une bougie M1 y a laissé  |
//|      une mèche de rejet (mèche haute >= WickMinRatio de la bougie)|
//|   2. une bougie M1 clôture sous le plus bas des StructBars bougies|
//|      d'avant le sommet (plafonné à ConfirmMaxATR × ATR D1)       |
//|   3. la bougie M5 en cours va déjà dans le sens du trade          |
//|   4. le spread ne dépasse pas SpreadMaxPct % de la bougie signal  |
//|  Puis, comme l'EA M5 : stop au-delà du sommet (au moins           |
//|  MinStopATR × ATR D1, jamais au-delà du SL du plan), ratio >=     |
//|  MinRR, horaires d'entrée, une seule entrée par marché et par    |
//|  jour, zones retirées par le contrôle de 10h15 abandonnées.       |
//|                                                                  |
//|  Trade virtuel (même gestion simple pour M1 et M5) : stop touché |
//|  avant l'objectif 1 = -1 R ; objectif 1 puis retour au prix       |
//|  d'entrée = 0 R ; objectif final = + ratio R ; vendredi à         |
//|  FridayCloseHour ou après MaxDays jours : clôture au cours.       |
//+------------------------------------------------------------------+
#property copyright "Plan de trading du jour"
#property version   "1.00"

input group "Envoi des données vers GitHub"
input string GitHubToken        = "";    // Jeton GitHub (le même que l'EA du démo)
input string GitHubRepo         = "kidimig/trading-plan"; // Dépôt GitHub
input string DataBranch         = "m1";  // Branche où écrire m1.csv
input int    PushMinutes        = 15;    // Envoi des données toutes les X minutes

input group "Plan"
input string PlanURL            = "https://raw.githubusercontent.com/kidimig/trading-plan/main/plan.csv"; // Plan du jour
input int    PollMinutes        = 5;     // Relecture du plan (minutes)
input int    CayenneUtcOffset   = -3;    // Décalage horaire de Cayenne par rapport à UTC
input int    EntryStartHour     = 3;     // Signaux comptés à partir de (heure Cayenne)
input int    EntryEndHour       = 16;    // Signaux comptés jusqu'à (heure Cayenne)
input int    FridayCloseHour    = 16;    // Vendredi : trades virtuels clôturés à (heure Cayenne)
input bool   BreakoutZones      = true;  // Observer aussi les lignes CASSURE du plan

input group "Mêmes règles que l'EA M5"
input double MinRR              = 1.5;   // Ratio gain/risque minimum au signal
input double MinStopATR         = 0.7;   // Stop minimum en fraction de l'ATR D1
input double ConfirmMaxATR      = 0.25;  // Preuve au plus à cette fraction de l'ATR D1 du sommet

input group "Filtres anti-bruit du M1"
input int    StructBars         = 5;     // Niveau de preuve : plus bas (vente) ou plus haut (achat) des N bougies M1 avant le sommet
input double WickMinRatio       = 0.5;   // Mèche de rejet dans la zone : au moins cette part de la bougie (0 = sans)
input bool   RequireM5Dir       = true;  // La bougie M5 en cours doit aller dans le sens du trade
input double SpreadMaxPct       = 20;    // Spread maximum en % de la hauteur de la bougie de signal (0 = sans)

input group "Suivi des trades virtuels"
input int    MaxDays            = 5;     // Trade virtuel encore ouvert : clôturé au bout de N jours
input int    KeepDays           = 21;    // Signaux gardés dans m1.csv (jours)

const string EA_VERSION = "M1-1.00";
const string SIG_FILE   = "PlanExecutorM1_signaux.csv";

//--- État d'une zone pour une unité de temps (M1 ou M5)
struct TfState
  {
   bool              touched;
   double            extreme;
   datetime          extremeTime;
   double            structLevel;
   datetime          lastBar;
   bool              done;
   bool              wick;         // M1 : mèche de rejet vue dans la zone
   string            status;
   int               nWick, nDir, nSpread, nRatio, nHours; // signaux écartés
  };

struct MZone
  {
   string            sym;
   int               dir;          // 1 achat, -1 vente
   double            zlo, zhi, slDay, tp, tp1;
   bool              cassure;
   TfState           m1;
   TfState           m5;
  };

//--- Trade virtuel
struct Sig
  {
   string            date;         // date du plan
   string            zkey;
   string            sym;
   int               dir;
   bool              cassure;
   string            tf;           // "M1" ou "M5"
   datetime          t;            // clôture de la bougie de signal (heure serveur)
   double            price, sl, tp, tp1, rr, spread;
   int               state;        // 0 ouvert, 1 stop, 2 objectif 1 puis entrée, 3 objectif, 4 clôturé au cours
   bool              tp1Hit;
   double            mfe, mae;     // gain et recul maximum, en fois le risque
   datetime          tEnd;
   double            resR;
   datetime          lastBar;
  };

MZone    zones[];
Sig      sigs[];
string   planDate   = "";
string   lastError  = "";
string   pushStatus = "";
datetime lastPoll   = 0;
datetime lastPush   = 0;
bool     pushNeeded = false;
bool     sigDirty   = false;

//+------------------------------------------------------------------+
//| Heures                                                           |
//+------------------------------------------------------------------+
datetime CayenneNow() { return TimeGMT() + CayenneUtcOffset * 3600; }

long SrvOffset()   // décalage heure serveur - UTC, arrondi à l'heure
  {
   long d = (long)(TimeTradeServer() - TimeGMT());
   return (long)MathRound(d / 3600.0) * 3600;
  }

datetime CayOf(datetime srv) { return (datetime)(srv - SrvOffset() + CayenneUtcOffset * 3600); }

string TodayCayenne()
  {
   string d = TimeToString(CayenneNow(), TIME_DATE);
   StringReplace(d, ".", "-");
   return d;
  }

bool PlanIsToday() { return planDate != "" && planDate == TodayCayenne(); }

bool InEntryHours(datetime cay)
  {
   MqlDateTime t;
   TimeToStruct(cay, t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return false;
   if(t.day_of_week == 5 && t.hour >= FridayCloseHour)
      return false;
   return t.hour >= EntryStartHour && t.hour < EntryEndHour;
  }

string D(double v, int dg) { return DoubleToString(v, dg); }
int    SymDigits(string sym) { return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); }
string TfStr(ENUM_TIMEFRAMES tf) { return tf == PERIOD_M1 ? "M1" : "M5"; }

string Clean(string s)
  {
   StringReplace(s, ";", ",");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\r", " ");
   return s;
  }

string HM(datetime cay) { return TimeToString(cay, TIME_DATE | TIME_MINUTES); }

//+------------------------------------------------------------------+
int OnInit()
  {
   LoadSignals();
   EventSetTimer(10);
   PollPlan();
   UpdateComment();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(sigDirty)
      SaveSignals();
   Comment("");
  }

void OnTimer()
  {
   if(TimeLocal() - lastPoll >= PollMinutes * 60)
      PollPlan();

   if(PlanIsToday())
     {
      for(int i = 0; i < ArraySize(zones); i++)
        {
         if(ProcessTF(zones[i], zones[i].m1, PERIOD_M1))
            CancelOthers(i, true);
         if(ProcessTF(zones[i], zones[i].m5, PERIOD_M5))
            CancelOthers(i, false);
        }
     }
   UpdateSignals();

   if(sigDirty)
     {
      SaveSignals();
      sigDirty   = false;
      pushNeeded = true;
     }
   if(GitHubToken != "")
     {
      MqlDateTime t;
      TimeToStruct(CayenneNow(), t);
      int every = (t.day_of_week == 0 || t.day_of_week == 6) ? 360 : PushMinutes;
      long since = (long)(TimeLocal() - lastPush);
      if(since >= every * 60 || (pushNeeded && since >= 120))
         PushData();
     }
   UpdateComment();
  }

//+------------------------------------------------------------------+
//| Plan                                                             |
//+------------------------------------------------------------------+
void PollPlan()
  {
   lastPoll = TimeLocal();
   char   post[], result[];
   string headers;
   string url = PlanURL + "?t=" + IntegerToString((long)TimeGMT());
   string req = (GitHubToken != "") ? "Authorization: token " + GitHubToken + "\r\n" : "";
   ResetLastError();
   int code = WebRequest("GET", url, req, 10000, post, result, headers);
   if(code == -1)
     {
      lastError = "WebRequest refusé (erreur " + IntegerToString(GetLastError()) +
                  ") : ajoute https://raw.githubusercontent.com dans Outils > Options > Expert Advisors";
      return;
     }
   if(code != 200)
     {
      lastError = "Plan introuvable (HTTP " + IntegerToString(code) + ")";
      return;
     }
   lastError = "";
   ParsePlan(CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
  }

string ZoneKey(const MZone &z)
  {
   int dg = SymDigits(z.sym);
   return z.sym + "|" + IntegerToString(z.dir) + "|" + D(z.zlo, dg) + "|" + D(z.zhi, dg) + (z.cassure ? "|C" : "");
  }

void InitState(TfState &st, const string status)
  {
   st.touched     = false;
   st.extreme     = 0;
   st.extremeTime = 0;
   st.structLevel = 0;
   st.lastBar     = 0;
   st.done        = false;
   st.wick        = false;
   st.status      = status;
   st.nWick = 0; st.nDir = 0; st.nSpread = 0; st.nRatio = 0; st.nHours = 0;
  }

void ParsePlan(string text)
  {
   StringReplace(text, "\r", "");
   string lines[];
   int n = StringSplit(text, '\n', lines);
   string newDate = "";
   MZone  newZones[];

   for(int i = 0; i < n; i++)
     {
      string line = lines[i];
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         continue;
      string f[];
      int k = StringSplit(line, ';', f);
      if(k < 2)
         continue;
      if(f[0] == "#date")
        {
         newDate = f[1];
         continue;
        }
      if(StringGetCharacter(line, 0) == '#' || k < 7)
         continue;

      MZone z;
      z.sym   = f[0];
      z.dir   = (f[1] == "BUY") ? 1 : ((f[1] == "SELL") ? -1 : 0);
      z.zlo   = StringToDouble(f[2]);
      z.zhi   = StringToDouble(f[3]);
      z.slDay = StringToDouble(f[4]);
      z.tp    = StringToDouble(f[5]);
      z.tp1   = StringToDouble(f[6]);
      z.cassure = (k >= 8 && StringFind(f[7], "CASSURE") == 0);
      if(z.dir == 0 || z.zlo <= 0 || z.zhi <= 0 || z.slDay <= 0 || z.tp <= 0)
         continue;
      if(z.cassure && !BreakoutZones)
         continue;
      if(z.zlo > z.zhi)
        {
         double tmp = z.zlo;
         z.zlo = z.zhi;
         z.zhi = tmp;
        }
      if(!SymbolSelect(z.sym, true))
        {
         lastError = "Symbole inconnu dans le plan : " + z.sym;
         continue;
        }
      string st0 = z.cassure ? "CASSURE : en attente du niveau" : "en attente de la zone";
      InitState(z.m1, st0);
      InitState(z.m5, st0);
      z.m1.lastBar = iTime(z.sym, PERIOD_M1, 0);
      z.m5.lastBar = iTime(z.sym, PERIOD_M5, 0);
      int m = ArraySize(newZones);
      ArrayResize(newZones, m + 1);
      newZones[m] = z;
     }
   if(newDate == "")
      return;

   if(newDate == planDate)
     {
      // Même plan : mise à jour en cours de journée (contrôle de 10h15)
      for(int a = 0; a < ArraySize(zones); a++)
        {
         bool kept = false;
         for(int b = 0; b < ArraySize(newZones); b++)
            if(ZoneKey(zones[a]) == ZoneKey(newZones[b]))
               kept = true;
         if(!kept)
           {
            if(!zones[a].m1.done) { zones[a].m1.done = true; zones[a].m1.status = "retirée par le contrôle de 10h15"; }
            if(!zones[a].m5.done) { zones[a].m5.done = true; zones[a].m5.status = "retirée par le contrôle de 10h15"; }
           }
        }
      for(int b = 0; b < ArraySize(newZones); b++)
        {
         bool known = false;
         for(int a = 0; a < ArraySize(zones); a++)
            if(ZoneKey(zones[a]) == ZoneKey(newZones[b]))
               known = true;
         if(!known)
           {
            int m = ArraySize(zones);
            ArrayResize(zones, m + 1);
            zones[m] = newZones[b];
            MarkKnownSignals(m);
           }
        }
      return;
     }

   planDate = newDate;
   ArrayResize(zones, ArraySize(newZones));
   for(int b = 0; b < ArraySize(newZones); b++)
     {
      zones[b] = newZones[b];
      MarkKnownSignals(b);
     }
   pushNeeded = true;
  }

// Après un redémarrage : une zone qui a déjà son signal du jour ne le refait pas
void MarkKnownSignals(int i)
  {
   string key = ZoneKey(zones[i]);
   for(int s = 0; s < ArraySize(sigs); s++)
     {
      if(sigs[s].date != planDate)
         continue;
      bool sameMarket = (sigs[s].sym == zones[i].sym);
      if(sigs[s].zkey != key && !sameMarket)
         continue;
      string why = (sigs[s].zkey == key) ? "signal déjà noté" : "annulée : l'autre zone de ce marché a déjà son signal";
      if(sigs[s].tf == "M1")
        {
         zones[i].m1.done = true;
         zones[i].m1.status = why;
        }
      else
        {
         zones[i].m5.done = true;
         zones[i].m5.status = why;
        }
     }
  }

// Une seule entrée par marché et par jour (comme l'EA M5), séparément pour M1 et M5
void CancelOthers(int i, bool isM1)
  {
   for(int k = 0; k < ArraySize(zones); k++)
     {
      if(k == i || zones[k].sym != zones[i].sym)
         continue;
      if(isM1 && !zones[k].m1.done)
        {
         zones[k].m1.done = true;
         zones[k].m1.status = "annulée : l'autre zone de ce marché a eu son signal M1";
        }
      if(!isM1 && !zones[k].m5.done)
        {
         zones[k].m5.done = true;
         zones[k].m5.status = "annulée : l'autre zone de ce marché a eu son signal M5";
        }
     }
  }

//+------------------------------------------------------------------+
//| Outils de calcul (mêmes formules que l'EA M5)                    |
//+------------------------------------------------------------------+
double AtrBars(const MqlRates &r[], int period)
  {
   double s = 0;
   int n = 0;
   for(int i = 1; i <= period && i + 1 < ArraySize(r); i++)
     {
      double tr = MathMax(r[i].high - r[i].low,
                          MathMax(MathAbs(r[i].high - r[i + 1].close), MathAbs(r[i].low - r[i + 1].close)));
      s += tr;
      n++;
     }
   return n > 0 ? s / n : 0;
  }

double AtrD1(string sym)
  {
   MqlRates d[];
   ArraySetAsSeries(d, true);
   if(CopyRates(sym, PERIOD_D1, 0, 16, d) < 16)
      return 0;
   return AtrBars(d, 14);
  }

double CapStruct(string sym, int dir, double extreme, double level)
  {
   if(ConfirmMaxATR <= 0)
      return level;
   double cap = ConfirmMaxATR * AtrD1(sym);
   if(cap <= 0)
      return level;
   int dg = SymDigits(sym);
   if(dir == -1 && extreme - level > cap)
      return NormalizeDouble(extreme - cap, dg);
   if(dir == 1 && level - extreme > cap)
      return NormalizeDouble(extreme + cap, dg);
   return level;
  }

double LowestLow(const MqlRates &r[], int from, int to)
  {
   double v = r[from].low;
   for(int i = from + 1; i <= to && i < ArraySize(r); i++)
      v = MathMin(v, r[i].low);
   return v;
  }

double HighestHigh(const MqlRates &r[], int from, int to)
  {
   double v = r[from].high;
   for(int i = from + 1; i <= to && i < ArraySize(r); i++)
      v = MathMax(v, r[i].high);
   return v;
  }

// Mèche de rejet : mèche haute (vente) ou basse (achat) d'au moins WickMinRatio de la bougie
bool IsRejection(const MqlRates &b, int dir)
  {
   if(WickMinRatio <= 0)
      return true;
   double rng = b.high - b.low;
   if(rng <= 0)
      return false;
   double wick = (dir == -1) ? b.high - MathMax(b.open, b.close) : MathMin(b.open, b.close) - b.low;
   return wick / rng >= WickMinRatio;
  }

// La bougie M5 qui contient la bougie M1 de signal va-t-elle dans le sens du trade ?
bool M5Agrees(const MZone &z, const MqlRates &b)
  {
   int sh = iBarShift(z.sym, PERIOD_M5, b.time, false);
   if(sh < 0)
      return true;
   double o5 = iOpen(z.sym, PERIOD_M5, sh);
   if(o5 <= 0)
      return true;
   return (z.dir == -1) ? b.close < o5 : b.close > o5;
  }

//+------------------------------------------------------------------+
//| Recherche des signaux                                            |
//+------------------------------------------------------------------+
bool ProcessTF(const MZone &z, TfState &st, ENUM_TIMEFRAMES tf)
  {
   if(st.done)
      return false;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(z.sym, tf, 0, 40, r) < 20)
      return false;
   if(r[1].time <= st.lastBar)
      return false;                  // pas de nouvelle bougie clôturée
   st.lastBar = r[1].time;
   MqlRates b = r[1];
   int  dg   = SymDigits(z.sym);
   bool isM1 = (tf == PERIOD_M1);
   int  last = isM1 ? 1 + MathMax(1, StructBars) : 6;

   if(z.cassure)
     {
      double px = b.close;
      if(z.dir == -1)
        {
         if(b.high >= z.slDay)          { st.done = true; st.status = "CASSURE : invalidée (stop journalier touché)"; return false; }
         if(b.low <= z.tp && !st.touched) { st.done = true; st.status = "CASSURE : objectif atteint sans signal"; return false; }
         if(px >= z.zhi) { st.status = "CASSURE : attente d'une clôture " + TfStr(tf) + " sous " + D(z.zhi, dg); return false; }
         if(px < z.zlo)  { st.status = "CASSURE : prix trop loin sous " + D(z.zlo, dg); return false; }
         if(!st.touched)
           {
            st.touched     = true;
            st.extreme     = HighestHigh(r, 1, 6);
            st.extremeTime = b.time;
           }
        }
      else
        {
         if(b.low <= z.slDay)            { st.done = true; st.status = "CASSURE : invalidée (stop journalier touché)"; return false; }
         if(b.high >= z.tp && !st.touched) { st.done = true; st.status = "CASSURE : objectif atteint sans signal"; return false; }
         if(px <= z.zlo) { st.status = "CASSURE : attente d'une clôture " + TfStr(tf) + " au-dessus de " + D(z.zlo, dg); return false; }
         if(px > z.zhi)  { st.status = "CASSURE : prix trop loin au-dessus de " + D(z.zhi, dg); return false; }
         if(!st.touched)
           {
            st.touched     = true;
            st.extreme     = LowestLow(r, 1, 6);
            st.extremeTime = b.time;
           }
        }
      return TrySignal(z, st, tf, r);
     }

   if(z.dir == -1)
     {
      if(b.high >= z.slDay)            { st.done = true; st.status = "invalidée (stop journalier touché)"; return false; }
      if(b.low <= z.tp && !st.touched) { st.done = true; st.status = "objectif atteint sans signal"; return false; }
      if(b.high >= z.zlo)
        {
         if(!st.touched || b.high > st.extreme)
           {
            st.extreme     = b.high;
            st.extremeTime = b.time;
            st.structLevel = CapStruct(z.sym, -1, st.extreme, LowestLow(r, 2, last));
           }
         st.touched = true;
         if(isM1 && IsRejection(b, -1))
            st.wick = true;
         st.status = "dans la zone, attente d'une clôture " + TfStr(tf) + " sous " + D(st.structLevel, dg);
        }
      if(st.touched && b.time > st.extremeTime && b.close < st.structLevel)
         return TrySignal(z, st, tf, r);
     }
   else
     {
      if(b.low <= z.slDay)              { st.done = true; st.status = "invalidée (stop journalier touché)"; return false; }
      if(b.high >= z.tp && !st.touched) { st.done = true; st.status = "objectif atteint sans signal"; return false; }
      if(b.low <= z.zhi)
        {
         if(!st.touched || b.low < st.extreme)
           {
            st.extreme     = b.low;
            st.extremeTime = b.time;
            st.structLevel = CapStruct(z.sym, 1, st.extreme, HighestHigh(r, 2, last));
           }
         st.touched = true;
         if(isM1 && IsRejection(b, 1))
            st.wick = true;
         st.status = "dans la zone, attente d'une clôture " + TfStr(tf) + " au-dessus de " + D(st.structLevel, dg);
        }
      if(st.touched && b.time > st.extremeTime && b.close > st.structLevel)
         return TrySignal(z, st, tf, r);
     }
   return false;
  }

bool TrySignal(const MZone &z, TfState &st, ENUM_TIMEFRAMES tf, const MqlRates &r[])
  {
   MqlRates b   = r[1];
   bool   isM1  = (tf == PERIOD_M1);
   int    dg    = SymDigits(z.sym);
   datetime closeSrv = b.time + PeriodSeconds(tf);
   string pre   = z.cassure ? "CASSURE : " : "";

   if(!InEntryHours(CayOf(closeSrv)))
     {
      st.nHours++;
      st.status = pre + "signal " + TfStr(tf) + " hors des horaires d'entrée, zone gardée";
      return false;
     }
   double point  = SymbolInfoDouble(z.sym, SYMBOL_POINT);
   double spread = SymbolInfoDouble(z.sym, SYMBOL_ASK) - SymbolInfoDouble(z.sym, SYMBOL_BID);
   if(spread <= 0)
      spread = (double)SymbolInfoInteger(z.sym, SYMBOL_SPREAD) * point;

   if(isM1)
     {
      if(!z.cassure && WickMinRatio > 0 && !st.wick)
        {
         st.nWick++;
         st.status = "signal M1 écarté : pas de mèche de rejet dans la zone, zone gardée";
         return false;
        }
      if(RequireM5Dir && !M5Agrees(z, b))
        {
         st.nDir++;
         st.status = pre + "signal M1 écarté : la bougie M5 en cours va contre le trade, zone gardée";
         return false;
        }
      double rng = b.high - b.low;
      if(SpreadMaxPct > 0 && (rng <= 0 || spread > SpreadMaxPct / 100.0 * rng))
        {
         st.nSpread++;
         st.status = pre + StringFormat("signal M1 écarté : spread %s pour une bougie de %s, zone gardée", D(spread, dg), D(rng, dg));
         return false;
        }
     }

   // Entrée et stop calculés comme l'EA M5
   double price   = (z.dir == -1) ? b.close : b.close + spread;
   double buf     = MathMax(2 * spread, 0.15 * AtrBars(r, 14));
   double minDist = MinStopATR * AtrD1(z.sym);
   double sl;
   if(z.dir == -1)
     {
      sl = st.extreme + buf;
      if(sl - price < minDist)
         sl = price + minDist;
      if(sl >= z.slDay)
         sl = z.slDay;
     }
   else
     {
      sl = st.extreme - buf;
      if(price - sl < minDist)
         sl = price - minDist;
      if(sl <= z.slDay)
         sl = z.slDay;
     }
   double risk = MathAbs(price - sl);
   bool tpOk = (z.dir == -1) ? z.tp < price : z.tp > price;
   if(risk <= 0 || !tpOk || (z.dir == -1 ? sl <= price : sl >= price))
     {
      st.status = pre + "signal " + TfStr(tf) + " ignoré : stop ou objectif trop proche";
      return false;
     }
   double rr = MathAbs(z.tp - price) / risk;
   if(rr < MinRR)
     {
      st.nRatio++;
      st.status = pre + "signal " + TfStr(tf) + " écarté : ratio " + D(rr, 2) + " trop faible, zone gardée";
      return false;
     }

   AddSignal(z, TfStr(tf), closeSrv, NormalizeDouble(price, dg), NormalizeDouble(sl, dg), rr, spread);
   st.done   = true;
   st.status = pre + StringFormat("SIGNAL %s à %s, prix %s, SL %s, ratio %.2f", TfStr(tf),
                                  TimeToString(CayOf(closeSrv), TIME_MINUTES), D(price, dg), D(sl, dg), rr);
   return true;
  }

void AddSignal(const MZone &z, const string tf, datetime t, double price, double sl, double rr, double spread)
  {
   Sig s;
   s.date    = planDate;
   s.zkey    = ZoneKey(z);
   s.sym     = z.sym;
   s.dir     = z.dir;
   s.cassure = z.cassure;
   s.tf      = tf;
   s.t       = t;
   s.price   = price;
   s.sl      = sl;
   s.tp      = z.tp;
   s.tp1     = z.tp1;
   s.rr      = rr;
   s.spread  = spread;
   s.state   = 0;
   s.tp1Hit  = false;
   s.mfe     = 0;
   s.mae     = 0;
   s.tEnd    = 0;
   s.resR    = 0;
   s.lastBar = t - 60;               // la bougie M1 qui suit le signal sera la première suivie
   int m = ArraySize(sigs);
   ArrayResize(sigs, m + 1);
   sigs[m] = s;
   sigDirty = true;
   Print("Observation ", tf, " : signal ", z.sym, z.dir == -1 ? " vente" : " achat", " à ", D(price, SymDigits(z.sym)),
         ", SL ", D(sl, SymDigits(z.sym)), ", ratio ", D(rr, 2));
  }

//+------------------------------------------------------------------+
//| Suivi des trades virtuels sur les bougies M1                      |
//+------------------------------------------------------------------+
void CloseSig(Sig &s, int state, double r, datetime t)
  {
   s.state = state;
   s.resR  = r;
   s.tEnd  = t;
   sigDirty = true;
  }

void UpdateSignals()
  {
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      if(sigs[i].state != 0)
         continue;
      MqlRates r[];
      ArraySetAsSeries(r, false);
      datetime from = sigs[i].lastBar + 60;
      if(from > now)
         continue;
      int n = CopyRates(sigs[i].sym, PERIOD_M1, from, now, r);
      if(n <= 0)
         continue;
      double risk = MathAbs(sigs[i].price - sigs[i].sl);
      if(risk <= 0)
        {
         CloseSig(sigs[i], 4, 0, sigs[i].t);
         continue;
        }
      bool sell = (sigs[i].dir == -1);
      double sp = sigs[i].spread;   // les bougies sont en Bid : une vente sort à l'Ask
      for(int k = 0; k < n && sigs[i].state == 0; k++)
        {
         if(r[k].time + 60 > now)
            break;                   // bougie encore en cours
         if(r[k].time < sigs[i].t)
            continue;                // bougies d'avant le signal
         sigs[i].lastBar = r[k].time;
         double hi = r[k].high + (sell ? sp : 0);
         double lo = r[k].low  + (sell ? sp : 0);
         double fav = sell ? sigs[i].price - lo : hi - sigs[i].price;
         double adv = sell ? hi - sigs[i].price : sigs[i].price - lo;
         sigs[i].mfe = MathMax(sigs[i].mfe, fav / risk);
         sigs[i].mae = MathMax(sigs[i].mae, adv / risk);
         datetime tEnd = r[k].time + 60;

         // Vendredi soir ou trade trop long : clôture au cours
         MqlDateTime c;
         TimeToStruct(CayOf(tEnd), c);
         bool friday = (c.day_of_week == 5 && c.hour >= FridayCloseHour) || c.day_of_week == 6;
         if(friday || tEnd - sigs[i].t > MaxDays * 86400)
           {
            double ex = r[k].close + (sell ? sp : 0);
            CloseSig(sigs[i], 4, (sell ? sigs[i].price - ex : ex - sigs[i].price) / risk, tEnd);
            break;
           }
         if(!sigs[i].tp1Hit)
           {
            // Prudence : si une bougie touche le stop et l'objectif 1, on compte le stop
            if(sell ? hi >= sigs[i].sl : lo <= sigs[i].sl)
              {
               CloseSig(sigs[i], 1, -1, tEnd);
               break;
              }
            if(sell ? lo <= sigs[i].tp : hi >= sigs[i].tp)
              {
               sigs[i].tp1Hit = true;
               CloseSig(sigs[i], 3, sigs[i].rr, tEnd);
               break;
              }
            if(sigs[i].tp1 > 0 && (sell ? lo <= sigs[i].tp1 : hi >= sigs[i].tp1))
              {
               sigs[i].tp1Hit = true;
               sigDirty = true;
              }
           }
         else
           {
            // Après l'objectif 1, stop au prix d'entrée
            if(sell ? hi >= sigs[i].price : lo <= sigs[i].price)
              {
               CloseSig(sigs[i], 2, 0, tEnd);
               break;
              }
            if(sell ? lo <= sigs[i].tp : hi >= sigs[i].tp)
              {
               CloseSig(sigs[i], 3, sigs[i].rr, tEnd);
               break;
              }
           }
        }
     }
   // Ménage : signaux plus vieux que KeepDays
   datetime limit = now - KeepDays * 86400;
   int w = 0;
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      if(sigs[i].t < limit && sigs[i].state != 0)
        {
         sigDirty = true;
         continue;
        }
      if(w != i)
         sigs[w] = sigs[i];
      w++;
     }
   if(w != ArraySize(sigs))
      ArrayResize(sigs, w);
  }

//+------------------------------------------------------------------+
//| Mémoire des signaux (fichier MQL5\Files\PlanExecutorM1_signaux)  |
//+------------------------------------------------------------------+
void SaveSignals()
  {
   int h = FileOpen(SIG_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      lastError = "écriture impossible de " + SIG_FILE;
      return;
     }
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      Sig s = sigs[i];
      int dg = SymDigits(s.sym);
      string line = s.date + ";" + s.zkey + ";" + s.sym + ";" + IntegerToString(s.dir) + ";" + (s.cassure ? "1" : "0") + ";" +
                    s.tf + ";" + IntegerToString((long)s.t) + ";" + D(s.price, dg) + ";" + D(s.sl, dg) + ";" +
                    D(s.tp, dg) + ";" + D(s.tp1, dg) + ";" + D(s.rr, 4) + ";" + D(s.spread, dg + 1) + ";" +
                    IntegerToString(s.state) + ";" + (s.tp1Hit ? "1" : "0") + ";" + D(s.mfe, 4) + ";" + D(s.mae, 4) + ";" +
                    IntegerToString((long)s.tEnd) + ";" + D(s.resR, 4) + ";" + IntegerToString((long)s.lastBar);
      FileWriteString(h, line + "\n");
     }
   FileClose(h);
  }

void LoadSignals()
  {
   ArrayResize(sigs, 0);
   if(!FileIsExist(SIG_FILE))
      return;
   int h = FileOpen(SIG_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
      return;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      string f[];
      if(StringSplit(line, ';', f) < 20)
         continue;
      Sig s;
      s.date    = f[0];
      s.zkey    = f[1];
      s.sym     = f[2];
      s.dir     = (int)StringToInteger(f[3]);
      s.cassure = (f[4] == "1");
      s.tf      = f[5];
      s.t       = (datetime)StringToInteger(f[6]);
      s.price   = StringToDouble(f[7]);
      s.sl      = StringToDouble(f[8]);
      s.tp      = StringToDouble(f[9]);
      s.tp1     = StringToDouble(f[10]);
      s.rr      = StringToDouble(f[11]);
      s.spread  = StringToDouble(f[12]);
      s.state   = (int)StringToInteger(f[13]);
      s.tp1Hit  = (f[14] == "1");
      s.mfe     = StringToDouble(f[15]);
      s.mae     = StringToDouble(f[16]);
      s.tEnd    = (datetime)StringToInteger(f[17]);
      s.resR    = StringToDouble(f[18]);
      s.lastBar = (datetime)StringToInteger(f[19]);
      SymbolSelect(s.sym, true);
      int m = ArraySize(sigs);
      ArrayResize(sigs, m + 1);
      sigs[m] = s;
     }
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Fichier m1.csv envoyé sur GitHub                                  |
//+------------------------------------------------------------------+
string StateName(int st)
  {
   switch(st)
     {
      case 0: return "ouvert";
      case 1: return "stop";
      case 2: return "objectif 1 puis retour à l'entrée";
      case 3: return "objectif";
      case 4: return "clôturé au cours";
     }
   return "?";
  }

string SettingsStr()
  {
   return "ratio min " + D(MinRR, 2) + " / stop min " + D(MinStopATR, 2) + " ATR / preuve max " + D(ConfirmMaxATR, 2) + " ATR" +
          " / preuve M1 " + IntegerToString(StructBars) + " bougies / mèche " + (WickMinRatio > 0 ? D(WickMinRatio * 100, 0) + "%" : "non") +
          " / sens M5 " + (RequireM5Dir ? "oui" : "non") + " / spread max " + (SpreadMaxPct > 0 ? D(SpreadMaxPct, 0) + "%" : "non") +
          " / entrées " + IntegerToString(EntryStartHour) + "h-" + IntegerToString(EntryEndHour) + "h / vendredi " +
          IntegerToString(FridayCloseHour) + "h / cassures " + (BreakoutZones ? "oui" : "non");
  }

string Summary(const string tf)
  {
   int n = 0, win = 0, loss = 0, zero = 0, open = 0;
   double tot = 0;
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      if(sigs[i].tf != tf)
         continue;
      n++;
      if(sigs[i].state == 0)
        {
         open++;
         continue;
        }
      tot += sigs[i].resR;
      if(sigs[i].resR > 0.001)
         win++;
      else
         if(sigs[i].resR < -0.001)
            loss++;
         else
            zero++;
     }
   return "RESUME;" + tf + ";" + IntegerToString(n) + ";" + IntegerToString(win) + ";" + IntegerToString(loss) + ";" +
          IntegerToString(zero) + ";" + IntegerToString(open) + ";" + D(tot, 2) + "\n";
  }

string BuildCsv()
  {
   string s = "#generated_utc;" + TimeToString(TimeGMT(), TIME_DATE | TIME_MINUTES) + "\n";
   s += "EA;version=" + EA_VERSION + ";mode=observation (aucun trade);plan=" + planDate + ";erreur=" + Clean(lastError) +
        ";compte=" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ";reglages=" + Clean(SettingsStr()) + "\n";

   s += "#ZONE;symbole;sens;type;zone_bas;zone_haut;sl_jour;tp;tp1;etat_M1;etat_M5;M1_ecartes\n";
   for(int i = 0; i < ArraySize(zones); i++)
     {
      int dg = SymDigits(zones[i].sym);
      TfState a = zones[i].m1;
      s += "ZONE;" + zones[i].sym + ";" + (zones[i].dir == 1 ? "BUY" : "SELL") + ";" + (zones[i].cassure ? "cassure" : "rebond") + ";" +
           D(zones[i].zlo, dg) + ";" + D(zones[i].zhi, dg) + ";" + D(zones[i].slDay, dg) + ";" + D(zones[i].tp, dg) + ";" +
           D(zones[i].tp1, dg) + ";" + Clean(zones[i].m1.status) + ";" + Clean(zones[i].m5.status) + ";" +
           StringFormat("mèche %d / sens M5 %d / spread %d / ratio %d / horaires %d", a.nWick, a.nDir, a.nSpread, a.nRatio, a.nHours) + "\n";
     }

   s += "#SIG;date;symbole;sens;type;tf;heure_cayenne;prix;sl;tp;tp1;ratio;spread;etat;resultat_R;gain_max_R;recul_max_R;fin_cayenne\n";
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      Sig g = sigs[i];
      int dg = SymDigits(g.sym);
      s += "SIG;" + g.date + ";" + g.sym + ";" + (g.dir == 1 ? "BUY" : "SELL") + ";" + (g.cassure ? "cassure" : "rebond") + ";" +
           g.tf + ";" + HM(CayOf(g.t)) + ";" + D(g.price, dg) + ";" + D(g.sl, dg) + ";" + D(g.tp, dg) + ";" + D(g.tp1, dg) + ";" +
           D(g.rr, 2) + ";" + D(g.spread, dg) + ";" + StateName(g.state) + (g.state == 0 && g.tp1Hit ? " (objectif 1 atteint)" : "") + ";" +
           (g.state == 0 ? "" : D(g.resR, 2)) + ";" + D(g.mfe, 2) + ";" + D(g.mae, 2) + ";" + (g.tEnd > 0 ? HM(CayOf(g.tEnd)) : "") + "\n";
     }
   s += "#RESUME;tf;signaux;gagnants;perdants;a_zero;ouverts;total_R\n";
   s += Summary("M1");
   s += Summary("M5");
   return s;
  }

string Base64(const string text)
  {
   uchar src[], dst[], key[];
   int n = StringToCharArray(text, src, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(src, n - 1);
   if(CryptEncode(CRYPT_BASE64, src, key, dst) <= 0)
      return "";
   return CharArrayToString(dst);
  }

string JsonStr(const string s, const string key)
  {
   int p = StringFind(s, "\"" + key + "\"");
   if(p < 0)
      return "";
   p = StringFind(s, ":", p);
   if(p < 0)
      return "";
   int a = StringFind(s, "\"", p + 1);
   if(a < 0)
      return "";
   int b = StringFind(s, "\"", a + 1);
   if(b < 0)
      return "";
   return StringSubstr(s, a + 1, b - a - 1);
  }

int Gh(const string method, const string path, const string body, string &resp)
  {
   char data[], result[];
   string rh;
   string headers = "Authorization: Bearer " + GitHubToken + "\r\n" +
                    "Accept: application/vnd.github+json\r\n" +
                    "X-GitHub-Api-Version: 2022-11-28\r\n" +
                    "User-Agent: PlanExecutorM1-MT5\r\n" +
                    "Content-Type: application/json\r\n";
   if(body != "")
     {
      int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(n > 0)
         ArrayResize(data, n - 1);
     }
   ResetLastError();
   int code = WebRequest(method, "https://api.github.com/repos/" + GitHubRepo + path, headers, 30000, data, result, rh);
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         pushStatus = "envoi bloqué : ajoute https://api.github.com dans Outils > Options > Expert Advisors > WebRequest";
      else
         pushStatus = "envoi impossible (erreur WebRequest " + IntegerToString(err) + ")";
     }
   return code;
  }

string GhError(const string step, int code, const string resp)
  {
   if(code == -1)
      return pushStatus;
   if(code == 401)
      return "jeton GitHub refusé (mal copié ou expiré)";
   if(code == 403 || code == 404)
      return "le jeton n'a pas le droit d'écrire dans " + GitHubRepo + " (Contents : Read and write) — étape " + step;
   string m = JsonStr(resp, "message");
   return "GitHub a refusé l'étape " + step + " (HTTP " + IntegerToString(code) + (m != "" ? " : " + m : "") + ")";
  }

void PushData()
  {
   lastPush   = TimeLocal();
   pushNeeded = false;
   string b64 = Base64(BuildCsv());
   if(b64 == "")
     {
      pushStatus = "échec de l'encodage des données";
      return;
     }
   string resp, msg = "Observation M1 " + TimeToString(TimeGMT(), TIME_DATE | TIME_MINUTES) + " UTC";

   int code = Gh("GET", "/git/ref/heads/" + DataBranch, "", resp);
   string parent = "";
   if(code == 200)
      parent = JsonStr(resp, "sha");
   else
      if(code != 404)
        {
         pushStatus = GhError("lecture de la branche", code, resp);
         return;
        }
   code = Gh("POST", "/git/blobs", "{\"content\":\"" + b64 + "\",\"encoding\":\"base64\"}", resp);
   if(code != 201)
     {
      pushStatus = GhError("fichier", code, resp);
      return;
     }
   string blob = JsonStr(resp, "sha");
   code = Gh("POST", "/git/trees", "{\"tree\":[{\"path\":\"m1.csv\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"" + blob + "\"}]}", resp);
   if(code != 201)
     {
      pushStatus = GhError("arborescence", code, resp);
      return;
     }
   string tree = JsonStr(resp, "sha");
   string parents = (parent != "") ? "[\"" + parent + "\"]" : "[]";
   code = Gh("POST", "/git/commits", "{\"message\":\"" + msg + "\",\"tree\":\"" + tree + "\",\"parents\":" + parents + "}", resp);
   if(code != 201)
     {
      pushStatus = GhError("commit", code, resp);
      return;
     }
   string commit = JsonStr(resp, "sha");
   if(parent == "")
      code = Gh("POST", "/git/refs", "{\"ref\":\"refs/heads/" + DataBranch + "\",\"sha\":\"" + commit + "\"}", resp);
   else
      code = Gh("POST", "/merges", "{\"base\":\"" + DataBranch + "\",\"head\":\"" + commit + "\",\"commit_message\":\"" + msg + "\"}", resp);
   if(code != 201 && code != 204)
     {
      pushStatus = GhError("branche", code, resp);
      return;
     }
   pushStatus = "données envoyées à " + TimeToString(CayenneNow(), TIME_MINUTES) + " (heure de Cayenne)";
  }

//+------------------------------------------------------------------+
//| Affichage sur le graphique                                       |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   int open = 0, m1 = 0, m5 = 0;
   for(int i = 0; i < ArraySize(sigs); i++)
     {
      if(sigs[i].state == 0)
         open++;
      if(sigs[i].tf == "M1")
         m1++;
      else
         m5++;
     }
   string c = "PlanExecutorM1 " + EA_VERSION + " — OBSERVATION, aucun trade\n" +
              "Plan : " + (planDate == "" ? "pas encore lu" : planDate) + (lastError != "" ? " — " + lastError : "") + "\n" +
              "Signaux gardés : M1 " + IntegerToString(m1) + ", M5 " + IntegerToString(m5) + ", trades virtuels ouverts " + IntegerToString(open) + "\n" +
              "Envoi : " + (GitHubToken == "" ? "pas de jeton GitHub" : (pushStatus == "" ? "en attente" : pushStatus));
   Comment(c);
  }
//+------------------------------------------------------------------+
