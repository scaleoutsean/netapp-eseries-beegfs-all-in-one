#!/bin/bash
set -e

# BeeGFS Certificate and Authentication Setup Script
CERT_DIR="./certs"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"
S3_CERT_FILE="$CERT_DIR/s3.crt"
S3_KEY_FILE="$CERT_DIR/s3.key"
AUTH_FILE="$CERT_DIR/conn.auth"

echo "Setting up BeeGFS certificates and authentication..."

# Create certs directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Create connection authentication file (required even when auth is disabled)
echo "Creating BeeGFS connection authentication file..."
echo "beegfs_test_auth_key" > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
echo "  Authentication file: $AUTH_FILE"

echo "Generating BeeGFS TLS certificates..."

# Generate private key and certificate with proper SAN
openssl req -new -x509 -nodes -days 365 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -config ./openssl.conf \
    -subj "/C=US/ST=State/L=City/O=BeeGFS/CN=localhost"

# Set proper permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Generate S3 gateway certificates (same content, different extensions)
echo "Generating S3 gateway certificates..."
cp "$CERT_FILE" "$S3_CERT_FILE"
cp "$KEY_FILE" "$S3_KEY_FILE"
chmod 600 "$S3_KEY_FILE"
chmod 644 "$S3_CERT_FILE"

echo "TLS certificates generated:"
echo "  BeeGFS Certificate: $CERT_FILE"
echo "  BeeGFS Private Key: $KEY_FILE"
echo "  S3 Certificate: $S3_CERT_FILE"
echo "  S3 Private Key: $S3_KEY_FILE"
echo "  Auth file: $AUTH_FILE"

# Update .env file with certificate data
echo "Updating .env file with certificate data..."

# Remove existing TLS entries if they exist
sed -i '/^TLS_CERT_FILE_DATA=/d' .env 2>/dev/null || true
sed -i '/^TLS_KEY_FILE_DATA=/d' .env 2>/dev/null || true
sed -i '/^# TLS Certificate Data/d' .env 2>/dev/null || true

# Add new certificate data
echo "# TLS Certificate Data" >> .env
echo "TLS_CERT_FILE_DATA=\"$(base64 -w 0 < $CERT_FILE)\"" >> .env
echo "TLS_KEY_FILE_DATA=\"$(base64 -w 0 < $KEY_FILE)\"" >> .env

echo "Certificate data added to .env file"
echo "Done!"