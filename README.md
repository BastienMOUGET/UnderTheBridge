# UnderTheBridge

*(amalgame-bridge)*

Service Windows en Amalgame. Il offre aux applications un **point de montage local**, sur un seul port : **SOCKS5** (navigateurs, curl) et **HTTP CONNECT** (Claude Code, npm, pip, et tout client qui ne parle que `HTTPS_PROXY`). Tout le trafic qui y entre ressort sur une **interface réseau désignée**, par une **pile TCP/IP dédiée** : [lwIP](https://savannah.nongnu.org/projects/lwip/) 2.2.0, qui parle directement à la carte via Npcap. La pile de Windows et sa table de routage ne sont pas utilisées.

```
 application ──SOCKS5──► 127.0.0.1:1080 ──► amalgame-bridge
                                              │  socks.am     point de montage (CONNECT, UDP ASSOCIATE)
                                              │  net.am       façade Amalgame ⇄ lwIP
                                              │  lwIP         ARP · IPv4 · ICMP · UDP · TCP · DHCP (+ACD) · DNS
                                              │  link.am      trames Ethernet : Npcap (Windows) / AF_PACKET (Linux)
                                              ▼
                                       interface désignée (« Ethernet 2 »)
```

**Choix de l'interface** : `interface = auto` (défaut) prend, au démarrage, la carte Ethernet ou Wi-Fi active qui porte la route par défaut. Sous Windows, c'est celle que donne `GetBestInterface` si elle est éligible, sinon celle de plus faible métrique IPv4 ; les adaptateurs TAP, Wintun, WireGuard et Bluetooth sont écartés. Sous Linux, c'est la route `default` de plus faible métrique. Si la carte retenue est en Wi-Fi, `mac = auto` devient `mac = host`. `--list-interfaces` affiche le choix `auto`.

La pile a sa propre identité réseau :
- **MAC** : par défaut une MAC administrée localement, dérivée de celle de la carte (`mac = auto`). On peut aussi garder celle de la carte (`mac = host`, obligatoire en Wi-Fi).
- **IP** : obtenue par son **propre bail DHCP**, avec détection de conflit RFC 5227. Une IP statique est aussi possible. Avec `mac = host`, la pile envoie l'option DHCP 61 (`dhcp_client_id = auto` → `bridge-<mac>`) pour que le routeur lui attribue un bail distinct de celui de Windows.
- **DNS** : les serveurs reçus par DHCP. Les noms de domaine des requêtes SOCKS sont donc résolus sur l'interface désignée.

## Surveillance du réseau

- **Au démarrage**, si l'interface est indisponible (réseau pas encore prêt au boot, Npcap absent), le bridge réessaie toutes les 5 s au lieu de quitter. Le service est en démarrage différé (`delayed-auto`).
- **En marche**, toutes les 5 s et sans aucun trafic, le bridge vérifie :
  - l'état de la carte côté système (`down` ou `up`, avec la passerelle et le sous-réseau). Au retour sur le même réseau, la pile redemande son bail. Sur un autre réseau, elle repart de zéro : DHCP, ARP, adresse ;
  - en mode `auto`, la meilleure carte. Un changement confirmé sur deux vérifications fait basculer la pile sur la nouvelle carte ;
  - les erreurs de capture (carte retirée) : le bridge rouvre l'interface, ou attend qu'elle revienne. Pendant l'attente, les requêtes reçoivent `503`.
- **Sortie de veille** : détectée par l'événement de reprise du service ou par un saut d'horloge de plus de 20 s. La pile revérifie alors son bail.
- **Erreur fatale en service** : le processus se termine en échec pour que le SCM le relance. Sinon, Windows prendrait l'arrêt pour un arrêt normal.

## Arborescence

| Chemin | Rôle |
|---|---|
| `src/sys.am` | horloge, aléa, journal, dossier de l'exécutable |
| `src/bytes.am` | octets, adresses IP et MAC, `ByteQueue` |
| `src/link.am` | accès brut à l'interface : Npcap chargé dynamiquement, filtrage des trames en C |
| `src/net.am` | classes `Net`, `TcpStream`, `UdpEndpoint`, `DnsLookup` au-dessus de lwIP |
| `src/hostsock.am` | sockets non bloquantes de l'hôte (Winsock / POSIX), utilisées pour le point de montage |
| `src/socks.am` | serveur SOCKS5 (RFC 1928, authentification RFC 1929) |
| `src/config.am` | lecture et validation de `bridge.conf` |
| `src/main.am` | arguments, intégration SCM (amalgame-service), boucle d'événements |
| `src/native/` | glue C lwIP (`bridge_lwip.c`), `lwipopts.h`, portage `arch/cc.h` |
| `vendor/lwip/` | lwIP `STABLE-2_2_0_RELEASE` (BSD), non modifié |
| `vendor/amalgame-service/` | façade amalgame-service v0.3.0 (Apache-2.0) |

## Build

Il faut `amc` (≥ 0.8.90), `libgc` et le dépôt `amalgame-service` (trouvé automatiquement dans `~/Développement` ou dans le cache de paquets, sinon `AMALGAME_SERVICE=…`).

**Linux** (développement et tests) :

```bash
./build.sh             # → build/bridge
./tests/run_tests.sh   # build + test bout en bout
```

**Windows** : `build.cmd`, ou `powershell -ExecutionPolicy Bypass -File build.ps1`. Le script utilise le gcc livré par l'installeur Amalgame (`<prefix>\gcc\bin`, ou `$env:GCC_BIN`) et produit `dist\` : `bridge.exe`, les DLL nécessaires et `bridge.conf`.

Npcap n'est pas nécessaire pour compiler : `wpcap.dll` est chargée à l'exécution depuis `System32\Npcap`. Il faut en revanche l'installer sur la machine cible ([npcap.com](https://npcap.com)), sans le mode de compatibilité WinPcap.

## Installation du service

```powershell
.\dist\bridge.exe --list-interfaces           # repérer le nom de l'interface
notepad dist\bridge.conf                       # renseigner « interface = … »
.\dist\bridge.exe --config dist\bridge.conf    # essai en console (administrateur)
powershell -ExecutionPolicy Bypass -File install.ps1             # service (administrateur)
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Configuration côté clients (même port pour les deux protocoles) :

| Client | Réglage |
|---|---|
| curl | `curl --socks5-hostname 127.0.0.1:1080 …` ou `curl -x http://127.0.0.1:1080 …` |
| Chrome | `--proxy-server="socks5://127.0.0.1:1080" --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost , EXCLUDE [::1]" --user-data-dir=…` (les exclusions `localhost` sont nécessaires pour les redirections OAuth locales, comme la connexion de Claude Code) |
| Claude Code | `HTTPS_PROXY=http://127.0.0.1:1080` (Claude Code ne gère pas SOCKS) |

Le service est enregistré avec `depend= npcap`, démarrage automatique et redémarrage en cas d'échec. Côté application, il suffit de configurer le proxy `socks5://127.0.0.1:1080`. Par exemple : `curl --socks5-hostname 127.0.0.1:1080 https://example.com`.

## Package distribuable

Sous Windows : `package.cmd`, ou `powershell -ExecutionPolicy Bypass -File package.ps1 [-NoBuild] [-Version x.y.z]`.
Le script compile, puis produit `package\UnderTheBridge-<version>.zip` et son `.sha256`. Le zip contient :

- `bridge.exe` et les DLL nécessaires ;
- `bridge.conf.example`, qui sert de modèle ;
- `install.cmd` / `uninstall.cmd` : double-clic, élévation automatique en administrateur. À la première installation, `install.ps1` affiche les interfaces et propose `auto` par défaut ;
- `chrome-bridge.cmd` ;
- `LISEZMOI.txt` : guide pour les utilisateurs ;
- `licenses\` : lwIP, amalgame-service, bdwgc, winpthreads.

Le `dist\bridge.conf` personnel n'est jamais inclus.

## Tests

`tests/selftest_e2e.py` lance `bridge --selftest`. Ce mode n'a besoin ni de réseau ni de privilège : un lien factice, l'IP 10.255.0.1 et un serveur echo lwIP sur le port 7. Le script vérifie ensuite :

- CONNECT et intégrité de 4 Mio ;
- ATYP domaine, refus de connexion (REP 0x05), BIND non supporté (0x07), méthode refusée (0xFF) ;
- 50 sessions simultanées ;
- négociation UDP ASSOCIATE ;
- arrêt propre sur SIGTERM.

Le trafic suit tout le chemin SOCKS → glue → lwIP TCP, et revient par la boucle locale de lwIP.

**Essai sur un vrai réseau depuis Linux** : il faut `CAP_NET_RAW`.

```bash
sudo setcap cap_net_raw+ep build/bridge
./build/bridge --interface enp0s3 -c bridge.conf.example
curl --socks5-hostname 127.0.0.1:1080 http://example.com
```

## Limites connues et pistes

- **Validé sous Windows** (gcc de l'installeur Amalgame) : auto-test complet, puis HTTPS réel via SOCKS5 sur une interface Wi-Fi avec `mac = host` (bail DHCP distinct de celui de Windows : à confirmer dans le journal).
- **Attente active sous Windows.** Npcap ne peut pas être surveillé par `select()`, la boucle tourne donc par pas de 1 ms. Amélioration possible : `pcap_getevent()` + `WSAEventSelect()` + `WaitForMultipleObjects()`.
- **Débit.** Environ 30 Mo/s en aller-retour en auto-test. Les octets transitent par `List<int>` entre les sockets de l'hôte et lwIP ; un relais direct en C (tampons `uint8_t`) lèverait ce goulot.
- **IPv4 seulement**, sans BIND SOCKS ni fragmentation UDP SOCKS (FRAG ≠ 0 jeté).
- **Wi-Fi** : utiliser `mac = host`. Si le routeur ignore l'option 61 et redonne l'IP de Windows, la détection de conflit refuse l'adresse (le journal affiche `BACKING_OFF`). Il faut alors passer en `mode = static` avec une IP hors de la plage DHCP.
- **Sortie console** : ne pas rediriger la sortie du bridge vers un tube que personne ne lit. Sous Windows, le tampon d'environ 4 Ko se remplit et bloque la boucle.
- **Port SOCKS exposé** : une écoute hors de 127.0.0.1 exige `socks_user` et `socks_password`.

## Licence

Apache 2.0 (voir [LICENSE](LICENSE) et [NOTICE](NOTICE)). Composants tiers : lwIP (BSD), amalgame-service (Apache 2.0), bdwgc, winpthreads. Leurs licences sont dans [licenses/](licenses/).
