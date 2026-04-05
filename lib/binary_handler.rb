# frozen_string_literal: true

require "digest"

# Handles binary file comparison and conflict resolution.
# For binary files (rxdata, images, audio), we can't do text-based merging —
# instead we detect which side changed and either copy or flag as conflict.
class BinaryHandler
  # Result struct for a binary file decision
  Decision = Struct.new(:action, :source, :note, keyword_init: true)

  # Compare the three versions of a binary file and decide what to do.
  #
  # @param base_path   [String, nil] Path to PIF base version (may be nil if new file)
  # @param pif_path    [String, nil] Path to PIF new version (may be nil if deleted)
  # @param kif_path    [String, nil] Path to KIF current version (may be nil if not present)
  # @return [Decision]
  def self.decide(base_path:, pif_path:, kif_path:)
    base_hash = hash_file(base_path)
    pif_hash  = hash_file(pif_path)
    kif_hash  = hash_file(kif_path)

    pif_changed = base_hash != pif_hash
    kif_changed = base_hash != kif_hash

    if !pif_changed && !kif_changed
      # Neither side changed — keep either (use KIF as authoritative)
      Decision.new(action: :unchanged, source: kif_path || pif_path,
                   note: "Unchanged in both PIF and KIF")

    elsif pif_changed && !kif_changed
      # Only PIF changed — use PIF's version
      if pif_path
        Decision.new(action: :take_pif, source: pif_path,
                     note: "PIF updated; KIF unchanged — taking PIF version")
      else
        # PIF deleted the file
        Decision.new(action: :delete, source: nil,
                     note: "PIF deleted this file; KIF unchanged — omitting from output")
      end

    elsif !pif_changed && kif_changed
      # Only KIF changed — keep KIF's version
      Decision.new(action: :keep_kif, source: kif_path,
                   note: "KIF modified; PIF unchanged — keeping KIF version")

    else
      # Both changed — PIF 6.7.2 takes priority
      if pif_path && kif_path
        Decision.new(action: :take_pif, source: pif_path,
                     note: "Both PIF and KIF modified this binary file — PIF 6.7.2 takes priority")
      elsif pif_path
        # KIF deleted it but PIF updated it — take PIF
        Decision.new(action: :take_pif, source: pif_path,
                     note: "PIF updated but KIF deleted — PIF 6.7.2 takes priority")
      elsif kif_path
        # PIF deleted it but KIF updated it — keep KIF since no PIF version exists
        Decision.new(action: :keep_kif, source: kif_path,
                     note: "KIF updated but PIF deleted — keeping KIF (no PIF version available)")
      else
        Decision.new(action: :delete, source: nil,
                     note: "Both sides deleted this file")
      end
    end
  end

  # Copy both conflicting versions to the output directory with suffixes.
  #
  # @param kif_path    [String] Path to KIF version
  # @param pif_path    [String] Path to PIF version
  # @param output_path [String] Intended output path (used to derive suffixed names)
  # @return [Array<String>] Paths of the two output files written
  def self.write_conflict_copies(kif_path:, pif_path:, output_path:)
    dir      = File.dirname(output_path)
    ext      = File.extname(output_path)
    base     = File.basename(output_path, ext)
    written  = []

    [[kif_path, "_KIF"], [pif_path, "_PIF"]].each do |src, suffix|
      next unless src && File.exist?(src)
      dest = File.join(dir, "#{base}#{suffix}#{ext}")
      FileUtils.makedirs(dir)
      FileUtils.cp(src, dest)
      written << dest
    end

    written
  end

  # SHA-256 hash a file; returns nil if the path is nil or missing.
  def self.hash_file(path)
    return nil unless path && File.exist?(path)
    Digest::SHA256.file(path).hexdigest
  rescue => e
    warn "WARN: Could not hash #{path}: #{e.message}"
    nil
  end
end
