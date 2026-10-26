# Sourced by scripts/make-app.sh and scripts/notarize.sh (plan D6): makes a dedicated signing
# keychain usable by codesign for the rest of the calling script.
#
# codesign --keychain picks the identity from that keychain but looks its private key up through
# the user keychain search list. When another keychain earlier in the list (for example the login
# keychain) holds a copy of the same key whose partition list lacks "apple:", securityd asks the
# user to allow codesign; with no UI (SSH, CI) that fails as errSecInternalComponent. Putting the
# signing keychain first avoids it. The previous order is put back when the script exits.
#
# use_signing_keychain <keychain> [<password file>]: unlocks the keychain when a password file is
# given (the password is never printed) and moves the keychain to the front of the user search
# list. The caller must run restore_signing_keychain_order on exit (from its EXIT trap; a second
# trap here would replace the caller's). Call it once per script.

signing_keychain_saved_list=()
signing_keychain_path=""

use_signing_keychain() {
    signing_keychain_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    [[ -f "$signing_keychain_path" ]] || { echo "keychain not found: $1" >&2; return 1; }
    if [[ -n "${2:-}" ]]; then
        security unlock-keychain -p "$(<"$2")" "$signing_keychain_path"
    fi
    local entry front=("$signing_keychain_path")
    while IFS= read -r entry; do
        entry="${entry#"${entry%%[![:space:]]*}"}"; entry="${entry#\"}"; entry="${entry%\"}"
        [[ -n "$entry" ]] || continue
        signing_keychain_saved_list+=("$entry")
        [[ "$entry" == "$signing_keychain_path" ]] || front+=("$entry")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${front[@]}"
}

# Puts the signing keychain back where it was (or removes it when it was not in the list),
# keeping any change other tools made to the rest of the list in the meantime.
restore_signing_keychain_order() {
    [[ -n "$signing_keychain_path" ]] || return 0
    local entry current=() was_listed=0
    for entry in "${signing_keychain_saved_list[@]}"; do
        [[ "$entry" == "$signing_keychain_path" ]] && was_listed=1
    done
    while IFS= read -r entry; do
        entry="${entry#"${entry%%[![:space:]]*}"}"; entry="${entry#\"}"; entry="${entry%\"}"
        [[ -n "$entry" && "$entry" != "$signing_keychain_path" ]] && current+=("$entry")
    done < <(security list-keychains -d user)
    if [[ $was_listed -eq 1 ]]; then
        # Its old index among the entries that are still there.
        local index=0 result=() placed=0
        for entry in "${signing_keychain_saved_list[@]}"; do
            [[ "$entry" == "$signing_keychain_path" ]] && break
            index=$((index + 1))
        done
        local i=0
        for entry in "${current[@]}"; do
            if [[ $placed -eq 0 && $i -eq $index ]]; then result+=("$signing_keychain_path"); placed=1; fi
            result+=("$entry")
            i=$((i + 1))
        done
        [[ $placed -eq 1 ]] || result+=("$signing_keychain_path")
        current=("${result[@]}")
    fi
    security list-keychains -d user -s "${current[@]}"
    signing_keychain_path=""
}
