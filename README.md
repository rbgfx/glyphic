<h1 align="center">Glyphic</h1>

<p align="center">Bitmap and outline font rendering for Ruby graphics.</p>

<p align="center">
  <a href="https://rubygems.org/gems/glyphic"><img src="https://badge.fury.io/rb/glyphic.svg" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/glyphic"><img src="https://img.shields.io/gem/dt/glyphic?label=downloads" alt="Downloads"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby Version"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-750014.svg" alt="License"></a>
</p>

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start)

***

Glyphic loads BDF bitmap fonts and TrueType outlines, measures UTF-8 text, and draws it onto Tessel RGBA8 images.

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

### Requirements

- Ruby 3.1 or newer.
- Tessel is installed automatically as a runtime dependency.

## Quick Start

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

## Contributing

Bug reports and pull requests are welcome at [rbgfx/glyphic](https://github.com/rbgfx/glyphic).

## License

[MIT](LICENSE.txt)
