#!/usr/bin/env bash
# Builds the lab system generation from the generations the lab repositories publish, verifies it and publishes it as
# an OCI artifact with the engines' layout (devos-dotnet-intelligence docs/USAGE.md, "Publishing the generation (OCI)";
# devos-intelligence-federation docs/PUBLISHING.md). Needs Docker and jq; runs the same in CI and on a workstation.
#
#   TARGET   repository of the system generation, for example ghcr.io/albertomitroi/context-devos-lab (required)
#   PUSH     true: push to TARGET as system-<key> and main-system; anything else: write an OCI layout under
#            $WORK/oci instead (dry run, default)
#   REGISTRY_USER, REGISTRY_TOKEN   credentials for the push (the inputs are public and pulled anonymously)
#   FEDERATION_IMAGE, ORAS_IMAGE    pinned defaults below
#   WORK     work directory (default .system-context, removed at start)
#
# <key> is the SHA-256 of the system generation's input commit (`system:` over every input's name, commit and
# manifest digest), its configuration hash (system.yml) and the federation version: the same key means the same
# inputs, configuration and federation, hence the same bytes. An existing system-<key> tag with other content stops
# the run instead of being overwritten.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:?set TARGET, for example ghcr.io/albertomitroi/context-devos-lab}"
lower() { tr '[:upper:]' '[:lower:]'; }
TARGET="$(printf '%s' "$TARGET" | lower)"
PUSH="${PUSH:-false}"
FEDERATION_IMAGE="${FEDERATION_IMAGE:-ghcr.io/albertomitroi/intelligence-federation:0.1.0}"
ORAS_IMAGE="${ORAS_IMAGE:-ghcr.io/oras-project/oras:v1.3.6@sha256:9cfb578be975b762fd898b9d004243d8003aeb807a3e15b2ed212cdd1326c9eb}"
work="${WORK:-$root/.system-context}"
user="$(id -u):$(id -g)"
ARTIFACT_TYPE=application/vnd.devos.intelligence.generation.v1
LAYER_TYPE=application/vnd.devos.intelligence.generation.v1.tar+gzip

step() { printf '\n== %s\n' "$*"; }
# Without -i: inside the input loop a container must not read the loop's stdin.
oras() { docker run --rm --user "$user" -e HOME=/tmp -v "$work:/work" -w /work "$ORAS_IMAGE" "$@"; }
oras_auth() { printf '%s' "$REGISTRY_TOKEN" | docker run --rm -i --user "$user" -e HOME=/tmp -v "$work:/work" -w /work "$ORAS_IMAGE" "$@" -u "$REGISTRY_USER" --password-stdin; }
federation() { docker run --rm --network none --user "$user" "$@"; }

rm -rf "$work"
mkdir -p "$work/pull" "$work/inputs" "$work/out"

step "federation image"
# Pulled in CI; a local image of the same name (a dry run before the release) is used as is.
docker pull -q "$FEDERATION_IMAGE" >/dev/null 2>&1 || docker image inspect "$FEDERATION_IMAGE" >/dev/null
federation_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$FEDERATION_IMAGE" 2>/dev/null || echo unknown)"
echo "$FEDERATION_IMAGE ($federation_digest)"

step "inputs"
inputs=()
pinned=()
while IFS=$'\t' read -r name ref; do
  [ "$ref" != "-" ] || { echo "generation $name has no oci reference in system.yml" >&2; exit 2; }
  ref="$(printf '%s' "$ref" | lower)"
  digest="$(oras resolve "$ref")"
  oras manifest fetch "${ref%:*}@$digest" > "$work/pull/$name.manifest.json"
  expected="$(jq -r '.layers[0].annotations["dev.devos.intelligence.manifest-sha256"] // empty' "$work/pull/$name.manifest.json")"
  oras pull -o "pull/$name" "${ref%:*}@$digest" >/dev/null
  mkdir -p "$work/inputs/$name"
  tar -xzf "$work/pull/$name/generation.tar.gz" -C "$work/inputs/$name"
  actual="$(sha256sum "$work/inputs/$name/manifest.json" 2>/dev/null | cut -d ' ' -f 1 || shasum -a 256 "$work/inputs/$name/manifest.json" | cut -d ' ' -f 1)"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "$name: manifest.json sha256 $actual does not match the layer annotation '$expected'" >&2; exit 1; }
  echo "$name  ${ref%:*}@$digest  manifest $actual"
  inputs+=(--input "$name=/generations/$name")
  pinned+=("$name=${ref%:*}@$digest")
done < <(federation -v "$root:/config:ro" "$FEDERATION_IMAGE" list-inputs --system /config/system.yml </dev/null)

step "federate"
federation -e "FEDERATION_IMAGE_DIGEST=$federation_digest" \
  -v "$work/inputs:/generations:ro" -v "$root:/config:ro" -v "$work/out:/out" \
  "$FEDERATION_IMAGE" federate --system /config/system.yml --out /out/system "${inputs[@]}"

step "verify"
federation -v "$work/inputs:/generations:ro" -v "$work/out:/out:ro" "$FEDERATION_IMAGE" verify /out/system "${inputs[@]}"

step "pack"
manifest="$work/out/system/manifest.json"
status="$(jq -r .status "$manifest")"
[ "$status" != failed ] || { echo "system generation status is failed" >&2; exit 1; }
# A system generation with an excluded input is not published: it would replace main-system with less.
excluded="$(jq -r '[.inputs[] | select(.included | not) | .name] | join(", ")' "$manifest")"
[ -z "$excluded" ] || { echo "inputs excluded by verification: $excluded (see inputs.ndjson); not publishing" >&2; exit 1; }
key="$(jq -r '[.commit, .configurationHash, (.engine.name + "@" + .engine.version)] | join("\n")' "$manifest" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d ' ' -f 1)"
tag="system-$key"
manifest_sha="$({ sha256sum "$manifest" 2>/dev/null || shasum -a 256 "$manifest"; } | cut -d ' ' -f 1)"
# Same generation, same bytes: sorted entries, fixed times and owners, no gzip timestamp (GNU tar of the image).
docker run --rm --network none --user "$user" --entrypoint sh -v "$work/out:/out" "$FEDERATION_IMAGE" -c \
  'tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C /out/system -cf - . | gzip -n > /out/generation.tar.gz'
mv "$work/out/generation.tar.gz" "$work/generation.tar.gz"
revision="${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}"
source="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-AlbertoMitroi/devos-lab}"
jq -n --arg source "$source" --arg revision "$revision" --arg ref "${GITHUB_REF:-refs/heads/main}" \
  --arg system "$(jq -r .commit "$manifest")" --arg inputs "${pinned[*]}" --arg image "$federation_digest" \
  --arg manifest "$manifest_sha" \
  '{"$manifest": {"org.opencontainers.image.source": $source, "org.opencontainers.image.revision": $revision,
                  "org.opencontainers.image.ref.name": $ref, "dev.devos.intelligence.engine": "intelligence-federation",
                  "dev.devos.intelligence.system-commit": $system, "dev.devos.intelligence.inputs": $inputs,
                  "dev.devos.intelligence.federation-image": $image},
    "generation.tar.gz": {"dev.devos.intelligence.manifest-sha256": $manifest}}' > "$work/annotations.json"
echo "status $status, tag $tag, manifest.json sha256 $manifest_sha"

step "publish"
push_args=(--artifact-type "$ARTIFACT_TYPE" --annotation-file annotations.json "generation.tar.gz:$LAYER_TYPE")
if [ "$PUSH" = true ]; then
  if existing="$(oras_auth manifest fetch "$TARGET:$tag" 2>/dev/null)"; then
    previous="$(printf '%s' "$existing" | jq -r '.layers[0].annotations["dev.devos.intelligence.manifest-sha256"] // empty')"
    [ "$previous" = "$manifest_sha" ] || { echo "$TARGET:$tag exists with manifest.json sha256 $previous, not $manifest_sha: refusing to overwrite" >&2; exit 1; }
    echo "$TARGET:$tag already holds this system generation; moving main-system only"
    oras_auth tag "$TARGET:$tag" main-system
  else
    oras_auth push "$TARGET:$tag,main-system" "${push_args[@]}"
  fi
  digest="$(oras_auth resolve "$TARGET:$tag")"
  where="$TARGET:$tag ($digest), main-system"
else
  oras push --oci-layout "oci:$tag" "${push_args[@]}" >/dev/null
  digest="$(oras resolve --oci-layout "oci:$tag")"
  where="OCI layout $work/oci:$tag ($digest); not pushed (PUSH=$PUSH)"
fi
echo "$where"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "tag=$tag"; echo "digest=$digest"; echo "status=$status"; } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### System generation"
    echo "- Published: $where"
    echo "- Status: $status, system commit $(jq -r .commit "$manifest")"
    echo "- Inputs:"
    for p in "${pinned[@]}"; do echo "  - \`$p\`"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi
