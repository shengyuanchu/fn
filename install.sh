#!/bin/sh

set -eu

repository="shengyuanchu/fn"
install_dir="${FN_INSTALL_DIR:-${HOME}/.local/bin}"
version="${FN_VERSION:-latest}"

case "$(uname -s)" in
  Darwin) operating_system="macos" ;;
  Linux) operating_system="linux" ;;
  *) echo "fn: unsupported operating system" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) architecture="x86_64" ;;
  arm64|aarch64) architecture="aarch64" ;;
  *) echo "fn: unsupported architecture" >&2; exit 1 ;;
esac

archive="fn-${operating_system}-${architecture}.tar.gz"
if [ "$version" = "latest" ]; then
  release_url="https://github.com/${repository}/releases/latest/download"
else
  release_url="https://github.com/${repository}/releases/download/${version}"
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

curl -fsSL "${release_url}/${archive}" -o "${temporary_dir}/${archive}"
curl -fsSL "${release_url}/${archive}.sha256" -o "${temporary_dir}/${archive}.sha256"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$temporary_dir" && sha256sum -c "${archive}.sha256")
else
  (cd "$temporary_dir" && shasum -a 256 -c "${archive}.sha256")
fi

tar -xzf "${temporary_dir}/${archive}" -C "$temporary_dir"
mkdir -p "$install_dir"
install -m 755 "${temporary_dir}/fn" "${install_dir}/fn"

echo "Installed fn to ${install_dir}/fn"
