# AIQL — ask your data

**AIQL** is a small Mac app for someone who lives in a marketing or analytics tool, not a
terminal. You give it three things — a local model, an **MCP data source**, and a plain-English
request — and press **Go**. It pulls the dataset, turns it into the spreadsheet you asked for,
and drops a `.csv` into a folder you chose.

The data is read by a model running **on your Mac** — nothing is sent to an online AI provider.
And the model never touches the rows: it writes one **SQL query**, the host runs it read-only,
and only the answer's shape (column names, row count) comes back. So the model can't miscopy or
invent a single value.

This is the SwiftUI counterpart to the pipeline in
[`docs/sdk-guide.md` §8b](../../docs/sdk-guide.md).

## What Go does

1. **Connect** to the MCP server. A public server connects straight away; an OAuth server opens a
   browser sign-in and comes back on its own (`aiql://oauth/callback`).
2. **Download the model** if it isn't cached yet (first run only — progress bar).
3. **Run the pipeline** in the folder you chose:

   ```
   the data tool  → raw/data.json   (FileBackedTool `saveAs` — the raw payload never enters the model's context)
   loadTable        raw/data.json    → an ephemeral SQLite table; returns its CREATE TABLE
   sqlQuery       → out.csv          (one read-only SELECT; the host runs it, the rows never reach the model)
   ```

The progress panel shows each step in plain language ("Reading the data…", "Building the
spreadsheet…"). When it's done, the CSV preview appears with a **Show in Finder** button.

## What the model actually does

The pipeline is a fixed program in Swift. The model fills in the blanks — it never runs a loop,
evaluates a condition, or handles a value.

**Hardcoded in `AIQLApp.swift` / the Core tools** — the same every run:

- the step order (pull → `loadTable` → `sqlQuery` → `csvInfo`) and the file name at each stage
- `loadTable`: finding the records array, flattening records to typed columns, splitting a
  nested array into a child table, the bulk insert — all Swift
- `sqlQuery`: the SELECT runs against a connection opened **read-only**, behind a
  `sqlite3_set_authorizer` allowlist (SELECT/READ/FUNCTION only — no writes, no `ATTACH`), one
  statement, a timeout, a row cap. Only a receipt (columns, row count, first rows) returns
- which tools the model even sees: the server's tools are ranked by how "dataset-like" the name
  looks and only the top few are wrapped; the raw-file reader is withheld
- the raw payload's path — `FileBackedTool`'s `saveAs` parks it in `raw/data.json`; it never
  enters the model's context

**The model decides** — a data-tool pick, a table name, then one `SELECT`:

1. which data tool answers the question (and whether to paginate; a second dataset → a second
   `loadTable`)
2. a short name for each table
3. **the SQL** — one `SELECT` against the `CREATE TABLE`(s) `loadTable` printed. Matching the
   request's wording to the real column names is the one genuinely semantic step; `WHERE` /
   `BETWEEN` / `ORDER BY … LIMIT` / `JOIN` / `GROUP BY` are mechanical SQLite

So the intelligence budget is small and bounded: request→schema matching, and writing one
standard `SELECT`. Everything downstream is deterministic. The model describes the query once; it
never orchestrates a multi-step sequence, so it can't drop a step — the failure mode that made a
range filter silently vanish when it was step 4 of a 6-call chain. A wrong column name comes
back as a SQLite `Error:` (with the real columns appended) that it fixes and retries, not a
wrong number. Verified end to end with `mlx-community/Qwen3-8B-4bit` and `Qwen3-14B-4bit`
(the SDK's `examples/aiql-eval` harness).

## What it highlights for SDK developers

Three existing examples stitched together, plus the SQL tools:

| from | what it contributes |
|---|---|
| [`workspace-buddy-local`](../workspace-buddy-local) | SwiftUI + App Sandbox + `MLXModelProvider` download + `NSOpenPanel` folder picker + security-scoped bookmark |
| [`plate-today`](../plate-today) | `MCPServerManager` + the OAuth redirect wired through `AppDelegate` (not SwiftUI's `.onOpenURL`) + `CFBundleURLTypes` |
| [`repo-qa`](../repo-qa) | building tools from a live MCP schema — here `FileBackedTool.mcp(descriptor:manager:root:)` |
| SDK §8b | `loadTable` + `sqlQuery` — JSON records → an ephemeral SQLite table → one read-only `SELECT` → CSV. `describeJson` / `csvInfo` for discovery/verification |

Other things worth a look in `Sources/AIQL/AIQLApp.swift`:

- **`session.events`** — the pipeline's progress panel is driven by the session's tool-call
  side-channel (`SessionEvent.toolCallStarted` / `.toolCallFinished`), mapped to friendly labels.
- **Tool curation for a small model** — the server's tools are ranked by how "dataset-like" the
  name looks and only the top few are wrapped; `readWorkspaceFile` is deliberately not offered
  (the raw dump is far past the context window, so the model only ever sees the bounded
  `describeJson` / `csvInfo` views).

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session.

**1. Install Xcode 27.** Get it from the Mac App Store or
[developer.apple.com/xcode](https://developer.apple.com/xcode/).
`Package.swift` requires `platforms: [.macOS("27.0")]`, so an older Xcode fails with `'v27' is unavailable`.

**2. Point `swift` at Xcode 27** for the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Leaves your system default alone; lasts only for the current terminal (re-run it in each new one,
or add it to your `~/.zshrc`). `Package.swift` builds against SDK `1.0.0-beta.4` with no further
setup — it links **two** binaries, `LocalLMLabSDKCore.xcframework` and
`LocalLMLabSDKInference.xcframework` (the MLX runtime), from that one GitHub Release.
`export LOCALLM_SDK_VERSION=<version>` to pin a different published release. **No Metal Toolchain
needed** — the prebuilt Inference xcframework bundles the compiled `default.metallib`; you only
need it if you build the SDK from source.

**3. Compile-check:**

```bash
swift build
```

This just proves it builds. To *actually run* it: open the Xcode project (next), or make a
signed `.app` with `packaging/build-and-sign.sh` (further below).

## Open in Xcode and Run

A committed `AIQL.xcodeproj` is the lowest-friction way to try it. **Open it in Xcode 27 or newer** (the target is macOS 27):

```bash
open -a Xcode AIQL.xcodeproj
```

Pick the **AIQL** scheme and Run — a real sandboxed `.app` with the
`files.user-selected.read-write` and `network.client` entitlements (the model download and the
MCP connection both need the latter), the `aiql://` URL scheme registered for the OAuth callback,
and the `LocalLMLabSDKInference` (MLX) framework embedded. **First Go downloads the model**
(~8 GB for the default); after that it's local and offline.

**Signing.** Set to **Automatic** with no hard-coded team, so Xcode signs with your **Apple
Development** identity — the security-scoped bookmark for the output folder is bound to the
signing identity and won't survive a rebuild under an ad-hoc one.

| Your Xcode setup | What happens on Run |
|---|---|
| One Apple ID in **Xcode ▸ Settings ▸ Accounts** (**free** is enough) | picked automatically — stable `Apple Development` signing, bookmark persists across rebuilds |
| No Apple ID | Run stops with *"requires a development team"* — add a free Apple ID, **or** target ▸ **Signing & Capabilities** ▸ **Sign to Run Locally** (ad-hoc; runs, but you re-pick the folder each rebuild) |

Only the Xcode Run build is affected. `packaging/build-and-sign.sh` (below) ignores the project
file and signs with whatever `APP_IDENTITY` you pass it.

Generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit `project.yml`, not the `.xcodeproj`,
then `xcodegen generate`.

## Running it — the distributable build

A bare `swift build` is compile-only (no sandbox, no entitlements, no URL scheme).
`packaging/build-and-sign.sh` makes a `.app` you can hand to another Mac (Developer-ID signed and
notarizable). A **free "Apple Development"** identity is enough for a local run; a Developer ID
for distribution.

```bash
APP_IDENTITY="Apple Development: Your Name (TEAMID)" NOTARIZE_APP=0 \
  ./packaging/build-and-sign.sh          # → dist/AIQL.app
open dist/AIQL.app
```

(`DEVELOPER_DIR` and `LOCALLM_SDK_VERSION` come from step 2.) The model download lands in the
app's sandbox container at
`~/Library/Containers/lab.locallm.sdk.reference.aiql/Data/Library/Caches/huggingface/` (not
`~/.cache`) — swift-huggingface redirects it automatically for a sandboxed app.

## Try it

The **Anthropic Economic Index** publishes a public, no-auth MCP server — a good first data
source because every one of its tools returns a clean table of records:

- **MCP data source:** `https://econ-index.mcp.claude.com/mcp`

### Reproduce the demo — step by step

1. **Open AIQL** (Xcode ▸ Run, or `dist/AIQL.app`).
2. **Model:** leave it at the default `mlx-community/Qwen3-14B-4bit`. First Go downloads it
   (~8 GB, one time); needs a 16 GB Mac. On an 8 GB Mac type `mlx-community/Qwen3-8B-4bit`.
3. **MCP data source:** paste `https://econ-index.mcp.claude.com/mcp` and let it connect
   (public server — no sign-in).
4. **Output folder:** click **Choose…** and pick any writable folder. `out.csv` lands there.
5. **Request — prompt 1 (a plain ranking):**

   ```
   The 10 US states with the highest Claude usage index, and each one's automation percentage.
   ```

   Press **Go**. The progress panel shows *Connecting → Reading the data… → Building the
   spreadsheet…*. Three tool calls happen: the data pull (`→ raw/data.json`, ~56 KB, never
   enters the model's context), `loadTable` (`51 rows into 'states'`, plus child tables for the
   nested arrays), and one `sqlQuery` (`10 rows, 3 columns → out.csv`). `out.csv`:

   ```
   name,anthropic_usage_index,automation_pct
   "Washington, D.C.",...
   California,...
   New York,...
   Washington,...
   Massachusetts,...
   Colorado,...
   Utah,...
   Hawaii,...
   Nevada,...
   Oregon,...
   ```

   The underlying query is `SELECT name, anthropic_usage_index, automation_pct FROM states
   ORDER BY anthropic_usage_index DESC LIMIT 10`.

6. **Request — prompt 2 (the same, plus a range filter):**

   ```
   US states whose automation percentage is between 45 and 50, highest usage index first —
   state name and automation percentage.
   ```

   Press **Go** again (same folder — `out.csv` is overwritten). Now the query gains a `WHERE`:
   `SELECT name, automation_pct FROM states WHERE automation_pct BETWEEN 45 AND 50 ORDER BY
   anthropic_usage_index DESC`. `out.csv` — 20 rows:

   ```
   name,automation_pct
   "Washington, D.C.",45.52
   California,48.0
   New York,46.9
   Washington,48.08
   Massachusetts,46.7
   Oregon,49.12
   Maryland,48.08
   Virginia,49.37
   Connecticut,48.59
   New Jersey,48.97
   Illinois,48.58
   Rhode Island,48.85
   Minnesota,49.54
   Pennsylvania,48.8
   Maine,49.81
   Wisconsin,49.69
   Alaska,49.83
   Wyoming,48.94
   North Dakota,48.49
   West Virginia,49.9
   ```

   Colorado, Utah, Nevada and Hawaii — in prompt 1's top 10 — are gone: their automation is
   above 50. The filter is applied by SQLite against the copied rows, not by the model, so it
   can't be silently dropped or half-applied.

Both results are byte-for-byte reproducible — same fixture rows, deterministic SQL — and match
the SDK's `examples/aiql-eval` cases **E1** and **E2**.

### More prompts to try

| Request | `out.csv` |
|---|---|
| `every country and its usage index, highest first, top 10` | `name, anthropic_usage_index` — Australia 6.4, Singapore 5.81, … |
| `for each US state, its number-one job category` | `name, top_job_category` (from the `states__top_job_categories` child table) |
| `all job categories ranked by their share of global Claude usage` | `name, pct` |
| `States where coursework use is above 12 percent — state and that percentage, highest first` | `name, use_case_coursework_pct` — 5 rows |

The model picks the data tool, `loadTable`s it, then writes one `SELECT` against the printed
`CREATE TABLE`. Rows are copied from the source by the host — exact against the published index.
The app wraps this pipeline in a UI; its progress panel is fed by `session.events`.

**Writing your own.** Name a dataset ("every country", "US states", "work tasks", "job
categories"), the columns you want, and any refinements: "top N" / "highest … first", "between A
and B", "only rows containing …", "for each X, the …". The model turns it into one read-only
`SELECT`; the host runs it, so `out.csv` can't contain a value the source didn't have.

## Model choice

`mlx-community/Qwen3-14B-4bit` (the default, ~8 GB) needs a 16 GB Mac to clear the
size-vs-memory preflight (weights ≤ 70% of physical RAM).

`mlx-community/Qwen3-8B-4bit` (~4.3 GB) runs the pipeline cleanly — the SDK's eval harness
(`examples/aiql-eval`) is 9/9 on it (and on 14B) across single-table filters, ranges, a
child-table join, a two-dataset `JOIN`, and `GROUP BY … HAVING`. A bigger model mainly buys a
touch more reliability on request→column matching. A 4B model usually works.

Any MLX-format Hugging Face repo id works in the field. Avoid `mlx-community/gemma-3-12b-it-4bit`
and its `qat` sibling — their shipped `model.safetensors.index.json` disagrees with the actual
weight files, so the load fails (and the bad size in it trips the preflight).

The model field and the download progress panel here are hand-built (the panel is fed by
`session.events`). For a settings-screen version of the same thing — a model list with
availability badges, on-disk sizes, and an "Add from Hugging Face" field — use `Components`'
`ModelPickerView`; see
[`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer).

## More

- [`docs/sdk-guide.md` §8b](../../docs/sdk-guide.md) — `loadTable` + `sqlQuery` and the "AIQL"
  data verbs, in prose. §6a — the model layer. §8 — App Sandbox + the folder picker.
- [`workspace-buddy-local`](../workspace-buddy-local) — the sandbox + MLX + folder-picker base
  this builds on.
- [`plate-today`](../plate-today) — the MCP + OAuth-redirect base.
