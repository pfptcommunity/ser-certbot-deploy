# Secure Email Relay (SER) Connector Certbot Deploy Hook

A small Bash deploy hook for installing Certbot-managed TLS certificates into the standard SER connector certificate locations.

- The SER connector receives certificate and key files in predictable locations.
- The private key is installed with restrictive permissions.
- The `ser-connector` service is restarted after deployment.
- Existing certificate and key files are backed up before replacement.
- The deployed certificate and private key are validated as a matching pair.

## Disclaimer

This code is provided as-is, without warranty, support commitment, or guarantee of fitness for a particular purpose.

Users are responsible for reviewing, testing, and validating the script in their own environment before using it in production. Certificate deployment errors can cause TLS failures, service interruption, or mail-flow impact.

Always test in a lab or non-production environment first, and ensure that your operational rollback process is understood and validated before production use.

## Default SER connector directory and file layout

By default, deployed files are written to:

```text
/opt/ser/config/tls/certs/<deploy-name>.crt
/opt/ser/config/tls/private/<deploy-name>.key
```

For example, if the deploy name is `relay.company.com`, the deployed files are:

```text
/opt/ser/config/tls/certs/relay.company.com.crt
/opt/ser/config/tls/private/relay.company.com.key
```

A typical SER connector YAML configuration would reference those files:

```yaml
User:
# Modify and uncomment the following lines
  ConnectorUser:
    ClientID: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    ClientSecret: "<secret>"
  RelayUser:
    Username: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Password: "<secret>"
#NDR:
#  StoreBounces:
#   # Select one of the two following lines
#    Enable: true
#    Enable: false
#    Path: "Your path where to store the bounces if different from the default /var/spool/cmgw/deadletter"
#  ForwardEmail:
#   # Select one of the two following lines
#    Enable: true
#    Enable: false
#    FromAddress: "Your from address for NDR"
#    ToAddress: "Your to address for NDR"
#   # Select one of the three following lines
#    TlsMode: "forced TLS and verify"
#    TlsMode: "forced TLS"
#    TlsMode: "opportunistic"
Listener:
  - Port: 25
    Certificate: '/opt/ser/config/tls/certs/relay.company.com.crt'
    Key: '/opt/ser/config/tls/private/relay.company.com.key'
    StartTLS: 'optional'
    Type: SMTP
  - Port: 587
    Certificate: '/opt/ser/config/tls/certs/relay.company.com.crt'
    Key: '/opt/ser/config/tls/private/relay.company.com.key'
    Type: SMTPS
  - Port: 465
    Certificate: '/opt/ser/config/tls/certs/relay.company.com.crt'
    Key: '/opt/ser/config/tls/private/relay.company.com.key'
    Type: SMTPS

```

## How Certbot integration works

When Certbot runs a deploy hook, it provides environment variables to the hook script.

The most important one is:

```text
RENEWED_LINEAGE
```

This points to the specific Certbot live lineage directory for the renewed certificate.

Example:

```text
/etc/letsencrypt/live/relay.company.com
```

The script then reads:

```text
/etc/letsencrypt/live/relay.company.com/fullchain.pem
/etc/letsencrypt/live/relay.company.com/privkey.pem
```

Certbot may also provide:

```text
RENEWED_DOMAINS
```

Example:

```text
relay.company.com smtp.company.com
```

The script uses the first renewed domain as the default deploy name unless `--deploy-name` is provided.

## Deploy name

`--deploy-name` controls only the destination filename base used by the SER connector.

It does not change:

- the certificate subject
- the certificate SANs
- the Certbot certificate name
- the Certbot lineage path
- the source files under `/etc/letsencrypt/live`

Example:

```bash
--deploy-name outbound-relay
```

creates or updates:

```text
/opt/ser/config/tls/certs/outbound-relay.crt
/opt/ser/config/tls/private/outbound-relay.key
```

This is useful when the SER connector YAML uses a stable logical name that differs from the certificate's first domain.

## Install

Install the script as a root-owned administrative command:

```bash
sudo install -o root -g root -m 0755 ser-certbot-deploy.sh /usr/local/sbin/ser-certbot-deploy.sh
```

Use the absolute path in Certbot commands. Do not rely on `PATH` for automated renewal hooks.

## Basic Certbot usage

Single-name certificate:

```bash
sudo certbot certonly \
  --standalone \
  --agree-tos \
  --email user@company.com \
  --server <YOUR_ACME_OR_SCM_DIRECTORY_URL> \
  --eab-kid <YOUR_EAB_KEY_ID> \
  --eab-hmac-key <YOUR_EAB_HMAC_KEY> \
  --domain relay.company.com \
  --deploy-hook "/usr/local/sbin/ser-certbot-deploy.sh"
```

This will normally deploy:

```text
/opt/ser/config/tls/certs/relay.company.com.crt
/opt/ser/config/tls/private/relay.company.com.key
```

## Certbot usage with multiple SANs

A single certificate can contain multiple DNS names.

Example:

```bash
sudo certbot certonly \
  --standalone \
  --agree-tos \
  --email user@company.com \
  --server <YOUR_ACME_OR_SCM_DIRECTORY_URL> \
  --eab-kid <YOUR_EAB_KEY_ID> \
  --eab-hmac-key <YOUR_EAB_HMAC_KEY> \
  --domain relay.company.com \
  --domain smtp.company.com \
  --deploy-hook "/usr/local/sbin/ser-certbot-deploy.sh"
```

Even though the certificate is valid for multiple names, the script deploys one certificate/key pair for the SER connector.

By default, the first domain becomes the deploy name:

```text
relay.company.com
```

Result:

```text
/opt/ser/config/tls/certs/relay.company.com.crt
/opt/ser/config/tls/private/relay.company.com.key
```

## Certbot usage with explicit SER filename

Use `--deploy-name` when the SER connector YAML should use a logical or stable name instead of the first certificate domain.

```bash
sudo certbot certonly \
  --standalone \
  --agree-tos \
  --email user@company.com \
  --server <YOUR_ACME_OR_SCM_DIRECTORY_URL> \
  --eab-kid <YOUR_EAB_KEY_ID> \
  --eab-hmac-key <YOUR_EAB_HMAC_KEY> \
  --domain relay.company.com \
  --domain smtp.company.com \
  --deploy-hook "/usr/local/sbin/ser-certbot-deploy.sh --deploy-name outbound-relay"
```

Result:

```text
/opt/ser/config/tls/certs/outbound-relay.crt
/opt/ser/config/tls/private/outbound-relay.key
```

## Manual testing

Manual testing is useful before wiring the script into Certbot.

Dry run using a domain:

```bash
sudo /usr/local/sbin/ser-certbot-deploy.sh \
  --domains relay.company.com \
  --dry-run \
  --verbose
```

Dry run using a Certbot certificate name:

```bash
sudo /usr/local/sbin/ser-certbot-deploy.sh \
  --cert-name relay.company.com \
  --dry-run \
  --verbose
```

Dry run using a Certbot certificate name with a custom SER deploy filename:

```bash
sudo /usr/local/sbin/ser-certbot-deploy.sh \
  --cert-name relay.company.com \
  --deploy-name outbound-relay \
  --dry-run \
  --verbose
```

## Options

| Option | Purpose | When to use |
|---|---|---|
| `-l`, `--lineage PATH` | Advanced manual override for the Certbot lineage path | Usually not needed; Certbot provides `RENEWED_LINEAGE` during deploy hooks |
| `-n`, `--cert-name NAME` | Manual mode shortcut for `/etc/letsencrypt/live/<cert-name>` | Useful for manual testing |
| `-N`, `--deploy-name NAME` | Filename base for deployed SER cert/key files | Use when SER should use a name different from the certificate's first domain |
| `-d`, `--domains DOMAINS` | Domain names used for manual mode and deploy-name fallback | Usually provided by Certbot as `RENEWED_DOMAINS` during deploy hooks |
| `-s`, `--service NAME` | Override the SER service name to restart | Use only if your install uses a custom systemd service name |
| `-o`, `--owner USER` | Override owner for deployed files and created directories | Use only if your SER install uses a custom service account |
| `-g`, `--group GROUP` | Override group for deployed files and created directories | Use only if your SER install uses a custom group |
| `-f`, `--log-file PATH` | Optional log file path | If used, configure logrotate |
| `-t`, `--dry-run` | Show what would happen but do not modify files or restart services | Recommended for testing |
| `-r`, `--no-reload` | Deploy files but do not restart the service | Useful for controlled maintenance windows |
| `-v`, `--verbose` | Print more details | Useful for troubleshooting |
| `-h`, `--help` | Show help output | Use anytime |

## Defaults

| Setting | Default |
|---|---|
| Certificate directory | `/opt/ser/config/tls/certs` |
| Private key directory | `/opt/ser/config/tls/private` |
| Service name | `ser-connector` |
| Owner | `ser-connector` |
| Group | `root` |
| Certificate directory mode | `0755` |
| Private key directory mode | `0750` |
| Certificate file mode | `0644` |
| Private key file mode | `0600` |

## Logging

The script logs to stdout/stderr and also attempts to write to syslog using the tag:

```text
deploy-ser-cert
```

View logs with:

```bash
journalctl -t deploy-ser-cert
```

View Certbot service logs with:

```bash
journalctl -u certbot.service
```

Optional file logging can be enabled with:

```bash
--log-file /var/log/ser-certbot-deploy.log
```

If file logging is used long term, configure log rotation.

## Safety behavior

The script performs several safety checks before and during deployment. The SER connector is restarted because the service does not support reload:

- verifies source certificate and private key files exist
- verifies required commands are available
- verifies owner and group exist
- creates destination directories with expected ownership and permissions
- backs up existing deployed files before replacement
- installs certificate and key with explicit ownership and modes
- validates that the certificate and private key match
- restarts the SER service after deployment
- attempts rollback if service restart fails after deployment

## Certbot renewal behavior

If the deploy hook is saved in Certbot's renewal configuration, it will be reused during future renewals.

Check the renewal configuration with:

```bash
sudo cat /etc/letsencrypt/renewal/relay.company.com.conf
```

To test renewal behavior without replacing certificates, use:

```bash
sudo certbot renew --dry-run
```

## Notes

For production, prefer the standard deploy-hook form:

```bash
--deploy-hook "/usr/local/sbin/ser-certbot-deploy.sh"
```

Only pass `--deploy-name` when the SER destination filename should be different from the certificate's first domain.

Avoid placing the script in a user home directory for production use. Certbot renewals are normally run by system automation, and the hook should not depend on a user home path.
