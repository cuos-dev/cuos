#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

get_reports_filter() {
  grep report_ -- "$@" | sed -e 's/^[	 ]*report_//g' | sed -e 's#$#'" \"$1\""'#'
  #| grep -v 'err "$@"'
}
export -f get_reports_filter

find system updater \
  -name \*.sh \
  -not -name utils.sh \
  -exec bash -c 'get_reports_filter "$@"' -- '{}' ';'

#find system -name \*.sh -not -name utils.sh -exec grep report_ '{}' ';' | sed -e 's/^[	 ]*report_//g'

