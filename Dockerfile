FROM certbot/dns-dnsmadeeasy:v0.31.0
MAINTAINER Thomas Schaz <schazet@gmail.com>

RUN apk add --no-cache --update wget bash

RUN \
  wget https://storage.googleapis.com/kubernetes-release/release/v1.13.0/bin/linux/amd64/kubectl -O /usr/local/bin/kubectl && \
  chmod +x /usr/local/bin/kubectl

WORKDIR /opt/certbot
