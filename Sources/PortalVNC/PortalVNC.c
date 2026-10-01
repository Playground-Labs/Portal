#include "PortalVNC.h"
#include <rfb/rfbclient.h>
#include "RSAAuth.h"
#include <openssl/provider.h>
#include <openssl/ssl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <iconv.h>
#include <time.h>

struct PortalVNC {
    PortalCallbacks cb;
    rfbClient *client;
    int tunneled, authorized, fatal, ready, audio, screenCount;
    char error[512];
    char *saslUser, *saslPassword;
    uint8_t fingerprint[32];
    int hasFingerprint;
    int automaticQuality, frameCount, frameDirty, continuousSupported;
    uint64_t updates;
    double updateSeconds;
};
static char tag;
static _Thread_local PortalVNC *active;
static void clear_log_scope(PortalVNC **scope) { active=*scope; }
#define LOG_SCOPE(value) PortalVNC *log_scope __attribute__((cleanup(clear_log_scope))) = active; active=(value)
static PortalVNC *owner(rfbClient *c) { return rfbClientGetClientData(c, &tag); }
static void log_message(const char *format, ...) {
    if (!active) return;
    va_list args; va_start(args, format);
    vsnprintf(active->error, sizeof(active->error), format, args); va_end(args);
}
static void diagnostic_log(const char *format, ...) {
    const char *prefix = "Unknown authentication scheme from VNC server: ";
    if (!active || strncmp(format, prefix, strlen(prefix)) != 0) return;
    char diagnostic[512];
    va_list args; va_start(args, format);
    vsnprintf(diagnostic, sizeof(diagnostic), format, args); va_end(args);
    snprintf(active->error, sizeof(active->error),
                 "This server requires authentication Portal does not support (types %.*s). Use a server authentication method compatible with Portal.",
                 (int)strcspn(diagnostic + strlen(prefix), "\r\n"), diagnostic + strlen(prefix));
}
static int fail(PortalVNC *p, const char *message) {
    p->fatal = 1; snprintf(p->error, sizeof(p->error), "%s", message); return 0;
}
static int valid_size(int w, int h) { return w > 0 && h > 0 && w <= 16384 && h <= 16384 && (uint64_t)w*h <= 33554432; }
static rfbBool stream_updates(rfbClient *c) {
    const uint8_t message[]={150,1,0,0,0,0,c->width>>8,c->width&255,c->height>>8,c->height&255};
    if(!WriteToRFBServer(c,(const char *)message,sizeof(message))) return fail(owner(c),"Could not request continuous screen updates.");
    c->portalContinuousUpdates=TRUE;
    return TRUE;
}
static rfbBool allocate(rfbClient *c) {
    PortalVNC *p = owner(c);
    if (!valid_size(c->width,c->height)) return fail(p,"The remote desktop is too large or has invalid dimensions.");
    uint8_t *buffer = calloc((size_t)c->width*c->height,4);
    if (!buffer) return fail(p,"Not enough memory for the remote desktop.");
    free(c->frameBuffer); c->frameBuffer = buffer; p->frameDirty=1;
    return !c->portalContinuousUpdates || stream_updates(c);
}
static int authorize(PortalVNC *p) {
    if (p->authorized || p->tunneled || p->client->tlsSession || p->client->portalRead || p->client->saslconn) return 1;
    if (!p->cb.authorize || !p->cb.authorize(p->cb.context,1,"This connection is not encrypted.")) return fail(p,"Connection cancelled.");
    p->authorized = 1; return 1;
}
static char *sasl_user(rfbClient *c);
static char *password(rfbClient *c) {
    PortalVNC *p=owner(c); char *user=NULL,*pass=NULL;
    if((c->authScheme==rfbSASL || c->subAuthScheme==rfbVeNCryptX509SASL || c->subAuthScheme==rfbVeNCryptTLSSASL) && !p->saslPassword && !sasl_user(c)) return NULL;
    if(p->saslPassword) { pass=p->saslPassword; p->saslPassword=NULL; return pass; }
    if (!authorize(p) || !p->cb.credentials || !p->cb.credentials(p->cb.context,1,&user,&pass)) { free(user); free(pass); return NULL; }
    free(user); return pass;
}
static char *sasl_user(rfbClient *c) {
    PortalVNC *p=owner(c);
    if(!p->saslUser && (!p->cb.credentials || !p->cb.credentials(p->cb.context,2,&p->saslUser,&p->saslPassword))) return NULL;
    return p->saslUser;
}
static rfbCredential *credential(rfbClient *c,int kind) {
    PortalVNC *p=owner(c); rfbCredential *cred=calloc(1,sizeof(*cred));
    if (!cred) return NULL;
    if (kind == rfbCredentialTypeX509) {
        if(p->hasFingerprint) { cred->x509Credential.x509ExpectedFingerprint=malloc(32); if(!cred->x509Credential.x509ExpectedFingerprint) { free(cred); return NULL; } memcpy(cred->x509Credential.x509ExpectedFingerprint,p->fingerprint,32); }
        return cred;
    }
    if(kind != rfbCredentialTypeUser || !authorize(p) || !p->cb.credentials || !p->cb.credentials(p->cb.context,2,&cred->userCredential.username,&cred->userCredential.password)) {
        free(cred->userCredential.username); free(cred->userCredential.password); free(cred); return NULL;
    }
    return cred;
}
static rfbBool certificate(rfbClient *c,const char *subject,time_t from,time_t until,const uint8_t *hash,size_t length) {
    PortalVNC *p=owner(c); char text[65];
    if(length!=32) return FALSE;
    for(int i=0;i<32;i++) snprintf(text+i*2,3,"%02x",hash[i]);
    return p->cb.authorize && p->cb.authorize(p->cb.context,2,text);
}
static void pump_input(rfbClient *c) {
    PortalVNC *p=owner(c);
    if(p->ready && !p->fatal && p->cb.input) p->cb.input(p->cb.context);
}
static void cursor(rfbClient *c, int x, int y, int width, int height, int bytesPerPixel) {
    PortalVNC *p=owner(c);
    if(!p->cb.cursor) return;
    if(width==0 || height==0) { p->cb.cursor(p->cb.context,NULL,0,0,0,0); return; }
    if(bytesPerPixel!=4 || !c->rcSource || !c->rcMask) return;
    for(int i=0;i<width*height;i++) c->rcSource[i*4+3]=c->rcMask[i]?255:0;
    p->cb.cursor(p->cb.context,c->rcSource,width,height,x,y);
}
static void damage(rfbClient *c, int x, int y, int width, int height) {
    (void)x; (void)y;
    if(width>0 && height>0) owner(c)->frameDirty=1;
}
static void frame(rfbClient *c) {
    PortalVNC *p=owner(c);
    if(!p->frameDirty) return;
    p->frameDirty=0; p->updates++;
    if(p->cb.frame) p->cb.frame(p->cb.context,c->frameBuffer,c->width,c->height);
}
static void clipboard(rfbClient *c,const char *text,int length) { PortalVNC *p=owner(c); if(length>=0 && length<=1048576 && p->cb.clipboard) p->cb.clipboard(p->cb.context,text,length,0); }
static void clipboard_utf8(rfbClient *c,const char *text,int length) { PortalVNC *p=owner(c); if(length>=0 && length<=1048576 && p->cb.clipboard) p->cb.clipboard(p->cb.context,text,length,1); }
static rfbBool encoding(rfbClient *c,rfbFramebufferUpdateRectHeader *rect) {
    PortalVNC *p=owner(c);
    if(rect->encoding == -259) { p->audio=1; if(p->cb.audio) p->cb.audio(p->cb.context,NULL,0); return TRUE; }
    if(rect->encoding != rfbEncodingExtDesktopSize) return FALSE;
    uint8_t header[4]; PortalScreen screens[255]; rfbExtDesktopScreen raw;
    if(!ReadFromRFBServer(c,(char*)header,4)) { fail(p,"Incomplete display layout."); return TRUE; }
    int count=header[0], valid=count>0 && valid_size(rect->r.w,rect->r.h);
    for(int i=0;i<count;i++) {
        if(!ReadFromRFBServer(c,(char*)&raw,sizeof(raw))) { fail(p,"Incomplete display layout."); return TRUE; }
        screens[i]=(PortalScreen){ntohl(raw.id),ntohs(raw.x),ntohs(raw.y),ntohs(raw.width),ntohs(raw.height)};
        PortalScreen s=screens[i];
        if(!s.width || !s.height || s.x+s.width>rect->r.w || s.y+s.height>rect->r.h) valid=0;
        if(count==1) c->screen=raw;
    }
    c->requestedResize=FALSE;
    if(rect->r.x==1 && rect->r.y!=0) { if(p->cb.layout) p->cb.layout(p->cb.context,screens,0,0); return TRUE; }
    if(!valid) { fail(p,"Invalid remote display layout."); return TRUE; }
    p->screenCount=count;
    if(c->width!=rect->r.w || c->height!=rect->r.h) {
        c->width=rect->r.w; c->height=rect->r.h;
        c->updateRect.x=c->updateRect.y=0; c->updateRect.w=c->width; c->updateRect.h=c->height;
        if(!allocate(c)) return TRUE;
    }
    if(p->cb.layout) p->cb.layout(p->cb.context,screens,count,count==1);
    return TRUE;
}
static rfbBool message(rfbClient *c,rfbServerToClientMsg *msg) {
    if(msg->type==150) {
        PortalVNC *p=owner(c);
        if(!p->continuousSupported) {
            p->continuousSupported=1;
            stream_updates(c);
        } else {
            c->portalContinuousUpdates=FALSE;
            if(!SendIncrementalFramebufferUpdateRequest(c)) fail(p,"Could not resume screen updates.");
        }
        return TRUE;
    }
    if(msg->type!=255) return FALSE;
    PortalVNC *p=owner(c); uint8_t head[3];
    if(!ReadFromRFBServer(c,(char*)head,3) || head[0]!=1) { fail(p,"Invalid audio message."); return TRUE; }
    int operation=(head[1]<<8)|head[2];
    if(operation==0 || operation==1) return TRUE;
    uint32_t networkLength;
    if(operation!=2 || !ReadFromRFBServer(c,(char*)&networkLength,4)) { fail(p,"Invalid audio message."); return TRUE; }
    uint32_t length=ntohl(networkLength);
    if(length>1048576 || length%4) { fail(p,"Invalid audio packet size."); return TRUE; }
    uint8_t *data=malloc(length ? length : 1);
    if(!data || !ReadFromRFBServer(c,(char*)data,length)) { free(data); fail(p,"Incomplete audio packet."); return TRUE; }
    if(length && p->cb.audio) p->cb.audio(p->cb.context,data,length);
    free(data); return TRUE;
}
static rfbBool rsa_auth(rfbClient *c,uint32_t scheme) {
    PortalVNC *p=owner(c); return portal_rsa_auth(c,scheme,p->cb,p->error,sizeof(p->error));
}
static const uint32_t securityTypes[]={129,5,130,6,0};
static int encodings[]={-259,rfbEncodingExtDesktopSize,-313,0};
static rfbClientProtocolExtension extension={.encodings=encodings,.handleEncoding=encoding,.handleMessage=message,.securityTypes=securityTypes,.handleAuthentication=rsa_auth};
static pthread_once_t registration=PTHREAD_ONCE_INIT;
static OSSL_PROVIDER *defaultProvider;
static void register_extension(void) { defaultProvider=OSSL_PROVIDER_load(NULL,"default"); rfbClientRegisterExtension(&extension); rfbClientLog=diagnostic_log; rfbClientErr=log_message; }
PortalVNC *portal_vnc_create(PortalCallbacks cb) { LOG_SCOPE(NULL);
    pthread_once(&registration,register_extension);
    if(!defaultProvider) return NULL;
    PortalVNC *p=calloc(1,sizeof(*p)); if(!p) return NULL;
    p->cb=cb; p->client=rfbGetClient(8,3,4);
    if(!p->client) { free(p); return NULL; }
    rfbClient *c=p->client; rfbClientSetClientData(c,&tag,p);
    c->portalPumpInput=pump_input; c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=damage; c->FinishedFrameBufferUpdate=frame;
    c->GotXCutText=clipboard; c->GotXCutTextUTF8=clipboard_utf8;
    c->GetPassword=password; c->GetUser=sasl_user; c->GetCredential=credential; c->GetX509CertFingerprintMismatchDecision=certificate;
    c->canHandleNewFBSize=TRUE; c->connectTimeout=8; c->readTimeout=8;
    c->format.bigEndian=FALSE; c->format.redShift=0; c->format.greenShift=8; c->format.blueShift=16;
    c->GotCursorShape=cursor; c->appData.useRemoteCursor=p->cb.cursor!=NULL; c->appData.compressLevel=1;
    return p;
}
int portal_vnc_connect(PortalVNC *p,const char *host,int port,int tunnel,int quality,const char *fingerprint) { LOG_SCOPE(p);
    if(!p || !host || port<1 || port>65535 || p->ready) return 0;
    active=p; rfbClient *c=p->client; p->tunneled=tunnel; c->portalExternalSSF=tunnel?128:0;
    if(fingerprint && strlen(fingerprint)==64) {
        p->hasFingerprint=1;
        for(int i=0;i<32;i++) { unsigned int value; if(sscanf(fingerprint+i*2,"%2x",&value)!=1) { p->hasFingerprint=0; break; } p->fingerprint[i]=value; }
    }
    free(c->serverHost); c->serverHost=strdup(host); c->serverPort=port; p->automaticQuality=quality<0; c->appData.qualityLevel=quality<0 ? 6 : quality;
    if(!rfbClientConnect(c) || !InitialiseRFBConnection(c) || !authorize(p)) return 0;
    c->width=c->si.framebufferWidth; c->height=c->si.framebufferHeight;
    if(!allocate(c) || !SetFormatAndEncodings(c)) return 0;
    c->updateRect.x=c->updateRect.y=0; c->updateRect.w=c->width; c->updateRect.h=c->height; c->isUpdateRectManagedByLib=TRUE;
    p->ready=!!SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE); return p->ready;
}
int portal_vnc_poll(PortalVNC *p) { LOG_SCOPE(p);
    if(!p || !p->ready || p->fatal) return -1;
    active=p; int result=(p->client->buffered || portal_rsa_pending(p->client) || (p->client->tlsSession && SSL_pending(p->client->tlsSession)) || p->client->saslDecodedLength>p->client->saslDecodedOffset) ? 1 : WaitForMessage(p->client,0);
    uint64_t previousUpdates=p->updates;
    struct timespec start,end; clock_gettime(CLOCK_MONOTONIC,&start);
    int handled=result<=0 || HandleRFBServerMessage(p->client);
    clock_gettime(CLOCK_MONOTONIC,&end);
    if(p->updates!=previousUpdates && p->automaticQuality) {
        p->updateSeconds+=(end.tv_sec-start.tv_sec)+(end.tv_nsec-start.tv_nsec)/1e9;
        if(++p->frameCount==30) {
            double average=p->updateSeconds/30;
            int quality=average>0.15 ? 3 : (average<0.04 ? 9 : 6);
            p->frameCount=0; p->updateSeconds=0;
            if(quality!=p->client->appData.qualityLevel) { p->client->appData.qualityLevel=quality; if(!SetFormatAndEncodings(p->client)) handled=0; }
        }
    }
    if(result<0 || !handled || p->fatal) { p->ready=0; return -1; }
    return result>0;
}
int portal_vnc_pointer(PortalVNC *p,int x,int y,int buttons) { LOG_SCOPE(p); return p && p->ready && x>=0 && y>=0 && x<p->client->width && y<p->client->height && SendPointerEvent(p->client,x,y,buttons); }
int portal_vnc_key(PortalVNC *p,uint32_t key,int down) { LOG_SCOPE(p); return p && p->ready && SendKeyEvent(p->client,key,down); }
int portal_vnc_clipboard(PortalVNC *p,const char *text,int length) { LOG_SCOPE(p);
    if(!p || !p->ready || !text || length<0 || length>1048576) return 0;
    if(p->client->extendedClipboardServerCapabilities) return !!SendClientCutTextUTF8(p->client,(char*)text,length);
    iconv_t converter=iconv_open("ISO-8859-1","UTF-8");
    if(converter==(iconv_t)-1) return 0;
    char *buffer=malloc((size_t)length+1), *input=(char*)text, *output=buffer;
    if(!buffer) { iconv_close(converter); return 0; }
    size_t remaining=length, capacity=length;
    int converted=iconv(converter,&input,&remaining,&output,&capacity)!=(size_t)-1;
    int sent=converted && SendClientCutText(p->client,buffer,(int)(output-buffer));
    iconv_close(converter); free(buffer); return sent;
}
int portal_vnc_resize(PortalVNC *p,int width,int height) { LOG_SCOPE(p); return p && p->ready && p->screenCount==1 && valid_size(width,height) && SendExtDesktopSize(p->client,width,height); }
int portal_vnc_audio(PortalVNC *p,int enabled) { LOG_SCOPE(p);
    if(!p || !p->ready || !p->audio) return 0;
    const char format[]={255,1,0,2,3,2,0,0,172,68}; const char command[]={255,1,0,enabled?0:1};
    return (!enabled || WriteToRFBServer(p->client,format,sizeof(format))) && WriteToRFBServer(p->client,command,sizeof(command));
}
int portal_vnc_quality(PortalVNC *p,int quality) { LOG_SCOPE(p); if(!p || !p->ready || quality < -1 || quality>9) return 0; p->automaticQuality=quality<0; p->client->appData.qualityLevel=quality<0 ? 6 : quality; return !!SetFormatAndEncodings(p->client); }
int portal_vnc_encrypted(PortalVNC *p) { LOG_SCOPE(p); return p && (p->tunneled || p->client->tlsSession!=NULL || p->client->portalRead!=NULL || p->client->saslconn!=NULL); }
const char *portal_vnc_error(PortalVNC *p) { LOG_SCOPE(p); return p && p->error[0] ? p->error : "The connection closed unexpectedly."; }
void portal_vnc_destroy(PortalVNC *p) { LOG_SCOPE(p); if(!p) return; if(p->client) { portal_rsa_destroy(p->client); free(p->client->frameBuffer); p->client->frameBuffer=NULL; rfbClientCleanup(p->client); } free(p->saslUser); if(p->saslPassword) { OPENSSL_cleanse(p->saslPassword,strlen(p->saslPassword)); free(p->saslPassword); } if(active==p) active=NULL; free(p); }
