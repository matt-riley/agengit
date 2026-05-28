# Changelog

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
