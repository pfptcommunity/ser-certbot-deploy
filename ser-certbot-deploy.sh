#!/usr/bin/env bash
################################################################################
#
#          Name: Ludvik Jerabek
#          Date: 06/09/2026
#       Version: 1.0
#
#       Summary: Command line tool for certbot deployment for SER Connector
#
#       Change History:
#
#       06/09/2026 - Initial Release
#
################################################################################

# Fail fast and avoid surprises:
#   -e stops on failed commands
#   -u catches misspelled or unset variables
#   pipefail prevents hidden failures in command pipelines
set -euo pipefail

# Keep the script name dynamic so usage output still looks correct
# even if the file is renamed later.
SCRIPT_NAME="$(basename "$0")"

# Certbot normally provides RENEWED_LINEAGE and RENEWED_DOMAINS when this
# script is used as a deploy hook. These defaults also allow the same script
# to be run manually with explicit arguments.
LINEAGE=""
CERT_NAME=""
DEPLOY_NAME=""
DOMAINS="${RENEWED_DOMAINS:-}"

# Source paths are resolved after we know which Certbot lineage to use.
CERT_SRC=""
KEY_SRC=""

# Default SER certificate and key directories.
# Destination filenames are normally derived from the deploy name, cert name,
# or primary domain so multiple certificates can coexist safely.
CERT_DIR="/opt/ser/config/tls/certs"
KEY_DIR="/opt/ser/config/tls/private"

# Destination certificate and key paths are resolved later from the standard
# SER directories and the derived deployment filename.
CERT_DST=""
KEY_DST=""

# These defaults match the SER connector service account. The certificate is
# world-readable, but the private key is locked down later with mode 0600.
SERVICE_NAME="ser-connector"
CERT_OWNER="ser-connector"
CERT_GROUP="root"
CERT_DIR_MODE="0755"
KEY_DIR_MODE="0750"
CERT_FILE_MODE="0644"
KEY_FILE_MODE="0600"


# Logging is optional because many deploy hooks already run under automation.
# When enabled, stdout and stderr are redirected to this file. If you decide
# to log to a file long term, you should setup logrotate to clean up log files.
LOG_FILE=""

# Backup suffix. This is generated only after path resolution so all backup
# files from a single run share the same timestamp.
STAMP=""

# Runtime flags. Use integer values because Bash conditionals are simple and
# predictable with [[ "$FLAG" -eq 1 ]].
DRY_RUN=0
NO_RESTART=0
VERBOSE=0

# This provides the basic usage and help information when no correct arguments
# or environment variables are passed. 
brief_usage() {
  echo "Usage: $SCRIPT_NAME [options]"
  echo "Try '$SCRIPT_NAME --help' for more information."
  echo
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
EOF


  cat <<EOF | column -s'&' -t
  -l, --lineage &Advanced manual override for the Certbot lineage path
                     &Usually not needed; Certbot provides RENEWED_LINEAGE during deploy hooks
                     &Example: /etc/letsencrypt/live/relay.company.com
  &
  -n, --cert-name &Manual mode shortcut for /etc/letsencrypt/live/<cert-name>
                       &Usually not needed during Certbot deploy-hook execution
                       &Example: relay.company.com resolves to /etc/letsencrypt/live/relay.company.com
  &
  -N, --deploy-name &Filename base for deployed SER cert/key files
                        &Use only when SER should use a name different from the certificate's first domain
                        &Example: outbound-relay creates outbound-relay.crt and outbound-relay.key
  &
  -d, --domains &Domain names used for manual mode and deploy-name fallback
                        &Usually provided by Certbot as RENEWED_DOMAINS during deploy hooks
                        &Example: relay.company.com
  &
  -s, --service &Override the SER service name to restart
                    &Use only if your install uses a custom systemd service name
                    &Default: $SERVICE_NAME
  &
  -o, --owner &Override owner for deployed files and created directories
                  &Use only if your SER install uses a custom service account
                  &Default: $CERT_OWNER
  &
  -g, --group &Override group for deployed files and created directories
                   &Use only if your SER install uses a custom group
                   &Default: $CERT_GROUP
  &
  -f, --log-file &Optional log file path. If used, configure logrotate.
                     &Default: disabled; syslog/journald is still used when available
  &
  -t, --dry-run &Show what would happen but do not modify files or restart services
  &
  -r, --no-restart &Deploy files but do not restart the service
  &
  -v, --verbose &Print more details
  &
  -h, --help &Show this help
EOF

  cat <<EOF

The following examples show how to use this tool with Certbot or for manual testing.

Certbot deploy-hook mode:
  certbot certonly \\
    --manual \\
    --preferred-challenges dns \\
    --domain relay.company.com \\
    --deploy-hook "/path/to/$SCRIPT_NAME"

Certbot deploy-hook mode with explicit SER filename:
  certbot certonly \\
    --manual \\
    --preferred-challenges dns \\
    --domain relay.company.com \\
    --domain smtp.company.com \\
    --deploy-hook "/path/to/$SCRIPT_NAME --deploy-name outbound-relay"

Manual testing:
  $SCRIPT_NAME --domains relay.company.com --dry-run --verbose
  $SCRIPT_NAME --cert-name relay.company.com --dry-run --verbose
  $SCRIPT_NAME --cert-name relay.company.com --deploy-name outbound-relay --dry-run --verbose
  
The following examples show how to view or follow logs created by this tool.

  View SER certificate deploy logs:
    journalctl -t ser-certbot-deploy

  Follow SER certificate deploy logs:
    journalctl -t ser-certbot-deploy -f

EOF
}

# Logging function logs to the current output stream and also try syslog. 
# Syslog is best effort so a missing logger service never breaks certificate deployment.
log() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%:z')] $msg"
  logger -t ser-certbot-deploy -- "$msg" 2>/dev/null || true
}

# Error logging function logs to the current output stream and also try syslog. 
# Syslog is best effort so a missing logger service never breaks certificate deployment.
error() {
  local msg="ERROR: $*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%:z')] $msg" >&2
  logger -t ser-certbot-deploy -p user.err -- "$msg" 2>/dev/null || true
}

# Keep normal output clean, but make troubleshooting easy when -v is used.
debug() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    log "DEBUG: $*"
  fi
}

# Centralize dry-run behavior so file operations can be written once and
# safely reused without sprinkling dry-run checks everywhere.
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
  else
    debug "RUN: $*"
    "$@"
  fi
}

# Use one exit path for fatal errors so logging stays consistent.
fail() {
  error "$*"
  exit 1
}

# Catches arguments that require a value.
require_value() {
  local opt_name="$1"

  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    echo "ERROR: $opt_name requires a value" >&2
    usage >&2
    exit 1
  fi

  if [[ "$2" == -* ]]; then
    echo "ERROR: $opt_name requires a value before: $2" >&2
    usage >&2
    exit 1
  fi
}

# Parse command line args taking into account call from certbot vs someone manually running the tool. 
parse_args() {

  # No args means Certbot deploy-hook mode; require RENEWED_LINEAGE.
  if [[ $# -eq 0 && -z "${RENEWED_LINEAGE:-}" ]]; then
    brief_usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--lineage)
        require_value "$1" "${2:-}"
        LINEAGE="$2"
        shift 2
        ;;

      -n|--cert-name)
        require_value "$1" "${2:-}"
        CERT_NAME="$2"
        shift 2
        ;;

      -N|--deploy-name|-H|--hostname)
        require_value "$1" "${2:-}"
        DEPLOY_NAME="$2"
        shift 2
        ;;

      -d|--domains)
        require_value "$1" "${2:-}"
        DOMAINS="$2"
        shift 2
        ;;


      -s|--service)
        require_value "$1" "${2:-}"
        SERVICE_NAME="$2"
        shift 2
        ;;

      -o|--owner)
        require_value "$1" "${2:-}"
        CERT_OWNER="$2"
        shift 2
        ;;

      -g|--group)
        require_value "$1" "${2:-}"
        CERT_GROUP="$2"
        shift 2
        ;;

      -f|--log-file)
        require_value "$1" "${2:-}"
        LOG_FILE="$2"
        shift 2
        ;;

      -t|--dry-run)
        DRY_RUN=1
        shift
        ;;

      -r|--no-restart)
        NO_RESTART=1
        shift
        ;;

      -v|--verbose)
        VERBOSE=1
        shift
        ;;

      -h|--help)
        usage
        exit 0
        ;;

      --)
        # Stop option parsing in the standard Unix style. Any remaining values
        # are rejected below because this script does not accept positional args.
        shift
        break
        ;;

      -*)
        echo "ERROR: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;

      *)
        echo "ERROR: unexpected argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    echo "ERROR: unexpected argument(s): $*" >&2
    usage >&2
    exit 1
  fi
}

# Resolve Certbot lineage from explicit input or deploy-hook variables.
# Lineage precedence: --lineage, RENEWED_LINEAGE, --cert-name, single --domains.
derive_lineage() {
  if [[ -z "$LINEAGE" && -n "${RENEWED_LINEAGE:-}" ]]; then
    LINEAGE="$RENEWED_LINEAGE"
  fi

  if [[ -z "$LINEAGE" && -n "$CERT_NAME" ]]; then
    LINEAGE="/etc/letsencrypt/live/$CERT_NAME"
  fi

  if [[ -z "$LINEAGE" && -n "$DOMAINS" ]]; then
    local first_domain
    first_domain="${DOMAINS%% *}"

    # Only infer lineage from --domains when one domain was provided.
    if [[ "$DOMAINS" != *" "* ]]; then
      LINEAGE="/etc/letsencrypt/live/$first_domain"
    fi
  fi
}

# Dry runs stay visible; real runs might log to file.
setup_logging() {
  if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then
    touch "$LOG_FILE"
    chmod 0644 "$LOG_FILE"
    exec >> "$LOG_FILE" 2>&1
  fi
}

# Log what was resolved before implementing changes.
log_config() {
  log "==== Starting certificate deploy ===="
  log "Script: $SCRIPT_NAME"
  log "Domains: ${DOMAINS:-unknown}"
  log "Cert name: ${CERT_NAME:-not provided}"
  log "Deploy name: ${DEPLOY_NAME:-not provided}"
  log "Lineage: ${LINEAGE:-unset}"
  log "Certificate source: ${CERT_SRC:-unset}"
  log "Private key source: ${KEY_SRC:-unset}"
  log "Certificate destination: $CERT_DST"
  log "Private key destination: $KEY_DST"
  log "Service: $SERVICE_NAME"
  log "Owner: $CERT_OWNER"
  log "Group: $CERT_GROUP"
  log "Dry run: $DRY_RUN"
  log "No restart: $NO_RESTART"
  log "Log file: ${LOG_FILE:-disabled}"
}

# Used to choose a safe filename base for derived certificate and key paths.
derive_certificate_filename() {
  local output_name=""

  if [[ -n "$DEPLOY_NAME" ]]; then
    output_name="$DEPLOY_NAME"
  elif [[ -n "$CERT_NAME" ]]; then
    output_name="$CERT_NAME"
  elif [[ -n "$DOMAINS" ]]; then
    output_name="${DOMAINS%% *}"
  elif [[ -n "$LINEAGE" ]]; then
    output_name="$(basename "$LINEAGE")"
  fi

  [[ -n "$output_name" ]] || fail "unable to derive certificate filename. Use --deploy-name, --cert-name, or --domains"

  # Make wildcard certificate names filesystem friendly.
  if [[ "$output_name" == \*.* ]]; then
    output_name="wildcard.${output_name:2}"
  fi

  if [[ ! "$output_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "invalid certificate filename derived from deploy-name/cert-name/domain: $output_name"
  fi

  echo "$output_name"
}

# Used to name destination files from the deploy-name/cert-name/domain using the
# standard SER certificate and key directories.
derive_destination_paths() {
  local output_name

  output_name="$(derive_certificate_filename)"

  CERT_DST="${CERT_DIR}/${output_name}.crt"
  KEY_DST="${KEY_DIR}/${output_name}.key"
}

# No lineage, no deploy. Guessing cert paths is how gremlins win.
resolve_paths() {
  [[ -n "$LINEAGE" ]] || fail "certificate lineage is not set. Use --lineage, --cert-name, --domains, or run this script from a Certbot deploy hook"

  CERT_SRC="${LINEAGE}/fullchain.pem"
  KEY_SRC="${LINEAGE}/privkey.pem"

  derive_destination_paths

  CERT_DIR="$(dirname "$CERT_DST")"
  KEY_DIR="$(dirname "$KEY_DST")"

  STAMP="$(date +%F-%H%M%S)"
}

# Used to check ownership early so install does not fail halfway through. 
# Certs, keys, and paths must have the correct permissions.
validate_user() {
  local user_name="$1"
  
  if ! id -u "$user_name" >/dev/null 2>&1; then
    fail "owner user does not exist: $user_name"
  fi
}

# Used to check group early so install does not fail halfway through. 
# Certs, keys, and paths must have the correct permissions.
validate_group() {
  local group_name="$1"

  if ! getent group "$group_name" >/dev/null 2>&1; then
    fail "group does not exist: $group_name"
  fi
}

# Used to check required command before deployment starts.
require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "$command_name is required but was not found"
  fi
}

# Used to validate all needed tools and paths exist before executing.
preflight_checks() {
  [[ -f "$CERT_SRC" ]] || fail "missing certificate: $CERT_SRC"
  [[ -f "$KEY_SRC" ]] || fail "missing private key: $KEY_SRC"

  require_command openssl
  require_command id
  require_command getent
  require_command dirname
  require_command basename
  require_command install

  validate_user "$CERT_OWNER"
  validate_group "$CERT_GROUP"

  # Let dry-run and --no-restart work without systemctl.
  if [[ "$DRY_RUN" -eq 0 && "$NO_RESTART" -eq 0 ]]; then
    require_command systemctl
  fi
}

# Used to create the target directories if the appliance or lab image does not have
# them yet. Existing directories are left alone.
create_destination_dirs() {
  run install -d -o "$CERT_OWNER" -g "$CERT_GROUP" -m "$CERT_DIR_MODE" "$CERT_DIR"
  run install -d -o "$CERT_OWNER" -g "$CERT_GROUP" -m "$KEY_DIR_MODE" "$KEY_DIR"
}

# Used to keep timestamped copies before replacing anything. If a cert deploy breaks
# service behavior, these backups make rollback fast and obvious.
backup_existing_files() {
  if [[ -f "$CERT_DST" ]]; then
    run cp -a "$CERT_DST" "${CERT_DST}.${STAMP}.bak"
  fi

  if [[ -f "$KEY_DST" ]]; then
    run cp -a "$KEY_DST" "${KEY_DST}.${STAMP}.bak"
  fi
}

# Used to install instead of cp/chown/chmod so ownership and permissions are set
# atomically as part of the file deployment step.
install_certificates() {
  run install -o "$CERT_OWNER" -g "$CERT_GROUP" -m "$CERT_FILE_MODE" "$CERT_SRC" "$CERT_DST"
  run install -o "$CERT_OWNER" -g "$CERT_GROUP" -m "$KEY_FILE_MODE" "$KEY_SRC" "$KEY_DST"
}

 # Compares the public key derived from the certificate, not filenames or dates.
certificate_public_hash() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -pubkey -noout | openssl sha256
}

# Derives the public key from the private key so it can be compared safely
# without printing or exposing private key material.
private_key_public_hash() {
  local key_path="$1"
  openssl pkey -in "$key_path" -pubout | openssl sha256
}

# Validate what was deployed during live execution. In dry-run mode, validate the
# source files because nothing is written to the destination paths.
validate_certificate_pair() {
  local cert_path
  local key_path
  local cert_label

  if [[ "$DRY_RUN" -eq 0 ]]; then
    cert_path="$CERT_DST"
    key_path="$KEY_DST"
    cert_label="deployed"
  else
    cert_path="$CERT_SRC"
    key_path="$KEY_SRC"
    cert_label="source"
  fi

  local cert_pub
  local key_pub

  cert_pub="$(certificate_public_hash "$cert_path")"
  key_pub="$(private_key_public_hash "$key_path")"

  # A mismatched keypair would cause TLS failures after restart, so stop before
  # declaring the deployment successful.
  if [[ "$cert_pub" != "$key_pub" ]]; then
    fail "$cert_label certificate and private key do not match"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: source certificate and private key match"
  else
    log "Certificate and private key match"
  fi
}

# Used to rollback certificates to the prior set. 
rollback_certificates() {
  if [[ -f "${CERT_DST}.${STAMP}.bak" && -f "${KEY_DST}.${STAMP}.bak" ]]; then
    log "Rolling back certificate files"
    run cp -a "${CERT_DST}.${STAMP}.bak" "$CERT_DST"
    run cp -a "${KEY_DST}.${STAMP}.bak" "$KEY_DST"

    if [[ "$NO_RESTART" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
      systemctl restart "$SERVICE_NAME"
    fi
  else
    error "Rollback requested but backup files were not found"
  fi
}

# Restart the SER connector service after certificate deployment.
# SER does not support reload, but writes queue data to disk before stopping,
# so restart is the supported way to pick up the updated certificate and key.
restart_service() {
  if [[ "$NO_RESTART" -eq 1 ]]; then
    log "Skipping service restart because --no-restart was specified"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would restart service: $SERVICE_NAME"
    log "Dry run completed successfully"
    return 0
  fi

  if systemctl restart "$SERVICE_NAME"; then
    log "Restarted $SERVICE_NAME successfully"
  else
    error "Restart failed after certificate deploy"
    rollback_certificates
    fail "service failed after deploy; rollback attempted"
  fi
}

# Main function, it's where all the magic happens like MTV Cribs.
main() {
  parse_args "$@"
  derive_lineage
  resolve_paths
  setup_logging
  log_config
  preflight_checks
  create_destination_dirs
  backup_existing_files
  install_certificates
  validate_certificate_pair
  restart_service
  log "Deploy completed successfully"
}

main "$@"
