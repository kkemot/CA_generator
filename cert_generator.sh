#!/bin/bash

# ============================================
# CERTIFICATE AUTHORITY GENERATOR
# For home lab with Kubernetes cert-manager integration
# ============================================

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cert.conf"

# ============================================
# COLOR OUTPUT - Auto-detect terminal support
# ============================================
# Detect if running in a terminal that supports ANSI colors
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    COLORS=true
else
    COLORS=false
fi

# Disable colors on Windows unless running in proper bash (not through cmd/powershell)
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || -n "$WINDIR" ]]; then
    COLORS=false
fi

if [[ "$COLORS" == "true" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ============================================
# LOGGING FUNCTIONS
# ============================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# CONFIGURATION PARSER
# ============================================
parse_config() {
    local section=$1
    local key=$2
    local default=$3
    
    # Parse INI-style config file
    local value=$(awk -F= -v section="[$section]" -v key="$key" '
        $0 == section { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 ~ "^[ \t]*"key"[ \t]*$" { 
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            gsub(/"/, "", $2);
            gsub(/#.*$/, "", $2);
            gsub(/[ \t]+$/, "", $2);
            print $2;
            exit
        }
    ' "$CONFIG_FILE")
    
    echo "${value:-$default}"
}

# ============================================
# CONFIGURATION VALIDATION
# ============================================
validate_config() {
    log_info "Validating configuration file..."
    
    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "The configuration file is mandatory. Please create cert.conf before running this script."
        exit 1
    fi
    
    # Check if config file is readable
    if [[ ! -r "$CONFIG_FILE" ]]; then
        log_error "Configuration file is not readable: $CONFIG_FILE"
        exit 1
    fi
    
    # Validate required sections exist
    local required_sections=("root_ca" "intermediate_ca" "server_cert" "kubernetes")
    for section in "${required_sections[@]}"; do
        if ! grep -q "^\[$section\]" "$CONFIG_FILE"; then
            log_error "Missing required section [$section] in configuration file"
            exit 1
        fi
    done
    
    # Validate required keys in root_ca section
    local required_root_keys=("name" "organization" "country" "validity_days" "key_size")
    for key in "${required_root_keys[@]}"; do
        local value=$(parse_config "root_ca" "$key" "")
        if [[ -z "$value" ]]; then
            log_error "Missing required key '$key' in [root_ca] section"
            exit 1
        fi
    done
    
    log_success "Configuration file validated successfully"
}

# ============================================
# DIRECTORY SETUP
# ============================================
setup_directories() {
    log_info "Setting up directory structure..."
    
    OUTPUT_DIR=$(parse_config "directories" "output_dir" "./certs")
    ROOT_CA_DIR=$(parse_config "directories" "root_ca_dir" "./certs/root-ca")
    INTERMEDIATE_CA_DIR=$(parse_config "directories" "intermediate_ca_dir" "./certs/intermediate-ca")
    SERVER_CERTS_DIR=$(parse_config "directories" "server_certs_dir" "./certs/server")
    K8S_EXPORT_DIR=$(parse_config "directories" "k8s_export_dir" "./certs/kubernetes")
    
    mkdir -p "$ROOT_CA_DIR" "$INTERMEDIATE_CA_DIR" "$SERVER_CERTS_DIR" "$K8S_EXPORT_DIR"
    
    # Create index and serial files for CA
    touch "$ROOT_CA_DIR/index.txt"
    touch "$INTERMEDIATE_CA_DIR/index.txt"
    echo 1000 > "$ROOT_CA_DIR/serial"
    echo 1000 > "$INTERMEDIATE_CA_DIR/serial"
    
    log_success "Directory structure created"
}

# ============================================
# GENERATE ROOT CA
# ============================================
generate_root_ca() {
    # Check if Root CA already exists
    if [[ -f "$ROOT_CA_DIR/root-ca.crt" && -f "$ROOT_CA_DIR/root-ca.key" ]]; then
        log_warning "Root CA already exists, skipping generation"
        log_info "Existing Root CA: $ROOT_CA_DIR/root-ca.crt"
        display_cert_info "$ROOT_CA_DIR/root-ca.crt"
        return 0
    fi
    
    log_info "Generating Root CA..."
    
    ROOT_CA_NAME=$(parse_config "root_ca" "name" "Example Root CA")
    ROOT_CA_ORG=$(parse_config "root_ca" "organization" "ExampleOrg")
    ROOT_CA_COUNTRY=$(parse_config "root_ca" "country" "PL")
    ROOT_CA_STATE=$(parse_config "root_ca" "state" "ExampleRegion")
    ROOT_CA_LOCALITY=$(parse_config "root_ca" "locality" "ExampleCity")
    ROOT_CA_EMAIL=$(parse_config "root_ca" "email" "")
    ROOT_CA_VALIDITY=$(parse_config "root_ca" "validity_days" "18250")
    ROOT_CA_KEY_SIZE=$(parse_config "root_ca" "key_size" "4096")
    
    # Generate Root CA private key
    log_info "Generating Root CA private key ($ROOT_CA_KEY_SIZE bits)..."
    openssl genrsa -aes256 -out "$ROOT_CA_DIR/root-ca.key" "$ROOT_CA_KEY_SIZE"
    chmod 400 "$ROOT_CA_DIR/root-ca.key"
    
    # Create OpenSSL config for Root CA
    cat > "$ROOT_CA_DIR/root-ca.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = $ROOT_CA_COUNTRY
ST = $ROOT_CA_STATE
L = $ROOT_CA_LOCALITY
O = $ROOT_CA_ORG
CN = $ROOT_CA_NAME
EOF

    # Add email only if not empty
    if [[ -n "$ROOT_CA_EMAIL" ]]; then
        echo "emailAddress = $ROOT_CA_EMAIL" >> "$ROOT_CA_DIR/root-ca.cnf"
    fi
    
    cat >> "$ROOT_CA_DIR/root-ca.cnf" <<EOF

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
    
    # Generate Root CA certificate
    log_info "Generating Root CA certificate..."
    openssl req -new -x509 -days "$ROOT_CA_VALIDITY" \
        -key "$ROOT_CA_DIR/root-ca.key" \
        -out "$ROOT_CA_DIR/root-ca.crt" \
        -config "$ROOT_CA_DIR/root-ca.cnf"
    
    log_success "Root CA generated: $ROOT_CA_DIR/root-ca.crt"
    
    # Display certificate info
    openssl x509 -noout -text -in "$ROOT_CA_DIR/root-ca.crt" | head -20
}

# ============================================
# GENERATE INTERMEDIATE CA
# ============================================
generate_intermediate_ca() {
    # Check if Intermediate CA already exists
    if [[ -f "$INTERMEDIATE_CA_DIR/intermediate-ca.crt" && -f "$INTERMEDIATE_CA_DIR/intermediate-ca.key" ]]; then
        log_warning "Intermediate CA already exists, skipping generation"
        log_info "Existing Intermediate CA: $INTERMEDIATE_CA_DIR/intermediate-ca.crt"
        display_cert_info "$INTERMEDIATE_CA_DIR/intermediate-ca.crt"
        return 0
    fi
    
    log_info "Generating Intermediate CA..."
    
    INT_CA_NAME=$(parse_config "intermediate_ca" "name" "Example Intermediate CA")
    INT_CA_ORG=$(parse_config "intermediate_ca" "organization" "ExampleOrg")
    INT_CA_COUNTRY=$(parse_config "intermediate_ca" "country" "PL")
    INT_CA_STATE=$(parse_config "intermediate_ca" "state" "ExampleRegion")
    INT_CA_LOCALITY=$(parse_config "intermediate_ca" "locality" "ExampleCity")
    INT_CA_EMAIL=$(parse_config "intermediate_ca" "email" "")
    INT_CA_VALIDITY=$(parse_config "intermediate_ca" "validity_days" "9125")
    INT_CA_KEY_SIZE=$(parse_config "intermediate_ca" "key_size" "4096")
    
    # Generate Intermediate CA private key (without password for Kubernetes automation)
    log_info "Generating Intermediate CA private key ($INT_CA_KEY_SIZE bits)..."
    log_warning "Intermediate CA key will be generated WITHOUT password for Kubernetes cert-manager compatibility"
    openssl genrsa -out "$INTERMEDIATE_CA_DIR/intermediate-ca.key" "$INT_CA_KEY_SIZE"
    chmod 400 "$INTERMEDIATE_CA_DIR/intermediate-ca.key"
    
    # Create OpenSSL config for Intermediate CA
    cat > "$INTERMEDIATE_CA_DIR/intermediate-ca.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = $INT_CA_COUNTRY
ST = $INT_CA_STATE
L = $INT_CA_LOCALITY
O = $INT_CA_ORG
CN = $INT_CA_NAME
EOF

    # Add email only if not empty
    if [[ -n "$INT_CA_EMAIL" ]]; then
        echo "emailAddress = $INT_CA_EMAIL" >> "$INTERMEDIATE_CA_DIR/intermediate-ca.cnf"
    fi
    
    cat >> "$INTERMEDIATE_CA_DIR/intermediate-ca.cnf" <<EOF

[v3_intermediate_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
    
    # Generate CSR for Intermediate CA
    log_info "Generating Intermediate CA CSR..."
    openssl req -new -sha256 \
        -key "$INTERMEDIATE_CA_DIR/intermediate-ca.key" \
        -out "$INTERMEDIATE_CA_DIR/intermediate-ca.csr" \
        -config "$INTERMEDIATE_CA_DIR/intermediate-ca.cnf"
    
    # Sign Intermediate CA with Root CA
    log_info "Signing Intermediate CA with Root CA..."
    openssl x509 -req -days "$INT_CA_VALIDITY" \
        -in "$INTERMEDIATE_CA_DIR/intermediate-ca.csr" \
        -CA "$ROOT_CA_DIR/root-ca.crt" \
        -CAkey "$ROOT_CA_DIR/root-ca.key" \
        -CAcreateserial \
        -out "$INTERMEDIATE_CA_DIR/intermediate-ca.crt" \
        -extfile "$INTERMEDIATE_CA_DIR/intermediate-ca.cnf" \
        -extensions v3_intermediate_ca
    
    # Create certificate chain
    log_info "Creating certificate chain..."
    cat "$INTERMEDIATE_CA_DIR/intermediate-ca.crt" "$ROOT_CA_DIR/root-ca.crt" > "$INTERMEDIATE_CA_DIR/ca-chain.crt"
    
    log_success "Intermediate CA generated: $INTERMEDIATE_CA_DIR/intermediate-ca.crt"
}

# ============================================
# GENERATE SERVER CERTIFICATE
# ============================================
generate_server_cert() {
    local common_name=$1
    local dns_names=$2
    
    if [[ -z "$common_name" ]]; then
        log_error "Common name required for server certificate"
        return 1
    fi
    
    log_info "Generating server certificate for: $common_name"
    
    # Initialize directory variables if not set
    if [[ -z "$SERVER_CERTS_DIR" ]]; then
        OUTPUT_DIR=$(parse_config "directories" "output_dir" "./certs")
        INTERMEDIATE_CA_DIR=$(parse_config "directories" "intermediate_ca_dir" "./certs/intermediate-ca")
        SERVER_CERTS_DIR=$(parse_config "directories" "server_certs_dir" "./certs/server")
    fi
    
    SERVER_VALIDITY=$(parse_config "server_cert" "validity_days" "365")
    SERVER_KEY_SIZE=$(parse_config "server_cert" "key_size" "2048")
    
    local cert_dir="$SERVER_CERTS_DIR/$common_name"
    mkdir -p "$cert_dir"
    
    # Generate private key (no password for servers)
    openssl genrsa -out "$cert_dir/server.key" "$SERVER_KEY_SIZE"
    chmod 400 "$cert_dir/server.key"
    
    # Parse DNS names for SAN
    IFS=',' read -ra DNS_ARRAY <<< "$dns_names"
    local san_entries=""
    local counter=1
    for dns in "${DNS_ARRAY[@]}"; do
        dns=$(echo "$dns" | xargs)  # trim whitespace
        san_entries="${san_entries}DNS.${counter} = ${dns}\n"
        ((counter++))
    done
    
    # Create OpenSSL config
    cat > "$cert_dir/server.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $common_name

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$(echo -e "$san_entries")
EOF
    
    # Generate CSR
    openssl req -new -key "$cert_dir/server.key" \
        -out "$cert_dir/server.csr" \
        -config "$cert_dir/server.cnf"
    
    # Sign with Intermediate CA
    openssl x509 -req -days "$SERVER_VALIDITY" \
        -in "$cert_dir/server.csr" \
        -CA "$INTERMEDIATE_CA_DIR/intermediate-ca.crt" \
        -CAkey "$INTERMEDIATE_CA_DIR/intermediate-ca.key" \
        -CAcreateserial \
        -out "$cert_dir/server.crt" \
        -extfile "$cert_dir/server.cnf" \
        -extensions v3_req
    
    # Create full chain
    cat "$cert_dir/server.crt" "$INTERMEDIATE_CA_DIR/ca-chain.crt" > "$cert_dir/server-fullchain.crt"
    
    log_success "Server certificate generated: $cert_dir/server.crt"
}

# ============================================
# EXPORT FOR KUBERNETES CERT-MANAGER
# ============================================
export_for_kubernetes() {
    log_info "Exporting certificates for Kubernetes cert-manager..."
    
    K8S_ENABLED=$(parse_config "kubernetes" "enable_k8s_export" "true")
    if [[ "$K8S_ENABLED" != "true" ]]; then
        log_warning "Kubernetes export disabled in config"
        return
    fi
    
    K8S_NAMESPACE=$(parse_config "kubernetes" "namespace" "cert-manager")
    K8S_SECRET_NAME=$(parse_config "kubernetes" "ca_secret_name" "ca-secret")
    
    # Create Kubernetes secret YAML for CA
    cat > "$K8S_EXPORT_DIR/ca-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $K8S_SECRET_NAME
  namespace: $K8S_NAMESPACE
type: Opaque
data:
  tls.crt: $(base64 -w 0 "$INTERMEDIATE_CA_DIR/ca-chain.crt")
  tls.key: $(base64 -w 0 "$INTERMEDIATE_CA_DIR/intermediate-ca.key")
  ca.crt: $(base64 -w 0 "$ROOT_CA_DIR/root-ca.crt")
EOF
    
    # Create CA Issuer
    cat > "$K8S_EXPORT_DIR/ca-issuer.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca-issuer
spec:
  ca:
    secretName: $K8S_SECRET_NAME
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: homelab-ca-issuer
  namespace: $K8S_NAMESPACE
spec:
  ca:
    secretName: $K8S_SECRET_NAME
EOF
    
    # Create example Certificate CR
    cat > "$K8S_EXPORT_DIR/example-certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-tls-cert
  namespace: default
spec:
  secretName: example-tls-secret
  issuerRef:
    name: homelab-ca-issuer
    kind: ClusterIssuer
  commonName: example.homelab.local
  dnsNames:
    - example.homelab.local
    - "*.example.homelab.local"
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days
EOF
    
    # Create example Ingress with automatic cert-manager integration
    cat > "$K8S_EXPORT_DIR/example-ingress-auto-tls.yaml" <<EOF
# Example: Ingress with automatic TLS certificate generation
# cert-manager will automatically create and sign the certificate
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  namespace: default
  annotations:
    # This annotation tells cert-manager to automatically create a certificate
    cert-manager.io/cluster-issuer: "homelab-ca-issuer"
    # Optional: force SSL redirect
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # Optional: force HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx  # or your ingress class
  tls:
  - hosts:
    - myapp.homelab.local
    - api.homelab.local
    secretName: myapp-tls-auto  # cert-manager creates this automatically
  rules:
  - host: myapp.homelab.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp-service
            port:
              number: 80
  - host: api.homelab.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 8080
---
# Example: Wildcard Ingress with automatic certificate
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wildcard-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "homelab-ca-issuer"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - "*.apps.homelab.local"
    secretName: wildcard-apps-tls-auto
  rules:
  - host: "*.apps.homelab.local"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: default-backend
            port:
              number: 80
EOF
    
    # Create installation script
    cat > "$K8S_EXPORT_DIR/install-to-k8s.sh" <<EOF
#!/bin/bash
# Install CA certificates to Kubernetes

set -e

echo "================================================"
echo "  Installing HomeLab CA to Kubernetes"
echo "================================================"

echo ""
echo "[1/4] Creating namespace: $K8S_NAMESPACE"
kubectl create namespace $K8S_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "[2/4] Applying CA secret..."
kubectl apply -f ca-secret.yaml

echo ""
echo "[3/4] Applying CA issuer..."
kubectl apply -f ca-issuer.yaml

echo ""
echo "[4/4] Verifying installation..."
kubectl get clusterissuer homelab-ca-issuer
kubectl get secret $K8S_SECRET_NAME -n $K8S_NAMESPACE

echo ""
echo "================================================"
echo "  ✓ Installation Complete!"
echo "================================================"
echo ""
echo "Your Intermediate CA is now ready to automatically sign certificates."
echo ""
echo "Usage Options:"
echo ""
echo "1. Manual Certificate Creation:"
echo "   kubectl apply -f example-certificate.yaml"
echo ""
echo "2. Automatic via Ingress (RECOMMENDED):"
echo "   kubectl apply -f example-ingress-auto-tls.yaml"
echo ""
echo "3. Add to existing Ingress:"
echo "   Add annotation: cert-manager.io/cluster-issuer: homelab-ca-issuer"
echo ""
echo "cert-manager will automatically:"
echo "  • Create Certificate resource"
echo "  • Generate CSR"
echo "  • Sign with your Intermediate CA"
echo "  • Create TLS Secret"
echo "  • Renew before expiration"
echo ""
echo "Monitor certificates: kubectl get certificate -A"
echo "Check cert-manager logs: kubectl logs -n cert-manager -l app=cert-manager"
echo "================================================"
EOF
    
    chmod +x "$K8S_EXPORT_DIR/install-to-k8s.sh"
    
    log_success "Kubernetes manifests exported to: $K8S_EXPORT_DIR"
    log_info "Run: cd $K8S_EXPORT_DIR && ./install-to-k8s.sh"
}

# ============================================
# DISPLAY CERTIFICATE INFO
# ============================================
display_cert_info() {
    local cert_file=$1
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate file not found: $cert_file"
        return 1
    fi
    
    echo ""
    echo "================================================"
    echo "Certificate Information: $(basename "$cert_file")"
    echo "================================================"
    
    openssl x509 -noout -text -in "$cert_file" | grep -A2 "Subject:\|Issuer:\|Not Before\|Not After\|DNS:"
    
    echo "================================================"
    echo ""
}

# ============================================
# LIST ALL CERTIFICATES
# ============================================
list_all_certificates() {
    log_info "Scanning for certificates..."
    echo ""
    
    OUTPUT_DIR=$(parse_config "directories" "output_dir" "./certs")
    
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        log_warning "Certificate directory not found: $OUTPUT_DIR"
        return 1
    fi
    
    # Find all .crt files
    local cert_files=($(find "$OUTPUT_DIR" -name "*.crt" -type f 2>/dev/null))
    
    if [[ ${#cert_files[@]} -eq 0 ]]; then
        log_warning "No certificates found in $OUTPUT_DIR"
        return 1
    fi
    
    log_success "Found ${#cert_files[@]} certificate(s)"
    echo ""
    
    for cert_file in "${cert_files[@]}"; do
        local rel_path=$(realpath --relative-to="$SCRIPT_DIR" "$cert_file" 2>/dev/null || echo "$cert_file")
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}Certificate:${NC} $rel_path"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Extract certificate information
        local subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null | sed 's/subject=//')
        local issuer=$(openssl x509 -noout -issuer -in "$cert_file" 2>/dev/null | sed 's/issuer=//')
        local not_before=$(openssl x509 -noout -startdate -in "$cert_file" 2>/dev/null | sed 's/notBefore=//')
        local not_after=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | sed 's/notAfter=//')
        local fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" 2>/dev/null | sed 's/SHA256 Fingerprint=//')
        
        # Calculate days until expiration
        local expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null)
        local current_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
        
        echo -e "${YELLOW}Subject:${NC}      $subject"
        echo -e "${YELLOW}Issuer:${NC}       $issuer"
        echo -e "${YELLOW}Valid From:${NC}   $not_before"
        echo -e "${YELLOW}Valid Until:${NC}  $not_after"
        
        # Color code expiration warning
        if [[ $days_left -lt 0 ]]; then
            echo -e "${RED}Status:${NC}       EXPIRED ($days_left days ago)"
        elif [[ $days_left -lt 30 ]]; then
            echo -e "${RED}Status:${NC}       WARNING - Expires in $days_left days"
        elif [[ $days_left -lt 90 ]]; then
            echo -e "${YELLOW}Status:${NC}       Expires in $days_left days"
        else
            echo -e "${GREEN}Status:${NC}       Valid ($days_left days remaining)"
        fi
        
        echo -e "${YELLOW}Fingerprint:${NC}  $fingerprint"
        
        # Check for SAN entries
        local san=$(openssl x509 -noout -ext subjectAltName -in "$cert_file" 2>/dev/null | grep -v "X509v3 Subject Alternative Name:" | sed 's/^[[:space:]]*//')
        if [[ -n "$san" ]]; then
            echo -e "${YELLOW}DNS Names:${NC}    $san"
        fi
        
        echo ""
    done
}

# ============================================
# MAIN MENU
# ============================================
show_menu() {
    echo ""
    echo "================================================"
    echo "  CERTIFICATE AUTHORITY GENERATOR"
    echo "================================================"
    echo "1. Initialize CA (Root + Intermediate)"
    echo "2. Generate Server Certificate"
    echo "3. Export to Kubernetes"
    echo "4. List All Certificates"
    echo "5. Exit"
    echo "================================================"
    read -p "Select option [1-5]: " choice
    
    case $choice in
        1)
            setup_directories
            generate_root_ca
            generate_intermediate_ca
            export_for_kubernetes
            ;;
        2)
            read -p "Enter Common Name (e.g., app.homelab.local): " cn
            read -p "Enter DNS names (comma-separated, e.g., app.homelab.local,*.app.homelab.local): " dns
            generate_server_cert "$cn" "$dns"
            ;;
        3)
            export_for_kubernetes
            ;;
        4)
            list_all_certificates
            ;;
        5)
            log_info "Exiting..."
            exit 0
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
    
    show_menu
}

# ============================================
# MAIN ENTRY POINT
# ============================================
main() {
    log_info "Starting Certificate Authority Generator"
    log_info "Config file: $CONFIG_FILE"
    
    # Validate configuration file (mandatory)
    validate_config
    
    # Check for required tools
    for cmd in openssl base64; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # Check if script arguments provided
    if [[ $# -eq 0 ]]; then
        show_menu
    else
        # CLI mode
        case $1 in
            init)
                setup_directories
                generate_root_ca
                generate_intermediate_ca
                export_for_kubernetes
                ;;
            server)
                generate_server_cert "$2" "$3"
                ;;
            k8s-export)
                export_for_kubernetes
                ;;
            list)
                list_all_certificates
                ;;
            *)
                echo "Usage: $0 [init|server <cn> <dns>|k8s-export|list]"
                exit 1
                ;;
        esac
    fi
}

# Run main function
main "$@"


