# Performance self-test helpers

`pageserver.py [port]` serves a realistic page (title, favicon, stylesheet, script, images,
about 60 KB of text) for every path on 127.0.0.1. Point a self-test fixture's tabs at
`http://site<N>.localhost:<port>/page/<N>`: Chromium resolves `*.localhost` to loopback, so every
tab is its own site with its own renderer, and no test depends on the network (B107: on a Mac whose
DNS is answered by a TUN proxy, made-up hosts fail TLS and every tab builds an error page).

Use it with the dev-only sidebar self-test (`OPENARC_SIDEBAR_SCROLL_SELFTEST`, see
`app/Sources/OpenArcShell/Sidebar/SidebarScrollSelfTest.swift`) and `OPENARC_ENGINE=chromium`.
