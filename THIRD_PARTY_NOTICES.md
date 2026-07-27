# Third-party notices

Mien is MIT licensed. Its assembled development and release bundles include the following unmodified, separately maintained executables:

| Component | Pinned revision | License | Source |
|---|---|---|---|
| OpenAI Codex | `0.145.0`, `25af12f7e61572b0bc18ddb1008be543b91519b0` | Apache-2.0 | <https://github.com/openai/codex> |
| Codex ACP | `1.1.7`, `ba5bef59cfcea4229841fe9438d816696621307b` | Apache-2.0, Copyright 2025 JetBrains s.r.o. | <https://github.com/agentclientprotocol/codex-acp> |
| Longview | `1400db26424323e5e413bdf2f1b03a07961f2458` | MIT, Copyright 2026 Longview contributors | <https://github.com/kohoj/longview> |

OpenAI Codex includes code derived from Ratatui under the MIT License, Copyright 2016–2022 Florian Dehau and Copyright 2023–2025 The Ratatui Developers.

The exact manifest used for a build is embedded at `Contents/Resources/runtime-manifest.json`. Complete upstream license and NOTICE texts are embedded at `Contents/Resources/ThirdPartyLicenses/`. The build fails if those files are absent.
