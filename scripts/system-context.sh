#!/usr/bin/env bash
# Builds the lab system generation from the generations the lab repositories publish, verifies it and publishes it as
# an OCI artifact with the engines' layout (devos-dotnet-intelligence docs/USAGE.md, "Publishing the generation (OCI)";
# devos-intelligence-federation docs/PUBLISHING.md). Needs Docker and jq; runs the same in CI and on a workstation.
#
#   TARGET   package of system generations (required), for example ghcr.io/albertomitroi/context-systems
#   PUSH     true: push to TARGET; anything else: write an OCI layout under $WORK/oci instead (dry run, default)
#   REGISTRY_USER, REGISTRY_TOKEN   credentials for the push (the inputs are public and pulled anonymously)
#   FEDERATION_IMAGE, ORAS_IMAGE    pinned defaults below
#   WORK     work directory (default .system-context, removed at start)
#
# Tags, all on one manifest (<system> is the name in system.yml):
#   <system>-<64 hex>                  immutable: <key>, the SHA-256 of the system generation's input commit
#                                      (`system:` over every input's name, commit and manifest digest), its
#                                      configuration hash (system.yml) and the federation's name@version, joined by
#                                      newlines: the same key means the same inputs, configuration and federation
#   <system>-main                      moving: the newest system generation
#   <system>.<repository>.<40 hex>     one per input: its repository name and commit, so a working copy finds the
#                                      system that contains its commit with a single tag listing; moves to the newest
#                                      system generation that contains that commit
# An existing <system>-<key> whose manifest.json differs stops the run: the immutable tag is never overwritten (with
# deterministic federation it cannot happen; it would mean a nondeterministic run).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:?set TARGET, for example ghcr.io/albertomitroi/context-systems}"
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
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "$name: manifest.json sha256 $actual does not match the layer annotation '$expected'" >&2
    exit 1
  fi
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
# A system generation with an excluded input is not published: it would replace <system>-main with less.
excluded="$(jq -r '[.inputs[] | select(.included | not) | .name] | join(", ")' "$manifest")"
[ -z "$excluded" ] || { echo "inputs excluded by verification: $excluded (see inputs.ndjson); not publishing" >&2; exit 1; }
system="$(jq -r .system "$manifest")"
system_commit="$(jq -r .commit "$manifest")"
key="$(jq -r '[.commit, .configurationHash, (.engine.name + "@" + .engine.version)] | join("\n")' "$manifest" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d ' ' -f 1)"
tag="$system-$key"
moving="$system-main"
# One tag per input: <system>.<repository name>.<commit>; two engines on one repository and commit share it.
input_tags="$(jq -r --arg system "$system" 'select(.included) | (.repository.remoteUrl // "" | sub("\\.git$"; "") | split("/") | last | ascii_downcase) as $repo
  | select($repo != "" and (.commit // "" | test("^[0-9a-f]{40}$"))) | "\($system).\($repo).\(.commit)"' "$work/out/system/inputs.ndjson" | sort -u)"
manifest_sha="$({ sha256sum "$manifest" 2>/dev/null || shasum -a 256 "$manifest"; } | cut -d ' ' -f 1)"
# Same generation, same bytes: sorted entries, fixed times and owners, no gzip timestamp (GNU tar of the image).
docker run --rm --network none --user "$user" --entrypoint sh -v "$work/out:/out" "$FEDERATION_IMAGE" -c \
  'tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C /out/system -cf - . | gzip -n > /out/generation.tar.gz'
mv "$work/out/generation.tar.gz" "$work/generation.tar.gz"
revision="${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}"
source="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-AlbertoMitroi/devos-lab}"
jq -n --arg source "$source" --arg revision "$revision" --arg ref "${GITHUB_REF:-refs/heads/main}" \
  --arg system "$system" --arg commit "$system_commit" --arg inputs "${pinned[*]}" --arg image "$federation_digest" \
  --arg manifest "$manifest_sha" \
  '{"$manifest": {"org.opencontainers.image.source": $source, "org.opencontainers.image.revision": $revision,
                  "org.opencontainers.image.ref.name": $ref, "dev.devos.intelligence.engine": "intelligence-federation",
                  "dev.devos.intelligence.generation-type": "system", "dev.devos.intelligence.system": $system,
                  "dev.devos.intelligence.system-commit": $commit, "dev.devos.intelligence.inputs": $inputs,
                  "dev.devos.intelligence.federation-image": $image},
    "generation.tar.gz": {"dev.devos.intelligence.manifest-sha256": $manifest}}' > "$work/annotations.json"
echo "status $status, manifest.json sha256 $manifest_sha"
echo "tags: $tag $moving $(printf '%s ' "$input_tags" | tr '\n' ' ')"

step "publish"
push_args=(--artifact-type "$ARTIFACT_TYPE" --annotation-file annotations.json "generation.tar.gz:$LAYER_TYPE")
# The moving tags: <system>-main and one per input.
others="$moving"
for t in $input_tags; do others="$others $t"; done
if [ "$PUSH" = true ]; then
  if existing="$(oras_auth manifest fetch "$TARGET:$tag" 2>/dev/null)"; then
    previous="$(printf '%s' "$existing" | jq -r '.layers[0].annotations["dev.devos.intelligence.manifest-sha256"] // empty')"
    [ "$previous" = "$manifest_sha" ] || { echo "$TARGET:$tag exists with manifest.json sha256 $previous, not $manifest_sha: the same key gave another system generation; the immutable tag is not overwritten" >&2; exit 1; }
    echo "$TARGET:$tag already holds this system generation; moving the other tags only"
  else
    oras_auth push "$TARGET:$tag" "${push_args[@]}"
  fi
  # shellcheck disable=SC2086
  oras_auth tag "$TARGET:$tag" $others
  digest="$(oras_auth resolve "$TARGET:$tag")"
  where="$TARGET:$tag ($digest)"
else
  oras push --oci-layout "oci:$tag" "${push_args[@]}" >/dev/null
  # shellcheck disable=SC2086
  oras tag --oci-layout "oci:$tag" $others >/dev/null
  digest="$(oras resolve --oci-layout "oci:$tag")"
  where="OCI layout $work/oci:$tag ($digest); not pushed (PUSH=$PUSH)"
fi
echo "$where"
echo "also tagged: $others"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "tag=$tag"; echo "digest=$digest"; echo "status=$status"; } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### System generation $system"
    echo "- Published: $where"
    echo "- Moving tags: $others"
    echo "- Status: $status, system commit $system_commit"
    echo "- Inputs:"
    for p in "${pinned[@]}"; do echo "  - \`$p\`"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi
