#!/usr/bin/env ruby
# frozen_string_literal: true

# KIF ← PIF Update Merger
# Performs an automated three-way merge to bring PIF 6.5→6.7.2 changes
# into KIF while protecting KIF-specific modifications (e.g. shiny system).
#
# Usage:
#   ruby merger.rb [--config path/to/config.yml] [--dry-run] [--verbose] [--help]

require "optparse"
require "fileutils"
require "pathname"
require "digest"

SCRIPT_DIR = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(SCRIPT_DIR, "lib"))

require_relative "lib/config"
require_relative "lib/binary_handler"
require_relative "lib/three_way_merge"
require_relative "lib/pbs_merger"
require_relative "lib/report"

# ---------------------------------------------------------------------------
# Terminal colours (degrades gracefully on Windows without ANSI support)
# ---------------------------------------------------------------------------
module Color
  RESET  = "\e[0m"
  GREEN  = "\e[32m"
  YELLOW = "\e[33m"
  RED    = "\e[31m"
  CYAN   = "\e[36m"
  BOLD   = "\e[1m"

  module_function

  def green(s)  = "#{GREEN}#{s}#{RESET}"
  def yellow(s) = "#{YELLOW}#{s}#{RESET}"
  def red(s)    = "#{RED}#{s}#{RESET}"
  def cyan(s)   = "#{CYAN}#{s}#{RESET}"
  def bold(s)   = "#{BOLD}#{s}#{RESET}"

  # Disable colour on Windows unless ANSICON / Windows Terminal is detected.
  def supported?
    return true  if ENV["TERM"] || ENV["WT_SESSION"] || ENV["ANSICON"]
    return false if Gem.win_platform? rescue false
    true
  end
end

unless Color.supported?
  Color.instance_methods(false).each do |m|
    Color.define_method(m) { |s| s }
  end
end

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
def log_info(msg)    = puts(msg)
def log_ok(msg)      = puts(Color.green("  ✔ #{msg}"))
def log_warn(msg)    = puts(Color.yellow("  ⚠ #{msg}"))
def log_error(msg)   = puts(Color.red("  ✖ #{msg}"))
def log_verbose(msg) = ($verbose && puts(Color.cyan("  … #{msg}")))

# ---------------------------------------------------------------------------
# CLI option parsing
# ---------------------------------------------------------------------------
options = { config: nil, dry_run: false, verbose: false }

OptionParser.new do |opts|
  opts.banner = "Usage: ruby merger.rb [options]"
  opts.on("-c", "--config PATH", "Path to config YAML (default: config/merge_config.yml)") { |v| options[:config] = v }
  opts.on("-n", "--dry-run",     "Simulate merge without writing any files")               { options[:dry_run] = true }
  opts.on("-v", "--verbose",     "Print every file processed")                             { options[:verbose] = true }
  opts.on("-h", "--help",        "Show this message")                                      { puts opts; exit }
end.parse!

$dry_run = options[:dry_run]
$verbose = options[:verbose]

# ---------------------------------------------------------------------------
# Helper: copy a file, creating parent directories as needed
# ---------------------------------------------------------------------------
def copy_file(src, dest)
  return unless src && File.exist?(src)
  FileUtils.makedirs(File.dirname(dest))
  FileUtils.cp(src, dest)
end

# Helper: write text content to a file, creating parent directories as needed
def write_text(dest, content)
  FileUtils.makedirs(File.dirname(dest))
  File.write(dest, content, encoding: "utf-8")
end

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
cfg = Config.new(options[:config])

puts
puts Color.bold("KIF ← PIF Update Merger")
puts "=" * 50
puts "  PIF Base  (6.4.5) : #{cfg.pif_base}"
puts "  PIF New   (6.7.2) : #{cfg.pif_new}"
puts "  KIF Current       : #{cfg.kif_current}"
puts "  Output            : #{cfg.output}"
puts "  Dry-run           : #{$dry_run}"
puts "=" * 50
puts

# Validate that required source directories exist
[:pif_base, :pif_new, :kif_current].each do |key|
  path = cfg.send(key)
  unless path && File.directory?(path)
    abort Color.red(
      "ERROR: #{key} directory not found: #{path}\n" \
      "Edit config/merge_config.yml and set the correct path."
    )
  end
end

# ---------------------------------------------------------------------------
# Collect all relative file paths from all three trees
# ---------------------------------------------------------------------------
def collect_files(root)
  root = Pathname.new(root)
  Dir.glob("#{root}/**/*", File::FNM_DOTMATCH)
     .reject { |f| File.directory?(f) }
     .map    { |f| Pathname.new(f).relative_path_from(root).to_s }
end

report     = Report.new
all_paths  = (
  collect_files(cfg.pif_base) +
  collect_files(cfg.pif_new)  +
  collect_files(cfg.kif_current)
).uniq.sort

# Filter to configured merge directories (if any specified)
if cfg.merge_directories && !cfg.merge_directories.empty?
  all_paths = all_paths.select do |rel|
    cfg.merge_directories.any? { |dir| rel.start_with?(dir + "/") || rel.start_with?(dir + "\\") }
  end
end

log_info "Found #{all_paths.size} unique files across all three directories."
puts

conflicts_found = false

all_paths.each do |rel|
  base_path = File.join(cfg.pif_base,    rel)
  pif_path  = File.join(cfg.pif_new,     rel)
  kif_path  = File.join(cfg.kif_current, rel)

  base_exists = File.exist?(base_path)
  pif_exists  = File.exist?(pif_path)
  kif_exists  = File.exist?(kif_path)

  out_path = File.join(cfg.output, rel)

  # ------------------------------------------------------------------
  # 1. Exclusion check — always keep KIF version
  # ------------------------------------------------------------------
  if cfg.excluded?(rel)
    if kif_exists
      log_verbose "EXCLUDED  #{rel}"
      report.record(relative_path: rel, action: :excluded,
                    note: "Protected by exclusion pattern — KIF version kept")
      copy_file(kif_path, out_path) unless $dry_run
    else
      log_verbose "EXCLUDED (not in KIF)  #{rel}"
      report.record(relative_path: rel, action: :excluded,
                    note: "Excluded pattern but file not in KIF — skipped")
    end
    next
  end

  # ------------------------------------------------------------------
  # 2. Compute what changed
  # ------------------------------------------------------------------
  # Treat missing-from-base as nil hash so it compares as "changed"
  base_hash = base_exists ? Digest::SHA256.file(base_path).hexdigest : nil
  pif_hash  = pif_exists  ? Digest::SHA256.file(pif_path).hexdigest  : nil
  kif_hash  = kif_exists  ? Digest::SHA256.file(kif_path).hexdigest  : nil

  pif_changed = base_hash != pif_hash
  kif_changed = base_hash != kif_hash

  # ------------------------------------------------------------------
  # 3. Handle binary files
  # ------------------------------------------------------------------
  if cfg.binary_file?(rel)
    decision = BinaryHandler.decide(
      base_path: base_exists ? base_path : nil,
      pif_path:  pif_exists  ? pif_path  : nil,
      kif_path:  kif_exists  ? kif_path  : nil
    )

    case decision.action
    when :unchanged
      log_verbose "UNCHANGED #{rel}"
      src = kif_exists ? kif_path : pif_path
      copy_file(src, out_path) unless $dry_run
      report.record(relative_path: rel, action: :unchanged, note: decision.note)

    when :take_pif
      log_ok "PIF←      #{rel}"
      copy_file(pif_path, out_path) unless $dry_run
      report.record(relative_path: rel, action: :copied_from_pif, note: decision.note)

    when :keep_kif
      log_verbose "→KIF      #{rel}"
      copy_file(kif_path, out_path) unless $dry_run
      report.record(relative_path: rel, action: :kept_from_kif, note: decision.note)

    when :delete
      log_verbose "DELETE    #{rel}"
      report.record(relative_path: rel, action: :deleted, note: decision.note)

    when :conflict
      log_error "CONFLICT  #{rel}"
      conflicts_found = true
      unless $dry_run
        copies = BinaryHandler.write_conflict_copies(
          kif_path:    kif_exists ? kif_path : nil,
          pif_path:    pif_exists ? pif_path : nil,
          output_path: out_path
        )
        note = "#{decision.note} → #{copies.map { |p| File.basename(p) }.join(', ')}"
        report.record(relative_path: rel, action: :conflicted, note: note)
      else
        report.record(relative_path: rel, action: :conflicted, note: decision.note)
      end
    end

    next
  end

  # ------------------------------------------------------------------
  # 4. Handle text files
  # ------------------------------------------------------------------
  unless pif_changed || kif_changed
    # Identical everywhere
    log_verbose "UNCHANGED #{rel}"
    src = kif_exists ? kif_path : (pif_exists ? pif_path : base_path)
    copy_file(src, out_path) unless $dry_run
    report.record(relative_path: rel, action: :unchanged)
    next
  end

  if pif_changed && !kif_changed
    # Only PIF changed — take PIF
    log_ok "PIF←      #{rel}"
    copy_file(pif_path, out_path) unless $dry_run
    report.record(relative_path: rel, action: :copied_from_pif,
                  note: "PIF updated; KIF unchanged")
    next
  end

  if !pif_changed && kif_changed
    # Only KIF changed — keep KIF
    log_verbose "→KIF      #{rel}"
    copy_file(kif_path, out_path) unless $dry_run
    report.record(relative_path: rel, action: :kept_from_kif,
                  note: "KIF modified; PIF unchanged")
    next
  end

  # Both changed — three-way merge
  base_text   = base_exists ? File.read(base_path,   encoding: "utf-8") : ""
  kif_text    = kif_exists  ? File.read(kif_path,    encoding: "utf-8") : ""
  theirs_text = pif_exists  ? File.read(pif_path,    encoding: "utf-8") : ""

  # Choose merger based on file type / location
  merger_result =
    if rel.start_with?("PBS/") || rel.start_with?("PBS\\")
      PbsMerger.merge(base_text, kif_text, theirs_text)
    else
      ThreeWayMerge.merge(base_text, kif_text, theirs_text)
    end

  if merger_result.clean?
    log_ok "MERGED    #{rel}"
    write_text(out_path, merger_result.content) unless $dry_run
    report.record(relative_path: rel, action: :auto_merged,
                  note: "Clean three-way merge")
  else
    log_error "CONFLICT  #{rel} (#{merger_result.conflict_count} conflict(s))"
    conflicts_found = true
    write_text(out_path, merger_result.content) unless $dry_run
    report.record(relative_path: rel, action: :conflicted,
                  note: "#{merger_result.conflict_count} conflict hunk(s) — search for <<<<<<< KIF")
  end
end

# ---------------------------------------------------------------------------
# Write report
# ---------------------------------------------------------------------------
report_path = File.join(cfg.output.to_s, "merge_report.txt")
unless $dry_run
  FileUtils.makedirs(cfg.output.to_s)
  report.write(report_path)
end

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
c = report.counts
puts
puts "=" * 50
puts Color.bold("Merge complete#{$dry_run ? ' (DRY RUN)' : ''}!")
puts "  Copied from PIF    : #{Color.green(c.fetch(:copied_from_pif, 0).to_s)}"
puts "  Kept from KIF      : #{c.fetch(:kept_from_kif, 0)}"
puts "  Protected/excluded : #{Color.yellow(c.fetch(:excluded, 0).to_s)}"
puts "  Auto-merged        : #{Color.green(c.fetch(:auto_merged, 0).to_s)}"
puts "  Conflicts          : #{conflicts_found ? Color.red(c.fetch(:conflicted, 0).to_s) : '0'}"
puts "  Unchanged          : #{c.fetch(:unchanged, 0)}"
puts "  Deleted/omitted    : #{c.fetch(:deleted, 0)}"
puts
unless $dry_run
  puts "Output written to  : #{cfg.output}"
  puts "Report written to  : #{report_path}"
end
if conflicts_found
  puts
  puts Color.red("⚠  There are conflicts that require manual review.")
  puts "   Open the conflicted files and look for <<<<<<< KIF markers."
  puts "   For binary conflicts, both _KIF and _PIF copies are in the output."
end
puts
