# trading-plan

Pont entre le « Plan de trading du jour » (analyse publiee chaque matin a 9h, heure de Cayenne)
et l'EA PlanExecutor qui tourne dans MetaTrader 5 sur le VPS.

- `plan.csv` : zones du jour, reecrit a 9h et corrige si besoin au controle de 10h15.
  Format : `#date;AAAA-MM-JJ`, `#news;AAAA-MM-JJ HH:MM` (heure de Cayenne), puis
  `SYMBOLE;BUY|SELL;ZONE_BAS;ZONE_HAUT;SL_JOUR;TP;TP1`.
