#!/usr/bin/env bash
# Install a NervHawk site from one line and a one-use code (ADR 0033):
#
#   curl -fsSL <this file's address> | sudo bash -s -- <code>
#
# The code comes from `./nhp install-code` on the fleet server. The two public keys below are why
# this script does not have to trust that server: what it installs must be signed by one of them,
# and they did not come from the fleet. Everything runs inside main(), called on the last line, so
# a download that was cut off runs nothing. It never prints a code, a login or a key.
set -euo pipefail

GITHUB_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAgM8P7G4sfANqYQjOdKETdyiOEAejFVCMlOlD4uUo5eA=
-----END PUBLIC KEY-----'
BACKUP_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA2BHZC0V7YYP0ncAwm1zPJaJA2rpLugoAGGea4Oorq50=
-----END PUBLIC KEY-----'

root="${DESTDIR:-}"
work="$root/var/lib/nhp-install"
target="$root/opt/nervhawk-site"

die() { # <what went wrong> <the fix, one line>
  echo "install failed: $1" >&2
  [[ -z "${2:-}" ]] || echo "fix: $2" >&2
  exit 1
}

preflight() {
  [[ -n "$root" || $EUID -eq 0 ]] || die "not root" "run it with sudo"
  [[ "$GITHUB_KEY" == *"BEGIN PUBLIC KEY"* && "$BACKUP_KEY" == *"BEGIN PUBLIC KEY"* ]] ||
    die "this copy of the script has no release keys" "use the published script, not the template"
  local tool version
  for tool in curl python3 openssl docker sha256sum base64; do
    command -v "$tool" >/dev/null || die "no $tool on this machine" "install it, then run this line again"
  done
  docker info >/dev/null 2>&1 || die "Docker is not installed or not running" "install it: curl -fsSL https://get.docker.com | sudo sh"
  version="$(openssl version)"
  [[ "$version" =~ ^OpenSSL\ ([3-9]|[1-9][0-9])\. ]] ||
    die "$version: this needs OpenSSL 3.0 or newer" "use Ubuntu 22.04 or 24.04, or Debian 12 or newer"
}

already_installed() { # a site this script did not start, or finished: refused before the code is spent
  [[ ! -f "$target/.install-state/complete" ]] || return 0
  [[ ! -f "$work/answer.json" ]] || return 1
  [[ -e "$target/deploy/site/secrets/hub/hub.creds" ]] && return 0
  [[ -n "$(docker ps -q --filter label=com.docker.compose.project=nhp-site)" ]]
}

code_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; } # <secret>; printf is built in

fetch_answer() { # <address> <fingerprint> <secret>
  local address="$1" pin="$2" secret="$3" got status failed=0
  # Unverified on purpose, and only this: the hash below is what decides whether it is trusted.
  # Not ca.crt until the code is accepted: an earlier run's answer goes on to make the OS trust that.
  curl -fsSk --max-time 30 -o "$work/ca.new" "https://$address/v1/install/ca" </dev/null ||
    die "the fleet at $address does not answer" "open TCP ${address##*:} from this machine to ${address%:*}"
  got="$(sha256sum "$work/ca.new" | cut -d' ' -f1)"
  [[ "$got" == "$pin" ]] ||
    die "the server at $address is not the fleet this code was made for; the code was not sent" "check this machine's network, then ask for a new code"
  # printf is built in, so the secret is on no command line.
  status="$(printf '{"code":"%s"}' "$secret" | curl -sS --max-time 60 --cacert "$work/ca.new" \
    -H 'Content-Type: application/json' --data-binary @- -o "$work/answer.part" \
    -w '%{http_code}' "https://$address/v1/install/redeem")" || failed=$?
  case "$failed" in
    0) ;;
    # Before the request left: no name, no connection, a failed TLS handshake or certificate.
    6 | 7 | 35 | 60) die "could not reach the fleet at $address securely" "the code was not spent; run this line again" ;;
    *) die "the fleet at $address did not finish answering" "the code may have been spent: run this line again, and if it is refused, a new code works: ./nhp install-code <tenant>/<site>" ;;
  esac
  case "$status" in
    200)
      mv "$work/answer.part" "$work/answer.json"
      mv "$work/ca.new" "$work/ca.crt"
      code_hash "$secret" >"$work/code.sha256"
      ;;
    403) die "this code is unknown, used or expired" "make a new one: ./nhp install-code <tenant>/<site>" ;;
    *) die "the fleet answered $status" "try this line again in a minute; the code still works" ;;
  esac
}

read_answer() { # writes the secret parts to files; prints the checked public ones, one a line
  python3 -I -c 'import base64, json, re, sys
work = sys.argv[1]
answer = json.load(open(work + "/answer.json"))
release = answer["release"]
digest = re.compile(r"sha256:[0-9a-f]{64}")
checks = [
    (release["version"], re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")),
    (release["agent"], digest),
    (release["kit"], digest),
    (release["signature"], re.compile(r"[A-Za-z0-9+/]+={0,2}")),
    (answer["mirror"], re.compile(r"[A-Za-z0-9.-]+:[0-9]+")),
    (answer["nervhawk"], re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")),
    (answer["mirror_password"], re.compile(r"[^\s\x27]+")),
]
if not all(isinstance(v, str) and rule.fullmatch(v) for v, rule in checks):
    sys.exit(1)
raw = answer["bundle"]
bundle = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
names = re.compile(r"[a-z0-9][a-z0-9_-]{0,62}")
if not (names.fullmatch(bundle["tenant"]) and names.fullmatch(bundle["site"])):
    sys.exit(1)
signatures = answer["image_signatures"]
if not all(isinstance(k, str) and isinstance(v, str) for k, v in signatures.items()):
    sys.exit(1)
open(work + "/bundle.txt", "w").write(raw)
open(work + "/mirror-password", "w").write(answer["mirror_password"] + "\n")
json.dump(signatures, open(work + "/signatures.json", "w"))
for value in (release["version"], release["agent"], release["kit"], release["signature"],
              answer["mirror"], answer["nervhawk"], bundle["tenant"], bundle["site"]):
    print(value)' "$work" 2>/dev/null
}

signed_by_our_keys() { # <version> <agent digest> <kit digest> <signature>
  local key
  printf 'nhp-site-release-v1\n%s\n%s\n%s\n' "$1" "$2" "$3" >"$work/statement"
  printf '%s' "$4" | base64 -d >"$work/signature" 2>/dev/null || return 1
  for key in github backup; do
    if openssl pkeyutl -verify -pubin -inkey "$work/release-keys/$key.pem" -rawin \
      -in "$work/statement" -sigfile "$work/signature" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

trust_fleet_ca() { # <mirror>: as install-edge.sh's trust_os_ca, which comes too late for the first pull
  local anchor rebuild i
  install -d -m 0755 "$root/etc/docker/certs.d/$1"
  install -m 0644 "$work/ca.crt" "$root/etc/docker/certs.d/$1/ca.crt"
  if command -v update-ca-certificates >/dev/null; then
    anchor="$root/usr/local/share/ca-certificates/nervhawk-fleet-ca.crt" rebuild=(update-ca-certificates)
  elif command -v update-ca-trust >/dev/null; then
    anchor="$root/etc/pki/ca-trust/source/anchors/nervhawk-fleet-ca.crt" rebuild=(update-ca-trust extract)
  else
    die "the OS cannot be told to trust the fleet CA" "install the ca-certificates package, then run this line again"
  fi
  if [[ -f "$anchor" && "$(<"$work/ca.crt")" == "$(<"$anchor")" ]]; then return 0; fi
  install -D -m 0644 "$work/ca.crt" "$anchor"
  "${rebuild[@]}" >/dev/null
  if [[ -n "$(docker ps -q)" ]]; then
    die "the OS trusts the fleet CA, but Docker reads it only at its start, and containers run here" "sudo systemctl restart docker when they may stop, then run this line again"
  fi
  systemctl restart docker
  for ((i = 0; i < 30; i++)); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Docker did not come back after its restart" "sudo systemctl status docker shows why; fix it, then run this line again"
}

fetch_installer() { # <mirror> <login> <kit image>: the kit's own installer, from the signed kit
  local id
  docker login "$1" -u "$2" --password-stdin <"$work/mirror-password" >/dev/null ||
    die "the mirror $1 refused this site's login" "on the fleet server: make nats-accounts, then a new code"
  docker pull "$3" </dev/null >/dev/null || die "cannot pull the site kit" "open TCP ${1##*:} from this machine to ${1%:*}, then run this line again"
  id="$(docker create "$3" none </dev/null)" || die "cannot read the site kit" "free disk space, then run this line again"
  if ! docker cp "$id:/kit/deploy/site/install-edge.sh" "$work/install-edge.sh" </dev/null >/dev/null; then
    docker rm "$id" </dev/null >/dev/null 2>&1 || true
    die "the site kit has no installer" "the release on the fleet server is not a site kit"
  fi
  docker rm "$id" </dev/null >/dev/null
}

main() {
  local code="" license_lock="" parsed fields
  while (($#)); do
    case "$1" in
      --license-lock) license_lock=1 ;;
      -*) die "unknown option $1" "the line is: ... | sudo bash -s -- <code>" ;;
      *) [[ -z "$code" ]] || die "more than one code" "give one code"; code="$1" ;;
    esac
    shift
  done
  [[ "$code" =~ ^NH1::([A-Za-z0-9.-]+:[0-9]+)::([0-9a-f]{64})::([A-Za-z0-9_-]{16,128})$ ]] ||
    die "that is not an install code" "copy it again: it starts with NH1::"
  local address="${BASH_REMATCH[1]}" pin="${BASH_REMATCH[2]}" secret="${BASH_REMATCH[3]}"

  preflight
  if already_installed; then
    die "a site is already installed or running on this machine; the code was not spent" "to update it: sudo /opt/nervhawk-site/deploy/site/install-edge.sh --update"
  fi
  umask 077
  install -d -m 0700 "$work"
  # Only the code that earned the stored answer continues it: that answer's enrollment code may be
  # spent or past its 24 h, and then a new code is the way out.
  if [[ -f "$work/answer.json" && "$(cat "$work/code.sha256" 2>/dev/null)" == "$(code_hash "$secret")" ]]; then
    echo "continuing an earlier run: the code is not needed twice"
  else
    fetch_answer "$address" "$pin" "$secret"
    echo "the fleet accepted the code"
  fi

  parsed="$(read_answer)" || die "the fleet's answer is malformed; nothing was installed" "do not retry until the fleet server has been checked"
  mapfile -t fields <<<"$parsed"
  local version="${fields[0]}" agent="${fields[1]}" kit="${fields[2]}" signature="${fields[3]}"
  local mirror="${fields[4]}" nervhawk="${fields[5]}" tenant="${fields[6]}" site="${fields[7]}"

  install -d -m 0755 "$work/release-keys"
  printf '%s\n' "$GITHUB_KEY" >"$work/release-keys/github.pem"
  printf '%s\n' "$BACKUP_KEY" >"$work/release-keys/backup.pem"
  chmod 0644 "$work/release-keys/github.pem" "$work/release-keys/backup.pem"

  signed_by_our_keys "$version" "$agent" "$kit" "$signature" ||
    die "release $version is not signed by the NervHawk release key; nothing was installed" "do not retry: the fleet server may have been tampered with"
  echo "release $version: signature checked"

  local login="registry_${tenant}_${site}" images="$mirror/hamza-shamaseen/nervhawk-fleet"
  login="${login//-/_}"
  local kit_ref="$images/site-kit:$version@$kit" agent_ref="$images/agent:$version@$agent"
  trust_fleet_ca "$mirror"
  fetch_installer "$mirror" "$login" "$kit_ref"

  # The kit's files should keep their normal modes; only this script's own work is private.
  if ! (umask 022 && bash "$work/install-edge.sh" "$work/bundle.txt" --nervhawk "$nervhawk" \
    --mirror "$mirror" --tag "$version" --mirror-password-file "$work/mirror-password" \
    --signed-updates --kit-image "$kit_ref" --agent-image "$agent_ref" \
    --image-signatures "$work/signatures.json" ${license_lock:+--license-lock} </dev/null); then
    die "the install stopped (the lines above say why)" "fix that, then run this same line again: the code is not needed twice"
  fi
  rm -rf "$work"
  echo "installed: site $tenant/$site"
}

main "$@"
