# Fixture for self-test.yml's image-only-suite: go-service-ci's `image` job
# builds this with `image-context: tests/go-service-ci/image`. Tiny on
# purpose; each RUN asserts one promise of that job, so a green build is the
# evidence:
FROM alpine:3.22

# amd64 only — the deployment target, never an emulated arm64 leg.
ARG TARGETPLATFORM
RUN test "$TARGETPLATFORM" = linux/amd64 || { echo "built for $TARGETPLATFORM, want linux/amd64"; exit 1; }

# CI_TOKEN arrives as the BuildKit secret every caller's Dockerfile mounts
# (id=ci_token); `required=true` fails the build if it is missing, and `-s`
# if it is empty.
RUN --mount=type=secret,id=ci_token,required=true test -s /run/secrets/ci_token
