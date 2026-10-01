/* RSA-AES wire flow adapted from TigerVNC CSecurityRSAAES and AES streams.
 * Copyright (C) 2022 Dinglan Peng. GPL-2.0-or-later; see LICENSE.
 * Cryptographic operations use OpenSSL and Nettle, not custom primitives.
 */
#include "RSAAuth.h"
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/core_names.h>
#include <openssl/param_build.h>
#include <openssl/rand.h>
#include <nettle/eax.h>
#include <nettle/aes.h>
#include <nettle/version.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    struct eax_key key;
    struct eax_ctx eax;
    union { struct aes128_ctx a128; struct aes256_ctx a256; } cipher;
    nettle_cipher_func *encrypt;
    uint8_t nonce[16];
} Cipher;
typedef struct {
    Cipher input, output;
    uint8_t buffer[65535];
    size_t offset, length;
    int failed;
    char *error;
    size_t errorSize;
} Transport;
static int failure(Transport *t, const char *message) {
    t->failed=1; snprintf(t->error,t->errorSize,"%s",message); return 0;
}
static void cipher_init(Cipher *c, const uint8_t *key, int size) {
    if(size==16) { aes128_set_encrypt_key(&c->cipher.a128,key); c->encrypt=(nettle_cipher_func *)aes128_encrypt; }
    else { aes256_set_encrypt_key(&c->cipher.a256,key); c->encrypt=(nettle_cipher_func *)aes256_encrypt; }
    eax_set_key(&c->key,&c->cipher,c->encrypt);
}
static int record(Cipher *c,int decrypt,uint8_t *dst,const uint8_t *src,size_t n,const uint8_t header[2],uint8_t tag[16]) {
    eax_set_nonce(&c->eax,&c->key,&c->cipher,c->encrypt,16,c->nonce);
    eax_update(&c->eax,&c->key,&c->cipher,c->encrypt,2,header);
    if(decrypt) eax_decrypt(&c->eax,&c->key,&c->cipher,c->encrypt,n,dst,src);
    else eax_encrypt(&c->eax,&c->key,&c->cipher,c->encrypt,n,dst,src);
#if NETTLE_VERSION_MAJOR >= 4
    eax_digest(&c->eax,&c->key,&c->cipher,c->encrypt,tag);
#else
    eax_digest(&c->eax,&c->key,&c->cipher,c->encrypt,16,tag);
#endif
    for(int i=0;i<16;i++) if(++c->nonce[i]) return 1;
    return 0;
}
static rfbBool encrypted_read(rfbClient *c,char *out,unsigned int n) {
    Transport *t=c->portalTransport;
    if(t->failed) return FALSE;
    while(n) {
        if(t->offset==t->length) {
            uint8_t header[2],tag[16],expected[16];
            if(!PortalReadRaw(c,(char *)header,2)) return failure(t,"The encrypted connection closed unexpectedly.");
            t->length=((size_t)header[0]<<8)|header[1]; t->offset=0;
            if(!PortalReadRaw(c,(char *)t->buffer,(unsigned)t->length) || !PortalReadRaw(c,(char *)tag,16))
                return failure(t,"The encrypted connection closed unexpectedly.");
            if(!record(&t->input,1,t->buffer,t->buffer,t->length,header,expected) || CRYPTO_memcmp(tag,expected,16))
                return failure(t,"Encrypted message verification failed. The connection was stopped.");
        }
        size_t count=t->length-t->offset; if(count>n) count=n;
        memcpy(out,t->buffer+t->offset,count); t->offset+=count; out+=count; n-=count;
    }
    return TRUE;
}
static rfbBool encrypted_write(rfbClient *c,const char *data,unsigned int n) {
    Transport *t=c->portalTransport;
    if(t->failed) return FALSE;
    while(n) {
        uint8_t packet[8192+18]; size_t count=n>8192?8192:n;
        packet[0]=count>>8; packet[1]=count;
        if(!record(&t->output,0,packet+2,(const uint8_t *)data,count,packet,packet+2+count))
            return failure(t,"The encrypted session must be reconnected.");
        if(!PortalWriteRaw(c,(char *)packet,(unsigned)count+18)) return failure(t,"The encrypted connection closed unexpectedly.");
        data+=count; n-=count;
    }
    return TRUE;
}
int portal_rsa_pending(rfbClient *c) {
    Transport *t=c->portalTransport; return c->portalRead && t && t->offset<t->length;
}
void portal_rsa_destroy(rfbClient *c) {
    if(c->portalTransport) { OPENSSL_cleanse(c->portalTransport,sizeof(Transport)); free(c->portalTransport); }
    c->portalTransport=NULL; c->portalRead=NULL; c->portalWrite=NULL;
}
static int hash_pair(const EVP_MD *md,const uint8_t *a,size_t an,const uint8_t *b,size_t bn,uint8_t *out) {
    EVP_MD_CTX *ctx=EVP_MD_CTX_new(); unsigned int n;
    int ok=ctx && EVP_DigestInit_ex(ctx,md,NULL)>0 && EVP_DigestUpdate(ctx,a,an)>0 && EVP_DigestUpdate(ctx,b,bn)>0 && EVP_DigestFinal_ex(ctx,out,&n)>0;
    EVP_MD_CTX_free(ctx); return ok;
}
static EVP_PKEY *public_key(const uint8_t *n,const uint8_t *e,size_t size) {
    BIGNUM *bn=BN_bin2bn(n,(int)size,NULL), *be=BN_bin2bn(e,(int)size,NULL);
    OSSL_PARAM_BLD *build=OSSL_PARAM_BLD_new(); OSSL_PARAM *params=NULL;
    EVP_PKEY_CTX *ctx=EVP_PKEY_CTX_new_from_name(NULL,"RSA",NULL); EVP_PKEY *key=NULL;
    if(bn && be && build && ctx && BN_is_odd(bn) && BN_is_odd(be) && BN_cmp(be,BN_value_one())>0 &&
       OSSL_PARAM_BLD_push_BN(build,OSSL_PKEY_PARAM_RSA_N,bn) && OSSL_PARAM_BLD_push_BN(build,OSSL_PKEY_PARAM_RSA_E,be)) {
        params=OSSL_PARAM_BLD_to_param(build);
        if(!params || EVP_PKEY_fromdata_init(ctx)<=0 || EVP_PKEY_fromdata(ctx,&key,EVP_PKEY_PUBLIC_KEY,params)<=0) { EVP_PKEY_free(key); key=NULL; }
    }
    BN_free(bn); BN_free(be); OSSL_PARAM_free(params); OSSL_PARAM_BLD_free(build); EVP_PKEY_CTX_free(ctx); return key;
}
static int crypt_random(EVP_PKEY *key,int decrypt,const uint8_t *in,size_t n,uint8_t *out,size_t *outSize) {
    EVP_PKEY_CTX *ctx=EVP_PKEY_CTX_new(key,NULL); int ok=0;
    if(ctx && (decrypt?EVP_PKEY_decrypt_init(ctx):EVP_PKEY_encrypt_init(ctx))>0 && EVP_PKEY_CTX_set_rsa_padding(ctx,RSA_PKCS1_PADDING)>0)
        ok=(decrypt?EVP_PKEY_decrypt(ctx,out,outSize,in,n):EVP_PKEY_encrypt(ctx,out,outSize,in,n))>0;
    EVP_PKEY_CTX_free(ctx); return ok;
}
int portal_rsa_auth(rfbClient *c,unsigned int scheme,PortalCallbacks cb,char *error,size_t errorSize) {
    Transport *t=calloc(1,sizeof(*t)); if(!t) return 0;
    t->error=error; t->errorSize=errorSize; c->portalTransport=t;
    EVP_PKEY *server=NULL,*client=NULL;
    uint8_t serverBlob[2052],clientBlob[2052],clientRandom[32]={0},serverRandom[1024]={0},encrypted[1024],hash[32],expected[32],key[32];
    char *user=NULL,*pass=NULL; int ok=0;
    size_t serverSize=0,clientSize=0;
    int keySize=(scheme==129 || scheme==130)?32:16;
    const EVP_MD *md=keySize==32?EVP_sha256():EVP_sha1();
    unsigned int hashSize=(unsigned)EVP_MD_get_size(md);
#define REQUIRE(condition,message) do { if(!(condition)) { failure(t,message); ok=0; goto done; } } while(0)
    REQUIRE(PortalReadRaw(c,(char *)serverBlob,4),"Could not read the server’s RSA key.");
    uint32_t bits; memcpy(&bits,serverBlob,4); bits=ntohl(bits);
    REQUIRE(bits>=1024 && bits<=8192,"The server’s RSA key size is invalid (expected 1024–8192 bits).");
    serverSize=(bits+7)/8;
    REQUIRE(PortalReadRaw(c,(char *)serverBlob+4,(unsigned)serverSize*2),"Incomplete server RSA key.");
    server=public_key(serverBlob+4,serverBlob+4+serverSize,serverSize);
    REQUIRE(server && EVP_PKEY_get_bits(server)==bits,"The server’s RSA key is invalid.");
    REQUIRE(hash_pair(EVP_sha256(),serverBlob,4+serverSize*2,NULL,0,hash),"Could not verify the server’s identity.");
    char fingerprint[65]; for(int i=0;i<32;i++) snprintf(fingerprint+i*2,3,"%02x",hash[i]);
    REQUIRE(cb.authorize && cb.authorize(cb.context,3,fingerprint),"Connection cancelled.");
    // A fixed 2048-bit ephemeral client key avoids server-controlled key generation cost.
    client=EVP_PKEY_Q_keygen(NULL,NULL,"RSA",2048);
    REQUIRE(client,"Could not create an RSA session key.");
    clientSize=(size_t)EVP_PKEY_get_size(client);
    uint32_t clientBits=htonl(2048); memcpy(clientBlob,&clientBits,4);
    BIGNUM *n=NULL,*e=NULL;
    int exported=EVP_PKEY_get_bn_param(client,OSSL_PKEY_PARAM_RSA_N,&n) && EVP_PKEY_get_bn_param(client,OSSL_PKEY_PARAM_RSA_E,&e);
    if(exported) exported=BN_bn2binpad(n,clientBlob+4,(int)clientSize)==clientSize && BN_bn2binpad(e,clientBlob+4+clientSize,(int)clientSize)==clientSize;
    BN_free(n); BN_free(e);
    REQUIRE(exported && PortalWriteRaw(c,(char *)clientBlob,(unsigned)(4+clientSize*2)),"Could not send the client’s RSA key.");
    REQUIRE(RAND_bytes(clientRandom,keySize)>0,"Could not generate secure random data.");
    size_t encryptedSize=sizeof(encrypted);
    REQUIRE(crypt_random(server,0,clientRandom,keySize,encrypted,&encryptedSize),"RSA key exchange failed.");
    uint16_t wireSize=htons((uint16_t)encryptedSize);
    REQUIRE(PortalWriteRaw(c,(char *)&wireSize,2) && PortalWriteRaw(c,(char *)encrypted,(unsigned)encryptedSize),"RSA key exchange failed.");
    REQUIRE(PortalReadRaw(c,(char *)&wireSize,2) && ntohs(wireSize)==clientSize,"Invalid RSA key exchange response.");
    REQUIRE(PortalReadRaw(c,(char *)encrypted,(unsigned)clientSize),"Incomplete RSA key exchange.");
    size_t randomSize=sizeof(serverRandom);
    REQUIRE(crypt_random(client,1,encrypted,clientSize,serverRandom,&randomSize) && randomSize==keySize,"RSA key exchange verification failed.");
    REQUIRE(hash_pair(md,clientRandom,keySize,serverRandom,keySize,key),"Could not derive the session key."); cipher_init(&t->input,key,keySize);
    REQUIRE(hash_pair(md,serverRandom,keySize,clientRandom,keySize,key),"Could not derive the session key."); cipher_init(&t->output,key,keySize);
    c->portalRead=encrypted_read; c->portalWrite=encrypted_write;
    REQUIRE(hash_pair(md,clientBlob,4+clientSize*2,serverBlob,4+serverSize*2,hash),"Could not verify the RSA handshake.");
    REQUIRE(encrypted_write(c,(char *)hash,hashSize),"Could not send the RSA handshake verification.");
    REQUIRE(hash_pair(md,serverBlob,4+serverSize*2,clientBlob,4+clientSize*2,expected),"Could not verify the RSA handshake.");
    if(!encrypted_read(c,(char *)hash,hashSize)) goto done;
    REQUIRE(CRYPTO_memcmp(hash,expected,hashSize)==0,"The server’s RSA handshake verification failed.");
    uint8_t subtype;
    if(!encrypted_read(c,(char *)&subtype,1)) goto done;
    REQUIRE(subtype==1 || subtype==2,"The server requested an unsupported RSA authentication subtype.");
    REQUIRE(cb.credentials && cb.credentials(cb.context,subtype==1?2:1,&user,&pass),"Connection cancelled.");
    size_t un=subtype==1 && user?strlen(user):0, pn=pass?strlen(pass):0;
    REQUIRE(un<=255 && pn<=255,"RSA-AES credentials must be at most 255 UTF-8 bytes each.");
    uint8_t credentials[512]; size_t length=0;
    credentials[length++]=(uint8_t)un; if(un) { memcpy(credentials+length,user,un); length+=un; }
    credentials[length++]=(uint8_t)pn; if(pn) { memcpy(credentials+length,pass,pn); length+=pn; }
    ok=encrypted_write(c,(char *)credentials,(unsigned)length); OPENSSL_cleanse(credentials,sizeof(credentials));
    if(scheme==6 || scheme==130) {
        REQUIRE(t->offset==t->length,"Unexpected data after RSA authentication.");
        c->portalRead=NULL; c->portalWrite=NULL;
    }
done:
    if(pass) { OPENSSL_cleanse(pass,strlen(pass)); free(pass); } free(user);
    EVP_PKEY_free(server); EVP_PKEY_free(client);
    OPENSSL_cleanse(clientRandom,sizeof(clientRandom)); OPENSSL_cleanse(serverRandom,sizeof(serverRandom)); OPENSSL_cleanse(key,sizeof(key));
    return ok;
#undef REQUIRE
}
