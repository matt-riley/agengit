# Changelog

## [1.26.1](https://github.com/matt-riley/agengit/compare/v1.26.0...v1.26.1) (2026-07-02)


### Bug Fixes

* **ci:** pin validation-macos runner to macos-15 ([#100](https://github.com/matt-riley/agengit/issues/100)) ([6ae029e](https://github.com/matt-riley/agengit/commit/6ae029ef0fd11485e363f13246e0f08831d545ca))

## [1.26.0](https://github.com/matt-riley/agengit/compare/v1.25.1...v1.26.0) (2026-07-01)


### Features

* add blob-body content search to grep ([#86](https://github.com/matt-riley/agengit/issues/86)) ([1a3d5e7](https://github.com/matt-riley/agengit/commit/1a3d5e719dec51f2fa38618399785adff445c1f0))
* add Copilot CLI hook integration ([0264b42](https://github.com/matt-riley/agengit/commit/0264b4206d9c69cb35eaf5450b96b31d9dea2144))
* add evidence-based eval command ([80a63ef](https://github.com/matt-riley/agengit/commit/80a63eff29069ad1a8984f2080f1b416416edc07))
* add experimental jsonl observer source ([#79](https://github.com/matt-riley/agengit/issues/79)) ([44e935f](https://github.com/matt-riley/agengit/commit/44e935f1a0b9a7c220afa8bd714428c31d6c4f6f))
* add experimental observer support ([bd7cd6a](https://github.com/matt-riley/agengit/commit/bd7cd6afd941a765bace8d38dbcec8615bebe699))
* add fsck integrity verification ([58cf96d](https://github.com/matt-riley/agengit/commit/58cf96d05b4f2e1481b491204bd3c8ffcfe886d5))
* add gc store maintenance command ([4a3380a](https://github.com/matt-riley/agengit/commit/4a3380ad3b9d24b7477564dfa778621718c4c9c6))
* add historical grep command ([3684978](https://github.com/matt-riley/agengit/commit/3684978ffc3ec60ecedfcb925ff0323cca3f29bb))
* add investigation workflow views ([816d232](https://github.com/matt-riley/agengit/commit/816d2329904488505f698300bff86eee5ccef8cc))
* add Pi hook integration ([6ca3f4a](https://github.com/matt-riley/agengit/commit/6ca3f4a76850f4d1e9be2b9e7ddadc2df4d7fbe7))
* add portable bundle export and import ([fa685ee](https://github.com/matt-riley/agengit/commit/fa685ee98eeec955c6f845ba8c54746c65b800aa))
* add recall memory retrieval and replay non-goal ADR ([c5ff7ad](https://github.com/matt-riley/agengit/commit/c5ff7ad21edfe44278a9134c088de3b29059b31d))
* add remote push and pull sync ([02979ef](https://github.com/matt-riley/agengit/commit/02979ef3fdfb6a2cb7190d0854d4eec2d827574c))
* add watch and analytics commands ([618758f](https://github.com/matt-riley/agengit/commit/618758f01042f13e94b8de8044f9857228ece247))
* agit steps command, eval --include-steps, eval --list, and expanded log fields ([#97](https://github.com/matt-riley/agengit/issues/97)) ([4e64902](https://github.com/matt-riley/agengit/commit/4e649021af7d4f33770d6baa4941cbd536819a32))
* **cli:** add consistent --help and repo-discovery hints (ADR 012) ([94460f2](https://github.com/matt-riley/agengit/commit/94460f2eefd5fb5aea81b911dd344844bff46c5a))
* **cli:** add structured JSON output and generated completions ([a8bc423](https://github.com/matt-riley/agengit/commit/a8bc42346c1beac16fbac3b26f888fcfe1a5ff26))
* **cli:** implement ADR 029 guided setup and hook-install preview ([c25fcee](https://github.com/matt-riley/agengit/commit/c25fceefedbf396359ca9a3e2427d8657699dcab))
* **config:** implement crash-safe init/uninstall writes ([d6baa8c](https://github.com/matt-riley/agengit/commit/d6baa8cff10cd10955292cd837c79e6e4899bcde))
* correlate sessions with git commits ([a632ff2](https://github.com/matt-riley/agengit/commit/a632ff21f505e23fc3282180cee53b2bed513c60))
* execute plans 006 007 009 and 010 ([c263461](https://github.com/matt-riley/agengit/commit/c263461caf7bde0b11563a2560b334416e2f686c))
* **hooks:** add structured payload diagnostics ([1e0ef2e](https://github.com/matt-riley/agengit/commit/1e0ef2e84bb94a1de5bb2e95572d6d05244bb1dc))
* **hooks:** implement ADR-024 event identity and cwd anchoring ([2374b9b](https://github.com/matt-riley/agengit/commit/2374b9b6737e69ab895b40c9ee53edfe5ec14428))
* **locking:** implement robust concurrent lock handling ([3cf6f58](https://github.com/matt-riley/agengit/commit/3cf6f581c6d57555c47fb2a7252519992784aa35))
* persist session evaluation reports as eval objects ([#84](https://github.com/matt-riley/agengit/issues/84)) ([faed198](https://github.com/matt-riley/agengit/commit/faed1982dc9c1dba79209d7c31b7db3900ae0c14))
* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([da53a01](https://github.com/matt-riley/agengit/commit/da53a01afa13b45d10c60756a6031dfc83c2b8ae))
* Phase 4 – recorder/capture engine ([2aae8cc](https://github.com/matt-riley/agengit/commit/2aae8cc43df6f085514f7c2a99221bee70f1d2de))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([d82274f](https://github.com/matt-riley/agengit/commit/d82274f59fdd2561c73d09582302ea3ca1ef14c4))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([297f228](https://github.com/matt-riley/agengit/commit/297f2280a9dbb827c1f856977274a3ebfeafb7fc))
* Phase 7 – integration tests, release workflow, and Renovate config ([1c11f65](https://github.com/matt-riley/agengit/commit/1c11f654fde3ba0aebff4592693c52f605ac3f9e))
* **privacy:** implement ADR 026 controls ([85340b6](https://github.com/matt-riley/agengit/commit/85340b6cb73ec7a39021d77e66335725dc92c44f))
* record and render per-line blame attribution ([0d8bb7e](https://github.com/matt-riley/agengit/commit/0d8bb7ef327b3d43c691d50a448c878d10b0cd6f))
* record per-step model attribution ([9626597](https://github.com/matt-riley/agengit/commit/9626597520c7b22393cd8e1f5ceb597b41afa6b6))
* **recorder:** make finalize CAS-first and add stats ([d933b58](https://github.com/matt-riley/agengit/commit/d933b58450578c654224ced4d6f133a521709a9d))
* restore captured snapshots to the working tree ([c84b4b1](https://github.com/matt-riley/agengit/commit/c84b4b12b42aedd9f474e6e92dcfb1c55a50c3dc))
* show agent and model in blame output ([694001d](https://github.com/matt-riley/agengit/commit/694001d39d12a1366cde57cd2564675089f134c4))
* **store:** add durable directory fsync for atomic writes ([068810d](https://github.com/matt-riley/agengit/commit/068810dd9fc23d7b9c73bc19b120153e12de05c7))
* **store:** add gc packfiles and blob deltas ([90dc32d](https://github.com/matt-riley/agengit/commit/90dc32d023bd4d38b0a0821573cdfe7e3e74173d))
* **store:** cache object prefix resolution ([0f666b7](https://github.com/matt-riley/agengit/commit/0f666b7e7be5535641e8f70f39e59316c818133c))
* **store:** implement ADR 007 reconcile and incremental reindex ([#43](https://github.com/matt-riley/agengit/issues/43)) ([763380c](https://github.com/matt-riley/agengit/commit/763380cf0c528b0de121f99462b8803ae07cbf4e))
* switch VHS demos from gif to mp4, fix agit status leak ([44239d0](https://github.com/matt-riley/agengit/commit/44239d055beacd305b805fe17754defc049c5ba4))
* sync README commands from usage specs ([d9ae2cf](https://github.com/matt-riley/agengit/commit/d9ae2cf3561b47cd843eae38617c9779bcbdb5b3))


### Bug Fixes

* align sanitizer config for smoke doctor ([307e02c](https://github.com/matt-riley/agengit/commit/307e02c57408d6a9d94c8aaed8b34be4599139d5))
* **ci:** grant package read to shared workflow callers ([f279d80](https://github.com/matt-riley/agengit/commit/f279d80c4ca772f0f8775b4c1afedb9d3c369700))
* **ci:** satisfy workflow shell lint ([2922fc5](https://github.com/matt-riley/agengit/commit/2922fc59f844a09568fa97cf7186ca3d88be0d36))
* **ci:** use workflow token for release labels ([#63](https://github.com/matt-riley/agengit/issues/63)) ([8d24fdf](https://github.com/matt-riley/agengit/commit/8d24fdffe7e781a30ce93107cb7305063cd58992))
* **ci:** wire Zig sanitizer option ([70368e2](https://github.com/matt-riley/agengit/commit/70368e2423e3ff3fa893396b0db5c1e77a619eee))
* close file handles correctly in watch e2e test ([a29b340](https://github.com/matt-riley/agengit/commit/a29b340941163cf19e9faa0f96e90f9e7d0c43ff))
* correct JSON string-end detection and expand secret redaction rules ([adee437](https://github.com/matt-riley/agengit/commit/adee43760aff28dc98b0154de9fcd629e7b948d0))
* correct store diagnostics ([7c621af](https://github.com/matt-riley/agengit/commit/7c621afd64b92b47e666fb1995a7c75402f178dc))
* emit valid Codex hooks config ([d2c24bd](https://github.com/matt-riley/agengit/commit/d2c24bd44f3a833238c63019ddabee0558c6e4fc))
* failing test ([5af5b3e](https://github.com/matt-riley/agengit/commit/5af5b3e34948e7b6e601dca98383eb4946da86a3))
* **file-lock:** remove unsupported createFile make_path option ([025bc3d](https://github.com/matt-riley/agengit/commit/025bc3dda2183a12dc4200bfd2269e070053db85))
* **gemini:** update hooks to use array format in settings.json ([ad6fc1b](https://github.com/matt-riley/agengit/commit/ad6fc1be454621fac1d4d5ae9f8f95997711b8c3))
* harden privacy config and remote security defaults ([5063957](https://github.com/matt-riley/agengit/commit/5063957e9793bdaa85bfa09dca08001ab9686ef1))
* harden recording-path cwd with .agit/ ancestry check ([#87](https://github.com/matt-riley/agengit/issues/87)) ([a423e49](https://github.com/matt-riley/agengit/commit/a423e49cc1af33317cdd4404ffae549d1f32dd3f))
* hide VHS setup (source/cd) from demo videos ([9309913](https://github.com/matt-riley/agengit/commit/9309913c91cc17d97707520e047d20fe9eaadb06))
* ignore video links in docs checker ([c26dadf](https://github.com/matt-riley/agengit/commit/c26dadf2cc8f05a89cb24ac24cce1c06f1833504))
* implement Windows process liveness via OpenProcess/GetExitCodeProcess ([be63e5a](https://github.com/matt-riley/agengit/commit/be63e5a725d4933d42707d3bf019e7dbe3eace30))
* install Copilot capture as an extension ([495af92](https://github.com/matt-riley/agengit/commit/495af9279cdd003e2ef0a3f7a8c8d1094303cf28))
* isolate openWorkspaceDir fallback tests from repo's own .agit ancestor ([33f8ffc](https://github.com/matt-riley/agengit/commit/33f8ffc1f357fa962b4f745f42e87c57f847bb82))
* keep e2e hook fixtures inside test package ([90803c0](https://github.com/matt-riley/agengit/commit/90803c03cdcd7159aa9af9d638af1a86141be9f9))
* make blame VHS show agent and model attribution ([d0020de](https://github.com/matt-riley/agengit/commit/d0020ded747f4dba99c6bc293e43e13241ede8a8))
* normalize path separators to forward-slashes on Windows ([422d7c2](https://github.com/matt-riley/agengit/commit/422d7c2098aa22c96b0198fe3a512195e226f26b))
* parse --help before opening store in log command ([d7baad4](https://github.com/matt-riley/agengit/commit/d7baad40a14cf7d530a18903be95a7e57d1b1377))
* re-render log.mp4 (was showing 'session not found') ([b44901a](https://github.com/matt-riley/agengit/commit/b44901a25924efc225e5124797ba58507921c03f))
* regenerate VHS demo gifs without error messages ([0aed9ce](https://github.com/matt-riley/agengit/commit/0aed9ce72d68475238e637ec0553c5c78f8088d2))
* reject absolute cwd in hook payload ([115a8cb](https://github.com/matt-riley/agengit/commit/115a8cbcd4f5bacbab23419afa9879f5442f6f86))
* **release:** reconcile release-please labels ([922c0ba](https://github.com/matt-riley/agengit/commit/922c0ba5638bdacb77144f3e85f1e16f0d8b8870))
* **release:** skip github release in release-please step ([2a364bd](https://github.com/matt-riley/agengit/commit/2a364bd09690e4616652b43c0439690a1007fe6c))
* **release:** use release-please token for label reconciliation ([e5b885c](https://github.com/matt-riley/agengit/commit/e5b885ce2e7a9c62c8880f7a258bc1286de8ccf4))
* remove absolute paths from VHS tapes ([d1f289b](https://github.com/matt-riley/agengit/commit/d1f289bc7ed0f5152d3e69a93ab9ec72a9e1e614))
* repair log and uninstall demo videos ([9c0e87f](https://github.com/matt-riley/agengit/commit/9c0e87f4617d02bf7ca6ae42f899a8ca63b67c35))
* repair stale meta_ref in reconcileSession divergence case ([ea646f1](https://github.com/matt-riley/agengit/commit/ea646f1f27a625aa752e3495dceafa53b37fcc81))
* replace brittle substring-based object kind detection ([48285ed](https://github.com/matt-riley/agengit/commit/48285ed293b7e55cd12f90efb6d6408b30ed26be))
* resolve issues [#67](https://github.com/matt-riley/agengit/issues/67)-[#70](https://github.com/matt-riley/agengit/issues/70) ([0e3be2f](https://github.com/matt-riley/agengit/commit/0e3be2f5d483a566c023933d939003134c705c32))
* restore release label updates ([20badc2](https://github.com/matt-riley/agengit/commit/20badc2c653fb7248afaa4ba4ac41b96810f1dbb))
* seed .agit store root before running hooks in non_mutating_open e2e test ([#55](https://github.com/matt-riley/agengit/issues/55)) ([08deeb6](https://github.com/matt-riley/agengit/commit/08deeb6d369b9ae8f4c47669fa7683a9ad9e9c14))
* something? ([7b9b471](https://github.com/matt-riley/agengit/commit/7b9b47184e4fdc526db51e8440255e5deb59eada))
* split release publishing from release-please ([#52](https://github.com/matt-riley/agengit/issues/52)) ([db366fc](https://github.com/matt-riley/agengit/commit/db366fcce06f549ee16a6357b3669968ff45e48d))
* stop silently overwriting blame when prior state is unavailable ([aa84cbb](https://github.com/matt-riley/agengit/commit/aa84cbb0d05480d94dfe503120ac4b4e1f8cbbf1))
* **store:** serialize fresh index bootstrap ([1d0e0a2](https://github.com/matt-riley/agengit/commit/1d0e0a2483891d7a66ea1cd173ca27a59c079613))
* sync reindex with blame timestamp counter and clear stale meta ([72e139b](https://github.com/matt-riley/agengit/commit/72e139be01f177214b4e797e095e7c6d5cb0dc61))
* **tests:** create sandbox agit repo for privacy scan ([2830f6a](https://github.com/matt-riley/agengit/commit/2830f6abb8deed9d0ccf74c9113b9c1e3a64e20f))
* tighten eval scope handling ([ff749b2](https://github.com/matt-riley/agengit/commit/ff749b22e2d8664514ce97d2acf30475ee0420f8))
* update blame.gif to show help text (fixture lacks blame data) ([96469e2](https://github.com/matt-riley/agengit/commit/96469e21788cfdd355ef9f0e147cfb67ed2c6f78))
* upgrade remote encryption KDF from SHA-256 to Argon2id ([d0fa37c](https://github.com/matt-riley/agengit/commit/d0fa37c7eb9817924c2b3c5593b2a00fd0caa0ac))
* use absolute path for runtime.env in VHS tapes ([bcce616](https://github.com/matt-riley/agengit/commit/bcce61617f9ea6bef06448c02c9d4cc33c8cd52b))
* use target-safe home directory lookup ([03a4c1b](https://github.com/matt-riley/agengit/commit/03a4c1bb83b39d38bbf155bc6005cfbd12d66680))
* validate and normalize hook failure workspace path ([c4ac85c](https://github.com/matt-riley/agengit/commit/c4ac85c4d8aec4ea699d32d9a066a991eb637b3f))
* versioning ([30b3fad](https://github.com/matt-riley/agengit/commit/30b3fad9e74b80c11822527b1ae6c6ff19f60822))
* workflow issue with tokens ([650b6f0](https://github.com/matt-riley/agengit/commit/650b6f06d995f151a032731a3299b3d7d80dc7e8))
* write Codex hooks in matcher group format ([9586416](https://github.com/matt-riley/agengit/commit/95864166bc8c6ffa66bd7745aab3145698cb832a))
* write fake S3 ready file atomically ([b141560](https://github.com/matt-riley/agengit/commit/b14156004ec5a663a785a404a62636f63b11aac1))


### Performance Improvements

* append-only staging file for recorder turns ([#76](https://github.com/matt-riley/agengit/issues/76)) ([65d5d13](https://github.com/matt-riley/agengit/commit/65d5d13e593c0989289eb5f0c0331d239ef1be47))
* batch blame step-meta lookups and hashmap dedup ([#78](https://github.com/matt-riley/agengit/issues/78)) ([009a3d2](https://github.com/matt-riley/agengit/commit/009a3d2a3a7fa1855c42174401990c3a1b3d049c))
* cache parsed trees and reuse step-row tree hashes in agit stats file tally ([4145b0f](https://github.com/matt-riley/agengit/commit/4145b0f0bf557feb9ac32a94d7aa6ab8434f0e4c))
* serve timeline/watch/recall previews from the index ([#77](https://github.com/matt-riley/agengit/issues/77)) ([587be97](https://github.com/matt-riley/agengit/commit/587be9718c30070d4bc5f773aa102c806aa6b212))
* **store:** optimize snapshot and blame hot paths ([000938a](https://github.com/matt-riley/agengit/commit/000938aa6717c94acc398a443e383dabf53fd33e))

## [1.25.1](https://github.com/matt-riley/agengit/compare/v1.25.0...v1.25.1) (2026-06-26)


### Bug Fixes

* ignore video links in docs checker ([3bb854d](https://github.com/matt-riley/agengit/commit/3bb854d3f7670ab8f2d2ff8fde4fd5f878e0b204))

## [1.25.0](https://github.com/matt-riley/agengit/compare/v1.24.0...v1.25.0) (2026-06-26)


### Features

* show agent and model in blame output ([086865c](https://github.com/matt-riley/agengit/commit/086865cc8182f1e591dd2f54ea7c65a7fd9a86f3))
* switch VHS demos from gif to mp4, fix agit status leak ([cd1e597](https://github.com/matt-riley/agengit/commit/cd1e597af762a2465e152b2711b81f43a71a1611))


### Bug Fixes

* hide VHS setup (source/cd) from demo videos ([0306e7c](https://github.com/matt-riley/agengit/commit/0306e7c1ab9e6ba3e62c8534fb6b866d70a54b60))
* make blame VHS show agent and model attribution ([c665187](https://github.com/matt-riley/agengit/commit/c6651870357fe8a155ad13a80d26dfb9b8ad6940))
* re-render log.mp4 (was showing 'session not found') ([10f399d](https://github.com/matt-riley/agengit/commit/10f399dbaef23492bea116b178c4e58b510c22ce))
* regenerate VHS demo gifs without error messages ([2689822](https://github.com/matt-riley/agengit/commit/268982295b083e432bebdbab299f897057acf950))
* remove absolute paths from VHS tapes ([1441845](https://github.com/matt-riley/agengit/commit/1441845d9a895e87f78ef91327186c5d4e9b9aa8))
* repair log and uninstall demo videos ([4720794](https://github.com/matt-riley/agengit/commit/47207944e243dabf0023e1b5683ea8991dec4db7))
* update blame.gif to show help text (fixture lacks blame data) ([13784b9](https://github.com/matt-riley/agengit/commit/13784b9ba12af443c832d126d3903a3196710ed1))
* use absolute path for runtime.env in VHS tapes ([22b31c4](https://github.com/matt-riley/agengit/commit/22b31c42878faa8f4fb206ab3906962ef3eee332))

## [1.24.0](https://github.com/matt-riley/agengit/compare/v1.23.0...v1.24.0) (2026-06-21)


### Features

* add blob-body content search to grep ([#86](https://github.com/matt-riley/agengit/issues/86)) ([a5e4377](https://github.com/matt-riley/agengit/commit/a5e43777c80185bbe721740ec11abe3d7b160779))
* add experimental jsonl observer source ([#79](https://github.com/matt-riley/agengit/issues/79)) ([9c431f3](https://github.com/matt-riley/agengit/commit/9c431f31eefc2cb1a8a1354fc1fe801dbf9e19cc))
* persist session evaluation reports as eval objects ([#84](https://github.com/matt-riley/agengit/issues/84)) ([9e30a37](https://github.com/matt-riley/agengit/commit/9e30a37ce4a53e0fa1290217b8b1a20d14bbcb8e))


### Bug Fixes

* harden recording-path cwd with .agit/ ancestry check ([#87](https://github.com/matt-riley/agengit/issues/87)) ([5eeb60d](https://github.com/matt-riley/agengit/commit/5eeb60d54f7f4ecc9f6d57b232125a2fd498b0d9))
* isolate openWorkspaceDir fallback tests from repo's own .agit ancestor ([9a97bc2](https://github.com/matt-riley/agengit/commit/9a97bc2757315d12db718297286f86781757d705))
* keep e2e hook fixtures inside test package ([f70ff13](https://github.com/matt-riley/agengit/commit/f70ff13ae2eed07f6dc01f1675a1134b604be043))


### Performance Improvements

* append-only staging file for recorder turns ([#76](https://github.com/matt-riley/agengit/issues/76)) ([4308779](https://github.com/matt-riley/agengit/commit/4308779946551a0450fbf025779a755b1f2665c5))
* batch blame step-meta lookups and hashmap dedup ([#78](https://github.com/matt-riley/agengit/issues/78)) ([2d51172](https://github.com/matt-riley/agengit/commit/2d51172c127a5df93a2b0a1ff30a582677e4bc0f))
* cache parsed trees and reuse step-row tree hashes in agit stats file tally ([8e3107a](https://github.com/matt-riley/agengit/commit/8e3107a6d09857d5028eaf0fd081a71a74fb051c))
* serve timeline/watch/recall previews from the index ([#77](https://github.com/matt-riley/agengit/issues/77)) ([fec1e5f](https://github.com/matt-riley/agengit/commit/fec1e5f39e6f1616a454fc3d7fd0013bb622dc91))

## [1.23.0](https://github.com/matt-riley/agengit/compare/v1.22.3...v1.23.0) (2026-06-21)


### Features

* record per-step model attribution ([54e40a6](https://github.com/matt-riley/agengit/commit/54e40a6eee2dadbb8ef824c90bf15e340673acc3))

## [1.22.3](https://github.com/matt-riley/agengit/compare/v1.22.2...v1.22.3) (2026-06-20)


### Bug Fixes

* correct store diagnostics ([8a2e8c7](https://github.com/matt-riley/agengit/commit/8a2e8c7b14956c830efb9ce55d3b420368729903))
* something? ([dc0d2d0](https://github.com/matt-riley/agengit/commit/dc0d2d0390e92478b45334d757de80ba8de17ecf))

## [1.22.2](https://github.com/matt-riley/agengit/compare/v1.22.1...v1.22.2) (2026-06-20)


### Bug Fixes

* resolve issues [#67](https://github.com/matt-riley/agengit/issues/67)-[#70](https://github.com/matt-riley/agengit/issues/70) ([f1ba783](https://github.com/matt-riley/agengit/commit/f1ba7837f18632b10f7f229e1bbc07cf44a14025))

## [1.22.1](https://github.com/matt-riley/agengit/compare/v1.22.0...v1.22.1) (2026-06-20)


### Bug Fixes

* reject absolute cwd in hook payload ([2bbaf68](https://github.com/matt-riley/agengit/commit/2bbaf6883501f82a1ae791999620b8633c3420bf))

## [1.22.0](https://github.com/matt-riley/agengit/compare/v1.21.5...v1.22.0) (2026-06-20)


### Features

* execute plans 006 007 009 and 010 ([98ea006](https://github.com/matt-riley/agengit/commit/98ea00620bd5efdb8d4f5eeae1bfbd6bbb59d159))


### Bug Fixes

* close file handles correctly in watch e2e test ([b2d0213](https://github.com/matt-riley/agengit/commit/b2d0213bb92d6534a649fdee57b0e1c6e4f5c412))
* emit valid Codex hooks config ([07fffa1](https://github.com/matt-riley/agengit/commit/07fffa15f4063ecaa348ba5b72fc21d820f8c7a9))
* failing test ([989ce06](https://github.com/matt-riley/agengit/commit/989ce0697aef8d10cc79a00954e13a08815b3237))
* replace brittle substring-based object kind detection ([2992a14](https://github.com/matt-riley/agengit/commit/2992a1415639d6dcf63398994c2bf91b4de76b87))
* stop silently overwriting blame when prior state is unavailable ([d92ea40](https://github.com/matt-riley/agengit/commit/d92ea409f621c6dee45b3d0c8eae04bd8fde9dbf))
* sync reindex with blame timestamp counter and clear stale meta ([cea6ee8](https://github.com/matt-riley/agengit/commit/cea6ee8b0c4b09cdd7f72c7856e2cfa2204c522b))
* validate and normalize hook failure workspace path ([b1fd786](https://github.com/matt-riley/agengit/commit/b1fd786eeca8f5df68c8b5961e25966849247590))

## [1.21.5](https://github.com/matt-riley/agengit/compare/v1.21.4...v1.21.5) (2026-06-18)


### Bug Fixes

* tighten eval scope handling ([bae6a6c](https://github.com/matt-riley/agengit/commit/bae6a6cece26873673312fbb90f5e750e148340d))

## [1.21.4](https://github.com/matt-riley/agengit/compare/v1.21.3...v1.21.4) (2026-06-17)


### Bug Fixes

* restore release label updates ([39493f9](https://github.com/matt-riley/agengit/commit/39493f9d10454681aff51829160fcdcc7f2be617))

## [1.21.3](https://github.com/matt-riley/agengit/compare/v1.21.2...v1.21.3) (2026-06-17)


### Bug Fixes

* **ci:** use workflow token for release labels ([#63](https://github.com/matt-riley/agengit/issues/63)) ([0ebc771](https://github.com/matt-riley/agengit/commit/0ebc77149dc14eb184f4170cda3ce599d5323d04))

## [1.21.2](https://github.com/matt-riley/agengit/compare/v1.21.1...v1.21.2) (2026-06-17)


### Bug Fixes

* workflow issue with tokens ([1a022e5](https://github.com/matt-riley/agengit/commit/1a022e5a0956a5897cc8aa3e1a23cb715c6c0920))

## [1.21.1](https://github.com/matt-riley/agengit/compare/v1.21.0...v1.21.1) (2026-06-17)


### Bug Fixes

* **release:** use release-please token for label reconciliation ([432f524](https://github.com/matt-riley/agengit/commit/432f5246708f8d76354a3bb3438e60f2859edb5d))
* versioning ([c6d14f3](https://github.com/matt-riley/agengit/commit/c6d14f3fc84681e0a37691a3236555c047718307))

## [1.21.0](https://github.com/matt-riley/agengit/compare/v1.20.1...v1.21.0) (2026-06-16)


### Features

* add evidence-based eval command ([f971141](https://github.com/matt-riley/agengit/commit/f9711415be6776afdf54c0087bacf8b4c56cfd1a))


### Bug Fixes

* **ci:** grant package read to shared workflow callers ([ac83b08](https://github.com/matt-riley/agengit/commit/ac83b0811cd90a958bcaba845af8885f0b4c8e83))
* **ci:** satisfy workflow shell lint ([2e65f66](https://github.com/matt-riley/agengit/commit/2e65f667a1f194346f5d07dd09d39d81a1386b3d))
* **release:** reconcile release-please labels ([1ad2819](https://github.com/matt-riley/agengit/commit/1ad2819b8322e1a0607cc6db8a4f34bca77046a3))
* **release:** skip github release in release-please step ([a4fd199](https://github.com/matt-riley/agengit/commit/a4fd1991536b17e4aa2004dfd6be744a85195f20))

## [1.20.1](https://github.com/matt-riley/agengit/compare/v1.20.0...v1.20.1) (2026-06-02)


### Bug Fixes

* install Copilot capture as an extension ([9838892](https://github.com/matt-riley/agengit/commit/98388924e7e72ac43a618e0927aaef1bba787aad))

## [1.20.0](https://github.com/matt-riley/agengit/compare/v1.19.0...v1.20.0) (2026-05-31)


### Features

* add recall memory retrieval and replay non-goal ADR ([3585245](https://github.com/matt-riley/agengit/commit/358524573b3ef2a96fec7d0318e78508fb917cc1))

## [1.19.0](https://github.com/matt-riley/agengit/compare/v1.18.2...v1.19.0) (2026-05-31)


### Features

* add Copilot CLI hook integration ([c5e3bb1](https://github.com/matt-riley/agengit/commit/c5e3bb1d3c086a377569f324aebb265fd57815ed))
* add Pi hook integration ([674e12e](https://github.com/matt-riley/agengit/commit/674e12e56e77d75e28b581376b92a6018de7b0f8))
* add watch and analytics commands ([0053195](https://github.com/matt-riley/agengit/commit/005319530bb31286c7d2771ca0ebb7ce59f92a3a))
* correlate sessions with git commits ([f2bace0](https://github.com/matt-riley/agengit/commit/f2bace0481480a9b6117506443aa595650cc623d))
* record and render per-line blame attribution ([8fd7eb0](https://github.com/matt-riley/agengit/commit/8fd7eb0ef94565204c2ea64bf7a20e7e94f7986b))
* restore captured snapshots to the working tree ([58aefe3](https://github.com/matt-riley/agengit/commit/58aefe3a66b29dc0766b9f75719364a687c1c102))

## [1.18.2](https://github.com/matt-riley/agengit/compare/v1.18.1...v1.18.2) (2026-05-29)


### Bug Fixes

* correct JSON string-end detection and expand secret redaction rules ([16d55ad](https://github.com/matt-riley/agengit/commit/16d55add7c6c963effd070a1e63b9c581360b3dd))
* harden privacy config and remote security defaults ([1c58dea](https://github.com/matt-riley/agengit/commit/1c58dea56e4004bebf438e0c4f4e7aaa9f443acc))
* implement Windows process liveness via OpenProcess/GetExitCodeProcess ([04aae7e](https://github.com/matt-riley/agengit/commit/04aae7eb9b91706235e96083997d38d4645635d5))
* repair stale meta_ref in reconcileSession divergence case ([69a3d42](https://github.com/matt-riley/agengit/commit/69a3d4250e06942cc66095a594874a167e653a95))
* seed .agit store root before running hooks in non_mutating_open e2e test ([#55](https://github.com/matt-riley/agengit/issues/55)) ([e4cf2c6](https://github.com/matt-riley/agengit/commit/e4cf2c649fc4531f21cd5901f800b77b1daf8e23))
* upgrade remote encryption KDF from SHA-256 to Argon2id ([c24dab9](https://github.com/matt-riley/agengit/commit/c24dab9071d21010a1d6c528acb6a744c6cd48c5))

## [1.18.1](https://github.com/matt-riley/agengit/compare/v1.18.0...v1.18.1) (2026-05-28)


### Bug Fixes

* split release publishing from release-please ([#52](https://github.com/matt-riley/agengit/issues/52)) ([62cacb3](https://github.com/matt-riley/agengit/commit/62cacb3dff9f7c8feca0de9cd5d65b1892ff0a27))

## [1.18.0](https://github.com/matt-riley/agengit/compare/v1.17.0...v1.18.0) (2026-05-28)


### Features

* add experimental observer support ([faf2545](https://github.com/matt-riley/agengit/commit/faf2545181e93f10120bc8438300ef6d3dde0cdb))
* add fsck integrity verification ([e3cba1f](https://github.com/matt-riley/agengit/commit/e3cba1f36f36d91e0cb8888de7a8d0f900db9759))
* add gc store maintenance command ([f026533](https://github.com/matt-riley/agengit/commit/f0265336ce8064bda3eae1f9c62b802657e8a7f1))
* add historical grep command ([2bc6be9](https://github.com/matt-riley/agengit/commit/2bc6be92a226aabe83a4cb52fb4b02f71f0d673d))
* add investigation workflow views ([47107a5](https://github.com/matt-riley/agengit/commit/47107a5aafc0fd92113e34d95c09afe253639991))
* add portable bundle export and import ([6299f93](https://github.com/matt-riley/agengit/commit/6299f93ed64155bf8f67b82d4ce5edfaa1bd5b26))
* add remote push and pull sync ([111f6d0](https://github.com/matt-riley/agengit/commit/111f6d01e827afc5c3cb0a11f40473cd7376f924))
* **cli:** add consistent --help and repo-discovery hints (ADR 012) ([d1ab5f7](https://github.com/matt-riley/agengit/commit/d1ab5f76fb6ea45f498fa4220fbc02c7632983f2))
* **cli:** add structured JSON output and generated completions ([438b3a3](https://github.com/matt-riley/agengit/commit/438b3a344c5cf4d58ebddecee6044e8896b6b183))
* **cli:** implement ADR 029 guided setup and hook-install preview ([50fb16d](https://github.com/matt-riley/agengit/commit/50fb16d4e05585bab7e8a4ffad67605d8b7c2177))
* **config:** implement crash-safe init/uninstall writes ([1a83ae5](https://github.com/matt-riley/agengit/commit/1a83ae540995297ed8149d5bc7a8ddb0cafe36ac))
* **hooks:** add structured payload diagnostics ([05eae69](https://github.com/matt-riley/agengit/commit/05eae6991f4f12c0bdc5d93cd76e9be6ae3d2128))
* **hooks:** implement ADR-024 event identity and cwd anchoring ([5b59c32](https://github.com/matt-riley/agengit/commit/5b59c32a70611ba9d3450d319ca2a463c031536e))
* **locking:** implement robust concurrent lock handling ([5cc76eb](https://github.com/matt-riley/agengit/commit/5cc76eb4c6fab87dd3d7fdaa892f4d29aa33f95c))
* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))
* **privacy:** implement ADR 026 controls ([a46079e](https://github.com/matt-riley/agengit/commit/a46079e19509d79f3b287381e4121ab0b1c758de))
* **recorder:** make finalize CAS-first and add stats ([13154ac](https://github.com/matt-riley/agengit/commit/13154acc5525c26f2a9b92ec04ae049117ad7bd8))
* **store:** add durable directory fsync for atomic writes ([66fdc01](https://github.com/matt-riley/agengit/commit/66fdc0154e1afe089a70d1442f4ac61948c6fa0e))
* **store:** add gc packfiles and blob deltas ([bcc7531](https://github.com/matt-riley/agengit/commit/bcc75318b0a666cff252e0dc926ae300dc8265f3))
* **store:** cache object prefix resolution ([ae921f6](https://github.com/matt-riley/agengit/commit/ae921f6e9f550ca629f60187d8492d4b02a96366))
* **store:** implement ADR 007 reconcile and incremental reindex ([#43](https://github.com/matt-riley/agengit/issues/43)) ([7436c11](https://github.com/matt-riley/agengit/commit/7436c11d1f2f82ae9650bedcf2670386eb32e9b4))
* sync README commands from usage specs ([87950ef](https://github.com/matt-riley/agengit/commit/87950ef1977ba85e43264504edea30193d053055))


### Bug Fixes

* align sanitizer config for smoke doctor ([ff437ff](https://github.com/matt-riley/agengit/commit/ff437ff02501a0c5dbd852ba41a2e232734f0177))
* **ci:** wire Zig sanitizer option ([7f86a5d](https://github.com/matt-riley/agengit/commit/7f86a5dbe37b710585cef36223a358e52b2d9f19))
* **file-lock:** remove unsupported createFile make_path option ([43b1f0a](https://github.com/matt-riley/agengit/commit/43b1f0a527376a5a2ee2660555fabfae86928c4a))
* **gemini:** update hooks to use array format in settings.json ([eb8738b](https://github.com/matt-riley/agengit/commit/eb8738bb0ca6f120c8890464a92762b99edaeced))
* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* parse --help before opening store in log command ([acc2318](https://github.com/matt-riley/agengit/commit/acc23185832fcef9b10cfabedbc367753ad29e8b))
* **store:** serialize fresh index bootstrap ([0f0c47b](https://github.com/matt-riley/agengit/commit/0f0c47b272b5e9063dd9b780efb1179a51efb8a7))
* **tests:** create sandbox agit repo for privacy scan ([0428623](https://github.com/matt-riley/agengit/commit/04286238a5a9546c03e830fcb46c505b7a23a0d0))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))
* write Codex hooks in matcher group format ([dd5a345](https://github.com/matt-riley/agengit/commit/dd5a34546a639b557f3bca13b0e7f3132e70f29f))
* write fake S3 ready file atomically ([ddf550f](https://github.com/matt-riley/agengit/commit/ddf550f2c157751830ec4b4ec2915db5bdfdbb17))


### Performance Improvements

* **store:** optimize snapshot and blame hot paths ([0544219](https://github.com/matt-riley/agengit/commit/0544219bd5e454cff9560dac9d792e11f19761d9))

## [1.17.0](https://github.com/matt-riley/agengit/compare/v1.16.0...v1.17.0) (2026-05-28)


### Features

* add experimental observer support ([faf2545](https://github.com/matt-riley/agengit/commit/faf2545181e93f10120bc8438300ef6d3dde0cdb))
* add fsck integrity verification ([e3cba1f](https://github.com/matt-riley/agengit/commit/e3cba1f36f36d91e0cb8888de7a8d0f900db9759))
* add gc store maintenance command ([f026533](https://github.com/matt-riley/agengit/commit/f0265336ce8064bda3eae1f9c62b802657e8a7f1))
* add historical grep command ([2bc6be9](https://github.com/matt-riley/agengit/commit/2bc6be92a226aabe83a4cb52fb4b02f71f0d673d))
* add investigation workflow views ([47107a5](https://github.com/matt-riley/agengit/commit/47107a5aafc0fd92113e34d95c09afe253639991))
* add portable bundle export and import ([6299f93](https://github.com/matt-riley/agengit/commit/6299f93ed64155bf8f67b82d4ce5edfaa1bd5b26))
* add remote push and pull sync ([111f6d0](https://github.com/matt-riley/agengit/commit/111f6d01e827afc5c3cb0a11f40473cd7376f924))
* **cli:** add consistent --help and repo-discovery hints (ADR 012) ([d1ab5f7](https://github.com/matt-riley/agengit/commit/d1ab5f76fb6ea45f498fa4220fbc02c7632983f2))
* **cli:** add structured JSON output and generated completions ([438b3a3](https://github.com/matt-riley/agengit/commit/438b3a344c5cf4d58ebddecee6044e8896b6b183))
* **cli:** implement ADR 029 guided setup and hook-install preview ([50fb16d](https://github.com/matt-riley/agengit/commit/50fb16d4e05585bab7e8a4ffad67605d8b7c2177))
* **config:** implement crash-safe init/uninstall writes ([1a83ae5](https://github.com/matt-riley/agengit/commit/1a83ae540995297ed8149d5bc7a8ddb0cafe36ac))
* **hooks:** add structured payload diagnostics ([05eae69](https://github.com/matt-riley/agengit/commit/05eae6991f4f12c0bdc5d93cd76e9be6ae3d2128))
* **hooks:** implement ADR-024 event identity and cwd anchoring ([5b59c32](https://github.com/matt-riley/agengit/commit/5b59c32a70611ba9d3450d319ca2a463c031536e))
* **locking:** implement robust concurrent lock handling ([5cc76eb](https://github.com/matt-riley/agengit/commit/5cc76eb4c6fab87dd3d7fdaa892f4d29aa33f95c))
* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))
* **privacy:** implement ADR 026 controls ([a46079e](https://github.com/matt-riley/agengit/commit/a46079e19509d79f3b287381e4121ab0b1c758de))
* **recorder:** make finalize CAS-first and add stats ([13154ac](https://github.com/matt-riley/agengit/commit/13154acc5525c26f2a9b92ec04ae049117ad7bd8))
* **store:** add durable directory fsync for atomic writes ([66fdc01](https://github.com/matt-riley/agengit/commit/66fdc0154e1afe089a70d1442f4ac61948c6fa0e))
* **store:** add gc packfiles and blob deltas ([bcc7531](https://github.com/matt-riley/agengit/commit/bcc75318b0a666cff252e0dc926ae300dc8265f3))
* **store:** cache object prefix resolution ([ae921f6](https://github.com/matt-riley/agengit/commit/ae921f6e9f550ca629f60187d8492d4b02a96366))
* **store:** implement ADR 007 reconcile and incremental reindex ([#43](https://github.com/matt-riley/agengit/issues/43)) ([7436c11](https://github.com/matt-riley/agengit/commit/7436c11d1f2f82ae9650bedcf2670386eb32e9b4))
* sync README commands from usage specs ([87950ef](https://github.com/matt-riley/agengit/commit/87950ef1977ba85e43264504edea30193d053055))


### Bug Fixes

* align sanitizer config for smoke doctor ([ff437ff](https://github.com/matt-riley/agengit/commit/ff437ff02501a0c5dbd852ba41a2e232734f0177))
* **ci:** wire Zig sanitizer option ([7f86a5d](https://github.com/matt-riley/agengit/commit/7f86a5dbe37b710585cef36223a358e52b2d9f19))
* **file-lock:** remove unsupported createFile make_path option ([43b1f0a](https://github.com/matt-riley/agengit/commit/43b1f0a527376a5a2ee2660555fabfae86928c4a))
* **gemini:** update hooks to use array format in settings.json ([eb8738b](https://github.com/matt-riley/agengit/commit/eb8738bb0ca6f120c8890464a92762b99edaeced))
* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* parse --help before opening store in log command ([acc2318](https://github.com/matt-riley/agengit/commit/acc23185832fcef9b10cfabedbc367753ad29e8b))
* **store:** serialize fresh index bootstrap ([0f0c47b](https://github.com/matt-riley/agengit/commit/0f0c47b272b5e9063dd9b780efb1179a51efb8a7))
* **tests:** create sandbox agit repo for privacy scan ([0428623](https://github.com/matt-riley/agengit/commit/04286238a5a9546c03e830fcb46c505b7a23a0d0))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))
* write Codex hooks in matcher group format ([dd5a345](https://github.com/matt-riley/agengit/commit/dd5a34546a639b557f3bca13b0e7f3132e70f29f))
* write fake S3 ready file atomically ([ddf550f](https://github.com/matt-riley/agengit/commit/ddf550f2c157751830ec4b4ec2915db5bdfdbb17))


### Performance Improvements

* **store:** optimize snapshot and blame hot paths ([0544219](https://github.com/matt-riley/agengit/commit/0544219bd5e454cff9560dac9d792e11f19761d9))

## [1.16.0](https://github.com/matt-riley/agengit/compare/v1.15.0...v1.16.0) (2026-05-27)


### Features

* add experimental observer support ([faf2545](https://github.com/matt-riley/agengit/commit/faf2545181e93f10120bc8438300ef6d3dde0cdb))
* add portable bundle export and import ([6299f93](https://github.com/matt-riley/agengit/commit/6299f93ed64155bf8f67b82d4ce5edfaa1bd5b26))
* add remote push and pull sync ([111f6d0](https://github.com/matt-riley/agengit/commit/111f6d01e827afc5c3cb0a11f40473cd7376f924))


### Bug Fixes

* write fake S3 ready file atomically ([ddf550f](https://github.com/matt-riley/agengit/commit/ddf550f2c157751830ec4b4ec2915db5bdfdbb17))

## [1.15.0](https://github.com/matt-riley/agengit/compare/v1.14.0...v1.15.0) (2026-05-26)


### Features

* add investigation workflow views ([47107a5](https://github.com/matt-riley/agengit/commit/47107a5aafc0fd92113e34d95c09afe253639991))
* **store:** add gc packfiles and blob deltas ([bcc7531](https://github.com/matt-riley/agengit/commit/bcc75318b0a666cff252e0dc926ae300dc8265f3))


### Bug Fixes

* **store:** serialize fresh index bootstrap ([0f0c47b](https://github.com/matt-riley/agengit/commit/0f0c47b272b5e9063dd9b780efb1179a51efb8a7))

## [1.14.0](https://github.com/matt-riley/agengit/compare/v1.13.0...v1.14.0) (2026-05-26)


### Features

* add fsck integrity verification ([e3cba1f](https://github.com/matt-riley/agengit/commit/e3cba1f36f36d91e0cb8888de7a8d0f900db9759))
* add gc store maintenance command ([f026533](https://github.com/matt-riley/agengit/commit/f0265336ce8064bda3eae1f9c62b802657e8a7f1))
* add historical grep command ([2bc6be9](https://github.com/matt-riley/agengit/commit/2bc6be92a226aabe83a4cb52fb4b02f71f0d673d))
* **privacy:** implement ADR 026 controls ([a46079e](https://github.com/matt-riley/agengit/commit/a46079e19509d79f3b287381e4121ab0b1c758de))
* **store:** cache object prefix resolution ([ae921f6](https://github.com/matt-riley/agengit/commit/ae921f6e9f550ca629f60187d8492d4b02a96366))
* sync README commands from usage specs ([87950ef](https://github.com/matt-riley/agengit/commit/87950ef1977ba85e43264504edea30193d053055))


### Bug Fixes

* **tests:** create sandbox agit repo for privacy scan ([0428623](https://github.com/matt-riley/agengit/commit/04286238a5a9546c03e830fcb46c505b7a23a0d0))


### Performance Improvements

* **store:** optimize snapshot and blame hot paths ([0544219](https://github.com/matt-riley/agengit/commit/0544219bd5e454cff9560dac9d792e11f19761d9))

## [1.13.0](https://github.com/matt-riley/agengit/compare/v1.12.0...v1.13.0) (2026-05-25)


### Features

* **cli:** add consistent --help and repo-discovery hints (ADR 012) ([d1ab5f7](https://github.com/matt-riley/agengit/commit/d1ab5f76fb6ea45f498fa4220fbc02c7632983f2))
* **cli:** add structured JSON output and generated completions ([438b3a3](https://github.com/matt-riley/agengit/commit/438b3a344c5cf4d58ebddecee6044e8896b6b183))
* **cli:** implement ADR 029 guided setup and hook-install preview ([50fb16d](https://github.com/matt-riley/agengit/commit/50fb16d4e05585bab7e8a4ffad67605d8b7c2177))
* **hooks:** implement ADR-024 event identity and cwd anchoring ([5b59c32](https://github.com/matt-riley/agengit/commit/5b59c32a70611ba9d3450d319ca2a463c031536e))


### Bug Fixes

* align sanitizer config for smoke doctor ([ff437ff](https://github.com/matt-riley/agengit/commit/ff437ff02501a0c5dbd852ba41a2e232734f0177))
* **ci:** wire Zig sanitizer option ([7f86a5d](https://github.com/matt-riley/agengit/commit/7f86a5dbe37b710585cef36223a358e52b2d9f19))
* parse --help before opening store in log command ([acc2318](https://github.com/matt-riley/agengit/commit/acc23185832fcef9b10cfabedbc367753ad29e8b))

## [1.12.0](https://github.com/matt-riley/agengit/compare/v1.11.1...v1.12.0) (2026-05-25)


### Features

* **hooks:** add structured payload diagnostics ([05eae69](https://github.com/matt-riley/agengit/commit/05eae6991f4f12c0bdc5d93cd76e9be6ae3d2128))

## [1.11.1](https://github.com/matt-riley/agengit/compare/v1.11.0...v1.11.1) (2026-05-25)


### Bug Fixes

* **gemini:** update hooks to use array format in settings.json ([eb8738b](https://github.com/matt-riley/agengit/commit/eb8738bb0ca6f120c8890464a92762b99edaeced))

## [1.11.0](https://github.com/matt-riley/agengit/compare/v1.10.0...v1.11.0) (2026-05-25)


### Features

* **recorder:** make finalize CAS-first and add stats ([13154ac](https://github.com/matt-riley/agengit/commit/13154acc5525c26f2a9b92ec04ae049117ad7bd8))
* **store:** implement ADR 007 reconcile and incremental reindex ([#43](https://github.com/matt-riley/agengit/issues/43)) ([7436c11](https://github.com/matt-riley/agengit/commit/7436c11d1f2f82ae9650bedcf2670386eb32e9b4))


### Bug Fixes

* write Codex hooks in matcher group format ([dd5a345](https://github.com/matt-riley/agengit/commit/dd5a34546a639b557f3bca13b0e7f3132e70f29f))

## [1.10.0](https://github.com/matt-riley/agengit/compare/v1.9.0...v1.10.0) (2026-05-25)


### Features

* **config:** implement crash-safe init/uninstall writes ([1a83ae5](https://github.com/matt-riley/agengit/commit/1a83ae540995297ed8149d5bc7a8ddb0cafe36ac))
* **locking:** implement robust concurrent lock handling ([5cc76eb](https://github.com/matt-riley/agengit/commit/5cc76eb4c6fab87dd3d7fdaa892f4d29aa33f95c))
* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))
* **store:** add durable directory fsync for atomic writes ([66fdc01](https://github.com/matt-riley/agengit/commit/66fdc0154e1afe089a70d1442f4ac61948c6fa0e))


### Bug Fixes

* **file-lock:** remove unsupported createFile make_path option ([43b1f0a](https://github.com/matt-riley/agengit/commit/43b1f0a527376a5a2ee2660555fabfae86928c4a))
* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.9.0](https://github.com/matt-riley/agengit/compare/v1.8.0...v1.9.0) (2026-05-25)


### Features

* **config:** implement crash-safe init/uninstall writes ([1a83ae5](https://github.com/matt-riley/agengit/commit/1a83ae540995297ed8149d5bc7a8ddb0cafe36ac))
* **locking:** implement robust concurrent lock handling ([5cc76eb](https://github.com/matt-riley/agengit/commit/5cc76eb4c6fab87dd3d7fdaa892f4d29aa33f95c))
* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))
* **store:** add durable directory fsync for atomic writes ([66fdc01](https://github.com/matt-riley/agengit/commit/66fdc0154e1afe089a70d1442f4ac61948c6fa0e))


### Bug Fixes

* **file-lock:** remove unsupported createFile make_path option ([43b1f0a](https://github.com/matt-riley/agengit/commit/43b1f0a527376a5a2ee2660555fabfae86928c4a))
* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.8.0](https://github.com/matt-riley/agengit/compare/v1.7.0...v1.8.0) (2026-05-25)


### Features

* **locking:** implement robust concurrent lock handling ([5cc76eb](https://github.com/matt-riley/agengit/commit/5cc76eb4c6fab87dd3d7fdaa892f4d29aa33f95c))

## [1.7.0](https://github.com/matt-riley/agengit/compare/v1.6.0...v1.7.0) (2026-05-25)


### Features

* **store:** add durable directory fsync for atomic writes ([66fdc01](https://github.com/matt-riley/agengit/commit/66fdc0154e1afe089a70d1442f4ac61948c6fa0e))

## [1.6.0](https://github.com/matt-riley/agengit/compare/v1.5.0...v1.6.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.5.0](https://github.com/matt-riley/agengit/compare/v1.4.0...v1.5.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.4.0](https://github.com/matt-riley/agengit/compare/v1.3.0...v1.4.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.3.0](https://github.com/matt-riley/agengit/compare/v1.2.0...v1.3.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
* use target-safe home directory lookup ([d4770d0](https://github.com/matt-riley/agengit/commit/d4770d00dd24e4d2802205d43e27a78a4e38de39))

## [1.2.0](https://github.com/matt-riley/agengit/compare/v1.1.0...v1.2.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))

## [1.1.0](https://github.com/matt-riley/agengit/compare/v1.0.0...v1.1.0) (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))

## 1.0.0 (2026-05-25)


### Features

* Phase 1 – clap/zqlite deps, CLI dispatch, util modules, CI ([8ce3b17](https://github.com/matt-riley/agengit/commit/8ce3b1765463a5af5e4bf44b6183a718f1c1347a))
* Phase 2+3 – core object store, snapshot engine, and blame/diff ([0281539](https://github.com/matt-riley/agengit/commit/0281539c9f32f55d91c8340a4c395cea3ec657d5))
* Phase 4 – recorder/capture engine ([492b343](https://github.com/matt-riley/agengit/commit/492b343eec332049e53e8e409e26a40191f2c800))
* Phase 5 – hook adapters, init/uninstall/doctor, fixture payloads ([163a5d5](https://github.com/matt-riley/agengit/commit/163a5d5ee8a37dadac1aad884cf7f4868f881bc7))
* Phase 6 – user CLI commands (status, sessions, log, show, blame, cat, completion) ([4e8a4c2](https://github.com/matt-riley/agengit/commit/4e8a4c278cb1b20633e855f2a9caf789a8708f77))
* Phase 7 – integration tests, release workflow, and Renovate config ([68b86f1](https://github.com/matt-riley/agengit/commit/68b86f127cbc5668438b535b4707fd02b21a5eaf))


### Bug Fixes

* normalize path separators to forward-slashes on Windows ([3bdcd7c](https://github.com/matt-riley/agengit/commit/3bdcd7cc628be0e4684e82911f803acef382cbec))
