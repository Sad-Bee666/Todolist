#!/bin/bash
# 创建本地 code signing 自签证书，让 TCC 授权在重新构建后依然有效。
# 只做一次；重复执行会覆盖同名身份。
set -euo pipefail

IDENTITY="Todolist Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMPDIR_SIGN="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SIGN}"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
  echo "已存在签名身份：${IDENTITY}，无需重建"
  exit 0
fi

cd "${TMPDIR_SIGN}"
cat > req.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Todolist Local Signing
O=Local Development
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config req.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -name "${IDENTITY}" -passout pass:todolist

security import id.p12 -k "${KEYCHAIN}" -P todolist -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" cert.pem

echo "已创建并信任签名身份：${IDENTITY}"
security find-identity -v -p codesigning | grep "${IDENTITY}" || true
echo
echo "之后 ./build.sh 会自动用它签名；TCC 的屏幕录制授权不会再因重新构建而失效。"
