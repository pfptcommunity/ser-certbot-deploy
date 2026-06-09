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
DOMAINS="${RENEWED_DOMAINS:-}"

# Source paths are resolved after we know which Certbot lineage to use.
CERT_SRC=""
KEY_SRC=""

# SER expects the active certificate and key at these fixed locations.
# The defaults can be overridden for lab testing or a different install path.
CERT_DST="/opt/ser/config/tls/certs/server.crt"
KEY_DST="/opt/ser/config/tls/private/server.key"

# Destination directories are derived from the destination file paths so the
# script does not need separate directory options.
CERT_DIR=""
KEY_DIR=""

# These defaults match the SER connector service account. The certificate is
# world-readable, but the private key is locked down later with mode 0600.
SERVICE_NAME="ser-connector"
CERT_OWNER="ser-connector"
CERT_GROUP="root"

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
NO_RELOAD=0
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

Certbot deploy-hook mode:
  $SCRIPT_NAME

Manual mode:
  $SCRIPT_NAME -n relay.company.com
  $SCRIPT_NAME --cert-name relay.company.com
  $SCRIPT_NAME --lineage /etc/letsencrypt/live/relay.company.com --domains relay.company.com

Options:
EOF

  # The ampersand is used as a simple field delimiter and column handles the
  # spacing. This keeps help text readable without manually counting spaces.
  cat <<EOF | column -s'&' -t
  -l, --lineage PATH&Certbot lineage path
                     &Example: /etc/letsencrypt/live/relay.company.com
  -n, --cert-name NAME&Certbot certificate name
                       &Example: relay.company.com
  -d, --domains DOMAINS&Domain names
                        &Example: relay.company.com
  -c, --cert-dst PATH&Destination certificate path
                     &Default: $CERT_DST
  -k, --key-dst PATH&Destination private key path
                    &Default: $KEY_DST
  -s, --service NAME&Service to reload or restart
                    &Default: $SERVICE_NAME
  -o, --owner USER&Owner for deployed files
                  &Default: $CERT_OWNER
  -g, --group GROUP&Group for deployed files
                   &Default: $CERT_GROUP
  -f, --log-file PATH&Optional log file path. If used, configure logrotate.
                     &Default: disabled
  -t, --dry-run&Show what would happen but do not modify files
  -r, --no-reload&Deploy files but do not reload or restart service
  -v, --verbose&Print more details
  -h, --help&Show this help
EOF
echo
}

# Logging function logs to the current output stream and also try syslog. 
# Syslog is best effort so a missing logger service never breaks certificate deployment.
log() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%:z')] $msg"
  logger -t deploy-ser-cert -- "$msg" 2>/dev/null || true
}

# Error logging function logs to the current output stream and also try syslog. 
# Syslog is best effort so a missing logger service never breaks certificate deployment.
error() {
  local msg="ERROR: $*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%:z')] $msg" >&2
  logger -t deploy-ser-cert -p user.err -- "$msg" 2>/dev/null || true
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
    echo "ERROR: $opt_name requires a value requires a value before: $2" >&2
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

      -d|--domains)
        require_value "$1" "${2:-}"
        DOMAINS="$2"
        shift 2
        ;;

      -c|--cert-dst)
        require_value "$1" "${2:-}"
        CERT_DST="$2"
        shift 2
        ;;

      -k|--key-dst)
        require_value "$1" "${2:-}"
        KEY_DST="$2"
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

      -r|--no-reload)
        NO_RELOAD=1
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
  log "Cert name: ${CERT_NAME:-unknown}"
  log "Lineage: ${LINEAGE:-unset}"
  log "Certificate source: ${CERT_SRC:-unset}"
  log "Private key source: ${KEY_SRC:-unset}"
  log "Certificate destination: $CERT_DST"
  log "Private key destination: $KEY_DST"
  log "Service: $SERVICE_NAME"
  log "Owner: $CERT_OWNER"
  log "Group: $CERT_GROUP"
  log "Dry run: $DRY_RUN"
  log "No reload: $NO_RELOAD"
  log "Log file: ${LOG_FILE:-disabled}"
}

# No lineage, no deploy. Guessing cert paths is how gremlins win.
resolve_paths() {
  [[ -n "$LINEAGE" ]] || fail "certificate lineage is not set. Use --lineage, --cert-name, --domains, or run this script from a Certbot deploy hook"

  CERT_SRC="${LINEAGE}/fullchain.pem"
  KEY_SRC="${LINEAGE}/privkey.pem"

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
  require_command install

  validate_user "$CERT_OWNER"
  validate_group "$CERT_GROUP"

  # Let dry-run and --no-reload work without systemctl.
  if [[ "$DRY_RUN" -eq 0 && "$NO_RELOAD" -eq 0 ]]; then
    require_command systemctl
  fi
}

# Used to create the target directories if the appliance or lab image does not have
# them yet. Existing directories are left alone.
create_destination_dirs() {
  run mkdir -p "$CERT_DIR"
  run mkdir -p "$KEY_DIR"
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
  run install -o "$CERT_OWNER" -g "$CERT_GROUP" -m 0644 "$CERT_SRC" "$CERT_DST"
  run install -o "$CERT_OWNER" -g "$CERT_GROUP" -m 0600 "$KEY_SRC" "$KEY_DST"
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

  # A mismatched keypair would cause TLS failures after reload, so stop before
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

    if [[ "$NO_RELOAD" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
      systemctl restart "$SERVICE_NAME"
    fi
  else
    error "Rollback requested but backup files were not found"
  fi
}

# Reload if possible; restart if the service needs a shove.
reload_or_restart_service() {
  if [[ "$NO_RELOAD" -eq 1 ]]; then
    log "Skipping service reload because --no-reload was specified"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would reload service: $SERVICE_NAME"
    log "Dry run completed successfully"
    return 0
  fi

  # Reload is gentler; restart if reload is not enough.
  if systemctl reload "$SERVICE_NAME"; then
    log "Reloaded $SERVICE_NAME successfully"
  else
    log "Reload failed, attempting restart"

    if systemctl restart "$SERVICE_NAME"; then
      log "Restarted $SERVICE_NAME successfully"
    else
      error "Restart failed after certificate deploy"
      rollback_certificates
      fail "service failed after deploy; rollback attempted"
    fi
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
  reload_or_restart_service
  log "Deploy completed successfully"
}

main "$@"
