#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage:
  manage.sh check [--project-root PATH] [--domain-suffix SUFFIX]
  manage.sh install [--project-root PATH] [--domain-suffix SUFFIX] [--resume]
  manage.sh bootstrap [--project-root PATH] [--timeout SECONDS|--close]
  manage.sh verify [--project-root PATH]
  manage.sh --help
Project root: --project-root overrides NOOK_PROJECT_ROOT (default /opt/vps-nook).
Domain suffix: internal. Bootstrap timeout: 600 seconds (60..3600).
USAGE
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
usage_error() { printf '[FAIL] %s\n' "$*" >&2; usage >&2; exit 2; }
ok() { printf '[OK] %s\n' "$*"; }
action() { printf '[ACTION] %s\n' "$*"; }

[[ $# -gt 0 ]] || usage_error 'A command is required'
if [[ $1 == --help && $# == 1 ]]; then usage; exit 0; fi
COMMAND=$1
shift
case "$COMMAND" in check|install|bootstrap|verify) ;; *) usage_error 'Unknown command' ;; esac
PROJECT_ROOT=${NOOK_PROJECT_ROOT:-/opt/vps-nook}
SUFFIX=internal
TIMEOUT=600
RESUME=false
CLOSE=false
declare -A SEEN=()
while (( $# )); do
    option=$1
    shift
    [[ -n $option ]] || usage_error 'Empty option'
    [[ ! ${SEEN[$option]+present} ]] || usage_error 'Duplicate option'
    SEEN[$option]=1
    case "$option" in
        --help) [[ $# == 0 && ${#SEEN[@]} == 1 ]] || usage_error 'Incompatible help options'; usage; exit 0 ;;
        --project-root|--domain-suffix|--timeout)
            [[ $# -gt 0 && -n $1 && $1 != --* ]] || usage_error 'Missing option value'
            case "$option" in
                --project-root) PROJECT_ROOT=$1 ;;
                --domain-suffix)
                    [[ $COMMAND == check || $COMMAND == install ]] || usage_error 'Incompatible domain suffix'
                    SUFFIX=$1 ;;
                --timeout)
                    [[ $COMMAND == bootstrap ]] || usage_error 'Incompatible timeout'
                    [[ $1 =~ ^[0-9]{1,4}$ ]] || usage_error 'Timeout must be 60..3600 seconds'
                    TIMEOUT=$((10#$1))
                    (( TIMEOUT >= 60 && TIMEOUT <= 3600 )) || usage_error 'Timeout must be 60..3600 seconds' ;;
            esac
            shift ;;
        --resume) [[ $COMMAND == install ]] || usage_error 'Incompatible resume'; RESUME=true ;;
        --close) [[ $COMMAND == bootstrap ]] || usage_error 'Incompatible close'; CLOSE=true ;;
        *) usage_error 'Unknown option' ;;
    esac
done
[[ $CLOSE == false || ! ${SEEN[--timeout]+present} ]] || usage_error 'Timeout and close are mutually exclusive'
[[ $(id -u) == 0 ]] || fail 'Run this command in a VPS root shell'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
for dependency in docker python3; do
    command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is required"
done

# Standard-library helpers never print Compose environments or inspection payloads.
model() {
    python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def path_type(path, directory=False, optional=False):
    path = Path(path)
    for parent in reversed(path.parents):
        require(stat.S_ISDIR(parent.lstat().st_mode), 'Path ancestor is not a real directory')
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        require(optional, 'Required path is missing')
        return
    require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode),
            'Path is not a real directory' if directory else 'Path is not a regular non-symlink file')


def targets(root):
    for relative in ('volumes', 'volumes/vaultwarden', 'Caddyfile.d'):
        path = root / relative
        if path.parent.exists():
            path_type(path, directory=True, optional=True)
    if (root / 'Caddyfile.d').exists():
        path_type(root / 'Caddyfile.d/vaultwarden.conf', optional=True)


def suffix(value):
    require(len('vw.' + value) <= 253 and
            re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*', value)
            and value != 'local' and not value.endswith('.local'), 'Invalid domain suffix')
    return value


def service(file):
    return json.loads(Path(file).read_text()).get('services', {}).get('vaultwarden')


try:
    op, *args = sys.argv[1:]
    if op == 'paths':
        value, sources = args
        root = Path(value)
        require(root.is_absolute() and value != '/' and not value.startswith('//') and
                '..' not in root.parts and value == str(root) and
                all(ord(c) >= 32 and ord(c) != 127 for c in value), 'Invalid project root')
        path_type(root, directory=True)
        path_type(root / 'docker-compose.yml')
        path_type(root / 'docker-compose.override.yml', optional=True)
        for name in ('compose.override.yml', 'Caddyfile.conf'):
            path_type(Path(sources) / name)
        targets(root)
    elif op == 'render':
        source, dest, value = args
        suffix(value)
        for name in ('compose.override.yml', 'Caddyfile.conf'):
            path_type(Path(source) / name)
            data = (Path(source) / name).read_bytes()
            require(b'vw.internal' in data, 'Source fragment has no canonical hostname')
            data = data.replace(b'vw.internal', ('vw.' + value).encode())
            require(value == 'internal' or not re.search(rb'vw\.internal(?![a-z0-9.-])', data),
                    'Stale hostname in generated fragment')
            (Path(dest) / name).write_bytes(data)
    elif op == 'present':
        sys.exit(0 if service(args[0]) is not None else 1)
    elif op == 'equal':
        actual, expected = map(service, args)
        require(actual is not None and actual == expected, 'Installed Vaultwarden differs from the generated recipe')
    elif op == 'domain':
        actual = service(args[0])
        require(isinstance(actual, dict), 'Vaultwarden is not installed')
        domain = actual.get('environment', {}).get('DOMAIN', '')
        require(domain.startswith('https://vw.'), 'Invalid Vaultwarden DOMAIN')
        print(suffix(domain[len('https://vw.'):]))
    elif op == 'caddy':
        installed, expected = map(Path, args)
        path_type(installed)
        require(installed.read_bytes() == expected.read_bytes(), 'Installed Caddy fragment differs from the generated recipe')
    elif op == 'directories':
        root = Path(args[0])
        targets(root)
        for relative in ('volumes', 'volumes/vaultwarden', 'Caddyfile.d'):
            path = root / relative
            path_type(path, directory=True, optional=True)
            try:
                path.mkdir(mode=0o755)
            except FileExistsError:
                pass
            path_type(path, directory=True)
    elif op == 'publish':
        def interrupted(signum, frame):
            raise SystemExit(1)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, interrupted)
        source, destination = map(Path, args)
        path_type(source)
        path_type(destination.parent, directory=True)
        fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        temp = '.vaultwarden-' + secrets.token_hex(16)
        try:
            out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(out, 'wb') as stream:
                stream.write(source.read_bytes())
                stream.flush()
                os.fchmod(stream.fileno(), 0o644)
            path_type(destination.parent, directory=True)
            require(os.path.samestat(os.fstat(fd), destination.parent.stat()), 'Publication directory changed')
            require(not os.path.lexists(destination), 'Publication target already exists')
            os.link(temp, destination.name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        finally:
            try:
                os.unlink(temp, dir_fd=fd)
            except FileNotFoundError:
                pass
            finally:
                os.close(fd)
    elif op == 'runtime':
        runtime = json.loads(Path(args[0]).read_text())
        require(len(runtime) == 1, 'Expected one Vaultwarden container')
        container = runtime[0]
        state = container.get('State', {})
        require(state.get('Running') and state.get('Health', {}).get('Status') == 'healthy', 'Vaultwarden is not healthy')
        if len(args) > 1:
            config = container.get('Config', {})
            require(config.get('Image') == service(args[1])['image'], 'Running image differs from the recipe pin')
            values = [item.split('=', 1)[1] for item in config.get('Env', []) if item.startswith('SIGNUPS_ALLOWED=')]
            require(values == ['false'], 'Running SIGNUPS_ALLOWED must be exactly false')
            require(not container.get('HostConfig', {}).get('PortBindings') and
                    not any(container.get('NetworkSettings', {}).get('Ports', {}).values()), 'Runtime publishes ports')
    else:
        raise ValueError('Unknown model operation')
except (OSError, ValueError, KeyError, TypeError) as error:
    # Errors deliberately omit file/JSON values: operator overrides may contain secrets.
    print('[FAIL] ' + (str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError)
                       else 'Cannot validate recipe paths or model'), file=sys.stderr)
    sys.exit(1)
PY
}

TEMP_DIR=''
WINDOW_OPEN=false
RECOVER_INSTALL=false
cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ $WINDOW_OPEN == true ]]; then
        if ! close_registration; then
            printf '[FAIL] Registration closure failed; run: %q bootstrap --project-root %q --close\n' "$SCRIPT_DIR/manage.sh" "$PROJECT_ROOT" >&2
            status=1
        fi
    fi
    [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"
    if (( status != 0 && status != 3 )); then
        printf '[FAIL] Requested operation did not complete\n' >&2
        if [[ $RECOVER_INSTALL == true ]]; then
            printf '[ACTION] Preserve files/data for diagnosis; recover with: %q install --project-root %q --domain-suffix %q --resume\n' \
                "$SCRIPT_DIR/manage.sh" "$PROJECT_ROOT" "$SUFFIX" >&2
        fi
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
model paths "$PROJECT_ROOT" "$SCRIPT_DIR"
docker compose version >/dev/null 2>&1 || fail 'Docker Compose is required'
TEMP_DIR=$(mktemp -d)
chmod 700 "$TEMP_DIR"
COMPOSE=(docker compose --project-directory "$PROJECT_ROOT" -f "$PROJECT_ROOT/docker-compose.yml")
OVERRIDE=$PROJECT_ROOT/docker-compose.override.yml
CADDY=$PROJECT_ROOT/Caddyfile.d/vaultwarden.conf
[[ ! -e $OVERRIDE ]] || COMPOSE+=(-f "$OVERRIDE")
compose_config() {
    "${COMPOSE[@]}" config --format json >"$TEMP_DIR/installed.json" 2>"$TEMP_DIR/docker.err" \
        || fail 'Installed Compose configuration does not render'
}
compose_config
prepare_expected() {
    model render "$SCRIPT_DIR" "$TEMP_DIR" "$SUFFIX"
    printf '%s\n' '---' 'services: {}' 'networks:' '  vpn_net: {}' >"$TEMP_DIR/base.yml"
    docker compose --project-directory "$PROJECT_ROOT" -f "$TEMP_DIR/base.yml" -f "$TEMP_DIR/compose.override.yml" \
        config --format json >"$TEMP_DIR/expected.json" 2>"$TEMP_DIR/docker.err" \
        || fail 'Generated Compose configuration does not render'
}
inspect_runtime() {
    local container
    container=$("${COMPOSE[@]}" ps -q vaultwarden 2>"$TEMP_DIR/docker.err") || return 1
    [[ -n $container && $container != *$'\n'* ]] || return 1
    docker inspect "$container" >"$TEMP_DIR/runtime.json" 2>"$TEMP_DIR/docker.err"
}
wait_healthy() {
    local attempt
    for ((attempt=0; attempt<30; attempt++)); do
        if inspect_runtime && model runtime "$TEMP_DIR/runtime.json" 2>/dev/null; then return 0; fi
        sleep 5
    done
    printf '[FAIL] Vaultwarden did not become healthy within 150 seconds\n' >&2
    return 1
}
start_service() {
    "${COMPOSE[@]}" "$@" up -d vaultwarden >"$TEMP_DIR/docker.out" 2>"$TEMP_DIR/docker.err"
}

if [[ $COMMAND == check || $COMMAND == install ]]; then
    prepare_expected
    if [[ $RESUME == true ]]; then
        model equal "$TEMP_DIR/installed.json" "$TEMP_DIR/expected.json"
        [[ ! -e $CADDY ]] || model caddy "$CADDY" "$TEMP_DIR/Caddyfile.conf"
    else
        if model present "$TEMP_DIR/installed.json"; then fail 'Vaultwarden already exists; reconcile before install --resume'; fi
        [[ ! -e $CADDY ]] || fail 'Vaultwarden Caddy fragment already exists'
        if [[ -e $OVERRIDE ]]; then
            printf '%s\n' '----- BEGIN VAULTWARDEN COMPOSE FRAGMENT -----'
            cat -- "$TEMP_DIR/compose.override.yml"
            printf '%s\n' '----- END VAULTWARDEN COMPOSE FRAGMENT -----'
            action 'Manually add only the Vaultwarden mapping under the existing single services: key; preserve all other mappings and top-level settings.'
            printf '[ACTION] Then run: %q install --project-root %q --domain-suffix %q --resume\n' \
                "$SCRIPT_DIR/manage.sh" "$PROJECT_ROOT" "$SUFFIX"
            exit 3
        fi
    fi
    ok 'Source fragments, project paths, generated hostname pair and Compose models passed preflight'
    if [[ $COMMAND == check ]]; then ok 'Ready for a clean install; no deployed files or containers changed'; exit 0; fi
    # Repeat path checks at the mutation boundary; publication never replaces a target.
    model paths "$PROJECT_ROOT" "$SCRIPT_DIR"
    model directories "$PROJECT_ROOT"
    RECOVER_INSTALL=true
    if [[ $RESUME == false ]]; then
        model publish "$TEMP_DIR/compose.override.yml" "$OVERRIDE"
        COMPOSE+=(-f "$OVERRIDE")
    fi
    if [[ -e $CADDY ]]; then
        model caddy "$CADDY" "$TEMP_DIR/Caddyfile.conf"
    else
        model publish "$TEMP_DIR/Caddyfile.conf" "$CADDY"
    fi
    compose_config
    model equal "$TEMP_DIR/installed.json" "$TEMP_DIR/expected.json"
    "${COMPOSE[@]}" config -q >"$TEMP_DIR/docker.out" 2>"$TEMP_DIR/docker.err" || fail 'Compose validation failed'
    start_service || fail 'Vaultwarden startup failed'
    wait_healthy || fail 'Vaultwarden health check failed'
    ok 'Vaultwarden installed and healthy; files and persistent data preserved'
    action 'Activate Caddy by rerunning the same verified version-pinned installer bytes or the tagged controller playbook; never reload Caddy directly.'
    exit 0
fi

SUFFIX=$(model domain "$TEMP_DIR/installed.json")
prepare_expected

close_registration() {
    rm -f -- "$TEMP_DIR/registration.yml" || return 1
    "${COMPOSE[@]}" config --format json >"$TEMP_DIR/installed.json" 2>"$TEMP_DIR/docker.err" || return 1
    model equal "$TEMP_DIR/installed.json" "$TEMP_DIR/expected.json" || return 1
    start_service || return 1
    wait_healthy || return 1
    model runtime "$TEMP_DIR/runtime.json" "$TEMP_DIR/expected.json" || return 1
    ok 'Registration closed: configured and running SIGNUPS_ALLOWED=false; Vaultwarden healthy'
}

if [[ $COMMAND == bootstrap ]]; then
    model equal "$TEMP_DIR/installed.json" "$TEMP_DIR/expected.json"
    if [[ $CLOSE == true ]]; then
        WINDOW_OPEN=true
        exit 0 # EXIT performs the same closure and reports any failure.
    fi
    exec {TTY_FD}<>/dev/tty || fail 'Bootstrap requires /dev/tty'
    if ! inspect_runtime || ! model runtime "$TEMP_DIR/runtime.json"; then
        fail 'Bootstrap requires a healthy Vaultwarden container'
    fi
    if ! close_registration; then
        printf '[FAIL] Cannot reconcile closed registration; run: %q bootstrap --project-root %q --close\n' \
            "$SCRIPT_DIR/manage.sh" "$PROJECT_ROOT" >&2
        exit 1
    fi
    printf '%s\n' '---' 'services:' '  vaultwarden:' '    environment:' '      SIGNUPS_ALLOWED: "true"' \
        >"$TEMP_DIR/registration.yml"
    chmod 600 "$TEMP_DIR/registration.yml"
    "${COMPOSE[@]}" -f "$TEMP_DIR/registration.yml" config -q >"$TEMP_DIR/docker.out" 2>"$TEMP_DIR/docker.err" \
        || fail 'Temporary registration model is invalid'
    WINDOW_OPEN=true # A failed recreation may already have changed the running container.
    start_service -f "$TEMP_DIR/registration.yml" || fail 'Cannot open registration'
    wait_healthy || fail 'Registration container did not become healthy'
    action "Create the first account at https://vw.$SUFFIX over VPN with trusted HTTPS; every VPN peer can register during this window."
    action "Press Enter here when finished; registration closes after $TIMEOUT seconds or interruption."
    if ! IFS= read -r -t "$TIMEOUT" -u "$TTY_FD" REPLY; then
        fail 'Registration timed out or terminal input ended; closing registration'
    fi
    exit 0
fi

if [[ $COMMAND == verify ]]; then
    model equal "$TEMP_DIR/installed.json" "$TEMP_DIR/expected.json"
    ok 'Effective image equals the shipped tag+digest; only vpn_net and the project-relative volumes/vaultwarden:/data bind'
    ok 'Configured SIGNUPS_ALLOWED=false; no configured published ports'
    model caddy "$CADDY" "$TEMP_DIR/Caddyfile.conf"
    ok "Exact generated Caddy fragment matches Compose DOMAIN https://vw.$SUFFIX"
    inspect_runtime || fail 'Cannot inspect the running Vaultwarden container'
    model runtime "$TEMP_DIR/runtime.json" "$TEMP_DIR/expected.json"
    ok 'Running image matches the pin; SIGNUPS_ALLOWED=false; no runtime published ports; upstream health is healthy'
    action "VPN client: open https://vw.$SUFFIX with trusted HTTPS, without certificate bypass."
    action 'VPN client: confirm a saved vault item persists across logout/login.'
    action 'VPN client: confirm an independent signup in a private browser session is denied.'
fi
