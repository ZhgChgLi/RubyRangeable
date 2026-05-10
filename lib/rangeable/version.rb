# frozen_string_literal: true

# Defined as a class because the main `Rangeable` symbol in `rangeable.rb` is
# a class. We declare it the same way here so that requiring this file
# alone (e.g. from the gemspec) does not lock the symbol into being a
# module.
class Rangeable
  VERSION = '2.0.0'
end
