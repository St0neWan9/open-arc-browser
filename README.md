# Open Arc update feeds

Static files the app downloads, served as raw content from this branch:

- `adblock/manifest.json` + `manifest.json.sig`: the ad-block ruleset manifest, signed with Ed25519 (plan C19, `scripts/publish-adblock-ruleset.sh` on `main`). The app checks the signature against its built-in key before using a ruleset.
- `adblock/rulesets/<version>/`: compiled EasyList + EasyPrivacy rulesets with their `ATTRIBUTION`.
- `appcast.xml`: the Sparkle update feed (plan D7), once releases are published.

Nothing here is edited by hand; publish with the scripts on `main`.
