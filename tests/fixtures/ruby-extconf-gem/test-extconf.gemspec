Gem::Specification.new do |s|
  s.name        = "test-extconf"
  s.version     = "1.0.0"
  s.summary     = "Test fixture: extconf.rb writes marker during install"
  s.authors     = ["test"]
  s.files       = ["lib/test_ext.rb"]
  s.extensions  = ["ext/test_ext/extconf.rb"]
  s.license     = "MIT"
end
