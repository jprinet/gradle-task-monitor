FROM alpine:latest

RUN apk add --no-cache curl jq

RUN adduser -u 1000 -h /home/runner runner --disabled-password
USER runner
WORKDIR /home/runner

COPY --chown=runner *.sh /home/runner
RUN chmod +x /home/runner/*.sh
