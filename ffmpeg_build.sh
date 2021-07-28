#!/bin/bash

set -e
set -u

# Set to 1 to build ffmpeg for deployment in docker
declare -i DOCKER_BUILD=1

declare -r SCRIPT_DIR=$(dirname ${BASH_SOURCE[0]})
declare -r FFMPEGROOT="$(realpath $SCRIPT_DIR)"
declare -r SRC="$FFMPEGROOT/src"
declare -r BUILD="$FFMPEGROOT/build"
declare -r BIN="$FFMPEGROOT/bin"

PATH=${PATH-"/usr/bin"}
PKG_CONFIG_PATH=${PKG_CONFIG_PATH-"/usr/lib/pkgconfig"}
export PATH=$BIN:$PATH
export PKG_CONFIG_PATH="$BUILD/lib/pkgconfig:$PKG_CONFIG_PATH" 

###############
# get sources #
###############

declare -r TAG_MP3="3.100"

declare -r GIT_FFMPEG="https://github.com/FFmpeg/FFmpeg"
declare -r GIT_X264="https://code.videolan.org/videolan/x264.git"
declare -r GIT_X265="https://bitbucket.org/multicoreware/x265_git.git"
declare -r GIT_AAC="https://github.com/mstorsjo/fdk-aac"
declare -r URL_MP3="https://downloads.sourceforge.net/project/lame/lame/$TAG_MP3/lame-$TAG_MP3.tar.gz"
declare -r GIT_NASM="https://github.com/netwide-assembler/nasm.git"
declare -r GIT_OPENSSL="https://github.com/openssl/openssl"

declare -r SRC_FFMPEG="$SRC/ffmpeg"
declare -r SRC_X264="$SRC/x264"
declare -r SRC_X265="$SRC/x265"
declare -r SRC_AAC="$SRC/aac"
declare -r SRC_MP3="$SRC/mp3"
declare -r SRC_NASM="$SRC/nasm"
declare -r SRC_OPENSSL="$SRC/openssl"

mkdir -p $SRC
mkdir -p $BUILD
mkdir -p $BIN

# ffmpeg
if [[ ! -d $SRC_FFMPEG ]]
then
    git clone $GIT_FFMPEG $SRC_FFMPEG
fi

# libx264
if [[ ! -d $SRC_X264 ]]
then
    git clone --depth 1 --no-single-branch $GIT_X264 $SRC_X264
fi

# libx265
if [[ ! -d $SRC_X265 ]]
then
    git clone $GIT_X265 $SRC_X265
fi

# libfdk_aac
if [[ ! -d $SRC_AAC ]]
then
    git clone $GIT_AAC $SRC_AAC
fi

# libmp3lame
if [[ ! -d $SRC_MP3 ]]
then
    curl -sL $URL_MP3  | tar xvzf - --transform="s|^lame-$TAG_MP3|$SRC_MP3|g" -C /
fi

#nasm
if [[ ! -d $SRC_NASM ]]
then
    git clone $GIT_NASM $SRC_NASM
fi

#openssl
if [[ ! -d $SRC_OPENSSL ]]
then
    git clone $GIT_OPENSSL $SRC_OPENSSL
fi

##############
# BUILD NASM #
##############

pushd $SRC_NASM
latest=$(git tag | grep ^nasm | grep -v rc | sort | tail -1)
git reset --hard $latest
./autogen.sh
./configure \
    --prefix="$BUILD"   \
    --bindir="$BIN"
make
#make install

# disabled make install as following dependencies are not met:
# make install --> nasm.1 --> make manpages --> asciidoc
# asciidoc is not installed and requires 2GB of disk space
# copy the binaries directly
/usr/bin/install -c nasm $BIN/nasm
/usr/bin/install -c ndisasm $BIN/ndisasm

popd

#################
# BUILD openssl #
#################

pushd $SRC_OPENSSL
latest=$(git tag | grep ^OpenSSL_[123456789] | grep -v "-" | tail -1)
git reset --hard $latest
./config \
    --prefix=$BUILD \
    no-shared \
    no-tests \
    enable-zlib
make
make install_sw
popd

##############
# BUILD x264 #
##############

pushd "$SRC_X264"
git checkout stable
./configure         \
    --prefix="$BUILD"   \
    --bindir="$BIN"     \
    --enable-static     \
    --enable-pic
make
make install
popd

##############
# BUILD x265 #
##############

pushd "$SRC_X265/build/linux"
latest=$(git tag | grep -v _ | sort | tail -1)
git reset --hard $latest
cmake \
    -G "Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX="$BUILD" \
    -DENABLE_SHARED:bool=off \
    ../../source
make
make install
popd


#################
# BUILD fdk-aac #
#################

pushd $SRC_AAC
latest=$(git tag | grep ^v | sort | tail -1)
git reset --hard $latest
autoreconf -fiv
./configure \
    --prefix="$BUILD" \
    --disable-shared
make
make install
popd

#############
# build mp3 #
#############

pushd $SRC_MP3
./configure \
    --prefix="$BUILD" \
    --bindir="$BIN" \
    --disable-shared \
    --enable-nasm
make
make install
popd

################
# build ffmpeg #
################

pushd $SRC_FFMPEG
latest=$(git tag | grep ^n | grep -v dev | sort | tail -n 1)
git reset --hard $latest

# minimal options
declare -i MINI_BUILD=0
declare -r VID_DECODERS="mpeg2video,h264,rawvideo"
declare -r VID_ENCODERS="mpeg2video,libx264,rawvideo"
declare -r AUD_DECODERS="mp2,aac,libfdk_aac,ac3,pcm_s16le,pcm_s32le"
declare -r AUD_ENCODERS="$AUD_DECODERS"
declare -r DEMUXERS="mpegts,mov,mxf,h264,mpegvideo,rawvideo,wav,aac,ac3,pcm_s16le,pcm_s32le"
declare -r MUXERS="mpegts,mov,mp4,mxf,mpeg2video,rawvideo,wav,mp2,aac,ac3,pcm_s16le,pcm_s32le"
declare -r PROTOCOLS="file,pipe,udp"
declare -r PARSERS="h264,aac,ac3,mpegvideo,mpegaudio"
declare -r FILTERS="scale,amix,aresample"

declare -r MINI_OPTS=$(echo \
    --disable-all                                               \
    --enable-ffmpeg                                             \
    --enable-avcodec                                            \
    --enable-avformat                                           \
    --enable-avfilter                                           \
    --enable-swresample                                         \
    --enable-swscale                                            \
    --enable-decoder=${VID_DECODERS},${AUD_DECODERS}            \
    --enable-encoder=${VID_ENCODERS},${AUD_ENCODERS}            \
    --enable-parser=${PARSERS}                                  \
    --enable-protocol=${PROTOCOLS}                              \
    --enable-demuxer=${DEMUXERS}                                \
    --enable-muxer=${MUXERS}                                    \
    --enable-filter=${FILTERS}                                  \
    )

declare -r DOCKER_BUILD_OPTS=$(echo \
    --disable-ffplay                                            \
    --disable-libxcb                                            \
    --disable-libxcb-shm                                        \
    --disable-libxcb-xfixes                                     \
    --disable-libxcb-shape                                      \
    --disable-alsa                                              \
    --disable-indev=alsa                                        \
    --disable-outdev=alsa                                       \
    --disable-sdl2                                              \
    --disable-sndio                                             \
    --disable-xlib                                              \
    )

declare -r DEFAULT_OPTS=$(echo \
    --prefix="$BUILD"                                           \
    --pkg-config-flags="--static"                               \
    --extra-cflags="-I$BUILD/include"                           \
    --extra-cxxflags="-I$BUILD/include"                         \
    --extra-ldflags="-L$BUILD/lib"                              \
    --extra-libs=-lpthread                                      \
    --extra-libs=-lm                                            \
    --bindir="$BIN"                                             \
    --enable-openssl                                            \
    --enable-gpl                                                \
    --enable-nonfree                                            \
    --enable-libx264                                            \
    --enable-libx265                                            \
    --enable-libfdk_aac                                         \
    --enable-libmp3lame                                         \
    )

if [[ $MINI_BUILD -eq 1 ]]
then
    BUILD_OPTS="${DEFAULT_OPTS} ${MINI_OPTS}"
elif [[ $DOCKER_BUILD -eq 1 ]]
then
    BUILD_OPTS="${DEFAULT_OPTS} ${DOCKER_BUILD_OPTS}"
else
    BUILD_OPTS="${DEFAULT_OPTS}"
fi

echo $BUILD_OPTS

./configure  ${BUILD_OPTS}
make
make install
popd

$BIN/ffmpeg -version
$BIN/ffmpeg -buildconf
$BIN/ffmpeg -formats
$BIN/ffmpeg -devices
$BIN/ffmpeg -codecs
$BIN/ffmpeg -decoders
$BIN/ffmpeg -encoders
$BIN/ffmpeg -bsfs
$BIN/ffmpeg -protocols
$BIN/ffmpeg -filters
$BIN/ffmpeg -layouts

du -h $BIN/ffmpeg

echo done

