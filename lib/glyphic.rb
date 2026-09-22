# frozen_string_literal: true

require "tessel"

require_relative "glyphic/version"

module Glyphic
  class Error < StandardError; end
  class UnsupportedError < ArgumentError; end

  Glyph = Struct.new(:advance, :bearing_x, :bearing_y, :width, :height, :alpha, :runs, keyword_init: true) do
    def initialize(**attributes)
      super
      self.alpha = String(alpha || "").b.freeze
      self.runs ||= build_runs
      freeze
    end

    def bytes = alpha

    private

    def build_runs
      rows = []
      (0...height).each do |y|
        x = 0
        while x < width
          x += 1 while x < width && alpha.getbyte(y * width + x).zero?
          start = x
          x += 1 while x < width && alpha.getbyte(y * width + x).positive?
          rows << [start, x - 1, y] if x > start
        end
      end
      rows.freeze
    end
  end

  class Font
    attr_reader :line_height, :ascent, :descent

    def initialize(glyphs, line_height:, ascent:, descent: 0, fallback: nil, skipped_glyphs: 0)
      @glyphs = glyphs
      @line_height = line_height
      @ascent = ascent
      @descent = descent
      @fallback = fallback
      @skipped_glyphs = skipped_glyphs
    end

    attr_reader :skipped_glyphs

    def glyph?(character)
      @glyphs.key?(character.to_s.codepoints.first)
    end

    def glyph(character)
      @glyphs[character.to_s.codepoints.first] || @fallback || @glyphs[63] || blank_glyph
    end

    def measure(text)
      lines = Layout.lines(text, self)
      [lines.map { |line| Layout.width(line, self) }.max.to_i, lines.length * line_height]
    end

    def text_width(text)
      measure(text)[0]
    end

    def kerning(_left, _right)
      0
    end

    def draw(target, x, y, text, color: [255, 255, 255, 255], baseline: false, **options)
      Renderer.draw(self, target, x, y, text, color: color, baseline: baseline, **options)
    end

    def draw_text_box(target, x:, y:, width:, text:, color: [255, 255, 255, 255], align: :left, wrap: :word, line_spacing: 1.0, **options)
      Renderer.draw_box(self, target, x: x, y: y, width: width, text: text, color: color, align: align, wrap: wrap, line_spacing: line_spacing, **options)
    end

    def render(text, color: [255, 255, 255, 255], padding: 0)
      width, height = measure(text)
      image = Tessel::Image.new(width + padding * 2, height + padding * 2)
      draw(image, padding, padding, text, color: color)
      image
    end

    private

    def blank_glyph
      @blank_glyph ||= Glyph.new(advance: line_height / 2, bearing_x: 0, bearing_y: ascent, width: 0, height: 0, alpha: "".b)
    end
  end

  module BDF
    module_function

    def load(source)
      text = if source.respond_to?(:read)
        source.read
      elsif source.is_a?(String) && source.lstrip.start_with?("STARTFONT")
        source
      else
        File.read(source)
      end
      lines = text.lines.map(&:strip)
      raise ArgumentError, "not a BDF font" unless lines.first == "STARTFONT 2.1" || lines.first&.start_with?("STARTFONT")

      ascent = lines.find { |line| line.start_with?("FONT_ASCENT") }&.split&.last.to_i
      descent = lines.find { |line| line.start_with?("FONT_DESCENT") }&.split&.last.to_i
      registry = lines.find { |line| line.start_with?("CHARSET_REGISTRY") }&.split(" ", 2)&.last.to_s.delete('"')
      glyphs = {}
      skipped = 0
      index = 0
      while index < lines.length
        unless lines[index].start_with?("STARTCHAR")
          index += 1
          next
        end
        block = []
        index += 1
        while index < lines.length && lines[index] != "ENDCHAR"
          block << lines[index]
          index += 1
        end
        encoded = block.find { |line| line.start_with?("ENCODING") }&.split&.last
        code = encoded&.to_i
        if code && code >= 0
          code = jis_to_unicode(code) if registry.start_with?("JISX0208")
          if code
            glyph = parse_glyph(block, advance: block.find { |line| line.start_with?("DWIDTH") }&.split&.last.to_i)
            glyphs[code] = glyph
          else
            skipped += 1
          end
        else
          skipped += 1
        end
        index += 1
      end
      Font.new(glyphs, line_height: ascent + descent, ascent: ascent, descent: descent, skipped_glyphs: skipped)
    end

    def parse_glyph(block, advance:)
      bbx = block.find { |line| line.start_with?("BBX") }.split.drop(1).map(&:to_i)
      width, height, offset_x, offset_y = bbx
      bitmap_start = block.index("BITMAP")
      rows = block[(bitmap_start + 1), height].to_a
      alpha = rows.map do |line|
        value = line.to_i(16)
        (0...width).map { |x| (value & (1 << ([line.length * 4, width].max - x - 1))).positive? ? 255 : 0 }
      end.flatten.pack("C*")
      Glyph.new(advance: advance, bearing_x: offset_x, bearing_y: offset_y + height, width: width, height: height, alpha: alpha)
    end
    private_class_method :parse_glyph

    def jis_to_unicode(code)
      bytes = [(code >> 8) + 0x80, (code & 0xff) + 0x80].pack("C2")
      bytes.force_encoding("EUC-JP").encode("UTF-8").codepoints.first
    rescue EncodingError
      nil
    end
    private_class_method :jis_to_unicode
  end

  module TrueType
    module_function

    class Reader
      attr_reader :bytes, :tables

      def initialize(bytes)
        @bytes = bytes.b
        @tables = {}
        count = @bytes.byteslice(4, 2).unpack1("n")
        count.times do |index|
          tag, _checksum, offset, length = @bytes.byteslice(12 + index * 16, 16).unpack("a4N3")
          @tables[tag] = @bytes.byteslice(offset, length)
        end
      end

      def u16(data, offset) = data.byteslice(offset, 2).unpack1("n")
      def i16(data, offset) = data.byteslice(offset, 2).unpack1("s>")
      def u32(data, offset) = data.byteslice(offset, 4).unpack1("N")
    end

    class Font < Glyphic::Font
      def initialize(reader, size)
        @reader = reader
        @size = size.to_f
        @head = reader.tables.fetch("head")
        @hhea = reader.tables.fetch("hhea")
        @maxp = reader.tables.fetch("maxp")
        @hmtx = reader.tables.fetch("hmtx")
        @loca = reader.tables.fetch("loca")
        @glyf = reader.tables.fetch("glyf")
        @units_per_em = reader.u16(@head, 18)
        @loca_format = reader.i16(@head, 50)
        @glyph_count = reader.u16(@maxp, 4)
        @metric_count = reader.u16(@hhea, 34)
        @cmap = build_cmap(reader.tables.fetch("cmap"))
        @kern = build_kern(reader.tables["kern"])
        ascent = reader.i16(@hhea, 4) * @size / @units_per_em
        descent = -reader.i16(@hhea, 6) * @size / @units_per_em
        super({}, line_height: (ascent + descent).ceil, ascent: ascent.ceil, descent: descent.ceil)
      end

      def glyph?(character)
        @cmap.key?(character.to_s.codepoints.first)
      end

      def glyph(character)
        codepoint = character.to_s.codepoints.first
        index = @cmap[codepoint]
        return super unless index
        @glyph_cache ||= {}
        @glyph_cache_order ||= []
        if @glyph_cache.key?(codepoint)
          @glyph_cache_order.delete(codepoint)
          @glyph_cache_order << codepoint
          return @glyph_cache[codepoint]
        end

        @glyph_cache[codepoint] = build_glyph(index)
        @glyph_cache_order << codepoint
        @glyph_cache.delete(@glyph_cache_order.shift) if @glyph_cache_order.length > 2048
        @glyph_cache[codepoint]
      end

      def kerning(left, right)
        return 0 unless @kern
        left_index = @cmap[left.to_s.codepoints.first]
        right_index = @cmap[right.to_s.codepoints.first]
        (@kern[[left_index, right_index]] || 0) * @size / @units_per_em
      end

      private

      def build_cmap(data)
        records = @reader.u16(data, 2).times.map do |index|
          platform, encoding, offset = data.byteslice(4 + index * 8, 8).unpack("n2N")
          [platform, encoding, offset]
        end
        selected = records.sort_by { |platform, encoding, _| platform == 3 && encoding == 10 ? 0 : platform == 3 && encoding == 1 ? 1 : platform.zero? ? 2 : 3 }.find { |_, _, offset| [4, 12].include?(@reader.u16(data, offset)) }
        return {} unless selected
        format = @reader.u16(data, selected[2])
        format == 12 ? cmap12(data.byteslice(selected[2]..)) : cmap4(data.byteslice(selected[2]..))
      end

      def build_kern(data)
        return if data.nil? || @reader.u16(data, 0) != 0

        pairs = {}
        offset = 4
        @reader.u16(data, 2).times do
          length = @reader.u16(data, offset + 2)
          coverage = @reader.u16(data, offset + 4)
          if coverage & 0xff == 0
            base = offset + 6
            @reader.u16(data, base).times do |index|
              left, right, value = data.byteslice(base + 8 + index * 6, 6).unpack("n2s>")
              pairs[[left, right]] = value
            end
          end
          offset += length
        end
        pairs
      end

      def cmap12(data)
        result = {}
        @reader.u32(data, 12).times do |index|
          start_code, end_code, start_glyph = data.byteslice(16 + index * 12, 12).unpack("N3")
          (start_code..end_code).each { |code| result[code] = start_glyph + code - start_code }
        end
        result
      end

      def cmap4(data)
        segments = @reader.u16(data, 6) / 2
        end_codes = data.byteslice(14, segments * 2).unpack("n*")
        start_offset = 16 + segments * 2
        start_codes = data.byteslice(start_offset, segments * 2).unpack("n*")
        delta_offset = start_offset + segments * 2
        deltas = data.byteslice(delta_offset, segments * 2).unpack("s>*")
        range_offset = delta_offset + segments * 2
        offsets = data.byteslice(range_offset, segments * 2).unpack("n*")
        result = {}
        end_codes.each_index do |segment|
          (start_codes[segment]..end_codes[segment]).each do |code|
            next if code == 0xffff
            glyph = if offsets[segment].zero?
              (code + deltas[segment]) & 0xffff
            else
              address = range_offset + segment * 2 + offsets[segment] + (code - start_codes[segment]) * 2
              value = @reader.u16(data, address)
              value.zero? ? 0 : (value + deltas[segment]) & 0xffff
            end
            result[code] = glyph if glyph.positive?
          end
        end
        result
      end

      def build_glyph(index)
        advance = if index < @metric_count
          @reader.u16(@hmtx, index * 4)
        else
          @reader.u16(@hmtx, (@metric_count - 1) * 4)
        end
        scale = @size / @units_per_em
        points, end_points, x_min, y_min, x_max, y_max, = outline(index, [])
        return Glyph.new(advance: (advance * scale).round, bearing_x: 0, bearing_y: 0, width: 0, height: 0, alpha: "".b) if points.empty?
        width = [(x_max - x_min) * scale, 1].max.ceil
        height = [(y_max - y_min) * scale, 1].max.ceil
        alpha = rasterize(points, end_points, x_min, y_min, x_max, y_max, width, height, scale)
        Glyph.new(advance: (advance * scale).round, bearing_x: (x_min * scale).floor, bearing_y: (y_max * scale).ceil, width: width, height: height, alpha: alpha)
      end

      def outline(index, stack)
        raise UnsupportedError, "cyclic TrueType composite glyph" if stack.include?(index)

        offset = glyph_offset(index)
        finish = glyph_offset(index + 1)
        return [[], [], 0, 0, 0, 0, []] if finish <= offset

        glyph = @glyf.byteslice(offset, finish - offset)
        contours = @reader.i16(glyph, 0)
        return composite_outline(index, glyph, stack) if contours.negative?

        end_points = glyph.byteslice(10, contours * 2).unpack("n*")
        point_count = end_points.last.to_i + 1
        cursor = 10 + contours * 2
        instruction_length = @reader.u16(glyph, cursor)
        cursor += 2 + instruction_length
        flags = []
        while flags.length < point_count
          flag = glyph.getbyte(cursor)
          cursor += 1
          repeat = flag.anybits?(8) ? glyph.getbyte(cursor).tap { cursor += 1 } : 0
          flags.concat([flag] * (repeat + 1))
        end
        xs = read_coordinates(glyph, flags, cursor, point_count, horizontal: true)
        ys = read_coordinates(glyph, flags, xs[1], point_count, horizontal: false)
        raw_points = xs[0].zip(ys[0]).map { |x, y| [x, y] }
        x_min, y_min, x_max, y_max = glyph.byteslice(2, 8).unpack("s>4")
        points, flattened_end_points = flatten_contours(raw_points, flags, end_points)
        [points, flattened_end_points, x_min, y_min, x_max, y_max, raw_points]
      end

      def glyph_offset(index)
        if @loca_format.zero?
          @reader.u16(@loca, index * 2) * 2
        else
          @reader.u32(@loca, index * 4)
        end
      end

      def composite_outline(index, glyph, stack)
        flags = 0
        cursor = 10
        points = []
        reference_points = []
        end_points = []
        loop do
          flags = @reader.u16(glyph, cursor)
          component_index = @reader.u16(glyph, cursor + 2)
          cursor += 4
          word_args = flags.anybits?(1)
          arg1, arg2 = if word_args
            values = glyph.byteslice(cursor, 4).unpack("s>2")
            cursor += 4
            values
          else
            values = glyph.byteslice(cursor, 2).unpack("c2")
            cursor += 2
            values
          end
          dx, dy = flags.anybits?(2) ? [arg1, arg2] : [0, 0]
          a, b, c, d = component_transform(glyph, flags, cursor)
          cursor += transform_size(flags)
          component = outline(component_index, stack + [index])
          component_points = component[0]
          transformed = component_points.map { |x, y| [x * a + y * c, x * b + y * d] }
          transformed_reference = component[6].map { |x, y| [x * a + y * c, x * b + y * d] }
          if flags.anybits?(2)
            transformed.map! { |x, y| [x + dx, y + dy] }
            transformed_reference.map! { |x, y| [x + dx, y + dy] }
          else
            parent = reference_points[arg2]
            child = transformed_reference[arg1]
            raise UnsupportedError, "invalid TrueType composite point index" unless parent && child
            offset_x = parent[0] - child[0]
            offset_y = parent[1] - child[1]
            transformed.map! { |x, y| [x + offset_x, y + offset_y] }
            transformed_reference.map! { |x, y| [x + offset_x, y + offset_y] }
          end
          point_offset = points.length
          points.concat(transformed)
          reference_points.concat(transformed_reference)
          end_points.concat(component[1].map { |endpoint| endpoint + point_offset })
          break unless flags.anybits?(32)
        end
        x_values = points.map(&:first)
        y_values = points.map(&:last)
        [points, end_points, x_values.min.to_i, y_values.min.to_i, x_values.max.to_i, y_values.max.to_i, reference_points]
      end

      def flatten_contours(points, flags, end_points)
        flattened = []
        flattened_end_points = []
        start = 0
        end_points.each do |finish|
          contour = points[start..finish]
          contour_flags = flags[start..finish]
          count = contour.length
          if contour_flags.first.anybits?(1)
            current = contour.first
            index = 1 % count
            processed = 1
          elsif contour_flags.last.anybits?(1)
            current = contour.last
            index = 0
            processed = 1
          else
            current = midpoint(contour.last, contour.first)
            index = 0
            processed = 0
          end
          outline = [current]
          loop do
            point = contour[index]
            if contour_flags[index].anybits?(1)
              outline << point unless point == outline.last
              current = point
              index = (index + 1) % count
              processed += 1
            else
              following_index = (index + 1) % count
              following = contour[following_index]
              if contour_flags[following_index].anybits?(1)
                append_quadratic(outline, current, point, following)
                current = following
                index = (index + 2) % count
                processed += 2
              else
                implied = midpoint(point, following)
                append_quadratic(outline, current, point, implied)
                current = implied
                index = following_index
                processed += 1
              end
            end
            break if processed >= count
          end
          flattened.concat(outline)
          flattened_end_points << flattened.length - 1
          start = finish + 1
        end
        [flattened, flattened_end_points]
      end

      def append_quadratic(outline, first, control, last)
        length = Math.hypot(control[0] - first[0], control[1] - first[1]) + Math.hypot(last[0] - control[0], last[1] - control[1])
        steps = [(length * @size / @units_per_em / 0.25).ceil, 1].max
        (1..steps).each do |step|
          amount = step.to_f / steps
          inverse = 1 - amount
          outline << [inverse * inverse * first[0] + 2 * inverse * amount * control[0] + amount * amount * last[0], inverse * inverse * first[1] + 2 * inverse * amount * control[1] + amount * amount * last[1]]
        end
      end

      def midpoint(first, second)
        [(first[0] + second[0]) / 2.0, (first[1] + second[1]) / 2.0]
      end

      def component_transform(glyph, flags, cursor)
        if flags.anybits?(128)
          glyph.byteslice(cursor, 8).unpack("s>4").map { |value| value / 16_384.0 }
        elsif flags.anybits?(64)
          x, y = glyph.byteslice(cursor, 4).unpack("s>2").map { |value| value / 16_384.0 }
          [x, 0, 0, y]
        elsif flags.anybits?(8)
          scale = @reader.i16(glyph, cursor) / 16_384.0
          [scale, 0, 0, scale]
        else
          [1, 0, 0, 1]
        end
      end

      def transform_size(flags)
        return 8 if flags.anybits?(128)
        return 4 if flags.anybits?(64)
        flags.anybits?(8) ? 2 : 0
      end

      def read_coordinates(glyph, flags, cursor, count, horizontal:)
        values = []
        previous = 0
        count.times do |index|
          flag = flags[index]
          short = horizontal ? flag.anybits?(2) : flag.anybits?(4)
          same = horizontal ? flag.anybits?(16) : flag.anybits?(32)
          if short
            delta = glyph.getbyte(cursor)
            cursor += 1
            delta = -delta if !same
          elsif same
            delta = 0
          else
            delta = glyph.byteslice(cursor, 2).unpack1("s>")
            cursor += 2
          end
          previous += delta
          values << previous
        end
        [values, cursor]
      end

      def rasterize(points, end_points, x_min, y_min, x_max, y_max, width, height, scale)
        alpha = Array.new(width * height, 0)
        (0...height).each do |row|
          (0...width).each do |column|
            x = x_min + (column + 0.5) / scale
            y = y_max - (row + 0.5) / scale
            winding = 0
            start = 0
            end_points.each do |finish|
              contour = points[start..finish]
              contour.each_with_index do |first, index|
                second = contour[(index + 1) % contour.length]
                next unless (first[1] > y) != (second[1] > y)
                crossing = (second[0] - first[0]) * (y - first[1]) / (second[1] - first[1]) + first[0]
                winding += second[1] > first[1] ? 1 : -1 if crossing > x
              end
              start = finish + 1
            end
            alpha[row * width + column] = 255 if winding != 0
          end
        end
        alpha.pack("C*")
      end
    end

    def load(path, size: 16)
      Font.new(Reader.new(File.binread(path)), size)
    rescue KeyError => error
      raise UnsupportedError, "TrueType font is missing required table: #{error.message}"
    end
  end

  module Layout
    module_function

    def width(text, font)
      previous = nil
      text.each_char.sum do |character|
        advance = font.glyph(character).advance + (previous ? font.kerning(previous, character) : 0)
        previous = character
        advance
      end
    end

    def lines(text, font, width: nil, wrap: nil, tab_width: 4)
      result = []
      text.to_s.split("\n", -1).each do |raw|
        expanded = raw.gsub("\t", " " * tab_width)
        if width && wrap.to_sym == :word
          current = +""
          expanded.split(/(?<=\s)|(?=\s)/).each do |chunk|
            if !current.empty? && Layout.width(current, font) + Layout.width(chunk, font) > width
              result << current.rstrip
              current = chunk.lstrip
            else
              current << chunk
            end
          end
          result << current
        elsif width && wrap
          current = +""
          expanded.each_char do |character|
            if !current.empty? && Layout.width(current, font) + Layout.width(character, font) > width
              result << current
              current = ""
            end
            current << character
          end
          result << current
        else
          result << expanded
        end
      end
      result
    end
  end

  module Renderer
    module_function

    def draw(font, target, x, y, text, color:, baseline: false, line_spacing: 1.0, **_options)
      x = Integer(x)
      origin_y = baseline ? Integer(y) - font.ascent : Integer(y)
      Layout.lines(text, font).each_with_index do |line, line_index|
        cursor = x
        line_y = origin_y + (font.line_height * line_spacing * line_index).round
        previous = nil
        line.each_char do |character|
          glyph = font.glyph(character)
          cursor += font.kerning(previous, character) if previous
          draw_glyph(target, glyph, cursor + glyph.bearing_x, line_y + font.ascent - glyph.bearing_y, color)
          cursor += glyph.advance
          previous = character
        end
      end
      target
    end

    def draw_box(font, target, x:, y:, width:, text:, color:, align:, wrap:, line_spacing:, **options)
      lines = Layout.lines(text, font, width: width, wrap: wrap)
      lines.each_with_index do |line, index|
        line_width = Layout.width(line, font)
        offset = case align
        when :center then (width - line_width) / 2
        when :right then width - line_width
        else 0
        end
        draw(font, target, x + offset, y + (font.line_height * line_spacing * index).round, line, color: color, **options)
      end
      target
    end

    def draw_glyph(target, glyph, x, y, color)
      if target.is_a?(Tessel::Image)
        target.blit_mask(glyph, x, y, color)
      elsif target.respond_to?(:get_pixel) && target.respond_to?(:set_pixel)
        packed = Tessel::Color.pack(color).unpack("C4")
        glyph.height.times do |row|
          glyph.width.times do |column|
            alpha = glyph.alpha.getbyte(row * glyph.width + column)
            next if alpha.zero?
            target.set_pixel(x + column, y + row, packed)
          end
        end
      else
        raise TypeError, "target must be a Tessel::Image or pixel surface"
      end
    end
    private_class_method :draw_glyph
  end

  class Chain
    def initialize(*fonts)
      raise ArgumentError, "at least one font is required" if fonts.empty?

      @fonts = fonts
      @line_height = fonts.map(&:line_height).max
      @ascent = fonts.map(&:ascent).max
    end

    attr_reader :line_height, :ascent

    def glyph?(character)
      @fonts.any? { |font| font.glyph?(character) }
    end

    def glyph(character)
      @fonts.find { |font| font.glyph?(character) }&.glyph(character) || @fonts.first.glyph(character)
    end

    def kerning(_left, _right)
      0
    end

    def draw(target, x, y, text, **options)
      Renderer.draw(self, target, x, y, text, **options)
    end

    def measure(text)
      lines = Layout.lines(text, self)
      [lines.map { |line| Layout.width(line, self) }.max.to_i, lines.length * line_height]
    end

    def draw_text_box(target, x:, y:, width:, text:, color: [255, 255, 255, 255], align: :left, wrap: :word, line_spacing: 1.0, **options)
      Renderer.draw_box(self, target, x: x, y: y, width: width, text: text, color: color, align: align, wrap: wrap, line_spacing: line_spacing, **options)
    end

    def render(text, color: [255, 255, 255, 255], padding: 0)
      width, height = measure(text)
      image = Tessel::Image.new(width + padding * 2, height + padding * 2)
      draw(image, padding, padding, text, color: color)
      image
    end
  end

  module_function

  def load(path, size: nil, **_options)
    bytes = File.binread(path)
    if bytes.start_with?("STARTFONT")
      BDF.load(path)
    elsif bytes.start_with?("\x00\x01\x00\x00")
      TrueType.load(path, size: size || 16)
    elsif bytes.start_with?("OTTO")
      raise UnsupportedError, "CFF fonts are not supported"
    else
      raise UnsupportedError, "unknown font format"
    end
  end

  def default
    @default ||= Builtin.font
  end

  module Builtin
    module_function

    def font
      patterns = {
        " " => ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
        "?" => ["11110", "00001", "00010", "00100", "00100", "00000", "00100"],
        "!" => ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
        "." => ["00000", "00000", "00000", "00000", "00000", "00110", "00110"],
        ":" => ["00000", "00110", "00110", "00000", "00110", "00110", "00000"],
        "-" => ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
        "_" => ["00000", "00000", "00000", "00000", "00000", "00000", "11111"]
      }
      patterns.merge!(
        "A" => %w[01110 10001 10001 11111 10001 10001 10001],
        "B" => %w[11110 10001 10001 11110 10001 10001 11110],
        "C" => %w[01111 10000 10000 10000 10000 10000 01111],
        "D" => %w[11110 10001 10001 10001 10001 10001 11110],
        "E" => %w[11111 10000 10000 11110 10000 10000 11111],
        "F" => %w[11111 10000 10000 11110 10000 10000 10000],
        "G" => %w[01111 10000 10000 10111 10001 10001 01111],
        "H" => %w[10001 10001 10001 11111 10001 10001 10001],
        "I" => %w[11111 00100 00100 00100 00100 00100 11111],
        "J" => %w[00111 00010 00010 00010 00010 10010 01100],
        "K" => %w[10001 10010 10100 11000 10100 10010 10001],
        "L" => %w[10000 10000 10000 10000 10000 10000 11111],
        "M" => %w[10001 11011 10101 10101 10001 10001 10001],
        "N" => %w[10001 11001 10101 10011 10001 10001 10001],
        "O" => %w[01110 10001 10001 10001 10001 10001 01110],
        "P" => %w[11110 10001 10001 11110 10000 10000 10000],
        "Q" => %w[01110 10001 10001 10001 10101 10010 01101],
        "R" => %w[11110 10001 10001 11110 10100 10010 10001],
        "S" => %w[01111 10000 10000 01110 00001 00001 11110],
        "T" => %w[11111 00100 00100 00100 00100 00100 00100],
        "U" => %w[10001 10001 10001 10001 10001 10001 01110],
        "V" => %w[10001 10001 10001 10001 10001 01010 00100],
        "W" => %w[10001 10001 10001 10101 10101 10101 01010],
        "X" => %w[10001 10001 01010 00100 01010 10001 10001],
        "Y" => %w[10001 10001 01010 00100 00100 00100 00100],
        "Z" => %w[11111 00001 00010 00100 01000 10000 11111]
      )
      ("a".."z").each { |letter| patterns[letter] = patterns[letter.upcase] }
      patterns.merge!(
        "0" => %w[01110 10001 10011 10101 11001 10001 01110],
        "1" => %w[00100 01100 00100 00100 00100 00100 01110],
        "2" => %w[01110 10001 00001 00010 00100 01000 11111],
        "3" => %w[11110 00001 00001 01110 00001 00001 11110],
        "4" => %w[00010 00110 01010 10010 11111 00010 00010],
        "5" => %w[11111 10000 10000 11110 00001 00001 11110],
        "6" => %w[01110 10000 10000 11110 10001 10001 01110],
        "7" => %w[11111 00001 00010 00100 01000 01000 01000],
        "8" => %w[01110 10001 10001 01110 10001 10001 01110],
        "9" => %w[01110 10001 10001 01111 00001 00001 01110]
      )
      glyphs = patterns.transform_keys(&:ord).transform_values do |rows|
        alpha = rows.join.chars.map { |bit| bit == "1" ? 255 : 0 }.pack("C*")
        Glyph.new(advance: 6, bearing_x: 0, bearing_y: 7, width: 5, height: 7, alpha: alpha)
      end
      Font.new(glyphs, line_height: 9, ascent: 7)
    end

    def letter_pattern(letter)
      seed = letter.ord
      Array.new(7) { |row| (0...5).map { |column| ((seed + row * 3 + column * 5) % 7).between?(0, 2) ? "1" : "0" }.join }
    end
    private_class_method :letter_pattern

    def digit_pattern(digit)
      ["01110", "10001", "10011", "10101", "11001", "10001", "01110"].rotate(digit.to_i % 7)
    end
    private_class_method :digit_pattern
  end
end
