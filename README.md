# Loto Revanche

Loto multijoueur sous Godot 4.6 avec roulette 3D, afficheur du numéro courant, tableau des 90 numéros et chat par salon.

## Jouer sur Mac

1. Importe `project.godot` dans Godot 4.6.
2. Ouvre le Terminal dans ce dossier et démarre le serveur.

   ```sh
   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --server
   ```

3. Lance le jeu avec **F5**. Pour ouvrir une deuxième fenêtre, lance cette commande dans un autre Terminal.

   ```sh
   /Applications/Godot.app/Contents/MacOS/Godot --path .
   ```

4. Entre deux pseudos avec l’adresse `ws://127.0.0.1:8071`. Crée un salon dans la première fenêtre et rejoins-le dans la deuxième. Au moins deux joueurs sont nécessaires.

Utilise `godot` à la place du chemin Mac si l’exécutable figure déjà dans le PATH. Les tests locaux créditent 10 000 pièces de test par connexion.

## Règles

- L’hôte fixe le prix d’un carton à 50, 100, 500 ou 1 000 pièces. Le premier carton est acheté dès la création ou l’entrée dans le salon. Avant le tirage, chaque joueur peut acheter autant d’autres cartons que lui permet son solde.
- Tous les cartons du joueur sont affichés dans la salle. Chaque numéro se coche à la main avant la boule suivante. Les coches sont propres à chaque carton et l’historique reste consultable pendant la partie. Un compte Revanche Games retrouve ses cartons et ses coches en rouvrant le loto tant que le salon est disponible.
- Le serveur valide la première réclamation admissible à chaque étape. Une ligne gagnante ne peut servir deux fois. Le carton plein requiert les quinze numéros du même carton.
- Les deux quines rapportent chacune 15 % de la cagnotte et le carton plein 50 %. Les gains sont arrondis à la pièce inférieure. Le solde de la cagnotte revient à Revanche Games. Les lots encore disponibles après le délai de réclamation qui suit la dernière boule sont remboursés proportionnellement aux cartons.
- Le bouton Quitter rembourse les cartons avant le tirage. Changer de page conserve la place du joueur.

## Web

Installe les modèles d’export Web Godot 4.6.3, puis lance les commandes suivantes.

```sh
mkdir -p build/web
godot --headless --editor --import --quit
godot --headless --export-release Web build/web/index.html
node deploy/server.mjs
```

Ouvre `http://localhost:8080`. Le service Web héberge le client Godot et relaie `/ws` vers le serveur. Le même service s’exécute dans Docker. Le port HTTP est configurable via `PORT`.

## Portefeuille Revanche Games

Le dépôt de la plateforme fournit la route privée `/api/game/loto/wallet` et la migration SQL correspondante. En mode plateforme, le serveur récupère le compte depuis un jeton signé Revanche Games. Chaque achat débite immédiatement le portefeuille, les gains et remboursements de fin sont versés au règlement de la manche. Le serveur doit s’exécuter en une seule instance par environnement puisque l’état du tirage est en mémoire. Les tours expirés sont remboursés par la tâche de récupération du serveur.

| Variable du service Loto | Rôle |
| --- | --- |
| `LOTO_WALLET_URL` | URL HTTPS de la route privée de la plateforme |
| `LOTO_WALLET_SECRET` | Secret différent des autres clés de la plateforme, également défini côté Revanche Games |
| `LOTO_REQUIRE_WALLET=1` | Rend la configuration du portefeuille obligatoire au démarrage |

Les pièces de test restent disponibles quand le portefeuille plateforme n’est pas configuré. Le navigateur ne reçoit que le jeton de connexion du joueur, jamais le secret du service.
