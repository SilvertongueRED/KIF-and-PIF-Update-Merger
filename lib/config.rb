# frozen_string_literal: true

require "yaml"
require "pathname"

# Handles loading and validating merge configuration from a YAML file.
class Config
  DEFAULT_CONFIG_PATH = File.expand_path("../../config/merge_config.yml", __FILE__)

  attr_reader :pif_base, :pif_new, :kif_current, :output,
              :exclusions, :merge_directories,
              :text_extensions, :binary_extensions

  def initialize(config_path = nil)
    config_path ||= DEFAULT_CONFIG_PATH
    @config = load_yaml(config_path)
    parse!
  end

  def excluded?(relative_path)
    norm = relative_path.to_s.gsub("\\", "/")
    @exclusions.any? do |pattern|
      # Support both simple fnmatch and **/glob patterns
      File.fnmatch?(pattern, norm, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
        File.fnmatch?(pattern, File.basename(norm), File::FNM_DOTMATCH)
    end
  end

  def text_file?(path)
    ext = File.extname(path).downcase
    @text_extensions.include?(ext)
  end

  def binary_file?(path)
    ext = File.extname(path).downcase
    @binary_extensions.include?(ext)
  end

  private

  def load_yaml(path)
    unless File.exist?(path)
      abort "ERROR: Config file not found: #{path}\n" \
            "Copy config/merge_config.yml and edit the paths section."
    end
    YAML.safe_load(File.read(path)) || {}
  rescue Psych::SyntaxError => e
    abort "ERROR: Invalid YAML in config file: #{e.message}"
  end

  def parse!
    paths = @config.fetch("paths", {})
    @pif_base    = resolve_path(paths["pif_base"])
    @pif_new     = resolve_path(paths["pif_new"])
    @kif_current = resolve_path(paths["kif_current"])
    @output      = resolve_path(paths["output"])

    @exclusions         = Array(@config.fetch("exclusions", []))
    @merge_directories  = Array(@config.fetch("merge_directories", []))
    @text_extensions    = Array(@config.fetch("text_extensions", [])).map(&:downcase)
    @binary_extensions  = Array(@config.fetch("binary_extensions", [])).map(&:downcase)
  end

  def resolve_path(raw)
    return nil if raw.nil? || raw.to_s.strip.empty?
    Pathname.new(raw.to_s).expand_path
  end
end
