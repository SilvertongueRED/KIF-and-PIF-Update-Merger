# frozen_string_literal: true

# Three-way text merge using a line-level LCS (Longest Common Subsequence) diff.
#
# Algorithm:
#   1. Diff base → ours (KIF changes)
#   2. Diff base → theirs (PIF changes)
#   3. Walk both diff sequences simultaneously, applying non-conflicting
#      hunks and inserting conflict markers for overlapping hunks.
class ThreeWayMerge
  # Result of a merge operation
  Result = Struct.new(:content, :conflict_count, keyword_init: true) do
    def clean?
      conflict_count == 0
    end
  end

  # Merge three text strings.
  # @param base   [String] Common ancestor (PIF 6.4.5)
  # @param ours   [String] KIF version
  # @param theirs [String] PIF new version
  # @return [Result]
  def self.merge(base, ours, theirs)
    new(base, ours, theirs).merge
  end

  def initialize(base, ours, theirs)
    @base_lines   = split_lines(base)
    @ours_lines   = split_lines(ours)
    @theirs_lines = split_lines(theirs)
  end

  def merge
    our_hunks    = diff_hunks(@base_lines, @ours_lines)
    their_hunks  = diff_hunks(@base_lines, @theirs_lines)

    output         = []
    conflict_count = 0
    base_pos       = 0

    # Walk through both hunk lists simultaneously
    our_idx   = 0
    their_idx = 0

    loop do
      our_hunk   = our_hunks[our_idx]
      their_hunk = their_hunks[their_idx]

      # Determine the next hunk to process
      if our_hunk.nil? && their_hunk.nil?
        # Append remaining base lines
        output.concat(@base_lines[base_pos..]) if base_pos < @base_lines.length
        break
      end

      next_base = [
        our_hunk   ? our_hunk[:base_start]   : Float::INFINITY,
        their_hunk ? their_hunk[:base_start]  : Float::INFINITY
      ].min

      # Copy unchanged base lines up to the next hunk
      if base_pos < next_base
        output.concat(@base_lines[base_pos...next_base])
        base_pos = next_base
      end

      # Collect all ours hunks starting at base_pos
      active_ours   = []
      active_theirs = []

      while our_hunks[our_idx] && our_hunks[our_idx][:base_start] <= base_pos
        active_ours << our_hunks[our_idx]
        our_idx += 1
      end

      while their_hunks[their_idx] && their_hunks[their_idx][:base_start] <= base_pos
        active_theirs << their_hunks[their_idx]
        their_idx += 1
      end

      if active_ours.empty? && active_theirs.empty?
        # Advance by one to avoid infinite loop
        output << @base_lines[base_pos] if base_pos < @base_lines.length
        base_pos += 1
        next
      end

      # Merge hunks that touch the same base region
      merged_ours   = active_ours.flat_map   { |h| h[:replacement] }
      merged_theirs = active_theirs.flat_map { |h| h[:replacement] }

      base_end_ours   = active_ours.map   { |h| h[:base_end] }.max || base_pos
      base_end_theirs = active_theirs.map { |h| h[:base_end] }.max || base_pos
      base_end        = [base_end_ours, base_end_theirs].max

      ours_changed   = !active_ours.empty?
      theirs_changed = !active_theirs.empty?

      if ours_changed && theirs_changed && merged_ours == merged_theirs
        # Both sides made the same change — clean
        output.concat(merged_ours)
      elsif ours_changed && !theirs_changed
        # Only KIF changed
        output.concat(merged_ours)
      elsif !ours_changed && theirs_changed
        # Only PIF changed
        output.concat(merged_theirs)
      else
        # Conflict
        conflict_count += 1
        output << "<<<<<<< KIF\n"
        output.concat(merged_ours)
        output << "=======\n"
        output.concat(merged_theirs)
        output << ">>>>>>> PIF\n"
      end

      base_pos = base_end
    end

    Result.new(content: output.join, conflict_count: conflict_count)
  end

  private

  # Split text into lines, preserving line endings.
  def split_lines(text)
    return [] if text.nil? || text.empty?
    lines = text.lines
    # Ensure last line has a newline if it doesn't
    lines[-1] += "\n" unless lines[-1].end_with?("\n") rescue nil
    lines
  end

  # Compute a list of "change hunks" from base → target using LCS diff.
  # Each hunk: { base_start:, base_end:, replacement: [lines] }
  def diff_hunks(base, target)
    lcs = longest_common_subsequence(base, target)
    hunks = []

    base_pos   = 0
    target_pos = 0
    lcs_idx    = 0

    while lcs_idx <= lcs.length
      lcs_entry = lcs[lcs_idx]

      b_anchor = lcs_entry ? lcs_entry[0] : base.length
      t_anchor = lcs_entry ? lcs_entry[1] : target.length

      if base_pos < b_anchor || target_pos < t_anchor
        # There are deleted/inserted lines between base_pos and the anchor
        hunks << {
          base_start:  base_pos,
          base_end:    b_anchor,
          replacement: target[target_pos...t_anchor] || []
        }
      end

      break if lcs_entry.nil?

      base_pos   = b_anchor + 1
      target_pos = t_anchor + 1
      lcs_idx   += 1
    end

    hunks
  end

  # Standard LCS using dynamic programming, returning pairs [base_idx, target_idx]
  # for matching lines.
  def longest_common_subsequence(a, b)
    # Use indices for memory-efficiency; limit to reasonable size
    m = a.length
    n = b.length

    # Build LCS table
    table = Array.new(m + 1) { Array.new(n + 1, 0) }

    (1..m).each do |i|
      (1..n).each do |j|
        table[i][j] = if a[i - 1] == b[j - 1]
                        table[i - 1][j - 1] + 1
                      else
                        [table[i - 1][j], table[i][j - 1]].max
                      end
      end
    end

    # Backtrack to find the LCS pairs
    result = []
    i = m
    j = n
    while i > 0 && j > 0
      if a[i - 1] == b[j - 1]
        result.unshift([i - 1, j - 1])
        i -= 1
        j -= 1
      elsif table[i - 1][j] > table[i][j - 1]
        i -= 1
      else
        j -= 1
      end
    end

    result
  end
end
