# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'rangeable'

# Test fixture markup tokens. Each one is a Struct with a tag symbol so two
# instances of the same fixture compare equal under Ruby's Struct equality
# (it inherits from Object#hash but Struct.new generates an `==` and `hash`
# from the field values).
Strong = Struct.new(:tag) unless defined?(Strong) && Strong.is_a?(Class)
Italic = Struct.new(:tag) unless defined?(Italic) && Italic.is_a?(Class)
Code   = Struct.new(:tag) unless defined?(Code) && Code.is_a?(Class)
Link   = Struct.new(:url) unless defined?(Link) && Link.is_a?(Class)

# Convenience builders so test bodies match the RFC narrative more closely.
module Fixtures
  def self.strong
    Strong.new(:strong)
  end

  def self.italic
    Italic.new(:italic)
  end

  def self.code
    Code.new(:code)
  end

  def self.link(url)
    Link.new(url)
  end
end
