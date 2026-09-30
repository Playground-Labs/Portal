#include "PortalVNC.h"
#include <rfb/rfbclient.h>
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
    uint8_t fingerprint[32];
    int hasFingerprint;
    int automaticQuality, frameCount;
    uint64_t updates;
    double updateSeconds;
};
static void quiet_log(const char *format, ...) {}
static char tag;
static _Thread_local PortalVNC *active;
static PortalVNC *owner(rfbClient *c) { return rfbClientGetClientData(c, &tag); }
static void log_message(const char *format, ...) {
    if (!active) return;
    va_list args; va_start(args, format);
    vsnprintf(active->error, sizeof(active->error), format, args); va_end(args);
}
static int fail(PortalVNC *p, const char *message) {
    p->fatal = 1; snprintf(p->error, sizeof(p->error), "%s", message); return 0;
}
static int valid_size(int w, int h) { return w > 0 && h > 0 && w <= 16384 && h <= 16384 && (uint64_t)w*h <= 33554432; }
static rfbBool allocate(rfbClient *c) {
    PortalVNC *p = owner(c);
    if (!valid_size(c->width,c->height)) return fail(p,"The remote desktop is too large or has invalid dimensions.");
    uint8_t *buffer = calloc((size_t)c->width*c->height,4);
    if (!buffer) return fail(p,"Not enough memory for the remote desktop.");
    free(c->frameBuffer); c->frameBuffer = buffer;
    return TRUE;
}
static int authorize(PortalVNC *p) {
    if (p->authorized || p->tunneled || p->client->tlsSession) return 1;
    if (!p->cb.authorize || !p->cb.authorize(p->cb.context,1,"This connection is not encrypted.")) return fail(p,"Connection cancelled.");
    p->authorized = 1; return 1;
}
static char *password(rfbClient *c) {
    PortalVNC *p=owner(c); char *user=NULL,*pass=NULL;
    if (!authorize(p) || !p->cb.credentials || !p->cb.credentials(p->cb.context,1,&user,&pass)) { free(user); free(pass); return NULL; }
    free(user); return pass;
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
static void frame(rfbClient *c) { PortalVNC *p=owner(c); p->updates++; if(p->cb.frame) p->cb.frame(p->cb.context,c->frameBuffer,c->width,c->height); }
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
static int encodings[]={-259,rfbEncodingExtDesktopSize,0};
static rfbClientProtocolExtension extension={.encodings=encodings,.handleEncoding=encoding,.handleMessage=message};
static pthread_once_t registration=PTHREAD_ONCE_INIT;
static void register_extension(void) { rfbClientRegisterExtension(&extension); rfbClientLog=quiet_log; rfbClientErr=log_message; }
PortalVNC *portal_vnc_create(PortalCallbacks cb) {
    pthread_once(&registration,register_extension);
    PortalVNC *p=calloc(1,sizeof(*p)); if(!p) return NULL;
    p->cb=cb; p->client=rfbGetClient(8,3,4);
    if(!p->client) { free(p); return NULL; }
    rfbClient *c=p->client; rfbClientSetClientData(c,&tag,p);
    c->MallocFrameBuffer=allocate; c->FinishedFrameBufferUpdate=frame;
    c->GotXCutText=clipboard; c->GotXCutTextUTF8=clipboard_utf8;
    c->GetPassword=password; c->GetCredential=credential; c->GetX509CertFingerprintMismatchDecision=certificate;
    c->canHandleNewFBSize=TRUE; c->connectTimeout=8; c->readTimeout=8;
    c->format.bigEndian=FALSE; c->format.redShift=0; c->format.greenShift=8; c->format.blueShift=16;
    c->appData.useRemoteCursor=FALSE; c->appData.compressLevel=1;
    return p;
}
int portal_vnc_connect(PortalVNC *p,const char *host,int port,int tunnel,int quality,const char *fingerprint) {
    if(!p || !host || port<1 || port>65535 || p->ready) return 0;
    active=p; rfbClient *c=p->client; p->tunneled=tunnel;
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
int portal_vnc_poll(PortalVNC *p) {
    if(!p || !p->ready || p->fatal) return -1;
    active=p; int result=WaitForMessage(p->client,20000);
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
int portal_vnc_pointer(PortalVNC *p,int x,int y,int buttons) { return p && p->ready && x>=0 && y>=0 && x<p->client->width && y<p->client->height && SendPointerEvent(p->client,x,y,buttons); }
int portal_vnc_key(PortalVNC *p,uint32_t key,int down) { return p && p->ready && SendKeyEvent(p->client,key,down); }
int portal_vnc_clipboard(PortalVNC *p,const char *text,int length) {
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
int portal_vnc_resize(PortalVNC *p,int width,int height) { return p && p->ready && p->screenCount==1 && valid_size(width,height) && SendExtDesktopSize(p->client,width,height); }
int portal_vnc_audio(PortalVNC *p,int enabled) {
    if(!p || !p->ready || !p->audio) return 0;
    const char format[]={255,1,0,2,3,2,0,0,172,68}; const char command[]={255,1,0,enabled?0:1};
    return (!enabled || WriteToRFBServer(p->client,format,sizeof(format))) && WriteToRFBServer(p->client,command,sizeof(command));
}
int portal_vnc_quality(PortalVNC *p,int quality) { if(!p || !p->ready || quality < -1 || quality>9) return 0; p->automaticQuality=quality<0; p->client->appData.qualityLevel=quality<0 ? 6 : quality; return !!SetFormatAndEncodings(p->client); }
int portal_vnc_encrypted(PortalVNC *p) { return p && (p->tunneled || p->client->tlsSession!=NULL); }
const char *portal_vnc_error(PortalVNC *p) { return p && p->error[0] ? p->error : "The connection closed unexpectedly."; }
void portal_vnc_destroy(PortalVNC *p) { if(!p) return; if(p->client) { free(p->client->frameBuffer); p->client->frameBuffer=NULL; rfbClientCleanup(p->client); } if(active==p) active=NULL; free(p); }
