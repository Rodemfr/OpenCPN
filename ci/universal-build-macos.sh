#!/usr/bin/env bash

set -x

# Install the stuff needed for upload to the Cloudsmith repository
# before messing w /usr/local
/usr/bin/python3 -m venv $HOME/cs-venv

#
# Build the OSX artifacts
#


# OpenCPN needs to support even older macOS releases than the system
# it is being built on, set MACOSX_DEPLOYMENT_TARGET environment
# variable to use the respective SDK version.
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}

# URL of the repository to download the dependency bundle from
export DEPS_BUNDLE_REPO="${DEPS_BUNDLE_REPO:-https://dl.cloudsmith.io/public/nohal/opencpn-dependencies/raw/files}"
# Name of the bundle
export DEPS_BUNDLE_FILE="${DEPS_BUNDLE_FILE:-macos_deps_universal-opencpn.tar.xz}"
# Where to unpack the bundle
export DEPS_BUNDLE_DEST="${DEPS_BUNDLE_DEST:-/usr/local}"
# What architecture(s) to build for
export ARCHS="${ARCHS:-arm64;x86_64}"
# Release component of the resulting package name
export RELEASE="${RELEASE:-universal}"

# Return latest installed brew version of given package
pkg_version() { brew list --versions $2 $1 | tail -1 | awk '{print $2}'; }


# Check if the cache is with us. If not, re-install brew.
brew list --versions python3 || {
    brew update-reset
    # As indicated by warning message in CircleCI build log:
    #git -C "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core" \
        #fetch --unshallow
    #git -C "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-cask" \
        #fetch --unshallow
}

#exit 0



# Install the build dependencies for OpenCPN
brew install cmake
brew install gettext
brew install create-dmg
brew install gpatch
brew install asciidoc

for pkg in python3  cmake ; do
    brew list --versions $pkg || brew install $pkg || brew install $pkg || :
    brew link --overwrite $pkg || :
done

# OpenCPN can be built against any wxWidgets version newer than 3.2.0
# but the resulting binary will (almost certainly) not be ABI compatible with 3rd party plugins
# For convenience and to save build time, we distribute a bundled build of wxWidgets.
# Note: For local builds it is completely OK to build against any other version of wxWidgets 3.2,
# for example installed from Homebrew, just keep in mind that such products should not be distributed
# as they will cause interoperability problems with plugins
if [ ! -f /tmp/${DEPS_BUNDLE_FILE} ]; then
    # Download only if we do not have the archive yet
    curl -k -o /tmp/${DEPS_BUNDLE_FILE} ${DEPS_BUNDLE_REPO}/${DEPS_BUNDLE_FILE}
fi
sudo mkdir -p ${DEPS_BUNDLE_DEST}
sudo tar -C ${DEPS_BUNDLE_DEST} -xJf /tmp/${DEPS_BUNDLE_FILE}

export PATH="/usr/local/opt/gettext/bin:$PATH"
echo 'export PATH="/usr/local/opt/gettext/bin:$PATH"' >> ~/.bash_profile

# Download and unzip documentation files
wget -nv -O QuickStartGuide.zip \
  "https://dl.cloudsmith.io/public/david-register/opencpn-docs/raw/files/QuickStartGuide-v0.4.zip"
mkdir -p data/doc/local
unzip QuickStartGuide.zip -d data/doc/local
sudo chmod -R +r data/doc/local

# Build, install and make package
mkdir -p build
cd build
test -n "$TRAVIS_TAG" && CI_BUILD=OFF || CI_BUILD=ON

# Make the build script fail if there are errors from now on
set -e

# Configure the build
cmake -DOCPN_CI_BUILD=$CI_BUILD \
  -DOCPN_VERBOSE=ON \
  -DOCPN_USE_LIBCPP=ON \
  -DCMAKE_INSTALL_PREFIX=/tmp/opencpn -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
  -DOCPN_RELEASE=${RELEASE} \
  -DOCPN_BUILD_TEST=OFF \
  -DOCPN_BUILD_SAMPLE=ON \
  -DOCPN_USE_DEPS_BUNDLE=ON \
  -DCMAKE_OSX_ARCHITECTURES="${ARCHS}" \
  -DOCPN_USE_SYSTEM_LIBARCHIVE=OFF \
  -DOCPN_DEPS_BUNDLE_PATH=${DEPS_BUNDLE_DEST} \
  -DwxWidgets_CONFIG_EXECUTABLE=${DEPS_BUNDLE_DEST}/lib/wx/config/osx_cocoa-unicode-3.2 \
  -DCMAKE_APPBUNDLE_PATH=${DEPS_BUNDLE_DEST} \
  -DwxWidgets_CONFIG_OPTIONS="--prefix=${DEPS_BUNDLE_DEST}" \
  ..

# Compile OpenCPN
make -j$(sysctl -n hw.physicalcpu)

# Make sure wx libraries are referenced using the symlinks

app="OpenCPN.app/Contents/MacOS/OpenCPN"
for lib in $(otool -L ${app} | grep libwx | cut -d' ' -f 1)
do
  newlib="$(echo $lib | sed 's/-3\.2.*\.dylib/-3.2.dylib/g')"
  echo "${lib} -> ${newlib}"
  install_name_tool -change ${lib} ${newlib} ${app}
done

# Create the package artifacts
mkdir -p /tmp/opencpn/bin/OpenCPN.app/Contents/MacOS
mkdir -p /tmp/opencpn/bin/OpenCPN.app/Contents/SharedSupport/plugins
make install
make install # Dunno why the second is needed but it is, otherwise
             # plugin data is not included in the bundle

# Make sure the code signatures are correct
if [ -z "${APPLE_DEVELOPER_ID}" ]; then
  # We do not have a paid Apple developer account, let's just reset the signatures
  codesign --force --deep --sign - /tmp/opencpn/bin/OpenCPN.app
else
  # We do have an account and did set up the certificates in ci/mac-sign.sh, let's sign the application bundle
  codesign --verbose --sign "${APPLE_DEVELOPER_ID}" --options=runtime --timestamp --options=runtime /tmp/opencpn/bin/OpenCPN.app/Contents/PlugIns/*.dylib
  codesign --deep --force --verbose --sign "${APPLE_DEVELOPER_ID}" --entitlements ../buildosx/entitlements.plist --timestamp --options=runtime /tmp/opencpn/bin/OpenCPN.app
fi

codesign -dv --verbose /tmp/opencpn/bin/OpenCPN.app

dsymutil -o OpenCPN.dSYM /tmp/opencpn/bin/OpenCPN.app/Contents/MacOS/OpenCPN
tar czf OpenCPN-$(git rev-parse --short HEAD).dSYM.tar.gz OpenCPN.dSYM

make create-pkg
if [[ ! -z "${CREATE_DMG+x}" ]]; then
  make create-dmg
fi

# Sign the installer if we have an Apple developer account set up
if [ -n "${APPLE_DEVELOPER_ID}" ]; then
  shopt -s nullglob
  for pkg_file in OpenCPN*.pkg; do
    productsign --sign "${APPLE_DEVELOPER_ID}" "${pkg_file}" pkg.signed
    mv pkg.signed "${pkg_file}"
  done
  # The resulting package has to be submitted to Apple for notarization
  # xcrun notarytool submit --apple-id <Apple id e-mail> --team-id <APPLE_DEVELOPER_ID> --password <Application specific password> <OpenCPN_*.pkg>
  # Once succesfully notarized, run the stapler to include the notarization ticket into the installer
  # xcrun stapler staple <OpenCPN_*.pkg>
fi

# The build is over, if there is error now it is not ours
set +e
