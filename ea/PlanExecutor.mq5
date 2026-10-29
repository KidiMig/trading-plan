//+------------------------------------------------------------------+
//|                                              PlanExecutor.mq5    |
//|  Exécute le « Plan de trading du jour » publié chaque matin      |
//|  sur GitHub : zones journalières + confirmation SMC en M15.       |
//|                                                                  |
//|  Format attendu du fichier plan.csv (séparateur ;) :             |
//|    #date;2026-10-12                 date du plan (heure Cayenne)  |
//|    #news;2026-10-14 09:30           annonce, heure de Cayenne     |
//|    SYMBOLE;SENS;ZONE_BAS;ZONE_HAUT;SL_JOUR;TP;TP1                 |
//|    GOLD#;SELL;4205;4219;4255;4115;4150                            |
//|                                                                  |
//|  À autoriser dans Outils > Options > Expert Advisors > WebRequest |
//|    https://raw.githubusercontent.com                             |
//|    https://api.github.com          (envoi des données XM)        |
//|                                                                  |
//|  v1.10 : envoie toutes les 15 min les cours XM, le compte, les   |
//|  positions et les trades dans xm.csv (branche « live » du dépôt). |
//+------------------------------------------------------------------+
#property copyright "Plan de trading du jour"
#property version   "1.43"

#include <Trade\Trade.mqh>

//--- Mode d'entrée dans la zone
enum ENUM_ENTRY_MODE
  {
   ENTRY_M15    = 0,   // Confirmation M15 (cassure d'une bougie 15 min)
   ENTRY_M5     = 1,   // Confirmation M5 (cassure d'une bougie 5 min)
   ENTRY_DIRECT = 2    // Entrée directe dès que le prix touche la zone
  };

//--- Réglages
input group "Envoi des données XM vers GitHub"
input string GitHubToken        = "";    // Jeton GitHub (fine-grained, Contents : Read and write)
input string GitHubRepo         = "kidimig/trading-plan"; // Dépôt GitHub
input string DataBranch         = "live";  // Branche où écrire xm.csv
input int    PushMinutes        = 15;    // Envoi des données toutes les X minutes
input string DataSymbols        = "GOLD#,SILVER#,BRENTCash#,OILCash#,NGASCash#,US500Cash#,US100Cash#,EURUSD#,GBPUSD#,USDJPY#"; // Symboles envoyés

input group "Plan et gestion du risque"
input ENUM_ENTRY_MODE EntryMode = ENTRY_M5; // Mode d'entrée dans la zone
input string PlanURL            = "https://raw.githubusercontent.com/kidimig/trading-plan/main/plan.csv"; // Adresse du plan
input double RiskPercent        = 1.0;   // Risque par trade (% du solde)
input int    MaxPositions       = 2;     // Positions ouvertes maximum en même temps
input int    MaxLossesPerDay    = 2;     // Arrêt pour la journée après N pertes
input double MinRR              = 1.5;   // Ratio gain/risque minimum à l'entrée
input double MinStopATR         = 0.3;   // Stop minimum en fraction du mouvement moyen d'une journée (ATR D1)
input double MinGainMoney       = 50;    // Gain minimum visé au TP (devise du compte), 0 = pas de minimum
input double LockTriggerMoney   = 70;    // Verrouiller un gain à partir de (devise du compte), 0 = désactivé
input double LockKeepMoney      = 50;    // Gain verrouillé (le SL garantit au moins ce gain)
input bool   Paused             = false; // Pause : aucune nouvelle entrée
input bool   AllowRealAccount   = false; // Autoriser le trading sur un compte réel
input int    PollMinutes        = 5;     // Relecture du plan (minutes)
input int    EntryStartHour     = 3;     // Entrées autorisées à partir de (heure Cayenne)
input int    EntryEndHour       = 16;    // Entrées autorisées jusqu'à (heure Cayenne)
input int    FridayCloseHour    = 16;    // Vendredi : tout fermer à (heure Cayenne)
input int    NewsMinutes        = 30;    // Pas d'entrée X min avant/après une annonce
input int    CayenneUtcOffset   = -3;    // Décalage horaire de Cayenne par rapport à UTC
input long   Magic              = 20261012; // Numéro magique de l'EA

input group "Suivi des positions ouvertes"
input bool   TrailEnabled       = true;  // Sortie quand l'élan s'essouffle (SL qui suit les creux/sommets H1)
input double TrailStartR        = 0.5;   // Activer quand le gain atteint X fois le risque
input int    TrailBarsH1        = 2;     // SL derrière le plus bas/haut des N dernières bougies H1
input bool   ActionsEnabled     = true;  // Exécuter les ordres de Claude (actions.csv)
input string ActionsURL         = "https://raw.githubusercontent.com/kidimig/trading-plan/main/actions.csv"; // Adresse des ordres de Claude

input group "Réveil de Claude (routine déclenchée par API)"
input bool   RoutineEnabled     = true;  // Réveiller Claude quand il se passe quelque chose sur un trade
input string RoutineURL         = "";    // Adresse de la routine (…/routines/trig_…/fire)
input string RoutineToken       = "";    // Jeton de la routine (sk-ant-oat01-…)
input int    RoutineMinMinutes  = 10;    // Délai minimum entre deux réveils (minutes)
input int    RoutineMaxPerDay   = 15;    // Réveils maximum par jour
input bool   RoutineTest        = false; // Envoyer un réveil de test au démarrage (remettre à false ensuite)

//--- Une zone du plan
struct Zone
  {
   string            sym;
   int               dir;          // 1 = achat, -1 = vente
   double            zlo, zhi;     // zone d'entrée
   double            slDay;        // stop journalier (invalidation)
   double            tp, tp1;
   bool              touched;
   double            extreme;      // plus haut (vente) / plus bas (achat) depuis l'entrée en zone
   datetime          extremeTime;
   double            structLevel;  // niveau dont la cassure M15 confirme le retournement
   datetime          lastBar;      // dernière bougie M15 traitée
   bool              done;
   string            status;
  };

Zone     zones[];
string   planDate   = "";
datetime newsTimes[];
datetime lastPoll   = 0;
string   lastError  = "";
CTrade   trade;
datetime lastPush   = 0;
bool     pushNeeded = false;
string   pushStatus = "";
string   actionStatus = "";
string   routineStatus = "";
string   pendingFire   = "";
datetime lastFire      = 0;
int      firesToday    = 0;
string   fireDay       = "";

//+------------------------------------------------------------------+
datetime CayenneNow() { return TimeGMT() + CayenneUtcOffset * 3600; }

// Unité de temps utilisée pour la confirmation (M5 aussi pour l'entrée directe : sert à l'ATR)
ENUM_TIMEFRAMES EntryTF() { return (EntryMode == ENTRY_M15) ? PERIOD_M15 : PERIOD_M5; }

string EntryModeName()
  {
   if(EntryMode == ENTRY_M15)
      return "confirmation M15";
   if(EntryMode == ENTRY_M5)
      return "confirmation M5";
   return "entrée directe";
  }

string TfName() { return (EntryMode == ENTRY_M15) ? "M15" : "M5"; }

string TodayCayenne()
  {
   string d = TimeToString(CayenneNow(), TIME_DATE); // AAAA.MM.JJ
   StringReplace(d, ".", "-");
   return d;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(30);
   EventSetTimer(60);
   PollPlan();
   if(RoutineTest)
      QueueFire("Test de connexion envoyé par l'EA au démarrage. Vérifie juste que tu lis bien xm.csv, puis réponds « Réveil OK » en une ligne avec le solde du compte.");
   UpdateComment();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(TimeLocal() - lastPoll >= PollMinutes * 60)
     {
      PollPlan();
      PollActions();
     }

   ManagePositions();
   CheckEvents();
   SendPendingFire();

   if(PlanIsToday())
     {
      for(int i = 0; i < ArraySize(zones); i++)
         ProcessZone(zones[i]);
     }

   if(GitHubToken != "")
     {
      MqlDateTime t;
      TimeToStruct(CayenneNow(), t);
      int every = (t.day_of_week == 0 || t.day_of_week == 6) ? 360 : PushMinutes; // week-end : toutes les 6 h
      long since = (long)(TimeLocal() - lastPush);
      if(since >= every * 60 || (pushNeeded && since >= 60))
         PushData();
     }
   else
      pushStatus = "envoi des données désactivé (pas de jeton GitHub)";

   UpdateComment();
  }

// Un trade vient d'être exécuté (EA ou manuel) : on renvoie les données au prochain passage
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      pushNeeded = true;
  }

//+------------------------------------------------------------------+
//| Téléchargement et lecture du plan                                |
//+------------------------------------------------------------------+
void PollPlan()
  {
   lastPoll = TimeLocal();
   char   post[], result[];
   string headers;
   string url = PlanURL + "?t=" + IntegerToString((long)TimeGMT()); // contourne le cache
   string req = (GitHubToken != "") ? "Authorization: token " + GitHubToken + "\r\n" : ""; // permet un dépôt privé
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

void ParsePlan(string text)
  {
   StringReplace(text, "\r", "");
   string lines[];
   int n = StringSplit(text, '\n', lines);

   string newDate = "";
   datetime news[];
   Zone newZones[];

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
      if(f[0] == "#news")
        {
         string t = f[1];
         StringReplace(t, "-", ".");
         int m = ArraySize(news);
         ArrayResize(news, m + 1);
         news[m] = StringToTime(t);
         continue;
        }
      if(StringGetCharacter(line, 0) == '#' || k < 7)
         continue;

      Zone z;
      z.sym   = f[0];
      z.dir   = (f[1] == "BUY") ? 1 : ((f[1] == "SELL") ? -1 : 0);
      z.zlo   = StringToDouble(f[2]);
      z.zhi   = StringToDouble(f[3]);
      z.slDay = StringToDouble(f[4]);
      z.tp    = StringToDouble(f[5]);
      z.tp1   = StringToDouble(f[6]);
      if(z.dir == 0 || z.zlo <= 0 || z.zhi <= 0 || z.slDay <= 0 || z.tp <= 0)
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
      z.touched     = false;
      z.extreme     = 0;
      z.extremeTime = 0;
      z.structLevel = 0;
      z.lastBar     = iTime(z.sym, EntryTF(), 0);
      z.done        = false;
      z.status      = "en attente de la zone";
      int m = ArraySize(newZones);
      ArrayResize(newZones, m + 1);
      newZones[m] = z;
     }

   if(newDate == "")
     {
      lastError = "Plan sans ligne #date";
      return;
     }
   // Même date : mise à jour en cours de journée (contrôle de 10h15).
   // Les zones inchangées gardent leur état, les zones retirées sont annulées, les nouvelles ajoutées.
   if(newDate == planDate)
     {
      for(int a = 0; a < ArraySize(zones); a++)
        {
         bool kept = false;
         for(int b = 0; b < ArraySize(newZones); b++)
            if(ZoneKey(zones[a]) == ZoneKey(newZones[b]))
               kept = true;
         if(!kept && !zones[a].done)
           {
            zones[a].done   = true;
            zones[a].status = "retirée par le contrôle de 10h15";
            Print(zones[a].sym, " : zone retirée du plan");
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
            Print(newZones[b].sym, " : nouvelle zone ajoutée au plan");
           }
        }
      int nn2 = ArraySize(news);
      ArrayResize(newsTimes, nn2);
      for(int j = 0; j < nn2; j++)
         newsTimes[j] = news[j];
      return;
     }

   planDate = newDate;
   int nz = ArraySize(newZones);
   ArrayResize(zones, nz);
   for(int j = 0; j < nz; j++)
      zones[j] = newZones[j];
   int nn = ArraySize(news);
   ArrayResize(newsTimes, nn);
   for(int j = 0; j < nn; j++)
      newsTimes[j] = news[j];
   Print("Nouveau plan du ", planDate, " : ", ArraySize(zones), " zone(s)");
  }

bool PlanIsToday() { return planDate != "" && planDate == TodayCayenne(); }

string ZoneKey(const Zone &z)
  {
   return z.sym + "|" + IntegerToString(z.dir) + "|" + DoubleToString(z.zlo, 5) + "|" + DoubleToString(z.zhi, 5) + "|" +
          DoubleToString(z.slDay, 5) + "|" + DoubleToString(z.tp, 5);
  }

//+------------------------------------------------------------------+
//| Logique d'une zone : entrée en zone puis cassure M15             |
//+------------------------------------------------------------------+
void ProcessZone(Zone &z)
  {
   if(z.done)
      return;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(z.sym, EntryTF(), 0, 30, r) < 20)
      return;

   // Entrée directe : on regarde le prix à chaque passage (toutes les minutes), sans attendre de cassure
   if(EntryMode == ENTRY_DIRECT)
     {
      double bid = SymbolInfoDouble(z.sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(z.sym, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         return;
      if(z.dir == -1)
        {
         if(ask >= z.slDay) { z.done = true; z.status = "invalidée (stop journalier touché)"; return; }
         if(bid <= z.tp && !z.touched) { z.done = true; z.status = "objectif atteint sans entrée"; return; }
         if(bid >= z.zlo && bid <= z.zhi)
           {
            z.touched = true;
            z.extreme = bid;
            TryEnter(z, r);
           }
         else
            if(z.touched && !z.done)
               z.status = "zone quittée, attente d'un retour dans la zone";
        }
      else
        {
         if(bid <= z.slDay) { z.done = true; z.status = "invalidée (stop journalier touché)"; return; }
         if(bid >= z.tp && !z.touched) { z.done = true; z.status = "objectif atteint sans entrée"; return; }
         if(ask >= z.zlo && ask <= z.zhi)
           {
            z.touched = true;
            z.extreme = ask;
            TryEnter(z, r);
           }
         else
            if(z.touched && !z.done)
               z.status = "zone quittée, attente d'un retour dans la zone";
        }
      return;
     }

   if(r[1].time <= z.lastBar)
      return;                       // pas de nouvelle bougie clôturée
   z.lastBar = r[1].time;
   MqlRates b = r[1];

   if(z.dir == -1)
     {
      if(b.high >= z.slDay)  { z.done = true; z.status = "invalidée (stop journalier touché)"; return; }
      if(b.low  <= z.tp && !z.touched) { z.done = true; z.status = "objectif atteint sans entrée"; return; }
      if(b.high >= z.zlo)
        {
         if(!z.touched || b.high > z.extreme)
           {
            z.extreme     = b.high;
            z.extremeTime = b.time;
            z.structLevel = LowestLow(r, 2, 6);
           }
         z.touched = true;
         z.status  = "dans la zone, attente de cassure " + TfName() + " sous " + DoubleToString(z.structLevel, SymDigits(z.sym));
        }
      if(z.touched && b.time > z.extremeTime && b.close < z.structLevel)
         TryEnter(z, r);
     }
   else
     {
      if(b.low  <= z.slDay)  { z.done = true; z.status = "invalidée (stop journalier touché)"; return; }
      if(b.high >= z.tp && !z.touched) { z.done = true; z.status = "objectif atteint sans entrée"; return; }
      if(b.low <= z.zhi)
        {
         if(!z.touched || b.low < z.extreme)
           {
            z.extreme     = b.low;
            z.extremeTime = b.time;
            z.structLevel = HighestHigh(r, 2, 6);
           }
         z.touched = true;
         z.status  = "dans la zone, attente de cassure " + TfName() + " au-dessus de " + DoubleToString(z.structLevel, SymDigits(z.sym));
        }
      if(z.touched && b.time > z.extremeTime && b.close > z.structLevel)
         TryEnter(z, r);
     }
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

double AtrM15(const MqlRates &r[], int period)
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

int SymDigits(string sym) { return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); }

//+------------------------------------------------------------------+
//| Contrôles avant entrée                                           |
//+------------------------------------------------------------------+
string BlockReason()
  {
   if(Paused)
      return "EA en pause";
   if(!AllowRealAccount && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
      return "compte réel non autorisé";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "trading algorithmique désactivé dans MT5";
   MqlDateTime t;
   TimeToStruct(CayenneNow(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return "week-end";
   if(t.day_of_week == 5 && t.hour >= FridayCloseHour)
      return "vendredi soir";
   if(t.hour < EntryStartHour || t.hour >= EntryEndHour)
      return "hors horaires d'entrée";
   datetime now = CayenneNow();
   for(int i = 0; i < ArraySize(newsTimes); i++)
      if(MathAbs((double)(now - newsTimes[i])) <= NewsMinutes * 60)
         return "annonce économique proche";
   if(CountPositions("") >= MaxPositions)
      return "nombre maximum de positions atteint";
   if(LossesToday() >= MaxLossesPerDay)
      return "limite de pertes du jour atteinte";
   return "";
  }

int CountPositions(string sym)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(sym == "" || PositionGetString(POSITION_SYMBOL) == sym)
         c++;
     }
   return c;
  }

int LossesToday()
  {
   datetime dayStart = (datetime)(((long)TimeCurrent() / 86400) * 86400);
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return 0;
   int c = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0 || HistoryDealGetInteger(tk, DEAL_MAGIC) != Magic)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      double p = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) + HistoryDealGetDouble(tk, DEAL_COMMISSION);
      if(p < 0)
         c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//| Taille de position selon le risque                               |
//+------------------------------------------------------------------+
string lotNote = "";   // explique une réduction du volume (marge insuffisante)

double LotsForRisk(string sym, double slDistance, int dir)
  {
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double vMin      = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vMax      = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vStep     = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(tickSize <= 0 || tickValue <= 0 || vStep <= 0 || slDistance <= 0)
      return 0;
   double riskMoney   = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double lossPerLot  = slDistance / tickSize * tickValue;
   double lots        = MathFloor(riskMoney / lossPerLot / vStep) * vStep;
   if(lots < vMin)
     {
      // Le lot minimum dépasse le risque voulu : on refuse s'il le dépasse de plus de 50 %
      if(vMin * lossPerLot > riskMoney * 1.5)
         return 0;
      lots = vMin;
     }
   lots = MathMin(lots, vMax);

   // Plafond de marge : la position ne doit pas prendre plus que sa part de la marge libre
   // (marge libre × 90 % ÷ nombre de places encore libres), sinon le broker refuse (« not enough money »)
   lotNote = "";
   double price = (dir == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double marginPerLot = 0;
   if(OrderCalcMargin(dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, 1.0, price, marginPerLot) && marginPerLot > 0)
     {
      int    slots  = MathMax(1, MaxPositions - CountPositions(""));
      double budget = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9 / slots;
      double maxLots = MathFloor(budget / marginPerLot / vStep) * vStep;
      if(lots > maxLots)
        {
         if(maxLots < vMin)
           {
            lotNote = "marge insuffisante même pour le lot minimum";
            return 0;
           }
         lotNote = StringFormat("volume réduit de %.2f à %.2f lot (marge du compte)", lots, maxLots);
         lots = maxLots;
        }
     }
   return lots;
  }

//+------------------------------------------------------------------+
//| Entrée au marché                                                 |
//+------------------------------------------------------------------+
void TryEnter(Zone &z, const MqlRates &r[])
  {
   string why = BlockReason();
   if(why != "")
     {
      z.status = "signal " + (EntryMode == ENTRY_DIRECT ? "d'entrée directe" : TfName()) + " ignoré : " + why;
      return;
     }
   if(CountPositions(z.sym) > 0)
     {
      z.status = "signal ignoré : position déjà ouverte sur ce symbole";
      return;
     }

   int    dg     = SymDigits(z.sym);
   double point  = SymbolInfoDouble(z.sym, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(z.sym, SYMBOL_BID);
   double ask    = SymbolInfoDouble(z.sym, SYMBOL_ASK);
   double spread = ask - bid;
   double buf    = MathMax(2 * spread, 0.15 * AtrM15(r, 14));
   double minStop = (double)SymbolInfoInteger(z.sym, SYMBOL_TRADE_STOPS_LEVEL) * point;

   // Stop minimum : une fraction du mouvement moyen d'une journée (ATR D1), propre à chaque symbole
   double atrD1 = 0;
   MqlRates d[];
   ArraySetAsSeries(d, true);
   if(CopyRates(z.sym, PERIOD_D1, 0, 16, d) >= 16)
      atrD1 = AtrM15(d, 14);            // même calcul d'ATR, appliqué aux bougies journalières
   double minDist = MinStopATR * atrD1;

   double price, sl, tp = z.tp;
   if(z.dir == -1)
     {
      price = bid;
      sl    = z.extreme + buf;
      if(sl - price < minDist)
         sl = price + minDist;         // pas de stop plus serré que le minimum
      if(sl >= z.slDay || EntryMode == ENTRY_DIRECT)
         sl = z.slDay;                 // jamais plus loin que le stop du plan ; entrée directe : stop du plan
      if(sl - price < minStop || price - tp <= 0)
        {
         z.status = "signal ignoré : stop ou objectif trop proche";
         return;
        }
     }
   else
     {
      price = ask;
      sl    = z.extreme - buf;
      if(price - sl < minDist)
         sl = price - minDist;         // pas de stop plus serré que le minimum
      if(sl <= z.slDay || EntryMode == ENTRY_DIRECT)
         sl = z.slDay;                 // jamais plus loin que le stop du plan ; entrée directe : stop du plan
      if(price - sl < minStop || tp - price <= 0)
        {
         z.status = "signal ignoré : stop ou objectif trop proche";
         return;
        }
     }

   double risk = MathAbs(price - sl);
   double rr   = MathAbs(tp - price) / risk;
   if(rr < MinRR)
     {
      z.status = "signal ignoré : ratio " + DoubleToString(rr, 2) + " trop faible, attente d'un meilleur point";
      return;
     }

   double lots = LotsForRisk(z.sym, risk, z.dir);
   if(lots <= 0)
     {
      if(lotNote != "")
        {
         z.status = "signal ignoré : " + lotNote;   // la marge peut se libérer plus tard : la zone reste active
         return;
        }
      z.status = "signal ignoré : le lot minimum dépasse le risque autorisé";
      z.done = true;
      return;
     }

   // Gain minimum visé au TP, en devise du compte
   double tickSize  = SymbolInfoDouble(z.sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(z.sym, SYMBOL_TRADE_TICK_VALUE);
   double gainMoney = (tickSize > 0) ? MathAbs(tp - price) / tickSize * tickValue * lots : 0;
   if(MinGainMoney > 0 && gainMoney < MinGainMoney)
     {
      z.status = StringFormat("signal ignoré : gain visé %.0f %s, sous le minimum de %.0f",
                              gainMoney, AccountInfoString(ACCOUNT_CURRENCY), MinGainMoney);
      return;
     }

   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
   string comment = "AI:" + DoubleToString(z.tp1, dg);

   trade.SetTypeFillingBySymbol(z.sym);
   bool ok = (z.dir == -1) ? trade.Sell(lots, z.sym, 0, sl, tp, comment)
                           : trade.Buy(lots, z.sym, 0, sl, tp, comment);
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      z.done   = true;
      // Mémorise le risque initial (distance entrée → SL) pour la sortie quand l'élan s'essouffle
      GlobalVariableSet("PE_R_" + IntegerToString((long)trade.ResultOrder()), MathAbs(trade.ResultPrice() - sl));
      z.status = StringFormat("ENTRÉE %s %.2f lot à %s, SL %s, TP %s (ratio %.2f)",
                              z.dir == -1 ? "vente" : "achat", lots,
                              DoubleToString(trade.ResultPrice(), dg),
                              DoubleToString(sl, dg), DoubleToString(tp, dg), rr);
      if(lotNote != "")
         z.status += " — " + lotNote;
      Print(z.sym, " : ", z.status);
     }
   else
     {
      z.status = "ordre refusé : " + trade.ResultRetcodeDescription();
      Print(z.sym, " : ", z.status);
     }
  }

//+------------------------------------------------------------------+
//| Gain verrouillé : quand le gain latent atteint LockTriggerMoney,  |
//| le SL passe au prix qui garantit LockKeepMoney. Il ne fait que se |
//| resserrer ; le suivi H1 ou Claude peuvent ensuite le monter plus. |
//+------------------------------------------------------------------+
void LockProfit(ulong tk)
  {
   if(LockTriggerMoney <= 0 || LockKeepMoney <= 0 || !PositionSelectByTicket(tk))
      return;
   double profit = PositionGetDouble(POSITION_PROFIT);
   if(profit < LockTriggerMoney)
      return;
   string sym     = PositionGetString(POSITION_SYMBOL);
   long   type    = PositionGetInteger(POSITION_TYPE);
   double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl      = PositionGetDouble(POSITION_SL);
   double tp      = PositionGetDouble(POSITION_TP);
   double vol     = PositionGetDouble(POSITION_VOLUME);
   int    dg      = SymDigits(sym);
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);
   double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double minStop = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(tickSz <= 0 || tickVal <= 0 || vol <= 0)
      return;
   double moneyPerUnit = tickVal / tickSz * vol;          // gain en devise du compte pour 1 unité de prix
   double dist  = LockKeepMoney / moneyPerUnit;           // distance au prix d'entrée qui garantit le gain
   double newSl;
   if(type == POSITION_TYPE_BUY)
     {
      newSl = NormalizeDouble(open + dist, dg);
      if(newSl <= sl + point || newSl >= bid - minStop)
         return;
     }
   else
     {
      newSl = NormalizeDouble(open - dist, dg);
      if((sl > 0 && newSl >= sl - point) || newSl <= ask + minStop)
         return;
     }
   if(trade.PositionModify(tk, newSl, tp))
     {
      Print(sym, " : gain de ", DoubleToString(profit, 2), " atteint, SL à ", DoubleToString(newSl, dg),
            " pour garantir +", DoubleToString(LockKeepMoney, 0));
      pushNeeded = true;
     }
  }

//+------------------------------------------------------------------+
//| Sortie quand l'élan s'essouffle                                  |
//| Dès que le gain atteint TrailStartR × risque, le SL suit le plus  |
//| bas (achat) / plus haut (vente) des TrailBarsH1 dernières bougies |
//| H1 fermées. Il ne fait que se resserrer.                          |
//+------------------------------------------------------------------+
void TrailPosition(ulong tk)
  {
   if(!TrailEnabled || !PositionSelectByTicket(tk))
      return;
   string sym    = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   double tp     = PositionGetDouble(POSITION_TP);
   int    dg     = SymDigits(sym);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double spread = ask - bid;
   double minStop = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(bid <= 0 || ask <= 0)
      return;

   // Risque initial : mémorisé à l'entrée, sinon déduit du SL encore du côté perdant
   string gv   = "PE_R_" + IntegerToString((long)tk);
   double risk = GlobalVariableCheck(gv) ? GlobalVariableGet(gv) : 0;
   if(risk <= 0)
     {
      if(type == POSITION_TYPE_BUY && sl > 0 && sl < open)
         risk = open - sl;
      if(type == POSITION_TYPE_SELL && sl > open)
         risk = sl - open;
      if(risk > 0)
         GlobalVariableSet(gv, risk);
     }
   bool locked = (type == POSITION_TYPE_BUY) ? (sl >= open) : (sl > 0 && sl <= open);
   if(risk <= 0 && !locked)
      return;
   double gain = (type == POSITION_TYPE_BUY) ? bid - open : open - ask;
   if(!locked && gain < TrailStartR * risk)
      return;

   int n = MathMax(1, TrailBarsH1);
   double newSl;
   if(type == POSITION_TYPE_BUY)
     {
      double lo = iLow(sym, PERIOD_H1, 1);
      for(int k = 2; k <= n; k++)
         lo = MathMin(lo, iLow(sym, PERIOD_H1, k));
      if(lo <= 0)
         return;
      newSl = NormalizeDouble(lo - spread, dg);
      if(newSl <= sl + point || newSl >= bid - minStop)
         return;
     }
   else
     {
      double hi = iHigh(sym, PERIOD_H1, 1);
      for(int k = 2; k <= n; k++)
         hi = MathMax(hi, iHigh(sym, PERIOD_H1, k));
      if(hi <= 0)
         return;
      newSl = NormalizeDouble(hi + 2 * spread, dg);   // le SL d'une vente se déclenche sur l'Ask
      if((sl > 0 && newSl >= sl - point) || newSl <= ask + minStop)
         return;
     }
   if(trade.PositionModify(tk, newSl, tp))
     {
      Print(sym, " : élan qui s'essouffle, SL resserré à ", DoubleToString(newSl, dg));
      pushNeeded = true;
     }
  }

//+------------------------------------------------------------------+
//| Ordres de Claude : actions.csv (branche main)                     |
//|   #date;AAAA-MM-JJ                                                |
//|   ID;CLOSE|SL|TP;TICKET;VALEUR;RAISON                             |
//| Seules les actions du jour sont lues, chaque ID une seule fois.   |
//| Un SL ne peut que se resserrer (jamais élargir le risque).        |
//+------------------------------------------------------------------+
void PollActions()
  {
   if(!ActionsEnabled)
      return;
   char   post[], result[];
   string headers;
   string url = ActionsURL + "?t=" + IntegerToString((long)TimeGMT());
   string req = (GitHubToken != "") ? "Authorization: token " + GitHubToken + "\r\n" : "";
   ResetLastError();
   int code = WebRequest("GET", url, req, 10000, post, result, headers);
   if(code != 200)
      return;                           // pas de fichier = aucun ordre
   string text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   StringReplace(text, "\r", "");
   string lines[];
   int n = StringSplit(text, '\n', lines);
   string fileDate = "";
   for(int i = 0; i < n; i++)
     {
      string line = lines[i];
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         continue;
      string f[];
      int k = StringSplit(line, ';', f);
      if(k >= 2 && f[0] == "#date")
        {
         fileDate = f[1];
         continue;
        }
      if(StringGetCharacter(line, 0) == '#' || k < 4)
         continue;
      if(fileDate != TodayCayenne())
         return;                        // ordres d'un autre jour : ignorés
      string id = f[0];
      string gv = "PE_A_" + id;
      if(GlobalVariableCheck(gv))
         continue;                      // déjà exécuté
      GlobalVariableSet(gv, (double)TimeCurrent());
      string why = (k >= 5) ? f[4] : "";
      actionStatus = ExecuteAction(f[1], (ulong)StringToInteger(f[2]), StringToDouble(f[3]), why);
      Print("Ordre de Claude ", id, " : ", actionStatus);
      pushNeeded = true;
     }
  }

string ExecuteAction(const string act, ulong tk, double val, const string why)
  {
   if(!PositionSelectByTicket(tk))
      return act + " " + IntegerToString((long)tk) + " ignoré : position introuvable (déjà fermée ?)";
   string sym    = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double sl     = PositionGetDouble(POSITION_SL);
   double tp     = PositionGetDouble(POSITION_TP);
   int    dg     = SymDigits(sym);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double minStop = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double v      = NormalizeDouble(val, dg);

   if(act == "CLOSE")
     {
      trade.SetTypeFillingBySymbol(sym);
      if(trade.PositionClose(tk))
         return "position " + sym + " fermée (" + why + ")";
      return "fermeture de " + sym + " refusée : " + trade.ResultRetcodeDescription();
     }
   if(act == "SL")
     {
      bool tighter = (type == POSITION_TYPE_BUY) ? (sl == 0 || v > sl) : (sl == 0 || v < sl);
      bool valid   = (type == POSITION_TYPE_BUY) ? (v < bid - minStop) : (v > ask + minStop);
      if(!tighter)
         return "SL de " + sym + " ignoré : un ordre de Claude ne peut que resserrer le stop";
      if(!valid)
         return "SL de " + sym + " ignoré : trop près du prix ou du mauvais côté";
      if(trade.PositionModify(tk, v, tp))
         return "SL de " + sym + " déplacé à " + DoubleToString(v, dg) + " (" + why + ")";
      return "SL de " + sym + " refusé : " + trade.ResultRetcodeDescription();
     }
   if(act == "TP")
     {
      bool valid = (type == POSITION_TYPE_BUY) ? (v > ask + minStop) : (v < bid - minStop);
      if(!valid)
         return "TP de " + sym + " ignoré : du mauvais côté du prix";
      if(trade.PositionModify(tk, sl, v))
         return "TP de " + sym + " déplacé à " + DoubleToString(v, dg) + " (" + why + ")";
      return "TP de " + sym + " refusé : " + trade.ResultRetcodeDescription();
     }
   return "ordre inconnu : " + act;
  }

//+------------------------------------------------------------------+
//| Réveil de Claude : l'EA appelle la routine par API quand il se    |
//| passe quelque chose sur un trade ouvert.                          |
//+------------------------------------------------------------------+
bool Once(const string key)
  {
   // Vrai la première fois seulement (mémorisé dans les variables globales du terminal)
   if(GlobalVariableCheck(key))
      return false;
   GlobalVariableSet(key, (double)TimeCurrent());
   return true;
  }

void CheckEvents()
  {
   if(!RoutineEnabled || RoutineURL == "" || RoutineToken == "")
      return;
   string   msg = "";
   datetime now = CayenneNow();
   MqlDateTime t;
   TimeToStruct(now, t);
   string today = TodayCayenne();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym   = PositionGetString(POSITION_SYMBOL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double pl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
      int    dg    = SymDigits(sym);
      bool   buy   = (type == POSITION_TYPE_BUY);
      double price = buy ? bid : ask;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      string p     = "PE_F_" + IntegerToString((long)tk) + "_";
      string head  = sym + " (ticket " + IntegerToString((long)tk) + ", " + (buy ? "achat" : "vente") + " à " +
                     DoubleToString(open, dg) + ", prix " + DoubleToString(price, dg) + ", P/L " + DoubleToString(pl, 2) + ") : ";

      // 1. Nouvelle position
      if(Once(p + "open"))
         msg += head + "nouvelle position ouverte.\n";

      // Risque initial
      string gv   = "PE_R_" + IntegerToString((long)tk);
      double risk = GlobalVariableCheck(gv) ? GlobalVariableGet(gv) : 0;
      if(risk <= 0 && sl > 0 && ((buy && sl < open) || (!buy && sl > open)))
         risk = MathAbs(open - sl);
      bool   locked = (sl > 0) && (buy ? sl >= open : sl <= open);
      double gain   = buy ? bid - open : open - ask;

      // 2. Paliers de gain
      if(risk > 0)
        {
         if(gain >= 0.5 * risk && Once(p + "r05"))
            msg += head + "le gain atteint 0,5 fois le risque.\n";
         if(gain >= 1.0 * risk && Once(p + "r1"))
            msg += head + "le gain atteint 1 fois le risque.\n";
         if(gain >= 2.0 * risk && Once(p + "r2"))
            msg += head + "le gain atteint 2 fois le risque.\n";
        }

      // 2 bis. Gain verrouillé : Claude décide s'il faut laisser monter (TP plus loin) ou encaisser
      if(LockTriggerMoney > 0 && PositionGetDouble(POSITION_PROFIT) >= LockTriggerMoney && Once(p + "lock"))
         msg += head + "gain de " + DoubleToString(LockTriggerMoney, 0) + " atteint, l'EA verrouille +" +
                DoubleToString(LockKeepMoney, 0) + " : décide s'il faut laisser monter (TP plus loin) ou encaisser.\n";

      // 3. Prix proche du SL (moins de 20 % de la distance de départ)
      if(risk > 0 && sl > 0 && !locked && MathAbs(price - sl) < 0.2 * risk && Once(p + "nearsl"))
         msg += head + "le prix est à moins de 20 % du stop " + DoubleToString(sl, dg) + ".\n";

      // 4. Élan qui s'inverse en H1 (au plus une fois toutes les 2 heures par position)
      datetime bar1 = iTime(sym, PERIOD_H1, 1);
      if(bar1 > opened)
        {
         bool rev = buy ? (iClose(sym, PERIOD_H1, 1) < iLow(sym, PERIOD_H1, 2))
                        : (iClose(sym, PERIOD_H1, 1) > iHigh(sym, PERIOD_H1, 2));
         string kl = p + "h1last";
         double last = GlobalVariableCheck(kl) ? GlobalVariableGet(kl) : 0;
         if(rev && (double)bar1 - last >= 7200)
           {
            GlobalVariableSet(kl, (double)bar1);
            msg += head + "la dernière bougie H1 a clôturé " + (buy ? "sous le plus bas" : "au-dessus du plus haut") +
                   " de la précédente (élan qui s'inverse).\n";
           }
        }

      // 5. Annonce économique dans les 30 minutes
      for(int j = 0; j < ArraySize(newsTimes); j++)
        {
         long dt = (long)(newsTimes[j] - now);
         if(dt > 0 && dt <= 30 * 60 && Once(p + "news" + IntegerToString((long)newsTimes[j])))
            msg += head + "annonce économique majeure à " + TimeToString(newsTimes[j], TIME_MINUTES) + " (heure de Cayenne).\n";
        }

      // 6. Le soir, position gardée pour la nuit (une fois par jour)
      if(t.hour >= 20 && Once(p + "soir" + today))
         msg += head + "position encore ouverte ce soir, elle va passer la nuit.\n";
     }

   if(msg != "")
      QueueFire(msg);
  }

void QueueFire(const string msg)
  {
   pendingFire += msg;
   if(StringLen(pendingFire) > 3000)
      pendingFire = StringSubstr(pendingFire, StringLen(pendingFire) - 3000);
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

void SendPendingFire()
  {
   if(pendingFire == "" || RoutineURL == "" || RoutineToken == "")
      return;
   string today = TodayCayenne();
   if(fireDay != today)
     {
      fireDay    = today;
      firesToday = 0;
     }
   if(firesToday >= RoutineMaxPerDay)
     {
      routineStatus = "limite de " + IntegerToString(RoutineMaxPerDay) + " réveils atteinte aujourd'hui";
      pendingFire   = "";
      return;
     }
   if(lastFire > 0 && TimeLocal() - lastFire < RoutineMinMinutes * 60)
      return;                           // trop tôt : on regroupera avec les prochains événements

   // Données fraîches pour Claude avant de le réveiller
   if(GitHubToken != "")
      PushData();

   string text = "Événements détectés par l'EA à " + TimeToString(CayenneNow(), TIME_DATE | TIME_MINUTES) +
                 " (heure de Cayenne) :\n" + pendingFire;
   string body = "{\"text\":\"" + JsonEscape(text) + "\"}";
   char   data[], result[];
   string rh;
   int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(data, n - 1);
   string headers = "Authorization: Bearer " + RoutineToken + "\r\n" +
                    "anthropic-beta: experimental-cc-routine-2026-04-01\r\n" +
                    "anthropic-version: 2023-06-01\r\n" +
                    "Content-Type: application/json\r\n";
   ResetLastError();
   int code = WebRequest("POST", RoutineURL, headers, 20000, data, result, rh);
   lastFire = TimeLocal();
   if(code == -1)
     {
      int err = GetLastError();
      routineStatus = (err == 4014) ? "réveil bloqué : ajoute https://api.anthropic.com dans Outils > Options > Expert Advisors > WebRequest"
                                    : "réveil impossible (erreur WebRequest " + IntegerToString(err) + ")";
      return;                           // on garde les événements pour réessayer
     }
   if(code >= 200 && code < 300)
     {
      firesToday++;
      routineStatus = "dernier réveil le " + TimeToString(CayenneNow(), TIME_DATE | TIME_MINUTES);
      pendingFire   = "";
      Print("Réveil de Claude envoyé : ", text);
      return;
     }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string m    = JsonStr(resp, "message");
   if(code == 401 || code == 403)
      routineStatus = "réveil refusé : jeton ou adresse de la routine incorrects (HTTP " + IntegerToString(code) + ")";
   else
      routineStatus = "réveil refusé (HTTP " + IntegerToString(code) + (m != "" ? " : " + m : "") + ")";
   if(code != 429)
      pendingFire = "";                 // erreur définitive : on n'insiste pas
  }

//+------------------------------------------------------------------+
//| Gestion des positions ouvertes                                   |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   MqlDateTime t;
   TimeToStruct(CayenneNow(), t);
   bool fridayClose = (t.day_of_week == 5 && t.hour >= FridayCloseHour);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);

      if(fridayClose)
        {
         trade.SetTypeFillingBySymbol(sym);
         if(trade.PositionClose(tk))
            Print(sym, " : position fermée avant le week-end");
         continue;
        }

      // Gain verrouillé : dès +LockTriggerMoney, le SL garantit au moins +LockKeepMoney
      LockProfit(tk);
      // Sortie quand l'élan s'essouffle : SL derrière les dernières bougies H1
      TrailPosition(tk);
      if(!PositionSelectByTicket(tk))
         continue;

      // Stop au prix d'entrée une fois l'objectif 1 atteint
      string cm = PositionGetString(POSITION_COMMENT);
      if(StringFind(cm, "AI:") != 0)
         continue;
      double tp1  = StringToDouble(StringSubstr(cm, 3));
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(tp1 <= 0)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
         if(ask <= tp1 && (sl == 0 || sl > open))
            if(trade.PositionModify(tk, open, tp))
               Print(sym, " : objectif 1 atteint, stop remonté au prix d'entrée");
        }
      else
        {
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);
         if(bid >= tp1 && (sl == 0 || sl < open))
            if(trade.PositionModify(tk, open, tp))
               Print(sym, " : objectif 1 atteint, stop remonté au prix d'entrée");
        }
     }
  }

//+------------------------------------------------------------------+
//| Envoi des données XM vers GitHub (branche DataBranch, xm.csv)     |
//| WebRequest ne fait que GET/POST : on passe par l'API Git          |
//| (blob → arbre → commit → fusion dans la branche).                 |
//+------------------------------------------------------------------+
string D(double v, int dg) { return DoubleToString(v, dg); }

string Clean(string s)
  {
   StringReplace(s, ";", ",");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\r", " ");
   return s;
  }

string TimeStr(datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
   StringReplace(s, ".", "-");
   return s;
  }

string DateStr(datetime t)
  {
   string s = TimeToString(t, TIME_DATE);
   StringReplace(s, ".", "-");
   return s;
  }

void AddBars(string &s, string sym, ENUM_TIMEFRAMES tf, string tfName, int count, int off, int dg)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(sym, tf, 0, count, r);
   for(int i = 0; i < n; i++)
     {
      // D1 : date du serveur XM ; H1/M15 : heure UTC d'ouverture de la bougie
      string t = (tf == PERIOD_D1) ? DateStr(r[i].time) : TimeStr(r[i].time - off);
      s += "BAR;" + sym + ";" + tfName + ";" + t + ";" + D(r[i].open, dg) + ";" + D(r[i].high, dg) + ";" +
           D(r[i].low, dg) + ";" + D(r[i].close, dg) + ";" + IntegerToString(r[i].tick_volume) + "\n";
     }
  }

string BuildDataCsv()
  {
   int off = (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 3600.0) * 3600; // décalage serveur XM / UTC
   string s = "#ver;1\n";
   s += "#generated_utc;" + TimeStr(TimeGMT()) + "\n";
   s += "#server_utc_offset_h;" + IntegerToString(off / 3600) + "\n";
   s += "#times;BAR D1 = date serveur XM, BAR H1/M15/M5, POS et DEAL = heure UTC\n";
   string mode = AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL";
   s += "ACCOUNT;" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ";" + AccountInfoString(ACCOUNT_SERVER) + ";" +
        AccountInfoString(ACCOUNT_CURRENCY) + ";" + D(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ";" +
        D(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ";" + D(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + ";" + mode + "\n";
   string why = BlockReason();
   s += "EA;plan=" + planDate + ";entrees=" + (why == "" ? "autorisees" : Clean(why)) + ";erreur=" + Clean(lastError) +
        ";risque=" + D(RiskPercent, 2) + ";maxpos=" + IntegerToString(MaxPositions) + ";mode=" + EntryModeName() +
        ";suivi=" + (TrailEnabled ? "H1" : "non") + ";ordres_claude=" + (ActionsEnabled ? "oui" : "non") +
        ";dernier_ordre=" + Clean(actionStatus) + ";reveil=" + Clean(routineStatus) + "\n";

   s += "#ZONE;symbole;sens;zone_bas;zone_haut;sl_jour;tp;tp1;touchee;etat\n";
   for(int i = 0; i < ArraySize(zones); i++)
     {
      int dg = SymDigits(zones[i].sym);
      s += "ZONE;" + zones[i].sym + ";" + (zones[i].dir == 1 ? "BUY" : "SELL") + ";" + D(zones[i].zlo, dg) + ";" +
           D(zones[i].zhi, dg) + ";" + D(zones[i].slDay, dg) + ";" + D(zones[i].tp, dg) + ";" + D(zones[i].tp1, dg) + ";" +
           (zones[i].touched ? "1" : "0") + ";" + Clean(zones[i].status) + "\n";
     }

   s += "#POS;ticket;symbole;type;volume;ouverture_utc;prix_ouverture;sl;tp;prix_actuel;profit;swap;magic;commentaire\n";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = SymDigits(sym);
      s += "POS;" + IntegerToString((long)tk) + ";" + sym + ";" +
           (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL") + ";" +
           D(PositionGetDouble(POSITION_VOLUME), 2) + ";" + TimeStr((datetime)PositionGetInteger(POSITION_TIME) - off) + ";" +
           D(PositionGetDouble(POSITION_PRICE_OPEN), dg) + ";" + D(PositionGetDouble(POSITION_SL), dg) + ";" +
           D(PositionGetDouble(POSITION_TP), dg) + ";" + D(PositionGetDouble(POSITION_PRICE_CURRENT), dg) + ";" +
           D(PositionGetDouble(POSITION_PROFIT), 2) + ";" + D(PositionGetDouble(POSITION_SWAP), 2) + ";" +
           IntegerToString(PositionGetInteger(POSITION_MAGIC)) + ";" + Clean(PositionGetString(POSITION_COMMENT)) + "\n";
     }

   s += "#DEAL;ticket;heure_utc;symbole;type;entree;volume;prix;profit;swap;commission;magic;position;commentaire\n";
   if(HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent() + 60))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0)
            continue;
         string sym = HistoryDealGetString(tk, DEAL_SYMBOL);
         int dg = (sym == "") ? 2 : SymDigits(sym);
         string typ = EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE));
         string ent = EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY));
         StringReplace(typ, "DEAL_TYPE_", "");
         StringReplace(ent, "DEAL_ENTRY_", "");
         s += "DEAL;" + IntegerToString((long)tk) + ";" + TimeStr((datetime)HistoryDealGetInteger(tk, DEAL_TIME) - off) + ";" +
              sym + ";" + typ + ";" + ent + ";" + D(HistoryDealGetDouble(tk, DEAL_VOLUME), 2) + ";" +
              D(HistoryDealGetDouble(tk, DEAL_PRICE), dg) + ";" + D(HistoryDealGetDouble(tk, DEAL_PROFIT), 2) + ";" +
              D(HistoryDealGetDouble(tk, DEAL_SWAP), 2) + ";" + D(HistoryDealGetDouble(tk, DEAL_COMMISSION), 2) + ";" +
              IntegerToString(HistoryDealGetInteger(tk, DEAL_MAGIC)) + ";" +
              IntegerToString(HistoryDealGetInteger(tk, DEAL_POSITION_ID)) + ";" + Clean(HistoryDealGetString(tk, DEAL_COMMENT)) + "\n";
        }
     }

   string syms[];
   int ns = StringSplit(DataSymbols, ',', syms);
   s += "#QUOTE;symbole;bid;ask;spread_points;digits\n";
   for(int i = 0; i < ns; i++)
     {
      string sym = syms[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "" || !SymbolSelect(sym, true))
         continue;
      int dg = SymDigits(sym);
      s += "QUOTE;" + sym + ";" + D(SymbolInfoDouble(sym, SYMBOL_BID), dg) + ";" + D(SymbolInfoDouble(sym, SYMBOL_ASK), dg) + ";" +
           IntegerToString(SymbolInfoInteger(sym, SYMBOL_SPREAD)) + ";" + IntegerToString(dg) + "\n";
     }
   s += "#BAR;symbole;unite;heure;open;high;low;close;volume_ticks\n";
   for(int i = 0; i < ns; i++)
     {
      string sym = syms[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "" || !SymbolSelect(sym, true))
         continue;
      int dg = SymDigits(sym);
      AddBars(s, sym, PERIOD_D1, "D1", 120, off, dg);
      AddBars(s, sym, PERIOD_H1, "H1", 120, off, dg);
      AddBars(s, sym, PERIOD_M15, "M15", 96, off, dg);
      AddBars(s, sym, PERIOD_M5, "M5", 144, off, dg);   // 12 dernières heures, pour vérifier les entrées M5
     }
   return s;
  }

string Base64(const string text)
  {
   uchar src[], dst[], key[];
   int n = StringToCharArray(text, src, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(src, n - 1);          // retire le zéro final
   if(CryptEncode(CRYPT_BASE64, src, key, dst) <= 0)
      return "";
   return CharArrayToString(dst);
  }

// Première valeur texte d'une clé dans une réponse JSON de GitHub
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
                    "User-Agent: PlanExecutor-MT5\r\n" +
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
      return pushStatus;                // déjà rempli par Gh()
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

   string b64 = Base64(BuildDataCsv());
   if(b64 == "")
     {
      pushStatus = "échec de l'encodage des données";
      return;
     }
   string resp, msg = "Donnees XM " + TimeStr(TimeGMT()) + " UTC";

   // 1. Où en est la branche ?
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

   // 2. Le fichier
   code = Gh("POST", "/git/blobs", "{\"content\":\"" + b64 + "\",\"encoding\":\"base64\"}", resp);
   if(code != 201)
     {
      pushStatus = GhError("fichier", code, resp);
      return;
     }
   string blob = JsonStr(resp, "sha");

   // 3. L'arborescence (un seul fichier : xm.csv)
   code = Gh("POST", "/git/trees", "{\"tree\":[{\"path\":\"xm.csv\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"" + blob + "\"}]}", resp);
   if(code != 201)
     {
      pushStatus = GhError("arborescence", code, resp);
      return;
     }
   string tree = JsonStr(resp, "sha");

   // 4. Le commit
   string parents = (parent != "") ? "[\"" + parent + "\"]" : "[]";
   code = Gh("POST", "/git/commits", "{\"message\":\"" + msg + "\",\"tree\":\"" + tree + "\",\"parents\":" + parents + "}", resp);
   if(code != 201)
     {
      pushStatus = GhError("commit", code, resp);
      return;
     }
   string commit = JsonStr(resp, "sha");

   // 5. Mise à jour de la branche (création la première fois, fusion ensuite)
   if(parent == "")
      code = Gh("POST", "/git/refs", "{\"ref\":\"refs/heads/" + DataBranch + "\",\"sha\":\"" + commit + "\"}", resp);
   else
      code = Gh("POST", "/merges", "{\"base\":\"" + DataBranch + "\",\"head\":\"" + commit + "\",\"commit_message\":\"" + msg + "\"}", resp);
   if(code != 201 && code != 204)
     {
      pushStatus = GhError("branche", code, resp);
      return;
     }
   pushStatus = "données XM envoyées à " + TimeToString(CayenneNow(), TIME_MINUTES) + " (heure de Cayenne)";
  }

//+------------------------------------------------------------------+
//| Affichage sur le graphique                                       |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   string s = "Plan de trading du jour — EA exécutant\n";
   if(lastError != "")
      s += "⚠ " + lastError + "\n";
   if(pushStatus != "")
      s += "Données : " + pushStatus + "\n";
   s += "Suivi : " + (TrailEnabled ? "SL qui suit les bougies H1 activé" : "SL fixe") +
        (ActionsEnabled ? " · ordres de Claude activés" : " · ordres de Claude désactivés") + "\n";
   if(actionStatus != "")
      s += "Dernier ordre de Claude : " + actionStatus + "\n";
   if(!RoutineEnabled || RoutineURL == "" || RoutineToken == "")
      s += "Réveil de Claude : désactivé (adresse ou jeton de la routine manquant)\n";
   else
      s += "Réveil de Claude : " + (routineStatus != "" ? routineStatus : "activé, en attente d'un événement") + "\n";
   if(planDate == "")
      s += "Aucun plan chargé\n";
   else
      s += "Plan du " + planDate + (PlanIsToday() ? "" : "  (PÉRIMÉ : aucune entrée)") + "\n";
   string why = BlockReason();
   s += "Entrées : " + (why == "" ? "autorisées" : "bloquées (" + why + ")") + "\n";
   s += StringFormat("Mode : %s · risque %.1f %% · positions %d/%d · pertes du jour %d/%d\n",
                     EntryModeName(), RiskPercent, CountPositions(""), MaxPositions, LossesToday(), MaxLossesPerDay);
   for(int i = 0; i < ArraySize(zones); i++)
     {
      Zone z = zones[i];
      int dg = SymDigits(z.sym);
      s += StringFormat("%s %s zone %s–%s : %s\n", z.sym, z.dir == 1 ? "ACHAT" : "VENTE",
                        DoubleToString(z.zlo, dg), DoubleToString(z.zhi, dg), z.status);
     }
   Comment(s);
  }
//+------------------------------------------------------------------+
