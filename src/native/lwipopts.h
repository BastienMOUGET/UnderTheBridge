/* lwipopts.h — configuration lwIP pour amalgame-bridge.
 *
 * Mode NO_SYS : pas de threads lwIP, pas de sockets BSD. La boucle
 * principale du service appelle brl_poll() (timers) et injecte les
 * trames reçues ; on n'utilise que l'API « raw » (callbacks).
 */
#ifndef BRIDGE_LWIPOPTS_H
#define BRIDGE_LWIPOPTS_H

#define NO_SYS                      1
#define SYS_LIGHTWEIGHT_PROT        0
#define LWIP_SOCKET                 0
#define LWIP_NETCONN                0
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS 1   /* évite le conflit avec winsock / arpa/inet */

/* ── Mémoire ─────────────────────────────────────── */
#define MEM_ALIGNMENT               8
#define MEM_SIZE                    (4 * 1024 * 1024)
#define MEMP_NUM_PBUF               256
#define MEMP_NUM_UDP_PCB            64
#define MEMP_NUM_TCP_PCB            512
#define MEMP_NUM_TCP_PCB_LISTEN     8
#define MEMP_NUM_TCP_SEG            4096
#define MEMP_NUM_REASSDATA          16
#define MEMP_NUM_ARP_QUEUE          64
#define PBUF_POOL_SIZE              1024
#define PBUF_POOL_BUFSIZE           1600

/* ── Protocoles ──────────────────────────────────── */
#define LWIP_IPV4                   1
#define LWIP_IPV6                   0
#define LWIP_ARP                    1
#define LWIP_ETHERNET               1
#define ETHARP_SUPPORT_STATIC_ENTRIES 0
#define ARP_QUEUEING                1
#define LWIP_ICMP                   1
#define LWIP_RAW                    0
#define LWIP_UDP                    1
#define LWIP_TCP                    1
#define LWIP_DHCP                   1
#define LWIP_ACD                    1     /* détection de conflit d'adresse (RFC 5227) */
#define LWIP_DHCP_DOES_ACD_CHECK    1
#define LWIP_DNS                    1
#define DNS_MAX_SERVERS             2
#define DNS_TABLE_SIZE              64
#define DNS_MAX_NAME_LENGTH         256
#define IP_REASSEMBLY               1
#define IP_FRAG                     1
#define IP_REASS_MAX_PBUFS          64
#define LWIP_IGMP                   0
#define LWIP_AUTOIP                 0
#define DHCP_OPTIONS_LEN            312   /* taille BOOTP standard (68 par défaut) */

/* Option 61 (identifiant client DHCP). En mode « MAC partagée » (Wi-Fi),
 * c'est elle qui permet au serveur DHCP de distinguer notre bail de
 * celui de Windows : sans elle, même MAC ⇒ même adresse ⇒ conflit.
 * La macro est développée DANS dhcp.c, d'où l'accès à dhcp_option()
 * et dhcp_option_byte() (statiques). */
#include <stdint.h>
int brl_dhcp_client_id(const uint8_t** out);
#define LWIP_HOOK_DHCP_APPEND_OPTIONS(netif, dhcp, state, msg, msg_type, options_len_ptr) \
    do {                                                                                   \
        const uint8_t* brl_cid_;                                                           \
        int brl_n_ = brl_dhcp_client_id(&brl_cid_);                                        \
        if (brl_n_ > 0) {                                                                  \
            int brl_i_;                                                                    \
            *(options_len_ptr) = dhcp_option(*(options_len_ptr), (msg)->options, 61, (u8_t) brl_n_); \
            for (brl_i_ = 0; brl_i_ < brl_n_; brl_i_++)                                    \
                *(options_len_ptr) = dhcp_option_byte(*(options_len_ptr), (msg)->options, brl_cid_[brl_i_]); \
        }                                                                                  \
    } while (0)

/* ── Interface ───────────────────────────────────── */
#define LWIP_NETIF_HOSTNAME         1
#define LWIP_NETIF_STATUS_CALLBACK  1
#define LWIP_NETIF_LINK_CALLBACK    1
#define LWIP_NETIF_LOOPBACK         1     /* connexions vers notre propre IP (auto-test) */
#define LWIP_HAVE_LOOPIF            0
#define LWIP_SINGLE_NETIF           1

/* ── TCP ─────────────────────────────────────────── */
#define TCP_MSS                     1460
#define LWIP_WND_SCALE              1
#define TCP_RCV_SCALE               2
#define TCP_WND                     (255 * 1024)  /* <= 0xFFFF << TCP_RCV_SCALE */
#define TCP_SND_BUF                 (256 * 1024)
#define TCP_SND_QUEUELEN            ((4 * TCP_SND_BUF) / TCP_MSS)
#define TCP_SNDLOWAT                32768
#define TCP_QUEUE_OOSEQ             1
#define LWIP_TCP_SACK_OUT           1
#define LWIP_TCP_TIMESTAMPS         1
#define TCP_LISTEN_BACKLOG          1
#define LWIP_TCP_KEEPALIVE          1

/* ── Aléa (ISN, xid DHCP, ports) ─────────────────── */
#include <stdint.h>
uint32_t brl_rand(void);
#define LWIP_RAND()                 brl_rand()

/* ── Diagnostics ─────────────────────────────────── */
#define LWIP_STATS                  0
#define LWIP_DEBUG                  0

#endif
