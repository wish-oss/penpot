#!/usr/bin/env bash

export ORGANIZATION="penpotapp";
export DEVENV_IMGNAME="$ORGANIZATION/devenv";
export DEVENV_PNAME="penpotdev";

export CURRENT_USER_ID=$(id -u);
export CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD);

# Set default java options
export JAVA_OPTS=${JAVA_OPTS:-"-Xmx1000m -Xms50m"};

set -e

function print-current-version {
    echo -n "$(git describe --tags --match "*.*.*")";
}

function build-devenv {
    set +e;
    echo "Building development image $DEVENV_IMGNAME:latest..."

    pushd docker/devenv;

    docker run --privileged --rm tonistiigi/binfmt --install all
    docker buildx inspect penpot > /dev/null 2>&1;

    if [ $? -eq 1 ]; then
        docker buildx create --name=penpot --use
        docker buildx inspect --bootstrap > /dev/null 2>&1;
    else
        docker buildx use penpot;
        docker buildx inspect --bootstrap  > /dev/null 2>&1;
    fi

    # docker build -t $DEVENV_IMGNAME:latest .
    docker buildx build --platform linux/amd64,linux/arm64 --push -t $DEVENV_IMGNAME:latest .;
    docker pull $DEVENV_IMGNAME:latest;

    popd;
}

function build-devenv-local {
    echo "Building local only development image $DEVENV_IMGNAME:latest..."

    pushd docker/devenv;
    docker build -t $DEVENV_IMGNAME:latest .;
    popd;
}

function pull-devenv {
    set -ex
    docker pull $DEVENV_IMGNAME:latest
}

function pull-devenv-if-not-exists {
    if [[ ! $(docker images $DEVENV_IMGNAME:latest -q) ]]; then
        pull-devenv $@
    fi
}

function start-devenv {
    pull-devenv-if-not-exists $@;

    docker compose -p $DEVENV_PNAME -f docker/devenv/docker-compose.yaml up -d;
}

function create-devenv {
    pull-devenv-if-not-exists $@;

    docker compose -p $DEVENV_PNAME -f docker/devenv/docker-compose.yaml create;
}

function stop-devenv {
    docker compose -p $DEVENV_PNAME -f docker/devenv/docker-compose.yaml stop -t 2;
}

function drop-devenv {
    docker compose -p $DEVENV_PNAME -f docker/devenv/docker-compose.yaml down -t 2 -v;

    echo "Clean old development image $DEVENV_IMGNAME..."
    docker images $DEVENV_IMGNAME -q | awk '{print $3}' | xargs --no-run-if-empty docker rmi
}

function log-devenv {
    docker compose -p $DEVENV_PNAME -f docker/devenv/docker-compose.yaml logs -f --tail=50
}

function run-devenv-tmux {
    if [[ ! $(docker ps -f "name=penpot-devenv-main" -q) ]]; then
        start-devenv
    fi

    docker exec -ti penpot-devenv-main sudo -EH -u penpot PENPOT_PLUGIN_DEV=$PENPOT_PLUGIN_DEV /home/start-tmux.sh
}

function run-devenv-shell {
    if [[ ! $(docker ps -f "name=penpot-devenv-main" -q) ]]; then
        start-devenv
    fi
    docker exec -ti \
           -e JAVA_OPTS="$JAVA_OPTS" \
           -e EXTERNAL_UID=$CURRENT_USER_ID \
           penpot-devenv-main sudo -EH -u penpot bash;
}

function build {
    echo ">> build start: $1"
    local version=$(print-current-version);

    pull-devenv-if-not-exists;
    docker volume create ${DEVENV_PNAME}_user_data;
    docker run -t --rm \
           --mount source=${DEVENV_PNAME}_user_data,type=volume,target=/home/penpot/ \
           --mount source=`pwd`,type=bind,target=/home/penpot/penpot \
           -e EXTERNAL_UID=$CURRENT_USER_ID \
           -e BUILD_STORYBOOK=$BUILD_STORYBOOK \
           -e SHADOWCLJS_EXTRA_PARAMS=$SHADOWCLJS_EXTRA_PARAMS \
           -e JAVA_OPTS="$JAVA_OPTS" \
           -w /home/penpot/penpot/$1 \
           $DEVENV_IMGNAME:latest sudo -EH -u penpot ./scripts/build $version

    echo ">> build end: $1"
}

function put-license-file {
    local target=$1;
    tee -a $target/LICENSE  >> /dev/null <<EOF
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

Copyright (c) KALEIDOS INC
EOF
}

function build-frontend-bundle {
    echo ">> bundle frontend start";

    mkdir -p ./bundles
    local version=$(print-current-version);
    local bundle_dir="./bundles/frontend";

    build "frontend";

    rm -rf $bundle_dir;
    mv ./frontend/target/dist $bundle_dir;
    echo $version > $bundle_dir/version.txt;
    put-license-file $bundle_dir;
    echo ">> bundle frontend end";
}

function build-backend-bundle {
    echo ">> bundle backend start";

    mkdir -p ./bundles
    local version=$(print-current-version);
    local bundle_dir="./bundles/backend";

    build "backend";

    rm -rf $bundle_dir;
    mv ./backend/target/dist $bundle_dir;
    echo $version > $bundle_dir/version.txt;
    put-license-file $bundle_dir;
    echo ">> bundle backend end";
}

function build-exporter-bundle {
    echo ">> bundle exporter start";

    mkdir -p ./bundles
    local version=$(print-current-version);
    local bundle_dir="./bundles/exporter";

    build "exporter";

    rm -rf $bundle_dir;
    mv ./exporter/target $bundle_dir;
    echo $version > $bundle_dir/version.txt
    put-license-file $bundle_dir;
    echo ">> bundle exporter end";
}

function build-docs-bundle {
    echo ">> bundle docs start";

    mkdir -p ./bundles
    local version=$(print-current-version);
    local bundle_dir="./bundles/docs";

    build "docs";

    rm -rf $bundle_dir;
    mv ./docs/_dist $bundle_dir;
    echo $version > $bundle_dir/version.txt;
    put-license-file $bundle_dir;
    echo ">> bundle docs end";
}


function build-frontend-docker-images {
    rsync -avr --delete ./bundles/frontend/ ./docker/images/bundle-frontend/;
    pushd ./docker/images;
    docker build -t penpotapp/frontend:$CURRENT_BRANCH -t penpotapp/frontend:latest -f Dockerfile.frontend .;
    popd;
}

function build-backend-docker-images {
    rsync -avr --delete ./bundles/backend/ ./docker/images/bundle-backend/;
    pushd ./docker/images;
    docker build -t penpotapp/backend:$CURRENT_BRANCH -t penpotapp/backend:latest -f Dockerfile.backend .;
    popd;
}

function build-exporter-docker-images {
    rsync -avr --delete ./bundles/exporter/ ./docker/images/bundle-exporter/;
    pushd ./docker/images;
    docker build -t penpotapp/exporter:$CURRENT_BRANCH -t penpotapp/exporter:latest -f Dockerfile.exporter .;
    popd;
}

function usage {
    echo "PENPOT build & release manager"
    echo "USAGE: $0 OPTION"
    echo "Options:"
    echo "- pull-devenv                      Pulls docker development oriented image"
    echo "- build-devenv                     Build docker development oriented image"
    echo "- build-devenv-local               Build a local docker development oriented image"
    echo "- create-devenv                    Create the development oriented docker compose service."
    echo "- start-devenv                     Start the development oriented docker compose service."

function build-frontend-docker-images {
    rsync -avr --delete ./bundles/frontend/ ./docker/images/bundle-frontend/;
    pushd ./docker/images;
    docker build -t penpotapp/frontend:$CURRENT_BRANCH -t penpotapp/frontend:latest -f Dockerfile.frontend .;
    popd;
}

function build-backend-docker-images {
    rsync -avr --delete ./bundles/backend/ ./docker/images/bundle-backend/;
    pushd ./docker/images;
    docker build -t penpotapp/backend:$CURRENT_BRANCH -t penpotapp/backend:latest -f Dockerfile.backend .;
    popd;
}

function build-exporter-docker-images {
    rsync -avr --delete ./bundles/exporter/ ./docker/images/bundle-exporter/;
    pushd ./docker/images;
    docker build -t penpotapp/exporter:$CURRENT_BRANCH -t penpotapp/exporter:latest -f Dockerfile.exporter .;
    popd;
}

function usage {
    echo "PENPOT build & release manager"
    echo "USAGE: $0 OPTION"
    echo "Options:"
    echo "- pull-devenv                      Pulls docker development oriented image"
    echo "- build-devenv                     Build docker development oriented image"
    echo "- build-devenv-local               Build a local docker development oriented image"
    echo "- create-devenv                    Create the development oriented docker compose service."
    echo "- start-devenv                     Start the development oriented docker compose service."
    echo "- stop-devenv                      Stops the development oriented docker compose service."
    echo "- drop-devenv                      Remove the development oriented docker compose containers, volumes and clean images."
    echo "- run-devenv                       Attaches to the running devenv container and starts development environment"
    echo "- run-devenv-shell                 Attaches to the running devenv container and starts a bash shell."
    echo "- log-devenv                       Show logs of the running devenv docker compose service."
    echo ""
    echo "- build-bundle                     Build all bundles (frontend, backend and exporter)."
    echo "- build-frontend-bundle            Build frontend bundle"
    echo "- build-backend-bundle             Build backend bundle."
    echo "- build-exporter-bundle            Build exporter bundle."
    echo "- build-docs-bundle                Build docs bundle."
    echo ""
    echo "- build-docker-images              Build all docker images (frontend, backend and exporter)."
    echo "- build-frontend-docker-images     Build frontend docker images."
    echo "- build-backend-docker-images      Build backend docker images."
    echo "- build-exporter-docker-images     Build exporter docker images."
    echo ""
    echo "- version                          Show penpot's version."
}

case $1 in
    version)
        print-current-version
        ;;

    ## devenv related commands
    pull-devenv)
        pull-devenv ${@:2};
        ;;

    build-devenv)
        build-devenv ${@:2}
        ;;

    build-devenv-local)
        build-devenv-local ${@:2}
        ;;

    create-devenv)
        create-devenv ${@:2}
        ;;

    start-devenv)
        start-devenv ${@:2}
        ;;
    run-devenv)
        run-devenv-tmux ${@:2}
        ;;
    run-devenv-shell)
        run-devenv-shell ${@:2}
        ;;
    stop-devenv)
        stop-devenv ${@:2}
        ;;
    drop-devenv)
        drop-devenv ${@:2}
        ;;
    log-devenv)
        log-devenv ${@:2}
        ;;

    ## production builds
    build-bundle)
        build-frontend-bundle;
        build-backend-bundle;
        build-exporter-bundle;
        ;;

    build-frontend-bundle)
        build-frontend-bundle;
        ;;

    build-backend-bundle)
        build-backend-bundle;
        ;;

    build-exporter-bundle)
        build-exporter-bundle;
        ;;

    build-docs-bundle)
        build-docs-bundle;
        ;;

    build-docker-images)
        build-frontend-docker-images
        build-backend-docker-images
        build-exporter-docker-images
        ;;

    build-frontend-docker-images)
        build-frontend-docker-images
        ;;

    build-backend-docker-images)
        build-backend-docker-images
        ;;

    build-exporter-docker-images)
        build-exporter-docker-images
        ;;

    *)
        usage
        ;;
esac
