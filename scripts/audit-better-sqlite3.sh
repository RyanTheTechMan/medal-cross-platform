#!/bin/zsh
set -eu

project_root=${0:A:h:h}
wrapper_root=${1:-$project_root/research/extracted-macos-m0/app/vendor/better-sqlite3}
source_root=${2:-$project_root/artifacts/better-sqlite3-source}
source_tag=v12.12.0
source_commit=38f111acfacced350ac17e62944ba9a4dbd176e5

if [[ ! -d $wrapper_root || ! -d $source_root/.git ]]; then
  print -u2 'usage: audit-better-sqlite3.sh [extracted-wrapper-directory] [public-source-checkout]'
  exit 2
fi

actual_commit=$(git -C "$source_root" rev-list -n 1 "$source_tag")
[[ $actual_commit == $source_commit ]] || {
  print -u2 "unexpected $source_tag commit: $actual_commit"
  exit 1
}

print "source_tag=$source_tag"
print "source_commit=$source_commit"
print "tag_signature=absent"

audit_result=0
while IFS= read -r wrapper_file; do
  relative_path=${wrapper_file#$wrapper_root/}
  vendor_hash=$(tr -d '\r' < "$wrapper_file" | shasum -a 256 | awk '{print $1}')
  source_hash=$(git -C "$source_root" show "${source_tag}:lib/$relative_path" 2>/dev/null | tr -d '\r' | shasum -a 256 | awk '{print $1}')
  if [[ $vendor_hash == $source_hash ]]; then
    print "MATCH $relative_path sha256=$vendor_hash"
  else
    print "DIFF $relative_path vendor=$vendor_hash source=$source_hash"
    audit_result=1
  fi
done < <(find "$wrapper_root" -type f | sort)

native_binary=$project_root/research/extracted-macos-m0/app/lib/binding/node-v148-win32-x64/better_sqlite3.node
binary_sqlite_version=$(strings -a "$native_binary" | rg -o '3\.[0-9]+\.[0-9]+' | head -n 1)
source_sqlite_version=$(git -C "$source_root" show "${source_tag}:deps/download.sh" | sed -n 's/^VERSION="\([0-9]*\)"/\1/p')
print "binary_sqlite_version=$binary_sqlite_version"
print "source_sqlite_amalgamation_version=$source_sqlite_version"
[[ $binary_sqlite_version == 3.53.3 && $source_sqlite_version == 3530300 ]] || audit_result=1

exit $audit_result
