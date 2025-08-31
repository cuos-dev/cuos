#!/bin/bash


IMAGE="dockerboot_imagebuilder"
docker run --rm -it \
	--network=host \
	--privileged \
	-v /root/.docker/:/root/.docker/:ro \
	-v "${PWD}/../output/:/output/" \
	--name dockerboot-imagebuilder-container \
	--entrypoint /bin/bash \
	"${IMAGE}" #\
#	"${VERSION}"
