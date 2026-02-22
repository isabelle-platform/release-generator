FROM ubuntu:25.04

ARG DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /home/root
ENV HOME="/home/root"

RUN apt-get update && \
    apt-get install -y build-essential cargo curl git libssl-dev pkg-config wget

