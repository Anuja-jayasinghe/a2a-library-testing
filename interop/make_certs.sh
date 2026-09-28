#!/usr/bin/env bash
# A throwaway CA, a server certificate for localhost, and a client certificate, in
# ${1:-/tmp/interop-certs}. For the TLS/mTLS interop checks only.
set -e
D=${1:-/tmp/interop-certs}; rm -rf "$D"; mkdir -p "$D"; cd "$D"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj "/CN=interop-test-ca" >/dev/null 2>&1
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > san.cnf
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 30 -extfile san.cnf >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=interop-client" >/dev/null 2>&1
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client.pem -days 30 >/dev/null 2>&1
openssl pkcs8 -topk8 -nocrypt -in server.key -out server.p8.key >/dev/null 2>&1
echo "certificates in $D"
