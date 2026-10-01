#pragma once
#include <rfb/rfbclient.h>
#include "PortalVNC.h"
int portal_rsa_auth(rfbClient *, unsigned int, PortalCallbacks, char *, size_t);
int portal_rsa_pending(rfbClient *);
void portal_rsa_destroy(rfbClient *);
