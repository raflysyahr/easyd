VCT — Video Compression Transfer v1.1.0
=======================================

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
VCT checks for zstd, sha256sum, curl, yt-dlp, ffmpeg, and ffprobe. Missing
packages are offered for installation using a supported package manager
(Termux pkg, apt-get, dnf, pacman, or apk). ffmpeg/ffprobe are used for direct
MPEG-DASH/MPD manifest URLs that return XML instead of a video file. Dependency
installation can be skipped; VCT can check/install dependencies again later.

Downloading MPEG-DASH / MPD
---------------------------
Choose Download video/file -> option 3 and paste the complete manifest URL,
even when it does not end with .mpd. VCT probes the available video
representations, lets you choose a quality, chooses the highest-bitrate audio
representation detected, then uses FFmpeg stream-copy (no re-encoding) to write
an MKV file. Signed URLs can expire or depend on server-side access conditions;
VCT does not bypass DRM or access restrictions.

Important note about compression
--------------------------------
Zstandard is lossless, so decompression restores the exact bytes of the file
that VCT compressed. Already-compressed video files (MP4, MKV, WebM) often
shrink only slightly or may grow. VCT keeps a .zst output only when it is smaller
than the source. Transfer both video.zst and video.zst.sha256, then use the VCT
restore menu on the receiving machine to decompress and verify the SHA-256.

MPD note
--------
An MPD manifest is not itself a single video file; it describes available
representations. Downloading an MPD with FFmpeg produces the selected video/audio
streams in an MKV container. The selected stream contents are copied without
re-encoding, but the MKV file is a newly assembled output, not byte-identical to
any original container that might have existed upstream. Subsequent Zstandard
compression/decompression preserves this generated MKV byte-for-byte.
