#!/bin/bash

DATE=`date +'%Y%m%d%H%M'`
ruby bbb-live-monitor.rb | tee monitor-$DATE.out

