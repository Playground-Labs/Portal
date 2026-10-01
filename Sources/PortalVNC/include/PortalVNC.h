#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct PortalVNC PortalVNC;
typedef struct { uint32_t id; int x, y, width, height; } PortalScreen;
typedef struct {
    void *context;
    void (*input)(void *); /* Drain queued input on the VNC worker during reads; never destroy/reconfigure the client here. */
    void (*frame)(void *, const uint8_t *, int, int);
    void (*cursor)(void *, const uint8_t *, int, int, int, int); /* RGBA, width/height, hotspot; NULL hides the cursor. */
    void (*clipboard)(void *, const char *, int, int);
    void (*layout)(void *, const PortalScreen *, int, int);
    void (*audio)(void *, const uint8_t *, int); /* NULL/0 announces availability; PCM is S16 LE, stereo, 44100 Hz. */
    int (*credentials)(void *, int, char **, char **); /* Return malloc-owned username/password; kind 1=password, 2=user. */
    int (*authorize)(void *, int, const char *); /* 1=unencrypted; 2=certificate fingerprint; 3=RSA key SHA-256 fingerprint. */
} PortalCallbacks;

PortalVNC *portal_vnc_create(PortalCallbacks callbacks);
int portal_vnc_connect(PortalVNC *, const char *host, int port, int tunneled, int quality, const char *fingerprint);
int portal_vnc_poll(PortalVNC *); /* -1=disconnected/error, 0=idle, 1=message */
int portal_vnc_pointer(PortalVNC *, int x, int y, int buttons);
int portal_vnc_key(PortalVNC *, uint32_t key, int down);
int portal_vnc_clipboard(PortalVNC *, const char *text, int length);
int portal_vnc_resize(PortalVNC *, int width, int height);
int portal_vnc_audio(PortalVNC *, int enabled);
int portal_vnc_quality(PortalVNC *, int quality);
int portal_vnc_encrypted(PortalVNC *);
const char *portal_vnc_error(PortalVNC *);
void portal_vnc_destroy(PortalVNC *);
