#!/bin/bash
# calibre-web 0.6.27 validates kepubify against SUPPORTED_KEPUBIFY_BINARIES =
# ("kepubify-linux-64bit", "kepubify-linux-32bit") on Linux (cps/binary_helper.py),
# but the LSIO image ships the binary as /usr/bin/kepubify. Alias it so config
# validation and epub->kepub conversions resolve the binary. Runs every boot.
ln -sf /usr/bin/kepubify /usr/bin/kepubify-linux-64bit
