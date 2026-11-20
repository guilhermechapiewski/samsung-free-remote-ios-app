#!/bin/sh
# Build phase: keeps signing settings in Config/Local.xcconfig (git-ignored) and out of the project file.
#
# Fails if the project file sets DEVELOPMENT_TEAM or a literal PRODUCT_BUNDLE_IDENTIFIER. Xcode writes these
# when a team is picked in Signing & Capabilities (which its own "requires a development team" error
# suggests when Config/Local.xcconfig is missing); target-level values override the xcconfig files for
# everyone who builds the project.
project="$PROJECT_FILE_PATH/project.pbxproj"
if grep -nE 'DEVELOPMENT_TEAM = [^;"]+;|"?PRODUCT_BUNDLE_IDENTIFIER(\[[^]]*\])?"? = [^$"][^;]*;' "$project" >/dev/null; then
    echo "error: Signing settings were written into SamsungRemote.xcodeproj (DEVELOPMENT_TEAM or a fixed PRODUCT_BUNDLE_IDENTIFIER), probably by picking a team in Signing & Capabilities. Discard that change to the project file (git checkout SamsungRemote.xcodeproj) and set DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER in Config/Local.xcconfig instead (copy Config/Local.example.xcconfig)."
    exit 1
fi
