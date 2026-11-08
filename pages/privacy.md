# Open Arc privacy policy

The current privacy policy is at **https://getopenarc.app/privacy**. This page is kept for older
versions of the app that link here.

Open Arc has no accounts and no servers of its own.

**What stays on your Mac.** Your sidebar (Spaces, tabs, folders, favorites), history, passwords,
cookies, downloads and settings are stored only on your Mac.

**iCloud sync (optional, off by default).** If you turn on Settings ▸ Account ▸ Sync Sidebar,
your sidebar is synced through your own private iCloud database (Apple CloudKit). The developer
cannot read it.

**Usage data (version 0.2.5, build 22 and later).** The app shares a few basic usage events with PostHog
(US): that it was used on a day, which of five features were used, whether an Arc import succeeded
and the archive interval chosen, with the app version, macOS version, processor type and a random
installation identifier. It never sends websites, page contents, searches, passwords or anything
from incognito windows. Sharing is on by default, starts only after the app has told you, and can
be turned off anytime in Settings ▸ General ▸ Share usage data. Earlier builds send no usage data.
The address of each request lets PostHog estimate a country and city; the address itself is
discarded and not stored.

**Connections the app makes on its own.** Update checks and ad-block filter lists from this
project's GitHub repository; certificate revocation lists from Google, as in every Chromium
browser; updates for extensions you installed from the Chrome Web Store; and, from 0.2.5 (build 22), the
usage data above.

**Off.** Google sign-in and Chromium sync, Safe Browsing, usage metrics upload of the engine, crash
report upload and field trials are turned off. Crash reports stay on your Mac.

Questions: [open an issue](https://github.com/St0neWan9/open-arc-browser/issues).
