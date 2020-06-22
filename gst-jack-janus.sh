#!/bin/sh

gst-launch-1.0 \
	jackaudiosrc name="Janus Streaming mountpoint" connect=0 ! \
		audioconvert ! opusenc bitrate=20000 ! rtpopuspay ! \
			udpsink host=127.0.0.1 port=20190
