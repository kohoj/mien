# Third-party notices

Mien is MIT licensed. Its assembled development and release bundles include the following pinned, separately maintained runtimes:

| Component | Pinned revision | License | Source |
|---|---|---|---|
| Pi Agent Harness | `0.82.1`, `cced6a21da273b26ee4a23a803680614bbe8dd1e` | MIT | <https://github.com/earendil-works/pi> |
| Longview | `bff4662cf7b06469101f7a2f3900e904bfce5aa9` | MIT, Copyright 2026 Longview contributors | <https://github.com/kohoj/longview> |
| Streamdown | `2.5.0` | Apache-2.0 | <https://github.com/vercel/streamdown> |
| Streamdown CJK | `1.0.3` | Apache-2.0 | <https://github.com/vercel/streamdown> |
| React | `19.2.8` | MIT | <https://github.com/facebook/react> |
| React DOM | `19.2.8` | MIT | <https://github.com/facebook/react> |

The exact native-runtime manifest is embedded at `Contents/Resources/runtime-manifest.json`. The locally bundled result renderer is pinned by `Web/ResultRenderer/package-lock.json`; its complete transitive component manifest is embedded at `Contents/Resources/result-renderer-components.json`. Upstream license and NOTICE texts for every bundled runtime and renderer component are embedded at `Contents/Resources/ThirdPartyLicenses/`. The build fails if those files or the renderer's locked, generated artifacts are absent or stale.
