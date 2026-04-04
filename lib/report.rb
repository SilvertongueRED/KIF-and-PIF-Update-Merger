# frozen_string_literal: true

# Generates a human-readable merge report file and provides helpers to
# accumulate per-file decisions during the merge run.
class Report
  HEADER = <<~TXT
    ============================================================
    KIF ← PIF Update Merger — Merge Report
    Generated: %<timestamp>s
    ============================================================

  TXT

  SECTION_HEADERS = {
    copied_from_pif:   "FILES COPIED FROM PIF (only PIF changed)",
    kept_from_kif:     "FILES KEPT FROM KIF (only KIF changed)",
    excluded:          "FILES EXCLUDED / PROTECTED (KIF-specific, e.g. shiny system)",
    auto_merged:       "FILES AUTO-MERGED (both changed, no conflicts)",
    conflicted:        "FILES WITH CONFLICTS — manual review required",
    unchanged:         "UNCHANGED FILES (identical in all three versions)",
    deleted:           "FILES OMITTED (deleted upstream and unchanged in KIF)"
  }.freeze

  Entry = Struct.new(:relative_path, :action, :note, keyword_init: true)

  def initialize
    @entries = []
  end

  # Record a file decision.
  # @param relative_path [String] path relative to project root
  # @param action [Symbol] one of :copied_from_pif, :kept_from_kif, :excluded,
  #                        :auto_merged, :conflicted, :unchanged, :deleted
  # @param note [String, nil] optional extra detail
  def record(relative_path:, action:, note: nil)
    @entries << Entry.new(relative_path: relative_path.to_s, action: action, note: note)
  end

  # Write the report to a file.
  def write(path)
    File.open(path, "w", encoding: "utf-8") do |f|
      f.write(format(HEADER, timestamp: Time.now.strftime("%Y-%m-%d %H:%M:%S")))
      write_summary(f)
      f.puts
      write_sections(f)
    end
  end

  # Return counts per action
  def counts
    @entries.group_by(&:action).transform_values(&:count)
  end

  private

  def write_summary(f)
    c = counts
    total = @entries.size
    f.puts "SUMMARY"
    f.puts "-------"
    f.puts "  Total files processed : #{total}"
    f.puts "  Copied from PIF       : #{c.fetch(:copied_from_pif, 0)}"
    f.puts "  Kept from KIF         : #{c.fetch(:kept_from_kif, 0)}"
    f.puts "  Protected/excluded    : #{c.fetch(:excluded, 0)}"
    f.puts "  Auto-merged (clean)   : #{c.fetch(:auto_merged, 0)}"
    f.puts "  CONFLICTS             : #{c.fetch(:conflicted, 0)}"
    f.puts "  Unchanged             : #{c.fetch(:unchanged, 0)}"
    f.puts "  Deleted/omitted       : #{c.fetch(:deleted, 0)}"
  end

  def write_sections(f)
    SECTION_HEADERS.each do |action, header|
      group = @entries.select { |e| e.action == action }
      next if group.empty?

      f.puts "------------------------------------------------------------"
      f.puts header
      f.puts "------------------------------------------------------------"
      group.each do |entry|
        f.puts "  #{entry.relative_path}"
        f.puts "    └─ #{entry.note}" if entry.note
      end
      f.puts
    end
  end
end
