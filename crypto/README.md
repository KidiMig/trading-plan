# Crypto : plan de Claude → CryptoExecutor (MT5, Pepperstone)

Système séparé du plan XM (`plan.csv` à la racine et PlanExecutor n'y touchent pas).

```
Tâche « Plan crypto du jour » (Claude, 7j/7)
   ├─ écrit crypto/plan.csv       (branche main)  ──► CryptoExecutor le lit toutes les 5 min
   ├─ écrit crypto/actions.csv    (branche main)  ──► fermer / resserrer un stop / annuler
   ├─ écrit crypto/bilans/        (branche main)      bilan de la veille + historique
   └─ lit   crypto/data.csv       (branche live)  ◄── CryptoExecutor l'envoie toutes les 15 min
```

## Installation de l'EA (une fois)

1. Copier `crypto/ea/CryptoExecutor.mq5` dans `MQL5/Experts/` du terminal MT5 connecté à Pepperstone
   (Fichier → Ouvrir le dossier des données), puis le compiler dans MetaEditor (F7, 0 erreur).
2. Outils → Options → Expert Advisors : cocher « Autoriser le WebRequest pour les URL listées »
   et ajouter `https://api.github.com`.
3. Ouvrir un graphique (BTCUSD, H1 par exemple) et y glisser CryptoExecutor.
   Onglet Commun : cocher « Autoriser le trading algo ». Onglet Entrées : coller le token GitHub
   (le même que PlanExecutor : droits Contents lecture/écriture sur `kidimig/trading-plan`).
4. Bouton « Trading algo » en vert. Le panneau en haut à gauche du graphique affiche l'état.

## Réglages principaux

| Réglage | Défaut | Rôle |
|---|---|---|
| Risque max par trade | 2 % | Le plan peut demander moins, jamais plus |
| Positions + ordres max | 2 | Ordres en attente compris |
| Perte max par jour | 6 % | Atteinte → tout est fermé jusqu'à 0h UTC (21h à Cayenne) |
| Ratio gain/risque min | 1,5 | Ligne rejetée en dessous |
| Stop au prix d'entrée à 1R | oui | Dès que le gain égale le risque initial |
| Numéro magique | 20261016 | Distingue les trades de cet EA |

## `crypto/plan.csv`

```
#date;2026-10-17
#valid_until_utc;2026-10-18 14:00
#generated_utc;2026-10-17 10:55
ID;SYMBOL;ORDER;ENTRY;SL;TP;RISK_PCT;NOTE
20261017-BTC-1;BTCUSD;BUY_LIMIT;80500;79200;84000;2;support 80k + liquidations purgées
```

- `ORDER` : `BUY_LIMIT`, `SELL_LIMIT`, `BUY_STOP`, `SELL_STOP`, `BUY` ou `SELL` (au marché, `ENTRY` ignoré).
- `RISK_PCT` vide = risque par défaut de l'EA. `NOTE` sans point-virgule. `ID` : 24 caractères max, unique.
- Chaque ID n'est exécuté qu'une fois. Un ordre en attente dont l'ID disparaît du plan est annulé ;
  pour garder un ordre d'hier, réécrire la même ligne avec le même ID.
- Plan expiré (`#valid_until_utc` dépassé) → les ordres en attente sont annulés, rien de nouveau n'est posé.
- Rejets automatiques : SL/TP incohérents, ratio < minimum, SL trop proche, lot minimum trop risqué,
  symbole non autorisé. La raison apparaît sur le panneau, dans le journal et dans les lignes `ZONE` de `data.csv`.

## `crypto/actions.csv`

```
#date;2026-10-17
ID;ACTION;TICKET;VALUE;REASON
20261017-1000-1;SL;123456789;81200;sommet H1 cassé
```

`ACTION` : `CLOSE` (VALUE 0), `SL` (seulement dans le sens qui réduit le risque), `TP`, `CANCEL` (ordre en attente).
Chaque ID n'est appliqué qu'une fois ; un fichier daté de plus de 2 jours est ignoré.

## `crypto/data.csv` (branche live, séparateur `;`, heures UTC)

- `#generated_utc;AAAA-MM-JJ HH:MM`
- `ACCOUNT;login;serveur;devise;solde;equity;marge_libre;DEMO|REAL`
- `EA;version=…;magic=…;plan=…;risque=…;maxpos=…;perte_max_jour=…;rr_min=…;solde_debut_jour=…;stop_jour=0|1;trading_algo=0|1;erreur=…;dernier_evenement=…`
- `SPEC;symbole;digits;point;taille_contrat;lot_min;pas_lot;lot_max;stops_level;tick_size;tick_value;marge_1_lot`
- `ZONE;id;symbole;ordre;entree;sl;tp;risque;etat` (lignes du plan en cours et ce que l'EA en a fait)
- `POS;ticket;symbole;BUY|SELL;volume;ouverture_utc;prix_ouverture;sl;tp;prix_actuel;profit;swap;magic;commentaire`
- `ORDER;ticket;symbole;type;volume;prix;sl;tp;pose_utc;magic;commentaire`
- `DEAL;ticket;heure_utc;symbole;type;IN|OUT;volume;prix;profit;swap;commission;magic;position;commentaire` (7 derniers jours)
- `QUOTE;symbole;bid;ask;spread_points;digits`
- `BAR;symbole;D1|H4|H1|M15;heure_utc;open;high;low;close;volume` (120 D1, 180 H4, 240 H1, 192 M15, prix Bid)
