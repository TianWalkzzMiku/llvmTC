#!/usr/bin/env bash

# Secret Variables for CI
# LLVM_NAME | Your desired Toolchain Name
# TG_TOKEN | Your Telegram Bot Token
# TG_CHAT_ID | Your Telegram Channel / Group Chat ID
# GH_TOKEN | Your Github Token
# GH_EMAIL | Your Email Address
# GH_USERNAME | Your Username Github
# GH_PUSH_REPO_URL | Repo Push URL Github Here
# GH_PUSH_REPO_SCRIPT | Script URL Github

# Directory where LLVM toolchain is installed
INSTALL_DIR="/home/runner/work/llvmTC/llvmTC/install"

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Inlined function to post a message
export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
tg_post_msg() {
    curl -s -X POST "$BOT_MSG_URL" -d chat_id="$TG_CHAT_ID" \
    -d "disable_web_page_preview=true" \
    -d "parse_mode=html" \
    -d text="$1"
}

tg_post_build() {
    curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
    -F chat_id="$TG_CHAT_ID"  \
    -F "disable_web_page_preview=true" \
    -F "parse_mode=html" \
    -F caption="$3"
}

# Build Info
rel_date="$(date "+%Y%m%d")" # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
builder_commit="$(git rev-parse HEAD)"

# Send a notification to TG
tg_post_msg "<b>$LLVM_NAME: Toolchain Compilation Started</b>%0A<b>Date : </b><code>$rel_friendly_date</code>%0A<b>Toolchain Script Commit : </b><code>$builder_commit</code>%0A"

# Build LLVM
msg "$LLVM_NAME: Building LLVM..."
tg_post_msg "<b>$LLVM_NAME: Building LLVM. . .</b>"
TomTal=$(nproc)
if [[ ! -z "${2}" ]]; then
    TomTal=$(($TomTal*2))
fi

# Ensure LLVM binaries directory is in PATH
export PATH="$INSTALL_DIR/bin:$PATH"

./build-llvm.py \
    --clang-vendor "$LLVM_NAME" \
    --targets "ARM;AArch64;X86" \
    --defines "LLVM_PARALLEL_COMPILE_JOBS=$TomTal LLVM_PARALLEL_LINK_JOBS=$TomTal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3'" \
    --no-ccache \
    --shallow-clone \
    --branch "main" 2>&1 | tee build.log

# Check if the final clang binary exists or not
if [[ ! -f "$INSTALL_DIR/bin/clang-1"* ]]; then
    err "Building LLVM failed! Kindly check errors!!"
    tg_post_build "build.log" "$TG_CHAT_ID" "Error Log"
    exit 1
fi

# Build binutils
msg "$LLVM_NAME: Building binutils..."
tg_post_msg "<b>$LLVM_NAME: Building Binutils. . .</b>"
./build-binutils.py --targets arm aarch64 x86_64

# Remove unused products
rm -fr "$INSTALL_DIR/include"
rm -f "$INSTALL_DIR/lib"/*.a "$INSTALL_DIR/lib"/*.la

# Strip remaining products
find "$INSTALL_DIR" -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}' | xargs -I{} strip -s {}

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
find "$INSTALL_DIR" -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}' | xargs -I{} patchelf --set-rpath "$INSTALL_DIR/lib" {}

# Release Info
cd llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
cd ..

llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$("$INSTALL_DIR/bin/clang" --version | head -n1 | cut -d' ' -f4)"

tg_post_msg "<b>$LLVM_NAME: Toolchain compilation Finished</b>%0A<b>Clang Version : </b><code>$clang_version</code>%0A<b>LLVM Commit : </b><code>$llvm_commit_url</code>%0A<b>Binutils Version : </b><code>$binutils_ver</code>"

# Push to GitHub
# Update Git repository
git config --global user.email "$GH_EMAIL"
git config --global user.name "$GH_USERNAME"
git clone "https://$GH_USERNAME:$GH_TOKEN@$GH_PUSH_REPO_URL" rel_repo
cd rel_repo || exit
rm -fr ./*
cp -r "$INSTALL_DIR"/* .
git checkout README.md # keep this as it's not part of the toolchain itself
git add .
git commit -asm "$LLVM_NAME: Bump to $rel_date build

LLVM commit: $llvm_commit_url
Clang Version: $clang_version
Binutils version: $binutils_ver
Builder commit: https://$GH_PUSH_REPO_SCRIPT/commit/$builder_commit"
git push -f
cd ..
tg_post_msg "<b>$LLVM_NAME: Toolchain pushed to <code>https://$GH_PUSH_REPO_URL</code></b>"
