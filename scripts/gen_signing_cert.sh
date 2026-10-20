#!/bin/bash
# 生成本机自签代码签名证书 zcode-pet-local 并导入登录钥匙串（一次性；换机器重跑）。
# 为什么需要：macOS 15 的 TCC 对 ad-hoc 签名 app 按 cdhash 记账（实测），每次重装
# （install.sh 重编译重签）辅助功能授权即作废，用户得反复去系统设置重加。
# 换成证书签名后 designated requirement 钉在证书上，重编译不再影响授权。
set -euo pipefail

CN="zcode-pet-local"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/c.key" -out "$TMP/c.crt" \
  -days 3650 -nodes -subj "/CN=$CN" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"

# macOS 的 security 解不了 OpenSSL 3 默认的 PKCS12 加密，必须 -legacy
openssl pkcs12 -export -legacy -out "$TMP/c.p12" -inkey "$TMP/c.key" \
  -in "$TMP/c.crt" -passout pass:zcode-pet-local

security import "$TMP/c.p12" -k ~/Library/Keychains/login.keychain-db \
  -P zcode-pet-local -T /usr/bin/codesign
security add-trusted-cert -p codeSign \
  -k ~/Library/Keychains/login.keychain-db "$TMP/c.crt"

echo "✅ 证书 $CN 已导入并信任（security find-identity -v -p codesigning 可查）"
