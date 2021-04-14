## Zoneminder Docker
(Current version: 1.34)

This is an experimental branch, with major changes in Dockerfile in order to optimize the image size.

## Optimizations
Builder (container that requires compilers like GCC) has been isolated from the main container.
* The only Python wheel that requires to be compiled is [dlib](https://pypi.org/project/dlib). Then, wheels are passed to the container at the next step, then, installed without issues. This is better to using virtual environment, as I firtsly planned.
* The Perl modules also need to be compiled. As like Python wheels, the whole CPAN cache is passed to the container next step, and everything installs successfully but `Time::Piece` (see below)

## Caveats
The `Time::Piece` Perl module wont built as it requires to be compiled, even if the precompiled package has been passed to the new container, unlike the rest, that has been installed successfully.

## Usage
    docker run -d --name="Zoneminder" \
    --net="bridge" \
    --privileged="false" \
    --shm-size="8G" \
    -p 8443:443/tcp \
    -p 9000:9000/tcp \
    -e TZ="America/New_York" \
    -e PUID="99" \
    -e PGID="100" \
    -e MULTI_PORT_START="0" \
    -e MULTI_PORT_END="0" \
    -v "/mnt/Zoneminder":"/config":rw \
    -v "/mnt/Zoneminder/data":"/var/cache/zoneminder":rw \
    amitie10g/zoneminder

### Tags
* `latest` The latest build close to the upstream, based on Focal
* `testing` The lates build, with modifications in Dockerfile for optimizing size, based on Focal
* `i386` The latest build close to the upstream, for i386 machines, based on Bionic
* `testing-i386` The lates build, with modifications in Dockerfile for optimizing size, for i386 machines, based on Bionic

You may want to use the docker-compose way, so, the `docker.compose.yaml` is available.

See the [README.md](https://github.com/dlandon/zoneminder.machine.learning/blob/master/README.md) from upstream for further information
