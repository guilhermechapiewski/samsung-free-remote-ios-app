# TLS test fixtures

**Test-only, not secrets.** These are throwaway self-signed EC P-256 certificates used solely by
`CertificatePinTests`. They identify nothing real; the private keys were discarded at generation
time and are not committed.

Generated with (LibreSSL 3.3.6 / OpenSSL-compatible):

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve \
  -nodes -keyout /tmp/key-a.pem -outform DER -out cert-a.der -days 36500 -subj "/CN=Test TV Cert A"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve \
  -nodes -keyout /tmp/key-b.pem -outform DER -out cert-b.der -days 36500 -subj "/CN=Test TV Cert B"
rm /tmp/key-a.pem /tmp/key-b.pem
```

Expected pin (SHA-256 of the 65-byte uncompressed EC point `04||X||Y`, i.e. what
`SecKeyCopyExternalRepresentation` returns):

```sh
openssl x509 -inform DER -in cert-a.der -noout -pubkey \
  | openssl ec -pubin -outform DER | tail -c 65 | openssl dgst -sha256 -hex
```
