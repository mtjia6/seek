<h1 align="center">Seek</h1>

<p align="center">
  <b>The file search Finder should have.</b><br/>
  Names, contents, text inside screenshots, and meaning — in about a millisecond, entirely on your Mac.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=for-the-badge&logo=apple" />
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=for-the-badge&logo=swift&logoColor=white" />
  <img alt="Runs locally" src="https://img.shields.io/badge/runs-100%25%20local-2E7D32?style=for-the-badge" />
</p>

<p align="center">
  Press <kbd>⌥ Space</kbd>, type, press <kbd>↩</kbd>.
</p>

---

## Find it the way you remember it

You remember a file by *something*: its exact name, a phrase inside it, what was on the screenshot, or just what it was about. Seek searches all four at once and merges them into one ranked list.

| You type | Seek finds |
|---|---|
| `Physics Distinction Award` | the file with exactly that name — always first |
| `cs2200` | `CS-2200/`, `CS 2200 Textbook.pdf` (separators and case don't matter) |
| `lease agreement` | the PDFs that *say* "lease agreement", with the line highlighted |
| `page table base register` | the screenshot of your lecture slide that shows those words |
| `how virtual memory translation works` | `L07 Memory management.pptx` — no shared keywords needed |

## Why not Finder?

Finder's search box is a front end to Spotlight's index. When that index is stale, incomplete, or excludes a folder, typing the **exact** file name still returns nothing. Seek keeps its own index, built from the real filesystem and kept current with FSEvents, so if a file exists, it is found.

| | Seek | Finder / Spotlight |
|---|---|---|
| Exact name always ranked first | ✅ | ❌ mixed with content hits |
| Independent of Spotlight's index health | ✅ | ❌ |
| Typo- and separator-tolerant (`cs2200` → `CS-2200`) | ✅ | ❌ word prefixes only |
| Unicode-normalized names (NFD, U+202F in screenshot names) | ✅ | partial |
| Full text in code, PDF, DOCX, PPTX, XLSX | ✅ | ✅ |
| Text inside screenshots and photos (OCR) | ✅ | partial (Live Text, not reliably indexed) |
| Find by meaning, no shared words | ✅ | ❌ |
| Boosts the folder open in your front Finder window | ✅ | ❌ |
| Learns from what you open | ✅ | partial |

## Features

- **Instant name search.** Every file name under your home folder, `/Applications`, iCloud Drive and `~/Library/CloudStorage` lives in memory and is scanned on all cores per keystroke.
- **Tiered ranking.** Exact name → starts with → word match → substring → all words → fuzzy. Frecency and recency reorder results *within* a tier, never across it, so a popular file can't bury your exact match.
- **Full-text search.** SQLite FTS5 with BM25 ranking; the last word matches as a prefix, so results arrive while you type.
- **OCR.** Screenshots, photos and scans are read once with Apple Vision.
- **Semantic search.** Every document gets a 256-d vector from [potion-base-8M](https://huggingface.co/minishlab/potion-base-8M), a Model2Vec static embedding model, scanned exactly with Accelerate.
- **Hybrid fusion.** The three retrievers run concurrently and merge with Reciprocal Rank Fusion; weights adapt to whether the query looks like a filename, a word, or a question.
- **Live index.** Creates, edits, renames, folder moves and deletes are reflected within ~1 s (names) to ~2 s (contents).
- **Snippets and match badges.** Each result shows the matching line and *why* it matched: content, text in image, or meaning.
- **Folder filter.** `dev/notchmusic` limits results to paths containing `dev`.

### Keys

| Key | Action |
|---|---|
| <kbd>⌥ Space</kbd> | Show / hide Seek (falls back to <kbd>⌃⌥ Space</kbd> if taken) |
| <kbd>↑</kbd> <kbd>↓</kbd> | Move selection |
| <kbd>↩</kbd> | Open |
| <kbd>⌘ ↩</kbd> | Reveal in Finder |
| <kbd>⌥ ↩</kbd> | Copy path |
| <kbd>Esc</kbd> | Close |

## How it works

```
                    ┌──────────── indexing (background, continuous) ────────────┐
 filesystem ──walk──► name index (memory)                                        │
     │              │                                                            │
     └──FSEvents────► content indexer ──extract──► SQLite FTS5 (BM25)            │
                    │                  └─embed───► vectors (SQLite + memory)     │
                    └────────────────────────────────────────────────────────────┘
                    ┌──────────── search (per keystroke, ~1–8 ms) ──────────────┐
 query ──┬─► name matcher ──┐                                                    │
         ├─► FTS5 BM25 ─────┼─► Reciprocal Rank Fusion ─► pin exact names ─► UI  │
         └─► vector scan ───┘                                                    │
                    └────────────────────────────────────────────────────────────┘
```

Nothing reads your files at search time; every keystroke queries structures built ahead of time.

| Component | File | Notes |
|---|---|---|
| Name index + FSEvents | `FileIndex.swift` | parallel `readdir` walk with a shared work stack; packages (`.app`, `.framework`) indexed as one item |
| Name matching | `Matcher.swift` | byte-level normalization (case, diacritics, NFD, whitespace variants, `_`/`-`) |
| Extraction | `Extractor.swift` | text/code, PDFKit, `NSAttributedString` (doc/docx/rtf/odt), unzip+XML (pptx/xlsx), Vision OCR |
| Content store | `ContentStore.swift` | FTS5, WAL mode, separate reader/writer connections |
| Incremental sync | `ContentIndexer.swift` | files remembered by (mtime, size); FSEvents changes coalesced over 1 s |
| Embeddings | `StaticEmbedding.swift`, `Semantic.swift` | WordPiece tokenizer + table lookup + mean, in pure Swift; no ML runtime |
| Fusion + ranking | `Search.swift` | RRF (k = 60) with query-shape routing |

### Why potion-base-8M

Measured on 5 natural-language queries over 3.8k of the author's own documents (MRR, higher is better):

| Model | MRR | Embed cost |
|---|---|---|
| Apple `NLEmbedding` (sentence) | 0.014 | 28 ms / doc |
| Apple `NLContextualEmbedding` + mean-centering | 0.224 | 16 ms / doc |
| **potion-base-8M, name + first 100 words** | **0.557** | **0.7 ms / doc** |
| potion-base-8M, 200-word windows, best window | 0.161 | 0.5 ms / window |

Model2Vec distills a sentence transformer (bge-base-en-v1.5) into a single token→vector table, so inference is a lookup and an average, but the vectors keep the teacher's retrieval training. Many windows per file *lost*: each extra window is another chance at a spuriously high cosine, so long noisy files float up.

## Install

Seek is built from source.

**Requirements:** macOS 14+, Xcode command-line tools (Swift 6), ~40 MB disk for the model.

```sh
git clone https://github.com/mtjia6/seek.git
cd seek
./build.sh
```

`build.sh` downloads the embedding model on first run (MIT, 30 MB, not stored in git), builds a release binary, bundles and signs `Seek.app`, installs it to `~/Applications`, and launches it. macOS will ask once for access to Desktop, Documents and Downloads — Seek can only index what you allow.

To start Seek at login: **System Settings → General → Login Items → +** → `~/Applications/Seek.app`.

### Command-line modes

Useful for benchmarking and testing; each builds its own index and exits.

```sh
.build/release/Seek --query "exact name" "cs2200"          # name search
.build/release/Seek --content "lease agreement" --hybrid    # full pipeline
.build/release/Seek --content "virtual memory" --semantic   # meaning only
.build/release/Seek --watch-test                            # live-update self-test
```

## Performance

Apple M4 Pro, 14 cores, macOS 27, release build, the author's home folder (19k items, 4.5k with extractable content). Query times are best of 5.

| What | Result |
|---|---|
| Full name walk, cold | **0.15 s** for 19,173 items |
| Name search | **0.2–1.5 ms** |
| Full-text search incl. snippets | **0.5–3 ms** |
| Semantic search (embed query + scan all vectors) | **0.1–0.2 ms** |
| Hybrid search, end to end | **1–8 ms** |
| First content index, text/PDF/Office (3.5k docs) | 17 s, background |
| First OCR pass (1,050 images) | ~2 min, background, ~0.12 s / image |
| Embedding every document | ~1 s |
| Re-sync on launch with nothing changed | **0.1–0.6 s** |

## Privacy

- Everything runs on your Mac. No network access after `build.sh` downloads the model.
- The index lives in `~/Library/Application Support/Seek/`; delete that folder to wipe it.
- Never entered: hidden folders (`.ssh`, `.git`, …), `~/Library` (except cloud folders), `node_modules`, `site-packages`.
- Names only, contents never read: virtualenvs, Go module cache, `build/`, `dist/`, `target/`, `vendor/`.
- The only Apple Event Seek sends is asking Finder for its front window's folder, to boost results there.

## Status

Working and in daily use on one machine. Known gaps:

- English-only semantic search (the model is English).
- External drives under `/Volumes` aren't indexed yet.
- Very long or noisy queries can surface weak full-text matches (e.g. CSS files containing common words).

## What might come next

- Query filters: `kind:pdf`, `in:Downloads`, `modified:last week`.
- External volumes.
- int8-quantized vectors and multilingual embeddings.
- A launchd agent with `KeepAlive` so indexing survives crashes.

## Credits

- Hybrid retrieval design and query-shape routing inspired by [Kensaku](https://github.com/yjid/kensaku).
- Semantic search uses [potion-base-8M](https://huggingface.co/minishlab/potion-base-8M) by [Minish Lab](https://github.com/MinishLab/model2vec) (MIT).
