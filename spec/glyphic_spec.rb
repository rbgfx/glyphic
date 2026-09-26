# frozen_string_literal: true

require "tmpdir"

RSpec.describe Glyphic do
  it "has a version number" do
    expect(Glyphic::VERSION).not_to be nil
  end

  it "draws text on a Tessel image" do
    image = Tessel::Image.new(80, 20)
    Glyphic.default.draw(image, 2, 2, "A0", color: "#ffffff")

    expect(image.bytes.bytes.any?(&:positive?)).to be(true)
  end

  it "loads BDF glyphs" do
    bdf = <<~BDF
      STARTFONT 2.1
      FONT_ASCENT 7
      FONT_DESCENT 2
      STARTCHAR A
      ENCODING 65
      DWIDTH 6 0
      BBX 3 3 0 0
      BITMAP
      E0
      A0
      E0
      ENDCHAR
      ENDFONT
    BDF
    path = File.join(Dir.tmpdir, "glyphic-test.bdf")
    File.write(path, bdf)

    font = Glyphic.load(path)

    expect(font.glyph?("A")).to be(true)
    expect(font.glyph("A").width).to eq(3)
  end

  it "rejects incomplete BDF glyphs" do
    bdf = <<~BDF
      STARTFONT 2.1
      FONT_ASCENT 7
      STARTCHAR A
      ENCODING 65
      DWIDTH 6 0
      BBX 3 2 0 0
      BITMAP
      E0
      A0
      ENDCHAR
      ENDFONT
    BDF
    ["BBX 3 2 0 0\n", "BITMAP\n", "A0\n", "DWIDTH 6 0\n", "ENDCHAR\n"].each do |line|
      source = bdf.sub(line, "")
      expect { Glyphic::BDF.load(source) }.to raise_error(Glyphic::UnsupportedError, /invalid BDF glyph/)
    end
  end

  it "reports skipped BDF glyphs" do
    bdf = <<~BDF
      STARTFONT 2.1
      FONT_ASCENT 7
      FONT_DESCENT 2
      STARTCHAR missing
      DWIDTH 6 0
      BBX 1 1 0 0
      BITMAP
      80
      ENDCHAR
      ENDFONT
    BDF

    expect(Glyphic::BDF.load(bdf).skipped_glyphs).to eq(1)
  end

  it "rejects truncated TrueType table directories and table data" do
    header = "\0\1\0\0".b
    table = header + [1, 0, 0, 0].pack("n4") + "head" + [0, 500, 4].pack("N3")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "broken.ttf")
      [header, table].each do |bytes|
        File.binwrite(path, bytes)
        expect { Glyphic.load(path) }.to raise_error(Glyphic::UnsupportedError, /invalid TrueType/)
      end
    end
  end

  it "uses one alpha byte per glyph pixel when drawing" do
    bdf = <<~BDF
      STARTFONT 2.1
      FONT_ASCENT 3
      FONT_DESCENT 0
      STARTCHAR A
      ENCODING 65
      DWIDTH 3 0
      BBX 3 3 0 0
      BITMAP
      E0
      A0
      E0
      ENDCHAR
      ENDFONT
    BDF
    path = File.join(Dir.tmpdir, "glyphic-mask-test.bdf")
    File.write(path, bdf)
    image = Tessel::Image.new(3, 3)
    Glyphic.load(path).draw(image, 0, 0, "A", color: "#ff0000")
    expect(image[0, 0]).to eq([255, 0, 0, 255])
    expect(image[1, 1]).to eq([0, 0, 0, 0])
    expect(image[2, 2]).to eq([255, 0, 0, 255])
  end

  it "measures trailing newlines consistently across chained fonts" do
    font = Glyphic.default
    expect(Glyphic::Chain.new(font).measure("A\n")).to eq(font.measure("A\n"))
  end

  it "uses readable built in bitmap patterns" do
    font = Glyphic.default

    expect(font.glyph("C").alpha.bytes.each_slice(5).to_a).to eq(
      ["01111", "10000", "10000", "10000", "10000", "10000", "01111"].map { |row| row.chars.map { |bit| bit == "1" ? 255 : 0 } }
    )
    expect(font.glyph("0").alpha.bytes.count(&:positive?)).to be > font.glyph("1").alpha.bytes.count(&:positive?)
  end

  it "wraps words and renders chained fonts" do
    font = Glyphic.default
    lines = Glyphic::Layout.lines("AAAA BBBB", font, width: 20, wrap: :word)
    expect(lines).to eq(["AAAA", "BBBB"])

    image = Glyphic::Chain.new(font).render("A")
    expect(image.width).to be > 0
  end

  it "rasterizes composite TrueType glyphs" do
    simple = [1, 0, 0, 10, 10].pack("s>5") + [2, 0, 49, 51, 39, 10, 10, 10].pack("n2C6")
    composite = [-1, 0, 0, 20, 10].pack("s>5") + [35, 0, 0, 0, 3, 0, 10, 0].pack("n2s>2n2s>2")
    font = Glyphic::TrueType::Font.allocate
    font.instance_variable_set(:@reader, Glyphic::TrueType::Reader.allocate)
    font.instance_variable_set(:@size, 10.0)
    font.instance_variable_set(:@units_per_em, 10)
    font.instance_variable_set(:@metric_count, 1)
    font.instance_variable_set(:@hmtx, [10, 0].pack("n2"))
    font.instance_variable_set(:@loca_format, 1)
    font.instance_variable_set(:@loca, [0, simple.bytesize, simple.bytesize + composite.bytesize].pack("N3"))
    font.instance_variable_set(:@glyf, simple + composite)

    glyph = font.send(:build_glyph, 1)

    expect(glyph.width).to eq(20)
    expect(glyph.height).to eq(10)
    expect(glyph.alpha.bytes.count(&:positive?)).to be > 0
  end

  it "applies TrueType kerning in layout measurements" do
    font = Glyphic::TrueType::Font.allocate
    font.instance_variable_set(:@cmap, { 65 => 1, 86 => 2 })
    font.instance_variable_set(:@kern, { [1, 2] => -2 })
    font.instance_variable_set(:@size, 10.0)
    font.instance_variable_set(:@units_per_em, 10)
    font.instance_variable_set(:@glyph_cache, {})
    expect(font.kerning("A", "V")).to eq(-2.0)
  end

  it "flattens quadratic TrueType contours" do
    font = Glyphic::TrueType::Font.allocate
    font.instance_variable_set(:@size, 10.0)
    font.instance_variable_set(:@units_per_em, 10)

    points, ends = font.send(:flatten_contours, [[0, 0], [5, 10], [10, 0]], [1, 0, 1], [2])

    expect(points.length).to be > 3
    expect(ends).to eq([points.length - 1])
  end

  it "uses the nonzero winding rule for overlapping contours" do
    font = Glyphic::TrueType::Font.allocate
    alpha = font.send(
      :rasterize,
      [[0, 0], [10, 0], [10, 10], [0, 10], [3, 3], [7, 3], [7, 7], [3, 7]],
      [3, 7], 0, 0, 10, 10, 10, 10, 1.0
    )

    expect(alpha.getbyte(5 * 10 + 5)).to eq(255)
  end
end
