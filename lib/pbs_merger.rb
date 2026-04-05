# frozen_string_literal: true

# PBS-specific section-aware merger for RPG Maker XP / Pokémon Essentials data files.
#
# PBS files (pokemon.txt, moves.txt, trainers.txt, etc.) use a section format:
#
#   [SECTIONNAME]
#   key=value
#   key2=value2
#
#   [NEXTSECTION]
#   ...
#
# This merger compares and merges at the section level, which gives much better
# results than line-by-line merging for structured game data.
class PbsMerger
  # Merge result, same interface as ThreeWayMerge::Result
  Result = Struct.new(:content, :conflict_count, keyword_init: true) do
    def clean?
      conflict_count == 0
    end
  end

  # Perform a section-aware three-way merge on PBS text content.
  #
  # @param base   [String] PIF 6.4.5 content
  # @param ours   [String] KIF current content
  # @param theirs [String] PIF 6.7.2 content
  # @return [Result]
  def self.merge(base, ours, theirs)
    new(base, ours, theirs).merge
  end

  def initialize(base, ours, theirs)
    @base_sections   = parse_sections(base)
    @ours_sections   = parse_sections(ours)
    @theirs_sections = parse_sections(theirs)
  end

  def merge
    conflict_count = 0
    output_parts   = []

    # Build the full set of section keys, preserving insertion order.
    # Priority for ordering: KIF order first, then any PIF-new sections appended.
    all_keys = ordered_keys(@ours_sections, @theirs_sections, @base_sections)

    all_keys.each do |key|
      base_sec   = @base_sections[key]
      ours_sec   = @ours_sections[key]
      theirs_sec = @theirs_sections[key]

      pif_changed = base_sec != theirs_sec
      kif_changed = base_sec != ours_sec

      result_sec =
        if !pif_changed && !kif_changed
          # Unchanged in both — use KIF (or base, same thing)
          ours_sec || base_sec
        elsif pif_changed && !kif_changed
          # Only PIF changed — take PIF version
          theirs_sec
        elsif !pif_changed && kif_changed
          # Only KIF changed — keep KIF version
          ours_sec
        else
          # Both changed — try line-level merge within the section
          require_relative "three_way_merge"
          merge_result = ThreeWayMerge.merge(
            section_to_text(key, base_sec),
            section_to_text(key, ours_sec),
            section_to_text(key, theirs_sec)
          )
          if merge_result.clean?
            # Return the raw merged text to be inserted verbatim
            output_parts << merge_result.content
            next
          else
            # PIF 6.7.2 takes priority on section conflicts
            output_parts << section_to_text(key, theirs_sec || [])
            next
          end
        end

      # Handle new/deleted sections
      if result_sec.nil?
        # Section deleted from one side — skip it
        next
      end

      output_parts << section_to_text(key, result_sec)
    end

    Result.new(content: output_parts.join("\n"), conflict_count: conflict_count)
  end

  private

  # Parse PBS text into an ordered hash: { "SECTIONKEY" => ["line1\n", "line2\n", ...] }
  # The "preamble" (lines before the first section header) is stored under key "__preamble__".
  def parse_sections(text)
    return {} if text.nil? || text.empty?

    sections       = {}
    current_key    = "__preamble__"
    current_lines  = []

    text.each_line do |line|
      if (m = line.match(/^\[([^\]]+)\]/))
        sections[current_key] = current_lines unless current_lines.empty? && current_key == "__preamble__"
        current_key   = m[1].strip
        current_lines = []
      else
        current_lines << line
      end
    end

    sections[current_key] = current_lines unless current_lines.empty? && current_key == "__preamble__"
    sections
  end

  # Reconstruct a section as text: "[KEY]\n" + body lines
  def section_to_text(key, lines)
    return "" if lines.nil?
    return lines.join if key == "__preamble__"

    header = "[#{key}]\n"
    header + lines.join
  end

  # Build conflict block for a whole section
  def conflict_section(key, ours_lines, theirs_lines)
    out  = "[#{key}]\n"
    out += "<<<<<<< KIF\n"
    out += Array(ours_lines).join
    out += "=======\n"
    out += Array(theirs_lines).join
    out += ">>>>>>> PIF\n"
    out
  end

  # Return all section keys in a sensible order:
  # 1. Keys present in KIF (ours) — in KIF order
  # 2. Keys new in PIF (theirs) that weren't in base or KIF — appended at end
  def ordered_keys(*section_maps)
    seen = {}
    result = []

    section_maps.each do |map|
      map.each_key do |k|
        unless seen[k]
          seen[k] = true
          result << k
        end
      end
    end

    result
  end
end
