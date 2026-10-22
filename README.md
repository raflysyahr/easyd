VCT — Video Compression Transfer
================================

Files
-----
vct.sh         Main menu-driven Bash application.
vct-install.sh Self-contained installer. It embeds the exact vct.sh payload,
               installs it as ~/.local/bin/vct, and offers dependency installation.

Local usage
-----------
chmod +x vct.sh
./vct.sh

Install from a local checkout
-----------------------------
./vct.sh --install

Remote one-line installer
-------------------------
1. Upload vct-install.sh to a PUBLIC GitHub repository and commit/push it.
2. Replace USERNAME, REPOSITORY, and BRANCH in this command with your details:

   curl -fsSL https://github.com/USERNAME/REPOSITORY/raw/refs/heads/BRANCH/vct-install.sh | bash

The remote URL must point to the published vct-install.sh. The URL in the example
above is a template; this package has not been uploaded to GitHub automatically.

After installation
------------------
Run:
  ~/.local/bin/vct

If ~/.local/bin is already on PATH, you can run:
  vct

If needed, add the following line to ~/.bashrc (or ~/.zshrc):
  export PATH="$HOME/.local/bin:$PATH"

Dependency handling
-------------------
The installer checks for zstd, sha256sum, curl, and yt-dlp. If any are missing,
it offers to install them using a supported package manager (Termux pkg, apt-get,
dnf, pacman, or apk). Dependency installation can be skipped; VCT will still be
installed, and can check/install dependencies again when run.

Optional environment settings:
  VCT_INSTALL_DIR=/custom/path   Select an install directory.
  VCT_INSTALL_DEPS=0             Skip dependency installation.
  VCT_INSTALL_DEPS=1             Attempt dependency installation without asking.
  VCT_YES=1                      Automatically confirm installer prompts.

Important note about compression
--------------------------------
Zstandard is lossless, so decompression restores the exact file bytes. Already-
compressed video files (MP4, MKV, WebM) often shrink only slightly or may grow.
VCT keeps a .zst output only when it is smaller than the source. Transfer both
video.zst and video.zst.sha256, then use the VCT restore menu on the receiving
machine to decompress and verify the SHA-256.
