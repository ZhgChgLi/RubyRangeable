# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rangeable/version'

Gem::Specification.new do |spec|
  spec.name          = 'rangeable'
  spec.version       = Rangeable::VERSION
  spec.authors       = ['ZhgChgLi']
  spec.email         = ['zhgchgli@gmail.com']

  spec.summary       = 'Hashable-element interval set with first-insert ordered active queries.'
  spec.description   = <<~DESC
    Rangeable is a language-neutral, generic, integer-coordinate closed-interval
    set container. It pairs hashable elements with their merged disjoint integer
    ranges and answers three queries: by-element ranges, by-position active set,
    and by-range transition events. The Ruby reference implementation follows
    the Rangeable RFC normatively, including idempotent containment fast-path,
    lazy boundary-event indexing, and first-insert deterministic ordering.
  DESC
  spec.homepage      = 'https://github.com/ZhgChgLi/RubyRangeable'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.metadata = {
    'homepage_uri'          => 'https://github.com/ZhgChgLi/RubyRangeable',
    'source_code_uri'       => 'https://github.com/ZhgChgLi/RubyRangeable',
    'bug_tracker_uri'       => 'https://github.com/ZhgChgLi/RubyRangeable/issues',
    'changelog_uri'         => 'https://github.com/ZhgChgLi/RubyRangeable/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/ZhgChgLi/RangeableRFC/blob/main/RFC.md',
    'rubygems_mfa_required' => 'true'
  }

  spec.files         = Dir['lib/**/*.rb', 'README.md', 'CHANGELOG.md', 'LICENSE']
  spec.require_paths = ['lib']

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake',     '~> 13.0'
end
