#!/bin/bash
# This script generates cron job creation commands for all 90 Nixelo tasks
# Just a reference file - actual creation is done via cron tool

# Allocation:
# Bolt: 14 (hours 0-6, ~30min intervals)
# Sentinel: 14 (hours 7-13)
# Spectra: 14 (hours 14-20)
# Auditor: 10
# Palette: 9
# Inspector: 9
# Refactor: 8
# Schema: 6
# Scribe: 5
# Librarian: 1

# Schedule mapping (total 90 tasks across 24 hours):
# 00:00-06:30 = Bolt (14 slots)
# 07:00-13:30 = Sentinel (14 slots)
# 14:00-20:30 = Spectra (14 slots)  
# 21:00-21:30 = Auditor 1-2
# 22:00-23:00 = Auditor 3-5
# Then wrap around or double up

echo "Reference file for Nixelo job allocation"
