/* bridge_lwip.h — API C plate entre lwIP et le code Amalgame.
 *
 * Tout est mono-thread : chaque fonction doit être appelée depuis la
 * boucle principale (celle qui appelle brl_poll()). Les objets sont
 * désignés par des handles entiers (>= 0) ; -1 = échec.
 * Adresses IPv4 en entier hôte (0xC0A80001 = 192.168.0.1).
 */
#ifndef BRIDGE_LWIP_H
#define BRIDGE_LWIP_H

#include <stdint.h>

/* Émission d'une trame Ethernet vers l'interface physique. */
typedef int (*brl_tx_fn)(void* ctx, const uint8_t* frame, int len);

/* ── Pile ───────────────────────────────────────────── */
int      brl_init(const uint8_t mac[6], int mtu, const char* hostname, brl_tx_fn tx, void* ctx);
void     brl_input(const uint8_t* frame, int len);   /* trame reçue */
void     brl_poll(void);                             /* timers lwIP */
void     brl_set_static(uint32_t ip, uint32_t mask, uint32_t gw);
void     brl_link_bounce(void);
void     brl_detach(void);
void     brl_rebind(const uint8_t mac[6], brl_tx_fn tx, void* ctx);
/* Identifiant client DHCP (option 61), à fixer avant brl_dhcp_start(). */
void     brl_set_dhcp_client_id(const uint8_t* id, int len);
int      brl_dhcp_start(void);
void     brl_dhcp_release(void);
int      brl_dhcp_state(void);   /* état lwIP (dhcp.h) ; -1 si DHCP inactif */
int      brl_dhcp_tries(void);
uint32_t brl_ip(void);
uint32_t brl_mask(void);
uint32_t brl_gw(void);
uint32_t brl_dns_server(int i);
void     brl_set_dns_server(int i, uint32_t ip);

/* ── TCP ────────────────────────────────────────────── */
/* États renvoyés par brl_tcp_state() */
#define BRL_TCP_CLOSED      0
#define BRL_TCP_CONNECTING  1
#define BRL_TCP_OPEN        2
/* Codes renvoyés par brl_tcp_error() */
#define BRL_ERR_NONE        0
#define BRL_ERR_REFUSED     1
#define BRL_ERR_TIMEOUT     2
#define BRL_ERR_RESET       3
#define BRL_ERR_OTHER       4

int  brl_tcp_connect(uint32_t ip, int port);
int  brl_tcp_state(int h);
int  brl_tcp_error(int h);
int  brl_tcp_local_port(int h);
int  brl_tcp_write_room(int h);
int  brl_tcp_write(int h, const uint8_t* data, int len);   /* octets acceptés */
int  brl_tcp_readable(int h);
int  brl_tcp_read(int h, uint8_t* out, int max);           /* octets lus */
int  brl_tcp_eof(int h);                                    /* FIN reçu et tout lu */
void brl_tcp_shutdown_write(int h);                         /* FIN après les données */
void brl_tcp_abort(int h);                                  /* RST */
void brl_tcp_release(int h);                                /* handle rendu */
int  brl_tcp_listen_echo(int port);                         /* auto-test : serveur echo */

/* ── UDP ────────────────────────────────────────────── */
int  brl_udp_open(void);
int  brl_udp_local_port(int h);
int  brl_udp_sendto(int h, uint32_t ip, int port, const uint8_t* data, int len);
int  brl_udp_recv(int h, uint32_t* ip, int* port, uint8_t* out, int max);  /* -1 si vide */
void brl_udp_close(int h);

/* ── DNS ────────────────────────────────────────────── */
int  brl_dns_query(const char* name);       /* handle */
int  brl_dns_result(int h, uint32_t* ip);   /* 0 en cours, 1 ok, -1 échec */
void brl_dns_free(int h);

#endif
