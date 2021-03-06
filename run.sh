#!/bin/bash
# set -xe

DOCKER_USERNAME=${DOCKER_USERNAME:-twang2218}
IMAGE_NAME=${IMAGE_NAME:-${DOCKER_USERNAME}/spark}
IMAGE_TAG=${IMAGE_TAG:-latest}

LATEST_SPARK_VERSION=2.2.0
LATEST_HADOOP_VERSION=2.7

SPARK_VERSIONS="1.6.3 2.0.2 2.1.1 2.2.0"
HADOOP_VERSIONS="2.3 2.4 2.6 2.7"

function remove_patch_version() {
  local version=$1
  echo "${version%.*}"
}

function get_dockerfile_path() {
  local spark_version=$1
  local hadoop_version=$2
  echo "$(remove_patch_version $spark_version)/hadoop$hadoop_version"
}

function get_image_tag() {
  local spark_version=$1
  local hadoop_version=$2
  echo "$spark_version-hadoop$hadoop_version"
}

function generate_dockerfile() {
  local spark_version=$1
  local hadoop_version=$2
  local path=`get_dockerfile_path $spark_version $hadoop_version`

  mkdir -p $path
  cat ./template/Dockerfile.template | sed \
    -e "s/#SPARK_VERSION#/$spark_version/g" \
    -e "s/#HADOOP_VERSION#/$hadoop_version/g" \
    > $path/Dockerfile
}

function generate() {
  generate_dockerfile 2.2.0 2.7
  generate_dockerfile 2.2.0 2.6
  generate_dockerfile 2.1.1 2.3
  generate_dockerfile 2.1.1 2.4
  generate_dockerfile 2.1.1 2.6
  generate_dockerfile 2.1.1 2.7
  generate_dockerfile 2.0.2 2.3
  generate_dockerfile 2.0.2 2.4
  generate_dockerfile 2.0.2 2.6
  generate_dockerfile 2.0.2 2.7
  generate_readme
}

function build_image() {
  local spark_version=$1
  local hadoop_version=$2
  local path=`get_dockerfile_path $spark_version $hadoop_version`
  local tag=`get_image_tag $spark_version $hadoop_version`

  docker build -t ${IMAGE_NAME}:${tag} ${path}
}

function test_image() {
  local spark_version=$1
  local hadoop_version=$2
  local tag=`get_image_tag $spark_version $hadoop_version`

  docker run -it --rm ${IMAGE_NAME}:${tag} spark-shell --version
}

function release_image() {
  local spark_version=$1
  local hadoop_version=$2
  local tag=`get_image_tag $spark_version $hadoop_version`
  local tag_list=`get_tag_list $spark_version $hadoop_version`
  docker push ${IMAGE_NAME}:${tag}

  for t in $tag_list; do
    if [ "$t" != "$tag" ]; then
      docker tag ${IMAGE_NAME}:${tag} ${IMAGE_NAME}:${t}
      docker push ${IMAGE_NAME}:${t}
    fi
  done
}

function build_and_test() {
  local spark_version=$1
  local hadoop_version=$2
  build_image $spark_version $hadoop_version
  test_image $spark_version $hadoop_version
}

function build_and_release() {
  local spark_version=$1
  local hadoop_version=$2
  build_image $spark_version $hadoop_version
  test_image $spark_version $hadoop_version
  release_image $spark_version $hadoop_version
}

function check_image() {
  local spark_version=$1
  local hadoop_version=$2
  local path=`get_dockerfile_path $spark_version $hadoop_version`
  local tag=`get_image_tag $spark_version $hadoop_version`

  if (git show --pretty="" --name-only | grep Dockerfile | grep -q $path); then
    echo "$path has been updated, rebuilding ${IMAGE_NAME}:$tag ..."
    build_and_release $spark_version $hadoop_version
  else
    echo "Nothing changed in $tag."
  fi
}

function get_tag_list() {
  local spark_version=$1
  local hadoop_version=$2

  local list=''
  # tag with patch version
  list+="`get_image_tag $spark_version $hadoop_version`"
  # tag without patch version
  list+=" `get_image_tag $(remove_patch_version $spark_version) $hadoop_version`"

  # branch tag without hadoop version
  if [ "$hadoop_version" = "$LATEST_HADOOP_VERSION" ]; then
    list+=" `remove_patch_version $spark_version`"
  fi

  # latest tag
  if [ "$spark_version" = "$LATEST_SPARK_VERSION" ] && [ "$hadoop_version" = "$LATEST_HADOOP_VERSION" ]; then
    list+=" latest"
  fi
  echo "$list"
}

function generate_tags_link() {
  local spark_version=$1
  local hadoop_version=$2
  local tags=`get_tag_list $spark_version $hadoop_version`

  local tags_label=''
  for i in $tags; do
    if [ -n "$tags_label" ]; then
      tags_label+=", "
    fi
    tags_label+="\`$i\`"
  done
  echo "- [${tags_label} (*${path}/Dockerfile*)](https://github.com/twang2218/docker-spark/blob/master/${path}/Dockerfile)"
}

function generate_readme() {
  local links=`foreach generate_tags_link`
  local tempfile=links.temp
  echo "$links" > $tempfile
  cat ./template/README.md.template | sed \
    -e "s#{IMAGE_NAME}#${IMAGE_NAME}#g" \
    -e "s/{LATEST_TAG}/$(remove_patch_version $LATEST_SPARK_VERSION)/g" \
    -e "/{VERSIONS}/ {r $tempfile" -e "d" -e "}" \
    -e "/{COMPOSE_EXAMPLE}/ {r docker-compose.yml" -e "d" -e "}" \
    > README.md
  rm $tempfile
}

function trigger_build() {
  local tag=$1
  if [ -n "$DOCKER_TRIGGER_TOKEN" ]; then
    curl --silent \
      --header "Content-Type: application/json" \
      --request POST \
      --data "{\"docker_tag\": \"$tag\"}" \
      https://registry.hub.docker.com/u/${IMAGE_NAME}/trigger/${DOCKER_TRIGGER_TOKEN}/
    echo -e "\nTriggerred Docker Hub build."
  else
    echo -e "\nDOCKER_TRIGGER_TOKEN is empty"
  fi
}

function run() {
  local version=${1:-$IMAGE_TAG}
  shift
  docker run -it --rm -p 7077:7077 -p 8080:8080 ${IMAGE_NAME}:${version} "$@"
}

function foreach() {
  local command="$@"
  for s in $SPARK_VERSIONS; do
    for h in $HADOOP_VERSIONS; do
      local path=`get_dockerfile_path $s $h`
      local tag=`get_image_tag $s $h`
      if [ -f "$path/Dockerfile" ]; then
        $command $s $h
      fi
    done
  done
}

function build() {
  generate
  foreach build_and_test
}

function release() {
  foreach release_image
}

function ci() {
  local option=$1
  if [[ -n "${DOCKER_PASSWORD}" ]]; then
    docker login -u "${DOCKER_USERNAME}" -p "${DOCKER_PASSWORD}"
  else
    echo "Cannot login to Docker Hub (DOCKER_PASSWORD is empty)"
    return 1
  fi

  # We just trigger the `base` build to refresh the README on the Hub
  trigger_build latest

  if [ "$option" == "--force" ]; then
    # build all no matter it's changed or not
    foreach build_and_release
  else
    foreach check_image
  fi

  # List all the images
  docker image list ${IMAGE_NAME}
}

function main() {
  local command=$1
  shift
  case $command in
    generate) generate "$@" ;;
    build)    build "$@" ;;
    run)      run "$@" ;;
    release)  release "$@" ;;
    ci)       ci "$@" ;;
    *)        echo "Usage: $0 (generate|build|run|release|ci)" ;;
  esac
}

main "$@"