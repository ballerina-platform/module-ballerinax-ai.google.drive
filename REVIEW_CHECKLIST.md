# PR #2 Review — Remediation Checklist

Tracking doc for the review of [PR #2](https://github.com/ballerina-platform/module-ballerinax-ai.google.drive/pull/2).
**6 blockers, ~61 distinct issues.** Working doc — delete or gitignore before pushing.

---

## Dependency map — read this before picking a task

Three blockers are chained. Doing them out of order means redoing work:

```
B4 (own ConnectionConfig + serviceUrl)
      └──> B3 (mock service + load() tests)
                 └──> B2 (GraalVM metadata via tracing agent over the test suite)
```

- **B4 first** because the loader currently consumes `drive:ConnectionConfig|drive:Client`, and
  the connector hardcodes `BASE_URL` with no override. Until that changes, no mock service is
  possible, so B3 cannot start.
- **B3 before B2** because the recommended way to produce the GraalVM metadata is to run the
  tracing agent over a real test suite. Writing metadata by hand first, then adding tests,
  means generating it twice.
- **B1, B5, B6 are independent** of that chain and can be done any time.

Phase 2 (B4) also unblocks Impl #1 / #2 / #3 (partial-response `fields`, retry config,
response limits), all of which need an HTTP client you control.

---

## ▶️ START HERE

**Phase 0, then B1.**

Phase 0 is pure deletion — no behaviour changes, no design decisions, ~1 hour. It removes dead
build tooling, dead code, and duplicate docs, which shrinks the diff a reviewer has to read
before the real work lands.

Then **B1** — the only proven silent-wrong-output bug in the PR, and self-contained.

---

## Phase 0 — Subtractive cleanup (no behaviour change) 🟢 low risk

Do this as one commit. Nothing here changes runtime behaviour.

### Dead build tooling
- [x] Remove `:checkstyle` sub-project — `apply plugin: 'checkstyle'` appears nowhere in the repo.
      Delete `build-config/checkstyle/`, and the `include ':checkstyle'` + `project(':checkstyle')`
      lines in `settings.gradle`. *(Alternative: wire it into `native/build.gradle`. Decide, don't leave it half-done.)*
- [x] Remove `com.github.spotbugs-base` and `com.github.johnrengelman.shadow` from `build.gradle:20-21`
      and `settings.gradle:10-11` — applied but never used (no SpotBugs task, no `shadowJar`).
- [x] Delete dead properties in `gradle.properties:12-15`: `ballerinaToOpenApiVersion`,
      `swaggerVersion`, `jacocoVersion`, `checkstylePluginVersion`. Also `spotbugsPluginVersion`
      and `shadowJarPluginVersion` once the plugins above are gone.
- [x] Delete `build.gradle:68` `tasks.findByPath(...).mustRunAfter(...)` — redundant with the
      `dependsOn` in `ballerina/build.gradle:108-109`, and NPEs at configuration time.
- [x] `build.gradle:64-66` — drop the `:ai.google.drive-native:build` dependency; the reference
      depends only on `:...-ballerina:build`.

### Duplicate documentation
- [x] Delete `ballerina/Module.md` and `ballerina/Package.md` — byte-identical to
      `ballerina/README.md`, which supersedes both since Swan Lake U10.
- [x] Remove the root `pull_request_template.md` (52 lines); GitHub only honours
      `.github/pull_request_template.md`.

### Dead code
- [x] `ballerina/utils.bal:179-182` — remove the `file.size` branch. `FILE_FIELDS` (`types.bal:71`)
      deliberately omits `size`, so it can never fire.
- [x] `ballerina/utils.bal:162-165` — fix the doc comment: it references "the Azure Files loader"
      (copy-paste artefact) and claims `size` is present, contradicting `types.bal:66-70`.
- [x] `ballerina/drive_data_loader.bal:197` — remove the `?: EXPORT_MIME_TEXT` fallback;
      `requiresExport()` already guarantees a non-nil result. Error or restructure instead.

### Test theater
- [x] `ballerina/tests/types_test.bal:21-70` — delete all five tests. They assert record field
      defaults, i.e. they test the Ballerina compiler. Replace in Phase 3.
- [x] `ballerina/tests/metadata_test.bal:41-56` — drop the `size` → `fileSize` assertion; it
      asserts the unreachable path removed above.
- [x] `ballerina/tests/client_test.bal:33-48` — drop `testOAuth2RefreshTokenConfigTypeChecks`;
      it asserts a compile-time type, not behaviour.

### API surface
- [x] `ballerina/utils.bal:53` — make `GOOGLE_FOLDER_MIME` module-private.
- [x] `ballerina/utils.bal:292` — make `driveIdFromUrl` private (or rename to `resolveDriveId`
      and document the bare-ID pass-through).

### Docs trim
- [x] `ballerina/README.md:143-149` — cut the three speculative OCR designs to
      "OCR is not supported" + a link to a tracking issue.

---

## Phase 1 — Proven correctness bugs 🔴 self-contained, testable now

### 🔴 B1 — Parser selection ✅ DONE
- [x] `native/.../TextExtractor.java` — `selectParser(fileName, mimeType)` now tries
      `parserForMimeType` first and falls back to `parserForExtension`. MIME parameters
      (`; charset=…`) are stripped before matching. `extractText` takes a third `mimeType`
      argument; `buildDocument` passes `metadata.mimeType ?: ""`.
- [x] Add tests for the three proven failures — **verified they fail against the old
      extension-only logic** (temporarily reverted `selectParser`, confirmed 4 failures, restored):
  - [x] DOCX bytes + name `"Q3 Report"` (no extension) + DOCX MIME
  - [x] XLS bytes + name `"Legacy Sheet"` + `application/vnd.ms-excel`
  - [x] PDF bytes + name `"report.docx"` + `application/pdf`
  - [x] End-to-end via `buildDocument` with the shape `classify` produces
- [x] Fallback tests: no MIME type, `application/octet-stream`, MIME with parameters

### Text decoding ✅ DONE
- [x] BOM stripping — new `TextDecoder.decodeText` resolves the charset from a BOM first and
      strips it. UTF-8/UTF-16LE/UTF-16BE BOMs handled.
- [x] Charset — `FileContent.mimeType` is now plumbed from `fetchAndBuild` into `buildDocument`
      as `contentType`; `charsetFromContentType` extracts the `charset` parameter. Priority:
      BOM → declared charset → UTF-8. Unknown charset names fall back to UTF-8. Decoding stays
      **strict**, so genuinely corrupt bytes still error rather than yielding replacement chars.
- [x] HTML — `TextDecoder.htmlToText` drops script/style bodies and comments, turns block
      boundaries into newlines, strips tags and resolves entities. Applied via a new `isHtml`
      check so a `.txt` containing angle brackets stays verbatim.

### Error handling & diagnostics ✅ DONE
- [x] `drive_data_loader.bal` — `file.id ?: ""` replaced with an explicit "file without an
      identifier" error.
- [x] `drive_data_loader.bal` — `loadFolder` now applies the same `trashed == true` check as
      `loadNamedFile`.
- [x] `client.bal` — `isNotFoundError` now reads the typed `http:ClientRequestError` status
      first (walking the cause chain, since the connector wraps it), and only falls back to
      message matching when there is no status. The bare `"404"` clause is gone.
- [x] `drive_data_loader.bal` — a folder ID in `fileIds` now says "that's a folder, use
      `folderId`" instead of "unsupported file type".
- [x] `utils.bal` + `TextExtractor.java` — the `"no extractable text"` substring contract is
      replaced by a structured `reason = "TEXTLESS_PDF"` detail. `isTextlessPdfError` walks the
      cause chain (the native error is wrapped by `buildDocument`).
      **Note:** the detail map must be an explicitly typed `map<anydata>` —
      `ValueCreator.createMapValue()` untyped makes `error.detail()` throw, and
      `PredefinedTypes.TYPE_ERROR_DETAIL` is readonly so it cannot be populated.
- [x] `TextExtractor.java` — widened to `catch (Exception | StackOverflowError | LinkageError e)`;
      `OutOfMemoryError` deliberately still uncaught.
- [x] `Ballerina.toml` — added `commons-codec` 1.18.0, `curvesapi` 1.08, `commons-math3` 3.6.1
      (the versions POI 5.4.1 declares). Added to the **template** (`build-config/resources/`),
      `gradle.properties`, and the `updateTomlFiles` replacements as well as the generated file.

---

## Phase 2 — 🔴 B4: Own the connection config ✅ DONE

**Decision:** the connector was removed entirely in favour of an owned `http:Client`. The
deciding constraint was that `googleapis.drive` hardcodes `BASE_URL` as a module-private const
with no `serviceUrl` — so a client built from it can never be pointed at a mock, which is what
blocks B3. Four other limits fell away with it (no field mask on listings → N+1; `File.size`
typed `int` where Drive sends a string → field unrequestable; no service-account auth; errors
returned as stringified JSON with no cause or status code).

- [x] Package-local public `ConnectionConfig` in `types.bal`: `serviceUrl` (default
      `DEFAULT_SERVICE_URL`), `auth` (now including `http:OAuth2JwtBearerGrantConfig`, so
      **service accounts work** — Impl #10), `timeout`, `retryConfig`, `responseLimits`,
      `maxFileSizeBytes`, `acknowledgeAbuse`, plus the usual `http:ClientConfiguration` subset.
- [x] `DriveClient` in `client.bal` owns an `http:Client` over four endpoints: `files.get`,
      `files.list` (paginated), `alt=media` download, `/export`. Own `DriveFile` /
      `DriveFileList` response types.
- [x] `drive:Client` reuse overload **dropped** — keeping it would mean keeping the dependency
      and two divergent code paths.
- [x] `ballerinax/googleapis.drive` gone from `Dependencies.toml`. This also removed
      `ballerinax/client.config`, which was the source of the pre-Update-12 build warning
      (**Version #3 resolved as a side effect** — the build is now warning-free).
- [x] `init()` now resolves every URL and enforces the folderId/folderUrl rule up front, storing
      `ResolvedSource[]`; `load()` cannot fail on configuration any more.
- [x] A `Source` that selects nothing logs a warning at `init`.
- [x] `isNotFoundError` moved to `utils.bal`, with `statusCodeOf` alongside it. **The typed
      status path now actually works** — with our own client a 4xx really is an
      `http:ClientRequestError`; under the connector it never was (see note below).

### Now-unblocked implementation fixes
- [x] **Impl #1 (N+1)** — `listChildren` requests `LIST_FIELDS` (the full per-file projection),
      so `listFolder` no longer issues a `files.get` per child. A 5,000-file folder goes from
      ~10,005 requests to ~5,005.
- [x] **Impl #2 (retry)** — `DEFAULT_RETRY_CONFIG`: 4 attempts, 1s interval, ×2 backoff, capped
      at 20s, over `[403, 429, 500, 502, 503, 504]`. 403 is included because Drive reports
      throttling as 403 `rateLimitExceeded` and `http:RetryConfig` cannot match on `reason`;
      the trade-off is that a genuine permissions 403 is retried before failing.
- [x] **Impl #3 (size limits)** — `maxFileSizeBytes` (default 100 MiB) is checked against the
      listing's `size` *before* download, skip-with-warning; `DEFAULT_RESPONSE_LIMITS` bounds
      `maxEntityBodySize` as the backstop for content with no reported size.
- [x] **Impl #6** — `webViewLink` requested and stored as `metadata["webUrl"]`.
- [x] **Impl #5** — `acknowledgeAbuse` is now configurable and sent on download.
- [x] **Logic #9 (partial)** — `incompleteSearch` is now surfaced as a warning, and pagination
      is an explicit `pageToken` loop rather than relying on `array.toStream()` laziness.
- [x] `childrenQuery` escapes `'` per Drive's `q` syntax.

> **Note for Phase 1 review:** the typed-`http:ClientRequestError` branch added in Phase 1 was
> *inert* while the connector was in use — `getDriveError` built a fresh `error(json.toString())`
> with no cause and no status code, so only the message fallback ever fired. It is live now.

---

## Phase 3 — 🔴 B3: Test the traversal logic ✅ DONE

**Coverage: `drive_data_loader.bal` 18.55% → 96.15%** (5 missed lines, was 101). Module 61.71% →
**92.25%**; `utils.bal` 100%; `client.bal` 76.92% (the untaken optional-config branches in
`DriveClient.init` — `secureSocket`, `proxy`, `poolConfig`, … — account for most of its 27).

- [x] `tests/mock_service.bal` — a mock Drive v3 service on port 9243 serving the same four
      endpoints the loader calls, over a fixed corpus. No OAuth token endpoint needed: bearer-token
      auth constructs offline.
- [x] Tests point at it via `serviceUrl`. `mockLoader()` also sets `retryConfig.count: 0`, since
      the default backoff would otherwise multiply every deliberately-failing request.

Covered:
- [x] `load()` end to end, both single-document unwrap and array
- [x] Folder listing, `recursive: true`, sub-folder descent
- [x] `includeExtensions` on a real listing, incl. that it excludes Workspace natives and that
      explicitly named files bypass it
- [x] Export-vs-download routing — the mock echoes the requested export target back, so the test
      asserts the *decision* (`[as text/plain]`), not merely that content arrived
- [x] Trashed file and trashed folder
- [x] `loadFolder` given a non-folder ID; missing folder; empty folder
- [x] `loadNamedFile` missing / trashed / unsupported / folder-ID-in-`fileIds`
- [x] `listChildren` failure (mock returns 500)
- [x] Multi-page folder — three pages chained by `nextPageToken`; also `incompleteSearch`
- [x] Oversized-file skip, and that `maxFileSizeBytes` is configurable
- [x] Skip-with-warning vs hard-error split, both directions
- [x] B1 and the HTML rendering re-verified through the real HTTP path

Fixtures:
- [x] `office-legacy.doc` added — generated with macOS `textutil -convert doc`, a genuine OLE2
      Composite Document. POI's HWPF path is now exercised (plus an extension-less variant).
- [x] BOM / non-UTF-8 / HTML tests — done in Phase 1, and HTML again end-to-end here.
- [ ] Coverage gate in CI — deferred to Phase 6 with the other CI work.

> **Two notes for whoever picks this up:**
> 1. `ConnectionConfig.httpVersion` had to default to `HTTP_1_1`, not `HTTP_2_0`. An HTTP/2
>    client speaking cleartext h2c to an HTTP/1.1 listener **hangs** rather than negotiating
>    down, which silently wedges the whole suite. The connector defaulted to 1.1 for the same
>    reason.
> 2. `testUndecodableFileCurrentlyAbortsTheWalk` pins **current** behaviour, not desired
>    behaviour — it asserts that an undecodable file aborts the folder walk. B5 changes that;
>    update this test as part of it so the behaviour change is visible in the diff.

---

## Phase 4 — Remaining behaviour blockers

### 🔴 B5 — Partial failure ✅ DONE
- [x] `listFolder` now logs a warning and continues for **any** per-file failure, not just
      `isTextlessPdfError`. Previously one bad file discarded the whole run — including documents
      already collected — contradicting the documented "one bad PDF never aborts a bulk load".
- [x] Hard errors kept for explicitly named `fileIds` — naming a file expresses intent, so
      failing to load it is worth reporting.
- [x] A per-folder summary warning (`loaded=N skipped=M`) when anything was skipped: a folder
      where everything failed would otherwise be indistinguishable from an empty one.
- [x] A child with no `id` is now warned about rather than silently skipped.
- [x] Impl #4 — Drive's 10 MB export cap is recognised and reported in plain words instead of
      pasting Drive's JSON. Inside a listing it is now a skip.
- [x] Impl #5 — `cannotDownloadAbusiveFile` likewise, and the message names the
      `acknowledgeAbuse` setting that overrides it.
- [ ] ~~`continueOnError` / `onError` hook~~ — not added. Skip-in-listings / error-when-named is
      already the documented contract; a config knob would be a second way to express it.

### B6 — Google Sheets data loss — ⛔ NOT FIXED (deliberate decision)
**Sheets remain exported as `text/csv`, which Google documents as first-sheet-only. Every tab
after the first is still silently dropped.** Owner's decision: keep CSV, do not change the export
format. Recorded here as a known, accepted limitation rather than an open task.
- [x] Decision made — keep `EXPORT_MIME_CSV`.
- [ ] `ballerina/README.md` must state this prominently as data loss, not a footnote (Phase 7).
- [ ] Optional, not done: a per-Sheet warning when exporting, so the loss is at least visible in
      the log. Not added because it was not asked for — worth revisiting.

> **Note:** the `FileClass` enum was left as-is. I had started the Design #6 refactor (splitting
> fetch strategy from text strategy) because XLSX-for-Sheets needs "export then extract", a
> combination the enum cannot express. With B6 declined there is no second case, so the refactor
> would be speculative generality and was reverted.

---

## Phase 5 — 🔴 B2: GraalVM metadata ⚠️ RESOLVED BY DECLARING `false`

**No GraalVM toolchain is available in this environment** (only Homebrew OpenJDK 21 — no
`GRAALVM_HOME`, no `native-image`, no `gu`). Both halves of B2 are therefore impossible here: the
tracing agent cannot be attached, and `bal build --graalvm` cannot verify anything.

Taken the review's stated alternative instead:

- [x] `graalvmCompatible = false` in **both** `ballerina/Ballerina.toml` **and**
      `build-config/resources/Ballerina.toml`. The template matters — `updateTomlFiles`
      regenerates from it at release, so changing only the generated file would silently restore
      `true` on the next release.
- [x] The declaration carries the reason and a numbered procedure for flipping it back.
- [x] `native-image.properties` kept, and now documents that `-H:+AddAllCharsets` became
      **load-bearing** in Phase 1: `TextDecoder` calls `Charset.forName(...)` with whatever Drive
      declares, and a native image ships only a small default charset set.
- [x] Verified the change is inert for the normal build — 144 tests still pass.
- [ ] Generate and commit the real metadata on a machine with GraalVM (see the procedure in
      `Ballerina.toml`), then flip the flag back to `true`.
- [ ] `ballerina/README.md` should note that native-image builds are not yet supported (Phase 7).

> **Deliberately NOT done:** hand-writing `reflect-config.json` etc. by reasoning about POI's
> reflective surface. Unverified metadata would recreate exactly the problem this change removes —
> the appearance of native-image support with runtime failure behind it — while adding ~2,000
> lines nobody can review. Only agent-generated, `--graalvm`-verified metadata is worth committing.

---

## Phase 6 — Build, CI & release config 🟡 quick, independent

- [ ] `.github/workflows/dev-stg-release.yml:22` — remove `additional-publish-flags: '-x test'`.
      This currently publishes to Central with the test gate disabled.
- [ ] `.github/workflows/pull-request.yml` — add the fork-PR guard:
      `additional-test-flags: ${{ github.event.pull_request.head.repo.full_name != github.repository && '-x test' || '' }}`.
      Without it, external contributor PRs fail on missing secrets, not on code.
- [ ] `.github/workflows/ci.yml:5-7` — add the `2201.[0-9]+.x` maintenance-branch trigger.
- [ ] Add `.gitattributes` (`/gradlew text eol=lf`, `*.bat text eol=crlf`) — without it a Windows
      round-trip makes `gradlew` unexecutable on Linux CI.
- [ ] `ballerina/Dependencies.toml:11-13` — regenerate against current `ballerina/ai`
      (locked at `1.11.2`, current is `1.13.0`): `bal build --locking-mode=soft`.
- [x] ~~`build-config/checkstyle/build.gradle:1-16` — non-standard licence header~~ — resolved by
      Phase 0; the directory was deleted, so the only non-WSO2 header in the repo is gone.
- [ ] `native/build.gradle:24-34` — add a comment explaining that `tika-parser-zip-commons` is
      runtime-only, or align the dependency lists.

---

## Phase 7 — Documentation ✅ DONE

Most of `ballerina/README.md` had become factually wrong across Phases 1–5, so it was rewritten
rather than patched. Corrections beyond the original checklist items:

- [x] Removed the claim that the package "builds on `ballerinax/googleapis.drive` and consumes that
      connector's `ConnectionConfig`" — no longer true after Phase 2.
- [x] Deleted the entire **"Reusing an existing client"** section: the `drive:Client` overload no
      longer exists.
- [x] Both examples now compile as written — the old ones imported `ballerinax/googleapis.drive`
      and the second used undeclared `clientId`/`clientSecret`/`refreshToken`.
- [x] Removed the "**one metadata call per loaded file**" limitation — the N+1 is gone (Phase 2).
- [x] Removed the reference to the exported `driveIdFromUrl()` helper — made private in Phase 0.
- [x] "decoded as UTF-8" → the actual BOM → declared-charset → UTF-8 precedence, plus BOM stripping.
- [x] HTML moved to its own "downloaded + rendered" row; it is no longer stored as raw markup.
- [x] Added a **Partial failure** section describing the skip-in-listings vs error-when-named
      split, which is now true for every failure reason rather than only text-less PDFs.
- [x] Added a **Configuration** table (`serviceUrl`, `retryConfig`, `responseLimits`,
      `maxFileSizeBytes`, `acknowledgeAbuse`, `httpVersion`, `timeout`) with the reasoning behind
      the non-obvious defaults.
- [x] Auth section now lists all four grant shapes, including the service account that Phase 2
      made possible. Added the required-scopes note: `drive.readonly` minimum, and
      **`drive.file` is explicitly called out as NOT sufficient**.
- [x] Metadata is now a table, and documents `webUrl` plus the corrected `fileSize` semantics —
      the old text claimed Drive reports it for "binary files and Google Docs", which was wrong in
      both directions.
- [x] Added a shortcuts row to the file-type matrix, and stated that the Drive MIME type is
      authoritative with the extension as fallback.
- [x] **Sheets data loss is now the first limitation, flagged ⚠️, and says plainly that tabs
      2..N are silently discarded** — it was previously one bullet among nine.
- [x] Added the GraalVM-not-supported limitation (Phase 5) and an end-to-end knowledge-base
      hand-off fragment, honestly marked as needing a vector store and embedding provider from
      other packages rather than faked as self-contained.
- [x] Root `README.md` — replaced the 2-line stub with badges, the issues/projects notice, the
      8-step build-from-source, contribute, code of conduct and useful links.
- [x] `changelog.md` — `## [Un-released]` → `## [1.0.0] - 2026-07-30`, with a real entry and a
      known-limitations section.
- [ ] **Correct the PR description** — cannot be done from here. It still claims live integration
      tests gated on `Config.toml`; there are none. Someone must edit it on GitHub.

### Original item list (all covered above)

- [ ] Root `README.md` — replace the 2-line stub: badges, "Issues and projects", the 8-step
      "Build from the source", "Contribute to Ballerina", "Code of conduct".
- [ ] `ballerina/README.md:136` — rewrite the `fileSize` section; it is derived from the
      downloaded byte count and is always unset for exported Workspace files.
- [ ] `ballerina/README.md:62` — the partial-failure guarantee becomes true once B5 lands; verify
      the wording matches the implemented behaviour.
- [ ] `ballerina/README.md:44-55` — add a shortcuts row to the file-type matrix.
- [ ] `ballerina/README.md:76-130` — make both examples self-contained and compilable (the
      "Reusing an existing client" snippet uses undeclared `clientId`/`clientSecret`/`refreshToken`).
- [ ] Add an end-to-end RAG example: load → `ai:Chunker` → `ai:KnowledgeBase`.
- [ ] Document required scopes explicitly — `drive.readonly` minimum; **`drive.file` is not
      sufficient** for arbitrary pre-existing files.
- [ ] Document that service-account / JWT / domain-wide-delegation auth is unavailable.
- [ ] `changelog.md:5-7` — change `## [Un-released]` to `## [1.0.0] - <date>`.
- [ ] **Correct the PR description** — it claims live integration tests gated on `Config.toml`.
      `client_test.bal` contains none. There are zero integration tests.

---

## ❓ Needs verification — ask the team, don't guess

- [ ] `.github/workflows/release.yml:6` — is the dispatch type `connector-release-pipeline` or
      `stdlib-release-pipeline`? **A mismatch means the release never triggers.** Check against
      another recently-created `ballerinax` connector.
- [ ] `.github/workflows/ci.yml:18` — should a brand-new connector set `publish-required: true`
      (snapshot-publishes every push to `main`) before its first release?
- [ ] `gradle.properties:9` — is `io.ballerina.plugin` 3.0.0 what the connector CI templates
      expect for a `java21` connector? (Reference uses 2.3.0.)
- [ ] `init` parameter naming — is `connection` acceptable, or is
      `googleDriveConnectionConfigs` contractual for Ballerina Integrator low-code surfacing?
- [ ] `.github/CODEOWNERS:7` — confirm `@shafreenAnfar @SasinduDilshara` are the intended owners.
- [ ] Were the five Office fixtures authored for this PR, or derived from third-party samples
      needing attribution?

---

## 🟦 Deferred — discuss scope before doing

My read: these are features or speculative generality rather than defects. Worth a tracking issue,
not worth blocking 1.0. Push back on them in the PR thread rather than silently implementing.

- [ ] **Follow Drive shortcuts** (Logic #5) — a feature, not a bug. Real gap (a folder of
      shortcuts loads zero documents), but it is new capability. Needs `shortcutDetails` in the
      field mask and loop guarding.
- [ ] **Visited-ID set + `maxDepth`** (Logic #8) — Drive has been single-parent since 2020, so a
      folder cycle is not constructible today. **Only becomes real if shortcut-following lands.**
      Do it with that, not before.
- [ ] **Concurrency / batching** (Design #7) — real complexity, no measurement behind it.
      Defer until Impl #1 (N+1 removal) is in and you can measure what is actually slow.
- [ ] **`FileClass` enum → record refactor** (Design #6) — speculative generality for two export
      types. Revisit when a third arrives.
- [ ] **`Source` model redesign** (Design #4) — `string[] folders` + per-source options. Better
      shape, but it is API churn; decide before 1.0 ships or live with it.
- [ ] **Markdown export for Google Docs** (Impl #7) — genuinely better for `ai:MarkdownChunker`.
      Feature, though. Fold into B6's "configurable export MIME type" work if you do that.
- [ ] **`idAfter` first-occurrence** (Logic #16) — the review itself calls it low-probability, and
      real Drive URLs do not produce the shape. Skip unless the parser goes public.

---

## Progress

| Phase | Scope | Status |
|---|---|---|
| 0 — Subtractive cleanup | 16 items, no behaviour change | ✅ done — 64 tests pass, gradle configures |
| 1 — Correctness bugs (incl. **B1**) | 12 items | ✅ done — 96 tests pass |
| 2 — **B4** connection config | 12 items, unblocks 3 & 5 | ↩️ **REVERTED by owner** — connector kept, limitations accepted |
| 3 — **B3** tests | 14 items | ↩️ **mostly reverted** — the mock-service suite required `serviceUrl`, which the connector does not expose |
| 4 — **B5** done, **B6** declined | 7 items | ⚠️ B5 ✅ kept; B6 not fixed by choice |
| 5 — **B2** GraalVM | 4 items | ⚠️ declared false — no GraalVM toolchain here |
| 6 — Build/CI | 7 items | ⏭️ skipped by owner (.github untouched) |
| 7 — Docs | 10 items | ✅ done — README rewritten, changelog cut |
| ❓ Verification | 6 questions | ☐ |
| 🟦 Deferred | 7 items — decide, don't default to doing | ☐ |


---

## ↩️ Reversal — B4 declined, the connector is kept

The owner elected to keep `ballerinax/googleapis.drive` rather than own the transport, accepting
the connector's limitations. Phase 2 was therefore reverted, and Phase 3 with it: the 74-test
mock-service suite depended on `ConnectionConfig.serviceUrl`, and the connector hardcodes its API
root as a module-private constant, so there is no way to point it at a test server.

**Current state: 111 tests pass. Module coverage 59.38%; `drive_data_loader.bal` 20.22%.**
(At the end of Phase 4 it was 144 tests, 93.22% module, 94.24% loader.)

### Kept from Phases 0/1/4/5/7 — none of these depended on owning the transport

- **B1** parser selection by MIME type, plus the `TextDecoder` BOM/charset/HTML work and the
  structured `TEXTLESS_PDF` error reason.
- **B5** every per-file failure inside a listing is skipped with a warning; the per-folder
  skip summary; named files still error.
- Fail-fast source validation in `init` (`ResolvedSource`), the folder-ID-in-`fileIds` and
  trashed-folder diagnostics, and `childrenQuery` quote escaping.
- `isNotFoundError` no longer matches a bare `"404"` substring.
- `retryConfig` / `responseLimits` defaults, applied to a **clone** of the caller's config — the
  connector leaves both unset, which would mean no retry over Drive's 403/429 throttling.
- `webViewLink` in the field mask, so the `webUrl` citation link survives.
- The `drive:Client` overload for reusing a caller's existing client.
- **B2** `graalvmCompatible = false`, and the docs.

### Lost, and now documented as limitations

| Lost | Why |
|---|---|
| End-to-end tests of traversal / routing / partial failure | No `serviceUrl` → no mock service |
| Size ceiling before download (`maxFileSizeBytes`) | `File.size` typed `int` vs Drive's JSON string |
| Single-request listings | `getAllFiles` takes no field mask → N+1 `files.get` restored |
| `incompleteSearch` warning | Dropped by the connector's listing stream |
| `acknowledgeAbuse` | Not exposed by the connector |
| Service-account (JWT bearer) auth | Connector `auth` admits only bearer / refresh-token |
| Status codes and error causes | `getDriveError` rebuilds every failure as `error(<body>)` |

The 10 MB export cap and the abusive-file refusal are still *named* rather than surfaced as raw
Drive JSON — `describeContentFailure` matches Drive's reason string in the connector's message.

### Consequence for the review

**B4 is now a declined finding, not a fixed one, and B3 is only partly addressed.** Both should be
answered in the PR discussion rather than left looking resolved. The reviewer's stated reason for
B4 was precisely that the connector blocks testing — that trade-off is now explicit in
`ballerina/README.md` (an "Inherited from the `googleapis.drive` connector" section plus a
test-coverage note) and in `changelog.md`.
