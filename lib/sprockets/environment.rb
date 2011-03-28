require 'fileutils'
require 'hike'
require 'logger'
require 'rack/request'
require 'thread'
require 'tilt'

module Sprockets
  class Environment
    DEFAULT_ENGINE_EXTENSIONS = %w( .coffee .erb .less .sass .scss .str )
    CONCATENATABLE_EXTENSIONS = %w( .css .js )

    @template_mappings = {}

    def self.register(ext, klass)
      ext = ext.to_s.sub(/^\./, '').downcase
      @template_mappings[ext] = klass
    end

    def self.lookup_engine(ext)
      ext = ext.to_s.sub(/^\./, '').downcase
      @template_mappings[ext] || Tilt[ext]
    end

    attr_accessor :logger

    attr_accessor :css_compressor, :js_compressor

    def initialize(root = ".")
      @trail = Hike::Trail.new(root)
      engine_extensions.replace(DEFAULT_ENGINE_EXTENSIONS + CONCATENATABLE_EXTENSIONS)

      @logger = Logger.new($stderr)
      @logger.level = Logger::FATAL

      @cache = {}
      @lock  = nil

      @static_root = nil

      @server = Server.new(self)
    end

    def use_default_compressors
      begin
        require 'yui/compressor'
        self.css_compressor = YUI::CssCompressor.new
        self.js_compressor  = YUI::JavaScriptCompressor.new(:munge => true)
      rescue LoadError
      end

      begin
        require 'closure-compiler'
        self.js_compressor = Closure::Compiler.new
      rescue LoadError
      end

      nil
    end

    def multithread
      @lock ? true : false
    end

    def multithread=(val)
      @lock = val ? Mutex.new : nil
    end

    def static_root
      @static_root
    end

    def static_root=(root)
      @static_root = root ? Pathname.new(root) : nil
    end

    def root
      @trail.root
    end

    def paths
      @trail.paths
    end

    def engine_extensions
      @trail.extensions
    end

    def call(env)
      @server.call(env)
    end

    def path(logical_path, fingerprint = true, prefix = nil)
      logical_path = Pathname.new(logical_path)

      if fingerprint && asset = find_asset(logical_path)
        basename = logical_path.basename_without_extensions +
          "-" + asset.digest +
          logical_path.extensions.join

        if logical_path.dirname == '.'
          url = basename
        else
          url = File.join(logical_path.dirname, basename)
        end
      else
        url = logical_path.to_s
      end

      url = File.join(prefix, url) if prefix
      url = "/#{url}" unless url =~ /^\//

      url
    end

    def url(env, logical_path, fingerprint = true, prefix = nil)
      req = Rack::Request.new(env)

      url = req.scheme + "://"
      url << req.host

      if req.scheme == "https" && req.port != 443 ||
          req.scheme == "http" && req.port != 80
        url << ":#{req.port}"
      end

      url << path(logical_path, fingerprint, prefix)

      url
    end

    def precompile(*paths)
      raise "missing static root" unless static_root

      paths.each do |path|
        if asset = find_asset(path)
          filename = File.join(static_root.to_s, path.to_s)

          FileUtils.mkdir_p File.dirname(filename)

          File.open(filename, 'w') do |f|
            f.write asset.to_s
          end
        end
      end
    end

    def resolve(logical_path, options = {})
      if block_given?
        @trail.find(logical_path.to_s, options) do |path|
          yield Pathname.new(path)
        end
      else
        resolve(logical_path, options) do |pathname|
          return pathname
        end
        raise FileNotFound, "couldn't find file '#{logical_path}'"
      end
    end

    def find_asset(logical_path)
      logger.debug "[Sprockets] Finding asset for #{logical_path}"

      logical_path = Pathname.new(logical_path)

      if asset = find_fresh_asset_from_cache(logical_path)
        asset
      elsif @lock
        @lock.synchronize do
          if asset = find_fresh_asset_from_cache(logical_path)
            asset
          elsif asset = build_asset(logical_path)
            @cache[logical_path.to_s] = asset
          end
        end
      elsif asset = build_asset(logical_path)
        @cache[logical_path.to_s] = asset
      end
    end

    alias_method :[], :find_asset

    protected
      def find_fresh_asset_from_cache(logical_path)
        if asset = @cache[logical_path.to_s]
          if logical_path.fingerprint
            logger.debug "[Sprockets] Asset #{logical_path} is cached"
            asset
          elsif asset.stale?
            logger.warn "[Sprockets] Asset #{logical_path} #{asset.digest} is stale"
            nil
          else
            logger.info "[Sprockets] Asset #{logical_path} #{asset.digest} is fresh"
            asset
          end
        else
          logger.debug "[Sprockets] Asset #{logical_path} is not cached"
          nil
        end
      end

      def build_asset(logical_path)
        logger.info "[Sprockets] Building asset for #{logical_path}"
        find_static_asset(logical_path) || find_asset_in_load_path(logical_path)
      end

      def find_static_asset(logical_path)
        return nil unless static_root

        pathname = Pathname.new(File.join(static_root.to_s, logical_path.to_s))

        if !pathname.fingerprint
          basename = "#{pathname.basename_without_extensions}-#{'[0-9a-f]'*7}*"
          basename = "#{basename}#{pathname.extensions.join}"

          Dir[File.join(pathname.dirname, basename)].each do |filename|
            return StaticAsset.new(filename)
          end
        end

        if pathname.file?
          return StaticAsset.new(pathname)
        end

        nil
      end

      def find_asset_in_load_path(logical_path)
        if fingerprint = logical_path.fingerprint
          pathname = resolve(logical_path.to_s.sub("-#{fingerprint}", ''))
        else
          pathname = resolve(logical_path)
        end
      rescue FileNotFound
        nil
      else
        if concatenatable?(pathname)
          asset = ConcatenatedAsset.new(self, pathname)
        else
          asset = StaticAsset.new(pathname)
        end

        if fingerprint && fingerprint != asset.digest
          logger.error "[Sprockets] Couldn't find #{logical_path}"
          return nil
        end

        asset
      end

      def concatenatable?(pathname)
        CONCATENATABLE_EXTENSIONS.include?(pathname.format_extension)
      end
  end
end
