"""Pinned LibVNCClient hooks for monitor layouts, RSA-AES records, and auth preference."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
anchor = '      if (rect.encoding == rfbEncodingExtDesktopSize) {\n'
assert source.count(anchor) == 1, 'Upstream layout handling changed; review the patch.'
source = source.replace(anchor, '''      if (rect.encoding == rfbEncodingExtDesktopSize) {
        rfbBool handled = FALSE;
        rfbClientProtocolExtension* extension;
        for (extension = rfbClientExtensions; extension && !handled; extension = extension->next)
          if (extension->handleEncoding) handled = extension->handleEncoding(client, &rect);
        if (handled) continue;
      }
''' + anchor)
path.write_text(source)

# RSA-AES needs a record transport while retaining LibVNCClient's socket buffering.
root = path.parents[2]
header = root / 'include/rfb/rfbclient.h'
s = header.read_text()
s = s.replace('} rfbClient;', '''  unsigned int portalExternalSSF;
  void *portalTransport;
  rfbBool (*portalRead)(struct _rfbClient *, char *, unsigned int);
  rfbBool (*portalWrite)(struct _rfbClient *, const char *, unsigned int);
} rfbClient;''')
s += '\nextern rfbBool PortalReadRaw(rfbClient *, char *, unsigned int);\nextern rfbBool PortalWriteRaw(rfbClient *, const char *, unsigned int);\n'
header.write_text(s)
sockets = root / 'src/libvncclient/sockets.c'
s = sockets.read_text()
for name, raw, declaration, arguments, hook in [
    ('ReadFromRFBServer', 'PortalReadRaw', 'rfbClient* client, char *out, unsigned int n', 'client, out, n', 'portalRead'),
    ('WriteToRFBServer', 'PortalWriteRaw', 'rfbClient* client, const char *buf, unsigned int n', 'client, buf, n', 'portalWrite'),
]:
    anchor = f'{name}({declaration})\n{{'
    assert s.count(anchor) == 1, f'Upstream {name} changed; review the patch.'
    s = s.replace(anchor, f'''{name}({declaration})
{{
  if (client->{hook}) return client->{hook}({arguments});
  return {raw}({arguments});
}}

rfbBool
{raw}({declaration})
{{''')
# An exact read must wait for NEW socket bytes, not its own incomplete buffer.
# WaitForMessage remains buffer-aware for callers polling for a new RFB message.
anchor = 'int WaitForMessage(rfbClient* client,unsigned int usecs)\n{'
assert s.count(anchor) == 1
s = s.replace(anchor, """int WaitForMessage(rfbClient* client,unsigned int usecs)
{
  if (client->buffered > 0) return 1;
  return PortalWaitForSocket(client, usecs);
}

static int PortalWaitForSocket(rfbClient* client,unsigned int usecs)
{""")
anchor = """  /* Check if we have buffered data available */
  if (client->buffered > 0) {
    return 1;
  }
"""
assert s.count(anchor) == 1
s = s.replace(anchor, '')
anchor = 'WaitForMessage(client, USECS_WAIT_PER_RETRY);'
assert s.count(anchor) == 2
s = s.replace(anchor, 'PortalWaitForSocket(client, USECS_WAIT_PER_RETRY);')
s = s.replace('rfbBool\nReadFromRFBServer(', 'static int PortalWaitForSocket(rfbClient *, unsigned int);\n\nrfbBool\nReadFromRFBServer(', 1)
sockets.write_text(s)

# Prefer full-session encryption before credential-only or unencrypted methods.
s = path.read_text()
anchor = '    authScheme=0;\n    /* now, we have a list'
assert s.count(anchor) == 1
s = s.replace(anchor, '''    if (!ReadFromRFBServer(client, (char *)tAuth, count)) return FALSE;
    if (!subAuth) {
        const uint8_t preferred[] = {129, 5, 19, 18, 20, 130, 6, 30, 113, 2, 1};
        unsigned int next = 0;
        for (unsigned int rank = 0; rank < sizeof(preferred); rank++)
            for (unsigned int i = next; i < count; i++)
                if (tAuth[i] == preferred[rank]) {
                    uint8_t temp = tAuth[next]; tAuth[next++] = tAuth[i]; tAuth[i] = temp;
                }
    }
    authScheme=0;
    /* now, we have a list''')
s = s.replace('        if (!ReadFromRFBServer(client, (char *)&tAuth[loop], 1)) return FALSE;\n', '')
path.write_text(s)

# PLAIN completes in sasl_client_start; stepping an already-finished exchange fails.
sasl = root / 'src/libvncclient/sasl.c'
s = sasl.read_text()
assert s.count('    for (;;) {') == 1
s = s.replace('    for (;;) {', '    while (!(complete && err == SASL_OK)) {')
s = s.replace('if (client->tlsSession) {', 'if (client->tlsSession || client->portalExternalSSF) {')
s = s.replace('(sasl_ssf_t)GetTLSCipherBits(client)', '(sasl_ssf_t)(client->portalExternalSSF ? client->portalExternalSSF : GetTLSCipherBits(client))')
s = s.replace('client->tlsSession ? 0 :', '(client->tlsSession || client->portalExternalSSF) ? 0 :')
s = s.replace('if (!client->tlsSession) {', 'if (!client->tlsSession && !client->portalExternalSSF) {')
sasl.write_text(s)

# Modern OpenSSL DH APIs reject MSLogonII's fixed 64-bit group. This legacy
# protocol is already gated by Portal's unencrypted-session consent prompt.
crypto = root / 'src/common/crypto_openssl.c'
s = crypto.read_text()
anchor = 'int dh_generate_keypair('
assert s.count(anchor) == 1
helper = '''static int portal_mslogon_dh(uint8_t *out, uint8_t *private_out,
                             const uint8_t *private_in, const uint8_t *base,
                             size_t base_len, const uint8_t *prime)
{
    int ok = 0;
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *p = BN_bin2bn(prime, 8, NULL), *b = BN_bin2bn(base, base_len, NULL);
    BIGNUM *x = private_in ? BN_bin2bn(private_in, 8, NULL) : BN_new();
    BIGNUM *result = BN_new(), *limit = p ? BN_dup(p) : NULL;
    if (!ctx || !p || !b || !x || !result || !limit || BN_num_bits(p) < 32 ||
        !BN_is_odd(p) || !BN_check_prime(p, ctx, NULL) || !BN_sub_word(limit, 2) ||
        BN_cmp(b, BN_value_one()) <= 0 || BN_cmp(b, limit) > 0) goto done;
    if (!private_in && (!BN_priv_rand_range(x, limit) || !BN_add_word(x, 1))) goto done;
    BN_set_flags(x, BN_FLG_CONSTTIME);
    if (!BN_mod_exp_mont_consttime(result, b, x, p, ctx, NULL) ||
        BN_cmp(result, BN_value_one()) <= 0 || BN_bn2binpad(result, out, 8) != 8) goto done;
    if (private_out && BN_bn2binpad(x, private_out, 8) != 8) goto done;
    ok = 1;
done:
    BN_CTX_free(ctx); BN_free(p); BN_free(b); BN_clear_free(x);
    BN_clear_free(result); BN_free(limit); return ok;
}

'''
s = s.replace(anchor, helper + anchor)
anchor = 'const size_t keylen)\n{'
assert s.count(anchor) == 2
first = s.index(anchor, s.index('int dh_generate_keypair(')) + len(anchor)
s = s[:first] + '\n    if (keylen == 8) return portal_mslogon_dh(pub_out, priv_out, NULL, gen, gen_len, prime);' + s[first:]
second = s.index(anchor, s.index('int dh_compute_shared_key(')) + len(anchor)
s = s[:second] + '\n    if (keylen == 8) return portal_mslogon_dh(shared_out, NULL, priv, pub, keylen, prime);' + s[second:]
crypto.write_text(s)

# An empty shape tells viewers to hide a previously supplied cursor.
cursor = root / 'src/libvncclient/cursor.c'
s = cursor.read_text()
anchor = "  if (width * height == 0)\n    return TRUE;"
assert s.count(anchor) == 1
s = s.replace(anchor, """  if (width * height == 0) {
    if (client->GotCursorShape) client->GotCursorShape(client, xhot, yhot, 0, 0, bytesPerPixel);
    return TRUE;
  }""")
cursor.write_text(s)

# Pipeline the next incremental request before decoding this update's rectangles.
s = path.read_text()
request = "    if (!SendIncrementalFramebufferUpdateRequest(client))\n      return FALSE;\n"
assert s.count(request) == 1
s = s.replace(request, '')
anchor = "    msg.fu.nRects = rfbClientSwap16IfLE(msg.fu.nRects);\n"
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + "\n" + request)
path.write_text(s)

# Drain only input writes while a fragmented message is waiting for more bytes.
s = header.read_text()
anchor = '  rfbBool (*portalWrite)(struct _rfbClient *, const char *, unsigned int);'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '\n  void (*portalPumpInput)(struct _rfbClient *);')
header.write_text(s)
s = sockets.read_text()
anchor = 'static int PortalWaitForSocket(rfbClient* client,unsigned int usecs)\n{'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + """
  if (client->portalPumpInput && usecs > 5000) {
    while (usecs > 0) {
      unsigned int slice = usecs > 5000 ? 5000 : usecs;
      int result = PortalWaitForSocket(client, slice);
      if (result != 0) return result;
      usecs -= slice;
    }
    return 0;
  }
  if (client->portalPumpInput) client->portalPumpInput(client);
""")
sockets.write_text(s)
