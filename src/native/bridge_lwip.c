/* bridge_lwip.c — glue entre lwIP (API raw, NO_SYS) et amalgame-bridge.
 *
 * Une seule interface réseau (celle désignée dans la config). Les
 * trames entrent par brl_input() et sortent par le callback tx fourni
 * à brl_init(). Les objets TCP/UDP/DNS sont exposés sous forme de
 * handles entiers pour rester simples à appeler depuis Amalgame.
 *
 * Contre-pression TCP : les données reçues restent en pbuf tant que
 * l'application ne les a pas lues, et tcp_recved() n'est appelé qu'à
 * la lecture — la fenêtre annoncée au pair reflète donc ce que le
 * client SOCKS consomme réellement.
 */
#include <string.h>
#include <stdlib.h>

#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <time.h>
#  include <unistd.h>
#endif

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/timeouts.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/dns.h"
#include "lwip/dhcp.h"
#include "netif/ethernet.h"

#include "bridge_lwip.h"

/* ── Plate-forme ─────────────────────────────────────── */

u32_t sys_now(void) {
#ifdef _WIN32
    return (u32_t) GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (u32_t) ((uint64_t) ts.tv_sec * 1000u + (uint64_t) ts.tv_nsec / 1000000u);
#endif
}

static uint64_t g_rand;

uint32_t brl_rand(void) {
    if (g_rand == 0) {
#ifdef _WIN32
        LARGE_INTEGER c; QueryPerformanceCounter(&c);
        g_rand = (uint64_t) c.QuadPart ^ ((uint64_t) GetCurrentProcessId() << 32);
#else
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        g_rand = ((uint64_t) ts.tv_sec << 30) ^ (uint64_t) ts.tv_nsec ^ ((uint64_t) getpid() << 48);
#endif
        g_rand |= 1;
    }
    g_rand ^= g_rand >> 12;
    g_rand ^= g_rand << 25;
    g_rand ^= g_rand >> 27;
    return (uint32_t) ((g_rand * 2685821657736338717ULL) >> 32);
}

static ip4_addr_t to_ip4(uint32_t host) {
    ip4_addr_t a;
    ip4_addr_set_u32(&a, lwip_htonl(host));
    return a;
}

static uint32_t from_ip4(const ip4_addr_t* a) {
    return a ? lwip_ntohl(ip4_addr_get_u32(a)) : 0;
}

/* ── Interface ───────────────────────────────────────── */

static struct netif g_netif;
static int          g_ready;
static brl_tx_fn    g_tx;
static void*        g_tx_ctx;
static uint8_t      g_mac[6];
static int          g_mtu = 1500;
static char         g_hostname[64] = "amalgame-bridge";

static err_t brl_linkoutput(struct netif* nif, struct pbuf* p) {
    (void) nif;
    uint8_t buf[1600];
    if (p->tot_len > sizeof buf) return ERR_BUF;
    u16_t n = pbuf_copy_partial(p, buf, p->tot_len, 0);
    if (!g_tx || g_tx(g_tx_ctx, buf, n) != 0) return ERR_IF;
    return ERR_OK;
}

static err_t brl_netif_init(struct netif* nif) {
    nif->name[0] = 'b';
    nif->name[1] = 'r';
    nif->hwaddr_len = ETH_HWADDR_LEN;
    memcpy(nif->hwaddr, g_mac, 6);
    nif->mtu = (u16_t) g_mtu;
    nif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
    nif->output = etharp_output;
    nif->linkoutput = brl_linkoutput;
    netif_set_hostname(nif, g_hostname);
    return ERR_OK;
}

int brl_init(const uint8_t mac[6], int mtu, const char* hostname, brl_tx_fn tx, void* ctx) {
    if (g_ready) return 0;
    memcpy(g_mac, mac, 6);
    if (mtu >= 576 && mtu <= 1500) g_mtu = mtu;
    if (hostname && *hostname) {
        strncpy(g_hostname, hostname, sizeof g_hostname - 1);
        g_hostname[sizeof g_hostname - 1] = 0;
    }
    g_tx = tx;
    g_tx_ctx = ctx;
    lwip_init();
    ip4_addr_t z; ip4_addr_set_zero(&z);
    if (!netif_add(&g_netif, &z, &z, &z, NULL, brl_netif_init, ethernet_input)) return -1;
    netif_set_default(&g_netif);
    netif_set_link_up(&g_netif);
    netif_set_up(&g_netif);
    g_ready = 1;
    return 0;
}

void brl_input(const uint8_t* frame, int len) {
    if (!g_ready || len <= 0 || len > 1600) return;
    struct pbuf* p = pbuf_alloc(PBUF_RAW, (u16_t) len, PBUF_POOL);
    if (!p) return;
    if (pbuf_take(p, frame, (u16_t) len) != ERR_OK || g_netif.input(p, &g_netif) != ERR_OK)
        pbuf_free(p);
}

void brl_poll(void) {
    if (!g_ready) return;
    netif_poll(&g_netif);       /* boucle locale (connexions vers notre IP) */
    sys_check_timeouts();
}

void brl_set_static(uint32_t ip, uint32_t mask, uint32_t gw) {
    ip4_addr_t a = to_ip4(ip), m = to_ip4(mask), g = to_ip4(gw);
    netif_set_addr(&g_netif, &a, &m, &g);
}

static uint8_t g_cid[64];
static int     g_cid_len;

void brl_set_dhcp_client_id(const uint8_t* id, int len) {
    if (len < 0) len = 0;
    if (len > (int) sizeof g_cid) len = (int) sizeof g_cid;
    if (len > 0) memcpy(g_cid, id, (size_t) len);
    g_cid_len = len;
}

int brl_dhcp_client_id(const uint8_t** out) {
    *out = g_cid;
    return g_cid_len;
}

int brl_dhcp_start(void) {
    return dhcp_start(&g_netif) == ERR_OK ? 0 : -1;
}

int brl_dhcp_state(void) {
    struct dhcp* d = netif_dhcp_data(&g_netif);
    return d ? d->state : -1;
}

int brl_dhcp_tries(void) {
    struct dhcp* d = netif_dhcp_data(&g_netif);
    return d ? d->tries : 0;
}

void brl_dhcp_release(void) {
    if (netif_dhcp_data(&g_netif)) dhcp_release_and_stop(&g_netif);
}

uint32_t brl_ip(void)   { return from_ip4(netif_ip4_addr(&g_netif)); }
uint32_t brl_mask(void) { return from_ip4(netif_ip4_netmask(&g_netif)); }
uint32_t brl_gw(void)   { return from_ip4(netif_ip4_gw(&g_netif)); }

uint32_t brl_dns_server(int i) {
    const ip_addr_t* a = dns_getserver((u8_t) i);
    return a ? from_ip4(ip_2_ip4(a)) : 0;
}

void brl_set_dns_server(int i, uint32_t ip) {
    ip_addr_t a;
    ip4_addr_set_u32(ip_2_ip4(&a), lwip_htonl(ip));
    dns_setserver((u8_t) i, &a);
}

/* ── TCP ─────────────────────────────────────────────── */

#define BRL_MAX_TCP 1024

typedef struct {
    int             used;
    struct tcp_pcb* pcb;
    int             state;
    int             err;
    struct pbuf*    rx;
    int             rx_len;
    int             eof;
    int             shut;
    int             lport;
} brl_tcp_t;

static brl_tcp_t g_tcp[BRL_MAX_TCP];

static brl_tcp_t* tcp_slot(int h) {
    if (h < 0 || h >= BRL_MAX_TCP || !g_tcp[h].used) return NULL;
    return &g_tcp[h];
}

static void tcp_detach(struct tcp_pcb* pcb) {
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_err(pcb, NULL);
}

static err_t on_connected(void* arg, struct tcp_pcb* pcb, err_t err) {
    brl_tcp_t* s = tcp_slot((int)(intptr_t) arg);
    if (!s) return ERR_OK;
    if (err != ERR_OK) { s->state = BRL_TCP_CLOSED; s->err = BRL_ERR_OTHER; return ERR_OK; }
    s->state = BRL_TCP_OPEN;
    s->lport = pcb->local_port;
    return ERR_OK;
}

static err_t on_recv(void* arg, struct tcp_pcb* pcb, struct pbuf* p, err_t err) {
    (void) pcb; (void) err;
    brl_tcp_t* s = tcp_slot((int)(intptr_t) arg);
    if (!s) { if (p) pbuf_free(p); return ERR_OK; }
    if (!p) { s->eof = 1; return ERR_OK; }
    if (s->rx) pbuf_cat(s->rx, p); else s->rx = p;
    s->rx_len += p->tot_len;
    return ERR_OK;
}

static void on_err(void* arg, err_t err) {
    /* lwIP a déjà libéré le pcb. */
    brl_tcp_t* s = tcp_slot((int)(intptr_t) arg);
    if (!s) return;
    s->pcb = NULL;
    if (s->state == BRL_TCP_CONNECTING)
        s->err = err == ERR_RST ? BRL_ERR_REFUSED : err == ERR_ABRT ? BRL_ERR_TIMEOUT : BRL_ERR_OTHER;
    else if (err == ERR_RST)
        s->err = BRL_ERR_RESET;
    else if (err == ERR_ABRT)
        s->err = BRL_ERR_TIMEOUT;
    else if (err != ERR_CLSD)
        s->err = BRL_ERR_OTHER;
    s->state = BRL_TCP_CLOSED;
    s->eof = 1;
}

/* Après release : on avale ce qui arrive encore jusqu'à la fermeture. */
static err_t on_recv_discard(void* arg, struct tcp_pcb* pcb, struct pbuf* p, err_t err) {
    (void) arg; (void) err;
    if (p) { tcp_recved(pcb, p->tot_len); pbuf_free(p); }
    return ERR_OK;
}

int brl_tcp_connect(uint32_t ip, int port) {
    if (!g_ready) return -1;
    int h = -1;
    for (int i = 0; i < BRL_MAX_TCP; i++) if (!g_tcp[i].used) { h = i; break; }
    if (h < 0) return -1;
    struct tcp_pcb* pcb = tcp_new();
    if (!pcb) return -1;
    memset(&g_tcp[h], 0, sizeof g_tcp[h]);
    g_tcp[h].used = 1;
    g_tcp[h].pcb = pcb;
    g_tcp[h].state = BRL_TCP_CONNECTING;
    tcp_arg(pcb, (void*)(intptr_t) h);
    tcp_recv(pcb, on_recv);
    tcp_err(pcb, on_err);
    tcp_nagle_disable(pcb);
    ip_addr_t dst;
    ip4_addr_set_u32(ip_2_ip4(&dst), lwip_htonl(ip));
    if (tcp_connect(pcb, &dst, (u16_t) port, on_connected) != ERR_OK) {
        tcp_detach(pcb);
        tcp_abort(pcb);
        g_tcp[h].used = 0;
        return -1;
    }
    g_tcp[h].lport = pcb->local_port;
    return h;
}

int brl_tcp_state(int h)      { brl_tcp_t* s = tcp_slot(h); return s ? s->state : BRL_TCP_CLOSED; }
int brl_tcp_error(int h)      { brl_tcp_t* s = tcp_slot(h); return s ? s->err : BRL_ERR_OTHER; }
int brl_tcp_local_port(int h) { brl_tcp_t* s = tcp_slot(h); return s ? s->lport : 0; }
int brl_tcp_readable(int h)   { brl_tcp_t* s = tcp_slot(h); return s ? s->rx_len : 0; }
int brl_tcp_eof(int h)        { brl_tcp_t* s = tcp_slot(h); return !s || (s->eof && s->rx_len == 0); }

int brl_tcp_write_room(int h) {
    brl_tcp_t* s = tcp_slot(h);
    if (!s || !s->pcb || s->state != BRL_TCP_OPEN || s->shut) return 0;
    if (tcp_sndqueuelen(s->pcb) >= TCP_SND_QUEUELEN - 4) return 0;
    return (int) tcp_sndbuf(s->pcb);
}

int brl_tcp_write(int h, const uint8_t* data, int len) {
    brl_tcp_t* s = tcp_slot(h);
    int room = brl_tcp_write_room(h);
    if (!s || room <= 0 || len <= 0) return 0;
    int n = len < room ? len : room;
    int done = 0;
    while (done < n) {
        int chunk = n - done;
        if (chunk > 0x8000) chunk = 0x8000;      /* tcp_write prend un u16 */
        if (tcp_write(s->pcb, data + done, (u16_t) chunk, TCP_WRITE_FLAG_COPY) != ERR_OK) break;
        done += chunk;
    }
    if (done > 0) tcp_output(s->pcb);
    return done;
}

int brl_tcp_read(int h, uint8_t* out, int max) {
    brl_tcp_t* s = tcp_slot(h);
    if (!s || !s->rx || max <= 0) return 0;
    int n = s->rx_len < max ? s->rx_len : max;
    if (n > 0xFFFF) n = 0xFFFF;
    u16_t got = pbuf_copy_partial(s->rx, out, (u16_t) n, 0);
    s->rx = pbuf_free_header(s->rx, got);
    s->rx_len -= got;
    if (s->pcb && got > 0) tcp_recved(s->pcb, got);   /* rouvre la fenêtre */
    return got;
}

void brl_tcp_shutdown_write(int h) {
    brl_tcp_t* s = tcp_slot(h);
    if (!s || s->shut) return;
    s->shut = 1;
    if (s->pcb && s->state == BRL_TCP_OPEN) {
        tcp_shutdown(s->pcb, 0, 1);
        tcp_output(s->pcb);
    }
}

void brl_tcp_abort(int h) {
    brl_tcp_t* s = tcp_slot(h);
    if (!s) return;
    if (s->pcb) { tcp_detach(s->pcb); tcp_abort(s->pcb); s->pcb = NULL; }
    s->state = BRL_TCP_CLOSED;
    s->eof = 1;
}

void brl_tcp_release(int h) {
    brl_tcp_t* s = tcp_slot(h);
    if (!s) return;
    if (s->pcb) {
        struct tcp_pcb* pcb = s->pcb;
        tcp_detach(pcb);
        if (s->state == BRL_TCP_OPEN) {
            tcp_recv(pcb, on_recv_discard);
            if (tcp_close(pcb) != ERR_OK) tcp_abort(pcb);
        } else {
            tcp_abort(pcb);
        }
    }
    if (s->rx) pbuf_free(s->rx);
    memset(s, 0, sizeof *s);
}

/* Serveur echo (auto-test bout en bout via la boucle locale). */
static err_t echo_recv(void* arg, struct tcp_pcb* pcb, struct pbuf* p, err_t err) {
    (void) arg; (void) err;
    if (!p) { tcp_close(pcb); return ERR_OK; }
    for (struct pbuf* q = p; q; q = q->next)
        tcp_write(pcb, q->payload, q->len, TCP_WRITE_FLAG_COPY);
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    tcp_output(pcb);
    return ERR_OK;
}

static err_t echo_accept(void* arg, struct tcp_pcb* pcb, err_t err) {
    (void) arg;
    if (err != ERR_OK || !pcb) return ERR_VAL;
    tcp_recv(pcb, echo_recv);
    return ERR_OK;
}

int brl_tcp_listen_echo(int port) {
    struct tcp_pcb* pcb = tcp_new();
    if (!pcb) return -1;
    if (tcp_bind(pcb, IP_ANY_TYPE, (u16_t) port) != ERR_OK) { tcp_abort(pcb); return -1; }
    struct tcp_pcb* l = tcp_listen(pcb);
    if (!l) return -1;
    tcp_accept(l, echo_accept);
    return 0;
}

/* ── UDP ─────────────────────────────────────────────── */

#define BRL_MAX_UDP 64
#define BRL_UDP_Q   64

typedef struct { uint32_t ip; int port; int len; uint8_t* data; } brl_dgram_t;
typedef struct {
    int             used;
    struct udp_pcb* pcb;
    brl_dgram_t     q[BRL_UDP_Q];
    int             head, count;
} brl_udp_t;

static brl_udp_t g_udp[BRL_MAX_UDP];

static brl_udp_t* udp_slot(int h) {
    if (h < 0 || h >= BRL_MAX_UDP || !g_udp[h].used) return NULL;
    return &g_udp[h];
}

static void on_udp(void* arg, struct udp_pcb* pcb, struct pbuf* p, const ip_addr_t* addr, u16_t port) {
    (void) pcb;
    brl_udp_t* s = udp_slot((int)(intptr_t) arg);
    if (!s) { pbuf_free(p); return; }
    if (s->count == BRL_UDP_Q) {              /* file pleine : on jette le plus ancien */
        free(s->q[s->head].data);
        s->head = (s->head + 1) % BRL_UDP_Q;
        s->count--;
    }
    brl_dgram_t* d = &s->q[(s->head + s->count) % BRL_UDP_Q];
    d->data = (uint8_t*) malloc(p->tot_len ? p->tot_len : 1);
    if (!d->data) { pbuf_free(p); return; }
    d->len = pbuf_copy_partial(p, d->data, p->tot_len, 0);
    d->ip = from_ip4(ip_2_ip4(addr));
    d->port = port;
    s->count++;
    pbuf_free(p);
}

int brl_udp_open(void) {
    if (!g_ready) return -1;
    int h = -1;
    for (int i = 0; i < BRL_MAX_UDP; i++) if (!g_udp[i].used) { h = i; break; }
    if (h < 0) return -1;
    struct udp_pcb* pcb = udp_new();
    if (!pcb) return -1;
    if (udp_bind(pcb, IP_ANY_TYPE, 0) != ERR_OK) { udp_remove(pcb); return -1; }
    memset(&g_udp[h], 0, sizeof g_udp[h]);
    g_udp[h].used = 1;
    g_udp[h].pcb = pcb;
    udp_recv(pcb, on_udp, (void*)(intptr_t) h);
    return h;
}

int brl_udp_local_port(int h) { brl_udp_t* s = udp_slot(h); return s ? s->pcb->local_port : 0; }

int brl_udp_sendto(int h, uint32_t ip, int port, const uint8_t* data, int len) {
    brl_udp_t* s = udp_slot(h);
    if (!s || len < 0 || len > 65507) return -1;
    struct pbuf* p = pbuf_alloc(PBUF_TRANSPORT, (u16_t) len, PBUF_RAM);
    if (!p) return -1;
    memcpy(p->payload, data, (size_t) len);
    ip_addr_t dst;
    ip4_addr_set_u32(ip_2_ip4(&dst), lwip_htonl(ip));
    err_t e = udp_sendto(s->pcb, p, &dst, (u16_t) port);
    pbuf_free(p);
    return e == ERR_OK ? 0 : -1;
}

int brl_udp_recv(int h, uint32_t* ip, int* port, uint8_t* out, int max) {
    brl_udp_t* s = udp_slot(h);
    if (!s || s->count == 0) return -1;
    brl_dgram_t* d = &s->q[s->head];
    int n = d->len < max ? d->len : max;
    memcpy(out, d->data, (size_t) n);
    *ip = d->ip;
    *port = d->port;
    free(d->data);
    s->head = (s->head + 1) % BRL_UDP_Q;
    s->count--;
    return n;
}

void brl_udp_close(int h) {
    brl_udp_t* s = udp_slot(h);
    if (!s) return;
    udp_remove(s->pcb);
    while (s->count > 0) { free(s->q[s->head].data); s->head = (s->head + 1) % BRL_UDP_Q; s->count--; }
    memset(s, 0, sizeof *s);
}

/* ── DNS ─────────────────────────────────────────────── */

#define BRL_MAX_DNS 256

typedef struct { int used; int gen; int state; uint32_t ip; } brl_dns_t;
static brl_dns_t g_dns[BRL_MAX_DNS];
static int       g_dns_gen;

static void on_dns(const char* name, const ip_addr_t* addr, void* arg) {
    (void) name;
    intptr_t v = (intptr_t) arg;
    int h = (int)(v & 0xFFFF), gen = (int)(v >> 16);
    if (h < 0 || h >= BRL_MAX_DNS || !g_dns[h].used || g_dns[h].gen != gen) return;  /* handle déjà rendu */
    if (addr) { g_dns[h].ip = from_ip4(ip_2_ip4(addr)); g_dns[h].state = 1; }
    else g_dns[h].state = -1;
}

int brl_dns_query(const char* name) {
    int h = -1;
    for (int i = 0; i < BRL_MAX_DNS; i++) if (!g_dns[i].used) { h = i; break; }
    if (h < 0 || !name) return -1;
    g_dns_gen = (g_dns_gen + 1) & 0x7FFF;
    g_dns[h].used = 1;
    g_dns[h].gen = g_dns_gen;
    g_dns[h].state = 0;
    g_dns[h].ip = 0;
    ip_addr_t a;
    err_t e = dns_gethostbyname(name, &a, on_dns, (void*)(((intptr_t) g_dns_gen << 16) | h));
    if (e == ERR_OK) { g_dns[h].ip = from_ip4(ip_2_ip4(&a)); g_dns[h].state = 1; }
    else if (e != ERR_INPROGRESS) g_dns[h].state = -1;
    return h;
}

int brl_dns_result(int h, uint32_t* ip) {
    if (h < 0 || h >= BRL_MAX_DNS || !g_dns[h].used) return -1;
    if (g_dns[h].state == 1) *ip = g_dns[h].ip;
    return g_dns[h].state;
}

void brl_dns_free(int h) {
    if (h >= 0 && h < BRL_MAX_DNS) g_dns[h].used = 0;
}
