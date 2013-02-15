# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'observer/version'

Gem::Specification.new do |gem|
  gem.name          = "observer"
  gem.version       = Observer::VERSION
  gem.authors       = ["Francis Tseng"]
  gem.email         = ["ftzeng@gmail.com"]
  gem.description   = %q{A command line tool to watch a local folder and sync it to a remote location (ftp or sftp)}
  gem.summary       = %q{Monitor and sync local files to a server with ftp or sftp}
  gem.homepage      = "https://github.com/ftzeng/observer"

  s.add_runtime_dependency 'colored', '>= 1.2'
  s.add_runtime_dependency 'net-sftp', '>= 2.1.1'

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
end
