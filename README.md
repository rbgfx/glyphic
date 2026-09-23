# Glyphic

[![Gem version](https://badge.fury.io/rb/glyphic.svg)](https://rubygems.org/gems/glyphic)
[![Downloads](https://img.shields.io/gem/dt/glyphic?label=downloads)](https://rubygems.org/gems/glyphic)
[![CI](https://github.com/rbgfx/glyphic/actions/workflows/main.yml/badge.svg)](https://github.com/rbgfx/glyphic/actions/workflows/main.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-MIT-750014.svg)](LICENSE.txt)

> Bitmap and outline font rendering for Ruby graphics.

Glyphic loads BDF bitmap fonts and TrueType outlines, measures UTF-8 text, and
draws it onto Tessel RGBA8 images.

**[Features](#features) · [Installation](#installation) · [Quick start](#quick-start) · [Development](#development)**

## Features

- BDF bitmap font loading.
- TrueType (.ttf) outline loading and rasterization.
- UTF-8 text measurement, wrapping, and text boxes.
- Fallback chains for missing glyphs.
- Direct rendering into Tessel images.
- A built-in font for examples and tools.

## Installation

Add Glyphic to your Gemfile:

~~~ruby
gem "glyphic"
~~~

Then run:

~~~sh
bundle install
~~~

Or install the released gem:

~~~sh
gem install glyphic
~~~

## Quick start

~~~ruby
require "glyphic"
require "tessel"

font = Glyphic.default
image = Tessel::Image.new(240, 40, fill: "#101827")
font.draw(image, 4, 4, "Hello, rbgfx", color: "#ffffff")
image.write("hello.png")
~~~

Load an external font with <code>Glyphic.load(path)</code>. BDF and TrueType
fonts are supported; CFF/OpenType outlines are currently unsupported.

## Development

~~~sh
bundle install
bundle exec rake verify
~~~

## License

[MIT](LICENSE.txt)
