#!/bin/bash
# More info on: http://www.brendangregg.com/flamegraphs.html#Updates

# Install performance tools
apt-get -y install linux-tools-common linux-tools-$(uname -r) apache2 sysstat

# Install pyflame
apt-get -y install autoconf automake autotools-dev g++ pkg-config python-dev libtool
cd pyflame
./autogen.sh
./configure    
make
make install
cd -

# Install flamegraph
git clone --depth 1 https://github.com/brendangregg/Flamegraph
