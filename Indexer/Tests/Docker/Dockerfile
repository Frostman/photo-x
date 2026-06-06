FROM alpine:3.20

# exiftool: the binary's only runtime dep. Alpine's exiftool package
# pulls in perl + a few exiftool modules — ~30 MB total layer.
RUN apk add --no-cache exiftool

# Pre-staged cross-compiled binary (copied in by `just linux-test`).
# Lives next to the Dockerfile during the build so the build
# context stays small; gitignored so it doesn't end up tracked.
COPY photox-arm64 /usr/local/bin/photox
RUN chmod 755 /usr/local/bin/photox

# Smoke-test driver. Each test fails the run as soon as something
# unexpected happens.
COPY run.sh /run.sh
RUN chmod 755 /run.sh

ENTRYPOINT ["/run.sh"]
