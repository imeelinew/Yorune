#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number> [target]"
    exit 64
fi

version="$1"
build="$2"
target="${3:-Yorune}"
project_file="${0:A:h:h}/Yorune.xcodeproj/project.pbxproj"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "Invalid marketing version: $version"
    exit 64
fi
if [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Build number must be a positive integer: $build"
    exit 64
fi

ruby - "$project_file" "$version" "$build" "$target" <<'RUBY'
path, version, build, target = ARGV
contents = File.binread(path)

target_pattern = /^\s*[A-F0-9]{24} \/\* #{Regexp.escape(target)} \*\/ = \{\n\s*isa = PBXNativeTarget;.*?^\s*buildConfigurationList = ([A-F0-9]{24})/m
target_match = contents.match(target_pattern)
abort "Target not found: #{target}" unless target_match

configuration_list_id = target_match[1]
configuration_list_pattern = /^\s*#{configuration_list_id} \/\*[^\n]*\*\/ = \{\n\s*isa = XCConfigurationList;\n\s*buildConfigurations = \((.*?)\);/m
configuration_list_match = contents.match(configuration_list_pattern)
abort "Build configuration list not found for target: #{target}" unless configuration_list_match

configuration_ids = configuration_list_match[1].scan(/^\s*([A-F0-9]{24}) \/\*[^\n]*\*\//).flatten
abort "No build configurations found for target: #{target}" if configuration_ids.empty?

updated = contents.dup
configuration_ids.each do |configuration_id|
  configuration_pattern = /^\s*#{configuration_id} \/\*[^\n]*\*\/ = \{\n\s*isa = XCBuildConfiguration;\n\s*buildSettings = \{\n.*?^\s*\};\n\s*name = [^;]+;\n\s*\};\n/m
  configuration_match = updated.match(configuration_pattern)
  abort "Build configuration not found: #{configuration_id}" unless configuration_match

  configuration = configuration_match[0]
  marketing_count = configuration.scan(/^\s*MARKETING_VERSION = [^;]+;\s*$/).length
  build_count = configuration.scan(/^\s*CURRENT_PROJECT_VERSION = [^;]+;\s*$/).length
  abort "Unexpected MARKETING_VERSION entry count in #{configuration_id}: #{marketing_count}" unless marketing_count == 1
  abort "Unexpected CURRENT_PROJECT_VERSION entry count in #{configuration_id}: #{build_count}" unless build_count == 1

  configuration.sub!(/^(\s*)MARKETING_VERSION = [^;]+;$/, "\\1MARKETING_VERSION = #{version};")
  configuration.sub!(/^(\s*)CURRENT_PROJECT_VERSION = [^;]+;$/, "\\1CURRENT_PROJECT_VERSION = #{build};")
  updated[configuration_match.begin(0)...configuration_match.end(0)] = configuration
end

File.binwrite(path, updated)
RUBY

print "${target} version set to ${version} (${build})"
