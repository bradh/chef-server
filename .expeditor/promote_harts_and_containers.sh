#!/bin/bash

set -eou pipefail

if [ "${TARGET_CHANNEL}" = "unstable" ];
then
  echo "This file does not support actions for artifacts promoted to unstable"
  exit 1
fi

#
# The following standard Expeditor artifact_actions environment variables
# are automatically set by the calling process:
#
# PROMOTABLE - in promotion artifact actions this is a reference to the
#              source channel.
# TARGET_CHANNEL - the channel which we are promoting to
#

source_channel=$PROMOTABLE

# Download the manifest
aws s3 cp "s3://chef-automate-artifacts/${source_channel}/latest/chef-server/manifest.json" manifest.json --profile chef-cd

# Download or create the versions file
aws s3 cp "s3://chef-automate-artifacts/${TARGET_CHANNEL}/latest/chef-server/versions.json" existing-versions.json --profile chef-cd || echo "[]" > existing-versions.json

# Promote the artifacts in Habitat Depot
jq -r -c ".packages[]" manifest.json | while read service_ident; do
  # service_ident will look like: chef/oc_erchef/12.18.2/20180806132701
  pkg_origin=$(echo $service_ident | cut -d / -f 1) # chef
  pkg_name=$(echo $service_ident | cut -d / -f 2) # oc_erchef
  pkg_version=$(echo $service_ident | cut -d / -f 3) # 12.18.2
  pkg_release=$(echo $service_ident | cut -d / -f 4) # 20180806132701

  if [ "$pkg_origin" = "core" ];
  then
    echo "Skipping promotion of core origin package ${service_ident}"
  else
    echo "Promoting ${service_ident} hart to the ${TARGET_CHANNEL} channel"
    hab pkg promote "${service_ident}" "${TARGET_CHANNEL}"

    echo "Promoting ${pkg_origin}/${pkg_name}:${pkg_version}-${pkg_release} container to ${TARGET_CHANNEL} tag"
    docker pull "${pkg_origin}/${pkg_name}:${pkg_version}-${pkg_release}"
    docker tag "${pkg_origin}/${pkg_name}:${pkg_version}-${pkg_release}" "${pkg_origin}/${pkg_name}:${TARGET_CHANNEL}"
    docker push "${pkg_origin}/${pkg_name}:${TARGET_CHANNEL}"

    if [ "$TARGET_CHANNEL" = "stable" ];
    then
      docker tag "${pkg_origin}/${pkg_name}:${pkg_version}-${pkg_release}" "${pkg_origin}/${pkg_name}:latest"
      docker push "${pkg_origin}/${pkg_name}:latest"
      docker rmi "${pkg_origin}/${pkg_name}:latest"
    fi

    docker rmi "${pkg_origin}/${pkg_name}:${pkg_version}-${pkg_release}" "${pkg_origin}/${pkg_name}:${TARGET_CHANNEL}"
  fi
done

# Append the new version to the target channel versions file
jq ". |= .+ [\"$(jq -r -c ".build" manifest.json)\"]" existing-versions.json > updated-versions.json

# Promote the License Scout Dependency Manifest
aws s3 cp "s3://chef-automate-artifacts/${source_channel}/latest/chef-server/licenses.json" "s3://chef-automate-artifacts/${TARGET_CHANNEL}/latest/chef-server/licenses.json" --acl public-read  --profile chef-cd
# Promote the manifest
aws s3 cp manifest.json "s3://chef-automate-artifacts/${TARGET_CHANNEL}/latest/chef-server/manifest.json" --acl public-read  --profile chef-cd
# Upload the updated versions file
aws s3 cp updated-versions.json "s3://chef-automate-artifacts/${TARGET_CHANNEL}/latest/chef-server/versions.json" --acl public-read  --profile chef-cd

# Cleanup
rm manifest.json
rm existing-versions.json
rm updated-versions.json
