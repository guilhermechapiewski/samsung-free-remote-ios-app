# Integration test fixtures

**Test-only, not secrets.** `fake-tv-identity.p12` (CN=FakeTV) and `fake-tv-identity-2.p12`
(CN=FakeTV2) are throwaway self-signed EC P-256 identities used solely by `FakeTV` to serve TLS on
127.0.0.1 in the integration tests. They identify nothing real. Password: `test`.

`info.json` is a made-up `/api/v2/` response served by `FakeTV` on port 8001.

Generated with (LibreSSL 3.3.6 / OpenSSL-compatible; the SHA1/3DES PKCS#12 algorithms keep the
files readable by `SecPKCS12Import`):

```sh
for cn in FakeTV FakeTV2; do
  out=$([ "$cn" = FakeTV ] && echo fake-tv-identity || echo fake-tv-identity-2)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve \
    -days 3650 -nodes -subj "/CN=$cn" -keyout /tmp/key.pem -out /tmp/cert.pem
  openssl pkcs12 -export -inkey /tmp/key.pem -in /tmp/cert.pem -name "$cn" -passout pass:test \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$out.p12"
  rm /tmp/key.pem /tmp/cert.pem
done
```
