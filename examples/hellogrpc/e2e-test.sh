#!/usr/bin/env bash
set -e

# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

if [[ -z "${1:-}" ]]; then
  echo "Usage: $(basename $0) <kubernetes namespace> <language ...>"
  exit 1
fi
namespace="$1"
shift
if [[ -z "${1:-}" ]]; then
  echo "ERROR: Languages not provided!"
  echo "Usage: $(basename $0) <kubernetes namespace> <language ...>"
  exit 1
fi

get_lb_ip() {
  kubectl --namespace="${namespace}" get service hello-grpc-staging \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

# Ensure there is an ip address for hell-grpc-staging:50051
apply-lb() {
  echo Applying service...
  bazel build examples/hellogrpc:staging-service.apply
  bazel-bin/examples/hellogrpc/staging-service.apply
}

create() {
  echo Creating $LANGUAGE...
  bazel build examples/hellogrpc/${LANGUAGE}/server:staging.create
  bazel-bin/examples/hellogrpc/${LANGUAGE}/server/staging.create
}

check_msg() {
  bazel build examples/hellogrpc/${LANGUAGE}/client

  while [[ -z $(get_lb_ip) ]]; do
    echo "service has not yet received an IP address, sleeping for 5s..."
    sleep 10
  done

  # Wait some more for after IP address allocation for the service to come
  # alive
  echo "Got IP Adress! Sleeping 30s more for service to come alive..."
  sleep 30

  OUTPUT=$(./bazel-bin/examples/hellogrpc/${LANGUAGE}/client/client $(get_lb_ip))
  echo Checking response from service: "${OUTPUT}" matches: "DEMO$1<space>"
  echo "${OUTPUT}" | grep "DEMO$1[ ]"
}

edit() {
  echo Setting $LANGUAGE to "$1"
  ./examples/hellogrpc/${LANGUAGE}/server/edit.sh "$1"
}

update() {
  echo Updating $LANGUAGE...
  bazel build examples/hellogrpc/${LANGUAGE}/server:staging.replace
  bazel-bin/examples/hellogrpc/${LANGUAGE}/server/staging.replace
}

delete() {
  echo Deleting $LANGUAGE...
  kubectl get all --namespace="${namespace}" --selector=app=hello-grpc-staging
  bazel build examples/hellogrpc/${LANGUAGE}/server:staging.describe
  bazel-bin/examples/hellogrpc/${LANGUAGE}/server/staging.describe || echo "Resource didn't exist!"
  bazel build examples/hellogrpc/${LANGUAGE}/server:staging.delete
  bazel-bin/examples/hellogrpc/${LANGUAGE}/server/staging.delete
}


apply-lb

while [[ -n "${1:-}" ]]; do
  LANGUAGE="$1"
  shift

  delete &> /dev/null || true
  create
  set +o xtrace
  trap "echo FAILED, cleaning up...; delete" EXIT
  set -o xtrace
  sleep 25
  check_msg ""

  for i in $RANDOM $RANDOM; do
    edit "$i"
    update
    # Don't let K8s slowness cause flakes.
    sleep 25
    check_msg "$i"
  done
  delete
done

# Replace the trap with a success message.
trap "echo PASS" EXIT
