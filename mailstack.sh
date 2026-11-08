#!/usr/bin/env bash
# Ubuntu 22.04 multi-domain virtual mail stack installer + mailadmin CLI.
# Usage: sudo bash mailstack.sh domain.com
set -Eeuo pipefail
umask 077

PRIMARY_DOMAIN="${1:-}"
MAIL_HOST="${MAIL_HOST:-}"
ROUNDCUBE_CONFIG="${ROUNDCUBE_CONFIG:-/var/www/roundcube/config/config.inc.php}"
ACME_WEBROOT="/var/www/mail-acme"
DB_NAME="mailserver"
DB_USER="mailuser"
DB_CNF="/etc/mailstack/mysql.cnf"
VMAIL_USER="vmail"
VMAIL_GROUP="vmail"
VMAIL_UID="5000"
VMAIL_GID="5000"
DKIM_SELECTOR="mail"

log() { printf '\n[mailstack] %s\n' "$*"; }
die() { printf '\n[mailstack] ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0 ..."; }
valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}
random_secret() { openssl rand -hex 24; }

install_mailstack() {
  need_root
  [[ -n "$PRIMARY_DOMAIN" ]] || die "Usage: sudo bash $0 yourdomain.com"
  PRIMARY_DOMAIN="${PRIMARY_DOMAIN,,}"
  valid_domain "$PRIMARY_DOMAIN" || die "Invalid domain: $PRIMARY_DOMAIN"
  [[ -n "$MAIL_HOST" ]] || MAIL_HOST="mx.$PRIMARY_DOMAIN"
  MAIL_HOST="${MAIL_HOST,,}"
  valid_domain "$MAIL_HOST" || die "Invalid mail hostname: $MAIL_HOST"

  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] || \
    die "This installer targets Ubuntu 22.04. Detected: ${PRETTY_NAME:-unknown}"

  command -v nginx >/dev/null 2>&1 || die "Nginx is not installed. Install/configure Nginx first; this script preserves your existing Nginx sites."
  command -v mysql >/dev/null 2>&1 && log "MariaDB/MySQL client already present." || true

  if dpkg -s exim4-config >/dev/null 2>&1 || dpkg -s exim4-daemon-light >/dev/null 2>&1 || dpkg -s exim4-daemon-heavy >/dev/null 2>&1; then
    log "Exim packages are installed. Backing up /etc/exim4 and removing Exim so Postfix can own SMTP."
    tar -czf "/root/exim4-backup-$(date +%Y%m%d-%H%M%S).tar.gz" /etc/exim4 2>/dev/null || true
    systemctl stop exim4 2>/dev/null || true
    systemctl disable exim4 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'exim4*' || die "Could not remove Exim. Resolve the package conflict and rerun."
  fi

  local admin_email admin_password db_password
  read -r -p "Primary administrator mailbox [admin@$PRIMARY_DOMAIN]: " admin_email
  admin_email="${admin_email:-admin@$PRIMARY_DOMAIN}"
  admin_email="${admin_email,,}"
  valid_email "$admin_email" || die "Invalid administrator email."
  [[ "$admin_email" == *"@$PRIMARY_DOMAIN" ]] || die "The initial administrator mailbox must use $PRIMARY_DOMAIN."
  read -r -s -p "Password for $admin_email (minimum 12 characters): " admin_password; echo
  [[ ${#admin_password} -ge 12 ]] || die "Use a password of at least 12 characters."
  db_password="$(random_secret)"

  log "Installing packages..."
  export DEBIAN_FRONTEND=noninteractive
  echo "postfix postfix/mailname string $PRIMARY_DOMAIN" | debconf-set-selections
  echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
  apt-get update
  apt-get install -y postfix postfix-mysql dovecot-imapd dovecot-lmtpd dovecot-mysql \
    mariadb-server opendkim opendkim-tools certbot ca-certificates openssl dnsutils

  log "Creating virtual-mail user and directories..."
  getent group "$VMAIL_GROUP" >/dev/null || groupadd --system --gid "$VMAIL_GID" "$VMAIL_GROUP"
  id "$VMAIL_USER" >/dev/null 2>&1 || useradd --system --uid "$VMAIL_UID" --gid "$VMAIL_GROUP" \
    --home-dir /var/vmail --create-home --shell /usr/sbin/nologin "$VMAIL_USER"
  install -d -o "$VMAIL_USER" -g "$VMAIL_GROUP" -m 0750 /var/vmail
  install -d -m 0750 /etc/mailstack
  install -d -m 0750 /etc/postfix/sql

  log "Configuring MariaDB..."
  systemctl enable --now mariadb
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${db_password}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${db_password}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${db_password}';
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  cat > "$DB_CNF" <<EOF
[client]
user=$DB_USER
password=$db_password
host=127.0.0.1
database=$DB_NAME
EOF
  chmod 0600 "$DB_CNF"

  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" <<'SQL'
CREATE TABLE IF NOT EXISTS virtual_domains (
  id INT NOT NULL AUTO_INCREMENT,
  name VARCHAR(255) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY (name)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS virtual_users (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  email VARCHAR(255) NOT NULL,
  password VARCHAR(255) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY (email),
  CONSTRAINT fk_user_domain FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS virtual_aliases (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  source VARCHAR(255) NOT NULL,
  destination VARCHAR(255) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY (source),
  CONSTRAINT fk_alias_domain FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;
SQL

  log "Configuring Postfix SQL maps..."
  cat > /etc/postfix/sql/mysql-virtual-mailbox-domains.cf <<EOF
user = $DB_USER
password = $db_password
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT 1 FROM virtual_domains WHERE name='%s'
EOF
  cat > /etc/postfix/sql/mysql-virtual-mailbox-maps.cf <<EOF
user = $DB_USER
password = $db_password
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT 1 FROM virtual_users WHERE email='%s'
EOF
  cat > /etc/postfix/sql/mysql-virtual-alias-maps.cf <<EOF
user = $DB_USER
password = $db_password
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT destination FROM virtual_aliases WHERE source='%s'
EOF
  chown root:postfix /etc/postfix/sql/*.cf
  chmod 0640 /etc/postfix/sql/*.cf

  postconf -e "myhostname = $MAIL_HOST"
  postconf -e "myorigin = /etc/mailname"
  postconf -e "mydestination = localhost"
  postconf -e "inet_interfaces = all"
  postconf -e "inet_protocols = ipv4"
  postconf -e "mynetworks = 127.0.0.0/8 [::1]/128"
  postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/sql/mysql-virtual-mailbox-domains.cf"
  postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/sql/mysql-virtual-mailbox-maps.cf"
  postconf -e "virtual_alias_maps = mysql:/etc/postfix/sql/mysql-virtual-alias-maps.cf"
  postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
  postconf -e "virtual_mailbox_base = /var/vmail"
  postconf -e "virtual_uid_maps = static:$VMAIL_UID"
  postconf -e "virtual_gid_maps = static:$VMAIL_GID"
  postconf -e "smtpd_sasl_type = dovecot"
  postconf -e "smtpd_sasl_path = private/auth"
  postconf -e "smtpd_sasl_auth_enable = yes"
  postconf -e "smtpd_sasl_security_options = noanonymous"
  postconf -e "smtpd_sasl_local_domain ="
  postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
  postconf -e "smtpd_relay_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
  postconf -e "smtpd_tls_security_level = may"
  postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/$MAIL_HOST/fullchain.pem"
  postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/$MAIL_HOST/privkey.pem"
  postconf -e "smtp_tls_security_level = may"
  postconf -e "smtpd_tls_auth_only = yes"
  postconf -e "smtpd_tls_loglevel = 1"
  postconf -e "smtpd_milters = inet:127.0.0.1:8891"
  postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"
  postconf -e "milter_default_action = accept"
  postconf -e "milter_protocol = 6"
  postconf -e "message_size_limit = 30720000"

  if ! grep -qE '^submission[[:space:]]+inet' /etc/postfix/master.cf; then
    cat >> /etc/postfix/master.cf <<'EOF'

# Mailstack: authenticated message submission on port 587
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
  fi

  log "Configuring Dovecot..."
  cat > /etc/dovecot/dovecot.conf <<'EOF'
!include_try /usr/share/dovecot/protocols.d/*.protocol
!include conf.d/*.conf
EOF
  cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:/var/vmail/%d/%n/Maildir
mail_privileged_group = mail
first_valid_uid = $VMAIL_UID
last_valid_uid = $VMAIL_UID
mail_access_groups = $VMAIL_GROUP
namespace inbox {
  inbox = yes
}
EOF
  cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-sql.conf.ext
EOF
  cat > /etc/dovecot/conf.d/auth-sql.conf.ext <<'EOF'
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
  driver = static
  args = uid=5000 gid=5000 home=/var/vmail/%d/%n
}
EOF
  cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=127.0.0.1 dbname=$DB_NAME user=$DB_USER password=$db_password
default_pass_scheme = SHA512-CRYPT
password_query = SELECT email AS user, password FROM virtual_users WHERE email='%u'
EOF
  chmod 0600 /etc/dovecot/dovecot-sql.conf.ext
  cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
service lmtp {
  unix_listener lmtp {
  }
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service imap {
}
service auth {
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
service auth-worker {
  user = $default_internal_user
}
EOF
  cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/$MAIL_HOST/fullchain.pem
ssl_key = </etc/letsencrypt/live/$MAIL_HOST/privkey.pem
EOF
  cat > /etc/dovecot/conf.d/20-imap.conf <<'EOF'
protocol imap {
  mail_max_userip_connections = 20
}
EOF
  cat > /etc/dovecot/conf.d/20-lmtp.conf <<'EOF'
protocol lmtp {
  postmaster_address = postmaster@localhost
}
EOF

  log "Preparing Let's Encrypt webroot for $MAIL_HOST..."
  install -d -m 0755 "$ACME_WEBROOT/.well-known/acme-challenge"
  local nginx_site="/etc/nginx/sites-available/mailstack-acme-$MAIL_HOST"
  cat > "$nginx_site" <<EOF
server {
    listen 80;
    server_name $MAIL_HOST;
    root $ACME_WEBROOT;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 404; }
}
EOF
  ln -sfn "$nginx_site" "/etc/nginx/sites-enabled/mailstack-acme-$MAIL_HOST"
  nginx -t
  systemctl reload nginx

  local admin_email_for_cert="$admin_email"
  if ! certbot certonly --webroot -w "$ACME_WEBROOT" -d "$MAIL_HOST" \
      --non-interactive --agree-tos -m "$admin_email_for_cert" --keep-until-expiring; then
    die "Let's Encrypt could not issue a certificate for $MAIL_HOST. Check that its DNS A record points to this server, Cloudflare proxy is OFF (DNS-only), and inbound port 80 is reachable. Fix DNS and rerun."
  fi

  log "Configuring OpenDKIM..."
  install -d -o opendkim -g opendkim -m 0750 /etc/opendkim/keys
  cat > /etc/opendkim.conf <<'EOF'
Syslog                  yes
UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1h
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
Socket                  inet:8891@localhost
PidFile                 /run/opendkim/opendkim.pid
UserID                  opendkim
KeyTable                /etc/opendkim/key.table
SigningTable            refile:/etc/opendkim/signing.table
ExternalIgnoreList      /etc/opendkim/trusted.hosts
InternalHosts           /etc/opendkim/trusted.hosts
EOF
  if [[ -f /etc/default/opendkim ]]; then
    if grep -q '^SOCKET=' /etc/default/opendkim; then
      sed -i 's|^SOCKET=.*|SOCKET="inet:8891@localhost"|' /etc/default/opendkim
    else
      echo 'SOCKET="inet:8891@localhost"' >> /etc/default/opendkim
    fi
  fi
  touch /etc/opendkim/key.table /etc/opendkim/signing.table
  cat > /etc/opendkim/trusted.hosts <<'EOF'
127.0.0.1
localhost
::1
EOF
  chown opendkim:opendkim /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts
  chmod 0640 /etc/opendkim/key.table /etc/opendkim/signing.table /etc/opendkim/trusted.hosts

  # Install administration command before using it.
  install -m 0755 "$0" /usr/local/sbin/mailadmin
  # Make sure installed command defaults to CLI mode.
  local hash
  hash="$(doveadm pw -s SHA512-CRYPT -p "$admin_password")"
  add_domain_db "$PRIMARY_DOMAIN"
  add_mailbox_db "$admin_email" "$hash"
  add_alias_db "postmaster@$PRIMARY_DOMAIN" "$admin_email"
  add_alias_db "dmarc@$PRIMARY_DOMAIN" "$admin_email"
  configure_dkim_domain "$PRIMARY_DOMAIN"

  # Make Roundcube use this server for IMAP and SMTP. Existing DB settings remain untouched.
  if [[ -f "$ROUNDCUBE_CONFIG" ]]; then
    local rc_backup="$ROUNDCUBE_CONFIG.mailstack-backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$ROUNDCUBE_CONFIG" "$rc_backup"
    python3 - "$ROUNDCUBE_CONFIG" "$MAIL_HOST" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
host = sys.argv[2]
s = p.read_text()
s = re.sub(r'\s*\?>\s*$', '\n', s)
block = f"""
// BEGIN mailstack managed settings
$config['default_host'] = 'ssl://{host}';
$config['default_port'] = 993;
$config['smtp_server'] = 'tls://{host}';
$config['smtp_port'] = 587;
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
// END mailstack managed settings
"""
s = re.sub(r'(?s)\\n?// BEGIN mailstack managed settings.*?// END mailstack managed settings\\n?', '\n', s)
p.write_text(s.rstrip() + '\n' + block)
PY
    log "Roundcube settings appended to $ROUNDCUBE_CONFIG (backup created)."
  else
    log "Roundcube config not found at $ROUNDCUBE_CONFIG; skipped automatic integration."
  fi

  # Add primary domain records and save installation metadata.
  local public_ip
  public_ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  cat > /etc/mailstack/settings <<EOF
PRIMARY_DOMAIN=$PRIMARY_DOMAIN
MAIL_HOST=$MAIL_HOST
PUBLIC_IP=$public_ip
DB_NAME=$DB_NAME
DB_USER=$DB_USER
EOF
  chmod 0600 /etc/mailstack/settings

  systemctl enable --now opendkim dovecot
  systemctl restart opendkim
  systemctl enable --now postfix
  systemctl restart dovecot postfix

  unset admin_password db_password
  log "Installation complete."
  echo
  echo "Mail hostname: $MAIL_HOST"
  echo "Public IPv4 detected: ${public_ip:-not detected}"
  if [[ -n "$public_ip" ]]; then
    echo "Reverse DNS (PTR): $(dig +short -x "$public_ip" | head -n1 || true)"
    if timeout 5 bash -c 'cat </dev/null >/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
      echo "Outbound TCP/25: reachable (not a reputation guarantee)"
    else
      echo "WARNING: outbound TCP/25 test failed or timed out; ask your host to unblock SMTP."
    fi
  fi
  echo "Administrator: $admin_email"
  echo "Roundcube URL: https://mail.$PRIMARY_DOMAIN"
  echo
  echo "DNS records to create for $PRIMARY_DOMAIN:"
  print_dns "$PRIMARY_DOMAIN"
  echo
  echo "Next: sudo mailadmin list"
  echo "Add another domain: sudo mailadmin add-domain example.com"
  echo "IMPORTANT: Set MX records to $MAIL_HOST and keep the MX hostname DNS-only in Cloudflare."
}

add_domain_db() {
  local domain="${1,,}"
  valid_domain "$domain" || die "Invalid domain: $domain"
  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
    "INSERT IGNORE INTO virtual_domains (name) VALUES ('$domain');"
}

add_mailbox_db() {
  local email="${1,,}" hash="$2" domain
  valid_email "$email" || die "Invalid email address: $email"
  domain="${email##*@}"
  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
    "INSERT INTO virtual_domains (name) VALUES ('$domain') ON DUPLICATE KEY UPDATE name=VALUES(name);"
  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
    "INSERT INTO virtual_users (domain_id,email,password) SELECT id,'$email','$hash' FROM virtual_domains WHERE name='$domain' ON DUPLICATE KEY UPDATE password=VALUES(password);"
  install -d -o "$VMAIL_USER" -g "$VMAIL_GROUP" -m 0750 "/var/vmail/$domain/${email%@*}/Maildir"
  for d in cur new tmp; do install -d -o "$VMAIL_USER" -g "$VMAIL_GROUP" -m 0700 "/var/vmail/$domain/${email%@*}/Maildir/$d"; done
}

add_alias_db() {
  local source="${1,,}" destination="${2,,}" domain
  valid_email "$source" && valid_email "$destination" || die "Invalid alias or destination address."
  domain="${source##*@}"
  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
    "INSERT INTO virtual_domains (name) VALUES ('$domain') ON DUPLICATE KEY UPDATE name=VALUES(name);"
  mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
    "INSERT INTO virtual_aliases (domain_id,source,destination) SELECT id,'$source','$destination' FROM virtual_domains WHERE name='$domain' ON DUPLICATE KEY UPDATE destination=VALUES(destination);"
}

configure_dkim_domain() {
  local domain="${1,,}" dir="/etc/opendkim/keys/${1,,}" keyfile
  valid_domain "$domain" || die "Invalid domain: $domain"
  install -d -o opendkim -g opendkim -m 0750 "$dir"
  keyfile="$dir/$DKIM_SELECTOR.private"
  if [[ ! -s "$keyfile" ]]; then
    opendkim-genkey -b 2048 -d "$domain" -D "$dir" -s "$DKIM_SELECTOR"
    chown opendkim:opendkim "$keyfile" "$dir/$DKIM_SELECTOR.txt"
    chmod 0600 "$keyfile"
  fi
  grep -qF "$DKIM_SELECTOR._domainkey.$domain" /etc/opendkim/key.table || \
    echo "$DKIM_SELECTOR._domainkey.$domain $domain:$DKIM_SELECTOR:$keyfile" >> /etc/opendkim/key.table
  grep -qF "*@$domain" /etc/opendkim/signing.table || \
    echo "*@$domain $DKIM_SELECTOR._domainkey.$domain" >> /etc/opendkim/signing.table
  chown opendkim:opendkim /etc/opendkim/key.table /etc/opendkim/signing.table
  chmod 0640 /etc/opendkim/key.table /etc/opendkim/signing.table
  add_domain_db "$domain"
}

print_dns() {
  local domain="$1" dkimfile="/etc/opendkim/keys/$1/$DKIM_SELECTOR.txt"
  local mailhost="${MAIL_HOST:-mx.$PRIMARY_DOMAIN}"
  local publicip="${PUBLIC_IP:-<SERVER-PUBLIC-IP>}"
  echo "A      ${mailhost%%.*}                  -> $publicip  (DNS only / grey cloud)"
  echo "MX     @                   -> 10 $mailhost."
  echo "TXT    @                   -> v=spf1 mx -all"
  echo "TXT    _dmarc              -> v=DMARC1; p=none; rua=mailto:dmarc@$domain; fo=1"
  if [[ -f "$dkimfile" ]]; then
    echo
    echo "DKIM record (copy the TXT record from this file): $dkimfile"
    cat "$dkimfile"
  fi
}

mailadmin_main() {
  need_root
  [[ -f "$DB_CNF" && -f /etc/mailstack/settings ]] || die "Mail stack is not installed. Run the installer first."
  # shellcheck disable=SC1091
  . /etc/mailstack/settings
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    add-domain)
      [[ $# -eq 1 ]] || die "Usage: mailadmin add-domain example.com"
      local domain="${1,,}"
      valid_domain "$domain" || die "Invalid domain."
      add_domain_db "$domain"
      configure_dkim_domain "$domain"
      systemctl restart opendkim postfix
      echo "Added $domain. Publish the DNS records printed below, with MX pointing to the configured mail hostname."
      print_dns "$domain"
      ;;
    add-user)
      [[ $# -ge 1 && $# -le 2 ]] || die "Usage: mailadmin add-user user@domain.com [password]"
      local email="${1,,}" password="${2:-}" hash
      if [[ -z "$password" ]]; then read -r -s -p "Password for $email: " password; echo; fi
      [[ ${#password} -ge 12 ]] || die "Password must be at least 12 characters."
      hash="$(doveadm pw -s SHA512-CRYPT -p "$password")"
      add_mailbox_db "$email" "$hash"
      unset password hash
      echo "Created/updated $email"
      ;;
    set-password)
      [[ $# -eq 1 ]] || die "Usage: mailadmin set-password user@domain.com"
      local email="${1,,}" password hash
      valid_email "$email" || die "Invalid email."
      read -r -s -p "New password for $email: " password; echo
      [[ ${#password} -ge 12 ]] || die "Password must be at least 12 characters."
      hash="$(doveadm pw -s SHA512-CRYPT -p "$password")"
      mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
        "UPDATE virtual_users SET password='$hash' WHERE email='$email';"
      unset password hash
      echo "Password updated (if the mailbox exists)."
      ;;
    add-alias)
      [[ $# -eq 2 ]] || die "Usage: mailadmin add-alias alias@domain.com destination@domain.com"
      add_alias_db "$1" "$2"
      echo "Alias created: $1 -> $2"
      ;;
    list)
      mysql --defaults-extra-file="$DB_CNF" "$DB_NAME" -e \
        "SELECT name AS domains FROM virtual_domains ORDER BY name; SELECT email AS mailboxes FROM virtual_users ORDER BY email; SELECT source AS alias,destination AS forwards_to FROM virtual_aliases ORDER BY source;"
      ;;
    dns)
      [[ $# -eq 1 ]] || die "Usage: mailadmin dns domain.com"
      print_dns "${1,,}"
      ;;
    help|*)
      cat <<'EOF'
mailadmin commands:
  mailadmin add-domain example.com
  mailadmin add-user user@example.com
  mailadmin set-password user@example.com
  mailadmin add-alias alias@example.com destination@example.com
  mailadmin list
  mailadmin dns example.com
EOF
      ;;
  esac
}

if [[ "${0##*/}" == "mailadmin" ]]; then
  mailadmin_main "$@"
else
  install_mailstack
fi
