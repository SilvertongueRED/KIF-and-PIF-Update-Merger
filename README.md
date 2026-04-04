# KIF ← PIF Update Merger

Automatically integrates Pokemon Infinite Fusion's (PIF) latest updates into KIF (Kuray's Infinite Fusion) via an automated three-way merge, while protecting KIF-specific changes (especially the shiny revamp system).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Setup — the three folders](#setup--the-three-folders)
3. [Configure the merger](#configure-the-merger)
4. [Running the merger](#running-the-merger)
5. [Reading the merge report](#reading-the-merge-report)
6. [Resolving conflicts manually](#resolving-conflicts-manually)
7. [How it works](#how-it-works)
8. [File structure](#file-structure)

---

## Prerequisites

- **Ruby 2.7+** installed on your system.
  - Windows: download from <https://rubyinstaller.org/>
  - macOS/Linux: use your system package manager (`brew install ruby`, `sudo apt install ruby`)
- No additional gems required — the script uses only Ruby's standard library.

Verify with:
```
ruby --version
```

---

## Setup — the three folders

You need three local folders before running the merger:

| Folder | Contents | How to get it |
|--------|----------|---------------|
| `PIF_Base_645` | PIF **6.4.5** — the common ancestor KIF was built on | Download the 6.4.5 release from the PIF GitHub releases page |
| `PIF_New_672`  | PIF **6.7.2** — the latest PIF release | Download from the PIF official site (not GitHub — 6.7.2 is a separate release) |
| `KIF_Current`  | Your current **KIF** build | Download the latest KIF release from the KIF GitHub page |

Extract each into its own folder alongside this repository. The default config expects them in the same directory as `merger.rb`:

```
KIF-and-PIF-Update-Merger/
├── merger.rb
├── PIF_Base_645/        ← extract PIF 6.4.5 here
│   ├── PBS/
│   ├── Scripts/
│   ├── Data/
│   └── ...
├── PIF_New_672/         ← extract PIF 6.7.2 here
│   ├── PBS/
│   └── ...
├── KIF_Current/         ← extract your current KIF here
│   ├── PBS/
│   └── ...
└── Merged_Output/       ← created automatically by the merger
```

---

## Configure the merger

Open `config/merge_config.yml` in a text editor:

```yaml
paths:
  pif_base:    "./PIF_Base_645"   # path to PIF 6.4.5
  pif_new:     "./PIF_New_672"    # path to PIF 6.7.2
  kif_current: "./KIF_Current"    # path to current KIF
  output:      "./Merged_Output"  # where output goes

exclusions:
  # Patterns here are ALWAYS kept from KIF — PIF changes are ignored for them.
  # This protects KIF's shiny revamp (v0.20.1) and any other KIF-specific work.
  - "**/shiny*"
  - "**/Shiny*"
  - "**/PokemonShiny*"
  # Add your own patterns:
  # - "**/MyCustomFile*"
```

### Adding exclusion patterns

If there are other KIF-specific files you want to protect from PIF updates, add their patterns to the `exclusions` list. Patterns support standard glob syntax:

- `*` — matches any characters within a single path segment
- `**` — matches any number of path segments
- `?` — matches a single character

Examples:
```yaml
exclusions:
  - "**/shiny*"                    # any file with "shiny" in its name
  - "Scripts/PokemonShinySystems*" # a specific script file
  - "Graphics/Pokemon/shiny/**"    # an entire subdirectory
```

---

## Running the merger

From a terminal in the `KIF-and-PIF-Update-Merger` directory:

```bash
ruby merger.rb
```

### Options

| Flag | Description |
|------|-------------|
| `--config PATH` | Use an alternative config file (default: `config/merge_config.yml`) |
| `--dry-run` / `-n` | Simulate the merge without writing any files |
| `--verbose` / `-v` | Print every file processed (not just changes) |
| `--help` / `-h` | Show usage information |

Examples:
```bash
# Preview what would happen without writing files
ruby merger.rb --dry-run

# Use a custom config
ruby merger.rb --config /path/to/my_config.yml

# Verbose output
ruby merger.rb --verbose
```

---

## Reading the merge report

After the merge, open `Merged_Output/merge_report.txt`. It contains:

### Summary section
```
SUMMARY
-------
  Total files processed : 1247
  Copied from PIF       : 83
  Kept from KIF         : 12
  Protected/excluded    : 47
  Auto-merged (clean)   : 5
  CONFLICTS             : 2
  Unchanged             : 1098
  Deleted/omitted       : 0
```

### Detailed sections

| Section | Meaning |
|---------|---------|
| **FILES COPIED FROM PIF** | Only PIF changed this file — PIF's version was used |
| **FILES KEPT FROM KIF** | Only KIF changed this file — KIF's version was kept |
| **FILES EXCLUDED / PROTECTED** | File matched an exclusion pattern — KIF version always kept |
| **FILES AUTO-MERGED** | Both sides changed — successfully merged with no conflicts |
| **FILES WITH CONFLICTS** | Both sides changed and the merger couldn't auto-resolve |
| **UNCHANGED FILES** | Identical in all three versions |
| **FILES OMITTED** | Deleted by PIF and unchanged in KIF — not included in output |

---

## Resolving conflicts manually

### Text file conflicts

Open the conflicted file in any text editor. Conflicts look like:

```
<<<<<<< KIF
  # KIF's version of this section
  some_kif_specific_code()
=======
  # PIF's version of this section
  some_pif_updated_code()
>>>>>>> PIF
```

1. Decide which version to keep (or combine both)
2. Delete the conflict markers (`<<<<<<< KIF`, `=======`, `>>>>>>> PIF`)
3. Save the file

### Binary file conflicts (rxdata, images, audio)

For binary files that both sides changed, the merger creates two copies:

```
Merged_Output/Data/CommonEvents_KIF.rxdata
Merged_Output/Data/CommonEvents_PIF.rxdata
```

1. Open both files in RPG Maker XP and compare them
2. Decide which version to use
3. Rename the chosen file to the original name (e.g., `CommonEvents.rxdata`)
4. Delete the other copy

---

## How it works

The merger performs a **three-way merge** using PIF 6.4.5 as the common ancestor:

```
PIF 6.4.5 (base)
    ├── → PIF 6.7.2 (theirs)   "what PIF changed"
    └── → KIF current  (ours)   "what KIF changed"
```

For each file:

1. **Exclusion check** — if the file matches an exclusion pattern, KIF's version is always kept.
2. **Change detection** — SHA-256 hashes detect whether each side changed the file.
3. **Decision logic**:
   - Only PIF changed → copy PIF version
   - Only KIF changed → keep KIF version
   - Neither changed → keep KIF version (unchanged)
   - Both changed → attempt three-way merge

4. **Text merge** — uses a line-level LCS diff algorithm with conflict markers.
5. **PBS merge** — uses section-level merging (`[SECTIONNAME]` headers) for better results with Pokémon data files.
6. **Binary files** — cannot be merged; conflicting versions are copied with `_KIF` / `_PIF` suffixes.

---

## File structure

```
KIF-and-PIF-Update-Merger/
├── merger.rb                 ← Main entry point (run this)
├── lib/
│   ├── config.rb             ← Configuration loading
│   ├── three_way_merge.rb    ← LCS-based text merge
│   ├── pbs_merger.rb         ← Section-aware PBS merge
│   ├── binary_handler.rb     ← Binary file handling
│   └── report.rb             ← Report generation
├── config/
│   └── merge_config.yml      ← Edit this to set your paths & exclusions
└── README.md                 ← This file
```

